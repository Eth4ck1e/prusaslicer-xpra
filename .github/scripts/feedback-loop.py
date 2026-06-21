#!/usr/bin/env python3
"""
Feedback loop for PR review re-request.

Triggered by .github/workflows/pr-review.yml after the review runs.
Reads the review result JSON (written by pr-review.py), checks PR labels
for retry count, and if changes are needed, manages the re-request lifecycle.

Environment:
  GITHUB_TOKEN        — GitHub token with pull-requests: write
  GITHUB_REPOSITORY   — "owner/repo"
  PR_NUMBER           — the pull request number
  MAX_RETRIES         — max fix-revision cycles before escalation (default 3)
  REVIEW_RESULT_FILE  — path to the review result JSON (default .github/review_result.json)

Label convention:
  review/retry-N      — N = 0, 1, 2, ... (current retry attempt number)
  review/retry-exhausted — all retries used, needs human intervention

Output:
  Writes feedback_result.json containing:
    {
      "feedback_action": "approved" | "re-request" | "escalated",
      "retry_count": int,
      "max_retries": int,
      "review_status": "changes_requested" | "approved" | "needs_review",
      "critical_count": int,
      "warning_count": int
    }
"""

import json
import os
import re
import sys
import urllib.error
import urllib.request
from typing import Optional

API_BASE = "https://api.github.com"

RETRY_LABEL_PREFIX = "review/retry-"
EXHAUSTED_LABEL = "review/retry-exhausted"

# ── helpers ────────────────────────────────────────────────────────────────

def gh_api(path: str, method: str = "GET", body: Optional[dict] = None) -> dict:
    token = os.environ.get("INPUT_GITHUB_TOKEN") or os.environ.get("GITHUB_TOKEN", "")
    url = f"{API_BASE}/{path.lstrip('/')}"
    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": "application/vnd.github.v3+json",
        "User-Agent": "prusaslicer-xpra-review-bot",
    }
    data = json.dumps(body).encode() if body else None
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        err_body = e.read().decode()
        print(f"❌ API error {e.code} on {method} {path}: {err_body}", file=sys.stderr)
        if e.code == 404:
            return {}
        raise


def post_pr_comment(repo: str, pr_number: int, body: str) -> bool:
    """Post a comment on the PR via the Issues API."""
    path = f"repos/{repo}/issues/{pr_number}/comments"
    result = gh_api(path, method="POST", body={"body": body})
    if result.get("id"):
        return True
    print(f"❌ Failed to post comment", file=sys.stderr)
    return False


def get_labels(repo: str, pr_number: int) -> list:
    """Get all labels on the PR/issue."""
    data = gh_api(f"repos/{repo}/issues/{pr_number}/labels")
    return [l["name"] for l in data] if data else []


def set_labels(repo: str, pr_number: int, labels: list) -> bool:
    """Replace all labels on the PR/issue."""
    path = f"repos/{repo}/issues/{pr_number}/labels"
    result = gh_api(path, method="PUT", body={"labels": labels})
    if result or result == []:
        # PUT /labels returns the list of labels, or empty list on success
        return True
    print(f"❌ Failed to set labels", file=sys.stderr)
    return False


def get_current_retry(labels: list) -> int:
    """Read the current retry count from labels."""
    for label in labels:
        m = re.match(rf"^{re.escape(RETRY_LABEL_PREFIX)}(\d+)$", label)
        if m:
            return int(m.group(1))
    return -1  # no retry label found


def build_re_request_comment(
    critical_findings: list,
    warning_findings: list,
    retry_number: int,
    max_retries: int,
) -> str:
    """Build a structured re-request comment for the fix agent."""
    lines = []
    lines.append("## 🔄 Fix Revision Requested")
    lines.append("")
    lines.append(
        f"_The automated review found issues that need to be addressed. "
        f"This is re-request **{retry_number + 1}/{max_retries}**._"
    )
    lines.append("")

    if critical_findings:
        lines.append("### 🔴 Critical Issues to Fix")
        for f in critical_findings:
            loc = f"{f.get('file_path', '(diff)')}:{f.get('line', 0)}" if f.get('line') else f.get('file_path', '(diff)')
            lines.append(f"- **{loc}** — {f.get('message', '')}.")
            if f.get('suggestion'):
                lines.append(f"  > Suggestion: {f['suggestion']}")

    if warning_findings:
        lines.append("### ⚠️ Warnings to Address")
        for f in warning_findings:
            loc = f"{f.get('file_path', '(diff)')}:{f.get('line', 0)}" if f.get('line') else f.get('file_path', '(diff)')
            lines.append(f"- **{loc}** — {f.get('message', '')}.")
            if f.get('suggestion'):
                lines.append(f"  > Suggestion: {f['suggestion']}")

    lines.append("")
    lines.append("---")
    lines.append(
        "*To proceed: push new commits to the PR branch. "
        "The review will re-run automatically on `synchronize`.*"
    )

    return "\n".join(lines)


