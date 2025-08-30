# Testing Parallel Execution

## How to Verify MinIO and K3s Install in Parallel

### 1. Terminal Monitoring Setup

**Terminal 1 - Main Deployment:**
```bash
make site
```

**Terminal 2 - MinIO Progress:**
```bash
ssh pi-cm5-4.local "journalctl -u minio -f"
```

**Terminal 3 - K3s Progress:**
```bash
ssh pi-cm5-1 "journalctl -u k3s -f"
```

**Terminal 4 - System Resources:**
```bash
# Monitor all Pi nodes simultaneously
watch -n 2 'echo "=== pi-cm5-1 ===" && ssh pi-cm5-1 "top -bn1 | head -5" && echo "=== pi-cm5-4 ===" && ssh pi-cm5-4.local "top -bn1 | head -5"'
```

### 2. What to Look For

**Parallel Execution Indicators:**
- ✅ Both MinIO and K3s logs should show activity simultaneously
- ✅ Deployment should show "Job ID" messages for both services
- ✅ CPU/memory usage on pi-cm5-1,2,3 AND pi-cm5-4 at the same time
- ✅ Total deployment time significantly less than sequential

**Sequential Execution (OLD behavior):**
- ❌ Only MinIO logs active first, then K3s logs later
- ❌ Only pi-cm5-4 busy first, then pi-cm5-1,2,3 busy later

### 3. Timing Comparison

**Expected Timing (Parallel):**
- Total: ~8-12 minutes
- Both services start within seconds of each other
- Finish around the same time

**Old Timing (Sequential):**
- Total: ~12-18 minutes
- MinIO finishes completely before K3s starts
- Clear gaps in activity between services

### 4. Deployment Output

Look for these messages in the main deployment:

```
🚀 Parallel Infrastructure Deployment Started
==========================================
Start Time: 2025-08-28T20:30:00.123Z
MinIO Installation: Job ID 12345 (targeting nas hosts)
K3s Installation: Job ID 67890 (targeting cluster hosts)

Both services are installing simultaneously on different Pi nodes.
This typically reduces deployment time by 40% compared to sequential execution.
```

Then later:

```
✅ Parallel Infrastructure Deployment Complete
============================================
Start Time: 2025-08-28T20:30:00.123Z
End Time: 2025-08-28T20:38:45.678Z
Total Duration: 8m 45s

MinIO Status: SUCCESS ✓
K3s Status: SUCCESS ✓

Both services are now ready for Kubernetes applications deployment.
🎯 Parallel execution saved time by running MinIO and K3s simultaneously!
```

### 5. Troubleshooting

If you don't see parallel execution:
1. Check that async jobs were created successfully
2. Verify different host groups are being targeted
3. Ensure no dependencies are blocking parallel execution
4. Check for resource constraints on Pi nodes
