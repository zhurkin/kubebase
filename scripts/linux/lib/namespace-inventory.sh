#!/usr/bin/env bash

# Shared KubeBase namespace inventory discovery/cache primitives.
#
# Discovery policy (schema v2):
#   1. Prefer cluster-wide Namespace LIST.
#   2. If LIST fails, use `kubectl auth can-i --list` only as a source of
#      candidate resourceNames, then verify every Namespace with the API.
#   3. Fallback discovery is always incomplete.
#
# Cache schema/layout v2 remains the current implementation. A later cache-v3
# migration can change this library without duplicating policy across Steps
# 60 and 80.


if ! declare -F kb_fail >/dev/null 2>&1; then
    _KB_NAMESPACE_LIB_DIR="$(
        cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
        pwd -P
    )"
    source "$_KB_NAMESPACE_LIB_DIR/common.sh"
    unset _KB_NAMESPACE_LIB_DIR
fi

KB_NAMESPACE_INVENTORY_SCHEMA="kubebase.namespaceInventory"
KB_NAMESPACE_INVENTORY_SCHEMA_VERSION=2


kb_namespace_name_is_valid()
{
    local value="$1"

    [ "${#value}" -le 63 ] || return 1
    [[ "$value" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]
}


kb_namespace_group_id_from_json()
{
    jq -r '
        (
            .metadata.labels["field.cattle.io/projectId"]
            // ""
        ) as $label
        |
        (
            .metadata.annotations["field.cattle.io/projectId"]
            // ""
        ) as $annotation
        |
        if $label != "" then
            $label
        elif $annotation != "" then
            ($annotation | split(":") | last)
        else
            ""
        end
    '
}


kb_namespace_entries_from_list()
{
    jq -c '
        [
            .items[]
            |
            {
                name: .metadata.name,
                groupId: (
                    .metadata.labels["field.cattle.io/projectId"]
                    //
                    (
                        .metadata.annotations["field.cattle.io/projectId"]
                        // ""
                        |
                        if . == "" then null else (split(":") | last) end
                    )
                )
            }
        ]
    '
}


kb_namespace_normalized_inventory()
{
    local cluster="$1"
    local user="$2"
    local context="$3"
    local method="$4"
    local complete="$5"
    local entries_json="$6"
    local timestamp="$7"

    jq -n \
        --arg schema "$KB_NAMESPACE_INVENTORY_SCHEMA" \
        --argjson schemaVersion "$KB_NAMESPACE_INVENTORY_SCHEMA_VERSION" \
        --arg cluster "$cluster" \
        --arg user "$user" \
        --arg context "$context" \
        --arg method "$method" \
        --argjson complete "$complete" \
        --arg discoveredAt "$timestamp" \
        --argjson entries "$entries_json" '
        {
            schema: $schema,
            schemaVersion: $schemaVersion,
            profile: {
                cluster: $cluster,
                user: $user,
                context: $context
            },
            discoveredAt: $discoveredAt,
            method: $method,
            complete: $complete,
            entries: (
                $entries
                | unique_by(.name)
                | sort_by(.name)
            )
        }
    '
}


kb_namespace_discover_live()
{
    local kubectl_bin="$1"
    local kubeconfig="$2"
    local context="$3"
    local cluster="$4"
    local user="$5"
    local request_timeout="$6"
    local temp_dir="${7:-}"

    local namespace_json
    local list_error_file
    local review_text
    local review_error_file
    local request_namespace
    local candidate
    local candidate_json
    local candidate_error_file
    local group_id
    local entries_file
    local entries_json
    local timestamp
    local -a candidates=()

    KB_NAMESPACE_DISCOVERY_JSON=""
    KB_NAMESPACE_DISCOVERY_METHOD=""
    KB_NAMESPACE_DISCOVERY_COMPLETE="false"
    KB_NAMESPACE_DISCOVERY_NOTE=""
    KB_NAMESPACE_DISCOVERY_ERROR=""
    KB_NAMESPACE_DISCOVERY_API_READY="false"
    KB_NAMESPACE_DISCOVERY_LIST_ERROR=""
    KB_NAMESPACE_DISCOVERY_NAMES_FOUND=0
    KB_NAMESPACE_DISCOVERY_NAMES_VERIFIED=0

    if [ -n "$temp_dir" ]; then
        list_error_file="$(mktemp "$temp_dir/namespace-list-error.XXXXXX")"
        review_error_file="$(mktemp "$temp_dir/namespace-review-error.XXXXXX")"
        entries_file="$(mktemp "$temp_dir/namespace-entries.XXXXXX")"
    else
        list_error_file="$(mktemp)"
        review_error_file="$(mktemp)"
        entries_file="$(mktemp)"
    fi

    : > "$list_error_file"

    if namespace_json="$(
        "$kubectl_bin" \
            --kubeconfig "$kubeconfig" \
            --context "$context" \
            --request-timeout="$request_timeout" \
            get namespaces \
            -o json \
            2>"$list_error_file"
    )"
    then
        entries_json="$(kb_namespace_entries_from_list <<< "$namespace_json")"
        timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

        KB_NAMESPACE_DISCOVERY_JSON="$(
            kb_namespace_normalized_inventory \
                "$cluster" \
                "$user" \
                "$context" \
                "namespace-list" \
                true \
                "$entries_json" \
                "$timestamp"
        )"
        KB_NAMESPACE_DISCOVERY_METHOD="namespace-list"
        KB_NAMESPACE_DISCOVERY_COMPLETE="true"
        KB_NAMESPACE_DISCOVERY_API_READY="true"
        KB_NAMESPACE_DISCOVERY_NAMES_FOUND="$(jq 'length' <<< "$entries_json")"
        KB_NAMESPACE_DISCOVERY_NAMES_VERIFIED="$KB_NAMESPACE_DISCOVERY_NAMES_FOUND"

        rm -f -- "$list_error_file" "$review_error_file" "$entries_file"
        return 0
    fi

    KB_NAMESPACE_DISCOVERY_LIST_ERROR="$(kb_first_nonempty_line_file "$list_error_file")"

    case "$KB_NAMESPACE_DISCOVERY_LIST_ERROR" in
        *Forbidden*|*forbidden*)
            KB_NAMESPACE_DISCOVERY_API_READY="true"
            ;;
    esac

    request_namespace="$(
        "$kubectl_bin" \
            --kubeconfig "$kubeconfig" \
            config view \
            -o json 2>/dev/null |
        jq -r \
            --arg context "$context" '
            [
                .contexts[]
                | select(.name == $context)
                | .context.namespace // ""
            ][0] // ""
        ' 2>/dev/null || true
    )"

    if [ -z "$request_namespace" ]; then
        request_namespace="default"
    fi

    : > "$review_error_file"

    if ! review_text="$(
        "$kubectl_bin" \
            --kubeconfig "$kubeconfig" \
            --context "$context" \
            --request-timeout="$request_timeout" \
            auth can-i \
            --list \
            --namespace "$request_namespace" \
            2>"$review_error_file"
    )"
    then
        KB_NAMESPACE_DISCOVERY_ERROR="namespace list: $(kb_first_nonempty_line_file "$list_error_file"); rules review: $(kb_first_nonempty_line_file "$review_error_file")"
        rm -f -- "$list_error_file" "$review_error_file" "$entries_file"
        return 1
    fi

    mapfile -t candidates < <(
        awk -F '[[:space:]][[:space:]]+' '
            $1 == "namespaces" && $3 ~ /^\[[^]]*\]$/ {
                names = $3
                sub(/^\[/, "", names)
                sub(/\]$/, "", names)

                count = split(names, parts, /[[:space:]]+/)
                for (i = 1; i <= count; i++) {
                    if (parts[i] != "" && parts[i] != "*") {
                        print parts[i]
                    }
                }
            }
        ' <<< "$review_text" |
        sort -u
    )

    : > "$entries_file"

    for candidate in "${candidates[@]}"; do
        [ -n "$candidate" ] || continue
        kb_namespace_name_is_valid "$candidate" || continue

        KB_NAMESPACE_DISCOVERY_NAMES_FOUND=$((KB_NAMESPACE_DISCOVERY_NAMES_FOUND + 1))

        if [ -n "$temp_dir" ]; then
            candidate_error_file="$(mktemp "$temp_dir/namespace-candidate-error.XXXXXX")"
        else
            candidate_error_file="$(mktemp)"
        fi

        if candidate_json="$(
            "$kubectl_bin" \
                --kubeconfig "$kubeconfig" \
                --context "$context" \
                --request-timeout="$request_timeout" \
                get namespace "$candidate" \
                -o json \
                2>"$candidate_error_file"
        )"
        then
            group_id="$(kb_namespace_group_id_from_json <<< "$candidate_json")"

            jq -cn \
                --arg name "$candidate" \
                --arg groupId "$group_id" '
                {
                    name: $name,
                    groupId: (
                        if $groupId == "" then null else $groupId end
                    )
                }
            ' >> "$entries_file"

            KB_NAMESPACE_DISCOVERY_NAMES_VERIFIED=$((KB_NAMESPACE_DISCOVERY_NAMES_VERIFIED + 1))
        fi

        rm -f -- "$candidate_error_file"
    done

    entries_json="$(jq -s '.' "$entries_file")"
    timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

    KB_NAMESPACE_DISCOVERY_JSON="$(
        kb_namespace_normalized_inventory \
            "$cluster" \
            "$user" \
            "$context" \
            "auth-can-i" \
            false \
            "$entries_json" \
            "$timestamp"
    )"
    KB_NAMESPACE_DISCOVERY_METHOD="auth-can-i"
    KB_NAMESPACE_DISCOVERY_COMPLETE="false"

    case "$KB_NAMESPACE_DISCOVERY_LIST_ERROR" in
        *Forbidden*|*forbidden*)
            KB_NAMESPACE_DISCOVERY_NOTE="cluster-wide namespace LIST is forbidden"
            ;;
        *)
            KB_NAMESPACE_DISCOVERY_NOTE="cluster-wide namespace LIST did not succeed"
            ;;
    esac

    rm -f -- "$list_error_file" "$review_error_file" "$entries_file"
    return 0
}


