---
name: land
description:
  Squash-merge the current PR, clean up the local workspace, and hand back
  control; use when asked to land or merge.
---

# Land

## Goals

- Squash-merge the PR cleanly.
- Clean up the local workspace after merge.

## Preconditions

- `gh` CLI is authenticated.
- You are on the PR branch.

## Steps

1. Locate the PR for the current branch.
2. Squash-merge with the PR title/body.
3. Clean up the local workspace directory after merge.

## Commands

```bash
# PR context
pr_number=$(gh pr view --json number -q .number)
pr_title=$(gh pr view --json title -q .title)
pr_body=$(gh pr view --json body -q .body)

# Squash-merge
gh pr merge --squash --subject "$pr_title" --body "$pr_body"

# Workspace cleanup
workspace_dir=$(pwd)
workspace_base=$(basename "$workspace_dir")
workspace_parent=$(dirname "$workspace_dir")
cd "$workspace_parent"
rm -rf "$workspace_base"
```

## Failure Handling

- If squash-merge fails, surface the error and stop in `Merging` for follow-up.
- Do not enable auto-merge.
- In the Symphony `Merging` state, assume PR feedback gates were already
  enforced in `In Progress` and `Human Review`; land focuses on merge and
  cleanup.
