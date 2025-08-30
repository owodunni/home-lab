# pfSense Integration Architecture

This document describes the architectural design and rationale for integrating pfSense with the K3s home lab cluster, providing enterprise-grade load balancing, SSL termination, and high availability while dramatically simplifying the Kubernetes cluster configuration.

## Overview

The pfSense-centric architecture moves complexity from the Kubernetes cluster to the network edge, leveraging pfSense's enterprise-grade capabilities to provide load balancing, SSL termination, and certificate management. This approach eliminates the need for MetalLB, NGINX Ingress Controller, and cert-manager within the cluster.

## Architectural Comparison

### Before: Complex K3s-Centric Approach
```
Internet → Router → MetalLB IP → NGINX Ingress → K3s Services
                     (SPOF)         ↓
                                SSL Term + cert-manager
                                    ↓
                             Complex certificate coordination
```

**Problems:**
- Single point of failure (MetalLB IP)
- Complex certificate management across multiple components
- Resource overhead on Pi nodes
- Traefik and ServiceLB disabled, losing K3s simplicity

### After: Simplified pfSense-Centric Approach
```
Internet → pfSense HAProxy → K3s Nodes (any/all)
           ├── SSL Termination (ACME)
           ├── Load Balancing (Round-robin)
           ├── Health Checks (/healthz)
           ├── Certificate Management
           └── Host-based Routing
```

**Benefits:**
- True high availability across all nodes
- Simplified K3s cluster (Traefik + ServiceLB enabled)
- Centralized certificate management
- Enterprise-grade load balancing at network edge

## Component Architecture

### pfSense Router Layer

#### HAProxy Load Balancer
- **Function**: Entry point for all external traffic
- **Features**:
  - SSL termination with Let's Encrypt certificates
  - Round-robin load balancing across K3s nodes
  - HTTP health checks to `/healthz` endpoint
  - Host-based routing (minio.jardoole.xyz, api.jardoole.xyz)
  - Automatic failover on node failure
- **High Availability**: Distributes traffic across all 3 K3s nodes
- **Monitoring**: Built-in stats dashboard and logging

#### ACME Client
- **Function**: Automated certificate lifecycle management
- **Features**:
  - Cloudflare DNS-01 validation
  - Wildcard certificate generation (`*.jardoole.xyz`)
  - Automatic renewal (90-day cycle)
  - Integration with HAProxy for certificate deployment
- **Security**: Certificates managed centrally at network perimeter

### K3s Cluster Layer

#### Simplified Configuration
- **Traefik**: Re-enabled for internal service discovery and routing
- **ServiceLB**: Re-enabled for internal load balancing
- **Flannel**: VXLAN networking for pod-to-pod communication
- **Embedded etcd**: High availability control plane across 3 nodes

#### Service Architecture
```yaml
# Internal services use ClusterIP
apiVersion: v1
kind: Service
metadata:
  name: my-app
spec:
  type: ClusterIP  # pfSense HAProxy handles external access
  selector:
    app: my-app
  ports:
  - port: 80

---
# Traefik IngressRoute for internal routing
apiVersion: traefik.containo.us/v1alpha1
kind: IngressRoute
metadata:
  name: my-app
spec:
  entryPoints:
  - web
  routes:
  - match: Host(`my-app.local`)
    kind: Rule
    services:
    - name: my-app
      port: 80
```

### MinIO NAS Layer

#### Simplified Configuration
- **HTTP Backend**: MinIO runs on HTTP internally (port 9001)
- **SSL Termination**: Handled by pfSense HAProxy
- **External Access**: https://minio.jardoole.xyz → pfSense → pi-cm5-4:9001
- **API Access**: https://api.jardoole.xyz → pfSense → pi-cm5-4:9000

## Traffic Flow Patterns

### External HTTPS Request Flow
1. **Client Request**: `curl https://minio.jardoole.xyz/dashboard`
2. **DNS Resolution**: Cloudflare DNS → External IP
3. **pfSense HAProxy**:
   - Terminates SSL using wildcard certificate
   - Matches Host header `minio.jardoole.xyz`
   - Routes to MinIO backend (pi-cm5-4:9001)
4. **MinIO Response**: HTTP response via pfSense
5. **Client Response**: HTTPS response with pfSense certificate

### Internal K3s Service Flow
1. **Client Request**: `curl https://app.jardoole.xyz/api`
2. **pfSense HAProxy**:
   - Terminates SSL
   - Default routing to K3s cluster backend
   - Round-robin to healthy K3s node (pi-cm5-1,2,3:80)
3. **K3s Traefik**:
   - Receives HTTP request on port 80
   - Routes based on Host header to appropriate service
   - Internal ClusterIP service handling
4. **Application Response**: Pod → Traefik → pfSense → Client

### Health Check Flow
1. **HAProxy Health Check**: Every 5 seconds to each K3s node
2. **Request**: `GET http://pi-cm5-X:80/healthz`
3. **Traefik Response**: Traefik exposes `/healthz` endpoint
4. **Status Evaluation**:
   - 200 OK → Node marked UP
   - Timeout/Error → Node marked DOWN after 3 failures
   - Auto-recovery when node returns healthy

## High Availability Design

### Node Failure Scenarios

