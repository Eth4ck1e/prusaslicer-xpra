#!/usr/bin/env python3
"""
PR → Issue & Kanban Task Linker

Parses a PR body for issue references (#N), keyword refs (Fixes/Closes/Resolves #N),
and kanban task IDs (t_xxxxx). On PR open/close/merge it:

  1. Posts a comment on each referenced GitHub issue linking back to the PR.
  2. Adds/removes labels (in-review, merged, closed) on the linked issue.
  3. Emits a structured KANBAN_EVENT line for downstream (Hermes cron) consumers.

Usage from GitHub Actions:
  python3 .github/scripts/pr-link.py

Environment variables (set by GITHUB_TOKEN + the workflow):
  GITHUB_TOKEN       — GitHub API token (secrets.GITHUB_TOKEN)
  GITHUB_REPOSITORY  — owner/repo (e.g. Eth4ck1e/prusaslicer-xpra)
  PR_NUMBER          — pull request number
  PR_ACTION          — opened | closed | reopened | synchronize
  PR_TITLE           — pull request title
  PR_BODY            — pull request body
  PR_URL             — pull request HTML URL
"""

import json
import os
import re
import sys
from urllib.error import HTTPError
from urllib.request import Request, urlopen

GITHUB_API = os.environ.get("GITHUB_API_URL", "https://api.github.com")
REPO = os.environ.get("GITHUB_REPOSITORY", "")
TOKEN = os.environ.get("GITHUB_TOKEN", "")

# ── API helper ──────────────────────────────────────────────────────────────


def api_call(method, path, data=None):
    """Make a GitHub REST API call and return the parsed JSON response."""
    if not REPO:
        sys.exit(1)
    url = f"{GITHUB_API}/repos/{REPO}{path}"
    headers = {
        "Authorization": f"Bearer {TOKEN}",
        "Accept": "application/vnd.github.v3+json",
        "User-Agent": "pr-link-script",
    }
    body = None
    if data is not None:
        headers["Content-Type"] = "application/json"
        body = json.dumps(data).encode("utf-8")

    req = Request(url, data=body, headers=headers, method=method)
    try:
        with urlopen(req) as resp:
            raw = resp.read().decode("utf-8")
            return json.loads(raw) if raw else None
    except HTTPError as e:
        err_body = e.read().decode("utf-8")
        print(f"  ⚠ API error {e.code} on {method} {path}: {err_body}",
              file=sys.stderr)
        return None


# ── Parsing ─────────────────────────────────────────────────────────────────


def parse_issue_refs(body: str) -> set:
    """Parse GitHub issue references from a PR body.

    Matches both keyword-prefixed (Fixes #5, Closes #5, Related to #5)
    and bare (#5) references.  Returns a set of issue numbers.
    """
    refs: set = set()
    if not body:
        return refs

    # Keyword-prefixed patterns: "Fixes #5", "Closes #5", "Resolves #5",
    # "Related to #5", "See #5", "Ref #5", "Refs #5"
    for m in re.finditer(
        r"(?:Fixes|Closes|Resolves|Related\s+to|See|Refs?)\s+#(\d+)",
        body,
        re.IGNORECASE,
    ):
        refs.add(int(m.group(1)))

    # Standalone #N references (not part of a longer word like C#8, #yolo)
    for m in re.finditer(r"(?<!\w|/|x|X)#(\d+)", body):
        refs.add(int(m.group(1)))

    return refs


def parse_kanban_refs(body: str) -> list:
    """Parse Hermes kanban task references (t_xxxxx) from a PR body."""
    if not body:
        return []
    return sorted(set(re.findall(r"t_[a-f0-9]+", body)))


# ── Actions ─────────────────────────────────────────────────────────────────


def post_issue_comment(issue_number: int, pr_number: int,
                       action: str, pr_title: str, pr_url: str) -> None:
    """Post a comment on the referenced issue linking back to the PR."""
    templates = {
        "opened": (
            f"🔄 **PR #{pr_number} opened** — [{pr_title}]({pr_url})\n\n"
            f"This pull request references this issue. "
            f"Track progress and review the diff on the PR page."
        ),
        "reopened": (
            f"🔄 **PR #{pr_number} re-opened** — [{pr_title}]({pr_url})\n\n"
            f"The associated pull request has been re-opened for further work."
        ),
        "merged": (
            f"🚀 **PR #{pr_number} merged** — [{pr_title}]({pr_url})\n\n"
            f"The associated pull request has been merged. "
            f"Changes are now on the target branch."
        ),
        "closed": (
            f"❌ **PR #{pr_number} closed (unmerged)** — "
            f"[{pr_title}]({pr_url})\n\n"
            f"The associated pull request was closed without merging."
        ),
    }

    body = templates.get(action)
    if not body:
        print(f"  ℹ No comment template for action '{action}' — skipping")
        return

    result = api_call("POST", f"/issues/{issue_number}/comments",
                      {"body": body})
    if result and result.get("id"):
        print(f"  ✅ Comment posted on issue #{issue_number} "
              f"(pr #{pr_number}, {action})")
    else:
        print(f"  ❌ Failed to post comment on issue #{issue_number}",
              file=sys.stderr)


