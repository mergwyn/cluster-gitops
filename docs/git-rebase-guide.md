# Rebasing Long-Running Feature Branches (Clean History)

## Why git CLI, not GitHub web UI

GitHub's web interface only offers "Update branch" (a merge commit) or squash-merge.
It cannot:
- Run an interactive rebase
- Let you edit, reorder, or squash individual commits
- Give you control during conflict resolution

For clean, minimal history, use the git CLI locally.

## Prerequisites

- `git rerere` enabled (see step 4) — very useful when rebasing multiple
  branches that will hit similar conflicts against the same target branch.

## Step-by-step process

### 1. Commit or stash outstanding changes

`git rebase` will refuse to start with a dirty working tree, but check anyway:

```bash
git status
```

Commit or stash anything outstanding before continuing.

### 2. Create a backup branch (safety net)

Before rewriting history, create a backup so you can always get back to the
exact pre-rebase state:

```bash
git checkout your-feature-branch
git branch backup/your-feature-branch-pre-rebase
git push origin backup/your-feature-branch-pre-rebase
```

Pushing the backup means it survives even if something happens to your
local repo (e.g. switching between Mac Mini and a server).

To restore if the rebase goes wrong:

```bash
git checkout your-feature-branch
git reset --hard backup/your-feature-branch-pre-rebase
```

Once you've verified the rebased branch is good, delete the backup:

```bash
git branch -D backup/your-feature-branch-pre-rebase
git push origin --delete backup/your-feature-branch-pre-rebase
```

Note: `git reflog` also retains the pre-rebase commit locally for ~90 days
by default, but it's local-only and slower to locate under pressure — the
backup branch is the more reliable option.

### 3. Fetch the latest target branch

```bash
git fetch origin
```

### 4. Rebase your feature branch

```bash
git checkout your-feature-branch
git rebase origin/main
```

Git replays your commits one at a time on top of `main`.

### 5. Resolve conflicts as they occur

For each commit that conflicts:

```bash
# fix the conflicted files
git add <resolved-files>
git rebase --continue
```

If a commit turns out to be redundant after resolving conflicts:

```bash
git rebase --skip
```

To abort and start over if something goes wrong:

```bash
git rebase --abort
```

### 6. Enable `git rerere` (reuse recorded resolutions)

Run once, globally:

```bash
git config --global rerere.enabled true
```

If you resolve the same conflict on one branch, `rerere` will remember and
auto-apply that resolution when you rebase your other long-running branches
against the same target. Always review auto-resolved hunks before continuing.

### 7. Clean up commit history

Use interactive rebase to keep only the minimal, meaningful commits:

```bash
git rebase -i origin/main
```

In the editor:
- `pick` — keep commit as-is
- `squash` / `fixup` — merge into the previous commit (fixup discards the message)
- `reword` — edit the commit message
- reorder lines to change commit order

Goal: end up with commits that represent the actual feature changes, plus
any necessary conflict-resolution changes folded into the relevant commit
(not left as separate noise commits).

### 8. Push the rewritten branch

```bash
git push --force-with-lease
```

Use `--force-with-lease`, not `--force`. It fails safely if someone else
has pushed to the branch since you last fetched, preventing accidental
overwrite of remote work.

### 9. Repeat for other long-running branches

With `rerere` enabled, subsequent branches against the same target should
require less manual conflict resolution.

## Using a Zed coding agent (supervised, not autonomous)

An agent can safely handle the mechanical git steps, but should **not**
resolve conflicts or force-push unsupervised — especially for Puppet/k3s
manifests where a wrong-but-plausible resolution can silently break
boot-critical config (ZBM, rEFInd) or cluster state.

Copy the block below into the Zed agent window, replacing `<branch-name>`.

```
Task: Rebase the branch <branch-name> onto origin/main, keeping history
clean and minimal.

Steps — stop and wait for my confirmation at each ⏸ marker:

1. Run `git status`. If dirty, tell me and stop.
2. Create and push a backup branch:
   backup/<branch-name>-pre-rebase
3. Run `git fetch origin`.
4. Start `git rebase origin/main`.
5. ⏸ On each conflict: show me the conflicting hunks and your proposed
   resolution. Do NOT run `git add` or `git rebase --continue` until I
   approve.
6. Once the rebase completes cleanly, run `git log --oneline origin/main..HEAD`
   and propose an interactive rebase plan (squash/fixup/reword) to keep
   commits minimal. ⏸ Show me the plan before applying.
7. ⏸ Show me `git diff origin/main..HEAD` in full before any push.
8. Do NOT run `git push --force-with-lease` — I will run that myself.
```

**Notes:**
- If the agent proposes a conflict resolution you're unsure about, ask it
  to explain the reasoning before approving — don't just accept silently.
- Run your normal validation (Puppet syntax check, ArgoCD diff/dry-run)
  after the rebase completes, before you do the manual force-push.
- Repeat with a new `<branch-name>` for each long-running branch.

## Quick reference

| Task | Command |
|---|---|
| Check for uncommitted changes | `git status` |
| Create backup branch | `git branch backup/your-feature-branch-pre-rebase` |
| Push backup branch | `git push origin backup/your-feature-branch-pre-rebase` |
| Restore from backup | `git reset --hard backup/your-feature-branch-pre-rebase` |
| Delete backup (local + remote) | `git branch -D backup/...` then `git push origin --delete backup/...` |
| Fetch latest target | `git fetch origin` |
| Start rebase | `git rebase origin/main` |
| Continue after resolving | `git rebase --continue` |
| Skip a commit | `git rebase --skip` |
| Abort rebase | `git rebase --abort` |
| Interactive cleanup | `git rebase -i origin/main` |
| Safe force-push | `git push --force-with-lease` |
| Enable resolution reuse | `git config --global rerere.enabled true` |
