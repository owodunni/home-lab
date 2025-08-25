# MinIO S3 Service Usage Guide

## Overview

MinIO is deployed on pi-cm5-4 with 2TB XFS storage providing S3-compatible object storage for Longhorn backups and general use.

## Access Information

- **Console URL:** http://pi-cm5-4.local:9001
- **API URL:** http://pi-cm5-4.local:9000
- **Root User:** miniosuperuser
- **Root Password:** Set via `vault_minio_root_password` (defaults to 'changeme123')

## Buckets and Service Accounts

### Buckets
- **longhorn-backups**: Private bucket with object locking for Kubernetes backups
- **cluster-logs**: Private bucket for log aggregation
- **media-storage**: Read-write bucket for general file storage

### Service Accounts
- **longhorn-backup**: Read-write access to longhorn-backups bucket
- **readonly-user**: Read-only access to media-storage bucket

## Web Console Access

```bash
# Access via browser
open http://pi-cm5-4.local:9001
# Login: miniosuperuser / [vault_minio_root_password]
```

## MinIO Client (mc) Setup

```bash
# Install MinIO client
brew install minio/stable/mc  # macOS
# or: wget https://dl.min.io/client/mc/release/linux-amd64/mc

# Configure alias
mc alias set homelab http://pi-cm5-4.local:9000 miniosuperuser [password]

# Test connection
mc admin info homelab
```

## Basic S3 Operations

### File Operations
```bash
# List buckets
mc ls homelab

# Upload file to bucket
mc cp /path/to/file.txt homelab/media-storage/

# Download file
mc cp homelab/media-storage/file.txt ./downloaded-file.txt

# Remove file
mc rm homelab/media-storage/file.txt

# Sync directory (backup local folder)
mc mirror /local/directory homelab/media-storage/backup/

# List objects in bucket
mc ls homelab/longhorn-backups --recursive

# Show bucket info and usage
mc du homelab/media-storage
```

### Bucket Management
```bash
# Create new bucket
mc mb homelab/new-bucket

# Set bucket policy (public read)
mc anonymous set public homelab/media-storage

# Set bucket policy (private)
mc anonymous set none homelab/media-storage

# Show bucket events
mc events list homelab/media-storage
```

## Python boto3 Integration

### Basic Setup
```python
import boto3
from botocore.client import Config

# Configure S3 client for MinIO
s3_client = boto3.client(
    's3',
    endpoint_url='http://pi-cm5-4.local:9000',
    aws_access_key_id='miniosuperuser',  # or service account
    aws_secret_access_key='[password]',
    config=Config(signature_version='s3v4'),
    region_name='us-east-1'  # MinIO default
)

# Test connection
response = s3_client.list_buckets()
print([bucket['Name'] for bucket in response['Buckets']])
```

### File Operations
```python
# Upload file
s3_client.upload_file('local-file.txt', 'media-storage', 'remote-file.txt')

# Download file
s3_client.download_file('media-storage', 'remote-file.txt', 'downloaded-file.txt')

# Upload with metadata
s3_client.put_object(
    Bucket='media-storage',
    Key='data/sample.json',
    Body=json.dumps({'key': 'value'}),
    ContentType='application/json',
    Metadata={'author': 'homelab', 'version': '1.0'}
)

# List objects
response = s3_client.list_objects_v2(Bucket='media-storage', Prefix='data/')
for obj in response.get('Contents', []):
    print(f"{obj['Key']} - {obj['Size']} bytes")
```

### Service Account Usage
```python
# Use longhorn-backup service account
longhorn_client = boto3.client(
    's3',
    endpoint_url='http://pi-cm5-4.local:9000',
    aws_access_key_id='longhorn-backup',
    aws_secret_access_key='[longhorn_backup_password]',
    config=Config(signature_version='s3v4'),
    region_name='us-east-1'
)

# Upload backup file (only works with longhorn-backups bucket)
longhorn_client.upload_file('backup.tar.gz', 'longhorn-backups', 'backups/2025-01-01/backup.tar.gz')
```

