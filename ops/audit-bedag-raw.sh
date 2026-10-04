#!/usr/bin/env bash

set -u

ROOT="${1:-kubernetes/apps}"

if [[ ! -d "$ROOT" ]]; then
    echo "ERROR: directory not found: $ROOT" >&2
    exit 1
fi

echo "Auditing bedag/raw releases under: $ROOT"
echo

found=0

while IFS= read -r -d '' helmfile; do
    relative="${helmfile#"$ROOT"/}"

    # ------------------------------------------------------------
    # Only process regular YAML Helmfiles.
    #
    # .gotmpl Helmfiles need manual inspection because yq cannot
    # reliably parse them before Helmfile evaluates the templates.
    # ------------------------------------------------------------

    if [[ "$helmfile" == *.gotmpl ]]; then
        if grep -Eq 'chart:[[:space:]]*["'\'']?bedag/raw' "$helmfile"; then
            found=1

            echo "============================================================"
            echo "Helmfile : $relative"
            echo
            echo "  .gotmpl Helmfile containing bedag/raw"
            echo "  RESULT: NEEDS REVIEW"
            echo
        fi

        continue
    fi

    # Find the indexes of releases using bedag/raw.
    while IFS= read -r index; do
        [[ -z "$index" ]] && continue

        found=1

        release_name="$(
            yq -r ".releases[$index].name // \"<unnamed>\" | tostring" \
                "$helmfile"
        )"

        echo "============================================================"
        echo "Helmfile : $relative"
        echo "Release  : $release_name"
        echo

        needs_review=0

        # --------------------------------------------------------
        # bedag/raw's own "templates:" feature.
        #
        # This is significant because these are resources generated
        # by the raw chart rather than ordinary static resources.
        # --------------------------------------------------------

        if yq -e ".releases[$index].values[]? | type == \"!!map\"" \
            "$helmfile" >/dev/null 2>&1
        then
            # Don't automatically flag maps. We only care about a
            # top-level "templates" key in the release.
            :
        fi

        if yq -e ".releases[$index].templates" "$helmfile" \
            >/dev/null 2>&1
        then
            echo "  raw chart templates : YES"
            needs_review=1
        else
            echo "  raw chart templates : NO"
        fi

        # --------------------------------------------------------
        # Values files.
        # --------------------------------------------------------

        values_found=0

        while IFS= read -r values_file; do
            [[ -z "$values_file" ]] && continue

            values_found=1

            values_path="$(dirname "$helmfile")/$values_file"

            echo "  Values              : $values_file"

            if [[ ! -f "$values_path" ]]; then
                echo "    !! FILE NOT FOUND"
                needs_review=1
                continue
            fi

            # ----------------------------------------------------
            # A .gotmpl values file is definitely templated.
            # ----------------------------------------------------

            if [[ "$values_file" == *.gotmpl ]]; then
                echo "    → .gotmpl file"
                needs_review=1
            fi

            # ----------------------------------------------------
            # Look for actual Go template expressions in the values
            # file.
            # ----------------------------------------------------

            if grep -Eq '\{\{[-]?' "$values_path"; then
                echo "    → contains {{ ... }} expressions"
                needs_review=1

                grep -n -E '\{\{[-]?' "$values_path" |
                    sed 's/^/      /'
            fi

            # ----------------------------------------------------
            # tpl usage.
            # ----------------------------------------------------

            if grep -Eq '(^|[^[:alnum:]_])tpl[[:space:]]' "$values_path"; then
                echo "    → contains tpl usage"
                needs_review=1
            fi

        done < <(
            yq -r ".releases[$index].values[]? | select(tag == \"!!str\")" \
                "$helmfile"
        )

        if [[ "$values_found" -eq 0 ]]; then
            echo "  Values              : none"
        fi

        echo

        if [[ "$needs_review" -eq 0 ]]; then
            echo "  RESULT: EASY MIGRATION"
            echo "          Raw resources appear to be static YAML."
        else
            echo "  RESULT: NEEDS REVIEW"
            echo "          Raw resources contain templating."
        fi

        echo

    done < <(
        yq -r '
            .releases // []
            | to_entries[]
            | select(.value.chart == "bedag/raw")
            | .key
        ' "$helmfile"

    )

done < <(
    find "$ROOT" -type f \
        \( -name 'helmfile.yaml' -o -name 'helmfile.yaml.gotmpl' \) \
        -print0 |
        sort -z
)

if [[ "$found" -eq 0 ]]; then
    echo "No bedag/raw releases found."
else
    echo "Audit complete."
fi
