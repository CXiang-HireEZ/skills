#!/usr/bin/env bash
# Start / stop the HireEZ local dev stack in the documented order:
#   1. TM-Hiretual-Backend-proxy  2. TM-Hiretual-Frontend  3. htm-backend
#   4. native-agent-backend + native-agent-frontend
# Each service runs in the background; logs and pids live in $STATE_DIR.

set -uo pipefail

PROJECTS_DIR="${HIREEZ_PROJECTS_DIR:-$HOME/Projects}"
STATE_DIR="${HIREEZ_DEV_STATE_DIR:-$HOME/.cache/hireez-dev}"
READY_TIMEOUT="${HIREEZ_READY_TIMEOUT:-300}"

SERVICES="proxy frontend htm agent-be agent-fe"

usage() {
  cat <<EOF
Usage: $(basename "$0") [start|stop|status|logs <service>] [options]

Commands:
  start (default)    start services in order, waiting for each port
  stop               stop services started by this script
  status             show pid / port state of each service
  logs <service>     tail -f a service log

Options (directory overrides, e.g. to run a git worktree):
  --projects DIR     base directory for all repos (default: ~/Projects)
  --proxy DIR        TM-Hiretual-Backend-proxy checkout
  --frontend DIR     TM-Hiretual-Frontend checkout
  --htm DIR          htm-backend checkout
  --agent-be DIR     native-agent-backend checkout
  --agent-fe DIR     native-agent-frontend checkout

Other options:
  --no-agent         skip native-agent-backend and native-agent-frontend
  --only LIST        comma-separated subset: proxy,frontend,htm,agent-be,agent-fe
  --install          run npm ci (npm install without a lockfile) / uv sync where dependencies are missing

Services: $SERVICES
EOF
}

# ---------- argument parsing ----------

CMD=start
case "${1:-}" in
  start|stop|status) CMD=$1; shift ;;
  logs) CMD=logs; shift; LOG_SERVICE="${1:-}"; shift || true ;;
  -h|--help) usage; exit 0 ;;
esac

DIR_proxy="" DIR_frontend="" DIR_htm="" DIR_agent_be="" DIR_agent_fe=""
ONLY="" NO_AGENT=0 INSTALL=0

while [ $# -gt 0 ]; do
  case "$1" in
    --projects) PROJECTS_DIR="$2"; shift 2 ;;
    --proxy) DIR_proxy="$2"; shift 2 ;;
    --frontend) DIR_frontend="$2"; shift 2 ;;
    --htm) DIR_htm="$2"; shift 2 ;;
    --agent-be) DIR_agent_be="$2"; shift 2 ;;
    --agent-fe) DIR_agent_fe="$2"; shift 2 ;;
    --no-agent) NO_AGENT=1; shift ;;
    --only) ONLY="$2"; shift 2 ;;
    --install) INSTALL=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# ---------- service metadata ----------

repo_of() {
  case "$1" in
    proxy) echo TM-Hiretual-Backend-proxy ;;
    frontend) echo TM-Hiretual-Frontend ;;
    htm) echo htm-backend ;;
    agent-be) echo native-agent-backend ;;
    agent-fe) echo native-agent-frontend ;;
  esac
}

default_dir_of() { echo "$PROJECTS_DIR/$(repo_of "$1")"; }

dir_of() {
  local override
  case "$1" in
    proxy) override=$DIR_proxy ;;
    frontend) override=$DIR_frontend ;;
    htm) override=$DIR_htm ;;
    agent-be) override=$DIR_agent_be ;;
    agent-fe) override=$DIR_agent_fe ;;
  esac
  if [ -n "$override" ]; then (cd "$override" 2>/dev/null && pwd) || echo "$override"
  else default_dir_of "$1"; fi
}

# Env file each service needs (gitignored, so worktrees don't have it)
env_file_of() {
  case "$1" in
    frontend|agent-fe) echo .env.development ;;
    htm|agent-be) echo .env ;;
  esac
}

