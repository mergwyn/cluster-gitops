#!/usr/bin/env bash
# helm-diff --diff-tool wrapper. helm-diff passes two file paths; we ignore them
# and emit `argocd app diff` output instead (live cluster vs revision/local).
#
# Env (set by doctor-check.sh):
#   ARGO_APP        argocd app name, e.g. argocd/open-webui   (required)
#   ARGO_DIFF_LOCK  lock dir path; only the first call per app runs (required)
#   REVISION        pushed sha/branch -> revision mode
#   ARGO_LOCAL      app dir to upload -> local mode (used when REVISION unset)
#   ARGO_DIFF_LOG   optional file; invocations/results are appended here so a
#                   run can prove the tool was (or wasn't) called by helm-diff
set -uo pipefail

log() {
  if [[ -n "${ARGO_DIFF_LOG:-}" ]]; then
    printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >> "${ARGO_DIFF_LOG}"
  fi
  return 0
}

log "invoked app=${ARGO_APP:-?}"

mkdir "${ARGO_DIFF_LOCK:?}" 2>/dev/null || { log "skipped (lock held)"; exit 0; }

args=(app diff "${ARGO_APP:?}" --server-side-generate)
if [[ -n "${REVISION:-}" ]]; then
  args+=(--revision "$REVISION")
  log "mode=revision rev=${REVISION}"
else
  args+=(--local "${ARGO_LOCAL:?set ARGO_LOCAL or REVISION}")
  log "mode=local dir=${ARGO_LOCAL}"
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmpout="$(mktemp)"; tmperr="$(mktemp)"
KUBECTL_EXTERNAL_DIFF="${HERE}/argocd-ext-diff.sh" argocd "${args[@]}" >"${tmpout}" 2>"${tmperr}"
rc=$?

cat "${tmpout}"
log "result rc=${rc} bytes=$(wc -c < "${tmpout}" | tr -d ' ')"
# argocd: 0 = no diff, 1 = diff, 2 = error. Only 2 is a real failure.
if [[ ${rc} -ge 2 ]]; then
  log "ERROR argocd app diff failed: $(head -c 500 "${tmperr}" | tr '\n' ' ')"
  echo "argocd app diff failed (exit ${rc}) for ${ARGO_APP}" >&2
fi
rm -f "${tmpout}" "${tmperr}"
exit 0
