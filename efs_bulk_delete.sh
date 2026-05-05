#!/usr/bin/env bash
# =============================================================================
# efs_bulk_delete.sh
# Production-safe parallel file deletion for large EFS mounts
# - Empties a directory but PRESERVES the directory itself
# - Hard rate limiting (max deletions/sec) to protect EFS metadata API
# - CLI flags only (no env var overrides)
#
# Usage: ./efs_bulk_delete.sh [options] <target_directory>
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()     { echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }
info()    { log "${CYAN}INFO${NC}  $*"; }
warn()    { log "${YELLOW}WARN${NC}  $*"; }
success() { log "${GREEN}OK${NC}    $*"; }
error()   { log "${RED}ERROR${NC} $*"; }

# ── Defaults ──────────────────────────────────────────────────────────────────
PARALLEL_WORKERS=32
FILES_PER_BATCH=500
MAX_DELETES_PER_SEC=0
DRY_RUN=false
SKIP_CONFIRM=false
LOG_FILE="/tmp/efs_delete_$(date +%Y%m%d_%H%M%S).log"

usage() {
  cat <<EOF
${BOLD}Usage:${NC}
  $0 [options] <target_directory>

${BOLD}Options:${NC}
  -w <N>   Parallel workers          (default: 32)
  -b <N>   Files per batch           (default: 500)
  -r <N>   Rate limit deletions/sec, 0=unlimited  (default: 0)
  -n       Dry run — preview only, no deletion
  -y       Skip confirmation prompt (for scripts/tmux)
  -l <f>   Log file path             (default: /tmp/efs_delete_<timestamp>.log)
  -h       Show this help

${BOLD}Rate limit guidance:${NC}
  -r 0     Unlimited — maintenance windows only
  -r 200   Conservative — safe during live workloads
  -r 500   Moderate — monitor CloudWatch MetadataIOPS
  -r 1000  Aggressive — low-traffic periods only

${BOLD}Examples:${NC}
  # Dry run first
  $0 -n /opt/shared/filecache/dataset1

  # Full speed, 32 workers
  $0 /opt/shared/filecache/dataset1

  # Rate-limited, skip prompt (for tmux/automation)
  $0 -r 200 -w 16 -y /opt/shared/filecache/dataset1

  # Maintenance window
  $0 -r 0 -w 64 -y /opt/shared/filecache/dataset1
EOF
  exit 0
}

# ── Parse CLI args ─────────────────────────────────────────────────────────────
while getopts ":w:b:r:l:nyh" opt; do
  case $opt in
    w) PARALLEL_WORKERS="$OPTARG" ;;
    b) FILES_PER_BATCH="$OPTARG" ;;
    r) MAX_DELETES_PER_SEC="$OPTARG" ;;
    l) LOG_FILE="$OPTARG" ;;
    n) DRY_RUN=true ;;
    y) SKIP_CONFIRM=true ;;
    h) usage ;;
    :) echo "Option -$OPTARG requires an argument."; exit 1 ;;
    \?) echo "Unknown option: -$OPTARG"; exit 1 ;;
  esac
done
shift $(( OPTIND - 1 ))

TARGET="${1:-}"