def update_labels(issue_number: int, action: str) -> None:
    """Add/remove lifecycle labels on the referenced issue.

    Label conventions used:
      - ``in-review``  — PR is open, under review
      - ``merged``     — PR was merged
      - ``closed``     — PR was closed without merging
    """
    label_map = {
        "opened":   ("in-review", ["merged", "closed"]),
        "reopened": ("in-review", ["merged", "closed"]),
        "merged":   ("merged",    ["in-review", "closed"]),
        "closed":   ("closed",    ["in-review", "merged"]),
    }

    to_add, to_remove = label_map.get(action, (None, []))

    if to_add:
        result = api_call("POST", f"/issues/{issue_number}/labels",
                          {"labels": [to_add]})
        if result is not None:
            print(f"  ✅ Added label '{to_add}' to issue #{issue_number}")

    for label in to_remove:
        result = api_call("DELETE",
                          f"/issues/{issue_number}/labels/{label}")
        if result is not None:
            print(f"  ✅ Removed label '{label}' from issue #{issue_number}")
        # 404 is OK — label simply didn't exist


def emit_kanban_event(pr_number: int, action: str,
                      kanban_refs: list) -> None:
    """Emit a structured JSON line for downstream kanban consumers.

    A Hermes cron job or webhook listener can grep workflow run logs
    for ``KANBAN_EVENT:`` lines and use the JSON payload to update the
    actual kanban board (moving tasks to 'in-review', 'done', etc.).
    """
    if not kanban_refs:
        return

    event = {
        "event": "pr_link",
        "pr_number": pr_number,
        "pr_action": action,
        "kanban_task_ids": kanban_refs,
        "repository": REPO,
    }
    # Write to stderr so it doesn't mix with stdout (which may be
    # captured by the workflow step).
    print(f"KANBAN_EVENT: {json.dumps(event)}", file=sys.stderr)
    print(f"  📋 Kanban task(s) referenced: {', '.join(kanban_refs)}")


# ── PR state helpers ────────────────────────────────────────────────────────


def is_merged(pr_number: int) -> bool:
    """Check whether a PR was actually merged (vs closed unmerged)."""
    data = api_call("GET", f"/pulls/{pr_number}")
    return bool(data and data.get("merged"))


# ── Main ────────────────────────────────────────────────────────────────────


def main() -> None:
    token = os.environ.get("GITHUB_TOKEN", "")
    repo = os.environ.get("GITHUB_REPOSITORY", "")

    if not token:
        print("❌ GITHUB_TOKEN environment variable not set", file=sys.stderr)
        sys.exit(1)
    if not repo:
        print("❌ GITHUB_REPOSITORY environment variable not set",
              file=sys.stderr)
        sys.exit(1)

    # Override module globals so api_call() uses test values
    global TOKEN, REPO
    TOKEN = token
    REPO = repo

    pr_number = int(os.environ.get("PR_NUMBER", "0"))
    pr_action = os.environ.get("PR_ACTION", "").lower()
    pr_title = os.environ.get("PR_TITLE", "")
    pr_body = os.environ.get("PR_BODY", "{}")  # toJSON-wrapped
    pr_url = os.environ.get("PR_URL", "")

    if not pr_number:
        print("❌ PR_NUMBER environment variable not set", file=sys.stderr)
        sys.exit(1)
    if pr_action not in ("opened", "closed", "reopened"):
        print(f"ℹ Skipping unhandled action '{pr_action}'")
        return

    # Unwrap toJSON'd body (GitHub wraps in JSON string with quotes)
    if pr_body.startswith('"') and pr_body.endswith('"'):
        try:
            pr_body = json.loads(pr_body)
        except json.JSONDecodeError:
            pass  # fall through with raw body

    # Only these actions trigger linking
    effective_action = pr_action
    if pr_action == "closed":
        effective_action = "merged" if is_merged(pr_number) else "closed"

    issue_refs = parse_issue_refs(pr_body)
    kanban_refs = parse_kanban_refs(pr_body)

    print(f"\n{'='*60}")
    print(f"📋 PR #{pr_number} ({effective_action}): {pr_title}")
    print(f"   URL: {pr_url}")
    print(f"   Issue refs found: {issue_refs or 'none'}")
    print(f"   Kanban refs found: {kanban_refs or 'none'}")

    # ── Link to GitHub issues ──
    for issue_num in sorted(issue_refs):
        if effective_action in ("opened", "reopened", "merged", "closed"):
            post_issue_comment(issue_num, pr_number,
                               effective_action, pr_title, pr_url)
            update_labels(issue_num, effective_action)

    # ── Kanban bridge ──
    emit_kanban_event(pr_number, effective_action, kanban_refs)

    if not issue_refs and not kanban_refs:
        print("ℹ️  No issue or kanban references found in PR body — "
              "nothing to link.")
    else:
        print(f"\n✅ PR → issue linking complete for PR #{pr_number}")


if __name__ == "__main__":
    main()
