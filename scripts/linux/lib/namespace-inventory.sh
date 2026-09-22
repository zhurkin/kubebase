#!/usr/bin/env bash

# Shared KubeBase namespace inventory discovery/cache primitives.
#
# Discovery policy (schema v3):
#   1. Prefer cluster-wide Namespace LIST.
#   2. If LIST fails, use `kubectl auth can-i --list` only as a source of
#      candidate resourceNames, then verify every Namespace with the API.
#   3. Fallback discovery is always incomplete.
#
# Cache layout v3 is context-specific and preserves complete and partial
# snapshots independently:
#
#   .kubebase/cache/namespaces/<cluster>/<user>/<sha256(context)>/
#     latest.json
#     complete.json
#     partial.json
#
# A partial refresh never replaces complete.json. Hashes are filesystem keys
# only; the original context remains part of the validated cache data.


if ! declare -F kb_fail >/dev/null 2>&1; then
    _KB_NAMESPACE_LIB_DIR="$(
        cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
        pwd -P
    )"
    source "$_KB_NAMESPACE_LIB_DIR/common.sh"
    unset _KB_NAMESPACE_LIB_DIR
fi

KB_NAMESPACE_INVENTORY_SCHEMA="kubebase.namespaceInventory"
KB_NAMESPACE_INVENTORY_SCHEMA_VERSION=3


