---
name: prusaslicer-xpra-conventions
description: Project conventions for the prusaslicer-xpra repository — commit messages, branch naming, PR review standards, versioning protocol, and build system architecture.
version: 1.0.0
platforms: [linux]
environments: [github]
metadata:
  hermes:
    tags: [prusaslicer, xpra, conventions, ci, versioning, github]
    related_skills: [cpp-cmake-code-review-checklist]
---

# Project Conventions — prusaslicer-xpra

> Canonical reference for how this repository is managed: commit hygiene, branch
> workflow, PR review standards, and versioning protocol.

---

## Table of Contents

1. [Commit Message Format](#1-commit-message-format)
2. [Branch Naming Conventions](#2-branch-naming-conventions)
3. [PR Review Standards](#3-pr-review-standards)
4. [Versioning Protocol](#4-versioning-protocol)

---

## 1. Commit Message Format

All commits in this repository follow the **Conventional Commits** format:

```
<type>: <short description>

<body> (optional)
```

### 1.1 Types

| Type    | Scope                        | Example                                         |
|---------|------------------------------|-------------------------------------------------|
| `fix`   | Bug fixes                    | `fix: resolve crash on empty G-code preview`    |
| `feat`  | New features                 | `feat: add Bambu Lab X1C printer profile`       |
| `chore` | Maintenance (deps, refactor) | `chore: bump libcurl to 7.88.1`                 |
| `ci`    | CI/CD config changes         | `ci: add apt cache restore step to builder job` |
| `docs`  | Documentation only           | `docs: document DOCKER_BUILDKIT env requirement`|

### 1.2 Rules

1. **Short description in imperative mood** — present tense, no full stop.
2. **No merge commits** — use squash merge only (see §3.2).
3. **Body is optional** — use it only when the short description needs elaboration (why, not what).
4. **Limit line length** — short description under 72 chars, body wrapped at 80 chars.

### 1.3 Examples

```
fix: handle null pointer in bed leveling mesh deserialization
```
```
feat: expose filament swap retract distance in UI
```
```
chore: update PrusaSlicer submodule to 2.9.5
```
```
ci: migrate Docker build to ubuntu-24.04 runner
```
```
ci: publish test results as CI artifact

Publish test output as a build artifact so contributors can inspect
failure details without re-running the workflow locally.
```

---

## 2. Branch Naming Conventions

### 2.1 Prefixes

| Prefix   | Use Case                              | Example                        |
|----------|---------------------------------------|--------------------------------|
| `fix/`   | Bug fixes                             | `fix/empty-gcode-crash`        |
| `feat/`  | New features or enhancements          | `feat/bambu-x1c-profile`       |
| `ci/`    | CI/CD pipeline changes only           | `ci/buildkite-migration`       |

### 2.2 Rules

1. **Lowercase only** — no uppercase letters in the slug.
2. **Hyphen-delimited** — words separated by `-`, never underscores or spaces.
3. **Descriptive but concise** — 2–5 words; enough to identify the change at a glance.
4. **No issue numbers in branch name** — reference the issue in the PR body instead.
5. **Delete after merge** — branches are short-lived; clean up when the PR closes.

### 2.3 Examples

```
fix/bed-level-null-ptr
fix/heater-timeout-regression

feat/bambu-x1c-profile
feat/filament-swap-retract-ui

ci/apt-cache-restore
ci/ubuntu-24-04-migration
```

### 2.4 Branch Lifecycle

```
main ──► fix/<slug> ──► PR ──► squash merge ──► main ──► delete branch
```

Branches are created from `main`, merged back via squash PR, and deleted immediately after merge. No long-running feature branches — every change is an isolated PR.

---

## 3. PR Review Standards

### 3.1 Purpose

These standards govern every pull request in the prusaslicer-xpra repository.
They apply to both human reviewers and the Bugbot automated review agent.

### 3.2 Merge Strategy — SQUASH Only

**All PRs must be merged via SQUASH.** No merge commits, no rebase merges.

Rationale:
- Keeps the commit history linear and readable
- Each PR becomes one atomic commit with a descriptive title
- Makes reverts and bisects straightforward

### 3.3 PR Title → Squash Commit Message

When a PR is squash-merged, the **PR title becomes the sole commit message**.
This means the PR title **IS** the commit message. Treat it accordingly:

- Use **Conventional Commits** format: `type(scope): description`
- Common types: `feat`, `fix`, `refactor`, `docs`, `test`, `ci`, `chore`, `perf`
- Keep under 72 characters
- Capitalize the description
- Do not end with a period
- Example: `fix(build): resolve missing libxcb dependency in CMakeLists.txt`

The PR body may contain additional context (test plan, migration notes, links to
issues), but the title is what lands in the permanent commit log.

### 3.4 Review Process

#### 3.4.1 Before Starting a Review

1. **Check the CI status** — do not review green code that has failing checks
   (trivial lint fixes excluded). CI must be green or the review should note
   the failures as blocking.

2. **Review the diff first** — get the big picture with `git diff main...HEAD --stat`
   before diving into individual files.

3. **Know the domain** — load the appropriate skill based on what changed:
   - **C++ / CMake changes:** load `cpp-cmake-code-review-checklist` skill
     (`skill_view(name='cpp-cmake-code-review-checklist')`) and follow the
     full 12-section checklist at `references/checklist.md`
   - **Python / CI / config:** use the general checklist in §3.4.2 below

#### 3.4.2 Review Checklist (General)

Check every PR against these categories:

| Category | What to check |
|----------|--------------|
| Correctness | Does the code do what it claims? Edge cases handled? Error paths? |
| Security | No hardcoded secrets, SQL injection, path traversal, XSS, shell injection |
| Code Quality | Clear naming, no dead code, focused functions, DRY |
| Testing | New code path tested? Happy + error cases? Tests readable and deterministic? |
| Performance | No N+1 patterns, unnecessary blocking ops in async paths, appropriate caching |
| Documentation | Public APIs documented, non-obvious logic explained, README updated if behavior changed |

#### 3.4.3 C++ / CMake Changes — Load the Checklist Skill

When the PR touches C++ or CMake files, the reviewer **MUST** load the
`cpp-cmake-code-review-checklist` skill and follow its full checklist:

```
skill_view(name='cpp-cmake-code-review-checklist')
skill_view(name='cpp-cmake-code-review-checklist', file_path='references/checklist.md')
```

The checklist covers these 12 sections (see the skill for full detail):

1. Correctness — C++ (RAII, const correctness, exception safety, initialization, casting, templates)
2. Correctness — C (buffer safety, pointer safety, integer overflow, format strings)
3. Style & Code Quality (naming, file org, formatting, comments, C++ modernity)
4. Edge Cases (containers/iterators, strings, numeric, I/O, cross-platform)
5. Security (injection, buffer overflow, use-after-free, TOCTOU, crypto)
6. Memory & Resource Management (leaks, stack vs heap, RAII wrappers)
7. Concurrency & Thread Safety (data races, deadlock, atomics, condition variables)
8. CMake & Build System (target linkage, find_package, compiler flags, install rules)
9. xpra / X11 Specific (X11 sockets, shared memory, pixel formats, socket I/O, frame encoding)
10. Testing (coverage, failure paths, edge cases, determinism)
11. Severity Guide (when to block vs suggest)
12. Appendix (grep/diff patterns for automated CI checks)

#### 3.4.4 Review Severity Levels

| Severity | Label | Meaning | Action |
|----------|-------|---------|--------|
| 🔴 Critical | Blocking | Security vulnerability, data loss, incorrect behavior | Must fix before merge |
| 🟡 Warning | Non-blocking | Code quality, missing edge cases, potential future bugs | Should fix; note for author |
| 💡 Suggestion | Advisory | Style preference, optional refactor, minor improvement | Note and move on |

#### 3.4.5 Submitting the Review

- Use GitHub's formal review workflow (Approve / Request Changes / Comment)
- Leave inline comments on specific lines for actionable feedback
- Post a summary comment covering the overall verdict
- **Request Changes** if any 🔴 Critical issues are found
- **Approve** only when all issues are resolved and CI is green

### 3.5 Pre-Merge Authorization

Before any automated merge, verify **ALL** of these conditions:

#### Mergeability
- PR is `open` (not `draft`)
- `merge_commit_sha` is non-null (GitHub has computed mergeability)
- `mergeable` is not `False` (no merge conflicts)

#### CI Status
- All checks are in `success` state
- No checks are `in_progress`, `queued`, or `pending`
- No checks with conclusion `failure`, `error`, or `cancelled`

#### Reviews
- If reviews are required: latest review is `APPROVED`
- No review has `CHANGES_REQUESTED` as its latest state
- If no review requirement is configured — trivially satisfied

#### Freshness
- PR data must be fetched within the last 60 seconds before merge
- Stale cached state is not acceptable

#### Safety Guards — Do NOT Merge If

- PR is a draft
- Merge conflicts exist (`mergeable` is `False`)
- CI is still running or has failures
- `merge_commit_sha` is `null` (re-fetch once — see pitfall below)
- Latest review is `CHANGES_REQUESTED`
- Branch protection rules block the merge

#### Pitfall — `mergeable: null` Timing

The API may return `mergeable: null` initially because GitHub hasn't computed
mergeability yet. This is not a blocking state — re-fetch the PR after a few
seconds and it will resolve to `true` or `false`. Only treat a confirmed `false`
as a merge conflict.

#### Pitfall — Stale PR Branch

When a PR's base branch has advanced and `merge_commit_sha` is `null` with
`mergeable: false`, do NOT force-push. Use the GitHub `update-branch` API
which merges the latest base into the PR branch without rewriting history.
This respects branch protection rules and doesn't break existing review comments.

### 3.6 Auto-Merge Conditions (for CI-bot usage)

When the CI-triage pipeline produces a fix PR that passes all checks:

1. PR author is the Bugbot profile
2. CI passes (all checks green)
3. No human review blocking required (self-approval on personal repo)
4. Merge method: **squash**
5. Commit title: the PR title (conventional commit format)
6. Optional commit message body for additional context

### 3.7 Repository Conventions

- **Base branch:** `main` for all PRs
- **Target:** Always `main` unless explicitly coordinated with the owner
- **Branch naming:** `fix/description`, `feat/description`, `docs/description`,
  `ci/description`, `refactor/description`
- **Auto-delete branch:** Delete the source branch after merge

---

## 4. Versioning Protocol

> Canonical reference for how PrusaSlicer versions are tracked, tagged, and
> published across the prusaslicer-xpra repository.

### 4.1 Single Source of Truth

**`ARG PRUSA_VERSION` in `Dockerfile` (the runtime image)** is the single
canonical version for the project.

- Format: bare semver — e.g. `2.9.5`
- Read by `docker.yml` to determine image tags
- Read by `auto-bump.yml` (the daily updater) to compare with upstream
- The version is duplicated in `Dockerfile.builder` but in git-tag form
  (see §4.2); both files are always updated together.

#### Files That Carry the Version

| File | Format | Example |
|---|---|---|
| `Dockerfile` | `ARG PRUSA_VERSION=<bare>` | `ARG PRUSA_VERSION=2.9.5` |
| `Dockerfile.builder` | `ARG PRUSA_VERSION=version_<bare>` | `ARG PRUSA_VERSION=version_2.9.5` |

#### How the Version Flows

```
Dockerfile         Dockerfile.builder
  ARG PRUSA_VERSION  ARG PRUSA_VERSION
       │                   │
       ▼                   ▼
  docker.yml            build-prusaslicer.yml
  (tag runtime image)   (check out upstream git tag,
                         compile PrusaSlicer)
       │                   │
       ▼                   ▼
  ghcr.io/.../prusaslicer-xpra   ghcr.io/.../prusaslicer-xpra-builder
  :latest / :<ver> / :<date>     :<ver> / :latest
```

### 4.2 Two-Stage Build System

The repo uses a builder/runtime split to keep CI fast.

#### Builder Image

| Attribute | Value |
|---|---|
| Image name | `ghcr.io/eth4ck1e/prusaslicer-xpra-builder` |
| What it does | Compiles PrusaSlicer from source |
| Build time | ~90 minutes |
| Trigger | `build-prusaslicer.yml` (manual `workflow_dispatch`, or auto-triggered by `auto-bump.yml`) |
| Dockerfile | `Dockerfile.builder` |
| Upstream source | `git clone --branch ${PRUSA_VERSION} https://github.com/prusa3d/PrusaSlicer.git` |

`PRUSA_VERSION` in `Dockerfile.builder` is the **full upstream git tag**, e.g.
`version_2.9.5`. This matches the naming convention used by
[Prusa3d/PrusaSlicer](https://github.com/prusa3d/PrusaSlicer/tags).

#### Runtime Image

| Attribute | Value |
|---|---|
| Image name | `ghcr.io/eth4ck1e/prusaslicer-xpra` |
| What it does | Packages the runtime: Xpra, VirtualGL, GPU drivers, and the pre-compiled PrusaSlicer binary from the builder stage |
| Build time | ~3 minutes |
| Trigger | `docker.yml` — push to main/dev, weekly cron (Fridays), `workflow_run` after builder completes, or manual |
| Dockerfile | `Dockerfile` |

`PRUSA_VERSION` in `Dockerfile` is the **bare semver**, e.g. `2.9.5`. It's used
to pull the matching builder image:

```dockerfile
FROM ghcr.io/eth4ck1e/prusaslicer-xpra-builder:${PRUSA_VERSION} AS builder
```

### 4.3 Docker Image Tags

#### Runtime Image — Main Branch (`docker.yml`)

Tags are computed by `docker.yml`'s `Set branch-aware image tags` step:

| Tag | Example | Purpose |
|---|---|---|
| `:latest` | `ghcr.io/eth4ck1e/prusaslicer-xpra:latest` | Default pull target |
| `:<version>` | `ghcr.io/eth4ck1e/prusaslicer-xpra:2.9.5` | Version-pinned |
| `:<date>` | `ghcr.io/eth4ck1e/prusaslicer-xpra:2026.06.21.060000` | Timestamped |

Date format: `%Y.%m.%d.%H%M%S` (UTC).

#### Runtime Image — Dev Branch

| Tag | Example | Purpose |
|---|---|---|
| `:dev` | `ghcr.io/eth4ck1e/prusaslicer-xpra:dev` | Dev branch head |
| `:dev-<date>` | `ghcr.io/eth4ck1e/prusaslicer-xpra:dev-2026.06.21.060000` | Dev branch, dated |

#### Builder Image (`build-prusaslicer.yml`)

| Tag | Example | Purpose |
|---|---|---|
| `:<version>` | `ghcr.io/eth4ck1e/prusaslicer-xpra-builder:2.9.5` | Version-pinned builder |
| `:latest` | `ghcr.io/eth4ck1e/prusaslicer-xpra-builder:latest` | Latest built version |

The builder image's version tag is the bare semver (obtained by stripping the
`version_` prefix from the git tag input), matching the runtime Dockerfile's
format.

### 4.4 Version Bump — Manual

```bash
# 1. Go to GitHub → Actions → Build PrusaSlicer → Run workflow
# 2. Enter the PrusaSlicer git tag, e.g.  version_2.9.5
# 3. The workflow:
#    - Validates the tag exists upstream
#    - Builds and pushes the builder image
#    - Triggers docker.yml to rebuild the runtime image
```

After the builder finishes, the version in both Dockerfiles must also be
updated. If you bump manually, run:

```bash
sed -i 's/^ARG PRUSA_VERSION=.*/ARG PRUSA_VERSION=2.9.5/' Dockerfile
sed -i 's/^ARG PRUSA_VERSION=.*/ARG PRUSA_VERSION=version_2.9.5/' Dockerfile.builder
git add Dockerfile Dockerfile.builder
git commit -m "chore: bump PrusaSlicer 2.9.4 → 2.9.5 [skip ci]"
git push
```

(Or submit a PR with the change — `docker.yml` will pick it up on merge to
main.)

### 4.5 Version Bump — Automatic

The `auto-bump.yml` workflow runs daily at **6:00 UTC** (configurable via the
`schedule` cron entry in the workflow file).

#### Flow

```
1. Fetch latest PrusaSlicer release tag from GitHub API
   → https://api.github.com/repos/prusa3d/PrusaSlicer/releases/latest

2. Read current PRUSA_VERSION from Dockerfile
   → grep '^ARG PRUSA_VERSION=' Dockerfile | cut -d= -f2

3. If versions differ:
   a. Update Dockerfile (bare semver)
   b. Update Dockerfile.builder (git tag form)
   c. Commit with message:
      "chore: bump PrusaSlicer <old> → <new> [skip ci]"
   d. Push to main
   e. Check if builder image exists on GHCR
   f. If missing: dispatch build-prusaslicer.yml, wait for completion

4. If versions match:
   → Log "Already up to date", exit cleanly
```

#### Pre-built Image Shortcut

Before dispatching the ~90-minute builder workflow, `auto-bump.yml` checks:

```bash
docker manifest inspect ghcr.io/eth4ck1e/prusaslicer-xpra-builder:<new-version>
```

If the image already exists (e.g. from a previous manual build), the builder
workflow is skipped entirely — only the version bump commit is pushed. The
`docker.yml` weekly cron will pick up the new version and build the runtime
image on its next Friday run.

### 4.6 Rolling Back

To pin to an older PrusaSlicer version:

```bash
# Revert both Dockerfiles
git checkout <commit-before-bump> -- Dockerfile Dockerfile.builder
git commit -m "revert: pin PrusaSlicer back to <old-version> [skip ci]"

# If the builder image for the older version still exists on GHCR,
# push to main and docker.yml will rebuild the runtime.
# If it was pruned, run Build PrusaSlicer workflow with the old tag first.
```

### 4.7 Summary

| Concept | Value |
|---|---|
| **Canonical version** | `PRUSA_VERSION` in `Dockerfile` (bare semver, e.g. `2.9.5`) |
| **Upstream source** | `Prusa3d/PrusaSlicer` git tags (`version_<semver>`) |
| **Builder image** | `prusaslicer-xpra-builder:<version>` |
| **Runtime images** | `prusaslicer-xpra:latest`, `:<version>`, `:<date>` |
| **Auto-update** | `auto-bump.yml` — daily 06:00 UTC |
| **Manual trigger** | `build-prusaslicer.yml` — workflow_dispatch with git tag |
| **Runtime publish** | `docker.yml` — push, schedule, workflow_run, dispatch |