kb_namespace_cache_v2_path()
{
    local workspace="$1"
    local cluster="$2"
    local user="$3"

    printf '%s/.kubebase/cache/namespaces/%s/%s.json\n' \
        "$workspace" \
        "$cluster" \
        "$user"
}


kb_namespace_cache_v2_write()
{
    local workspace="$1"
    local cluster="$2"
    local user="$3"
    local inventory="$4"

    local state_root="$workspace/.kubebase"
    local cache_root="$state_root/cache"
    local namespace_root="$cache_root/namespaces"
    local cache_dir="$namespace_root/$cluster"
    local cache_file="$cache_dir/$user.json"
    local temp="$cache_file.tmp.$$"
    local path

    umask 077

    [ ! -L "$state_root" ] || \
        kb_fail "internal KubeBase state must not be a symlink: $state_root"

    for path in "$state_root" "$cache_root" "$namespace_root" "$cache_dir"; do
        [ ! -L "$path" ] || \
            kb_fail "KubeBase cache path must not be a symlink: $path"

        if [ -e "$path" ] && [ ! -d "$path" ]; then
            kb_fail "KubeBase cache path is not a directory: $path"
        fi

        if [ ! -d "$path" ]; then
            mkdir -- "$path"
        fi

        chmod 700 "$path"
    done

    printf '%s\n' "$inventory" > "$temp"
    chmod 600 "$temp"
    mv -f -- "$temp" "$cache_file"

    KB_NAMESPACE_CACHE_FILE="$cache_file"
}


kb_namespace_cache_v2_valid()
{
    local cache_file="$1"
    local cluster="$2"
    local user="$3"
    local context="$4"

    [ -f "$cache_file" ] && [ ! -L "$cache_file" ] || return 1

    jq -e \
        --arg schema "$KB_NAMESPACE_INVENTORY_SCHEMA" \
        --argjson version "$KB_NAMESPACE_INVENTORY_SCHEMA_VERSION" \
        --arg cluster "$cluster" \
        --arg user "$user" \
        --arg context "$context" '
        .schema == $schema
        and
        .schemaVersion == $version
        and
        .profile.cluster == $cluster
        and
        .profile.user == $user
        and
        .profile.context == $context
        and
        (.entries | type) == "array"
    ' "$cache_file" >/dev/null 2>&1
}


kb_namespace_cache_v2_load()
{
    local cache_file="$1"

    jq \
        --argjson version "$KB_NAMESPACE_INVENTORY_SCHEMA_VERSION" '
        .schemaVersion = $version
        | .entries |= map(
            {
                name: .name,
                groupId: (.groupId // null)
            }
        )
    ' "$cache_file"
}
