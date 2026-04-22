#!/usr/bin/env bash

# Parse Namespace flag
TARGET_NS="-A"
while getopts "n:" opt; do
  case $opt in
    n) TARGET_NS="-n $OPTARG" ;;
    *) echo "Usage: $0 [-n namespace]"; exit 1 ;;
  esac
done

TMP_FILE=$(mktemp)

# Expanded Header with Limits
printf "%s\t%s\t%s\t%s\t%s\t%s\n" "NAMESPACE" "DEPLOYMENT" "TYPE" "CUR_REQ" "CUR_LIM" "RECOMMENDED" > "$TMP_FILE"
printf "%s\t%s\t%s\t%s\t%s\t%s\n" "---------" "----------" "----" "-------" "-------" "-----------" >> "$TMP_FILE"

# Get VPAs (filtered by namespace if flag provided)
kubectl get vpa $TARGET_NS -o json | jq -c '.items[]' | while read -r vpa; do
    NS=$(echo "$vpa" | jq -r '.metadata.namespace')
    TARGET_NAME=$(echo "$vpa" | jq -r '.spec.targetRef.name')

    # Recommendations
    REC_CPU=$(echo "$vpa" | jq -r '.status.recommendation.containerRecommendations[0].target.cpu // "0"')
    REC_MEM_RAW=$(echo "$vpa" | jq -r '.status.recommendation.containerRecommendations[0].target.memory // "0"')

    if [[ "$REC_MEM_RAW" =~ ^[0-9]+$ ]] && [ "$REC_MEM_RAW" -gt 0 ]; then
        REC_MEM="$((REC_MEM_RAW / 1024 / 1024))Mi"
    else
        REC_MEM="$REC_MEM_RAW"
    fi

    # Get Current Requests AND Limits
    JSON_RESOURCES=$(kubectl get deploy -n "$NS" "$TARGET_NAME" -o jsonpath='{.spec.template.spec.containers[0].resources}' 2>/dev/null)

    CUR_REQ_CPU=$(echo "$JSON_RESOURCES" | jq -r '.requests.cpu // "unset"')
    CUR_LIM_CPU=$(echo "$JSON_RESOURCES" | jq -r '.limits.cpu // "unset"')

    CUR_REQ_MEM=$(echo "$JSON_RESOURCES" | jq -r '.requests.memory // "unset"')
    CUR_LIM_MEM=$(echo "$JSON_RESOURCES" | jq -r '.limits.memory // "unset"')

    # CPU Row (if differs from Request)
    if [ "$CUR_REQ_CPU" != "$REC_CPU" ]; then
        printf "%s\t%s\t%s\t%s\t%s\t%s\n" "$NS" "$TARGET_NAME" "CPU" "$CUR_REQ_CPU" "$CUR_LIM_CPU" "$REC_CPU" >> "$TMP_FILE"
    fi

    # MEM Row (if differs from Request)
    if [ "$CUR_REQ_MEM" != "$REC_MEM" ]; then
        printf "%s\t%s\t%s\t%s\t%s\t%s\n" "$NS" "$TARGET_NAME" "MEM" "$CUR_REQ_MEM" "$CUR_LIM_MEM" "$REC_MEM" >> "$TMP_FILE"
    fi
done

column -t -s $'\t' "$TMP_FILE"
rm "$TMP_FILE"
