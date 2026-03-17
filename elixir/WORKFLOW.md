---
tracker:
  kind: linear
  project_slug: "e25f672de3c0"
  active_states:
    - Todo
    - In Progress
    - Rework
    - Agent Review
    - Resolve PR Comments
    - Human Review
    - Merging
  paused_states:
    - Human Review
  terminal_states:
    - Cancelled
    - Canceled
    - Duplicate
    - Done
polling:
  interval_ms: 5000
workspace:
  root: ~/code/symphony-workspaces
  source_repo_map:
    default:
      - git@github.com:arbitrium-platform/arbitrium-backend.git
      - git@github.com:arbitrium-platform/arbitrium-frontend.git
    label_overrides:
      backend: git@github.com:arbitrium-platform/arbitrium-backend.git
      backend-api: git@github.com:arbitrium-platform/arbitrium-backend.git
      frontend: git@github.com:arbitrium-platform/arbitrium-frontend.git
hooks:
  after_create: |
    if [ -f go.mod ]; then
      go mod download
    fi
    if [ -f frontend/package.json ]; then
      npm --prefix frontend ci --legacy-peer-deps
    fi
    if [ -f backoffice/package.json ]; then
      npm --prefix backoffice ci
    fi
  before_remove: |
    true
agent:
  max_concurrent_agents: 10
  max_turns: 20
  token_budget:
    enabled: true
    per_turn_soft_tokens: 180000
    per_turn_hard_tokens: 900000
    per_run_soft_tokens: 350000
    per_run_hard_tokens: 1200000
    per_issue_window_soft_tokens: 2500000
    per_issue_window_hard_tokens: 6000000
    issue_window_seconds: 86400
    comment_on_enforcement: true
    pause_on_hard_limit: false
codex:
  command: codex --config shell_environment_policy.inherit=all --config model_reasoning_effort=medium --model gpt-5.3-codex app-server
  approval_policy: never
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: workspaceWrite
    writableRoots:
      - ~/.docker/run
    networkAccess: true
---

You are working on a Linear ticket `{{ issue.identifier }}`

{% if attempt %}
Continuation context:

- This is retry attempt #{{ attempt }} because the ticket is still in an active state.
- Resume from the current workspace state instead of restarting from scratch.
- Do not repeat already-completed investigation or validation unless needed for new code changes.
- Do not end the turn while the issue remains in an active state unless you are blocked by missing required permissions/secrets.
  {% endif %}

Issue context:
Identifier: {{ issue.identifier }}
Title: {{ issue.title }}
Current status: {{ issue.state }}
Labels: {{ issue.labels }}
URL: {{ issue.url }}

Description:
{% if issue.description %}
{{ issue.description }}
{% else %}
No description provided.
{% endif %}

Instructions:

1. This is an unattended orchestration session. Never ask a human to perform follow-up actions.
2. Only stop early for a true blocker (missing required auth/permissions/secrets). If blocked, record it in the workpad and move the issue according to workflow.
3. Final message must report completed actions and blockers only. Do not include "next steps for user".

Work only inside the provided workspace and repositories copied into it. Do not touch any other path.

## Prerequisite: Linear MCP or `linear_graphql` tool is available

The agent should be able to talk to Linear, either via a configured Linear MCP server or injected `linear_graphql` tool. If none are present, stop and ask the user to configure Linear.

## Default posture

- Start by determining the ticket's current status, then follow the matching flow for that status.
- Enforce branch policy before implementation: branch names must use conventional prefixes (`build/`, `chore/`, `ci/`, `docs/`, `feat/`, `fix/`, `perf/`, `refactor/`, `revert/`, `style/`, or `test/`), and active work must run on the Linear issue branch.
- Start every task by opening the tracking workpad comment and bringing it up to date before doing new implementation work.
- Spend extra effort up front on planning and verification design before implementation.
- Reproduce first: always confirm the current behavior/issue signal before changing code so the fix target is explicit.
- Keep ticket metadata current (state, checklist, acceptance criteria, links).
- Treat a single persistent Linear comment as the source of truth for progress.
- Use that single workpad comment for all progress and handoff notes; do not post separate "done"/summary comments.
- Treat any ticket-authored `Validation`, `Test Plan`, or `Testing` section as non-negotiable acceptance input: mirror it in the workpad and execute it before considering the work complete.
- When meaningful out-of-scope improvements are discovered during execution,
  file a separate Linear issue instead of expanding scope. The follow-up issue
  must include a clear title, description, and acceptance criteria, be placed in
  `Backlog`, be assigned to the same project as the current issue, link the
  current issue as `related`, and use `blockedBy` when the follow-up depends on
  the current issue.
