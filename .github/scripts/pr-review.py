#!/usr/bin/env python3
"""
Automated PR review script for prusaslicer-xpra.

Triggered by .github/workflows/pr-review.yml on pull_request_target.
Fetches the PR diff, runs the C++/C/CMake code review checklist, and
posts a structured review comment on the PR.

Environment variables:
  GITHUB_TOKEN      — GitHub token with pull request write access
  GITHUB_REPOSITORY — "owner/repo"
  PR_NUMBER         — the pull request number
  INPUT_GITHUB_TOKEN — alternative source (GitHub Actions sets both)

Usage (local test):
  GITHUB_TOKEN=ghp_xxx GITHUB_REPOSITORY=owner/repo PR_NUMBER=123 ./pr-review.py

In GitHub Actions, the workflow must have:
  permissions:
    pull-requests: write
    contents: read
"""

import json
import os
import re
import sys
import urllib.error
import urllib.request
from typing import Optional

API_BASE = "https://api.github.com"

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


def gh_api_paginated(path: str) -> list:
    """Fetch all pages of a paginated GET endpoint."""
    items = []
    page = 1
    while True:
        sep = "&" if "?" in path else "?"
        data = gh_api(f"{path}{sep}per_page=100&page={page}")
        if not data:
            break
        items.extend(data)
        if len(data) < 100:
            break
        page += 1
    return items


def get_pr_diff(repo: str, pr_number: int) -> str:
    """Fetch the PR diff as a unified diff string."""
    token = os.environ.get("INPUT_GITHUB_TOKEN") or os.environ.get("GITHUB_TOKEN", "")
    url = f"{API_BASE}/repos/{repo}/pulls/{pr_number}"
    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": "application/vnd.github.v3.diff",
        "User-Agent": "prusaslicer-xpra-review-bot",
    }
    req = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(req) as resp:
            return resp.read().decode()
    except urllib.error.HTTPError as e:
        print(f"❌ Failed to fetch diff: {e}", file=sys.stderr)
        return ""


def language_for_file(path: str) -> str:
    """Classify a file by its extension for checklist routing."""
    if path.endswith((".cpp", ".cc", ".cxx", ".h", ".hpp", ".hh", ".hxx")):
        return "cpp"
    if path.endswith((".c",)):
        return "c"
    if path.endswith(("CMakeLists.txt",)) or path.endswith(".cmake"):
        return "cmake"
    if "CMakeLists.txt" in path:
        return "cmake"
    if "Dockerfile" in path or path.endswith(".dockerfile"):
        return "docker"
    if path.endswith((".py",)):
        return "python"
    if path.endswith((".yml", ".yaml")):
        return "yaml"
    if path.endswith((".sh", ".bash")):
        return "shell"
    return "other"


# ── finding types ──────────────────────────────────────────────────────────

class Finding:
    def __init__(self, severity: str, file_path: str, line: int, message: str, suggestion: str = ""):
        self.severity = severity  # "critical" | "warning" | "suggestion"
        self.file_path = file_path
        self.line = line
        self.message = message
        self.suggestion = suggestion

    def __repr__(self):
        return f"[{self.severity.upper()}] {self.file_path}:{self.line} — {self.message}"


# ── check runners ──────────────────────────────────────────────────────────

