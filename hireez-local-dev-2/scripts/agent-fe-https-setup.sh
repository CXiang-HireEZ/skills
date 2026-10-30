#!/usr/bin/env bash
# Prepare a native-agent-frontend checkout to run over https on localhost.test2.testhireez.com,
# sharing the test2 login cookie, with no TM-Hiretual-Frontend or TM-Hiretual-Backend-proxy:
#   1. write vite.local.config.ts (wraps vite.config.ts, adds https + the hostname)
#   2. add it to the repo's shared git exclude file
#   3. point .env.development at Vite's own proxy and the test2 login, and regenerate public/env.js
# Then check the one-time prerequisites and print the command to run the dev server.
# Safe to re-run.

set -euo pipefail

PROJECTS_DIR="${HIREEZ_PROJECTS_DIR:-$HOME/Projects}"
HOST=localhost.test2.testhireez.com
CERT_DIR="$HOME/.certs"
TEST2_APP=https://app.test2.testhireez.com

usage() {
  cat <<EOF
Usage: $(basename "$0") [DIR]

DIR is a native-agent-frontend checkout or worktree (default: current directory).
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

DIR="$(cd "${1:-.}" && pwd)"

if [ ! -f "$DIR/vite.config.ts" ] || ! grep -q '"name": "native-agent-frontend"' "$DIR/package.json" 2>/dev/null; then
  echo "error: $DIR is not a native-agent-frontend checkout" >&2
  exit 1
fi

# ---------- 1. vite.local.config.ts ----------

cat >"$DIR/vite.local.config.ts" <<'EOF'
// Local only, never committed (listed in .git/info/exclude). Written by the hireez-local-dev skill's
// agent-fe-https-setup.sh: serves the dev server over https on a test2 subdomain so the browser
// sends it the test2 session cookie.
import os from 'os';
import fs from 'fs';
import { defineConfig, mergeConfig } from 'vite';
import base from './vite.config';

const host = 'localhost.test2.testhireez.com';
const certs = `${os.homedir()}/.certs`;

export default defineConfig(async (env) =>
  mergeConfig(await base(env), {
    server: {
      host,
      https: {
        cert: fs.readFileSync(`${certs}/${host}.pem`),
        key: fs.readFileSync(`${certs}/${host}-key.pem`),
      },
      allowedHosts: [host],
    },
  }),
);
EOF
echo "wrote vite.local.config.ts"

# ---------- 2. git exclude ----------

EXCLUDE="$(git -C "$DIR" rev-parse --path-format=absolute --git-common-dir)/info/exclude"
mkdir -p "$(dirname "$EXCLUDE")"
if ! grep -qx 'vite.local.config.ts' "$EXCLUDE" 2>/dev/null; then
  echo 'vite.local.config.ts' >>"$EXCLUDE"
  echo "added vite.local.config.ts to $EXCLUDE"
fi

# ---------- 3. .env.development ----------

ENV_FILE="$DIR/.env.development"
if [ ! -f "$ENV_FILE" ]; then
  if [ -f "$PROJECTS_DIR/native-agent-frontend/.env.development" ] && [ "$DIR" != "$PROJECTS_DIR/native-agent-frontend" ]; then
    cp "$PROJECTS_DIR/native-agent-frontend/.env.development" "$ENV_FILE"
    echo "copied .env.development from $PROJECTS_DIR/native-agent-frontend"
  else
    cp "$DIR/.env.example" "$ENV_FILE"
    echo "copied .env.development from .env.example"
  fi
fi

# Replace KEY=... (commented or not) with KEY=VALUE, or append it when absent.
set_env() {
  local key=$1 value=$2 tmp
  tmp="$(mktemp)"
  awk -v key="$key" -v value="$value" '
    $0 ~ "^[[:space:]]*#?[[:space:]]*" key "=" {
      if (!done) { print key "=" value; done = 1 }
      next
    }
    { print }
    END { if (!done) print key "=" value }
  ' "$ENV_FILE" >"$tmp"
  mv "$tmp" "$ENV_FILE"
}

set_env NEW_BACKEND_API_URL ''
set_env REST_URL ''
set_env WEBSITE_URL "$TEST2_APP"
set_env AUTH_BRIDGE_URL "$TEST2_APP"
echo "set NEW_BACKEND_API_URL, REST_URL (empty) and WEBSITE_URL, AUTH_BRIDGE_URL ($TEST2_APP) in .env.development"

# The app reads these values from public/env.js, not .env.development. `npm run dev` regenerates it,
# a bare `npx vite` does not, so regenerate now as well.
(cd "$DIR" && node scripts/gen-env.js >/dev/null)
echo "regenerated public/env.js"

# ---------- prerequisites ----------

MISSING=0
if ! awk -v h="$HOST" '$1 == "127.0.0.1" { for (i = 2; i <= NF; i++) if ($i == h) f = 1 } END { exit !f }' /etc/hosts; then
  MISSING=1
  echo
  echo "missing: /etc/hosts entry. Run:"
  echo "  echo '127.0.0.1 $HOST' | sudo tee -a /etc/hosts"
fi
if [ ! -f "$CERT_DIR/$HOST.pem" ] || [ ! -f "$CERT_DIR/$HOST-key.pem" ]; then
  MISSING=1
  echo
  echo "missing: https certificate. Run:"
  echo "  brew install mkcert nss && mkcert -install"
  echo "  mkdir -p $CERT_DIR && (cd $CERT_DIR && mkcert $HOST)"
fi

# ---------- run command ----------

PORT=8083
while lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; do
  PORT=$((PORT + 1))
done

HTM_PORT="$(sed -nE "s/^HTTP_PORT=['\"]?([0-9]+)['\"]?.*/\1/p" "$PROJECTS_DIR/htm-backend/.env" 2>/dev/null | head -1)"
HTM_PORT="${HTM_PORT:-9001}"

echo
[ "$MISSING" = 1 ] && echo "Fix the missing prerequisites above, then run one of:" || echo "Ready. Run one of:"
echo "  # /tb-v2 to the local htm-backend"
echo "  cd $DIR && LOCAL_TB_BACKEND=http://127.0.0.1:$HTM_PORT npm run dev -- --config vite.local.config.ts --port $PORT"
echo "  # /tb-v2 to test2"
echo "  cd $DIR && LOCAL_TB_BACKEND=https://api.test2.testhireez.com npm run dev -- --config vite.local.config.ts --port $PORT"
echo "Open https://$HOST:$PORT/agent/ (sign in on $TEST2_APP if asked)."