# ── Preflight ──────────────────────────────────────────────────────────────────
preflight() {
  if [[ -z "$TARGET" ]]; then
    error "No target directory specified. Use -h for help."
    exit 1
  fi

  if [[ ! -d "$TARGET" ]]; then
    error "Target directory does not exist: $TARGET"
    exit 1
  fi

  # Validate numeric args
  if ! [[ "$PARALLEL_WORKERS" =~ ^[0-9]+$ ]] || (( PARALLEL_WORKERS < 1 || PARALLEL_WORKERS > 256 )); then
    error "-w workers must be between 1 and 256"
    exit 1
  fi
  if ! [[ "$MAX_DELETES_PER_SEC" =~ ^[0-9]+$ ]]; then
    error "-r rate-limit must be a non-negative integer"
    exit 1
  fi

  # Resolve real path — strips trailing slashes and symlinks
  # e.g. /opt/shared/filecache/ -> /opt/shared/filecache
  local resolved
  resolved=$(realpath "$TARGET")

  # System paths: block exact match AND any subdirectory
  local SYSTEM_FORBIDDEN=("/" "/etc" "/usr" "/var" "/home" "/root" "/proc" "/sys" "/dev" "/boot" "/tmp")
  for forbidden in "${SYSTEM_FORBIDDEN[@]}"; do
    if [[ "$resolved" == "$forbidden" || "$resolved" == "$forbidden/"* ]]; then
      error "SAFETY BLOCK: Refusing to run against system path: $resolved"
      exit 1
    fi
  done

  # App-protected paths: block exact match only, subdirectories ARE allowed
  # BLOCKED : /opt/shared/filecache   or   /opt/shared/filecache/
  # ALLOWED : /opt/shared/filecache/dataset1
  local APP_PROTECTED=("/mnt" "/opt" "/opt/shared" "/opt/shared/filecache")
  for protected in "${APP_PROTECTED[@]}"; do
    if [[ "$resolved" == "$protected" ]]; then
      error "SAFETY BLOCK: Refusing to run against protected path: $resolved"
      error "Target must be a subdirectory, e.g.: ${protected}/your-dataset"
      exit 1
    fi
  done

  # Check required tools
  for cmd in find xargs rm realpath; do
    if ! command -v "$cmd" &>/dev/null; then
      error "Required command not found: $cmd"
      exit 1
    fi
  done

  # Check for GNU parallel (optional)
  if command -v parallel &>/dev/null; then
    HAVE_PARALLEL=true
  else
    HAVE_PARALLEL=false
    warn "GNU parallel not found — falling back to find+xargs (still fast)"
  fi
}

# ── Estimate scope ─────────────────────────────────────────────────────────────
estimate_scope() {
  info "Estimating file count (sampling up to 100k files)..."
  local sample_count
  sample_count=$(find "$TARGET" -mindepth 1 -type f 2>/dev/null | head -100000 | wc -l)
  if (( sample_count >= 100000 )); then
    warn "100,000+ files found — actual count is much larger"
  else
    info "Estimated file count: $sample_count"
  fi
  local disk_usage
  disk_usage=$(du -sh "$TARGET" 2>/dev/null | cut -f1 || echo "unknown")
  info "Approximate disk usage: $disk_usage"
}

# ── Progress monitor (background) ─────────────────────────────────────────────
MONITOR_PID=""
start_progress_monitor() {
  local start_time=$SECONDS
  (
    while true; do
      sleep 30
      local elapsed=$(( SECONDS - start_time ))
      local fmt
      fmt=$(printf '%02d:%02d:%02d' $((elapsed/3600)) $((elapsed%3600/60)) $((elapsed%60)))
      local remaining
      remaining=$(find "$TARGET" -mindepth 1 -type f 2>/dev/null | head -10000 | wc -l || echo "?")
      log "${CYAN}PROGRESS${NC} Elapsed: ${fmt} | Files remaining (sample): ${remaining}+"
    done
  ) &
  MONITOR_PID=$!
}

stop_progress_monitor() {
  [[ -n "$MONITOR_PID" ]] && kill "$MONITOR_PID" 2>/dev/null || true
}

# ── Rate-limited delete (token bucket via flock) ───────────────────────────────
RATE_STATE_FILE=""

init_rate_limiter() {
  if (( MAX_DELETES_PER_SEC > 0 )); then
    RATE_STATE_FILE=$(mktemp /tmp/efs_rate_XXXXXX)
    echo "0 $(date +%s)" > "$RATE_STATE_FILE"
    info "Rate limiter active: max ${MAX_DELETES_PER_SEC} deletions/sec"
  fi
}

cleanup_rate_limiter() {
  [[ -n "$RATE_STATE_FILE" && -f "$RATE_STATE_FILE" ]] && rm -f "$RATE_STATE_FILE" "$RATE_STATE_FILE.lock" 2>/dev/null || true
}

rate_limited_delete() {
  local file="$1"
  local max_rate="$2"
  local state_file="$3"
  local lock_file="${state_file}.lock"

  (
    flock -x 9
    read -r count window_start < "$state_file"
    local now
    now=$(date +%s)

    if (( now > window_start )); then
      count=0
      window_start=$now
    fi

    if (( count >= max_rate )); then
      local sleep_time=$(( window_start + 1 - now ))
      (( sleep_time > 0 )) && sleep "$sleep_time"
      count=0
      window_start=$(date +%s)
    fi

    rm -f "$file"
    count=$(( count + 1 ))
    echo "$count $window_start" > "$state_file"
  ) 9>"$lock_file"
}
export -f rate_limited_delete

