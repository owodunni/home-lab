# OpenClaw AI Assistant

AI assistant with Signal messaging integration, Ollama cloud LLM (MiniMax M2.5), and Chrome browser automation. Web UI protected by Authentik forward auth.

## Architecture

| Component | Configuration |
|-----------|---------------|
| Chart | `openclaw/openclaw` v1.3.16 |
| LLM | Ollama cloud with MiniMax M2.5 |
| Messaging | Signal (dedicated phone number) |
| Browser | Chrome CDP sidecar (headless) |
| Ingress | `openclaw.jardoole.xyz` with TLS |
| Auth | Authentik forward auth (no anonymous access) |

## Vault Secrets Required

Before deploying, add these secrets to `group_vars/all/vault.yml`:

```yaml
vault_openclaw_ollama_api_key: "<ollama-cloud-api-key>"
vault_openclaw_gateway_token: "<generated-hex-32>"
vault_openclaw_secret_key: "<generated-hex-64>"
vault_openclaw_signal_phone: "<+1234567890>"
vault_openclaw_signal_allowed_numbers: "<+1234567890,+0987654321>"
```

Generate secrets with:

```bash
# Gateway token
openssl rand -hex 32

# Secret key
openssl rand -hex 64
```

Edit vault:

```bash
uv run ansible-vault edit group_vars/all/vault.yml
```

## Pre-install Steps

1. Generate secrets and add to vault (see above)
2. Obtain an Ollama cloud API key
3. Have a dedicated Signal phone number ready
4. Add Helm repository:
   ```bash
   make k3s-helm-setup
   ```

## Deployment

```bash
make app-deploy APP=openclaw
```

## Post-install Steps

### Configure Authentik

1. Create a **Proxy Provider** in Authentik:
   - Name: `openclaw`
   - Mode: Forward auth (single application)
   - External host: `https://openclaw.jardoole.xyz`

2. Create an **Application**:
   - Name: `OpenClaw`
   - Slug: `openclaw`
   - Provider: `openclaw`

3. Add the application to the **embedded outpost**

4. Bind user groups (Admins, Users) to the application

### Link Signal Account

1. Visit `https://openclaw.jardoole.xyz` (login via Authentik)
2. Navigate to Signal channel settings
3. Follow QR code registration to link your Signal number

### Verify Ollama Connectivity

Check that MiniMax M2.5 responses work in the web UI chat.

### Install ClawHub Skills

Install additional skills as needed from the ClawHub marketplace within the web UI.

## Verification

```bash
# Check pods (main + chromium sidecar)
kubectl get pods -n openclaw

# Check logs
kubectl logs -n openclaw -l app.kubernetes.io/name=openclaw

# Check ingress
kubectl get ingress -n openclaw
```

## Storage

| Volume | Type | Size | Purpose |
|--------|------|------|---------|
| data | NFS PVC | 5Gi | Config, skills, credentials, workspace |
| shm | emptyDir (Memory) | 512Mi | Chrome shared memory |
| tmp | emptyDir | - | Temporary scratch space |

## Troubleshooting

### Signal Linking Issues

If Signal QR code registration fails, check the phone number format (E.164: `+1234567890`):

```bash
kubectl logs -n openclaw -l app.kubernetes.io/name=openclaw -c main | grep -i signal
```

### Ollama Connectivity

Verify the API key is set and Ollama cloud is reachable:

```bash
kubectl logs -n openclaw -l app.kubernetes.io/name=openclaw -c main | grep -i ollama
```

### Chrome OOM (Out of Memory)

If Chrome crashes with OOM, check `/dev/shm` usage. The sidecar is limited to 512Mi shared memory:

```bash
kubectl describe pod -n openclaw -l app.kubernetes.io/name=openclaw
```

### Pod Restart Loop

Check init container logs (config merge or skill install failures):

```bash
kubectl logs -n openclaw -l app.kubernetes.io/name=openclaw -c init-config
kubectl logs -n openclaw -l app.kubernetes.io/name=openclaw -c init-skills
```
