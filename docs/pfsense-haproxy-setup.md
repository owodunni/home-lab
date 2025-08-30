# pfSense HAProxy Setup for K3s Cluster

This guide configures pfSense HAProxy to provide SSL termination, load balancing, and high availability for the K3s cluster, eliminating the need for MetalLB, NGINX Ingress, and cert-manager within the cluster.

## Architecture Overview

```
Internet → pfSense HAProxy → K3s Nodes (HTTP)
           ├── SSL Termination (Let's Encrypt)
           ├── Load Balancing (All 3 nodes)
           ├── Health Checks (/healthz)
           └── Certificate Management (ACME)
```

**Benefits:**
- **High Availability**: Automatic failover between K3s nodes
- **Simplified K3s**: Re-enables Traefik and ServiceLB for internal routing
- **Centralized SSL**: All certificates managed at pfSense level
- **Performance**: SSL termination at network edge

## Prerequisites

- pfSense firewall with admin access
- K3s cluster running on pi-cm5-1, pi-cm5-2, pi-cm5-3
- Domain name with Cloudflare DNS management
- Cloudflare API token for DNS-01 challenges

## Phase 1: Install Required pfSense Packages

### 1.1 Install HAProxy Package

1. Navigate to **System → Package Manager → Available Packages**
2. Search for "haproxy" and click **Install**
3. Wait for installation to complete

### 1.2 Install ACME Package

1. In **Available Packages**, search for "acme" and click **Install**
2. This provides Let's Encrypt certificate automation

## Phase 2: Configure ACME (Let's Encrypt)

### 2.1 Create ACME Account

1. Navigate to **Services → Acme Certificates → Account Keys**
2. Click **Add** to create new account:
   - **Name**: `letsencrypt-production`
   - **Description**: `Let's Encrypt Production Account`
   - **Email**: Your email address
   - **ACME Server**: `Let's Encrypt Production ACME v2`
3. Click **Create new account key** and **Save**

### 2.2 Configure Cloudflare Integration

1. Go to **Services → Acme Certificates → Account Keys**
2. Edit your account and configure DNS validation:
   - **Method**: `DNS-Cloudflare`
   - **Cloudflare API Token**: Your Cloudflare API token
3. Save configuration

### 2.3 Create Wildcard Certificate

1. Navigate to **Services → Acme Certificates → Certificates**
2. Click **Add** to create certificate:
   - **Name**: `jardoole-wildcard`
   - **Description**: `Wildcard certificate for *.jardoole.xyz`
   - **Status**: `Enabled`
   - **Acme Account**: Select your account
   - **Private Key**: `384-bit ECDSA` (highest security)
   - **Domain SAN List**:
     - **Mode**: `Enabled`
     - **Domainname**: `*.jardoole.xyz`
     - **Method**: `DNS-Cloudflare`
3. Click **Save** and **Issue/Renew**

**Note**: Certificate will auto-renew every 90 days via cron job.

## Phase 3: Configure HAProxy Load Balancer

### 3.1 HAProxy Global Settings

1. Navigate to **Services → HAProxy → Settings**
2. Configure global settings:
   - **Enable HAProxy**: ✓ Checked
   - **Maximum Connections**: `1000`
   - **Number of Threads**: `2` (optimal for Pi hardware)
   - **Stats Enabled**: ✓ Checked
   - **Stats URI**: `/haproxy-stats`
   - **Stats Admin**: ✓ Checked
3. Save settings

### 3.2 Create K3s Backend Pool

1. Go to **Services → HAProxy → Backend**
2. Click **Add** to create backend:
   - **Name**: `k3s-cluster`
   - **Description**: `K3s Cluster Nodes`
   - **Mode**: `HTTP`
   - **Balance**: `roundrobin`
   - **Server List**:
     ```
     Name: pi-cm5-1, Address: 192.168.0.X, Port: 80, Weight: 1
     Name: pi-cm5-2, Address: 192.168.0.Y, Port: 80, Weight: 1
     Name: pi-cm5-3, Address: 192.168.0.Z, Port: 80, Weight: 1
     ```
     Replace X, Y, Z with actual IP addresses

### 3.3 Configure Health Checks

1. In the same backend configuration:
   - **Health Check Method**: `HTTP`
   - **Health Check URI**: `/healthz`
   - **Check Inter**: `5s` (check every 5 seconds)
   - **Check Fall**: `3` (3 failures = down)
   - **Check Rise**: `2` (2 successes = up)

**Note**: Traefik exposes `/healthz` endpoint for health monitoring.

### 3.4 Create MinIO Backend Pool

1. Create second backend for MinIO:
   - **Name**: `minio-nas`
   - **Description**: `MinIO NAS Service`
   - **Mode**: `HTTP`
   - **Server List**:
     ```
     Name: pi-cm5-4, Address: pi-cm5-4.local, Port: 9001, Weight: 1
     ```

## Phase 4: Configure HAProxy Frontends

### 4.1 HTTPS Frontend (Port 443)

