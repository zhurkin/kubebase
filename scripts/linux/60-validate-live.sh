#!/usr/bin/env bash

set -euo pipefail


# ----------------------------------------------------------------------
# KubeBase
# Step 60 - Live profile validation
# Linux / Bash
#
# Read-only validation of configured cluster/user profiles against the
# Kubernetes API. Namespace inventory uses the same policy as Step 80:
#
#   1. list Namespace objects when RBAC permits it;
#   2. otherwise use `kubectl auth can-i --list` resourceNames as
#      candidates and verify each Namespace object individually.
#
# Discovery is best effort when namespace LIST is unavailable. A
# successful inventory refresh is written to the same cache used by
# `kubebase namespaces`.
# ----------------------------------------------------------------------

PROJECT_NAME="KubeBase"

CLUSTER_SCHEMA="kubebase.cluster"
CLUSTER_SCHEMA_VERSION=1

INVENTORY_SCHEMA="kubebase.namespaceInventory"
INVENTORY_SCHEMA_VERSION=1

DEFAULT_WORKSPACE_NAME="kubebase-workspace"
DEFAULT_REQUEST_TIMEOUT="10s"


# ----------------------------------------------------------------------
# Paths / defaults
# ----------------------------------------------------------------------

SCRIPT_DIR="$(
    cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
    pwd -P
)"

REPO_ROOT="$(
    cd -- "$SCRIPT_DIR/../.."
    pwd -P
)"

REPO_PARENT="$(dirname -- "$REPO_ROOT")"
DEFAULT_WORKSPACE_ROOT="$REPO_PARENT"

CONFIG_VALIDATOR="$SCRIPT_DIR/10-validate-config.sh"
USER_VALIDATOR="$SCRIPT_DIR/50-validate-users.sh"

WORKSPACE_NAME="$DEFAULT_WORKSPACE_NAME"
WORKSPACE_ROOT="$DEFAULT_WORKSPACE_ROOT"
REQUEST_TIMEOUT="$DEFAULT_REQUEST_TIMEOUT"

PROFILES=0
API_READY=0
INVENTORY_COMPLETE_COUNT=0
INVENTORY_BEST_EFFORT_COUNT=0
FAILED=0
WARNINGS=0
ERRORS=0

TEMP_DIR=""


# ----------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------

fail()
{
    echo "ERROR: $*" >&2
    exit 1
}


record_warning()
{
    echo "WARNING: $*" >&2
    WARNINGS=$((WARNINGS + 1))
}


record_error()
{
    echo "ERROR: $*" >&2
    ERRORS=$((ERRORS + 1))
}


cleanup()
{
    if [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ]; then
        rm -rf -- "$TEMP_DIR"
    fi
}


trap cleanup EXIT HUP INT TERM


usage()
{
    cat <<EOF_USAGE
$PROJECT_NAME live profile validation

Usage:
  $(basename "$0") [options]

Options:
  --workspace-name NAME
      Workspace directory name.

      Default:
        $DEFAULT_WORKSPACE_NAME

  --workspace-root PATH
      Parent directory containing workspace.

      Default:
        $DEFAULT_WORKSPACE_ROOT

  --request-timeout DURATION
      Kubernetes request timeout.

      Default:
        $DEFAULT_REQUEST_TIMEOUT

  -h, --help
      Show this help.
EOF_USAGE
}


detect_host_platform()
{
    local os_name
    local arch_name

    case "$(uname -s)" in
        Linux)
            os_name="linux"
            ;;
        *)
            fail "unsupported host operating system: $(uname -s)"
            ;;
    esac

    case "$(uname -m)" in
        x86_64|amd64)
            arch_name="amd64"
            ;;
        aarch64|arm64)
            arch_name="arm64"
            ;;
        *)
            fail "unsupported host architecture: $(uname -m)"
            ;;
    esac

    printf '%s-%s\n' "$os_name" "$arch_name"
}


