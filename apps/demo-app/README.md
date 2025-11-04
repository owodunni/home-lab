# Demo App

Simple nginx deployment demonstrating the standardized app deployment workflow with persistent storage and SSL certificates.

## Purpose

This app validates the complete deployment system:
- Helm chart deployment via reusable playbook
- Persistent storage using Longhorn
- SSL certificates via cert-manager and Let's Encrypt
- Ingress with HTTPS access

## Features

- **Chart**: bitnami/nginx 18.2.5
- **Namespace**: applications
- **Storage**: 1Gi persistent volume (Longhorn)
- **SSL**: Automatic Let's Encrypt certificate
- **URL**: https://demo.jardoole.xyz
- **Resources**: Small profile (50m CPU, 64Mi RAM)

## Deployment

```bash
# Validate configuration
make helm-lint

# Deploy
make app-deploy APP=demo-app

# Check status
make app-status APP=demo-app

# Verify pods
kubectl get pods -n applications --kubeconfig=/etc/rancher/k3s/k3s.yaml

# Check certificate
kubectl get certificate -n applications --kubeconfig=/etc/rancher/k3s/k3s.yaml

# Test access
curl -I https://demo.jardoole.xyz
```

## Cleanup

```bash
helm uninstall demo-app -n applications --kubeconfig=/etc/rancher/k3s/k3s.yaml

# Remove PVC if needed
kubectl delete pvc -n applications -l app.kubernetes.io/instance=demo-app --kubeconfig=/etc/rancher/k3s/k3s.yaml
```

## Validation Checklist

- [ ] helm-lint passes
- [ ] Deployment succeeds
- [ ] Pod is running
- [ ] PVC is bound and using Longhorn
- [ ] Certificate is ready
- [ ] HTTPS access works
- [ ] Persistent data survives pod restart
