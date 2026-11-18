---
name: hireez-devstack
description: Start, stop, restart and inspect the HireEZ local stack (htm-backend, native-agent-backend, ez-profile-agent sidecar, native-agent-frontend) in a background tmux session that outlives the agent session, with each service pointed at local or test2 automatically. Use when asked to start a dev server, run the local stack, verify a change locally across repos, give a frontend link to test, restart or check a local service, or read its logs.
---

# HireEZ devstack

`devstack` runs each service in its own window of the tmux session `devstack`. The
services keep running after this conversation ends. Logs go to
`~/.hireez-dev/logs/<svc>.log`.

Background, the problems this solves, and the design choices:
`~/.hireez-dev/docs/local-dev-stack.md`.
For what each repo is and the manual commands, see the `hireez-local-dev` skill. This
skill does not replace it.

The command is `devstack` on the PATH (a link to `scripts/devstack` in this skill).

## Services

| svc | repo | port |
|---|---|---|
| `htm` | htm-backend | `HTTP_PORT` in its `.env` (9004) |
| `nab` | native-agent-backend | 8000 |
| `pa` | ez-profile-agent (sidecar MCP) | 8765 |
| `fe` | native-agent-frontend | 8084 |

## Commands

```bash
devstack doctor [svc...] [--ticket T]        # checks only, changes nothing
devstack up svc... [--ticket T] [--dir svc=PATH] [--memory] [--no-wait]
devstack status
devstack logs svc [-f] [-n 100] [--pretty [--no-color]]   # --pretty: JSON lines as colored time/level/message (jq)
devstack restart svc...
devstack down [svc...]                       # all when none named
```

- `--ticket T` runs each service from the worktree whose branch or directory name
  contains T. With none, the main checkout in `~/Projects`. When several match, the
  output lists them all; if the pick is wrong, run `up` again with `--dir svc=PATH`.
- `--memory` runs `pa` on its in-memory store instead of the test2 database.
- `up` waits for the ports (180s) and prints each service as up, FAILED (with the
  reason) or EXITED, then the frontend link.

## What to start

Start only what the change needs, plus whatever sits between it and the browser:

- frontend only: `fe` (talks to test2)
- htm-backend change: `htm fe`
- native-agent-backend change: `htm nab fe` (the frontend reaches nab only through htm)
- sidecar change: `htm nab pa fe`

Check which repos have a branch or changes for the ticket when it isn't clear:
`git -C ~/Projects/<repo> branch --list '*<TICKET>*'`, and `git worktree list`.

## What devstack sets for you

Do not edit these by hand. devstack sets them from which services run locally, and
restarts running services when that set changes (`up` or `down` of another service).

- `fe`: `LOCAL_TB_BACKEND` → local htm, else `https://api.test2.testhireez.com`.
- `htm`: `NATIVE_AGENT_BE_URL` → local nab, else test2. htm-backend ignores the process
  env for anything in its `.env`, so this one line is written into the checkout's
  `.env`. The original is kept as `.env.devstack-backup` and restored by `down htm`.
- `nab`: `EZ_PROFILE_MCP_URL` → local pa when it runs.
- `pa`: `NATIVE_AGENT_BACKEND_URL` → local nab when it runs.
- All but `fe` get `AWS_PROFILE=test2`, `AWS_SDK_LOAD_CONFIG=1`, `AWS_REGION=us-west-2`.

Fixed per-service overrides live in `~/.hireez-dev/env/<svc>.env` (the sidecar's
Secrets Manager paths and engine URLs are in `pa.env`). Edit those files, not the
generated `~/.hireez-dev/run/<svc>.sh`.

## When something fails

- `doctor` or `up` prints `FAIL` lines and the commands that fix them. Some need the
  user: `aws sso login --profile test2` opens a browser; the `/etc/hosts` line needs
  sudo; `mkcert -install` adds a root certificate. Give the user these commands; run
  `aws sso login` yourself only after the user agrees, since they must approve it in
  the browser.
- A service shown as FAILED keeps its window; read `devstack logs <svc>`, fix, then
  `devstack restart <svc>`.
- htm `Found N errors` right after start usually means stale `node_modules` (doctor
  warns when `package-lock.json` is newer) or a checkout far behind `origin/master`.
  Ask before running `npm ci` in the user's main checkout.
- A port taken by something devstack did not start: `up` refuses and shows the
  process; ask before killing it.

## Reporting to the user

After `up`, give the frontend link (`https://localhost.test2.testhireez.com:8084/agent/`),
which checkout each service runs from, and anything FAILED. Mention that
`tmux attach -t devstack` shows the live output. Leave the stack running unless the
user asks to stop it.

## Use from T3 Code

`devstack status --json` and `devstack doctor --json` print one JSON document for tools. The T3 Code services panel reads the status shape (`{"services": [{id, name, state, port, url, cwd, branch, detail, lastLog}]}`, state is `running`, `starting`, `failed` or `stopped`), so keep those field names.

Without `--ticket`, `up` and `doctor` take the ticket from the current directory: a ticket key in its path, then in its git branch. T3 actions run at the project root, so they pick the thread's worktrees with no arguments.

`~/.hireez-dev/t3-actions.json` holds ready-made T3 actions (Start stack opens the frontend in the in-app browser) and the services panel commands. Import the actions in T3 Code under Settings → Projects → actions, or copy the file's keys into a repo's `t3.json`.
