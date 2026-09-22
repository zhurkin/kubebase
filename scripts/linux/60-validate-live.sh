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

TOOLCHAIN_SCHEMA="kubebase.clusterToolchain"
TOOLCHAIN_SCHEMA_VERSION=1

INSTALL_SCHEMA="kubebase.toolInstall"
INSTALL_SCHEMA_VERSION=1

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
source "$LIB_DIR/oidc.sh"

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
  kubebase validate live [options]

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
    kb_namespace_cache_v3_write "$@"
}


verify_materialized_kubectl()
{
    local cluster_name="$1"
    local cluster_file="$2"
    local cluster_dir="$3"
    local platform="$4"

    local kubectl_version
    local install_dir
    local install_manifest
    local installed_binary_file
    local installed_binary_sha256
    local installed_binary_path
    local actual_installed_sha256

    local toolchain_dir
    local toolchain_manifest
    local command_path
    local expected_target
    local actual_target
    local manifest_sha256
    local actual_command_sha256

    kubectl_version="$(jq -r 'if (.tools.kubectl.enabled? != false) then (.tools.kubectl.version // empty) else empty end' "$cluster_file")"
    [ -n "$kubectl_version" ] || return 1

    install_dir="$WORKSPACE_DIR/tools/$platform/kubectl/$kubectl_version"
    install_manifest="$install_dir/manifest.json"

    [ -f "$install_manifest" ] || return 1
    [ -r "$install_manifest" ] || return 1

    if ! jq -e \
        --arg schema "$INSTALL_SCHEMA" \
        --argjson schemaVersion "$INSTALL_SCHEMA_VERSION" \
        --arg version "$kubectl_version" \
        --arg platform "$platform" '
        .schema == $schema
        and
        .schemaVersion == $schemaVersion
        and
        .tool == "kubectl"
        and
        .version == $version
        and
        .platform == $platform
        and
        (.binary.file | type) == "string"
        and
        (.binary.sha256 | type) == "string"
    ' "$install_manifest" >/dev/null 2>&1
    then
        return 1
    fi

    installed_binary_file="$(jq -r '.binary.file' "$install_manifest")"
    installed_binary_sha256="$(jq -r '.binary.sha256' "$install_manifest")"
    installed_binary_sha256="${installed_binary_sha256,,}"

    kb_safe_filename "$installed_binary_file" || return 1
    [[ "$installed_binary_sha256" =~ ^[0-9a-f]{64}$ ]] || return 1

    installed_binary_path="$install_dir/$installed_binary_file"
    [ -f "$installed_binary_path" ] || return 1
    [ -x "$installed_binary_path" ] || return 1

    actual_installed_sha256="$(sha256sum "$installed_binary_path" | awk '{print $1}')"
    actual_installed_sha256="${actual_installed_sha256,,}"
    [ "$actual_installed_sha256" = "$installed_binary_sha256" ] || return 1

    toolchain_dir="$cluster_dir/toolchains/$platform"
    toolchain_manifest="$toolchain_dir/manifest.json"
    command_path="$toolchain_dir/bin/kubectl"
    expected_target="../../../../../tools/$platform/kubectl/$kubectl_version/$installed_binary_file"

    [ -f "$toolchain_manifest" ] || return 1
    [ -r "$toolchain_manifest" ] || return 1

    if ! jq -e \
        --arg schema "$TOOLCHAIN_SCHEMA" \
        --argjson schemaVersion "$TOOLCHAIN_SCHEMA_VERSION" \
        --arg cluster "$cluster_name" \
        --arg platform "$platform" \
        --arg version "$kubectl_version" \
        --arg binary "$installed_binary_file" \
        --arg sha256 "$installed_binary_sha256" \
        --arg linkTarget "$expected_target" '
        .schema == $schema
        and
        .schemaVersion == $schemaVersion
        and
        .cluster == $cluster
        and
        .platform == $platform
        and
        (.commands.kubectl | type) == "object"
        and
        .commands.kubectl.tool == "kubectl"
        and
        .commands.kubectl.version == $version
        and
        .commands.kubectl.binary == $binary
        and
        ((.commands.kubectl.sha256 | ascii_downcase) == $sha256)
        and
        .commands.kubectl.linkTarget == $linkTarget
    ' "$toolchain_manifest" >/dev/null 2>&1
    then
        return 1
    fi

    [ -L "$command_path" ] || return 1
    [ -x "$command_path" ] || return 1

    actual_target="$(readlink -- "$command_path")"
    [ "$actual_target" = "$expected_target" ] || return 1

    manifest_sha256="$(jq -r '.commands.kubectl.sha256' "$toolchain_manifest")"
    manifest_sha256="${manifest_sha256,,}"
    [[ "$manifest_sha256" =~ ^[0-9a-f]{64}$ ]] || return 1

    actual_command_sha256="$(sha256sum "$command_path" | awk '{print $1}')"
    actual_command_sha256="${actual_command_sha256,,}"

    [ "$actual_command_sha256" = "$manifest_sha256" ] || return 1
    [ "$actual_command_sha256" = "$installed_binary_sha256" ] || return 1

    VERIFIED_LIVE_KUBECTL="$command_path"
    return 0
}


