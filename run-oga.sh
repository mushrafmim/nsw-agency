#!/usr/bin/env bash
# Run OGA backends and/or frontends with per-agency config.
#
# Usage:
#   ./run-oga.sh <oga> [target]
#
#   <oga>     One of: npqs, fcau, ird, cda, default, all
#             'all' fans out and starts every agency in parallel.
#   [target]  One of: all (default), backend, frontend
#
# Each OGA maps to its own:
#   - backend HTTP port and SQLite DB file
#   - frontend dev server port
#   - frontend branding config (public/configs/<oga>.branding.json)
#   - IdP client id
#
# Env-var precedence (highest to lowest):
#   parent shell env > backend/.env (for backend vars) > script defaults
# i.e. OGA_PORT=9000 ./run-oga.sh npqs honours the override; .env can fill in
# anything the parent didn't set; the per-agency defaults below are the floor.
#
# Examples:
#   ./run-oga.sh npqs              # NPQS backend + frontend
#   ./run-oga.sh fcau backend      # FCAU backend only
#   ./run-oga.sh ird frontend      # IRD frontend only
#   ./run-oga.sh all               # every backend + frontend, in parallel
#   ./run-oga.sh all backend       # every backend, no frontends
#
# Ctrl-C terminates every child process (each runs in its own process group).

set -euo pipefail
# Enable job control so each backgrounded subshell becomes its own process
# group leader — that lets us kill `go run`'s grandchild binary on cleanup.
set -m

# Single source of truth for per-OGA config: "BE_PORT|FE_PORT|IDP_CLIENT_ID|NSW_CLIENT_ID".
# Adding an agency means one line here — nothing else.
# (Scalar vars rather than `declare -A` so this works on stock macOS bash 3.2.)
OGA_CONFIG_npqs="8081|5174|OGA_PORTAL_APP_NPQS|NPQS_TO_NSW"
OGA_CONFIG_fcau="8082|5175|OGA_PORTAL_APP_FCAU|FCAU_TO_NSW"
OGA_CONFIG_ird="8083|5176|OGA_PORTAL_APP_IRD|IRD_TO_NSW"
OGA_CONFIG_cda="8084|5177|OGA_PORTAL_APP_CDA|CDA_TO_NSW"
OGA_CONFIG_default="8081|5174|OGA_TO_NSW|OGA_TO_NSW"

# Real agencies (every OGA_CONFIG_* except 'default'), alphabetised for
# predictable launch order in 'all' mode. Derived from the config above so
# adding an agency only requires editing the OGA_CONFIG_* block.
ALL_OGAS=()
while IFS= read -r _v; do
  _oga="${_v#OGA_CONFIG_}"
  [[ "$_oga" == "default" ]] && continue
  ALL_OGAS+=("$_oga")
done < <(compgen -A variable OGA_CONFIG_ | sort)
unset _v _oga

usage() {
  cat <<EOF >&2
Usage: $0 <oga> [target]

  <oga>     One of: ${ALL_OGAS[*]}, default, all
  [target]  One of: all (default), backend, frontend

Examples:
  $0 npqs                  # NPQS backend + frontend
  $0 fcau backend          # FCAU backend only
  $0 all                   # every OGA, backends + frontends
  $0 all frontend          # every OGA, frontends only
EOF
  exit 1
}

OGA="${1:-}"
TARGET="${2:-all}"

[[ -z "$OGA" ]] && usage

case "$TARGET" in
  all|backend|frontend) ;;
  *)
    echo "Unknown target '$TARGET'." >&2
    usage
    ;;
esac

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKEND_DIR="$ROOT_DIR/backend"
FRONTEND_DIR="$ROOT_DIR/frontend"

PIDS=()

