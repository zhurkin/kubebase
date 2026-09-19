#!/usr/bin/env bash

set -euo pipefail


# ----------------------------------------------------------------------
# KubeBase
# Step 80 - Namespace and Rancher project navigation
# Linux / Bash
#
# Namespace inventory is live by default. Discovery is best effort:
#
#   1. list Namespace objects when RBAC permits it;
#   2. otherwise inspect SelfSubjectRulesReview resourceNames and verify
#      each candidate Namespace object individually;
#   3. if live discovery is unavailable, fall back to the last valid cache.
#
# A Kubernetes context still has at most one default namespace. KubeBase
# does not wrap kubectl or emulate multi-namespace kubectl semantics.
# ----------------------------------------------------------------------

PROJECT_NAME="KubeBase"

INVENTORY_SCHEMA="kubebase.namespaceInventory"
INVENTORY_SCHEMA_VERSION=1

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
CACHE_ROOT=""
CACHE_DIR=""
CACHE_FILE=""


# ----------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------

fail()
{
    echo "ERROR: $*" >&2
    exit 1
}


warn()
{
    echo "WARNING: $*" >&2
}


shell_export()
{
    local name="$1"
    local value="$2"

    printf 'export %s=%q\n' "$name" "$value"
}


shell_unset()
{
    local name="$1"

    printf 'unset %s\n' "$name"
}


first_nonempty_line()
{
    local text="$1"

    awk '
        NF {
            print
            exit
        }
    ' <<< "$text"
}


