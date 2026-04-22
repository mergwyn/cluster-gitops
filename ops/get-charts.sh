#!/usr/bin/env bash

declare -A OCI_KNOWN
# Core Stack
OCI_KNOWN["argoproj/argo-cd"]="ghcr.io/argoproj/argo-helm/argo-cd"
OCI_KNOWN["jetstack/cert-manager"]="quay.io/jetstack/cert-manager"
OCI_KNOWN["openebs/openebs"]="openebs.github.io/charts/openebs"
OCI_KNOWN["metallb/metallb"]="quay.io/metallb/metallb"
OCI_KNOWN["node-feature-discovery/node-feature-discovery"]="ghcr.io/kubernetes-sigs/node-feature-discovery/charts/node-feature-discovery"
# The "30-apps" fix
OCI_KNOWN["bjw-s-labs/app-template"]="ghcr.io/bjw-s/charts/app-template"
OCI_KNOWN["bjw-s/app-template"]="ghcr.io/bjw-s/charts/app-template"

echo "📂 Starting OCI Migration Scan"

find [1-9]*-* -name "helmfile.yaml" | while read -r FILE; do
    echo -e "\n📄 File: $FILE"

    # Capture every release, including bedag/raw
    mapfile -t RELEASES < <(yq eval '.releases[] | .name + "|" + .chart' "$FILE" 2>/dev/null)

    for LINE in "${RELEASES[@]}"; do
        [[ -z "$LINE" || "$LINE" == "null" || "$LINE" == *"|null"* ]] && continue
        
        REL_NAME="${LINE%|*}"
        REL_CHART="${LINE#*|}"

        echo "   🔍 $REL_NAME ($REL_CHART)"

        # 1. Check Hardcoded Map (Highest Priority)
        if [[ -n "${OCI_KNOWN[$REL_CHART]}" ]]; then
            echo "      ✅ FOUND (Map): oci://${OCI_KNOWN[$REL_CHART]}"
            continue
        fi

        # 2. Probe Loop for everything else (including bedag/raw)
        ORG="${REL_CHART%/*}"
        NAME="${REL_CHART#*/}"
        
        PROBES=(
            "ghcr.io/$ORG/charts/$NAME"
            "ghcr.io/$ORG/$NAME"
            "ghcr.io/$ORG/${NAME}-helm"
        )

        MATCHED=false
        for PROBE in "${PROBES[@]}"; do
            # Quietly check if the tag list exists
            if skopeo list-tags "docker://$PROBE" > /dev/null 2>&1; then
                echo "      ✅ FOUND (Probe): oci://$PROBE"
                MATCHED=true
                break
            fi
        done

        if [[ "$MATCHED" == "false" ]]; then
            echo "      ❌ No OCI path found."
        fi
    done
done

