# Paperless-ngx + Cornerstone AI via OpenRouter

**Date:** 2026-10-12
**Status:** Approved, ready to implement

## Problem

Two self-hosted services can use a large language model, and both are currently
off — no provider is configured:

- **Paperless-ngx AI features** (`PAPERLESS_AI_ENABLED`, default `false`):
  automatic suggestions for titles, tags, correspondents and document types,
  plus RAG retrieval over the document archive via a separate embedding model.
- **Cornerstone Auto-itemize** / **New Invoice from a document**: reads the OCR
  text Paperless produced for a linked invoice and proposes one budget line per
  row on the page. The feature is hidden entirely until `LLM_BASE_URL`,
  `LLM_API_KEY` and `LLM_MODEL` are set.

The household archive is **mostly Swedish with some English** invoices and
documents. Both services need an LLM that speaks Swedish, follows a strict
JSON-only prompt (Cornerstone requires a specific response shape and warns that
weak models fail it), and is cheap enough to run unattended indexing plus
per-invoice itemization without metering.

## Decisions (user-confirmed)

- **Single provider for both services: OpenRouter**, with one shared API key.
  OpenRouter exposes an OpenAI-compatible chat-completions API *and* a separate
  embeddings catalog, so no local Ollama or sentence-transformers service is
  needed.
- **Chat model: `openai/gpt-6-luna`** — $0.10 / $0.50 per million prompt /
  completion tokens, 1.05M context, and notably supports both
  `response_format` and `structured_outputs`, which Cornerstone's JSON-only
  prompt requires. Pinned slug (`openai/gpt-6-luna`), **not**
  `~openai/gpt-luna-latest`, matching the repo's deliberate-pin convention.
- **Embedding model: `baai/bge-m3`** — $0.01 per million tokens, 1024-dim,
  8194-token context, explicitly multilingual (Swedish + English). Paid, so it
  carries none of the "requests may be retained and used for training" caveats
  that OpenRouter's *free* embedding models do.
- **OCR: Swedish is the default language, English secondary.** Documents are
  mostly Swedish, so Tesseract must run with the Swedish model first.
- **Paperless AI output language: Swedish** (`swe`) — a Swedish archive should
  get Swedish titles/tags/correspondent, independent of which user is logged in.
- **Paperless chat calls are pinned to non-collecting providers** via an
  OpenRouter routing preference in the request body.
- **Cornerstone routing is left at OpenRouter's default** — the user accepted
  this; Cornerstone exposes no provider-routing configuration.

### Verified against the live OpenRouter API (2026-10-12)

- `openai/gpt-6-luna`: prompt `0.0000001` ($0.10/M), completion `0.0000005`
  ($0.50/M), 1,050,000 context, `supported_parameters` includes
  `response_format`, `structured_outputs`, `tools`, `reasoning_effort`.
- `deepseek/deepseek-v4.1-flash`: prompt `0.00000015` ($0.15/M), completion
  `0.0000006` ($0.60/M), 1,048,576 context, `structured_outputs` supported —
  the documented fallback if Luna proves weak on messy invoices.
- `baai/bge-m3` appears in `/api/v1/embeddings/models` (a **separate** catalog
  from `/api/v1/models`): 1024-dim, context 8194, prompt `0.00000001`
  ($0.01/M). This is why the embedding backend is viable on OpenRouter at all.

## Design

### 1. Shared secret

One cluster-wide key in `group_vars/all/vault.yml`, next to the existing
`vault_smtp_*` cluster-wide secrets:

```yaml
vault_openrouter_api_key: "<key added by operator via ansible-vault edit>"
```

Both services reference `{{ vault_openrouter_api_key }}`. A single key keeps
OpenRouter spend and rotation in one place. The operator adds it with
`ansible-vault edit`; vault files are never read or edited by tooling.

### 2. Paperless-ngx

`group_vars/paperless/main.yml` — new variables (with the repo's
What/Why/Resolves comment convention):

```yaml
# OCR — documents are mostly Swedish with some English. `swe+eng` makes
# Tesseract run the Swedish model first; `paperless_ocr_languages` installs
# the packs. German is retained because it was already installed and only
# loads when a document matches.
paperless_ocr_language: "swe+eng"
paperless_ocr_languages: "swe eng deu"

# AI — OpenRouter (OpenAI-compatible chat + embeddings).
paperless_ai_enabled: true
paperless_ai_llm_backend: "openai-like"
paperless_ai_llm_model: "openai/gpt-6-luna"
paperless_ai_llm_endpoint: "https://openrouter.ai/api/v1"
paperless_ai_llm_output_language: "swe"
# OpenRouter routing can exceed the 120s default; 180s gives headroom.
paperless_ai_llm_request_timeout: 180
# Routing guard: only use upstream providers that do not collect request data.
paperless_ai_llm_extra_params: '{"provider":{"data_collection":"deny"}}'

# Embeddings for RAG. bge-m3 accepts up to 8194 tokens; 1024-token chunks
# leave margin and match the default.
paperless_ai_embedding_backend: "openai-like"
paperless_ai_embedding_model: "baai/bge-m3"
paperless_ai_embedding_endpoint: "https://openrouter.ai/api/v1"
paperless_ai_embedding_chunk_size: 1024
```