def run_cpp_checks(diff_lines: list, changed_files: list) -> list:
    """Run C++-specific automated checks on the diff and files."""
    findings = []
    added_lines = [l for l in diff_lines if l.startswith("+")]

    # raw new/delete
    for i, line in enumerate(added_lines):
        # match 'new' keyword (not in comments/strings)
        if re.search(r'\bnew\b', line) and not re.search(r'//.*\bnew\b', line):
            # heuristic: flag unless it's std::make_unique/shared
            if not re.search(r'make_unique|make_shared', line):
                findings.append(Finding(
                    "warning", "(diff)", i + 1,
                    "Raw `new` detected — prefer `std::make_unique` or `std::make_shared`",
                    "Replace with `auto ptr = std::make_unique<T>(args...)`"
                ))

        if re.search(r'\bdelete\b', line) and not re.search(r'//.*\bdelete\b', line):
            findings.append(Finding(
                "warning", "(diff)", i + 1,
                "Raw `delete` detected — use RAII smart pointers instead"
            ))

    # C-style casts
    for i, line in enumerate(added_lines):
        if re.search(r'\([a-zA-Z_]\w*\*?\)\w', line) and not re.search(r'//.*\(.*\)\w', line):
            if not re.search(r'dynamic_cast|static_cast|const_cast|reinterpret_cast', line):
                findings.append(Finding(
                    "suggestion", "(diff)", i + 1,
                    "C-style cast detected — use C++ casts (`static_cast`/`dynamic_cast`)",
                    "Replace `(type)expr` with `static_cast<type>(expr)`"
                ))

    # NULL vs nullptr
    for i, line in enumerate(added_lines):
        if re.search(r'\bNULL\b', line):
            findings.append(Finding(
                "suggestion", "(diff)", i + 1,
                "`NULL` used — prefer `nullptr` in C++ code"
            ))

    # auto_ptr
    for i, line in enumerate(added_lines):
        if re.search(r'auto_ptr', line):
            findings.append(Finding(
                "critical", "(diff)", i + 1,
                "`std::auto_ptr` is removed in C++17 — replace with `std::unique_ptr`",
                "Replace with `std::unique_ptr<T>`"
            ))

    # dynamic exception specifications
    for i, line in enumerate(added_lines):
        if re.search(r'throw\(', line):
            findings.append(Finding(
                "warning", "(diff)", i + 1,
                "Dynamic exception specification `throw(...)` is deprecated/removed — use `noexcept`",
                "Replace with `noexcept` or `noexcept(false)`"
            ))

    # template definition not in header (possible ODR violation)
    for f in changed_files:
        if f.endswith(".cpp") or f.endswith(".cc"):
            findings.append(Finding(
                "suggestion", f, 0,
                "Template definitions in .cpp files — ensure they're not causing ODR violations",
                "Move templates to headers or use explicit instantiation"
            ))

    return findings


def run_c_checks(diff_lines: list, changed_files: list) -> list:
    """Run C-specific automated checks."""
    findings = []
    added_lines = [l for l in diff_lines if l.startswith("+")]

    dangerous_funcs = {
        r'\bstrcpy\b': ("strcpy is unbounded and can overflow the destination buffer",
                         "Use `strncpy` or `strlcpy` with explicit length check"),
        r'\bstrcat\b': ("strcat is unbounded",
                         "Use `strncat` with explicit size limit"),
        r'\bsprintf\b': ("sprintf is unbounded and can overflow",
                          "Use `snprintf` with buffer size"),
        r'\bgets\b': ("gets() is impossible to use safely — banned outright",
                      "Remove or replace with `fgets`"),
    }

    for i, line in enumerate(added_lines):
        for pat, (msg, sug) in dangerous_funcs.items():
            if re.search(pat, line):
                findings.append(Finding("critical", "(diff)", i + 1, msg, sug))

    # unchecked malloc/calloc/realloc
    for i, line in enumerate(added_lines):
        if re.search(r'=\s*(malloc|calloc|realloc)\(', line):
            # check if next line has NULL check
            if i + 1 >= len(added_lines) or not re.search(r'NULL|==\s*0|!\s*\w', added_lines[i + 1]):
                findings.append(Finding(
                    "warning", "(diff)", i + 1,
                    f"Return value of `{'malloc' if 'malloc' in line else 'calloc' if 'calloc' in line else 'realloc'}` not checked for NULL",
                    "Add `if (!ptr) { /* handle error */ }`"
                ))

    # format string vulnerability
    for i, line in enumerate(added_lines):
        if re.search(r'printf\([^"%]', line):
            findings.append(Finding(
                "critical", "(diff)", i + 1,
                "Possible format string vulnerability — `printf` with non-constant format string",
                "Use `printf(\"%s\", var)` instead of `printf(var)`"
            ))

    return findings