## Monitoring and Maintenance

### Health Checks
```bash
# Check MinIO service status
ansible nas -m systemd -a "name=minio state=started" -b

# View MinIO logs
ansible nas -m shell -a "journalctl -u minio --since '1 hour ago'" -b

# Check storage usage
mc admin info homelab

# Show server info and uptime
mc admin info homelab --json | jq .info
```

### Performance Monitoring
```bash
# Monitor real-time stats
mc admin top homelab

# Show network and drive stats
mc admin speedtest homelab

# Check heal status (data integrity)
mc admin heal homelab --verbose
```

### User and Policy Management
```bash
# List users
mc admin user list homelab

# Add new user
mc admin user add homelab newuser strongpassword

# Create policy file (policy.json)
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject"],
      "Resource": ["arn:aws:s3:::media-storage/*"]
    }
  ]
}

# Add policy
mc admin policy create homelab readonly-policy policy.json

# Assign policy to user
mc admin policy attach homelab readonly-policy --user newuser
```

## Integration Examples

### Longhorn Backup Configuration

When setting up Longhorn in Phase 7, use this configuration:

```yaml
apiVersion: longhorn.io/v1beta1
kind: Setting
metadata:
  name: backup-target
spec:
  value: s3://longhorn-backups@us-east-1/

---
apiVersion: longhorn.io/v1beta1
kind: Setting
metadata:
  name: backup-target-credential-secret
spec:
  value: minio-credentials

---
# Kubernetes secret for MinIO access
apiVersion: v1
kind: Secret
metadata:
  name: minio-credentials
  namespace: longhorn-system
data:
  AWS_ACCESS_KEY_ID: [base64_encoded_longhorn_backup_user]
  AWS_SECRET_ACCESS_KEY: [base64_encoded_longhorn_backup_password]
  AWS_ENDPOINTS: aHR0cDovL3BpLWNtNS00LmxvY2FsOjkwMDA=  # http://pi-cm5-4.local:9000
```

### Backup Scripts

```bash
#!/bin/bash
# Daily backup script example
DATE=$(date +%Y-%m-%d)
BACKUP_DIR="/tmp/daily-backup-$DATE"

# Create backup
mkdir -p "$BACKUP_DIR"
tar -czf "$BACKUP_DIR/configs.tar.gz" /etc/ansible/

# Upload to MinIO
mc cp "$BACKUP_DIR/configs.tar.gz" homelab/cluster-logs/backups/$DATE/

# Cleanup
rm -rf "$BACKUP_DIR"
echo "Backup completed: configs.tar.gz uploaded to MinIO"
```

## Security Considerations

### Access Control
- Use service accounts with minimal required permissions
- Regularly rotate passwords and access keys
- Enable object locking for critical buckets (longhorn-backups)
- Monitor access logs for unusual activity

### Planned Security Enhancements
- **Phase 5b (SSL)**: HTTPS access with Let's Encrypt certificates
- **Phase 5c (Encryption)**: Server-side encryption for sensitive buckets
- **Phase 5d (Tailscale)**: Secure remote access without port forwarding

## Troubleshooting

### Common Issues
```bash
# Service not responding
sudo systemctl status minio
sudo systemctl restart minio

# Check disk space
df -h /mnt/minio-drive1 /mnt/minio-drive2

# Verify MinIO configuration
sudo cat /etc/minio/minio.conf

# Test network connectivity
curl -I http://pi-cm5-4.local:9000
telnet pi-cm5-4.local 9000
```

### Log Analysis
```bash
# MinIO application logs
sudo journalctl -u minio -f

# Check for errors in last hour
sudo journalctl -u minio --since "1 hour ago" | grep -i error

# Audit logs (if enabled)
mc admin logs homelab --type audit
```

## Future Enhancements

After Phase 5 security enhancements are complete:
- HTTPS access via custom domain names
- Server-side encryption for longhorn-backups and cluster-logs
- Secure Tailscale-only access for remote management
- Automated backup verification and integrity checks
- Integration with monitoring stack for alerting