# ----------------------------------------------------------------------
# Arguments
# ----------------------------------------------------------------------

while [ "$#" -gt 0 ]; do
    case "$1" in
        --workspace-name)
            [ "$#" -ge 2 ] || { echo "ERROR: --workspace-name requires a value" >&2; exit 2; }
            WORKSPACE_NAME="$2"
            shift 2
            ;;
        --workspace-root)
            [ "$#" -ge 2 ] || { echo "ERROR: --workspace-root requires a value" >&2; exit 2; }
            WORKSPACE_ROOT="$2"
            shift 2
            ;;
        --request-timeout)
            [ "$#" -ge 2 ] || { echo "ERROR: --request-timeout requires a value" >&2; exit 2; }
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
    kb_fail "local user validation failed; run 'kubebase validate users' for details"
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


LIVE_BASE_PATH="$PATH"
if [ -n "${KREW_ROOT+x}" ]; then
    LIVE_BASE_KREW_ROOT_SET=1
    LIVE_BASE_KREW_ROOT="$KREW_ROOT"
else
    LIVE_BASE_KREW_ROOT_SET=0
    LIVE_BASE_KREW_ROOT=""
fi


# ----------------------------------------------------------------------
# Profiles
# ----------------------------------------------------------------------

for CLUSTER_FILE in "${CLUSTER_FILES[@]}"; do
    CLUSTER_NAME="$(jq -r '.name' "$CLUSTER_FILE")"
    CLUSTER_DIR="$CLUSTERS_DIR/$CLUSTER_NAME"

    if ! verify_materialized_kubectl \
        "$CLUSTER_NAME" \
        "$CLUSTER_FILE" \
        "$CLUSTER_DIR" \
        "$HOST_PLATFORM"
    then
        record_error "cluster '$CLUSTER_NAME': materialized kubectl failed integrity verification; run: kubebase materialize"
        continue
    fi

    KUBECTL_BIN="$VERIFIED_LIVE_KUBECTL"

    # Exec credential plugins such as kubectl oidc-login are discovered via
    # PATH. When Krew is enabled for this cluster, validate live must use the
    # same cluster-scoped KREW_ROOT and plugin PATH as an activated profile.
    if jq -e '
        (.tools.krew? | type) == "object"
        and (.tools.krew.enabled? != false)
    ' "$CLUSTER_FILE" >/dev/null 2>&1; then
        CLUSTER_KREW_ROOT="$(
            kb_krew_root_for_cluster \
                "$WORKSPACE_DIR" \
                "$CLUSTER_NAME" \
                "$HOST_PLATFORM"
        )"
        export KREW_ROOT="$CLUSTER_KREW_ROOT"
        export PATH="$CLUSTER_DIR/toolchains/$HOST_PLATFORM/bin:$CLUSTER_KREW_ROOT/bin:$LIVE_BASE_PATH"
    else
        if [ "$LIVE_BASE_KREW_ROOT_SET" -eq 1 ]; then
            export KREW_ROOT="$LIVE_BASE_KREW_ROOT"
        else
            unset KREW_ROOT
        fi
        export PATH="$LIVE_BASE_PATH"
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
        LIVE_KUBECONFIG_FILE="$KUBECONFIG_FILE"

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

        if kb_user_uses_oidc "$CLUSTER_FILE" "$USER_NAME"; then
            OIDC_PLUGIN="$(kb_oidc_plugin_path "$CLUSTER_KREW_ROOT")"

            if [ ! -x "$OIDC_PLUGIN" ]; then
                record_error "profile '$CLUSTER_NAME/$USER_NAME': OIDC dependency oidc-login is not prepared; run: kubebase auth prepare"
                FAILED=$((FAILED + 1))
                printf '  %-36s : %s\n' "Status" "FAILED"
                continue
            fi

            LIVE_FLAT_JSON="$TEMP_DIR/${CLUSTER_NAME}.${USER_NAME}.flat.json"
            LIVE_OIDC_JSON="$TEMP_DIR/${CLUSTER_NAME}.${USER_NAME}.oidc.json"

            if ! "$KUBECTL_BIN" \
                --kubeconfig "$KUBECONFIG_FILE" \
                config view \
                --raw \
                --flatten \
                -o json \
                > "$LIVE_FLAT_JSON"
            then
                record_error "profile '$CLUSTER_NAME/$USER_NAME': failed to flatten kubeconfig for OIDC validation"
                FAILED=$((FAILED + 1))
                printf '  %-36s : %s\n' "Status" "FAILED"
                continue
            fi

            LIVE_CONTEXT_USER="$(
                jq -r \
                    --arg context "$SELECTED_CONTEXT" '
                    [
                        .contexts[]
                        | select(.name == $context)
                        | .context.user // ""
                    ]
                    | if length == 1 then .[0] else "" end
                ' "$LIVE_FLAT_JSON"
            )"

            if [ -z "$LIVE_CONTEXT_USER" ]; then
                record_error "profile '$CLUSTER_NAME/$USER_NAME': selected context has no unique auth user for OIDC overlay"
                FAILED=$((FAILED + 1))
                printf '  %-36s : %s\n' "Status" "FAILED"
                continue
            fi

            if ! kb_oidc_overlay_kubeconfig_json \
                "$CLUSTER_FILE" \
                "$USER_NAME" \
                "$LIVE_CONTEXT_USER" \
                "$LIVE_FLAT_JSON" \
                "$LIVE_OIDC_JSON"
            then
                record_error "profile '$CLUSTER_NAME/$USER_NAME': failed to build OIDC effective kubeconfig"
                FAILED=$((FAILED + 1))
                printf '  %-36s : %s\n' "Status" "FAILED"
                continue
            fi

            chmod 600 "$LIVE_OIDC_JSON"
            LIVE_KUBECONFIG_FILE="$LIVE_OIDC_JSON"
            echo "  auth       : oidc (effective overlay)"
        fi

        # Namespace discovery itself is the live API/authentication probe.
        # This avoids relying on non-resource endpoints such as /version or
        # /api, which API gateways or Kubernetes RBAC may deny even when normal
        # namespaced API access is fully usable.
        if discover_namespace_inventory \
            "$KUBECTL_BIN" \
            "$LIVE_KUBECONFIG_FILE" \
            "$SELECTED_CONTEXT" \
            "$CLUSTER_NAME" \
            "$USER_NAME"
        then
            API_READY=$((API_READY + 1))

            API_GIT_VERSION="$(
                "$KUBECTL_BIN" \
                    --kubeconfig "$LIVE_KUBECONFIG_FILE" \
                    --context "$SELECTED_CONTEXT" \
                    --request-timeout="$REQUEST_TIMEOUT" \
                    get --raw=/version \
                    2>/dev/null |
                jq -r '.gitVersion // empty' 2>/dev/null || true
            )"

            write_inventory_cache \
                "$WORKSPACE_DIR" \
                "$CLUSTER_NAME" \
                "$USER_NAME" \
                "$SELECTED_CONTEXT" \
                "$DISCOVERY_JSON"

            CACHE_FILE="$KB_NAMESPACE_CACHE_FILE"
            CACHE_SNAPSHOT_FILE="$KB_NAMESPACE_CACHE_SNAPSHOT_FILE"

            NS_COUNT="$(jq '.entries | length' <<< "$DISCOVERY_JSON")"
            GROUP_COUNT="$(
                jq '[.entries[].group | select(. != null) | [.kind, .id]] | unique | length' \
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
            printf '    %-34s : %s\n' "Latest" "$CACHE_FILE"
            printf '    %-34s : %s\n' "Snapshot" "$CACHE_SNAPSHOT_FILE"

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

export PATH="$LIVE_BASE_PATH"
if [ "$LIVE_BASE_KREW_ROOT_SET" -eq 1 ]; then
    export KREW_ROOT="$LIVE_BASE_KREW_ROOT"
else
    unset KREW_ROOT
fi


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
