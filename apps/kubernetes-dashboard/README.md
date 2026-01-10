# Kubernetes Dashboard

Web-based UI for managing and monitoring the Kubernetes cluster.

## Access

- **URL**: https://dashboard.jardoole.xyz
- **Authentication**: Bearer token (see below)

## Getting Access Token

To log in to the dashboard, you need a bearer token:

```bash
# Get the token for the kubernetes-dashboard service account
kubectl -n dashboard create token kubernetes-dashboard --duration=87600h
```

This creates a token valid for 10 years. Copy and paste it into the dashboard login page.

## Features

- View cluster resources (pods, deployments, services, etc.)
- Monitor resource usage (CPU, memory)
- View logs from containers
- Execute commands in containers
- Edit resources via YAML
- Full admin access to the cluster

## Security

- Protected by TLS (Let's Encrypt certificate)
- Requires bearer token authentication
- Admin-level access (clusterAdminRole: true)
- Accessible only via ingress (not exposed externally except through Traefik)

## Dependencies

- cert-manager (for TLS certificates)
- Traefik (for ingress)
