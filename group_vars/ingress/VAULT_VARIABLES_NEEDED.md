# Vault Variables Required — ingress layer

These must be added to vault files before running `make ingress` or `make services`.

## group_vars/all/vault.yml

```
vault_cloudflare_api_token: "<Cloudflare API token — DNS:Edit permission for jardoole.xyz>"
```

If this already exists from a previous setup, no action needed.

To edit:
```
ansible-vault edit group_vars/all/vault.yml
```

## host_vars/beelink/vault.yml

```
vault_garage_rpc_secret: "<32-byte hex — generate with: openssl rand -hex 32>"
vault_garage_admin_token: "<random string — generate with: openssl rand -base64 32>"
```

To edit:
```
ansible-vault edit host_vars/beelink/vault.yml
```