namespace_name_is_valid()
{
    local value="$1"

    [ "${#value}" -le 63 ] || return 1
    [[ "$value" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]
}


project_id_from_namespace_json()
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


require_active_profile()
{
    [ "${KUBEBASE_ACTIVE:-}" = "1" ] || \
        fail "no active KubeBase profile; run 'kubebase use' first"

    [ -n "${KUBEBASE_WORKSPACE:-}" ] || \
        fail "active profile has no workspace"

    [ -n "${KUBEBASE_CLUSTER:-}" ] || \
        fail "active profile has no cluster"

    [ -n "${KUBEBASE_USER:-}" ] || \
        fail "active profile has no user"

    [ -n "${KUBEBASE_CONTEXT:-}" ] || \
        fail "active profile has no context"

    [ -n "${KUBEBASE_TOOLCHAIN_BIN:-}" ] || \
        fail "active profile has no toolchain"

    [ -n "${KUBEBASE_EFFECTIVE_KUBECONFIG:-}" ] || \
        fail "active profile has no effective kubeconfig"

    [ -n "${KUBEBASE_SESSION_DIR:-}" ] || \
        fail "active profile has no session directory"

    KUBECTL_BIN="$KUBEBASE_TOOLCHAIN_BIN/kubectl"

    [ -x "$KUBECTL_BIN" ] || \
        fail "active profile kubectl is missing or not executable: $KUBECTL_BIN"

    [ -f "$KUBEBASE_EFFECTIVE_KUBECONFIG" ] || \
        fail "effective kubeconfig not found: $KUBEBASE_EFFECTIVE_KUBECONFIG"

    [ -d "$KUBEBASE_SESSION_DIR" ] || \
        fail "active KubeBase session not found: $KUBEBASE_SESSION_DIR"

    [ -f "$KUBEBASE_SESSION_DIR/session.json" ] || \
        fail "active KubeBase session metadata not found"

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
        fail "active KubeBase session metadata does not match the shell profile"

    CACHE_ROOT="$KUBEBASE_WORKSPACE/.kubebase/cache"
    CACHE_DIR="$CACHE_ROOT/namespaces/$KUBEBASE_CLUSTER"
    CACHE_FILE="$CACHE_DIR/$KUBEBASE_USER.json"
}


ensure_cache_dir()
{
    umask 077

    [ ! -L "$KUBEBASE_WORKSPACE/.kubebase" ] || \
        fail "internal KubeBase state must not be a symlink"

    if [ ! -d "$KUBEBASE_WORKSPACE/.kubebase" ]; then
        mkdir -- "$KUBEBASE_WORKSPACE/.kubebase"
    fi

    chmod 700 "$KUBEBASE_WORKSPACE/.kubebase"

    local path

    for path in \
        "$CACHE_ROOT" \
        "$CACHE_ROOT/namespaces" \
        "$CACHE_DIR"
    do
        [ ! -L "$path" ] || \
            fail "KubeBase cache path must not be a symlink: $path"

        if [ -e "$path" ] && [ ! -d "$path" ]; then
            fail "KubeBase cache path is not a directory: $path"
        fi

        if [ ! -d "$path" ]; then
            mkdir -- "$path"
        fi

        chmod 700 "$path"
    done
}


cache_is_valid()
{
    [ -f "$CACHE_FILE" ] && [ ! -L "$CACHE_FILE" ] || return 1

    jq -e \
        --arg schema "$INVENTORY_SCHEMA" \
        --argjson version "$INVENTORY_SCHEMA_VERSION" \
        --arg cluster "$KUBEBASE_CLUSTER" \
        --arg user "$KUBEBASE_USER" \
        --arg context "$KUBEBASE_CONTEXT" '
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
    ' "$CACHE_FILE" >/dev/null 2>&1
}


load_cache()
{
    cache_is_valid || return 1

    INVENTORY_JSON="$(cat -- "$CACHE_FILE")"
    INVENTORY_SOURCE="cache"
    INVENTORY_METHOD="$(jq -r '.method // "unknown"' <<< "$INVENTORY_JSON")"
    INVENTORY_COMPLETE="$(jq -r '.complete // false' <<< "$INVENTORY_JSON")"
    INVENTORY_TIMESTAMP="$(jq -r '.discoveredAt // "unknown"' <<< "$INVENTORY_JSON")"

    return 0
}


write_cache()
{
    local inventory="$1"
    local temp

    ensure_cache_dir

    temp="$CACHE_FILE.tmp.$$"

    printf '%s\n' "$inventory" > "$temp"
    chmod 600 "$temp"
    mv -f -- "$temp" "$CACHE_FILE"
}


normalized_inventory()
{
    local entries_json="$1"
    local method="$2"
    local complete="$3"
    local timestamp="$4"

    jq -n \
        --arg schema "$INVENTORY_SCHEMA" \
        --argjson schemaVersion "$INVENTORY_SCHEMA_VERSION" \
        --arg cluster "$KUBEBASE_CLUSTER" \
        --arg user "$KUBEBASE_USER" \
        --arg context "$KUBEBASE_CONTEXT" \
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


entries_from_namespace_list()
{
    jq -c '
        [
            .items[]
            |
            {
                name: .metadata.name,
                projectId: (
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


live_discover_inventory()
{
    local namespace_json
    local list_error_file
    local list_error
    local review_text
    local review_error_file
    local review_error
    local request_namespace
    local candidate
    local candidate_json
    local candidate_error
    local candidate_error_file
    local project_id
    local entries_file
    local entries_json
    local timestamp
    local -a candidates=()

    list_error_file="$(mktemp)"

    if namespace_json="$("$KUBECTL_BIN" \
        --kubeconfig "$KUBEBASE_EFFECTIVE_KUBECONFIG" \
        --context "$KUBEBASE_CONTEXT" \
        --request-timeout="$REQUEST_TIMEOUT" \
        get namespaces \
        -o json \
        2>"$list_error_file")"
    then
        rm -f -- "$list_error_file"

        entries_json="$(entries_from_namespace_list <<< "$namespace_json")"
        timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

        INVENTORY_JSON="$(
            normalized_inventory \
                "$entries_json" \
                "namespace-list" \
                true \
                "$timestamp"
        )"

        INVENTORY_SOURCE="live"
        INVENTORY_METHOD="namespace-list"
        INVENTORY_COMPLETE="true"
        INVENTORY_TIMESTAMP="$timestamp"
        INVENTORY_NOTE=""

        write_cache "$INVENTORY_JSON"
        return 0
    fi

    list_error="$(cat -- "$list_error_file")"
    rm -f -- "$list_error_file"

    request_namespace="$($KUBECTL_BIN \
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
        ' 2>/dev/null || true
    )"

    if [ -z "$request_namespace" ]; then
        request_namespace="default"
    fi

    review_error_file="$(mktemp)"

    # Use kubectl's supported authorization command rather than constructing
    # SelfSubjectRulesReview with `create --raw`. Rancher proxy endpoints can
    # reject the raw POST even though `kubectl auth can-i --list` succeeds for
    # the same kubeconfig and identity.
    if ! review_text="$(
        "$KUBECTL_BIN" \
            --kubeconfig "$KUBEBASE_EFFECTIVE_KUBECONFIG" \
            --context "$KUBEBASE_CONTEXT" \
            --request-timeout="$REQUEST_TIMEOUT" \
            auth can-i \
            --list \
            --namespace "$request_namespace" \
            2>"$review_error_file"
    )"
    then
        review_error="$(cat -- "$review_error_file")"
        rm -f -- "$review_error_file"

        LIVE_ERROR="namespace list: $(first_nonempty_line "$list_error"); rules review: $(first_nonempty_line "$review_error")"
        return 1
    fi

    rm -f -- "$review_error_file"

    # `kubectl auth can-i --list` renders a table. Extract Resource Names from
    # rules whose resource column is exactly `namespaces`. Columns are
    # separated by two or more spaces, while multiple resource names inside
    # `[ ... ]` are separated by single spaces.
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

    entries_file="$(mktemp)"
    : > "$entries_file"

    for candidate in "${candidates[@]}"; do
        [ -n "$candidate" ] || continue
        namespace_name_is_valid "$candidate" || continue

        candidate_error_file="$(mktemp)"

        if candidate_json="$($KUBECTL_BIN \
            --kubeconfig "$KUBEBASE_EFFECTIVE_KUBECONFIG" \
            --context "$KUBEBASE_CONTEXT" \
            --request-timeout="$REQUEST_TIMEOUT" \
            get namespace "$candidate" \
            -o json \
            2>"$candidate_error_file")"
        then
            project_id="$(project_id_from_namespace_json <<< "$candidate_json")"

            jq -cn \
                --arg name "$candidate" \
                --arg projectId "$project_id" '
                {
                    name: $name,
                    projectId: (
                        if $projectId == "" then null else $projectId end
                    )
                }
            ' >> "$entries_file"
        else
            candidate_error="$(cat -- "$candidate_error_file")"
            : "$candidate_error"
        fi

        rm -f -- "$candidate_error_file"
    done

    entries_json="$(jq -s '.' "$entries_file")"
    rm -f -- "$entries_file"

    timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

    INVENTORY_JSON="$(
        normalized_inventory \
            "$entries_json" \
            "auth-can-i" \
            false \
            "$timestamp"
    )"

    INVENTORY_SOURCE="live"
    INVENTORY_METHOD="auth-can-i"
    INVENTORY_COMPLETE="false"
    INVENTORY_TIMESTAMP="$timestamp"
    INVENTORY_NOTE="namespace LIST is unavailable; inventory is best effort"

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

        fail "no valid namespace cache exists for $KUBEBASE_CLUSTER/$KUBEBASE_USER"
    fi

    if live_discover_inventory; then
        return 0
    fi

    if load_cache; then
        INVENTORY_NOTE="live discovery failed; using last valid cache"
        return 0
    fi

    if [ -n "$LIVE_ERROR" ]; then
        fail "namespace discovery failed and no valid cache exists: $LIVE_ERROR"
    fi

    fail "namespace discovery failed and no valid cache exists"
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


inventory_project_exists()
{
    local project="$1"

    jq -e \
        --arg project "$project" '
        any(.entries[]; .projectId == $project)
    ' <<< "$INVENTORY_JSON" >/dev/null 2>&1
}


# ----------------------------------------------------------------------
# Session / kubeconfig mutation
# ----------------------------------------------------------------------

update_session_navigation()
{
    local project_filter="$1"
    local namespace="$2"
    local namespace_project="$3"
    local manifest="$KUBEBASE_SESSION_DIR/session.json"
    local temp="$KUBEBASE_SESSION_DIR/.session.json.tmp.$$"

    jq \
        --arg projectFilter "$project_filter" \
        --arg namespace "$namespace" \
        --arg namespaceProject "$namespace_project" '
        .navigation = {
            projectFilter: (
                if $projectFilter == "" then null else $projectFilter end
            ),
            namespace: (
                if $namespace == "" then null else $namespace end
            ),
            namespaceProject: (
                if $namespaceProject == "" then null else $namespaceProject end
            )
        }
        | del(.scope)
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
        fail "effective kubeconfig context changed while clearing namespace"
    fi

    if [ -n "$(current_effective_namespace)" ]; then
        fail "effective kubeconfig namespace could not be cleared"
    fi
}


# ----------------------------------------------------------------------
# Display
# ----------------------------------------------------------------------

print_inventory_header()
{
    echo "$PROJECT_NAME namespaces"
    echo
    echo "Profile  : $KUBEBASE_CLUSTER/$KUBEBASE_USER"
    echo "Context  : $KUBEBASE_CONTEXT"
    echo "Source   : $INVENTORY_SOURCE"
    echo "Method   : $INVENTORY_METHOD"

    if [ "$INVENTORY_COMPLETE" = "true" ]; then
        echo "Complete : yes"
    else
        echo "Complete : no (best effort)"
    fi

    if [ "$INVENTORY_SOURCE" = "cache" ]; then
        echo "Cached   : $INVENTORY_TIMESTAMP"
    fi

    if [ -n "${KUBEBASE_PROJECT:-}" ]; then
        echo "Project  : $KUBEBASE_PROJECT"
    fi

    if [ -n "$INVENTORY_NOTE" ]; then
        echo "Note     : $INVENTORY_NOTE"
    fi

    echo
}


print_namespace_table()
{
    local filter_project="${KUBEBASE_PROJECT:-}"
    local count

    count="$(
        jq -r \
            --arg project "$filter_project" '
            [
                .entries[]
                | select(
                    $project == ""
                    or
                    .projectId == $project
                )
            ]
            | length
        ' <<< "$INVENTORY_JSON"
    )"

    if [ "$count" -eq 0 ]; then
        if [ -n "$filter_project" ]; then
            echo "No namespaces discovered for project '$filter_project'."
        else
            echo "No namespaces were discovered."
        fi
        return 0
    fi

    printf '%-40s %s\n' "NAMESPACE" "PROJECT"
    printf '%-40s %s\n' "----------------------------------------" "--------------------"

    jq -r \
        --arg project "$filter_project" '
        .entries[]
        | select(
            $project == ""
            or
            .projectId == $project
        )
        | [ .name, (.projectId // "-") ]
        | @tsv
    ' <<< "$INVENTORY_JSON" |
    while IFS=$'\t' read -r name project; do
        printf '%-40s %s\n' "$name" "$project"
    done
}


print_project_table()
{
    local count

    count="$(
        jq -r '
            [
                .entries[]
                | select(.projectId != null and .projectId != "")
                | .projectId
            ]
            | unique
            | length
        ' <<< "$INVENTORY_JSON"
    )"

    echo "$PROJECT_NAME projects"
    echo
    echo "Profile  : $KUBEBASE_CLUSTER/$KUBEBASE_USER"
    echo "Context  : $KUBEBASE_CONTEXT"
    echo "Source   : $INVENTORY_SOURCE"
    echo "Method   : $INVENTORY_METHOD"

    if [ "$INVENTORY_COMPLETE" = "true" ]; then
        echo "Complete : yes"
    else
        echo "Complete : no (best effort)"
    fi

    if [ "$INVENTORY_SOURCE" = "cache" ]; then
        echo "Cached   : $INVENTORY_TIMESTAMP"
    fi

    if [ -n "$INVENTORY_NOTE" ]; then
        echo "Note     : $INVENTORY_NOTE"
    fi

    echo

    if [ "$count" -eq 0 ]; then
        echo "No Rancher project metadata was discovered."
        return 0
    fi

    printf '%-24s %s\n' "PROJECT" "NAMESPACES"
    printf '%-24s %s\n' "------------------------" "----------"

    jq -r '
        [
            .entries[]
            | select(.projectId != null and .projectId != "")
        ]
        | group_by(.projectId)
        | sort_by(.[0].projectId)
        | .[]
        | [ .[0].projectId, (length | tostring) ]
        | @tsv
    ' <<< "$INVENTORY_JSON" |
    while IFS=$'\t' read -r project count_value; do
        printf '%-24s %s\n' "$project" "$count_value"
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


command_projects()
{
    require_active_profile
    discover_inventory "$FORCE_CACHE"

    print_project_table
}


# ----------------------------------------------------------------------
# Interactive selection
# ----------------------------------------------------------------------

select_namespace_interactively()
{
    local answer
    local index
    local project_filter="${KUBEBASE_PROJECT:-}"
    local -a names=()

    discover_inventory 0

    mapfile -t names < <(
        jq -r \
            --arg project "$project_filter" '
            .entries[]
            | select(
                $project == ""
                or
                .projectId == $project
            )
            | .name
        ' <<< "$INVENTORY_JSON"
    )

    [ "${#names[@]}" -gt 0 ] || {
        if [ -n "$project_filter" ]; then
            echo "ERROR: no namespaces discovered for project '$project_filter'" >&2
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
        if [ -n "$project_filter" ]; then
            echo "Available namespaces in project '$project_filter':"
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


select_project_interactively()
{
    local answer
    local index
    local -a projects=()

    discover_inventory 0

    mapfile -t projects < <(
        jq -r '
            [
                .entries[]
                | select(.projectId != null and .projectId != "")
                | .projectId
            ]
            | unique
            | .[]
        ' <<< "$INVENTORY_JSON"
    )

    [ "${#projects[@]}" -gt 0 ] || {
        echo "ERROR: no Rancher projects were discovered" >&2
        return 1
    }

    [ -r /dev/tty ] && [ -w /dev/tty ] || {
        echo "ERROR: interactive project selection requires a TTY" >&2
        echo "Use: kubebase project PROJECT" >&2
        return 1
    }

    {
        echo "Available projects:"
        echo

        index=1
        for project in "${projects[@]}"; do
            printf '  %d. %s\n' "$index" "$project"
            index=$((index + 1))
        done

        echo
        printf 'Select project [1-%d]: ' "${#projects[@]}"
    } > /dev/tty

    IFS= read -r answer < /dev/tty

    [[ "$answer" =~ ^[0-9]+$ ]] || {
        echo "ERROR: invalid project selection: $answer" >&2
        return 1
    }

    if [ "$answer" -lt 1 ] || [ "$answer" -gt "${#projects[@]}" ]; then
        echo "ERROR: project selection is out of range: $answer" >&2
        return 1
    fi

    printf '%s\n' "${projects[$((answer - 1))]}"
}


# ----------------------------------------------------------------------
# Shell-mutating commands
# ----------------------------------------------------------------------

command_emit_namespace()
{
    local selector="${1:-}"
    local namespace_json=""
    local project_id=""
    local error_file
    local error_text
    local cached_entry=""

    require_active_profile

    if [ "$selector" = "--clear" ]; then
        clear_effective_namespace

        update_session_navigation \
            "${KUBEBASE_PROJECT:-}" \
            "" \
            ""

        shell_unset "KUBEBASE_NAMESPACE"
        shell_unset "KUBEBASE_NAMESPACE_PROJECT"
        return 0
    fi

    if [ -z "$selector" ]; then
        selector="$(select_namespace_interactively)" || return $?
    fi

    namespace_name_is_valid "$selector" || {
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
        project_id="$(project_id_from_namespace_json <<< "$namespace_json")"
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
                project_id="$(jq -r '.projectId // ""' <<< "$cached_entry")"
            fi
        fi

        warn "namespace '$selector' could not be verified live; selecting it as an explicit Kubernetes namespace"
    fi

    rm -f -- "$error_file"

    if [ -n "${KUBEBASE_PROJECT:-}" ]; then
        if [ -z "$project_id" ]; then
            echo "ERROR: cannot verify that namespace '$selector' belongs to active project '$KUBEBASE_PROJECT'" >&2
            echo "Clear the project filter first with: kubebase project --clear" >&2
            return 1
        fi

        if [ "$project_id" != "$KUBEBASE_PROJECT" ]; then
            echo "ERROR: namespace '$selector' belongs to project '$project_id', not active project '$KUBEBASE_PROJECT'" >&2
            return 1
        fi
    fi

    set_effective_namespace "$selector"

    update_session_navigation \
        "${KUBEBASE_PROJECT:-}" \
        "$selector" \
        "$project_id"

    shell_export "KUBEBASE_NAMESPACE" "$selector"

    if [ -n "$project_id" ]; then
        shell_export "KUBEBASE_NAMESPACE_PROJECT" "$project_id"
    else
        shell_unset "KUBEBASE_NAMESPACE_PROJECT"
    fi
}


command_emit_project()
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
                "${KUBEBASE_NAMESPACE_PROJECT:-}"
        else
            update_session_navigation "" "" ""
        fi

        shell_unset "KUBEBASE_PROJECT"
        return 0
    fi

    if [ -z "$selector" ]; then
        selector="$(select_project_interactively)" || return $?
    else
        discover_inventory 0

        inventory_project_exists "$selector" || {
            echo "ERROR: project '$selector' was not discovered for the active profile" >&2
            return 1
        }
    fi

    clear_effective_namespace
    update_session_navigation "$selector" "" ""

    shell_export "KUBEBASE_PROJECT" "$selector"
    shell_unset "KUBEBASE_NAMESPACE"
    shell_unset "KUBEBASE_NAMESPACE_PROJECT"
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


command_direct_project()
{
    echo "ERROR: 'project' must modify the active KubeBase shell session and requires Bash integration." >&2
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
    namespaces|projects)
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
            command_projects
        fi
        ;;

    ns-direct)
        command_direct_namespace
        ;;

    project-direct)
        command_direct_project
        ;;

    __nav-ns)
        [ "$#" -le 1 ] || {
            echo "ERROR: usage: kubebase ns [NAME|--clear]" >&2
            exit 2
        }

        command_emit_namespace "${1:-}"
        ;;

    __nav-project)
        [ "$#" -le 1 ] || {
            echo "ERROR: usage: kubebase project [PROJECT|--clear]" >&2
            exit 2
        }

        command_emit_project "${1:-}"
        ;;

    help|-h|--help)
        cat <<EOF_USAGE
$PROJECT_NAME namespace/project navigation

Usage:
  kubebase namespaces [--cached]
  kubebase ns [NAME|--clear]
  kubebase projects [--cached]
  kubebase project [PROJECT|--clear]
EOF_USAGE
        ;;

    *)
        echo "ERROR: unknown Step 80 command: $SUBCOMMAND" >&2
        exit 2
        ;;
esac