cleanup() {
  # Avoid recursion if the trap fires more than once.
  trap - EXIT INT TERM
  if (( ${#PIDS[@]} > 0 )); then
    echo
    echo "[run-oga] Stopping ${#PIDS[@]} process(es)..."
    for pid in "${PIDS[@]}"; do
      if kill -0 "$pid" 2>/dev/null; then
        # Negative PID -> signal the whole process group (set -m makes each
        # background subshell its own pgroup leader with pgid == pid).
        kill -TERM "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
      fi
    done
    wait 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

# Sets BE_PORT, FE_PORT, IDP_CLIENT_ID, NSW_CLIENT_ID for the given agency.
resolve_oga() {
  local varname="OGA_CONFIG_$1"
  local config="${!varname:-}"
  if [[ -z "$config" ]]; then
    echo "Unknown OGA '$1'. Expected: ${ALL_OGAS[*]}, default, all." >&2
    return 1
  fi
  IFS='|' read -r BE_PORT FE_PORT IDP_CLIENT_ID NSW_CLIENT_ID <<<"$config"
}

# Source a .env file without clobbering vars already set in the environment.
# This preserves parent-shell overrides (e.g. OGA_PORT=9000 ./run-oga.sh npqs).
source_env_nonclobber() {
  local file=$1 line key
  [[ -f "$file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in ''|\#*) continue ;; esac
    [[ "$line" == *=* ]] || continue
    key="${line%%=*}"
    key="${key#export }"
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    # Already set in env (even to empty string) -> skip.
    [[ -n "${!key+x}" ]] && continue
    set -a
    eval "$line"
    set +a
  done <"$file"
}

start_backend() {
  local oga=$1
  resolve_oga "$oga"
  echo "[run-oga] Starting $oga backend  -> http://localhost:$BE_PORT (db: ${oga}_applications.db)"
  (
    cd "$BACKEND_DIR"
    # Apply per-OGA values BEFORE sourcing .env so they aren't clobbered by
    # the generic .env defaults (which typically have OGA_PORT=8081 etc.).
    # ${VAR:-…} preserves a parent-shell override.
    # Final precedence: parent env > script per-OGA > .env > Go-side fallback.
    export OGA_PORT="${OGA_PORT:-$BE_PORT}"
    export OGA_DB_DRIVER="${OGA_DB_DRIVER:-sqlite}"
    export OGA_DB_PATH="${OGA_DB_PATH:-./${oga}_applications.db}"
    export OGA_NSW_CLIENT_ID="${OGA_NSW_CLIENT_ID:-$NSW_CLIENT_ID}"
    # The Go server does not autoload .env — source it (non-clobber) so
    # OGA_NSW_* vars (API base URL, OAuth client secret, token URL) reach
    # the process without overriding anything already set above.
    if [[ -f .env ]]; then
      source_env_nonclobber .env
    else
      echo "[run-oga] WARNING: backend/.env not found — backend will fail if OGA_NSW_* vars are unset." >&2
    fi
    exec go run ./cmd/server
  ) &
  PIDS+=("$!")
}

start_frontend() {
  local oga=$1
  resolve_oga "$oga"
  echo "[run-oga] Starting $oga frontend -> http://localhost:$FE_PORT (branding: $oga, idp: $IDP_CLIENT_ID)"
  (
    cd "$FRONTEND_DIR"
    # Vite autoloads frontend/.env but only reads VITE_PORT from process env.
    VITE_PORT="${VITE_PORT:-$FE_PORT}" \
    VITE_BRANDING_NAME="${VITE_BRANDING_NAME:-$oga}" \
    VITE_API_BASE_URL="${VITE_API_BASE_URL:-http://localhost:$BE_PORT}" \
    VITE_IDP_BASE_URL="${VITE_IDP_BASE_URL:-https://localhost:8090}" \
    VITE_IDP_CLIENT_ID="${VITE_IDP_CLIENT_ID:-$IDP_CLIENT_ID}" \
    VITE_APP_URL="${VITE_APP_URL:-http://localhost:$FE_PORT}" \
    exec pnpm run dev
  ) &
  PIDS+=("$!")
}

# Resolve the OGA list to launch.
if [[ "$OGA" == "all" ]]; then
  OGAS=("${ALL_OGAS[@]}")
else
  # Validate it's a known OGA without polluting globals (subshell).
  ( resolve_oga "$OGA" >/dev/null ) || usage
  OGAS=("$OGA")
fi

for o in "${OGAS[@]}"; do
  [[ "$TARGET" == "all" || "$TARGET" == "backend"  ]] && start_backend  "$o"
  [[ "$TARGET" == "all" || "$TARGET" == "frontend" ]] && start_frontend "$o"
done

echo "[run-oga] ${#PIDS[@]} process(es) running. Logs from all processes will interleave below. Press Ctrl-C to stop."
wait