def build_escalation_comment(
    critical_findings: list,
    warning_findings: list,
    retry_number: int,
    max_retries: int,
) -> str:
    """Build an escalation comment when retries are exhausted."""
    lines = []
    lines.append("## ⛔ Retries Exhausted — Human Review Required")
    lines.append("")
    lines.append(
        f"_The automated review has requested changes **{retry_number + 1}** times "
        f"(max {max_retries}) and the issues remain unresolved._"
    )
    lines.append("")
    lines.append("### Remaining Issues")
    for f in critical_findings + warning_findings:
        sev = "🔴" if f.get("severity") == "critical" else "⚠️"
        loc = f"{f.get('file_path', '(diff)')}:{f.get('line', 0)}" if f.get('line') else f.get('file_path', '(diff)')
        lines.append(f"- {sev} **{loc}** — {f.get('message', '')}.")
    lines.append("")
    lines.append("### Next Steps")
    lines.append("- A human reviewer should address the remaining issues.")
    lines.append("- Once resolved, remove the `review/retry-exhausted` label to re-trigger the review.")
    lines.append("")
    lines.append("---")
    lines.append("*Escalated by automated review feedback loop.*")

    return "\n".join(lines)


# ── main ───────────────────────────────────────────────────────────────────

def main():
    repo = os.environ.get("GITHUB_REPOSITORY", "")
    pr_number_str = os.environ.get("PR_NUMBER", "")
    max_retries = int(os.environ.get("MAX_RETRIES", "3"))
    result_file = os.environ.get("REVIEW_RESULT_FILE", ".github/review_result.json")

    if not repo or not pr_number_str:
        print("❌ GITHUB_REPOSITORY and PR_NUMBER are required", file=sys.stderr)
        sys.exit(1)

    pr_number = int(pr_number_str)

    # 1. Read the review result
    if not os.path.exists(result_file):
        print(f"❌ Review result file not found: {result_file}", file=sys.stderr)
        print("  (pr-review.py must run first and write the review result)")
        sys.exit(1)

    with open(result_file) as f:
        review_result = json.load(f)

    critical_findings = review_result.get("findings", [])
    warning_findings = [f for f in critical_findings if f.get("severity") == "warning"]
    critical_findings_only = [f for f in critical_findings if f.get("severity") == "critical"]
    review_status = review_result.get("review_status", "approved")
    critical_count = review_result.get("critical_count", 0)
    warning_count = review_result.get("warning_count", 0)

    print(f"📋 Review status: {review_status}")
    print(f"  Critical: {critical_count}, Warnings: {warning_count}")

    # 2. Check if changes are actually requested
    changes_needed = (critical_count > 0) or (warning_count > 0)

    if not changes_needed:
        # Approved — nothing to do
        result = {
            "feedback_action": "approved",
            "retry_count": 0,
            "max_retries": max_retries,
            "review_status": review_status,
            "critical_count": critical_count,
            "warning_count": warning_count,
        }
        with open(".github/feedback_result.json", "w") as f:
            json.dump(result, f)
        print(f"✅ Review approved — no re-request needed.")
        return

    # 3. Read current labels and determine retry count
    current_labels = get_labels(repo, pr_number)
    print(f"  Current labels: {current_labels}")

    # Check if already exhausted
    if EXHAUSTED_LABEL in current_labels:
        print(f"⛔ Retries already exhausted for PR #{pr_number}")
        result = {
            "feedback_action": "escalated",
            "retry_count": max_retries,
            "max_retries": max_retries,
            "review_status": review_status,
            "critical_count": critical_count,
            "warning_count": warning_count,
        }
        with open(".github/feedback_result.json", "w") as f:
            json.dump(result, f)
        return

    current_retry = get_current_retry(current_labels)
    next_retry = current_retry + 1

    print(f"  Current retry: {current_retry}, Next retry: {next_retry}")

    # 4. Build new label set
    new_labels = [l for l in current_labels if not re.match(rf"^{re.escape(RETRY_LABEL_PREFIX)}\d+$", l)]

    if next_retry >= max_retries:
        # Exhausted — add exhaustion label
        new_labels.append(EXHAUSTED_LABEL)
        set_labels(repo, pr_number, new_labels)
        print(f"⛔ Retries exhausted ({next_retry}/{max_retries}) — added {EXHAUSTED_LABEL} label")

        comment = build_escalation_comment(
            critical_findings_only,
            warning_findings,
            next_retry,
            max_retries,
        )
        post_pr_comment(repo, pr_number, comment)

        result = {
            "feedback_action": "escalated",
            "retry_count": next_retry,
            "max_retries": max_retries,
            "review_status": review_status,
            "critical_count": critical_count,
            "warning_count": warning_count,
        }
    else:
        # Re-request fix
        new_labels.append(f"{RETRY_LABEL_PREFIX}{next_retry}")
        set_labels(repo, pr_number, new_labels)
        print(f"🔄 Re-request {next_retry}/{max_retries} — added {RETRY_LABEL_PREFIX}{next_retry} label")

        comment = build_re_request_comment(
            critical_findings_only,
            warning_findings,
            next_retry,
            max_retries,
        )
        post_pr_comment(repo, pr_number, comment)

        result = {
            "feedback_action": "re-request",
            "retry_count": next_retry,
            "max_retries": max_retries,
            "review_status": review_status,
            "critical_count": critical_count,
            "warning_count": warning_count,
        }

    # Write result
    with open(".github/feedback_result.json", "w") as f:
        json.dump(result, f)

    print(f"📝 Feedback result: {json.dumps(result)}")


if __name__ == "__main__":
    main()