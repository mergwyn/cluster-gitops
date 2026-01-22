# Renovate configuration – intent & structure

This directory contains a **split Renovate configuration**.  
The goal is **clarity and safety**, not cleverness.

The root `renovate.json` only *assembles* behaviour by extending the files here.
Each file is behaviour-identical to the original monolithic config.

---

## Design principles

* **Behaviour first** – changes are scaffolded to be diff-clean
* **Low noise** – auto-merge only where proven safe
* **Time as a signal** – release-age delays reduce churn and regressions
* **GitOps friendly** – no assumptions about CI or runtime environment
* **Future-proof** – files map to *intent*, not tools

---

## File overview

### `base.json`
Global Renovate behaviour:
* Schedule and timezone
* Internal checks
* Paths to ignore

This answers: *when* Renovate runs and *where* it should not look.

---

### `helm.json`
Helm-specific parsing rules.

* Explicitly tracks `values.yaml` and `values.yaml.gotmpl`
* Works with Argo CD + Helmfile plugin
* Helmfile itself is treated as a renderer, not a version source

This answers: *where Helm versions and images live*.

---

### `docker.json`
Docker-specific exceptions.

* Disables digest pinning for charts/images where it is unnecessary or harmful

This answers: *when not to be clever with digests*.

---

### `release-ages.json`
Time-based safety rails.

* All updates: minimum 3 days
* Docker digests: 1 day
* Docker minors: 5 days
* Docker majors: 14 days

This answers: *how long the ecosystem has to break before we upgrade*.

---

### `automerge.json`
Noise reduction rules.

* Patch auto-merge for safe ranges
* Targeted minor+patch auto-merge for selected components

This answers: *what is allowed to update without human attention*.

---

### `exceptions.json`
Known-bad or legacy edge cases.

* Version exclusions
* Regex-based matching for problematic image streams

This answers: *what history has taught us not to trust*.

---

## Notes for future changes

* Avoid adding new managers unless strictly required
* Prefer values-driven versioning over helmfile-driven versioning
* Any behavioural change should be intentional and reviewed
* Keep files small and single-purpose

If unsure: **diff against the previous behaviour first**.

