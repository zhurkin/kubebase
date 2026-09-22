#!/usr/bin/env bash

set -euo pipefail


# ----------------------------------------------------------------------
# Paths / libraries
# ----------------------------------------------------------------------

SCRIPT_DIR="$(
    cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
    pwd -P
)"

LIB_DIR="$SCRIPT_DIR/lib"
source "$LIB_DIR/common.sh"
source "$LIB_DIR/namespace-inventory.sh"


# ----------------------------------------------------------------------
# KubeBase
# Step 80 - Namespace and optional group navigation
# Linux / Bash
#
# Namespace inventory is live by default. Discovery is capability-based:
#
#   1. list Namespace objects when RBAC permits cluster-wide LIST;
#   2. otherwise inspect `kubectl auth can-i --list` resourceNames and
#      verify every discovered Namespace object individually;
#   3. if live discovery is unavailable, fall back to the latest valid cache
#      for the active cluster/user/context identity.
#
# Complete and partial cache snapshots are preserved independently. A partial
# refresh never replaces the last complete snapshot. In fallback mode the
# discovered namespaces are verified, but KubeBase cannot guarantee that the
# inventory contains every namespace accessible to the current identity.
#
# A Kubernetes context still has at most one default namespace. KubeBase
# does not wrap kubectl or emulate multi-namespace kubectl semantics.
# ----------------------------------------------------------------------

PROJECT_NAME="KubeBase"

SESSION_SCHEMA="kubebase.session"
SESSION_SCHEMA_VERSION=1

DEFAULT_REQUEST_TIMEOUT="10s"

REQUEST_TIMEOUT="$DEFAULT_REQUEST_TIMEOUT"
FORCE_CACHE=0

INVENTORY_JSON=""
INVENTORY_SOURCE=""
INVENTORY_METHOD=""
INVENTORY_COMPLETE="false"
INVENTORY_TIMESTAMP=""
INVENTORY_NOTE=""
LIVE_ERROR=""

KUBECTL_BIN=""
CACHE_DIR=""
CACHE_SELECTED_FILE=""
CACHE_SELECTED_KIND=""
CACHE_MIGRATED=0
LAST_COMPLETE_FILE=""
LAST_COMPLETE_TIMESTAMP=""
LAST_COMPLETE_COUNT=0


# ----------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------

require_active_profile()
{
    [ "${KUBEBASE_ACTIVE:-}" = "1" ] || \
        kb_fail "no active KubeBase profile; run 'kubebase use' first"

    [ -n "${KUBEBASE_WORKSPACE:-}" ] || \
        kb_fail "active profile has no workspace"

    [ -n "${KUBEBASE_CLUSTER:-}" ] || \
        kb_fail "active profile has no cluster"

    [ -n "${KUBEBASE_USER:-}" ] || \
        kb_fail "active profile has no user"

    [ -n "${KUBEBASE_CONTEXT:-}" ] || \
        kb_fail "active profile has no context"

    [ -n "${KUBEBASE_TOOLCHAIN_BIN:-}" ] || \
        kb_fail "active profile has no toolchain"

    [ -n "${KUBEBASE_EFFECTIVE_KUBECONFIG:-}" ] || \
        kb_fail "active profile has no effective kubeconfig"

    [ -n "${KUBEBASE_SESSION_DIR:-}" ] || \
        kb_fail "active profile has no session directory"

    KUBECTL_BIN="$KUBEBASE_TOOLCHAIN_BIN/kubectl"

    [ -x "$KUBECTL_BIN" ] || \
        kb_fail "active profile kubectl is missing or not executable: $KUBECTL_BIN"

    kb_require_readable_file \
        "$KUBEBASE_EFFECTIVE_KUBECONFIG" \
        "effective kubeconfig"

    [ -d "$KUBEBASE_SESSION_DIR" ] || \
        kb_fail "active KubeBase session not found: $KUBEBASE_SESSION_DIR"

    kb_require_readable_json_file \
        "$KUBEBASE_SESSION_DIR/session.json" \
        "active KubeBase session metadata"

    jq -e \
        --arg schema "$SESSION_SCHEMA" \
        --argjson version "$SESSION_SCHEMA_VERSION" \
        --arg workspace "$KUBEBASE_WORKSPACE" \
        --arg cluster "$KUBEBASE_CLUSTER" \
        --arg user "$KUBEBASE_USER" \
        --arg context "$KUBEBASE_CONTEXT" '
        .schema == $schema
        and
        .schemaVersion == $version
        and
        .workspace == $workspace
        and
        .profile.cluster == $cluster
        and
        .profile.user == $user
        and
        .profile.context == $context
    ' "$KUBEBASE_SESSION_DIR/session.json" >/dev/null 2>&1 || \
        kb_fail "active KubeBase session metadata does not match the shell profile"

    CACHE_DIR="$(
        kb_namespace_cache_v3_dir \
            "$KUBEBASE_WORKSPACE" \
            "$KUBEBASE_CLUSTER" \
            "$KUBEBASE_USER" \
            "$KUBEBASE_CONTEXT"
    )"
}