namespace_name_is_valid()
{
    local value="$1"

    [ "${#value}" -le 63 ] || return 1
    [[ "$value" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]
}


first_nonempty_line()
{
    awk 'NF { print; exit }' "$1"
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


normalized_inventory()
{
    local cluster="$1"
    local user="$2"
    local context="$3"
    local method="$4"
    local complete="$5"
    local entries_json="$6"
    local timestamp="$7"

    jq -n \
        --arg schema "$INVENTORY_SCHEMA" \
        --argjson schemaVersion "$INVENTORY_SCHEMA_VERSION" \
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


write_inventory_cache()
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
        fail "internal KubeBase state must not be a symlink: $state_root"

    for path in "$state_root" "$cache_root" "$namespace_root" "$cache_dir"; do
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

    printf '%s\n' "$inventory" > "$temp"
    chmod 600 "$temp"
    mv -f -- "$temp" "$cache_file"

    printf '%s\n' "$cache_file"
}


discover_namespace_inventory()
{
    local kubectl_bin="$1"
    local kubeconfig="$2"
    local context="$3"
    local cluster="$4"
    local user="$5"

    local namespace_json
    local list_error_file="$TEMP_DIR/list-error.$$"
    local review_text
    local review_error_file="$TEMP_DIR/review-error.$$"
    local request_namespace
    local candidate
    local candidate_json
    local candidate_error_file
    local project_id
    local entries_file="$TEMP_DIR/entries.$$"
    local entries_json
    local timestamp
    local -a candidates=()

    DISCOVERY_JSON=""
    DISCOVERY_METHOD=""
    DISCOVERY_COMPLETE="false"
    DISCOVERY_NOTE=""
    DISCOVERY_ERROR=""

    : > "$list_error_file"

    if namespace_json="$(
        "$kubectl_bin" \
            --kubeconfig "$kubeconfig" \
            --context "$context" \
            --request-timeout="$REQUEST_TIMEOUT" \
            get namespaces \
            -o json \
            2>"$list_error_file"
    )"
    then
        entries_json="$(entries_from_namespace_list <<< "$namespace_json")"
        timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

        DISCOVERY_JSON="$(
            normalized_inventory \
                "$cluster" \
                "$user" \
                "$context" \
                "namespace-list" \
                true \
                "$entries_json" \
                "$timestamp"
        )"
        DISCOVERY_METHOD="namespace-list"
        DISCOVERY_COMPLETE="true"
        return 0
    fi

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
            --request-timeout="$REQUEST_TIMEOUT" \
            auth can-i \
            --list \
            --namespace "$request_namespace" \
            2>"$review_error_file"
    )"
    then
        DISCOVERY_ERROR="namespace list: $(first_nonempty_line "$list_error_file"); rules review: $(first_nonempty_line "$review_error_file")"
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
        namespace_name_is_valid "$candidate" || continue

        candidate_error_file="$TEMP_DIR/candidate-error.$$.${RANDOM}"

        if candidate_json="$(
            "$kubectl_bin" \
                --kubeconfig "$kubeconfig" \
                --context "$context" \
                --request-timeout="$REQUEST_TIMEOUT" \
                get namespace "$candidate" \
                -o json \
                2>"$candidate_error_file"
        )"
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
        fi

        rm -f -- "$candidate_error_file"
    done

    entries_json="$(jq -s '.' "$entries_file")"
    timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

    DISCOVERY_JSON="$(
        normalized_inventory \
            "$cluster" \
            "$user" \
            "$context" \
            "auth-can-i" \
            false \
            "$entries_json" \
            "$timestamp"
    )"
    DISCOVERY_METHOD="auth-can-i"
    DISCOVERY_COMPLETE="false"
    DISCOVERY_NOTE="namespace LIST is unavailable; inventory is best effort"
    return 0
}


# ----------------------------------------------------------------------
# Arguments
# ----------------------------------------------------------------------

while [ "$#" -gt 0 ]; do
    case "$1" in
        --workspace-name)
            [ "$#" -ge 2 ] || fail "--workspace-name requires a value"
            WORKSPACE_NAME="$2"
            shift 2
            ;;
        --workspace-root)
            [ "$#" -ge 2 ] || fail "--workspace-root requires a value"
            WORKSPACE_ROOT="$2"
            shift 2
            ;;
        --request-timeout)
            [ "$#" -ge 2 ] || fail "--request-timeout requires a value"
            REQUEST_TIMEOUT="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "ERROR: unknown argument: $1" >&2
            echo >&2
            usage >&2
            exit 2
            ;;
    esac
done


# ----------------------------------------------------------------------
# Preconditions
# ----------------------------------------------------------------------

command -v jq >/dev/null 2>&1 || fail "jq is required"

[ -x "$CONFIG_VALIDATOR" ] || fail "configuration validator not found: $CONFIG_VALIDATOR"
[ -x "$USER_VALIDATOR" ] || fail "user validator not found: $USER_VALIDATOR"

"$CONFIG_VALIDATOR" \
    --workspace-name "$WORKSPACE_NAME" \
    --workspace-root "$WORKSPACE_ROOT" \
    --quiet

if ! "$USER_VALIDATOR" \
    --workspace-name "$WORKSPACE_NAME" \
    --workspace-root "$WORKSPACE_ROOT" \
    >/dev/null
then
    fail "local user validation failed; run 'kubebase validate-users' for details"
fi


# ----------------------------------------------------------------------
# Workspace / configuration
# ----------------------------------------------------------------------