def run_security_checks(diff_lines: list, changed_files: list) -> list:
    """Run security-specific automated checks."""
    findings = []
    added_lines = [l for l in diff_lines if l.startswith("+")]

    for i, line in enumerate(added_lines):
        # system/popen/exec with variable args
        if re.search(r'(system|popen|exec[lvpe]*)\s*\(', line):
            # check if argument is a string literal or variable
            if not re.search(r'system\s*\(\s*"', line):
                findings.append(Finding(
                    "critical", "(diff)", i + 1,
                    "`system()`/`popen()`/`exec*()` with non-literal argument — possible command injection",
                    "Validate/sanitize the argument or use `execvpe` with explicit argv"
                ))

        # hardcoded secrets heuristic
        if re.search(r'(password|passwd|api_key|API_KEY|secret)\s*=\s*["\'][^"\']+["\']', line, re.IGNORECASE):
            findings.append(Finding(
                "critical", "(diff)", i + 1,
                "Possible hardcoded credential — secrets must come from environment or secrets manager",
                "Use environment variables or a secrets vault"
            ))

        # SQL injection
        if re.search(r'sqlite3_exec|sqlite3_prepare\b', line):
            if re.search(r'\+|append|printf|sprintf', line):
                findings.append(Finding(
                    "critical", "(diff)", i + 1,
                    "Possible SQL injection — SQL query constructed with string concatenation",
                    "Use `sqlite3_prepare_v2` with parameterized queries"
                ))

        # unsafe PRNG
        if re.search(r'\brand\(\b', line):
            findings.append(Finding(
                "warning", "(diff)", i + 1,
                "`rand()` used — not cryptographically secure",
                "Use `/dev/urandom`, `getrandom()`, or proper CSPRNG"
            ))

    return findings


def run_xpra_checks(diff_lines: list, changed_files: list) -> list:
    """Run xpra/X11-specific automated checks."""
    findings = []
    xpra_diffs = [l for l in diff_lines if l.startswith("+")]

    for i, line in enumerate(xpra_diffs):
        # socket without timeout
        if re.search(r'(connect|accept|read|write|send|recv)\s*\(', line):
            if not re.search(r'timeout|TV_|select|poll|epoll|kqueue|SO_RCVTIMEO|SO_SNDTIMEO', line):
                findings.append(Finding(
                    "warning", "(diff)", i + 1,
                    "Network I/O without visible timeout — xpra socket operations can hang",
                    "Set socket timeout or use non-blocking + poll/select"
                ))

    # Check for X11-specific files that might need error handlers
    for f in changed_files:
        if "x11" in f.lower() or "xpra" in f.lower() or "display" in f.lower():
            findings.append(Finding(
                "suggestion", f, 0,
                "X11-related file changed — verify XSetErrorHandler is installed and socket timeouts are set",
                "Check §9 of the code review checklist"
            ))

    return findings


def run_build_checks(changed_files: list, repo: str, pr_number: int) -> list:
    """Run build system checks — new .cpp files not in CMakeLists.txt."""
    findings = []
    new_cpp = [f for f in changed_files if f.endswith(".cpp") and "/" in f]
    cmake_files = [f for f in changed_files if "CMakeLists.txt" in f or f.endswith(".cmake")]

    for cpp_file in new_cpp:
        base = cpp_file.split("/")[-1]
        # Check if the CMakeLists.txt in the same directory mentions it
        dir_part = "/".join(cpp_file.split("/")[:-1])
        cmake_path = f"{dir_part}/CMakeLists.txt"

        # We can't read arbitrary files from other PRs easily via API in this script,
        # but we can make a suggestion
        if not any(base in f for f in cmake_files):
            findings.append(Finding(
                "warning", cpp_file, 0,
                f"New C++ file `{base}` — verify it's added to the corresponding CMakeLists.txt",
                "Add to the `target_sources` or `add_library` in the relevant CMakeLists.txt"
            ))

    return findings