load_last_complete_metadata()
{
    local complete_file

    LAST_COMPLETE_FILE=""
    LAST_COMPLETE_TIMESTAMP=""
    LAST_COMPLETE_COUNT=0

    complete_file="$(
        kb_namespace_cache_v3_path \
            "$KUBEBASE_WORKSPACE" \
            "$KUBEBASE_CLUSTER" \
            "$KUBEBASE_USER" \
            "$KUBEBASE_CONTEXT" \
            complete
    )"

    if kb_namespace_cache_v3_valid \
        "$complete_file" \
        "$KUBEBASE_CLUSTER" \
        "$KUBEBASE_USER" \
        "$KUBEBASE_CONTEXT" \
        true
    then
        LAST_COMPLETE_FILE="$complete_file"
        LAST_COMPLETE_TIMESTAMP="$(jq -r '.discoveredAt' "$complete_file")"
        LAST_COMPLETE_COUNT="$(jq -r '.entries | length' "$complete_file")"
    fi
}


load_cache()
{
    CACHE_MIGRATED=0

    if ! kb_namespace_cache_v3_select_latest \
        "$KUBEBASE_WORKSPACE" \
        "$KUBEBASE_CLUSTER" \
        "$KUBEBASE_USER" \
        "$KUBEBASE_CONTEXT"
    then
        if kb_namespace_cache_v3_migrate_v2_once \
            "$KUBEBASE_WORKSPACE" \
            "$KUBEBASE_CLUSTER" \
            "$KUBEBASE_USER" \
            "$KUBEBASE_CONTEXT"
        then
            CACHE_MIGRATED=1

            kb_namespace_cache_v3_select_latest \
                "$KUBEBASE_WORKSPACE" \
                "$KUBEBASE_CLUSTER" \
                "$KUBEBASE_USER" \
                "$KUBEBASE_CONTEXT" || return 1
        else
            return 1
        fi
    fi

    CACHE_SELECTED_FILE="$KB_NAMESPACE_CACHE_SELECTED_FILE"
    CACHE_SELECTED_KIND="$KB_NAMESPACE_CACHE_SELECTED_KIND"
    INVENTORY_JSON="$(kb_namespace_cache_v3_load_selected)"
    INVENTORY_SOURCE="cache"
    INVENTORY_METHOD="$(jq -r '.method // "unknown"' <<< "$INVENTORY_JSON")"
    INVENTORY_COMPLETE="$(jq -r '.complete // false' <<< "$INVENTORY_JSON")"
    INVENTORY_TIMESTAMP="$(jq -r '.discoveredAt // "unknown"' <<< "$INVENTORY_JSON")"

    load_last_complete_metadata
    return 0
}


write_cache()
{
    local inventory="$1"

    kb_namespace_cache_v3_write \
        "$KUBEBASE_WORKSPACE" \
        "$KUBEBASE_CLUSTER" \
        "$KUBEBASE_USER" \
        "$KUBEBASE_CONTEXT" \
        "$inventory"

    CACHE_DIR="$KB_NAMESPACE_CACHE_DIR"
    CACHE_SELECTED_FILE="$KB_NAMESPACE_CACHE_LATEST_FILE"
    CACHE_SELECTED_KIND="latest"
    load_last_complete_metadata
}


