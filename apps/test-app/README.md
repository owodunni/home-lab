# Test App

Simple nginx deployment for testing the Helm app deployment workflow.

## Purpose

This app demonstrates the standard app deployment pattern:
- Chart metadata in `Chart.yml`
- Helm values in `values.yml`
- Deployment playbook in `app.yml`

## Usage

Deploy:
```bash
make app-deploy APP=test-app
```

Check status:
```bash
make app-status APP=test-app
```

Uninstall:
```bash
helm uninstall test-app -n applications
```

## Configuration

- **Chart**: bitnami/nginx
- **Namespace**: applications
- **Replicas**: 1
- **Service**: ClusterIP (internal only, no ingress)
- **Resources**: Medium profile (100m CPU, 128Mi RAM)

## Testing Checklist

- [ ] Chart validation passes (`make helm-lint`)
- [ ] Deployment succeeds (`make app-deploy APP=test-app`)
- [ ] Pod is running (`kubectl get pods -n applications`)
- [ ] Service is created (`kubectl get svc -n applications`)
- [ ] Resource limits are applied
- [ ] Uninstall is clean

## Notes

This is a test app - **not for production use**. It validates the deployment workflow without affecting cluster services.