def run_quality_checks(diff_lines: list) -> list:
    """Run general code quality automated checks."""
    findings = []

    todo_count = 0
    for i, line in enumerate(diff_lines):
        if line.startswith("+") and re.search(r'TODO|FIXME|HACK|XXX', line, re.IGNORECASE):
            findings.append(Finding(
                "warning", "(diff)", i + 1,
                f"`{re.search(r'TODO|FIXME|HACK|XXX', line, re.IGNORECASE).group()}` found in added code",
                "File an issue instead of leaving TODOs in committed code"
            ))
            todo_count += 1

    # trailing whitespace in added lines
    for i, line in enumerate(diff_lines):
        if line.startswith("+") and re.search(r'[ \t]+$', line):
            findings.append(Finding(
                "suggestion", "(diff)", i + 1,
                "Trailing whitespace detected",
                "Strip trailing whitespace"
            ))

    return findings


def run_docker_checks(diff_lines: list, changed_files: list) -> list:
    """Run Dockerfile-specific checks."""
    findings = []
    docker_files = [f for f in changed_files if "Dockerfile" in f]

    if not docker_files:
        return findings

    for f in docker_files:
        # Check for security concerns — we can't read the file easily here,
        # but flag that Dockerfiles changed for a manual review note
        findings.append(Finding(
            "suggestion", f, 0,
            "Dockerfile changed — review for security best practices",
            "Check: pinned base image tags, no COPY of secrets, no ADD of remote URLs"
        ))

    return findings


# ── report generation ──────────────────────────────────────────────────────

def generate_comment(findings: list, diff_stat: str, pr_title: str, pr_author: str,
                     changed_files: list, additions: int, deletions: int) -> str:
    """Generate a structured Markdown review comment."""
    criticals = [f for f in findings if f.severity == "critical"]
    warnings = [f for f in findings if f.severity == "warning"]
    suggestions = [f for f in findings if f.severity == "suggestion"]

    # Deduplicate findings that are very close (same message, same file, similar line)
    seen = set()
    def dedup(f):
        key = (f.message[:60], f.file_path, f.severity)
        if key in seen:
            return False
        seen.add(key)
        return True
    criticals = [f for f in criticals if dedup(f)]
    # Reset seen for other categories
    seen.clear()
    warnings = [f for f in warnings if dedup(f)]
    seen.clear()
    suggestions = [f for f in suggestions if dedup(f)]

    total = len(criticals) + len(warnings) + len(suggestions)

    # Verdict
    if criticals:
        verdict = "Changes Requested 🔴"
    elif warnings:
        verdict = "Changes Requested ⚠️"
    elif suggestions:
        verdict = "Reviewed 💬"
    else:
        verdict = "Approved ✅"

    lines = []
    lines.append(f"## Code Review Summary\n")
    lines.append(f"**Verdict: {verdict}** ({total} findings)\n")
    lines.append(f"**PR:** #{os.environ.get('PR_NUMBER', '?')} — {pr_title}")
    lines.append(f"**Author:** @{pr_author}")
    lines.append(f"**Files changed:** {len(changed_files)} (+{additions} -{deletions})")
    lines.append("")
    lines.append("> _Automated review based on the [cpp-cmake-code-review-checklist](https://github.com/Eth4ck1e/prusaslicer-xpra/tree/main/.github/checklist) criteria._\n")

    if criticals:
        lines.append("### 🔴 Critical")
        lines.append("_Issues that MUST be fixed before merge_\n")
        for f in criticals:
            loc = f"{f.file_path}:{f.line}" if f.line else f.file_path
            lines.append(f"- **{loc}** — {f.message}.")
            if f.suggestion:
                lines.append(f"  > Suggestion: {f.suggestion}")
        lines.append("")

    if warnings:
        lines.append("### ⚠️ Warnings")
        lines.append("_Issues that SHOULD be fixed_\n")
        for f in warnings:
            loc = f"{f.file_path}:{f.line}" if f.line else f.file_path
            lines.append(f"- **{loc}** — {f.message}.")
            if f.suggestion:
                lines.append(f"  > Suggestion: {f.suggestion}")
        lines.append("")

    if suggestions:
        lines.append("### 💡 Suggestions")
        lines.append("_Non-blocking improvements_\n")
        for f in suggestions:
            loc = f"{f.file_path}:{f.line}" if f.line else f.file_path
            lines.append(f"- **{loc}** — {f.message}.")
            if f.suggestion:
                lines.append(f"  > Suggestion: {f.suggestion}")
        lines.append("")

    if not findings:
        lines.append("### ✅ Looks Good")
        lines.append("- No automated issues detected. Code follows best practices.\n")

    # Add a checkbox summary
    lines.append("### 📊 Checklist Coverage")
    lines.append(f"- C++ correctness checks: {'🟢 run' if any('cpp' in str(f).lower() for f in findings) else '🟢 clean'}")
    lines.append(f"- C/correctness checks: {'🟢 run' if any('c' in str(f).lower() for f in findings) else '🟢 clean'}")
    lines.append(f"- Security checks: {'🟢 run' if any('security' in str(f).lower() for f in findings) else '🟢 clean'}")
    lines.append(f"- xpra/X11 checks: {'🟢 run' if any('xpra' in str(f).lower() or 'x11' in str(f).lower() for f in findings) else '🟢 clean'}")
    lines.append(f"- Build system checks: {'🟢 run' if any('cmake' in str(f).lower() or 'build' in str(f).lower() for f in findings) else '🟢 clean'}")
    lines.append(f"- Code quality checks: {'🔴 needs review' if todo_count_in(findings) > 0 else '🟢 clean'}")
    lines.append("")

    lines.append("---")
    lines.append("*Reviewed by [bugbot](https://github.com/Eth4ck1e/prusaslicer-xpra) · Powered by the cpp-cmake-code-review-checklist*")

    return "\n".join(lines)