- Move status only when the matching quality bar is met.
- Operate autonomously end-to-end unless blocked by missing requirements, secrets, or permissions.
- Use the blocked-access escape hatch only for true external blockers (missing required tools/auth) after exhausting documented fallbacks.
- Treat the main thread as orchestrator: delegate bounded discovery/verification tasks to sub-agents by default, then consume only concise summaries.
- Delegation trigger (required): if a sub-problem would take more than 5 tool/command calls or more than 2 file reads, call `spawn_agent` first and continue from the sub-agent summary.
- Keep token usage lean: avoid large raw dumps, prefer targeted reads/searches, and cap command output by default unless debugging a specific failure.
- Ticket pickup rule (required): whenever a ticket is picked up (from `Todo`, `In Progress`, or `Rework` restart), start by running the `tdd` skill (`$tdd`) before implementation.
- If multiple repositories are present in the workspace, apply branch/commit/push/PR hygiene per repository you modify.

## Related skills

- `linear`: interact with Linear.
- `tdd`: start every ticket pickup with red-green-refactor discipline before implementation.
- `commit`: produce clean, logical commits during implementation.
- `push`: keep remote branch current and publish updates.
- `pull`: keep branch updated with latest `origin/main` before handoff.
- `land`: when ticket reaches `Merging`, explicitly open and follow `.codex/skills/land/SKILL.md` for squash-merge + workspace cleanup.
- Do not call `gh pr merge` directly; `land` is the only merge path in this workflow.

## Status map

- `Backlog` -> out of scope for this workflow; do not modify.
- `Todo` -> queued; ensure branch policy/alignment first, then transition to `In Progress` before active work.
  - Special case: if a PR is already attached, treat as feedback loop (run full PR feedback sweep, address or explicitly push back, revalidate, return to `Human Review`).
- `In Progress` -> implementation actively underway.
- `Agent Review` -> run the required `/review` loop against `main`, resolve findings, and return to `In Progress` for fixes or advance to `Human Review` when clear.
- `Resolve PR Comments` -> human-triggered feedback pass; address outstanding PR comments/reviews, revalidate, and return to `Human Review`.
- `Human Review` -> PR is attached and validated; waiting on human action (`Resolve PR Comments` for changes or `Merging` for approval).
- `Merging` -> approved by human; run `land` to squash-merge, clean workspace, then move to `Done`.
- `Rework` -> full reset path only (close prior PR, restart from fresh branch/workpad).
- `Done` -> terminal state; no further action required.

## Step 0: Determine current ticket state and route

1. Fetch the issue by explicit ticket ID.
2. Read the current state.
3. Route to the matching flow:
   - `Backlog` -> do not modify issue content/state; stop and wait for human to move it to `Todo`.
   - `Todo` -> immediately move to `In Progress`, then ensure bootstrap workpad comment exists (create if missing), then start execution flow with mandatory `tdd` kickoff (`$tdd`).
     - If PR is already attached, start by reviewing all open PR comments and deciding required changes vs explicit pushback responses.
   - `In Progress` -> continue execution flow from current scratchpad comment, starting with mandatory `tdd` kickoff (`$tdd`) for this pickup session.
   - `Agent Review` -> continue/complete the `/review` loop against `main`; resolve findings, then proceed with normal pre-`Human Review` gates.
   - `Resolve PR Comments` -> run PR feedback resolution loop, then return to `Human Review` once clear.
   - `Human Review` -> wait and poll for decision/review updates; do not change state from `Human Review`.
   - `Merging` -> on entry, open and follow `.codex/skills/land/SKILL.md`; squash-merge, clean workspace, then move to `Done`.
   - `Rework` -> run full reset rework flow.
   - `Done` -> do nothing and shut down.
