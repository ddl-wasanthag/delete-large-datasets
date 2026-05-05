# efs_bulk_delete.sh

Production-safe parallel file deletion for large EFS mounts. Empties a directory while preserving the directory itself.

---

## What It Does

- **Preserves the root directory** — only its contents are deleted
- **Parallel workers** — configurable thread pool for high throughput
- **Token-bucket rate limiter** — caps EFS metadata API calls per second across all workers
- **CLI flags only** — environment variables are never used, no risk of env conflicts (e.g. a pre-existing `DRY_RUN=false` in your shell will not interfere)
- **Protected path guard** — refuses to run against system or protected mount paths
- **Two-phase cleanup** — files first, then empty subdirectories bottom-up

---

## Quick Start

```bash
# 1. Dry run first -- always do this before a real delete
./efs_bulk_delete.sh -n /opt/shared/filecache/dataset1

# 2. Full speed delete (prompts for confirmation)
./efs_bulk_delete.sh /opt/shared/filecache/dataset1

# 3. Rate-limited -- recommended when other workloads share the EFS
./efs_bulk_delete.sh -r 200 -w 16 /opt/shared/filecache/dataset1

# 4. Skip confirmation prompt (for tmux / automation)
./efs_bulk_delete.sh -y -r 200 -w 16 /opt/shared/filecache/dataset1

# 5. Maintenance window -- push as fast as possible
./efs_bulk_delete.sh -y -w 64 /opt/shared/filecache/dataset1
```

---

## All Flags

| Flag | Default | Description |
|------|---------|-------------|
| `-w <N>` | `32` | Number of parallel workers. Increase for speed; decrease to reduce EFS pressure. |
| `-b <N>` | `500` | Files per xargs batch (used when GNU parallel is not available). |
| `-r <N>` | `0` | Max deletions per second across all workers. `0` = unlimited. |
| `-n` | off | Dry run — preview only, no files deleted. |
| `-y` | off | Skip the interactive `YES` confirmation prompt. |
| `-l <path>` | auto | Log file path. Defaults to `/tmp/efs_delete_<timestamp>.log`. |
| `-h` | | Print help and exit. |

> **Note:** All configuration is via CLI flags. Environment variables are intentionally ignored.

---

## Rate Limiting the EFS Metadata API

### Why it matters

Every file deletion is a metadata API call to EFS. With many parallel workers running unthrottled, the script can fire thousands of deletes per second. This can:

- Exhaust your EFS burst credit pool
- Cause latency spikes for other applications on the same mount
- Trigger AWS-side throttling on the metadata tier

### How it works

The script uses a **token-bucket algorithm** coordinated across all worker processes via a shared lock file. The bucket refills at the configured rate (e.g. 200 tokens/sec). Each worker must acquire a token before calling `rm`. If the bucket is empty, the worker sleeps 1ms and retries — ensuring the total rate never exceeds the cap regardless of worker count.

### Recommended `-r` values

| `-r` value | Deletions/sec | When to use |
|------------|---------------|-------------|
| `0` | Unlimited | Maintenance window, no other workloads on EFS |
| `200` | ~200 | Conservative — safe during business hours |
| `500` | ~500 | Moderate — monitor CloudWatch `MetadataIOPS` |
| `1000` | ~1000 | Aggressive — low-traffic periods only |

### Monitoring EFS during deletion

Watch `MetadataIOPS` on your EFS file system in CloudWatch. If it flatlines at your provisioned limit, reduce `-r`. If there is headroom, increase it.

```bash
aws cloudwatch get-metric-statistics \
    --namespace AWS/EFS \
    --metric-name MetadataIOPS \
    --dimensions Name=FileSystemId,Value=fs-xxxxxxxx \
    --start-time $(date -u -d '5 minutes ago' +%FT%TZ) \
    --end-time $(date -u +%FT%TZ) \
    --period 60 --statistics Average
```

> **Important:** The rate limiter controls this script only. If multiple EC2 instances run the script against the same EFS simultaneously, the combined rate is `N × -r`. Divide your target rate by the number of instances accordingly.

---

## Protected Paths

The script refuses to run if the target resolves to a protected path. Trailing slashes are handled automatically via `realpath`.

| Target | Result | Reason |
|--------|--------|--------|
| `/opt/shared/filecache` | BLOCKED | App-protected path |
| `/opt/shared/filecache/` | BLOCKED | Trailing slash stripped by `realpath` — same as above |
| `/opt/shared/filecache/dataset1` | ALLOWED | Subdirectory of app-protected path |
| `/opt/shared/filecache/a/b/c` | ALLOWED | Nested subdirectory — allowed |
| `/opt`, `/opt/shared`, `/mnt` | BLOCKED | App-protected paths |
| `/mnt/efs/mydata` | ALLOWED | Subdirectory of `/mnt` — allowed |
| `/`, `/etc`, `/usr`, `/var` ... | BLOCKED | System paths — exact match and all subdirectories |
| `/etc/something` | BLOCKED | Subdirectory of system path — always blocked |

**System paths (and all subdirectories) — always blocked:**
```
/  /etc  /usr  /var  /home  /root  /proc  /sys  /dev  /boot  /tmp
```

**App-protected paths (exact match blocked, subdirectories allowed):**
```
/mnt  /opt  /opt/shared  /opt/shared/filecache
```