def todo_count_in(findings: list) -> int:
    return sum(1 for f in findings if "TODO" in f.message or "FIXME" in f.message)


def serialize_findings(findings: list) -> list:
    """Serialize Finding objects to plain dicts for JSON output."""
    return [
        {
            "severity": f.severity,
            "file_path": f.file_path,
            "line": f.line,
            "message": f.message,
            "suggestion": f.suggestion,
        }
        for f in findings
    ]


def write_review_result(findings: list, verdict: str, repo: str, pr_number: int):
    """Write structured review result to a JSON file for the feedback loop."""
    criticals = [f for f in findings if f.severity == "critical"]
    warnings = [f for f in findings if f.severity == "warning"]

    if criticals:
        review_status = "changes_requested"
    elif warnings:
        review_status = "changes_requested"
    else:
        review_status = "approved"

    result = {
        "review_status": review_status,
        "verdict": verdict,
        "critical_count": len(criticals),
        "warning_count": len([f for f in findings if f.severity == "warning"]),
        "suggestion_count": len([f for f in findings if f.severity == "suggestion"]),
        "total_findings": len(findings),
        "repo": repo,
        "pr_number": pr_number,
        "findings": serialize_findings(criticals + warnings),
    }

    # Determine the output path: use GITHUB_OUTPUT env var dir, or default
    output_dir = os.environ.get("GITHUB_WORKSPACE", ".")
    result_path = os.path.join(output_dir, ".github/review_result.json")
    os.makedirs(os.path.dirname(result_path), exist_ok=True)
    with open(result_path, "w") as f:
        json.dump(result, f, indent=2)
    print(f"📝 Review result written to {result_path}")
    return result_path


# ── PR posting ──────────────────────────────────────────────────────────────

def post_pr_comment(repo: str, pr_number: int, body: str) -> bool:
    """Post a comment on the PR via the Issues API."""
    path = f"repos/{repo}/issues/{pr_number}/comments"
    result = gh_api(path, method="POST", body={"body": body})
    if result.get("id"):
        return True
    print(f"❌ Failed to post comment", file=sys.stderr)
    return False


