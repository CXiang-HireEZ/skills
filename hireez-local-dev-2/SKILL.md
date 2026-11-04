---
name: hireez-local-dev
description: Set up and run the HireEZ local dev environment (TM-Hiretual-Frontend, TM-Hiretual-Backend-proxy, htm-backend, native-agent-frontend, native-agent-backend). Use when starting, stopping, or debugging the local stack, logging in locally, running several agent-frontend worktrees on a shared test2 login without the SaaS frontend, pointing a service at local vs. the test environment, or running a git worktree of one of these repos.
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

## Startup commands

Give the user one direct command for each service. Do not wrap the commands in a script. Each command runs in the foreground, so the user starts each service in its own terminal, in the startup order above, and stops it with Ctrl-C.

For a worktree, replace the `~/Projects/<repo>` directory with the worktree path. Env files are gitignored, so a new worktree does not have them. Copy the env file from the `~/Projects` checkout first, for example `cp ~/Projects/htm-backend/.env <worktree>/.env`.

The Node repos pin Node 18 (18.12.1). Run `nvm use 18` in the terminal first.

```bash
# 1. TM-Hiretual-Backend-proxy, port 9002
cd ~/Projects/TM-Hiretual-Backend-proxy && nvm use 18 && npm run dev

# 2. TM-Hiretual-Frontend, port 8081 (needs .env.development)
cd ~/Projects/TM-Hiretual-Frontend && nvm use 18 && npm start

# 3. htm-backend, port HTTP_PORT from its .env (9004 at the time of writing; default 9001)
cd ~/Projects/htm-backend && nvm use 18 && npm run start:dev

# 4a. native-agent-backend, port 8000 (needs .env)
cd ~/Projects/native-agent-backend && uv run uvicorn app.main:app --reload --port 8000 --app-dir src

# 4b. native-agent-frontend, port 8082 (needs .env.development)
cd ~/Projects/native-agent-frontend && nvm use 18 && npm run dev
```

If `node_modules` is missing, run `npm ci` first (`npm install` for `TM-Hiretual-Backend-proxy`, which has no lockfile). If `.venv` is missing in `native-agent-backend`, run `uv sync` first.

To check if a service listens on its port: `lsof -nP -iTCP:<port> -sTCP:LISTEN`.

## Agent frontend without the SaaS frontend or proxy

Use this setup to run several `native-agent-frontend` worktrees at once. You don't need `TM-Hiretual-Frontend` or `TM-Hiretual-Backend-proxy` for it.

The agent app has no login screen. It reads the `hiretual_session` and `csrfToken` cookies, and the test2 login sets them with `Domain=.test2.testhireez.com` and `Secure`. Serve the dev server over https on `localhost.test2.testhireez.com` and the browser sends it those cookies. The user signs in once on `https://app.test2.testhireez.com`, and every worktree shares that session. Cookies ignore ports, so each worktree can use its own port.

### Setup (one line per checkout)

```bash
~/.claude/skills/hireez-local-dev/scripts/agent-fe-https-setup.sh [DIR]   # DIR defaults to the current directory
```

The script is safe to re-run. It does three things in the given `native-agent-frontend` checkout or worktree:

1. It writes `vite.local.config.ts`, which wraps the committed `vite.config.ts` and adds https, the hostname and `allowedHosts`. The real config stays unchanged.
2. It adds that file to the repo's shared git exclude file (`$(git rev-parse --git-common-dir)/info/exclude`), so no worktree commits it.
3. It edits `.env.development`, copying it first from the `~/Projects` checkout or `.env.example` if it is missing. It empties `NEW_BACKEND_API_URL` and `REST_URL`, so every call goes through Vite's own proxy, and sets `WEBSITE_URL` and `AUTH_BRIDGE_URL` to `https://app.test2.testhireez.com`. Then it regenerates `public/env.js` from it.

Then it checks two one-time prerequisites and prints the commands for any that are missing:

- a `127.0.0.1 localhost.test2.testhireez.com` line in `/etc/hosts`
- the mkcert certificate pair `~/.certs/localhost.test2.testhireez.com.pem` and `-key.pem`

Don't run those commands yourself. Give them to the user: the `/etc/hosts` edit needs sudo, and `mkcert -install` adds a root certificate to the keychain.

Last, it prints the run commands with a free port (from 8083 up) and the htm-backend port from its `.env`.

### Running

Pick a free port per worktree, and always set `LOCAL_TB_BACKEND`. Without it, Vite sends `/tb-v2` to `127.0.0.1:9002`, which is the backend proxy.

Choose the target from what the task changes:

- **Frontend only.** The task changes `native-agent-frontend` and nothing in `htm-backend` or `native-agent-backend`. Point `/tb-v2` at test2 and start no local backend:

  ```bash
  LOCAL_TB_BACKEND=https://api.test2.testhireez.com npm run dev -- --config vite.local.config.ts --port 8084
  ```

- **Frontend and backend.** The task also changes `htm-backend` or `native-agent-backend`, for example a new or changed `/tb-v2` endpoint, or a frontend feature that waits on an unmerged backend branch. Point `/tb-v2` at the local htm-backend:

  ```bash
  # HTTP_PORT in htm-backend/.env, 9004 at the time of writing
  LOCAL_TB_BACKEND=http://127.0.0.1:9004 npm run dev -- --config vite.local.config.ts --port 8083
  ```

  The local htm-backend must be running on the branch with the change. Start it with the htm-backend command in "Startup commands", from the worktree directory if the change is in a worktree. If the change is in `native-agent-backend`, run that locally too with the native-agent-backend command, because htm-backend reaches it through `NATIVE_AGENT_BE_URL=http://127.0.0.1:8000` in its `.env`. A change only in `native-agent-backend` still needs the local htm-backend, since that is the only path from the frontend to it.

To decide, check the task description or ticket, and check whether the same ticket has a branch or uncommitted changes in `htm-backend` or `native-agent-backend` (`git -C ~/Projects/<repo> branch --list '*<TICKET>*'`, `git -C ~/Projects/<repo> status --short`). If it's still unclear, ask the user.

Use `npm run dev --`, not `npx vite`. The app reads its URLs from `public/env.js`, which `npm run dev` regenerates from `.env.development` before starting Vite. A bare `npx vite` serves a stale `env.js`, so the app keeps redirecting to `localhost:8081/login` even with the new `.env.development`. The setup script also regenerates it once.

The `--port` flag overrides the config's `strictPort: 8082`. Open `https://localhost.test2.testhireez.com:<port>/agent/`. Vite sends `/v1` and `/v2` to `api.test2.testhireez.com` itself, which is why the backend proxy isn't needed.

If the app redirects to the test2 login, the user signs in there. The test2 frontend may not redirect back to a local URL afterwards. In that case, open the local URL again; the session is already there.