4. Check whether a PR already exists for the current branch and whether it is closed.
   - If a branch PR exists and is `CLOSED` or `MERGED`, treat prior branch work as non-reusable for this run.
   - Create a fresh branch from `origin/main` and restart execution flow as a new attempt.
5. For `Todo` tickets, do startup sequencing in this exact order:
   - Ensure `issue.branchName` is set and valid for this ticket before any state change.
     - Valid format: `<type>/<slug>` where `<type>` is one of `build`, `chore`, `ci`, `docs`, `feat`, `fix`, `perf`, `refactor`, `revert`, `style`, or `test`.
     - If missing/invalid, update the issue branch name first, then create/switch local branch to match.
   - `update_issue(..., state: "In Progress")`
   - find/create `## Codex Workpad` bootstrap comment
   - only then begin analysis/planning/implementation work.
6. Add a short comment if state and issue content are inconsistent, then proceed with the safest flow.

## Step 1: Start/continue execution (Todo or In Progress)

1. Find or create a single persistent scratchpad comment for the issue:
    - Search existing comments for a marker header: `## Codex Workpad`.
    - Ignore resolved comments while searching; only active/unresolved comments are eligible to be reused as the live workpad.
    - If found, reuse that comment; do not create a new workpad comment.
    - If not found, create one workpad comment and use it for all updates.
    - Persist the workpad comment ID and only write progress updates to that ID.
2. If arriving from `Todo`, do not delay on additional status transitions: the issue should already be `In Progress` before this step begins.
3. Before any implementation edits, run the `tdd` skill (`$tdd`) for this pickup session and capture the initial red/repro signal in the workpad `Notes`.
   - If a suitable failing test already exists, record the exact command/output and proceed through green/refactor.
   - If no automated test is feasible, document deterministic reproduction evidence and the validation guardrail you will use instead.
4. Immediately reconcile the workpad before new edits:
    - Check off items that are already done.
    - Expand/fix the plan so it is comprehensive for current scope.
    - Ensure `Acceptance Criteria` and `Validation` are current and still make sense for the task.
5. Start work by writing/updating a hierarchical plan in the workpad comment.
6. Ensure the workpad includes a compact environment stamp at the top as a code fence line:
    - Format: `<host>:<abs-workdir>@<short-sha>`
    - Example: `devbox-01:/home/dev-user/code/symphony-workspaces/MT-32@7bdde33bc`
    - Do not include metadata already inferable from Linear issue fields (`issue ID`, `status`, `branch`, `PR link`).
7. Add explicit acceptance criteria and TODOs in checklist form in the same comment.
    - If changes are user-facing, include a UI walkthrough acceptance criterion that describes the end-to-end user path to validate.
    - If changes touch app files or app behavior, add explicit app-specific flow checks to `Acceptance Criteria` in the workpad (for example: launch path, changed interaction path, and expected result path).
    - If the ticket description/comment context includes `Validation`, `Test Plan`, or `Testing` sections, copy those requirements into the workpad `Acceptance Criteria` and `Validation` sections as required checkboxes (no optional downgrade).
8. Run a principal-style self-review of the plan and refine it in the comment.
9. Before implementing, capture a concrete reproduction signal and record it in the workpad `Notes` section (command/output, screenshot, or deterministic UI behavior).
10. Run the `pull` skill to sync with latest `origin/main` before any code edits, then record the pull/sync result in the workpad `Notes`.
    - Include a `pull skill evidence` note with:
      - merge source(s),
      - result (`clean` or `conflicts resolved`),
      - resulting `HEAD` short SHA.
11. Compact context and proceed to execution.

## PR feedback sweep protocol (required)

When a ticket has an attached PR, run this protocol before moving to `Human Review`:

1. Identify the PR number from issue links/attachments.
2. Gather feedback from all channels:
   - Top-level PR comments (`gh pr view --comments`).
   - Inline review comments (`gh api repos/<owner>/<repo>/pulls/<pr>/comments`).
   - Review summaries/states (`gh pr view --json reviews`).
   - Do not filter feedback by author type; bot-authored comments/reviews are
     first-class and must be handled like human feedback.