live_discover_inventory()
{
    local status=0

    kb_namespace_discover_live \
        "$KUBECTL_BIN" \
        "$KUBEBASE_EFFECTIVE_KUBECONFIG" \
        "$KUBEBASE_CONTEXT" \
        "$KUBEBASE_CLUSTER" \
        "$KUBEBASE_USER" \
        "$REQUEST_TIMEOUT" || status=$?

    if [ "$status" -ne 0 ]; then
        LIVE_ERROR="$KB_NAMESPACE_DISCOVERY_ERROR"
        return "$status"
    fi

    INVENTORY_JSON="$KB_NAMESPACE_DISCOVERY_JSON"
    INVENTORY_SOURCE="live"
    INVENTORY_METHOD="$KB_NAMESPACE_DISCOVERY_METHOD"
    INVENTORY_COMPLETE="$KB_NAMESPACE_DISCOVERY_COMPLETE"
    INVENTORY_TIMESTAMP="$(jq -r '.discoveredAt // "unknown"' <<< "$INVENTORY_JSON")"
    INVENTORY_NOTE="$KB_NAMESPACE_DISCOVERY_NOTE"
    LIVE_ERROR=""
    CACHE_MIGRATED=0

    write_cache "$INVENTORY_JSON"
    return 0
}


discover_inventory()
{
    FORCE_CACHE="${1:-0}"

    if [ "$FORCE_CACHE" -ne 0 ]; then
        if load_cache; then
            INVENTORY_NOTE="cached inventory requested explicitly"
            return 0
        fi

        kb_fail "no valid namespace cache exists for $KUBEBASE_CLUSTER/$KUBEBASE_USER context '$KUBEBASE_CONTEXT'"
    fi

    if live_discover_inventory; then
        return 0
    fi

    if load_cache; then
        INVENTORY_NOTE="live discovery failed; using last valid cache"
        return 0
    fi

    if [ -n "$LIVE_ERROR" ]; then
        kb_fail "namespace discovery failed and no valid cache exists for context '$KUBEBASE_CONTEXT': $LIVE_ERROR"
    fi

    kb_fail "namespace discovery failed and no valid cache exists for context '$KUBEBASE_CONTEXT'"
}


inventory_entry_for_name()
{
    local name="$1"

    jq -c \
        --arg name "$name" '
        [
            .entries[]
            | select(.name == $name)
        ][0] // empty
    ' <<< "$INVENTORY_JSON"
}


inventory_group_exists()
{
    local group="$1"

    jq -e \
        --arg group "$group" '
        any(.entries[]; .group != null and .group.id == $group)
    ' <<< "$INVENTORY_JSON" >/dev/null 2>&1
}


# ----------------------------------------------------------------------
# Session / kubeconfig mutation
# ----------------------------------------------------------------------

update_session_navigation()
{
    local group_filter="$1"
    local namespace="$2"
    local namespace_group="$3"
    local manifest="$KUBEBASE_SESSION_DIR/session.json"
    local temp="$KUBEBASE_SESSION_DIR/.session.json.tmp.$$"

    jq \
        --arg groupFilter "$group_filter" \
        --arg namespace "$namespace" \
        --arg namespaceGroup "$namespace_group" '
        .navigation = {
            groupFilter: (
                if $groupFilter == "" then null else $groupFilter end
            ),
            namespace: (
                if $namespace == "" then null else $namespace end
            ),
            namespaceGroup: (
                if $namespaceGroup == "" then null else $namespaceGroup end
            )
        }
    ' "$manifest" > "$temp"

    chmod 600 "$temp"
    mv -f -- "$temp" "$manifest"
}



current_effective_namespace()
{
    "$KUBECTL_BIN" \
        --kubeconfig "$KUBEBASE_EFFECTIVE_KUBECONFIG" \
        config view \
        -o json 2>/dev/null |
    jq -r \
        --arg context "$KUBEBASE_CONTEXT" '
        [
            .contexts[]
            | select(.name == $context)
            | .context.namespace // ""
        ][0] // ""
    '
}


set_effective_namespace()
{
    local namespace="$1"

    "$KUBECTL_BIN" \
        --kubeconfig "$KUBEBASE_EFFECTIVE_KUBECONFIG" \
        config set-context "$KUBEBASE_CONTEXT" \
        --namespace="$namespace" \
        >/dev/null
}