port_of() {
  case "$1" in
    proxy) echo 9002 ;;
    frontend) echo 8081 ;;
    htm)
      # htm-backend reads HTTP_PORT, defaulting to 9001
      local p
      p=$(grep -E '^[[:space:]]*HTTP_PORT[=:]' "$(dir_of htm)/.env" 2>/dev/null | head -1 | sed -E 's/^[^=:]*[=:][[:space:]]*//; s/["'\'' ]//g')
      echo "${p:-9001}" ;;
    agent-be) echo 8000 ;;
    agent-fe) echo 8082 ;;
  esac
}

cmd_of() {
  case "$1" in
    proxy) echo "npm run dev" ;;
    frontend) echo "npm start" ;;
    htm) echo "npm run start:dev" ;;
    agent-be) echo "uv run uvicorn app.main:app --reload --port 8000 --app-dir src" ;;
    agent-fe) echo "npm run dev" ;;
  esac
}

is_node() { [ "$1" != agent-be ]; }

selected_services() {
  local s
  for s in $SERVICES; do
    if [ -n "$ONLY" ]; then
      case ",$ONLY," in *",$s,"*) ;; *) continue ;; esac
    fi
    if [ "$NO_AGENT" = 1 ]; then
      case "$s" in agent-*) continue ;; esac
    fi
    echo "$s"
  done
}

# ---------- helpers ----------

pid_file() { echo "$STATE_DIR/pids/$1.pid"; }
log_file() { echo "$STATE_DIR/logs/$1.log"; }

port_pid() { lsof -nP -iTCP:"$1" -sTCP:LISTEN -t 2>/dev/null | head -1; }

pid_alive() { [ -n "$1" ] && kill -0 "$1" 2>/dev/null; }

saved_pid() { cat "$(pid_file "$1")" 2>/dev/null; }

NODE18_BIN=""
resolve_node18() {
  [ -n "$NODE18_BIN" ] && return 0
  if [ -s "${NVM_DIR:-$HOME/.nvm}/nvm.sh" ]; then
    # shellcheck disable=SC1091
    NODE18_BIN=$(. "${NVM_DIR:-$HOME/.nvm}/nvm.sh" >/dev/null 2>&1; nvm which 18 2>/dev/null)
    NODE18_BIN=$(dirname "$NODE18_BIN" 2>/dev/null)
  fi
  if [ -z "$NODE18_BIN" ] || [ ! -x "$NODE18_BIN/node" ]; then
    echo "error: Node 18 not found via nvm (repos pin node 18.12.1). Run: nvm install 18" >&2
    return 1
  fi
}

# ---------- preflight ----------

preflight() {
  local s dir env def ok=1
  for s in "$@"; do
    dir=$(dir_of "$s")
    if [ ! -d "$dir" ]; then
      echo "error: [$s] directory not found: $dir" >&2; ok=0; continue
    fi

    env=$(env_file_of "$s")
    if [ -n "$env" ] && [ ! -f "$dir/$env" ]; then
      def=$(default_dir_of "$s")
      if [ "$dir" != "$def" ] && [ -f "$def/$env" ]; then
        cp "$def/$env" "$dir/$env"
        echo "[$s] copied $env from $def"
      else
        echo "error: [$s] missing $dir/$env" >&2
        [ "$s" = htm ] && echo "       create it with contents copied from envs.yaml" >&2
        ok=0
      fi
    fi

    if is_node "$s" && [ ! -d "$dir/node_modules" ]; then
      if [ "$INSTALL" = 1 ]; then
        # npm ci needs a lockfile; TM-Hiretual-Backend-proxy has none
        local npm_cmd="npm ci"
        [ -f "$dir/package-lock.json" ] || npm_cmd="npm install"
        echo "[$s] installing dependencies ($npm_cmd)…"
        (cd "$dir" && PATH="$NODE18_BIN:$PATH" $npm_cmd) || { echo "error: [$s] $npm_cmd failed" >&2; ok=0; }
      else
        echo "error: [$s] node_modules missing in $dir (re-run with --install)" >&2; ok=0
      fi
    fi
    if [ "$s" = agent-be ] && [ ! -d "$dir/.venv" ]; then
      if [ "$INSTALL" = 1 ]; then
        echo "[$s] installing dependencies (uv sync)…"
        (cd "$dir" && uv sync) || { echo "error: [$s] uv sync failed" >&2; ok=0; }
      else
        echo "error: [$s] .venv missing in $dir (re-run with --install)" >&2; ok=0
      fi
    fi
  done
  [ "$ok" = 1 ]
}