3. Treat every actionable reviewer comment (human or bot), including inline review comments, as blocking until one of these is true:
   - code/test/docs updated to address it, or
   - explicit, justified pushback reply is posted on that thread.
   - Do not ask reviewers to restate existing PR feedback as new inline comments
     when the existing thread/review body already contains actionable guidance.
4. Update the workpad plan/checklist to include each feedback item and its resolution status.
5. Re-run validation after feedback-driven changes and push updates.
6. Repeat this sweep until there are no outstanding actionable comments.

## Code review loop (required)

Before moving any issue to `Human Review`, run a dedicated `/review` loop against `main`:

1. Refresh main and compute the merge base commit:
   - `git fetch origin --prune`
   - `BASE=$(git merge-base HEAD origin/main || git merge-base HEAD main)`
2. Invoke `/review` using this prompt template (replace `<BASE>`):
   - `Review the code changes against the base branch 'main'. The merge base commit for this comparison is <BASE>. Run \`git diff <BASE>\` to inspect the changes relative to main. Provide prioritized, actionable findings.`
3. Treat actionable findings as strictly blocking:
   - If `/review` returns any actionable items, do not proceed to `Human Review`.
   - Apply fixes (or record explicit, justified pushback when appropriate).
   - Re-run required validation.
   - Re-run `/review` with the same base-branch comparison.
4. Repeat step 3 continuously until `/review` returns zero actionable items.
5. Exit the loop only when there are no unresolved actionable findings from the latest `/review` pass.

## Human Review entry gate (hard requirement)

Before moving any issue to `Human Review`, all of the following must be true for the latest PR head commit:

1. CI/check status is fully complete:
   - No failed checks.
   - No pending/in-progress checks.
   - Required checks are `SUCCESS` (or explicitly non-blocking like `SKIPPED`/`NEUTRAL`).
2. Review feedback is fully clear:
   - No unresolved actionable comments from humans or bots (top-level, inline, review-body).
   - No outstanding review requesting changes that has not been addressed.
3. Bot-review settle window is complete:
   - After the latest push, wait long enough for asynchronous bot reviews to appear, then run one final full feedback+checks sweep.
   - If any new bot feedback appears, address it and repeat the gate.
4. `/review` loop is complete:
   - `/review` was run against `main` using merge-base diff (`git diff <BASE>`).
   - The agent stayed in the fix-and-re-review loop until `/review` returned zero actionable findings.
   - No unresolved actionable findings remain from the latest `/review` pass.
5. If any gate condition fails, do not move to `Human Review`; remain in `In Progress` and continue the fix loop.

## Blocked-access escape hatch (required behavior)

Use this only when completion is blocked by missing required tools or missing auth/permissions that cannot be resolved in-session.

- GitHub is **not** a valid blocker by default. Always try fallback strategies first (alternate remote/auth mode, then continue publish/review flow).
- Do not move to `Human Review` for GitHub access/auth until all fallback strategies have been attempted and documented in the workpad.
- If a non-GitHub required tool is missing, or required non-GitHub auth is unavailable, move the ticket to `Human Review` with a short blocker brief in the workpad that includes:
  - what is missing,
  - why it blocks required acceptance/validation,
  - exact human action needed to unblock.
- Keep the brief concise and action-oriented; do not add extra top-level comments outside the workpad.

## Step 2: Execution phase (Todo -> In Progress -> Agent Review -> Resolve PR Comments -> Human Review)

1. Determine current repo state (`branch`, `git status`, `HEAD`) and verify the kickoff `pull` sync result is already recorded in the workpad before implementation continues.
   - If `git branch --show-current` does not match Linear `issue.branchName`, stop and fix branch alignment first.
   - If the branch is missing or invalid, set Linear `branchName` and local branch to a conventional name (`build/`, `chore/`, `ci/`, `docs/`, `feat/`, `fix/`, `perf/`, `refactor/`, `revert/`, `style/`, or `test/`) before coding.
2. If current issue state is `Todo`, move it to `In Progress`; otherwise leave the current state unchanged.
3. Confirm `tdd` kickoff evidence exists for this pickup session (`$tdd` + red/repro note in workpad) before continuing implementation.
4. Load the existing workpad comment and treat it as the active execution checklist.
    - Edit it liberally whenever reality changes (scope, risks, validation approach, discovered tasks).
