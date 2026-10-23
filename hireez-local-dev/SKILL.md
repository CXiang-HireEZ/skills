---
name: hireez-local-dev
description: Set up and run the HireEZ local dev environment (TM-Hiretual-Frontend, TM-Hiretual-Backend-proxy, htm-backend, native-agent-frontend, native-agent-backend). Use when starting, stopping, or debugging the local stack, logging in locally, pointing a service at local vs. the test environment, or running a git worktree of one of these repos.
---

# HireEZ local dev environment

## Roles
- `TM-Hiretual-Frontend` (old frontend): used for login
- `TM-Hiretual-Backend` (old backend): don't start it; `TM-Hiretual-Backend-proxy` replaces it. Mostly only used for login auth
- `htm-backend` (common backend): must always be started
- `native-agent-frontend` (agent frontend): the agent module
- `native-agent-backend` (agent backend): start only when working on the agent

## Request flow
- Login: Frontend -> backend proxy -> test server
- Local debug: Frontend -> htm-backend -> native-agent-backend. Whichever part is pointed at local is served locally; the rest connects to the test environment.

## Startup order
1. `TM-Hiretual-Backend-proxy`
2. `TM-Hiretual-Frontend` (needs `.env.development`)
3. `htm-backend` (needs `.env`, contents copied from `envs.yaml`)
4. `native-agent-frontend` and `native-agent-backend`

## Startup script

`scripts/dev-stack.sh` (in this skill's directory) runs the pipeline in that order, in the background, waiting for each service's port before starting the next.

```bash
S=~/.claude/skills/hireez-local-dev/scripts/dev-stack.sh
$S                      # start everything from ~/Projects
$S --no-agent           # skip the agent frontend/backend
$S --only htm,agent-be  # start a subset
$S status               # pid / port / state per service
$S logs htm             # tail a service log
$S stop                 # stop what the script started
```

Use a worktree for any repo by overriding its directory; the rest stay on `~/Projects`:

```bash
$S --htm ~/Projects/htm-backend-wt/HT5-12345 --agent-be ../native-agent-backend-wt
```

Flags: `--projects DIR`, `--proxy DIR`, `--frontend DIR`, `--htm DIR`, `--agent-be DIR`, `--agent-fe DIR`, `--no-agent`, `--only LIST`, `--install`.

Behavior:
- Service names: `proxy`, `frontend`, `htm`, `agent-be`, `agent-fe`.
- Ports waited on: proxy 9002, frontend 8081, htm `HTTP_PORT` from its `.env` (default 9001), agent-be 8000, agent-fe 8082. A service whose port is already in use is skipped.
- Node services run on Node 18 from nvm (repos pin 18.12.1); agent-be runs via `uv run uvicorn`.
- Env files are gitignored, so a worktree won't have them: if missing in an overridden directory, the script copies them from the `~/Projects` checkout.
- Missing `node_modules` / `.venv` is an error unless `--install` is passed (runs `npm ci`, or `npm install` without a lockfile, / `uv sync`).
- Logs and pids: `~/.cache/hireez-dev/{logs,pids}`. Override with `HIREEZ_DEV_STATE_DIR`; readiness timeout with `HIREEZ_READY_TIMEOUT` (seconds, default 300).