# ── main ───────────────────────────────────────────────────────────────────

def main():
    repo = os.environ.get("GITHUB_REPOSITORY", "")
    pr_number_str = os.environ.get("PR_NUMBER", "")

    if not repo or not pr_number_str:
        print("❌ GITHUB_REPOSITORY and PR_NUMBER are required", file=sys.stderr)
        sys.exit(1)

    pr_number = int(pr_number_str)

    print(f"🔍 Reviewing PR #{pr_number} in {repo}")

    # 1. Fetch PR metadata
    pr_data = gh_api(f"repos/{repo}/pulls/{pr_number}")
    if not pr_data:
        print(f"❌ Could not fetch PR metadata", file=sys.stderr)
        # still attempt to post something
        post_pr_comment(repo, pr_number,
                        "## ⚠️ Review Agent Error\n\nCould not fetch PR metadata. "
                        "Check that the GITHUB_TOKEN has pull request read permissions.")
        sys.exit(1)

    pr_title = pr_data.get("title", "(unknown)")
    pr_author = pr_data.get("user", {}).get("login", "unknown")
    changed_files_data = gh_api_paginated(f"repos/{repo}/pulls/{pr_number}/files")
    changed_files = [f["filename"] for f in changed_files_data]
    additions = sum(f.get("additions", 0) for f in changed_files_data)
    deletions = sum(f.get("deletions", 0) for f in changed_files_data)

    print(f"  Title: {pr_title}")
    print(f"  Author: {pr_author}")
    print(f"  Files: {len(changed_files)} (+{additions} -{deletions})")

    # 2. Fetch the diff
    diff_text = get_pr_diff(repo, pr_number)
    diff_lines = diff_text.split("\n") if diff_text else []

    # 3. Skip for certain authors
    bot_skip = {"github-actions[bot]", "renovate[bot]", "dependabot[bot]"}
    if pr_author in bot_skip:
        print(f"  Skipping bot PR by {pr_author}")
        post_pr_comment(repo, pr_number,
                        f"## ⚠️ Review Skipped\n\nAutomated review skipped for bot PR (author: {pr_author}).")
        return

    print(f"  Diff size: {len(diff_lines)} lines")

    # 4. Run all checks
    findings = []
    findings.extend(run_cpp_checks(diff_lines, changed_files))
    findings.extend(run_c_checks(diff_lines, changed_files))
    findings.extend(run_security_checks(diff_lines, changed_files))
    findings.extend(run_xpra_checks(diff_lines, changed_files))
    findings.extend(run_build_checks(changed_files, repo, pr_number))
    findings.extend(run_quality_checks(diff_lines))
    findings.extend(run_docker_checks(diff_lines, changed_files))

    print(f"  Findings: {len(findings)}")
    for f in findings:
        print(f"    [{f.severity.upper()}] {f.file_path}:{f.line} — {f.message}")

    # 5. Generate and post the comment
    comment = generate_comment(
        findings=findings,
        diff_stat="",  # included in header
        pr_title=pr_title,
        pr_author=pr_author,
        changed_files=changed_files,
        additions=additions,
        deletions=deletions,
    )

    # Determine verdict based on same logic as generate_comment
    criticals = [f for f in findings if f.severity == "critical"]
    warnings = [f for f in findings if f.severity == "warning"]
    suggestions = [f for f in findings if f.severity == "suggestion"]
    if criticals:
        verdict = "Changes Requested 🔴"
    elif warnings:
        verdict = "Changes Requested ⚠️"
    elif suggestions:
        verdict = "Reviewed 💬"
    else:
        verdict = "Approved ✅"

    success = post_pr_comment(repo, pr_number, comment)
    if success:
        print(f"\n✅ Review posted to PR #{pr_number}")
        # Write structured result for the feedback loop
        write_review_result(findings, verdict, repo, pr_number)
    else:
        print(f"\n❌ Failed to post review to PR #{pr_number}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