1. Navigate to **Services → HAProxy → Frontend**
2. Click **Add** to create frontend:
   - **Name**: `https-frontend`
   - **Description**: `HTTPS Traffic Entry Point`
   - **Status**: `Active`
   - **External Address**: `WAN Interface`
   - **Port**: `443`
   - **Type**: `HTTP/HTTPS (SSL Offload)`
   - **SSL Offloading**: ✓ Checked
   - **Certificate**: Select `jardoole-wildcard`

### 4.2 Configure Host-Based Routing

1. In **Access Control Lists**, add routing rules:
   ```
   Name: minio_host, Expression: Host matches, Value: minio.jardoole.xyz
   Name: api_host, Expression: Host matches, Value: api.jardoole.xyz
   ```

2. In **Actions**, add backend routing:
   ```
   Condition: minio_host, Action: Use Backend, Backend: minio-nas
   Condition: api_host, Action: Use Backend, Backend: minio-nas
   Default: Use Backend k3s-cluster
   ```

### 4.3 HTTP Redirect Frontend (Port 80)

1. Create second frontend for HTTP→HTTPS redirect:
   - **Name**: `http-redirect`
   - **Description**: `HTTP to HTTPS Redirect`
   - **Status**: `Active`
   - **External Address**: `WAN Interface`
   - **Port**: `80`
   - **Type**: `HTTP`

2. Add redirect action:
   - **Action**: `http-request redirect`
   - **Rule**: `scheme https code 301`

## Phase 5: Configure Firewall Rules

### 5.1 WAN Rules

1. Navigate to **Firewall → Rules → WAN**
2. Add rules for external access:
   ```
   Protocol: TCP, Source: Any, Destination: WAN Address, Port: 443, Description: HTTPS to HAProxy
   Protocol: TCP, Source: Any, Destination: WAN Address, Port: 80, Description: HTTP to HAProxy
   ```

### 5.2 LAN Rules (if needed)

Ensure LAN→K3s nodes communication is allowed (usually default allow rule covers this).

## Phase 6: Testing and Verification

### 6.1 HAProxy Status

1. Navigate to **Services → HAProxy → Stats**
2. Verify all K3s backend servers show as "UP"
3. Check connection statistics

### 6.2 SSL Certificate Verification

```bash
# Test SSL certificate
openssl s_client -connect jardoole.xyz:443 -servername minio.jardoole.xyz

# Check certificate expiration
curl -I https://minio.jardoole.xyz
```

### 6.3 Load Balancing Test

```bash
# Test multiple requests get distributed
for i in {1..10}; do
  curl -H "Host: test.jardoole.xyz" https://jardoole.xyz/
done
```

### 6.4 Health Check Verification

1. Stop one K3s node: `sudo systemctl stop k3s`
2. Check HAProxy stats - node should show as "DOWN"
3. Verify traffic routes to healthy nodes
4. Restart node and verify it returns to "UP"

## Phase 7: MinIO Integration

### 7.1 Update MinIO Configuration

Since pfSense handles SSL termination, MinIO can run HTTP internally:

```bash
# On pi-cm5-4.local, verify MinIO is accessible
curl http://pi-cm5-4.local:9001/
```

### 7.2 DNS Configuration

Configure Cloudflare DNS records:
```
minio.jardoole.xyz → A → Your external IP
api.jardoole.xyz → A → Your external IP
*.jardoole.xyz → A → Your external IP (for future services)
```

## Monitoring and Maintenance

### Certificate Renewal

- ACME certificates auto-renew every 60-90 days
- Monitor via **Services → Acme Certificates → Certificate**
- Check logs at **Status → System Logs → System**

### HAProxy Health Monitoring

- Access stats at `https://jardoole.xyz/haproxy-stats`
- Monitor backend server health
- Review traffic statistics

### Log Analysis

```bash
# View HAProxy logs
tail -f /var/log/haproxy.log

# Check for SSL/certificate issues
grep -i ssl /var/log/system.log
```

## Troubleshooting

### Common Issues

1. **Backend servers showing DOWN**
   - Verify K3s nodes are running
   - Check health check URI `/healthz` is accessible
   - Review firewall rules between pfSense and K3s nodes

2. **SSL certificate issues**
   - Verify Cloudflare API token has correct permissions
   - Check DNS propagation for ACME challenges
   - Review ACME certificate logs

3. **Load balancing not working**
   - Check HAProxy frontend/backend configuration
   - Verify host-based routing ACLs
   - Review connection statistics in HAProxy stats

### Log Locations

- HAProxy: `/var/log/haproxy.log`
- ACME: **Status → System Logs → System**
- System: `/var/log/system.log`

## Security Considerations

- Use strong SSL ciphers (configured automatically with 384-bit ECDSA)
- Implement rate limiting if needed
- Monitor failed authentication attempts
- Keep pfSense and packages updated
- Use firewall rules to restrict access to admin interfaces

## Next Steps

After HAProxy is configured:

1. Deploy applications to K3s cluster
2. Create Traefik IngressRoute resources for internal routing
3. Access services via `https://service.jardoole.xyz`
4. Monitor performance and adjust load balancing algorithm if needed

This setup provides enterprise-grade load balancing and SSL management while keeping the K3s cluster simple and focused on container orchestration.