[[ "$WORKSPACE_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || \
    fail "invalid workspace name: $WORKSPACE_NAME"

[ -d "$WORKSPACE_ROOT" ] || fail "workspace root not found: $WORKSPACE_ROOT"

WORKSPACE_ROOT="$(cd -- "$WORKSPACE_ROOT" && pwd -P)"
WORKSPACE_DIR="$WORKSPACE_ROOT/$WORKSPACE_NAME"
WORKSPACE_FILE="$WORKSPACE_DIR/workspace.json"
CLUSTERS_DIR="$WORKSPACE_DIR/clusters"
HOST_PLATFORM="$(detect_host_platform)"

[ -f "$WORKSPACE_FILE" ] || fail "workspace configuration not found: $WORKSPACE_FILE"
[ -d "$CLUSTERS_DIR" ] || fail "clusters directory not found: $CLUSTERS_DIR"

CONFIG_PATH="$(jq -r '.configuration.path' "$WORKSPACE_FILE")"

if [[ "$CONFIG_PATH" = /* ]]; then
    CONFIG_DIR_CANDIDATE="$CONFIG_PATH"
else
    CONFIG_DIR_CANDIDATE="$WORKSPACE_DIR/$CONFIG_PATH"
fi

[ -d "$CONFIG_DIR_CANDIDATE" ] || fail "configuration directory not found: $CONFIG_DIR_CANDIDATE"
CONFIG_DIR="$(cd -- "$CONFIG_DIR_CANDIDATE" && pwd -P)"

TEMP_DIR="$(mktemp -d)"

mapfile -d '' -t CONFIG_FILES < <(
    find "$CONFIG_DIR" \
        -maxdepth 1 \
        \( -type f -o -type l \) \
        -name '*.json' \
        -print0 |
    sort -z
)

CLUSTER_FILES=()

for config_file in "${CONFIG_FILES[@]}"; do
    if jq -e \
        --arg schema "$CLUSTER_SCHEMA" \
        --argjson version "$CLUSTER_SCHEMA_VERSION" '
        .schema == $schema and .schemaVersion == $version
    ' "$config_file" >/dev/null 2>&1
    then
        CLUSTER_FILES+=("$config_file")
    fi
done


echo "$PROJECT_NAME live profile validation"
echo
echo "Repository : $REPO_ROOT"
echo "Workspace  : $WORKSPACE_DIR"
echo "Config dir : $CONFIG_DIR"
echo "Platform   : $HOST_PLATFORM"
echo "Network    : enabled (read-only)"


# ----------------------------------------------------------------------
# Profiles
# ----------------------------------------------------------------------

for CLUSTER_FILE in "${CLUSTER_FILES[@]}"; do
    CLUSTER_NAME="$(jq -r '.name' "$CLUSTER_FILE")"
    CLUSTER_DIR="$CLUSTERS_DIR/$CLUSTER_NAME"
    KUBECTL_BIN="$CLUSTER_DIR/toolchains/$HOST_PLATFORM/bin/kubectl"

    if [ ! -x "$KUBECTL_BIN" ]; then
        record_error "cluster '$CLUSTER_NAME': materialized kubectl is missing: $KUBECTL_BIN"
        continue
    fi

    mapfile -t USER_NAMES < <(jq -r '.users | keys[]' "$CLUSTER_FILE")

    for USER_NAME in "${USER_NAMES[@]}"; do
        PROFILES=$((PROFILES + 1))
        PROFILE_FAILED=0

        KUBECONFIG_REL="$(
            jq -r --arg user "$USER_NAME" '.users[$user].kubeconfig' "$CLUSTER_FILE"
        )"
        DECLARED_CONTEXT="$(
            jq -r --arg user "$USER_NAME" '.users[$user].context // ""' "$CLUSTER_FILE"
        )"
        KUBECONFIG_FILE="$CLUSTER_DIR/users/$USER_NAME/$KUBECONFIG_REL"

        echo
        echo "Profile: $CLUSTER_NAME/$USER_NAME"
        echo "  kubeconfig : $KUBECONFIG_FILE"

        if [ -n "$DECLARED_CONTEXT" ]; then
            SELECTED_CONTEXT="$DECLARED_CONTEXT"
            CONTEXT_SELECTION="configured users.$USER_NAME.context"
        else
            SELECTED_CONTEXT="$(
                "$KUBECTL_BIN" \
                    --kubeconfig "$KUBECONFIG_FILE" \
                    config current-context 2>/dev/null || true
            )"
            CONTEXT_SELECTION="kubeconfig current-context"
        fi

        if [ -z "$SELECTED_CONTEXT" ]; then
            record_error "profile '$CLUSTER_NAME/$USER_NAME': no context is selected"
            FAILED=$((FAILED + 1))
            echo "  status     : FAILED"
            continue
        fi

        echo "  context    : $SELECTED_CONTEXT"
        echo "  selection  : $CONTEXT_SELECTION"

        API_ERROR_FILE="$TEMP_DIR/api-error.$$"
        : > "$API_ERROR_FILE"

        # Use the core API discovery endpoint as the readiness/authentication
        # probe. Restricted Rancher profiles may legitimately have access to
        # /api and /apis while /version is denied as a non-resource URL.
        # Therefore /version is informational only and must not decide whether
        # a profile is usable.
        if API_DISCOVERY_JSON="$(
            "$KUBECTL_BIN" \
                --kubeconfig "$KUBECONFIG_FILE" \
                --context "$SELECTED_CONTEXT" \
                --request-timeout="$REQUEST_TIMEOUT" \
                get --raw=/api \
                2>"$API_ERROR_FILE"
        )"
        then
            API_READY=$((API_READY + 1))

            API_CORE_VERSIONS="$(
                jq -r '(.versions // []) | join(",")' \
                    <<< "$API_DISCOVERY_JSON" 2>/dev/null || true
            )"

            API_GIT_VERSION="$(
                "$KUBECTL_BIN" \
                    --kubeconfig "$KUBECONFIG_FILE" \
                    --context "$SELECTED_CONTEXT" \
                    --request-timeout="$REQUEST_TIMEOUT" \
                    get --raw=/version \
                    2>/dev/null |
                jq -r '.gitVersion // empty' 2>/dev/null || true
            )"

            if [ -n "$API_GIT_VERSION" ]; then
                echo "  api        : OK ($API_GIT_VERSION)"
            elif [ -n "$API_CORE_VERSIONS" ]; then
                echo "  api        : OK (core discovery: $API_CORE_VERSIONS)"
            else
                echo "  api        : OK"
            fi
        else
            API_ERROR="$(first_nonempty_line "$API_ERROR_FILE")"
            record_error "profile '$CLUSTER_NAME/$USER_NAME': Kubernetes API discovery failed: $API_ERROR"
            FAILED=$((FAILED + 1))
            echo "  api        : FAILED"
            echo "  status     : FAILED"
            continue
        fi

        if discover_namespace_inventory \
            "$KUBECTL_BIN" \
            "$KUBECONFIG_FILE" \
            "$SELECTED_CONTEXT" \
            "$CLUSTER_NAME" \
            "$USER_NAME"
        then
            CACHE_FILE="$(
                write_inventory_cache \
                    "$WORKSPACE_DIR" \
                    "$CLUSTER_NAME" \
                    "$USER_NAME" \
                    "$DISCOVERY_JSON"
            )"

            NS_COUNT="$(jq '.entries | length' <<< "$DISCOVERY_JSON")"
            PROJECT_COUNT="$(
                jq '[.entries[].projectId | select(. != null and . != "")] | unique | length' \
                    <<< "$DISCOVERY_JSON"
            )"

            echo "  discovery  : $DISCOVERY_METHOD"
            echo "  namespaces : $NS_COUNT"
            echo "  projects   : $PROJECT_COUNT"
            echo "  cache      : $CACHE_FILE"

            if [ "$DISCOVERY_COMPLETE" = "true" ]; then
                INVENTORY_COMPLETE_COUNT=$((INVENTORY_COMPLETE_COUNT + 1))
                echo "  inventory  : complete"
            else
                INVENTORY_BEST_EFFORT_COUNT=$((INVENTORY_BEST_EFFORT_COUNT + 1))
                echo "  inventory  : best effort"
                if [ -n "$DISCOVERY_NOTE" ]; then
                    echo "  note       : $DISCOVERY_NOTE"
                fi
            fi

            echo "  status     : READY"
        else
            record_warning "profile '$CLUSTER_NAME/$USER_NAME': namespace discovery unavailable: $DISCOVERY_ERROR"
            echo "  discovery  : unavailable"
            echo "  status     : PARTIAL"
        fi
    done
done


# ----------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------

echo
echo "Live validation complete."
echo
echo "Summary:"
echo "  profiles              : $PROFILES"
echo "  API ready             : $API_READY"
echo "  inventory complete    : $INVENTORY_COMPLETE_COUNT"
echo "  inventory best effort : $INVENTORY_BEST_EFFORT_COUNT"
echo "  failed                : $FAILED"
echo "  warnings              : $WARNINGS"
echo "  errors                : $ERRORS"

if [ "$ERRORS" -ne 0 ]; then
    echo
    echo "Validation FAILED."
    exit 1
fi

if [ "$WARNINGS" -ne 0 ]; then
    echo
    echo "Validation OK with warnings."
else
    echo
    echo "Validation OK"
fi
