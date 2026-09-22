#!/usr/bin/env bash

# Shared KubeBase workspace/config discovery primitives.
# These helpers are intentionally side-effect-light: callers keep control
# over validation policy, diagnostics, and which paths must exist.

kb_workspace_config_dir()
{
    local workspace_dir="$1"
    local workspace_file="$2"
    local config_path
    local candidate

    config_path="$(jq -r '.configuration.path' "$workspace_file")" || return 1

    if [[ "$config_path" = /* ]]; then
        candidate="$config_path"
    else
        candidate="$workspace_dir/$config_path"
    fi

    [ -d "$candidate" ] || return 1

    (
        cd -- "$candidate"
        pwd -P
    )
}


kb_config_json_files()
{
    local config_dir="$1"

    find "$config_dir" \
        -maxdepth 1 \
        \( -type f -o -type l \) \
        -name '*.json' \
        -print0 |
    sort -z
}


kb_config_cluster_files()
{
    local config_dir="$1"
    local schema="$2"
    local schema_version="${3:-}"
    local file

    while IFS= read -r -d '' file; do
        if [ -n "$schema_version" ]; then
            if jq -e \
                --arg schema "$schema" \
                --argjson version "$schema_version" '
                .schema == $schema and .schemaVersion == $version
            ' "$file" >/dev/null 2>&1
            then
                printf '%s\0' "$file"
            fi
        elif [ "$(jq -r '.schema // ""' "$file" 2>/dev/null)" = "$schema" ]; then
            printf '%s\0' "$file"
        fi
    done < <(kb_config_json_files "$config_dir")
}


kb_find_cluster_file()
{
    local cluster_name="$1"
    shift

    local file
    local found=""

    for file in "$@"; do
        if [ "$(jq -r '.name' "$file")" = "$cluster_name" ]; then
            [ -z "$found" ] || return 1
            found="$file"
        fi
    done

    [ -n "$found" ] || return 1
    printf '%s\n' "$found"
}


kb_configured_profile_selectors()
{
    local cluster_file
    local cluster_name
    local user_name

    for cluster_file in "$@"; do
        cluster_name="$(jq -r '.name' "$cluster_file")"

        while IFS= read -r user_name; do
            [ -n "$user_name" ] || continue
            printf '%s/%s\n' "$cluster_name" "$user_name"
        done < <(jq -r '.users | keys[]' "$cluster_file")
    done
}