5. Implement against the hierarchical TODOs and keep the comment current:
    - Check off completed items.
    - Add newly discovered items in the appropriate section.
    - Keep parent/child structure intact as scope evolves.
    - Update the workpad immediately after each meaningful milestone (for example: reproduction complete, code change landed, validation run, review feedback addressed).
    - Never leave completed work unchecked in the plan.
    - For tickets that started as `Todo` with an attached PR, run the full PR feedback sweep protocol immediately after kickoff and before new feature work.
6. Run validation/tests required for the scope.
    - Mandatory gate: execute all ticket-provided `Validation`/`Test Plan`/ `Testing` requirements when present; treat unmet items as incomplete work.
    - Prefer a targeted proof that directly demonstrates the behavior you changed.
    - You may make temporary local proof edits to validate assumptions (for example: tweak a local build input for `make`, or hardcode a UI account / response path) when this increases confidence.
    - Revert every temporary proof edit before commit/push.
    - Document these temporary proof steps and outcomes in the workpad `Validation`/`Notes` sections so reviewers can follow the evidence.
    - If app-touching, run `launch-app` validation and capture/upload media via `github-pr-media` before handoff.
7. Re-check all acceptance criteria and close any gaps.
8. Before every `git push` attempt, run the required validation for your scope and confirm it passes; if it fails, address issues and rerun until green, then commit and push changes.
9. Attach PR URL(s) to the issue (prefer attachment; use the workpad comment only if attachment is unavailable).
    - If multiple repositories were modified, open and attach one PR per modified repository.
    - Ensure each GitHub PR has label `symphony` (add it if missing).
10. Merge latest `origin/main` into branch, resolve conflicts, and rerun checks.
11. Update the workpad comment with final checklist status and validation notes.
    - Mark completed plan/acceptance/validation checklist items as checked.
    - Add final handoff notes (commit + validation summary) in the same workpad comment.
    - Do not include PR URL in the workpad comment; keep PR linkage on the issue via attachment/link fields.
    - Add a short `### Confusions` section at the bottom when any part of task execution was unclear/confusing, with concise bullets.
    - Do not post any additional completion summary comment.
12. Before moving to `Human Review`, poll PR feedback and checks:
    - Move the issue to `Agent Review` before running the required `/review` loop.
      - If `Agent Review` transition fails because the state is unavailable in Linear, continue in `In Progress` and record the fallback in the workpad `Notes`.
    - Read the PR `Manual QA Plan` comment (when present) and use it to sharpen UI/runtime test coverage for the current change.
    - Run the required `/review` loop against `main` (merge-base + `git diff <BASE>`), and resolve findings before proceeding.
      - Continue fixing and rerunning `/review` until it returns zero actionable items.
    - Run the full PR feedback sweep protocol.
    - Confirm PR checks are fully complete and passing (no failed, no pending/in-progress) for the latest head SHA.
    - Wait for bot-review settle window after the latest push, then re-run the full sweep once more.
    - Confirm every required ticket-provided validation/test-plan item is explicitly marked complete in the workpad.
    - Repeat this check-address-verify loop until no outstanding actionable comments remain and all checks are fully passing.
    - Re-open and refresh the workpad before state transition so `Plan`, `Acceptance Criteria`, and `Validation` exactly match completed work.
13. Only then move issue to `Human Review` from `Agent Review` (or from `In Progress` when `Agent Review` is unavailable).
    - Exception: if blocked by missing required non-GitHub tools/auth per the blocked-access escape hatch, move to `Human Review` with the blocker brief and explicit unblock actions.
14. For `Todo` tickets that already had a PR attached at kickoff:
    - Ensure all existing PR feedback was reviewed and resolved, including inline review comments (code changes or explicit, justified pushback response).
    - Ensure branch was pushed with any required updates.
    - Then apply the same `Human Review entry gate (hard requirement)` before any state transition.

## Step 3: Human Review, PR comments, and merge handling

