#!/usr/bin/env python3
"""Maintain the work log database (Notion Bases) in the Obsidian vault.

Each ticket-per-repo is a note in ~/Documents/Hireez/Work Log/Tickets/ whose frontmatter holds the row.

  worklog-sync.py                              Import my open Jira tickets that have no row yet (MY_TICKETS_JQL),
                                               then refresh every ongoing row:
                                                 summary, status <- Jira (status as a short name, via acli)
                                                 *_state       <- GitHub PR state (via gh)
                                                 done          <- master PR merge date, which moves the row to the Done view;
                                                                  for a row with no PRs, the day its Jira ticket reached Done
  worklog-sync.py add TICKET REPO "Change"     Create a row (or claim the imported repo-less `TICKET.md`), then sync it.
"""
import datetime
import json
import re
import subprocess
import sys
from pathlib import Path

WORK_LOG = Path.home() / "Documents/Hireez/Work Log"
TICKETS = WORK_LOG / "Tickets"
JIRA_BROWSE = "https://hiretual.atlassian.net/browse/"
FIELDS = ["summary", "jira", "status", "repo", "change", "develop_pr", "develop_state", "master_pr", "master_state", "done"]

# Open tickets where I'm the assignee, Engg Owner, an Involved Engineer or a Stakeholder.
MY_TICKETS_JQL = (
    '(assignee = currentUser() OR "Engg Owner" in (currentUser()) OR "Involved Engineer(s)" in (currentUser())'
    " OR Stakeholders in (currentUser())) AND statusCategory != Done"
)

PR_URL = re.compile(r"https://github\.com/([^/]+/[^/]+)/pull/(\d+)")
TICKET = re.compile(r"[A-Z][A-Z0-9]+-\d+")

# Jira status name (lowercased) -> short name. Unlisted statuses fall back to a slug of the name.
STATUS_NAMES = {
    "open": "Open",
    "backlog": "Backlog",
    "reopened": "Reopened",
    "ready for dev": "Ready",
    "dev in progress": "Dev",
    "developing": "Dev",
    "developing (dev)": "Dev",
    "test server (dev/qa)": "Test-QA",
    "test server(verifying)": "Test-Verify",
    "stage server (qa)": "Stage-QA",
    "prod server (qa)": "Prod-QA",
    "security review": "Security-Review",
    "approved to release": "Approved",
    "released & closed": "Released",
    "closed": "Closed",
    "done": "Done",
    "won't do": "Wont-Do",
}