kb_namespace_name_is_valid()
{
    local value="$1"

    [ "${#value}" -le 63 ] || return 1
    [[ "$value" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]
}


kb_namespace_group_json_from_json()
{
    jq -c '
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
        (
            if $label != "" then
                $label
            elif $annotation != "" then
                ($annotation | split(":") | last)
            else
                ""
            end
        ) as $id
        |
        if $id == "" then
            null
        else
            {
                kind: "rancher-project",
                id: $id
            }
        end
    '
}


kb_namespace_entries_from_list()
{
    jq -c '
        def namespace_group:
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
            (
                if $label != "" then
                    $label
                elif $annotation != "" then
                    ($annotation | split(":") | last)
                else
                    ""
                end
            ) as $id
            |
            if $id == "" then
                null
            else
                {
                    kind: "rancher-project",
                    id: $id
                }
            end;

        [
            .items[]
            |
            {
                name: .metadata.name,
                group: namespace_group
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
    local group_json
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

    # `auth can-i --list` is not treated as evidence. It is only a source of
    # candidate names. Every candidate must still be verified by GET below.
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
            group_json="$(kb_namespace_group_json_from_json <<< "$candidate_json")"

            jq -cn \
                --arg name "$candidate" \
                --argjson group "$group_json" '
                {
                    name: $name,
                    group: $group
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


kb_namespace_context_hash()
{
    local context="$1"

    [ -n "$context" ] || kb_fail "namespace cache context must not be empty"
    command -v sha256sum >/dev/null 2>&1 || \
        kb_fail "sha256sum is required for namespace cache keys"

    printf '%s' "$context" | sha256sum | awk '{ print $1 }'
}


kb_namespace_cache_v3_dir()
{
    local workspace="$1"
    local cluster="$2"
    local user="$3"
    local context="$4"
    local context_hash

    kb_safe_name "$cluster" || kb_fail "invalid cluster name for namespace cache: $cluster"
    kb_safe_name "$user" || kb_fail "invalid user name for namespace cache: $user"

    context_hash="$(kb_namespace_context_hash "$context")"

    printf '%s/.kubebase/cache/namespaces/%s/%s/%s\n' \
        "$workspace" \
        "$cluster" \
        "$user" \
        "$context_hash"
}


kb_namespace_cache_v3_path()
{
    local workspace="$1"
    local cluster="$2"
    local user="$3"
    local context="$4"
    local slot="$5"
    local cache_dir

    case "$slot" in
        latest|complete|partial)
            ;;
        *)
            kb_fail "invalid namespace cache slot: $slot"
            ;;
    esac

    cache_dir="$(kb_namespace_cache_v3_dir "$workspace" "$cluster" "$user" "$context")"
    printf '%s/%s.json\n' "$cache_dir" "$slot"
}


kb_namespace_cache_v3_prepare_dir()
{
    local workspace="$1"
    local cluster="$2"
    local user="$3"
    local context="$4"

    local state_root="$workspace/.kubebase"
    local cache_root="$state_root/cache"
    local namespace_root="$cache_root/namespaces"
    local cluster_dir="$namespace_root/$cluster"
    local user_dir="$cluster_dir/$user"
    local context_dir
    local path

    context_dir="$(kb_namespace_cache_v3_dir "$workspace" "$cluster" "$user" "$context")"

    umask 077

    for path in \
        "$state_root" \
        "$cache_root" \
        "$namespace_root" \
        "$cluster_dir" \
        "$user_dir" \
        "$context_dir"
    do
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

    KB_NAMESPACE_CACHE_DIR="$context_dir"
}


kb_namespace_cache_v3_valid()
{
    local cache_file="$1"
    local cluster="$2"
    local user="$3"
    local context="$4"
    local expected_complete="${5:-any}"

    [ -f "$cache_file" ] && [ ! -L "$cache_file" ] && [ -r "$cache_file" ] || return 1

    case "$expected_complete" in
        any|true|false)
            ;;
        *)
            return 1
            ;;
    esac

    jq -e \
        --arg schema "$KB_NAMESPACE_INVENTORY_SCHEMA" \
        --argjson version "$KB_NAMESPACE_INVENTORY_SCHEMA_VERSION" \
        --arg cluster "$cluster" \
        --arg user "$user" \
        --arg context "$context" \
        --arg expectedComplete "$expected_complete" '
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
        (.discoveredAt | type) == "string"
        and
        (.discoveredAt | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
        and
        (.method | type) == "string"
        and
        (.complete | type) == "boolean"
        and
        (
            $expectedComplete == "any"
            or
            (.complete | tostring) == $expectedComplete
        )
        and
        (.entries | type) == "array"
        and
        all(
            .entries[];
            (.name | type) == "string"
            and
            (.name | length) <= 63
            and
            (.name | test("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$"))
            and
            (
                .group == null
                or
                (
                    (.group | type) == "object"
                    and
                    .group.kind == "rancher-project"
                    and
                    (.group.id | type) == "string"
                    and
                    (.group.id | length) > 0
                    and
                    (
                        (.group | has("name") | not)
                        or
                        (.group.name | type) == "string"
                    )
                )
            )
        )
        and
        (([.entries[].name] | length) == ([.entries[].name] | unique | length))
    ' "$cache_file" >/dev/null 2>&1
}


kb_namespace_cache_v3_inventory_valid_text()
{
    local inventory="$1"
    local cluster="$2"
    local user="$3"
    local context="$4"

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
        (.discoveredAt | type) == "string"
        and
        (.discoveredAt | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
        and
        (.method | type) == "string"
        and
        (.complete | type) == "boolean"
        and
        (.entries | type) == "array"
        and
        all(
            .entries[];
            (.name | type) == "string"
            and
            (.name | length) <= 63
            and
            (.name | test("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$"))
            and
            (
                .group == null
                or
                (
                    (.group | type) == "object"
                    and
                    .group.kind == "rancher-project"
                    and
                    (.group.id | type) == "string"
                    and
                    (.group.id | length) > 0
                    and
                    (
                        (.group | has("name") | not)
                        or
                        (.group.name | type) == "string"
                    )
                )
            )
        )
        and
        (([.entries[].name] | length) == ([.entries[].name] | unique | length))
    ' <<< "$inventory" >/dev/null 2>&1
}


kb_namespace_cache_v3_retire_v2_if_same_context()
{
    local workspace="$1"
    local cluster="$2"
    local user="$3"
    local context="$4"
    local old_file="$workspace/.kubebase/cache/namespaces/$cluster/$user.json"

    [ -f "$old_file" ] && [ ! -L "$old_file" ] || return 0

    if jq -e \
        --arg schema "$KB_NAMESPACE_INVENTORY_SCHEMA" \
        --arg cluster "$cluster" \
        --arg user "$user" \
        --arg context "$context" '
        .schema == $schema
        and
        .schemaVersion == 2
        and
        .profile.cluster == $cluster
        and
        .profile.user == $user
        and
        .profile.context == $context
    ' "$old_file" >/dev/null 2>&1
    then
        rm -f -- "$old_file"
    fi
}


kb_namespace_cache_v3_write()
{
    local workspace="$1"
    local cluster="$2"
    local user="$3"
    local context="$4"
    local inventory="$5"

    local complete
    local slot
    local latest_file
    local slot_file
    local latest_temp
    local slot_temp

    kb_namespace_cache_v3_inventory_valid_text \
        "$inventory" "$cluster" "$user" "$context" || \
        kb_fail "refusing to write invalid namespace inventory v3"

    complete="$(jq -r '.complete' <<< "$inventory")"

    if [ "$complete" = "true" ]; then
        slot="complete"
    else
        slot="partial"
    fi

    kb_namespace_cache_v3_prepare_dir \
        "$workspace" "$cluster" "$user" "$context"

    latest_file="$KB_NAMESPACE_CACHE_DIR/latest.json"
    slot_file="$KB_NAMESPACE_CACHE_DIR/$slot.json"
    latest_temp="$(mktemp "$KB_NAMESPACE_CACHE_DIR/.latest.XXXXXX")"
    slot_temp="$(mktemp "$KB_NAMESPACE_CACHE_DIR/.$slot.XXXXXX")"

    printf '%s\n' "$inventory" > "$latest_temp"
    printf '%s\n' "$inventory" > "$slot_temp"
    chmod 600 "$latest_temp" "$slot_temp"

    # Preserve the class-specific snapshot first. If a process is interrupted
    # before latest.json is replaced, readers can still recover from the slot.
    mv -f -- "$slot_temp" "$slot_file"
    mv -f -- "$latest_temp" "$latest_file"

    KB_NAMESPACE_CACHE_FILE="$latest_file"
    KB_NAMESPACE_CACHE_LATEST_FILE="$latest_file"
    KB_NAMESPACE_CACHE_SNAPSHOT_FILE="$slot_file"
    KB_NAMESPACE_CACHE_SNAPSHOT_KIND="$slot"

    kb_namespace_cache_v3_retire_v2_if_same_context \
        "$workspace" "$cluster" "$user" "$context"
}


kb_namespace_cache_v3_select_latest()
{
    local workspace="$1"
    local cluster="$2"
    local user="$3"
    local context="$4"

    local latest_file
    local complete_file
    local partial_file
    local complete_valid=0
    local partial_valid=0
    local complete_timestamp=""
    local partial_timestamp=""

    latest_file="$(kb_namespace_cache_v3_path "$workspace" "$cluster" "$user" "$context" latest)"
    complete_file="$(kb_namespace_cache_v3_path "$workspace" "$cluster" "$user" "$context" complete)"
    partial_file="$(kb_namespace_cache_v3_path "$workspace" "$cluster" "$user" "$context" partial)"

    KB_NAMESPACE_CACHE_SELECTED_FILE=""
    KB_NAMESPACE_CACHE_SELECTED_KIND=""
    KB_NAMESPACE_CACHE_LAST_COMPLETE_FILE=""

    if kb_namespace_cache_v3_valid \
        "$complete_file" "$cluster" "$user" "$context" true
    then
        complete_valid=1
        KB_NAMESPACE_CACHE_LAST_COMPLETE_FILE="$complete_file"
    fi

    if kb_namespace_cache_v3_valid \
        "$partial_file" "$cluster" "$user" "$context" false
    then
        partial_valid=1
    fi

    if kb_namespace_cache_v3_valid \
        "$latest_file" "$cluster" "$user" "$context" any
    then
        KB_NAMESPACE_CACHE_SELECTED_FILE="$latest_file"
        KB_NAMESPACE_CACHE_SELECTED_KIND="latest"
        return 0
    fi

    # latest.json is a convenience pointer. Recover from the newest valid
    # class-specific snapshot if it is missing or damaged.
    if [ "$complete_valid" -ne 0 ] && [ "$partial_valid" -ne 0 ]; then
        complete_timestamp="$(jq -r '.discoveredAt' "$complete_file")"
        partial_timestamp="$(jq -r '.discoveredAt' "$partial_file")"

        if [[ "$partial_timestamp" > "$complete_timestamp" ]]; then
            KB_NAMESPACE_CACHE_SELECTED_FILE="$partial_file"
            KB_NAMESPACE_CACHE_SELECTED_KIND="partial"
        else
            KB_NAMESPACE_CACHE_SELECTED_FILE="$complete_file"
            KB_NAMESPACE_CACHE_SELECTED_KIND="complete"
        fi

        return 0
    fi

    if [ "$partial_valid" -ne 0 ]; then
        KB_NAMESPACE_CACHE_SELECTED_FILE="$partial_file"
        KB_NAMESPACE_CACHE_SELECTED_KIND="partial"
        return 0
    fi

    if [ "$complete_valid" -ne 0 ]; then
        KB_NAMESPACE_CACHE_SELECTED_FILE="$complete_file"
        KB_NAMESPACE_CACHE_SELECTED_KIND="complete"
        return 0
    fi

    return 1
}


kb_namespace_cache_v3_load_selected()
{
    [ -n "${KB_NAMESPACE_CACHE_SELECTED_FILE:-}" ] || return 1
    jq '.' "$KB_NAMESPACE_CACHE_SELECTED_FILE"
}


# One-time migration from the immediately previous cache schema. This is not
# used as a long-term fallback: a valid v2 file is converted to v3, written to
# the context-specific layout, and the old file is removed after success.
kb_namespace_cache_v3_migrate_v2_once()
{
    local workspace="$1"
    local cluster="$2"
    local user="$3"
    local context="$4"

    local old_file="$workspace/.kubebase/cache/namespaces/$cluster/$user.json"
    local migrated

    KB_NAMESPACE_CACHE_MIGRATED="false"

    [ -f "$old_file" ] && [ ! -L "$old_file" ] && [ -r "$old_file" ] || return 1

    jq -e \
        --arg schema "$KB_NAMESPACE_INVENTORY_SCHEMA" \
        --arg cluster "$cluster" \
        --arg user "$user" \
        --arg context "$context" '
        .schema == $schema
        and
        .schemaVersion == 2
        and
        .profile.cluster == $cluster
        and
        .profile.user == $user
        and
        .profile.context == $context
        and
        (.discoveredAt | type) == "string"
        and
        (.discoveredAt | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
        and
        (.method | type) == "string"
        and
        (.complete | type) == "boolean"
        and
        (.entries | type) == "array"
        and
        all(
            .entries[];
            (.name | type) == "string"
            and
            (.name | length) <= 63
            and
            (.name | test("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$"))
            and
            (
                .groupId == null
                or
                (.groupId | type) == "string"
            )
        )
        and
        (([.entries[].name] | length) == ([.entries[].name] | unique | length))
    ' "$old_file" >/dev/null 2>&1 || return 1

    migrated="$(
        jq \
            --argjson version "$KB_NAMESPACE_INVENTORY_SCHEMA_VERSION" '
            .schemaVersion = $version
            | .entries |= map(
                {
                    name: .name,
                    group: (
                        if (.groupId // "") == "" then
                            null
                        else
                            {
                                kind: "rancher-project",
                                id: .groupId
                            }
                        end
                    )
                }
            )
        ' "$old_file"
    )"

    kb_namespace_cache_v3_write \
        "$workspace" "$cluster" "$user" "$context" "$migrated"

    rm -f -- "$old_file"
    KB_NAMESPACE_CACHE_MIGRATED="true"
    KB_NAMESPACE_CACHE_MIGRATED_FROM="$old_file"
    return 0
}