1. When the issue is in `Human Review`, do not code or change ticket content.
2. Poll for updates as needed, including GitHub PR review comments from humans and bots.
3. If review feedback requires changes while in `Human Review`, do not change state; wait for a human to move the issue to `Resolve PR Comments`.
4. In `Resolve PR Comments`, address only outstanding PR feedback (code updates or explicit justified pushback replies), rerun required validation, and run the full PR feedback sweep until clear.
5. After `Resolve PR Comments` work is complete and the `Human Review entry gate (hard requirement)` is satisfied, move the issue back to `Human Review`.
6. If approved, human moves the issue to `Merging`.
7. When the issue is in `Merging`, open and follow `.codex/skills/land/SKILL.md` to squash-merge the PR and clean up the workspace (no additional review/check loop in this stage).
8. After merge and cleanup are complete, move the issue to `Done`.

## Step 4: Rework handling

1. Treat `Rework` as a full approach reset, not incremental patching.
2. Re-read the full issue body and all human comments; explicitly identify what will be done differently this attempt.
3. Close the existing PR tied to the issue.
4. Remove the existing `## Codex Workpad` comment from the issue.
5. Create a fresh branch from `origin/main`.
6. Start over from the normal kickoff flow:
   - If current issue state is `Todo`, move it to `In Progress`; otherwise keep the current state.
   - Create a new bootstrap `## Codex Workpad` comment.
   - Run mandatory `tdd` kickoff (`$tdd`), then build a fresh plan/checklist and execute end-to-end.

## Completion bar before Human Review

- Step 1/2 checklist is fully complete and accurately reflected in the single workpad comment.
- Acceptance criteria and required ticket-provided validation items are complete.
- Validation/tests are green for the latest commit.
- Required `/review` loop against `main` is complete with no unresolved actionable findings.
- Issue moved through `Agent Review` for the `/review` loop, or documented fallback when `Agent Review` state is unavailable.
- PR feedback sweep is complete and no actionable comments remain (including bot comments/reviews).
- PR checks are complete and green for latest head SHA (no pending/in-progress checks), branch is pushed, and PR is linked on the issue.
- Bot-review settle window completed after latest push with a final clean sweep.
- Required PR metadata is present (`symphony` label).
- If app-touching, runtime validation/media requirements from `App runtime validation (required)` are complete.

## Guardrails

- If the branch PR is already closed/merged, do not reuse that branch or prior implementation state for continuation.
- For closed/merged branch PRs, create a new branch from `origin/main` and restart from reproduction/planning as if starting fresh.
- If issue state is `Backlog`, do not modify it; wait for human to move to `Todo`.
- Do not move issues out of `Human Review`; humans control transitions from `Human Review`.
- Do not move `Human Review` tickets to `Rework` for normal PR feedback; use `Resolve PR Comments` instead.
- Use `Rework` only when a full reset is explicitly required (fresh branch + fresh workpad path).
- Do not edit the issue body/description for planning or progress tracking.
- Use exactly one persistent workpad comment (`## Codex Workpad`) per issue.
- If comment editing is unavailable in-session, use the update script. Only report blocked if both MCP editing and script-based editing are unavailable.
- Temporary proof edits are allowed only for local verification and must be reverted before commit.
- If out-of-scope improvements are found, create a separate Backlog issue rather
  than expanding current scope, and include a clear
  title/description/acceptance criteria, same-project assignment, a `related`
  link to the current issue, and `blockedBy` when the follow-up depends on the
  current issue.
- Do not move to `Human Review` unless the `Completion bar before Human Review` is satisfied.
- In `Human Review`, do not make changes; wait and poll.
- If state is terminal (`Done`), do nothing and shut down.
- Keep issue text concise, specific, and reviewer-oriented.
- If blocked and no workpad exists yet, add one blocker comment describing blocker, impact, and next unblock action.

## Workpad template

Use this exact structure for the persistent workpad comment and keep it updated in place throughout execution:

````md
## Codex Workpad

```text
<hostname>:<abs-path>@<short-sha>
```

### Plan

- [ ] 1\. Parent task
  - [ ] 1.1 Child task
  - [ ] 1.2 Child task
- [ ] 2\. Parent task

### Acceptance Criteria

- [ ] Criterion 1
- [ ] Criterion 2

### Validation

- [ ] targeted tests: `<command>`

### Notes

- <short progress note with timestamp>

### Confusions

- <only include when something was confusing during execution>
````
