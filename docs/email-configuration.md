# Email Configuration

Cluster-wide SMTP settings for sending email alerts from `alert@jardoole.xyz` via Gmail relay.

## Overview

| Setting | Value |
|---------|-------|
| Host | `smtp.gmail.com` |
| Port | `587` |
| TLS | `true` |
| From Address | `alert@jardoole.xyz` |

**How it works:** Gmail SMTP sends emails with `alert@jardoole.xyz` as the "From" address. Recipients see the custom domain address (with "via gmail.com" in headers).

## Prerequisites

Complete these steps before deploying.

### 1. Set Up Cloudflare Email Routing

Route `alert@jardoole.xyz` to your Gmail address:

1. Cloudflare Dashboard → jardoole.xyz → Email → Email Routing
2. Enable Email Routing if not already enabled
3. Create routing rule: `alert@jardoole.xyz` → your Gmail address
4. Verify destination email if prompted

### 2. Add "Send As" Address in Gmail

Configure Gmail to send as `alert@jardoole.xyz`:

1. Gmail → Settings (gear icon) → See all settings
2. Accounts and Import → "Send mail as" → Add another email address
3. Enter: Name: `Home Lab Alerts`, Email: `alert@jardoole.xyz`
4. Uncheck "Treat as an alias" (optional)
5. SMTP Server: `smtp.gmail.com`
6. Port: `587`
7. Username: your Gmail address
8. Password: your Gmail App Password (see step 3)
9. Select "Secured connection using TLS"
10. Click "Add Account"
11. Gmail sends verification email to `alert@jardoole.xyz` (forwards to your Gmail)
12. Click the verification link or enter the code

### 3. Create Gmail App Password

1. Go to [Google Account](https://myaccount.google.com/)
2. Security → 2-Step Verification (must be enabled)
3. At bottom: App passwords
4. Select app: "Mail", Select device: "Other (Custom name)"
5. Enter: "Home Lab SMTP"
6. Click Generate
7. Copy the 16-character password (shown with spaces, but spaces are optional)

## Add Secrets to Vault

Add SMTP credentials to `group_vars/all/vault.yml`:

```bash
uv run ansible-vault edit group_vars/all/vault.yml
```

Add:

```yaml
# SMTP credentials (Gmail App Password)
vault_smtp_username: "your-gmail@gmail.com"
vault_smtp_password: "xxxx-xxxx-xxxx-xxxx"
```

## Variable Reference

**Non-secret variables** in `group_vars/all/main.yml`:

| Variable | Value | Description |
|----------|-------|-------------|
| `smtp_host` | `smtp.gmail.com` | SMTP server |
| `smtp_port` | `587` | SMTP port (STARTTLS) |
| `smtp_use_tls` | `true` | Use STARTTLS |
| `smtp_use_ssl` | `false` | Don't use implicit SSL |
| `smtp_from` | `alert@jardoole.xyz` | Sender address |

**Secret variables** in `group_vars/all/vault.yml`:

| Variable | Description |
|----------|-------------|
| `vault_smtp_username` | Gmail address |
| `vault_smtp_password` | Gmail App Password |

## App Configurations

### Alertmanager

Configured in `apps/kube-prometheus-stack/values.yml`. Sends alert notifications to the Gmail address.

Deploy after adding vault secrets:

```bash
make app-deploy APP=kube-prometheus-stack
```

### Other Apps

Use the same variables when configuring email for other apps (e.g., Authentik):

```yaml
email:
  host: "{{ smtp_host }}"
  port: "{{ smtp_port }}"
  username: "{{ vault_smtp_username }}"
  password: "{{ vault_smtp_password }}"
  use_tls: "{{ smtp_use_tls }}"
  from: "{{ smtp_from }}"
```

## Verification

After deployment, test email delivery:

1. Access Alertmanager: https://alert-manager.jardoole.xyz
2. Status → Check SMTP configuration is loaded
3. Trigger a test alert or wait for a real alert
4. Check Gmail inbox for email from `alert@jardoole.xyz`

## Troubleshooting

### "Authentication failed"

- Verify App Password is correct (no typos)
- Ensure 2-Step Verification is enabled on Gmail
- Check `vault_smtp_username` matches the Gmail account

### "From address not allowed"

- Complete the "Send As" verification in Gmail
- Ensure `alert@jardoole.xyz` appears in Gmail's "Send mail as" list

### Emails not arriving

- Check spam folder
- Verify Cloudflare Email Routing is working (send test email to `alert@jardoole.xyz`)
- Check Alertmanager logs: `kubectl logs -n monitoring -l app.kubernetes.io/name=alertmanager`