#### K3s Node Failure
```
Before: pi-cm5-1 (UP), pi-cm5-2 (UP), pi-cm5-3 (UP)
Failure: pi-cm5-2 goes down
After:  pi-cm5-1 (UP), pi-cm5-2 (DOWN), pi-cm5-3 (UP)

HAProxy Response:
- Health checks fail for pi-cm5-2
- Traffic redistributed to pi-cm5-1 and pi-cm5-3
- Users experience no service interruption
- Automatic recovery when pi-cm5-2 returns
```

#### pfSense Failure
- **Impact**: Complete external access loss
- **Recovery**: pfSense config backup and restore
- **Mitigation**: pfSense HA configuration (future enhancement)

### Scalability Patterns

#### Adding New Services
1. Deploy service to K3s with ClusterIP
2. Create Traefik IngressRoute for internal routing
3. Add DNS record pointing to external IP
4. pfSense HAProxy automatically routes to K3s cluster
5. Service inherits SSL certificate and load balancing

#### Adding New K3s Nodes
1. Join node to K3s cluster
2. Add node to HAProxy backend pool
3. Configure health checks
4. Automatic load balancing across all nodes

## Security Architecture

### Network Security Boundaries

#### Perimeter Security (pfSense)
- **Firewall Rules**: Only ports 80/443 exposed externally
- **SSL Termination**: All external traffic encrypted
- **Rate Limiting**: Available via HAProxy configuration
- **DDoS Protection**: pfSense firewall capabilities
- **Certificate Management**: Centralized at network edge

#### Internal Network Security
- **Unencrypted Internal Traffic**: HTTP between pfSense and K3s (performance)
- **Network Segmentation**: K3s cluster on isolated subnet
- **Pod Security**: Kubernetes RBAC and network policies
- **Service Mesh**: Optional (Istio/Linkerd) for internal encryption

### Certificate Management Security

#### Let's Encrypt Integration
```
Certificate Lifecycle:
1. ACME client requests certificate from Let's Encrypt
2. DNS-01 challenge via Cloudflare API
3. Certificate stored in pfSense certificate store
4. HAProxy configured to use certificate
5. Automatic renewal 30 days before expiration
6. Zero-downtime certificate updates
```

#### API Token Security
- **Cloudflare API Token**: Stored in Ansible Vault
- **Minimal Permissions**: DNS:Edit for specific zone only
- **Rotation Policy**: Regular token rotation recommended

## Monitoring and Observability

### HAProxy Metrics
- **Built-in Stats**: Available at `/haproxy-stats`
- **Metrics Available**:
  - Backend server health status
  - Request rate and response times
  - Connection statistics
  - SSL certificate expiration

### Health Check Monitoring
```bash
# View HAProxy status
curl -s http://pfsense-ip/haproxy-stats

# Check individual backend health
ssh pfsense "echo 'show stat' | nc -U /var/run/haproxy.sock"

# Monitor certificate expiration
ssh pfsense "certbot certificates"
```

### Integration with Monitoring Stack
- **Prometheus**: Can scrape HAProxy stats endpoint
- **Grafana**: Dashboards for load balancer metrics
- **Alertmanager**: Alerts for backend failures or certificate expiration

## Deployment Strategy

### Phase 1: pfSense Configuration
1. Install HAProxy and ACME packages
2. Configure certificate management
3. Set up backend pools and health checks
4. Configure frontend routing rules

### Phase 2: K3s Reconfiguration
1. Update K3s configuration to re-enable Traefik and ServiceLB
2. Apply configuration via Ansible playbook
3. Verify internal service routing works correctly

### Phase 3: Service Migration
1. Update DNS records to point to external IP
2. Test external access via pfSense HAProxy
3. Remove MetalLB/NGINX/cert-manager if previously configured
4. Update documentation and runbooks

### Phase 4: Optimization
1. Fine-tune HAProxy settings for performance
2. Configure monitoring and alerting
3. Set up backup and disaster recovery procedures

## Maintenance and Operations

### Regular Maintenance Tasks
- **Certificate Renewal**: Automatic, monitor for failures
- **HAProxy Updates**: Regular package updates via pfSense
- **Health Check Monitoring**: Weekly review of backend status
- **Performance Monitoring**: Monthly review of load balancing metrics

### Troubleshooting Guide
- **Backend Server Down**: Check K3s node health and Traefik status
- **Certificate Issues**: Review ACME logs and Cloudflare API access
- **Load Balancing Problems**: Check HAProxy configuration and stats
- **Performance Issues**: Monitor connection statistics and backend response times

### Backup and Recovery
- **pfSense Config**: Regular backup of complete pfSense configuration
- **Certificate Backup**: Automatic via pfSense backup process
- **K3s Cluster**: Existing backup procedures remain unchanged
- **Documentation**: Keep architecture documentation updated

## Future Enhancements

### pfSense High Availability
- **CARP Configuration**: Active/passive pfSense setup
- **Shared Storage**: Certificate and configuration synchronization
- **Health Monitoring**: External monitoring of pfSense availability

### Advanced Load Balancing
- **Weighted Load Balancing**: Based on node capacity
- **Geographic Load Balancing**: For multi-site deployments
- **Application-Level Load Balancing**: Layer 7 routing enhancements

### Security Enhancements
- **Web Application Firewall**: ModSecurity integration
- **Rate Limiting**: Per-client connection limits
- **IP Reputation**: Automatic blocking of malicious IPs
- **Certificate Pinning**: Enhanced certificate validation

This architecture provides a robust, scalable, and maintainable foundation for the home lab infrastructure while leveraging the strengths of both pfSense and Kubernetes technologies.