`roles/paperless/templates/env.j2` — append, after the SSO block:

```
# AI — LLM + embeddings via OpenRouter
PAPERLESS_AI_ENABLED={{ paperless_ai_enabled | lower }}
PAPERLESS_AI_LLM_BACKEND={{ paperless_ai_llm_backend }}
PAPERLESS_AI_LLM_MODEL={{ paperless_ai_llm_model }}
PAPERLESS_AI_LLM_ENDPOINT={{ paperless_ai_llm_endpoint }}
PAPERLESS_AI_LLM_API_KEY={{ vault_openrouter_api_key }}
PAPERLESS_AI_LLM_OUTPUT_LANGUAGE={{ paperless_ai_llm_output_language }}
PAPERLESS_AI_LLM_REQUEST_TIMEOUT={{ paperless_ai_llm_request_timeout }}
PAPERLESS_AI_LLM_EXTRA_PARAMS={{ paperless_ai_llm_extra_params }}
PAPERLESS_AI_LLM_ALLOW_INTERNAL_ENDPOINTS=false
PAPERLESS_AI_LLM_EMBEDDING_BACKEND={{ paperless_ai_embedding_backend }}
PAPERLESS_AI_LLM_EMBEDDING_MODEL={{ paperless_ai_embedding_model }}
PAPERLESS_AI_LLM_EMBEDDING_ENDPOINT={{ paperless_ai_embedding_endpoint }}
PAPERLESS_AI_LLM_EMBEDDING_CHUNK_SIZE={{ paperless_ai_embedding_chunk_size }}
```

`PAPERLESS_AI_LLM_ALLOW_INTERNAL_ENDPOINTS=false` is set because the endpoint
is a public host; it is the safe value and matches intent.

The default embedding index cron (`10 2 * * *`) is left as-is: Paperless's AI
indexing is an outbound API call plus local index writes, and the same-host DB
backup at 02:00 is a short pg_dump — contention is negligible.

### 3. Cornerstone

`group_vars/cornerstone/main.yml`:

```yaml
# LLM — OpenRouter shared with Paperless (same key, same model).
cornerstone_llm_base_url: "https://openrouter.ai/api/v1"
cornerstone_llm_model: "openai/gpt-6-luna"
# OpenRouter is not one of the providers Cornerstone auto-detects
# (openai/anthropic/gemini/ollama), so pin generic.
cornerstone_llm_provider: "generic"
# Auto-itemize on a full backlog can exceed the 30s default; 120s is safe.
cornerstone_llm_request_timeout_ms: 120000
```

`roles/cornerstone/templates/env.j2` — append, after the Paperless block:

```
# ---- LLM (Auto-itemize / invoice-from-document) ------------------------------
LLM_BASE_URL={{ cornerstone_llm_base_url }}
LLM_API_KEY={{ vault_openrouter_api_key }}
LLM_MODEL={{ cornerstone_llm_model }}
LLM_PROVIDER={{ cornerstone_llm_provider }}
LLM_REQUEST_TIMEOUT_MS={{ cornerstone_llm_request_timeout_ms }}
```

`LLM_MAX_TOKENS` is left at its 16384 default (handles 100+ line invoices).

### 4. Documentation

The repo mandates that every config change records what/why/issue-resolved. The
non-obvious values here (the routing guard, the `generic` provider, the raised
timeouts, `LANG=swe+eng`) carry inline comments in both `group_vars` files. No
separate operational doc is needed; the design rationale lives in this spec and
in the `group_vars` comments.

## Verification

1. Add `vault_openrouter_api_key` to `group_vars/all/vault.yml`.
2. Deploy Paperless: `make app service=paperless`.
   - `uv run ansible paperless -a "grep -c '^PAPERLESS_AI_' /opt/paperless/.env"`
     returns the expected count (read-only check).
   - In the Paperless UI, run an AI suggestion on a Swedish document; the
     suggested title/tags come back in Swedish.
   - Trigger the embedding index and confirm no auth/routing errors in the logs.
3. Deploy Cornerstone: `make app service=cornerstone`.
   - Open an invoice with a linked Paperless document; the **Auto-itemize**
     action is visible (proves all three required vars reached the container).
   - Run Auto-itemize on one Swedish invoice; extracted lines are sensible and
     can be saved.
4. `make precommit` to run lint/guards before committing.

## Residual risks (accepted)

- `data_collection:"deny"` applies to Paperless **chat** calls only. Paperless
  has no separate embedding extra-params variable, and Cornerstone exposes no
  routing configuration, so embedding calls and all Cornerstone calls route at
  OpenRouter's default. Accepted by the user.
- `LLM_PROVIDER=generic` is an inference about OpenRouter support; if it
  misbehaves at runtime, the fallback is `LLM_PROVIDER=openai`.
- Changing `baai/bge-m3` later invalidates the existing embedding index and
  requires a full re-index.
- Both services now send document OCR text and metadata to a third party for
  every AI operation. This is inherent to the chosen provider and was accepted.
