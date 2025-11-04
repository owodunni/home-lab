# cert-manager

Automated SSL certificate management for Kubernetes with Let's Encrypt support.

## Overview

cert-manager automates the issuance and renewal of TLS certificates:
- **Let's Encrypt integration**: Free SSL certificates via ACME protocol
- **DNS-01 challenge**: Wildcard certificate support via Cloudflare DNS
- **Automatic renewal**: Certificates renewed before expiration
- **CRD-based**: Declarative certificate management via Kubernetes resources

## Dependencies

- **Traefik**: Ingress controller that uses issued certificates
- **Cloudflare DNS**: For DNS-01 challenge validation (configured in orchestration)

## Configuration

### CRD Installation
- **installCRDs**: true (Helm manages CRDs for easier upgrades)

### DNS-01 Challenge
- **Nameservers**: CoreDNS (10.43.0.10) forwarding to external DNS
- **Challenge type**: DNS-01 (supports wildcard certificates)
- **DNS provider**: Cloudflare (API token configured in orchestration playbook)

### Resource Limits
All components configured for Pi CM5 ARM64 nodes:
- **Controller**: 10m CPU request, 100m limit, 64Mi-128Mi memory
- **Webhook**: 10m CPU request, 100m limit, 64Mi-128Mi memory
- **CA injector**: 10m CPU request, 100m limit, 64Mi-128Mi memory

### Components
1. **Controller**: Main cert-manager logic, handles certificate lifecycle
2. **Webhook**: Validates CertificateRequest and Issuer resources
3. **CA injector**: Injects CA data into ValidatingWebhookConfiguration and APIService

## Deployment

Deploy via orchestration playbook (recommended for cluster setup):
```bash
make k3s-core
```

Or deploy standalone (without ClusterIssuers):
```bash
make app-deploy APP=cert-manager
```

**Note**: ClusterIssuers require Cloudflare API token and are created by orchestration playbook.

## Access

cert-manager has no UI. Interact via kubectl:
```bash
# View cluster issuers
kubectl get clusterissuer

# View certificates
kubectl get certificate --all-namespaces

# View certificate requests
kubectl get certificaterequest --all-namespaces

# Check certificate details
kubectl describe certificate <name> -n <namespace>
```

## Certificate Usage

Request a certificate by creating an Ingress with annotations:
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: my-app
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
spec:
  ingressClassName: traefik
  tls:
    - hosts:
        - app.jardoole.xyz
      secretName: app-tls-secret
  rules:
    - host: app.jardoole.xyz
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: my-app
                port:
                  number: 80
```

cert-manager automatically:
1. Creates Certificate resource from Ingress
2. Initiates DNS-01 challenge via Cloudflare
3. Obtains certificate from Let's Encrypt
4. Stores certificate in specified Secret
5. Renews certificate before expiration

## Maintenance

### Upgrade cert-manager
1. Check [upgrade notes](https://cert-manager.io/docs/installation/upgrading/)
2. Update `chart_version` in Chart.yml
3. Redeploy: `make app-deploy APP=cert-manager`

### Monitor Certificate Status
Check certificate ready status:
```bash
kubectl get certificate --all-namespaces
```

Check certificate expiration:
```bash
kubectl get certificate -o custom-columns=NAME:.metadata.name,READY:.status.conditions[0].status,EXPIRES:.status.notAfter --all-namespaces
```

### Troubleshoot Certificate Issues

**Certificate not issuing:**
```bash
# Check certificate status
kubectl describe certificate <name> -n <namespace>

# Check certificate request
kubectl get certificaterequest -n <namespace>
kubectl describe certificaterequest <name> -n <namespace>

# Check cert-manager logs
kubectl logs -n cert-manager -l app=cert-manager
```

**DNS-01 challenge failing:**
```bash
# Verify Cloudflare API token secret exists
kubectl get secret cloudflare-api-token -n cert-manager

# Check ClusterIssuer status
kubectl describe clusterissuer letsencrypt-prod

# Check cert-manager can reach Cloudflare API
kubectl logs -n cert-manager -l app=cert-manager | grep cloudflare
```

**Webhook issues:**
```bash
# Verify webhook is running
kubectl get pods -n cert-manager -l app=cert-manager-webhook

# Check webhook endpoints
kubectl get endpoints cert-manager-webhook -n cert-manager

# Verify webhook service DNS
kubectl run -it --rm debug --image=busybox --restart=Never -- nslookup cert-manager-webhook.cert-manager.svc.cluster.local
```

## ClusterIssuers

Configured by orchestration playbook:
- **letsencrypt-staging**: Let's Encrypt staging (for testing)
- **letsencrypt-prod**: Let's Encrypt production (for real certificates)

Both use DNS-01 challenge with Cloudflare for jardoole.xyz domain.

## References

- [cert-manager Documentation](https://cert-manager.io/docs/)
- [Let's Encrypt](https://letsencrypt.org/)
- [DNS-01 Challenge](https://cert-manager.io/docs/configuration/acme/dns01/)
- [Cloudflare DNS](https://cert-manager.io/docs/configuration/acme/dns01/cloudflare/)