# ── Main delete logic ──────────────────────────────────────────────────────────
run_delete() {
  if [[ "$DRY_RUN" == "true" ]]; then
    warn "DRY RUN — no files will be deleted"
    info "Root directory will be PRESERVED: $TARGET"
    info "Sample of contents that would be deleted:"
    find "$TARGET" -mindepth 1 2>/dev/null | head -20
    local count
    count=$(find "$TARGET" -mindepth 1 -type f 2>/dev/null | wc -l)
    info "Total files that would be deleted: $count"
    return
  fi

  init_rate_limiter
  local start_time=$SECONDS

  # Phase 1: delete files
  info "Phase 1/2: Deleting files (root directory preserved: $TARGET)"

  if (( MAX_DELETES_PER_SEC > 0 )); then
    info "Rate-limited mode: ${MAX_DELETES_PER_SEC} deletions/sec"
    find "$TARGET" -mindepth 1 -type f -print0 2>/dev/null \
      | xargs -0 -P "$PARALLEL_WORKERS" -n 1 \
          bash -c 'rate_limited_delete "$1" '"$MAX_DELETES_PER_SEC"' '"$RATE_STATE_FILE"'' _ \
      || warn "Some deletions had errors"

  elif [[ "$HAVE_PARALLEL" == "true" ]]; then
    info "GNU parallel mode: $PARALLEL_WORKERS workers, unlimited rate"
    find "$TARGET" -mindepth 1 -type f -print0 2>/dev/null \
      | parallel --null --jobs "$PARALLEL_WORKERS" --bar --eta \
          --joblog "${LOG_FILE}.joblog" rm -f {} \
      && success "File deletion complete" \
      || warn "Some deletions failed — check ${LOG_FILE}.joblog"

  else
    info "xargs mode: $PARALLEL_WORKERS workers, unlimited rate"
    find "$TARGET" -mindepth 1 -type f -print0 2>/dev/null \
      | xargs -0 -P "$PARALLEL_WORKERS" -n "$FILES_PER_BATCH" rm -f \
      || warn "Some deletions had errors"
  fi

  # Phase 2: remove empty subdirectories (never removes TARGET itself)
  info "Phase 2/2: Removing empty subdirectories (root preserved)"
  find "$TARGET" -mindepth 1 -depth -type d -empty -delete 2>/dev/null || true

  cleanup_rate_limiter

  local elapsed=$(( SECONDS - start_time ))
  local fmt
  fmt=$(printf '%02d:%02d:%02d' $((elapsed/3600)) $((elapsed%3600/60)) $((elapsed%60)))
  success "Deletion finished in ${fmt}"

  if [[ -d "$TARGET" ]]; then
    success "Root directory preserved: $TARGET"
  else
    error "Root directory missing — this should not happen!"
    exit 1
  fi
}

# ── Entry point ────────────────────────────────────────────────────────────────
main() {
  preflight

  info "═══════════════════════════════════════════════════"
  info "  EFS Bulk Delete — $(date)"
  info "  Target   : $TARGET  (directory preserved)"
  info "  Workers  : $PARALLEL_WORKERS | Batch: $FILES_PER_BATCH"
  info "  Rate cap : ${MAX_DELETES_PER_SEC} deletions/sec (0=unlimited)"
  info "  Dry run  : $DRY_RUN"
  info "  Log      : $LOG_FILE"
  info "═══════════════════════════════════════════════════"

  estimate_scope

  if [[ "$DRY_RUN" != "true" && "$SKIP_CONFIRM" != "true" ]]; then
    echo ""
    warn "About to permanently delete ALL CONTENTS of: $TARGET"
    warn "The directory itself will be preserved."
    echo ""
    read -r -p "    Type YES to confirm: " confirm
    if [[ "$confirm" != "YES" ]]; then
      error "Aborted by user."
      exit 1
    fi
  fi

  trap stop_progress_monitor EXIT
  start_progress_monitor
  run_delete
  stop_progress_monitor

  success "All done. Log: $LOG_FILE"
}

main