# ---------- commands ----------

start_one() {
  local s=$1 dir port cmd log pid existing waited=0 path_prefix=""
  dir=$(dir_of "$s"); port=$(port_of "$s"); cmd=$(cmd_of "$s"); log=$(log_file "$s")

  existing=$(port_pid "$port")
  if [ -n "$existing" ]; then
    echo "[$s] port $port already in use (pid $existing), skipping"
    return 0
  fi

  is_node "$s" && path_prefix="$NODE18_BIN:"
  echo "[$s] starting in $dir: $cmd"
  : > "$log"
  # set -m gives the job its own process group so stop can kill npm's children too
  set -m
  (cd "$dir" && PATH="$path_prefix$PATH" exec $cmd) >>"$log" 2>&1 &
  pid=$!
  set +m
  echo "$pid" > "$(pid_file "$s")"

  printf "[%s] waiting for port %s" "$s" "$port"
  while [ -z "$(port_pid "$port")" ]; do
    if ! pid_alive "$pid"; then
      echo; echo "error: [$s] exited before listening. Last log lines ($log):" >&2
      tail -n 30 "$log" >&2
      return 1
    fi
    if [ "$waited" -ge "$READY_TIMEOUT" ]; then
      echo; echo "error: [$s] not listening on $port after ${READY_TIMEOUT}s; see $log" >&2
      return 1
    fi
    sleep 2; waited=$((waited + 2)); printf "."
  done
  echo " ready (${waited}s)"
}

do_start() {
  local services s
  services=$(selected_services)
  [ -z "$services" ] && { echo "No services selected" >&2; exit 2; }
  mkdir -p "$STATE_DIR/pids" "$STATE_DIR/logs"
  resolve_node18 || exit 1
  # shellcheck disable=SC2086
  preflight $services || exit 1
  for s in $services; do
    start_one "$s" || { echo "Startup stopped at [$s]. Already-started services keep running; use: $(basename "$0") stop" >&2; exit 1; }
  done
  echo
  do_status
  echo
  echo "Logs: $STATE_DIR/logs  (tail with: $(basename "$0") logs <service>)"
}

do_stop() {
  local s pid reversed=""
  for s in $(selected_services); do reversed="$s $reversed"; done
  for s in $reversed; do
    pid=$(saved_pid "$s")
    if pid_alive "$pid"; then
      echo "[$s] stopping pid $pid"
      kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null
    fi
    rm -f "$(pid_file "$s")"
  done
}

do_status() {
  local s pid port listener state
  printf "%-9s %-7s %-6s %-10s %s\n" SERVICE PID PORT STATE DIR
  for s in $(selected_services); do
    pid=$(saved_pid "$s"); port=$(port_of "$s"); listener=$(port_pid "$port")
    if pid_alive "$pid" && [ -n "$listener" ]; then state=up
    elif pid_alive "$pid"; then state=starting
    elif [ -n "$listener" ]; then state="external"; pid=$listener
    else state=down; pid=-; fi
    printf "%-9s %-7s %-6s %-10s %s\n" "$s" "$pid" "$port" "$state" "$(dir_of "$s")"
  done
}

case "$CMD" in
  start) do_start ;;
  stop) do_stop ;;
  status) do_status ;;
  logs)
    [ -z "${LOG_SERVICE:-}" ] && { echo "Usage: $(basename "$0") logs <service>" >&2; exit 2; }
    exec tail -n 100 -f "$(log_file "$LOG_SERVICE")" ;;
esac