clear_effective_namespace()
{
    local temp="$KUBEBASE_SESSION_DIR/.kubeconfig.navigation.tmp.$$"

    "$KUBECTL_BIN" \
        --kubeconfig "$KUBEBASE_EFFECTIVE_KUBECONFIG" \
        config view \
        --raw \
        -o json |
    jq \
        --arg context "$KUBEBASE_CONTEXT" '
        (
            .contexts[]
            | select(.name == $context)
            | .context
        ) |= del(.namespace)
    ' > "$temp"

    chmod 600 "$temp"
    mv -f -- "$temp" "$KUBEBASE_EFFECTIVE_KUBECONFIG"

    if [ "$("$KUBECTL_BIN" \
        --kubeconfig "$KUBEBASE_EFFECTIVE_KUBECONFIG" \
        config current-context
    )" != "$KUBEBASE_CONTEXT" ]; then
        kb_fail "effective kubeconfig context changed while clearing namespace"
    fi

    if [ -n "$(current_effective_namespace)" ]; then
        kb_fail "effective kubeconfig namespace could not be cleared"
    fi
}


# ----------------------------------------------------------------------
# Display
# ----------------------------------------------------------------------

inventory_namespace_count()
{
    jq -r '.entries | length' <<< "$INVENTORY_JSON"
}


inventory_group_count()
{
    jq -r '
        [
            .entries[]
            | select(.group != null)
            | [ .group.kind, .group.id ]
        ]
        | unique
        | length
    ' <<< "$INVENTORY_JSON"
}

print_discovery_summary()
{
    local namespace_count
    local group_count
    local source_text
    local list_text
    local cache_snapshot=""

    namespace_count="$(inventory_namespace_count)"
    group_count="$(inventory_group_count)"

    if [ "$INVENTORY_SOURCE" = "live" ]; then
        source_text="LIVE Kubernetes API"
    else
        source_text="CACHE"
    fi

    case "$INVENTORY_METHOD" in
        namespace-list)
            list_text="YES"
            ;;
        auth-can-i)
            list_text="NO"
            ;;
        *)
            list_text="UNKNOWN"
            ;;
    esac

    echo "Namespace discovery:"
    printf '  %-34s : %s\n' "Data source" "$source_text"

    if [ "$INVENTORY_SOURCE" = "cache" ]; then
        printf '  %-34s : %s\n' "Cached at" "$INVENTORY_TIMESTAMP"

        if [ "$CACHE_SELECTED_KIND" = "latest" ]; then
            if [ "$INVENTORY_COMPLETE" = "true" ]; then
                cache_snapshot="latest / complete"
            else
                cache_snapshot="latest / partial"
            fi
        else
            cache_snapshot="$CACHE_SELECTED_KIND (latest.json unavailable)"
        fi

        printf '  %-34s : %s\n' "Cache snapshot" "$cache_snapshot"
    fi

    if [ "$INVENTORY_SOURCE" = "cache" ]; then
        if [ "$list_text" = "NO" ] && [[ "$INVENTORY_NOTE" == *Forbidden* || "$INVENTORY_NOTE" == *forbidden* ]]; then
            printf '  %-34s : %s\n' "Namespace LIST at cache refresh" "NO (Forbidden)"
        else
            printf '  %-34s : %s\n' "Namespace LIST at cache refresh" "$list_text"
        fi
    else
        if [ "$list_text" = "NO" ] && [[ "$INVENTORY_NOTE" == *Forbidden* || "$INVENTORY_NOTE" == *forbidden* ]]; then
            printf '  %-34s : %s\n' "Cluster-wide namespace LIST" "NO (Forbidden)"
        else
            printf '  %-34s : %s\n' "Cluster-wide namespace LIST" "$list_text"
        fi
    fi

    printf '  %-34s : %s\n' "Namespaces verified" "$namespace_count"

    if [ "$INVENTORY_SOURCE" = "cache" ]; then
        if [ "$INVENTORY_COMPLETE" = "true" ]; then
            printf '  %-34s : %s\n' "Complete cached list guaranteed" "YES"
        else
            printf '  %-34s : %s\n' "Complete cached list guaranteed" "NO"
        fi
    else
        if [ "$INVENTORY_COMPLETE" = "true" ]; then
            printf '  %-34s : %s\n' "Complete list guaranteed" "YES"
        else
            printf '  %-34s : %s\n' "Complete list guaranteed" "NO"
        fi
    fi

    if [ "$INVENTORY_COMPLETE" != "true" ] && [ -n "$LAST_COMPLETE_FILE" ]; then
        printf '  %-34s : %s (%s namespaces)\n' \
            "Last complete snapshot" \
            "$LAST_COMPLETE_TIMESTAMP" \
            "$LAST_COMPLETE_COUNT"
    fi

    printf '  %-34s : %s\n' "Namespace groups discovered" "$group_count"

    if [ -n "${KUBEBASE_GROUP:-}" ]; then
        printf '  %-34s : %s\n' "Group filter" "$KUBEBASE_GROUP"
    fi

    if [ "$CACHE_MIGRATED" -ne 0 ]; then
        printf '  %-34s : %s\n' "Cache migration" "v2 -> v3"
    fi

    case "$INVENTORY_NOTE" in
        "cached inventory requested explicitly")
            printf '  %-34s : %s\n' "Cache use" "explicitly requested"
            ;;
        "live discovery failed; using last valid cache")
            printf '  %-34s : %s\n' "Cache use" "live discovery failed; using last valid cache"
            ;;
    esac

    echo
}

