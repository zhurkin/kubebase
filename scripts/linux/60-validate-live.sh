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
# Discovery is capability-based. When cluster-wide Namespace LIST is
# permitted, the resulting inventory is complete for the identity used.
# Otherwise KubeBase extracts namespace resourceNames from authorization
# rules and verifies every discovered Namespace object individually. In
# that fallback mode the discovered entries are verified, but inventory
# completeness cannot be guaranteed.
#
# A successful inventory refresh is written to the same cache used by
# `kubebase namespaces`.
# ----------------------------------------------------------------------

PROJECT_NAME="KubeBase"

CLUSTER_SCHEMA="kubebase.cluster"
CLUSTER_SCHEMA_VERSION=1

INVENTORY_SCHEMA="kubebase.namespaceInventory"
INVENTORY_SCHEMA_VERSION=2

DEFAULT_WORKSPACE_NAME="kubebase-workspace"
DEFAULT_REQUEST_TIMEOUT="10s"


# ----------------------------------------------------------------------
# Paths / defaults
# ----------------------------------------------------------------------

SCRIPT_DIR="$(
    cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
    pwd -P
)"

LIB_DIR="$SCRIPT_DIR/lib"
source "$LIB_DIR/common.sh"
source "$LIB_DIR/workspace.sh"
source "$LIB_DIR/namespace-inventory.sh"

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
INVENTORY_PARTIAL_COUNT=0
INVENTORY_UNAVAILABLE_COUNT=0
FAILED=0
WARNINGS=0
ERRORS=0

TEMP_DIR=""


# ----------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------

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


discover_namespace_inventory()
{
    local kubectl_bin="$1"
    local kubeconfig="$2"
    local context="$3"
    local cluster="$4"
    local user="$5"
    local status=0

    kb_namespace_discover_live \
        "$kubectl_bin" \
        "$kubeconfig" \
        "$context" \
        "$cluster" \
        "$user" \
        "$REQUEST_TIMEOUT" \
        "$TEMP_DIR" || status=$?

    DISCOVERY_JSON="$KB_NAMESPACE_DISCOVERY_JSON"
    DISCOVERY_METHOD="$KB_NAMESPACE_DISCOVERY_METHOD"
    DISCOVERY_COMPLETE="$KB_NAMESPACE_DISCOVERY_COMPLETE"
    DISCOVERY_NOTE="$KB_NAMESPACE_DISCOVERY_NOTE"
    DISCOVERY_ERROR="$KB_NAMESPACE_DISCOVERY_ERROR"
    DISCOVERY_API_READY="$KB_NAMESPACE_DISCOVERY_API_READY"
    DISCOVERY_LIST_ERROR="$KB_NAMESPACE_DISCOVERY_LIST_ERROR"
    DISCOVERY_NAMES_FOUND="$KB_NAMESPACE_DISCOVERY_NAMES_FOUND"
    DISCOVERY_NAMES_VERIFIED="$KB_NAMESPACE_DISCOVERY_NAMES_VERIFIED"

    return "$status"
}


write_inventory_cache()
{
    kb_namespace_cache_v2_write "$@"
    printf '%s\n' "$KB_NAMESPACE_CACHE_FILE"
}


# ----------------------------------------------------------------------
# Arguments
# ----------------------------------------------------------------------

while [ "$#" -gt 0 ]; do
    case "$1" in
        --workspace-name)
            [ "$#" -ge 2 ] || kb_fail "--workspace-name requires a value"
            WORKSPACE_NAME="$2"
            shift 2
            ;;
        --workspace-root)
            [ "$#" -ge 2 ] || kb_fail "--workspace-root requires a value"
            WORKSPACE_ROOT="$2"
            shift 2
            ;;
        --request-timeout)
            [ "$#" -ge 2 ] || kb_fail "--request-timeout requires a value"
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

command -v jq >/dev/null 2>&1 || kb_fail "jq is required"

[ -x "$CONFIG_VALIDATOR" ] || kb_fail "configuration validator not found: $CONFIG_VALIDATOR"
[ -x "$USER_VALIDATOR" ] || kb_fail "user validator not found: $USER_VALIDATOR"

"$CONFIG_VALIDATOR" \
    --workspace-name "$WORKSPACE_NAME" \
    --workspace-root "$WORKSPACE_ROOT" \
    --quiet

if ! "$USER_VALIDATOR" \
    --workspace-name "$WORKSPACE_NAME" \
    --workspace-root "$WORKSPACE_ROOT" \
    >/dev/null