CI_FAILED = {"FAILURE", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE", "ERROR"}


def read_note(path):
    """Return (frontmatter dict, body). Values are JSON-quoted strings or bare scalars."""
    text = path.read_text()
    m = re.match(r"---\n(.*?)\n---\n?", text, re.S)
    if not m:
        return {}, text
    props = {}
    for line in m.group(1).splitlines():
        key, sep, value = line.partition(":")
        if not sep:
            continue
        value = value.strip()
        if value.startswith('"'):
            value = json.loads(value)
        elif value.startswith("'"):
            value = value[1:-1].replace("''", "'")
        props[key.strip()] = value or None
    return props, text[m.end():]


def write_note(path, props, body):
    lines = [f"{k}: {json.dumps(props[k], ensure_ascii=False) if props.get(k) else ''}".rstrip() for k in FIELDS]
    lines += [f"{k}: {json.dumps(v, ensure_ascii=False)}" for k, v in props.items() if k not in FIELDS and v]
    path.write_text("---\n" + "\n".join(lines) + "\n---\n" + body)


def ticket_notes():
    # iterdir raises if the folder can't be read (e.g. macOS privacy block); glob would silently return nothing.
    return sorted(p for p in TICKETS.iterdir() if p.suffix == ".md")


def acli_json(*args):
    out = subprocess.run(["acli", "jira", "workitem", *args, "--json"], capture_output=True, text=True)
    if out.returncode != 0:
        print(f"  ! acli {' '.join(args)}: {out.stderr.strip() or out.stdout.strip()}")
        return None
    return json.loads(out.stdout)


def short_status(name):
    return STATUS_NAMES.get(name.lower(), re.sub(r"[^A-Za-z0-9]+", "-", name).strip("-"))


def jira_issue(ticket):
    """(summary, short status, status is in the Done category) or None."""
    issue = acli_json("view", ticket, "--fields", "summary,status")
    if not issue:
        return None
    status = issue["fields"]["status"]
    return issue["fields"]["summary"], short_status(status["name"]), status["statusCategory"]["key"] == "done"


def import_my_tickets():
    issues = acli_json("search", "--jql", MY_TICKETS_JQL, "--fields", "summary", "--paginate")
    known = {TICKET.match(p.stem).group() for p in ticket_notes() if TICKET.match(p.stem)}
    for issue in issues or []:
        if issue["key"] not in known:
            write_note(TICKETS / f"{issue['key']}.md", {"jira": JIRA_BROWSE + issue["key"]}, "")
            print(f"  + New: {issue['key']}")


def pr_info(url):
    m = PR_URL.search(url or "")
    if not m:
        return None
    repo, number = m.groups()
    out = subprocess.run(
        ["gh", "pr", "view", number, "-R", repo, "--json", "state,isDraft,reviewDecision,mergedAt,statusCheckRollup"],
        capture_output=True, text=True,
    )
    if out.returncode != 0:
        print(f"  ! {repo}#{number}: {out.stderr.strip()}")
        return None
    return json.loads(out.stdout)


def pr_state(info):
    """The single most important fact about a PR."""
    if info["state"] == "MERGED":
        return "Merged"
    if info["state"] == "CLOSED":
        return "Closed"
    if info["isDraft"]:
        return "Draft"
    checks = info.get("statusCheckRollup") or []
    if any((c.get("conclusion") or c.get("state")) in CI_FAILED for c in checks):
        return "CI failing"
    if info.get("reviewDecision") == "CHANGES_REQUESTED":
        return "Changes requested"
    if info.get("reviewDecision") == "APPROVED":
        return "Approved"
    return "Open"


def sync(path):
    props, body = read_note(path)
    if props.get("done"):
        return
    ticket = TICKET.search(props.get("jira") or path.stem)
    jira = jira_issue(ticket.group()) if ticket else None
    if jira:
        props["summary"], props["status"], jira_done = jira
        if jira_done and not props.get("develop_pr") and not props.get("master_pr"):
            props["done"] = datetime.date.today().isoformat()
            print(f"  → Done: {path.stem} (closed in Jira)")
    for kind in ("develop", "master"):
        info = pr_info(props.get(f"{kind}_pr"))
        if info:
            props[f"{kind}_state"] = pr_state(info)
            if kind == "master" and info["state"] == "MERGED":
                merged = datetime.datetime.fromisoformat(info["mergedAt"].replace("Z", "+00:00")).astimezone()
                props["done"] = merged.strftime("%Y-%m-%d")
                print(f"  → Done: {path.stem}")
    write_note(path, props, body)


def add(ticket, repo, change):
    path = TICKETS / f"{ticket} {repo}.md"
    if path.exists():
        sys.exit(f"{path} already exists")
    imported = TICKETS / f"{ticket}.md"
    props, body = read_note(imported) if imported.exists() else ({"jira": JIRA_BROWSE + ticket}, "")
    props.update(repo=repo, change=change)
    write_note(path, props, body)
    if imported.exists():
        imported.unlink()
    return path


def main():
    if sys.argv[1:2] == ["add"]:
        if len(sys.argv) != 5:
            sys.exit('usage: worklog-sync.py add TICKET REPO "Change"')
        sync(add(*sys.argv[2:]))
    else:
        import_my_tickets()
        for path in ticket_notes():
            sync(path)
    print(f"Synced {WORK_LOG}")


if __name__ == "__main__":
    main()