print_inventory_header()
{
    echo "$PROJECT_NAME namespaces"
    echo
    echo "Profile : $KUBEBASE_CLUSTER/$KUBEBASE_USER"
    echo "Context : $KUBEBASE_CONTEXT"
    echo
    print_discovery_summary
}


print_namespace_table()
{
    local filter_group="${KUBEBASE_GROUP:-}"
    local name_width=9
    local group_width=5
    local kind_width=4
    local name_sep
    local group_sep
    local kind_sep
    local row
    local name
    local group
    local kind
    local -a rows=()

    mapfile -t rows < <(
        jq -r \
            --arg group "$filter_group" '
            .entries[]
            | select(
                $group == ""
                or
                (.group != null and .group.id == $group)
            )
            | [
                .name,
                (.group.id // "-"),
                (.group.kind // "-")
            ]
            | @tsv
        ' <<< "$INVENTORY_JSON"
    )

    if [ "${#rows[@]}" -eq 0 ]; then
        if [ -n "$filter_group" ]; then
            echo "No namespaces discovered for group '$filter_group'."
        else
            echo "No namespaces were discovered."
        fi
        return 0
    fi

    for row in "${rows[@]}"; do
        IFS=$'\t' read -r name group kind <<< "$row"
        [ "${#name}" -le "$name_width" ] || name_width=${#name}
        [ "${#group}" -le "$group_width" ] || group_width=${#group}
        [ "${#kind}" -le "$kind_width" ] || kind_width=${#kind}
    done

    printf -v name_sep '%*s' "$name_width" ''
    printf -v group_sep '%*s' "$group_width" ''
    printf -v kind_sep '%*s' "$kind_width" ''
    name_sep="${name_sep// /-}"
    group_sep="${group_sep// /-}"
    kind_sep="${kind_sep// /-}"

    printf '%-*s  %-*s  %-*s\n' \
        "$name_width" "NAMESPACE" \
        "$group_width" "GROUP" \
        "$kind_width" "KIND"
    printf '%s  %s  %s\n' "$name_sep" "$group_sep" "$kind_sep"

    for row in "${rows[@]}"; do
        IFS=$'\t' read -r name group kind <<< "$row"
        printf '%-*s  %-*s  %-*s\n' \
            "$name_width" "$name" \
            "$group_width" "$group" \
            "$kind_width" "$kind"
    done
}

print_group_table()
{
    local group_width=5
    local kind_width=4
    local count_width=10
    local group_sep
    local kind_sep
    local count_sep
    local row
    local group
    local kind
    local count_value
    local -a rows=()

    echo "$PROJECT_NAME groups"
    echo
    echo "Profile : $KUBEBASE_CLUSTER/$KUBEBASE_USER"
    echo "Context : $KUBEBASE_CONTEXT"
    echo
    print_discovery_summary

    mapfile -t rows < <(
        jq -r '
            [
                .entries[]
                | select(.group != null)
            ]
            | group_by([.group.kind, .group.id])
            | sort_by(.[0].group.kind, .[0].group.id)
            | .[]
            | [
                .[0].group.id,
                .[0].group.kind,
                (length | tostring)
            ]
            | @tsv
        ' <<< "$INVENTORY_JSON"
    )

    if [ "${#rows[@]}" -eq 0 ]; then
        echo "No namespace group metadata was discovered."
        return 0
    fi

    for row in "${rows[@]}"; do
        IFS=$'\t' read -r group kind count_value <<< "$row"
        [ "${#group}" -le "$group_width" ] || group_width=${#group}
        [ "${#kind}" -le "$kind_width" ] || kind_width=${#kind}
        [ "${#count_value}" -le "$count_width" ] || count_width=${#count_value}
    done

    printf -v group_sep '%*s' "$group_width" ''
    printf -v kind_sep '%*s' "$kind_width" ''
    printf -v count_sep '%*s' "$count_width" ''
    group_sep="${group_sep// /-}"
    kind_sep="${kind_sep// /-}"
    count_sep="${count_sep// /-}"

    printf '%-*s  %-*s  %-*s\n' \
        "$group_width" "GROUP" \
        "$kind_width" "KIND" \
        "$count_width" "NAMESPACES"
    printf '%s  %s  %s\n' "$group_sep" "$kind_sep" "$count_sep"

    for row in "${rows[@]}"; do
        IFS=$'\t' read -r group kind count_value <<< "$row"
        printf '%-*s  %-*s  %-*s\n' \
            "$group_width" "$group" \
            "$kind_width" "$kind" \
            "$count_width" "$count_value"
    done
}

# ----------------------------------------------------------------------
# Visible commands
# ----------------------------------------------------------------------

command_namespaces()
{
    require_active_profile
    discover_inventory "$FORCE_CACHE"

    print_inventory_header
    print_namespace_table
}


command_groups()
{
    require_active_profile
    discover_inventory "$FORCE_CACHE"

    print_group_table
}


# ----------------------------------------------------------------------
# Interactive selection
# ----------------------------------------------------------------------

select_namespace_interactively()
{
    local answer
    local index
    local group_filter="${KUBEBASE_GROUP:-}"
    local -a names=()

    discover_inventory 0

    mapfile -t names < <(
        jq -r \
            --arg group "$group_filter" '
            .entries[]
            | select(
                $group == ""
                or
                (.group != null and .group.id == $group)
            )
            | .name
        ' <<< "$INVENTORY_JSON"
    )

    [ "${#names[@]}" -gt 0 ] || {
        if [ -n "$group_filter" ]; then
            echo "ERROR: no namespaces discovered for group '$group_filter'" >&2
        else
            echo "ERROR: no namespaces are available for selection" >&2
        fi
        return 1
    }

    [ -r /dev/tty ] && [ -w /dev/tty ] || {
        echo "ERROR: interactive namespace selection requires a TTY" >&2
        echo "Use: kubebase ns NAME" >&2
        return 1
    }

    {
        if [ -n "$group_filter" ]; then
            echo "Available namespaces in group '$group_filter':"
        else
            echo "Available namespaces:"
        fi
        echo

        index=1
        for name in "${names[@]}"; do
            printf '  %d. %s\n' "$index" "$name"
            index=$((index + 1))
        done

        echo
        printf 'Select namespace [1-%d]: ' "${#names[@]}"
    } > /dev/tty

    IFS= read -r answer < /dev/tty

    [[ "$answer" =~ ^[0-9]+$ ]] || {
        echo "ERROR: invalid namespace selection: $answer" >&2
        return 1
    }

    if [ "$answer" -lt 1 ] || [ "$answer" -gt "${#names[@]}" ]; then
        echo "ERROR: namespace selection is out of range: $answer" >&2
        return 1
    fi

    printf '%s\n' "${names[$((answer - 1))]}"
}


select_group_interactively()
{
    local answer
    local index
    local -a groups=()

    discover_inventory 0

    mapfile -t groups < <(
        jq -r '
            [
                .entries[]
                | select(.group != null)
                | .group.id
            ]
            | unique
            | .[]
        ' <<< "$INVENTORY_JSON"
    )

    [ "${#groups[@]}" -gt 0 ] || {
        echo "ERROR: no namespace groups were discovered" >&2
        return 1
    }

    [ -r /dev/tty ] && [ -w /dev/tty ] || {
        echo "ERROR: interactive group selection requires a TTY" >&2
        echo "Use: kubebase group GROUP" >&2
        return 1
    }

    {
        echo "Available groups:"
        echo

        index=1
        for group in "${groups[@]}"; do
            printf '  %d. %s\n' "$index" "$group"
            index=$((index + 1))
        done

        echo
        printf 'Select group [1-%d]: ' "${#groups[@]}"
    } > /dev/tty

    IFS= read -r answer < /dev/tty

    [[ "$answer" =~ ^[0-9]+$ ]] || {
        echo "ERROR: invalid group selection: $answer" >&2
        return 1
    }

    if [ "$answer" -lt 1 ] || [ "$answer" -gt "${#groups[@]}" ]; then
        echo "ERROR: group selection is out of range: $answer" >&2
        return 1
    fi

    printf '%s\n' "${groups[$((answer - 1))]}"
}


# ----------------------------------------------------------------------
# Shell-mutating commands
# ----------------------------------------------------------------------

command_emit_namespace()
{
    local selector="${1:-}"
    local namespace_json=""
    local group_id=""
    local error_file
    local error_text
    local cached_entry=""

    require_active_profile

    if [ "$selector" = "--clear" ]; then
        clear_effective_namespace

        update_session_navigation \
            "${KUBEBASE_GROUP:-}" \
            "" \
            ""

        kb_shell_unset "KUBEBASE_NAMESPACE"
        kb_shell_unset "KUBEBASE_NAMESPACE_GROUP"
        return 0
    fi

    if [ -z "$selector" ]; then
        selector="$(select_namespace_interactively)" || return $?
    fi

    kb_namespace_name_is_valid "$selector" || {
        echo "ERROR: invalid Kubernetes namespace name: $selector" >&2
        return 2
    }

    error_file="$(mktemp)"

    if namespace_json="$("$KUBECTL_BIN" \
        --kubeconfig "$KUBEBASE_EFFECTIVE_KUBECONFIG" \
        --context "$KUBEBASE_CONTEXT" \
        --request-timeout="$REQUEST_TIMEOUT" \
        get namespace "$selector" \
        -o json \
        2>"$error_file")"
    then
        group_id="$(kb_namespace_group_json_from_json <<< "$namespace_json" | jq -r '.id // ""')"
    else
        error_text="$(cat -- "$error_file")"

        if grep -Eqi 'not[[:space:]-]*found|\(NotFound\)' <<< "$error_text"; then
            rm -f -- "$error_file"
            echo "ERROR: namespace '$selector' was not found" >&2
            return 1
        fi

        if load_cache; then
            cached_entry="$(inventory_entry_for_name "$selector")"

            if [ -n "$cached_entry" ]; then
                group_id="$(jq -r '.group.id // ""' <<< "$cached_entry")"
            fi
        fi

        kb_warn "namespace '$selector' could not be verified live; selecting it as an explicit Kubernetes namespace"
    fi

    rm -f -- "$error_file"

    if [ -n "${KUBEBASE_GROUP:-}" ]; then
        if [ -z "$group_id" ]; then
            echo "ERROR: cannot verify that namespace '$selector' belongs to active group '$KUBEBASE_GROUP'" >&2
            echo "Clear the group filter first with: kubebase group --clear" >&2
            return 1
        fi

        if [ "$group_id" != "$KUBEBASE_GROUP" ]; then
            echo "ERROR: namespace '$selector' belongs to group '$group_id', not active group '$KUBEBASE_GROUP'" >&2
            return 1
        fi
    fi

    set_effective_namespace "$selector"

    update_session_navigation \
        "${KUBEBASE_GROUP:-}" \
        "$selector" \
        "$group_id"

    kb_shell_export "KUBEBASE_NAMESPACE" "$selector"

    if [ -n "$group_id" ]; then
        kb_shell_export "KUBEBASE_NAMESPACE_GROUP" "$group_id"
    else
        kb_shell_unset "KUBEBASE_NAMESPACE_GROUP"
    fi
}


command_emit_group()
{
    local selector="${1:-}"
    local namespace=""

    require_active_profile

    if [ "$selector" = "--clear" ]; then
        namespace="$(current_effective_namespace)"

        if [ -n "$namespace" ]; then
            update_session_navigation \
                "" \
                "$namespace" \
                "${KUBEBASE_NAMESPACE_GROUP:-}"
        else
            update_session_navigation "" "" ""
        fi

        kb_shell_unset "KUBEBASE_GROUP"
        return 0
    fi

    if [ -z "$selector" ]; then
        selector="$(select_group_interactively)" || return $?
    else
        discover_inventory 0

        inventory_group_exists "$selector" || {
            echo "ERROR: group '$selector' was not discovered for the active profile" >&2
            return 1
        }
    fi

    clear_effective_namespace
    update_session_navigation "$selector" "" ""

    kb_shell_export "KUBEBASE_GROUP" "$selector"
    kb_shell_unset "KUBEBASE_NAMESPACE"
    kb_shell_unset "KUBEBASE_NAMESPACE_GROUP"
}


command_direct_namespace()
{
    echo "ERROR: 'ns' must modify the active KubeBase shell session and requires Bash integration." >&2
    echo >&2
    echo "Run:" >&2
    echo >&2
    echo "  eval \"\$(./kubebase.sh shell-init bash)\"" >&2
    return 2
}


command_direct_group()
{
    echo "ERROR: 'group' must modify the active KubeBase shell session and requires Bash integration." >&2
    echo >&2
    echo "Run:" >&2
    echo >&2
    echo "  eval \"\$(./kubebase.sh shell-init bash)\"" >&2
    return 2
}


# ----------------------------------------------------------------------
# Arguments / dispatch
# ----------------------------------------------------------------------

SUBCOMMAND="${1:-help}"

if [ "$#" -gt 0 ]; then
    shift
fi

case "$SUBCOMMAND" in
    namespaces|groups)
        while [ "$#" -gt 0 ]; do
            case "$1" in
                --cached)
                    FORCE_CACHE=1
                    shift
                    ;;

                --request-timeout)
                    [ "$#" -ge 2 ] || {
                        echo "ERROR: --request-timeout requires a value" >&2
                        exit 2
                    }

                    REQUEST_TIMEOUT="$2"
                    shift 2
                    ;;

                -h|--help)
                    cat <<EOF_USAGE
Usage:
  kubebase $SUBCOMMAND [--cached] [--request-timeout DURATION]

Live discovery is the default. If live discovery fails, KubeBase uses the
last valid cache automatically. --cached disables network discovery.
EOF_USAGE
                    exit 0
                    ;;

                *)
                    echo "ERROR: unknown $SUBCOMMAND argument: $1" >&2
                    exit 2
                    ;;
            esac
        done

        if [ "$SUBCOMMAND" = "namespaces" ]; then
            command_namespaces
        else
            command_groups
        fi
        ;;

    ns-direct)
        command_direct_namespace
        ;;

    group-direct)
        command_direct_group
        ;;

    __nav-ns)
        [ "$#" -le 1 ] || {
            echo "ERROR: usage: kubebase ns [NAME|--clear]" >&2
            exit 2
        }

        command_emit_namespace "${1:-}"
        ;;

    __nav-group)
        [ "$#" -le 1 ] || {
            echo "ERROR: usage: kubebase group [GROUP|--clear]" >&2
            exit 2
        }

        command_emit_group "${1:-}"
        ;;

    help|-h|--help)
        cat <<EOF_USAGE
$PROJECT_NAME namespace/group navigation

Usage:
  kubebase namespaces [--cached]
  kubebase ns [NAME|--clear]
  kubebase groups [--cached]
  kubebase group [GROUP|--clear]
EOF_USAGE
        ;;

    *)
        echo "ERROR: unknown Step 80 command: $SUBCOMMAND" >&2
        exit 2
        ;;
esac
