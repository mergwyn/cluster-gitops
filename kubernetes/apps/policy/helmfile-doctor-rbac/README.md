# Helmfile Doctor — PR gate for Renovate/Mend

Everything from our design conversation, wired together for a first test run.

## What's here

```
kubernetes/apps/policy/helmfile-doctor-rbac/   ServiceAccount, ClusterRole,
                                      token Secret, and a Kyverno
                                      ClusterPolicy (generates a RoleBinding
                                      into every namespace) — a normal
                                      helmfile app using bedag/raw, same as
                                      your other raw-manifest apps. Not
                                      part of bootstrap: it depends on
                                      Kyverno's CRDs already existing.

scripts/build-doctor-kubeconfig.sh   One-off: builds a standalone kubeconfig
                                      from the ServiceAccount token, uploads
                                      it as a GitHub secret

scripts/doctor-check.sh              Runs in CI: detects changed apps,
                                      replicates ArgoCD's KUBE_API_VERSIONS /
                                      KUBE_VERSION injection, checks the
                                      critical-package tier from
                                      renovate/automerge.json, runs
                                      `helmfile doctor` per app

.github/workflows/helmfile-doctor.yml   Wires it all into pull_request events
```

## Before you test — things you need to check, not assumptions I can verify

1. **`doctor-check.sh`'s app-name extraction** now matches your real layout:
   `kubernetes/apps/<category>/<app-name>/...`, so the app name is the 4th
   path segment (`awk -F/ '{print $4}'`), gated on changes under
   `kubernetes/apps/` rather than `clusters/` (which you've confirmed only
   holds per-environment variables). Worth a quick sanity check against a
   real diff before trusting it in CI — e.g. `git diff --name-only
   origin/main...HEAD | grep '^kubernetes/apps/' | awk -F/ '{print $4}'`
   on an existing branch with app changes.

2. **Ollama host/model** in the workflow (`HELMFILE_LLM_BASE_URL`,
   `HELMFILE_LLM_MODEL`) are placeholders — set them to your actual Ollama
   instance and model name.

3. **Self-hosted runner**: needs to already be registered against
   `mergwyn/cluster-gitops` and reachable from a network that can hit both
   the k3s-prod API server and your Ollama host.

## Setup order

```bash
# 1. Copy everything into your repo
cp -r .github kubernetes scripts /path/to/cluster-gitops/
cd /path/to/cluster-gitops

# 2. Before committing: check kubernetes/apps/policy/helmfile-doctor-rbac/app.yaml —
#    set syncWave to (your kyverno app's syncWave + 1), and check
#    helmfile.yaml's bedag/raw chart version against whatever version
#    you're already running elsewhere for that chart.

git add .github kubernetes scripts
git commit -m "Add helmfile-doctor PR gate"
git push

# 3. Let ArgoCD pick up and sync the new app (or hard-refresh if needed):
#    kubectl annotate application helmfile-doctor-rbac -n argocd \
#      argocd.argoproj.io/refresh=hard --overwrite

# 4. Confirm Kyverno generated the RoleBindings
kubectl get rolebinding helmfile-doctor-reader -A

# 5. Build the scoped kubeconfig and upload it as a GitHub secret
#    (run from a machine with kubectl access to k3s-prod and gh authenticated)
chmod +x scripts/build-doctor-kubeconfig.sh
./scripts/build-doctor-kubeconfig.sh
```

Since this is a normal GitOps-managed app rather than a bootstrap step, it
comes back automatically on any future cluster rebuild the moment ArgoCD
and Kyverno are synced — no manual `kubectl apply` to remember. Only the
GitHub-side pieces (Actions secret, runner registration, branch protection)
are outside GitOps and need redoing by hand on a new repo/cluster.

## First test — do this before touching branch protection

Open a small, throwaway PR that changes something under `clusters/` (e.g.
bump a digest by hand) and watch the Actions tab. You want to see:

- The job picks up on your self-hosted runner
- `doctor-check.sh` correctly identifies the changed app
- `helmfile doctor` actually reaches your Ollama instance (check the job log
  for the report, not just a bare `helmfile diff` fallback — that fallback
  fires silently if the LLM config or endpoint is wrong, so don't mistake it
  for a real doctor run)
- A comment appears on the PR with the report

Only once this looks right should you add "doctor" as a required status
check in branch protection (Settings → Branches → your `main` rule) —
otherwise a broken job could deadlock every PR against a pending check.

## Then — validate the automerge interaction

This is the part I flagged as needing a real test rather than taking my
word for it: confirm that Renovate's `ignoreTests: true` (used in your
Tier 1–3 `packageRules`) does *not* let it bypass a required GitHub status
check. Do this by:

1. Marking "doctor" required in branch protection
2. Triggering a digest-tier update that would normally automerge
   (matches the `automerge.json` "Auto merge digests" rule)
3. Confirming the PR sits blocked while "doctor" is pending/running, and
   only merges after it passes

If it *doesn't* block — i.e. Renovate/Mend merges anyway — that's a real
finding worth digging into further, not something to paper over.

## Rotating the token

The ServiceAccount token doesn't expire on its own. To rotate it:

```bash
kubectl delete secret helmfile-doctor-token -n kube-system
kubectl apply -f rbac/helmfile-doctor-rbac.yaml
./scripts/build-doctor-kubeconfig.sh
```