then
    kb_fail "local user validation failed; run 'kubebase validate-users' for details"
fi


# ----------------------------------------------------------------------
# Workspace / configuration
# ----------------------------------------------------------------------

[[ "$WORKSPACE_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || \
    kb_fail "invalid workspace name: $WORKSPACE_NAME"

[ -d "$WORKSPACE_ROOT" ] || kb_fail "workspace root not found: $WORKSPACE_ROOT"

WORKSPACE_ROOT="$(cd -- "$WORKSPACE_ROOT" && pwd -P)"
WORKSPACE_DIR="$WORKSPACE_ROOT/$WORKSPACE_NAME"
WORKSPACE_FILE="$WORKSPACE_DIR/workspace.json"
CLUSTERS_DIR="$WORKSPACE_DIR/clusters"
HOST_PLATFORM="$(kb_detect_host_platform)"

[ -f "$WORKSPACE_FILE" ] || kb_fail "workspace configuration not found: $WORKSPACE_FILE"
[ -d "$CLUSTERS_DIR" ] || kb_fail "clusters directory not found: $CLUSTERS_DIR"

CONFIG_PATH="$(jq -r '.configuration.path' "$WORKSPACE_FILE")"

if [[ "$CONFIG_PATH" = /* ]]; then
    CONFIG_DIR_CANDIDATE="$CONFIG_PATH"
else
    CONFIG_DIR_CANDIDATE="$WORKSPACE_DIR/$CONFIG_PATH"
fi

[ -d "$CONFIG_DIR_CANDIDATE" ] || kb_fail "configuration directory not found: $CONFIG_DIR_CANDIDATE"
CONFIG_DIR="$(cd -- "$CONFIG_DIR_CANDIDATE" && pwd -P)"

TEMP_DIR="$(mktemp -d)"

mapfile -d '' -t CLUSTER_FILES < <(
    kb_config_cluster_files \
        "$CONFIG_DIR" \
        "$CLUSTER_SCHEMA" \
        "$CLUSTER_SCHEMA_VERSION"
)


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
        echo "Profile : $CLUSTER_NAME/$USER_NAME"
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
            printf '  %-36s : %s\n' "Status" "FAILED"
            continue
        fi

        echo "  context    : $SELECTED_CONTEXT"
        echo "  selection  : $CONTEXT_SELECTION"

        # Namespace discovery itself is the live API/authentication probe.
        # This avoids relying on non-resource endpoints such as /version or
        # /api, which API gateways or Kubernetes RBAC may deny even when normal
        # namespaced API access is fully usable.
        if discover_namespace_inventory \
            "$KUBECTL_BIN" \
            "$KUBECONFIG_FILE" \
            "$SELECTED_CONTEXT" \
            "$CLUSTER_NAME" \
            "$USER_NAME"
        then
            API_READY=$((API_READY + 1))

            API_GIT_VERSION="$(
                "$KUBECTL_BIN" \
                    --kubeconfig "$KUBECONFIG_FILE" \
                    --context "$SELECTED_CONTEXT" \
                    --request-timeout="$REQUEST_TIMEOUT" \
                    get --raw=/version \
                    2>/dev/null |
                jq -r '.gitVersion // empty' 2>/dev/null || true
            )"

            CACHE_FILE="$(
                write_inventory_cache \
                    "$WORKSPACE_DIR" \
                    "$CLUSTER_NAME" \
                    "$USER_NAME" \
                    "$DISCOVERY_JSON"
            )"

            NS_COUNT="$(jq '.entries | length' <<< "$DISCOVERY_JSON")"
            GROUP_COUNT="$(
                jq '[.entries[].groupId | select(. != null and . != "")] | unique | length' \
                    <<< "$DISCOVERY_JSON"
            )"

            echo
            echo "  Connection:"
            printf '    %-34s : %s\n' "Kubernetes API reachable" "YES"
            printf '    %-34s : %s\n' "Identity authenticated" "YES"

            if [ -n "$API_GIT_VERSION" ]; then
                printf '    %-34s : %s\n' "Server version" "$API_GIT_VERSION"
            fi

            if [ "$DISCOVERY_METHOD" = "namespace-list" ]; then
                printf '    %-34s : %s\n' "Cluster-wide namespace LIST" "YES"
            else
                case "$DISCOVERY_LIST_ERROR" in
                    *Forbidden*|*forbidden*)
                        printf '    %-34s : %s\n' "Cluster-wide namespace LIST" "NO (Forbidden)"
                        ;;
                    *)
                        printf '    %-34s : %s\n' "Cluster-wide namespace LIST" "NO"
                        ;;
                esac
            fi

            echo
            echo "  Namespace discovery:"

            if [ "$DISCOVERY_METHOD" = "namespace-list" ]; then
                printf '    %-34s : %s\n' "Names returned by Kubernetes" "$DISCOVERY_NAMES_FOUND"
            else
                printf '    %-34s : %s\n' "Names found in authorization" "$DISCOVERY_NAMES_FOUND"
            fi

            printf '    %-34s : %s / %s\n' \
                "Names verified through API" \
                "$DISCOVERY_NAMES_VERIFIED" \
                "$DISCOVERY_NAMES_FOUND"

            if [ "$DISCOVERY_COMPLETE" = "true" ]; then
                INVENTORY_COMPLETE_COUNT=$((INVENTORY_COMPLETE_COUNT + 1))
                printf '    %-34s : %s\n' "Complete list guaranteed" "YES"
            else
                INVENTORY_PARTIAL_COUNT=$((INVENTORY_PARTIAL_COUNT + 1))
                printf '    %-34s : %s\n' "Complete list guaranteed" "NO"
            fi

            printf '    %-34s : %s\n' "Namespace groups discovered" "$GROUP_COUNT"

            echo
            echo "  Cache:"
            printf '    %-34s : %s\n' "Updated" "YES"
            printf '    %-34s : %s\n' "File" "$CACHE_FILE"

            echo
            printf '  %-36s : %s\n' "Status" "READY"
        else
            echo
            echo "  Connection:"

            if [ "$DISCOVERY_API_READY" = "true" ]; then
                API_READY=$((API_READY + 1))
                INVENTORY_UNAVAILABLE_COUNT=$((INVENTORY_UNAVAILABLE_COUNT + 1))
                record_warning "profile '$CLUSTER_NAME/$USER_NAME': namespace discovery unavailable: $DISCOVERY_ERROR"

                printf '    %-34s : %s\n' "Kubernetes API reachable" "YES"
                printf '    %-34s : %s\n' "Identity authenticated" "YES"
                case "$DISCOVERY_LIST_ERROR" in
                    *Forbidden*|*forbidden*)
                        printf '    %-34s : %s\n' "Cluster-wide namespace LIST" "NO (Forbidden)"
                        ;;
                    *)
                        printf '    %-34s : %s\n' "Cluster-wide namespace LIST" "NO"
                        ;;
                esac

                echo
                echo "  Namespace discovery:"
                printf '    %-34s : %s\n' "Automatic name discovery" "UNAVAILABLE"
                printf '    %-34s : %s\n' "Complete list guaranteed" "NO"
                printf '    %-34s : %s\n' "Explicit namespace selection" "AVAILABLE"

                echo
                printf '  %-36s : %s\n' "Status" "PARTIAL"
            else
                record_error "profile '$CLUSTER_NAME/$USER_NAME': Kubernetes API/authentication failed: $DISCOVERY_ERROR"
                FAILED=$((FAILED + 1))

                case "$DISCOVERY_ERROR" in
                    *Unauthorized*|*unauthorized*)
                        printf '    %-34s : %s\n' "Kubernetes API reachable" "YES"
                        printf '    %-34s : %s\n' "Identity authenticated" "NO"
                        ;;
                    *)
                        printf '    %-34s : %s\n' "Kubernetes API reachable" "NO or unknown"
                        printf '    %-34s : %s\n' "Identity authenticated" "UNKNOWN"
                        ;;
                esac

                echo
                printf '  %-36s : %s\n' "Status" "FAILED"
            fi
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
printf '  %-40s : %s\n' "Profiles checked" "$PROFILES"
printf '  %-40s : %s / %s\n' "Authenticated API access" "$API_READY" "$PROFILES"
printf '  %-40s : %s\n' "Complete namespace lists" "$INVENTORY_COMPLETE_COUNT"
printf '  %-40s : %s\n' "Namespace lists not guaranteed complete" "$INVENTORY_PARTIAL_COUNT"
printf '  %-40s : %s\n' "Namespace discovery unavailable" "$INVENTORY_UNAVAILABLE_COUNT"
printf '  %-40s : %s\n' "Failed profiles" "$FAILED"
printf '  %-40s : %s\n' "Warnings" "$WARNINGS"
printf '  %-40s : %s\n' "Errors" "$ERRORS"

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
