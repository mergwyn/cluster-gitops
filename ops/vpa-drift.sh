#!/usr/bin/env bash
set -euo pipefail
ns="${1:?usage: $0 <namespace>}"

vpa=$(kubectl get vpa -n "$ns" -o json)
wl=$(kubectl get deploy,sts,ds -n "$ns" -o json)

{
  printf 'CONTAINER\tMANIFEST_CPU\tVPA_CPU\tMANIFEST_MEM\tVPA_MEM\n'
  jq -rn --argjson vpa "$vpa" --argjson wl "$wl" '
    # CPU quantity -> millicores, e.g. "2" -> "2000m", "11m" -> "11m"
    def cpu:
      if . == null then "-"
      elif endswith("m") then (.[:-1] | tonumber | round | tostring) + "m"
      else (tonumber * 1000 | round | tostring) + "m"
      end;

    # Memory quantity -> Mi, e.g. "1239M" -> "1182Mi", "764046746" -> "729Mi"
    def mem:
      if . == null then "-"
      else
        capture("^(?<n>[0-9.]+)(?<u>[A-Za-z]*)$") as $m
        | ({"":1, "Ki":1024, "Mi":1048576, "Gi":1073741824, "Ti":1099511627776,
            "k":1000, "K":1000, "M":1000000, "G":1000000000, "T":1000000000000}[$m.u]) as $f
        | ($m.n | tonumber) * $f / 1048576 | round | tostring + "Mi"
      end;

    ($vpa.items
      | map(select(.status.recommendation)
            | .spec.targetRef as $t
            | .status.recommendation.containerRecommendations[]
            | {key: "\($t.kind)/\($t.name)/\(.containerName)", value: .target})
      | from_entries) as $rec
    | $wl.items[]
    | .kind as $k | .metadata.name as $n
    | .spec.template.spec.containers[]
    | "\($k)/\($n)/\(.name)" as $key
    | [$key,
       (.resources.requests.cpu    | cpu), ($rec[$key].cpu    | cpu),
       (.resources.requests.memory | mem), ($rec[$key].memory | mem)]
    | @tsv'
} | column -t -s $'\t'
