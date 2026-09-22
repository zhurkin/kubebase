#!/usr/bin/env bash

set -euo pipefail


# ----------------------------------------------------------------------
# KubeBase
# Step 70 - Profile discovery and shell activation
# Linux / Bash
#
# A profile is:
#
#   cluster + user
#
# Namespace/group navigation is layered on top by Step 80. Step 70
# owns only the connection identity, kubeconfig selection and cluster
# toolchain.
# ----------------------------------------------------------------------

PROJECT_NAME="KubeBase"

CLUSTER_SCHEMA="kubebase.cluster"
CLUSTER_SCHEMA_VERSION=1

TOOLCHAIN_SCHEMA="kubebase.clusterToolchain"
TOOLCHAIN_SCHEMA_VERSION=1

INSTALL_SCHEMA="kubebase.toolInstall"
INSTALL_SCHEMA_VERSION=1

ARTIFACT_SCHEMA="kubebase.artifact"
ARTIFACT_SCHEMA_VERSION=2

SESSION_SCHEMA="kubebase.session"
SESSION_SCHEMA_VERSION=1

DEFAULT_WORKSPACE_NAME="kubebase-workspace"


# ----------------------------------------------------------------------
# Paths
# ----------------------------------------------------------------------

SCRIPT_DIR="$(
    cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
    pwd -P
)"

LIB_DIR="$SCRIPT_DIR/lib"
source "$LIB_DIR/common.sh"
source "$LIB_DIR/toolchain.sh"
source "$LIB_DIR/workspace.sh"
source "$LIB_DIR/profile.sh"
source "$LIB_DIR/artifact-binary.sh"
source "$LIB_DIR/active-session.sh"
source "$LIB_DIR/oidc.sh"

REPO_ROOT="$(
    cd -- "$SCRIPT_DIR/../.."
    pwd -P
)"

REPO_PARENT="$(dirname -- "$REPO_ROOT")"
DEFAULT_WORKSPACE_ROOT="$REPO_PARENT"

CONFIG_VALIDATOR="$SCRIPT_DIR/10-validate-config.sh"
ENTRYPOINT="$REPO_ROOT/kubebase.sh"


# ----------------------------------------------------------------------
# Defaults / runtime state
# ----------------------------------------------------------------------

WORKSPACE_NAME="$DEFAULT_WORKSPACE_NAME"
WORKSPACE_ROOT="$DEFAULT_WORKSPACE_ROOT"

WORKSPACE_DIR=""
WORKSPACE_FILE=""
CONFIG_DIR=""
CLUSTERS_DIR=""
TOOLS_DIR=""
ARTIFACTS_DIR=""
INTERNAL_DIR=""
SESSIONS_DIR=""
HOST_PLATFORM=""

CONFIG_FILES=()
CLUSTER_FILES=()

PROFILE_ERROR=""
PROFILE_CLUSTER_FILE=""
PROFILE_CLUSTER_NAME=""
PROFILE_USER_NAME=""
PROFILE_CONTEXT=""
PROFILE_CONTEXT_SELECTION=""
PROFILE_CONTEXT_NAMESPACE=""
PROFILE_API_SERVER=""
PROFILE_CLUSTER_DIR=""
PROFILE_TOOLCHAIN_DIR=""
PROFILE_TOOLCHAIN_BIN=""
PROFILE_TOOLCHAIN_MANIFEST=""
PROFILE_KREW_ROOT=""
PROFILE_AUTH_TYPE=""
PROFILE_KUBECONFIG_AUTH_USER=""
PROFILE_SOURCE_KUBECONFIG=""
PROFILE_KUBECTL=""


# ----------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------

usage()
{
    cat <<EOF_USAGE
$PROJECT_NAME profile management

Usage:
  kubebase profiles [options]
  kubebase shell init bash [options]
  kubebase current [--verbose]

Internal activation is normally reached through the Bash function emitted
by 'kubebase shell init bash'.

Options:
  --workspace-name NAME
      Workspace directory name.

      Default:
        $DEFAULT_WORKSPACE_NAME

  --workspace-root PATH
      Parent directory containing workspace.

      Default:
        $DEFAULT_WORKSPACE_ROOT

  -h, --help
      Show this help.
EOF_USAGE
}


set_profile_error()
{
    PROFILE_ERROR="$1"
    return 1
}


# ----------------------------------------------------------------------
# Common option parsing
# ----------------------------------------------------------------------

parse_common_args()
{
    POSITIONAL_ARGS=()

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --workspace-name)
                [ "$#" -ge 2 ] || {
                    echo "ERROR: --workspace-name requires a value" >&2
                    return 2
                }

                WORKSPACE_NAME="$2"
                shift 2
                ;;

            --workspace-root)
                [ "$#" -ge 2 ] || {
                    echo "ERROR: --workspace-root requires a value" >&2
                    return 2
                }

                WORKSPACE_ROOT="$2"
                shift 2
                ;;

            -h|--help)
                POSITIONAL_ARGS+=("--help")
                shift
                ;;

            --)
                shift
                while [ "$#" -gt 0 ]; do
                    POSITIONAL_ARGS+=("$1")
                    shift
                done
                ;;

            --*)
                echo "ERROR: unknown argument: $1" >&2
                return 2
                ;;

            *)
                POSITIONAL_ARGS+=("$1")
                shift
                ;;
        esac
    done
}


# ----------------------------------------------------------------------
# Workspace / configuration discovery
# ----------------------------------------------------------------------

load_workspace()
{
    command -v jq >/dev/null 2>&1 || kb_fail "jq is required"
    command -v sha256sum >/dev/null 2>&1 || kb_fail "sha256sum is required"
    command -v stat >/dev/null 2>&1 || kb_fail "stat is required"
    command -v mktemp >/dev/null 2>&1 || kb_fail "mktemp is required"

    [ -x "$CONFIG_VALIDATOR" ] || \
        kb_fail "configuration validator not found: $CONFIG_VALIDATOR"

    kb_safe_name "$WORKSPACE_NAME" || \
        kb_fail "invalid workspace name: $WORKSPACE_NAME"

    [ -d "$WORKSPACE_ROOT" ] || \
        kb_fail "workspace root not found: $WORKSPACE_ROOT"

    WORKSPACE_ROOT="$(
        cd -- "$WORKSPACE_ROOT"
        pwd -P
    )"

    WORKSPACE_DIR="$WORKSPACE_ROOT/$WORKSPACE_NAME"
    WORKSPACE_FILE="$WORKSPACE_DIR/workspace.json"
    CLUSTERS_DIR="$WORKSPACE_DIR/clusters"
    TOOLS_DIR="$WORKSPACE_DIR/tools"
    ARTIFACTS_DIR="$WORKSPACE_DIR/artifacts"
    INTERNAL_DIR="$WORKSPACE_DIR/.kubebase"
    SESSIONS_DIR="$INTERNAL_DIR/sessions"

    kb_require_readable_file \
        "$WORKSPACE_FILE" \
        "workspace configuration"

    [ -d "$CLUSTERS_DIR" ] || \
        kb_fail "cluster directory not found: $CLUSTERS_DIR"

    [ -d "$TOOLS_DIR" ] || \
        kb_fail "tools directory not found: $TOOLS_DIR"

    [ -d "$ARTIFACTS_DIR" ] || \
        kb_fail "artifact directory not found: $ARTIFACTS_DIR"

    "$CONFIG_VALIDATOR" \
        --workspace-name "$WORKSPACE_NAME" \
        --workspace-root "$WORKSPACE_ROOT" \
        --quiet

    CONFIG_PATH="$(jq -r '.configuration.path' "$WORKSPACE_FILE")"

    if [[ "$CONFIG_PATH" = /* ]]; then
        CONFIG_DIR_CANDIDATE="$CONFIG_PATH"
    else
        CONFIG_DIR_CANDIDATE="$WORKSPACE_DIR/$CONFIG_PATH"
    fi

    [ -d "$CONFIG_DIR_CANDIDATE" ] || \
        kb_fail "configuration directory not found: $CONFIG_DIR_CANDIDATE"

    CONFIG_DIR="$(
        cd -- "$CONFIG_DIR_CANDIDATE"
        pwd -P
    )"

    HOST_PLATFORM="$(kb_detect_host_platform "Linux profile manager")"

    CONFIG_FILES=()
    CLUSTER_FILES=()

    mapfile -d '' -t CLUSTER_FILES < <(
        kb_config_cluster_files \
            "$CONFIG_DIR" \
            "$CLUSTER_SCHEMA" \
            "$CLUSTER_SCHEMA_VERSION"
    )

}


# ----------------------------------------------------------------------
# Installed tool source binding
# ----------------------------------------------------------------------

verify_installed_profile_tool()
{
    local requested_tool="$1"
    local requested_version="$2"
    local requested_platform="$3"

    local install_dir="$TOOLS_DIR/$requested_platform/$requested_tool/$requested_version"
    local install_manifest="$install_dir/manifest.json"
    local artifact_dir="$ARTIFACTS_DIR/$requested_platform/$requested_tool/$requested_version"
    local artifact_manifest="$artifact_dir/manifest.json"

    local recorded_artifact_file
    local recorded_artifact_sha256
    local recorded_source_binary
    local binary_file
    local binary_sha256
    local artifact_file
    local artifact_type
    local artifact_binary
    local artifact_sha256
    local checksum_file
    local checksum_sha256
    local actual_sha256
    local source_binary_sha256
    local expected_binary_file

    VERIFIED_PROFILE_BINARY_FILE=""
    VERIFIED_PROFILE_BINARY_SHA256=""

    [ -f "$install_manifest" ] || return 1
    [ -r "$install_manifest" ] || return 1
    [ -f "$artifact_manifest" ] || return 1
    [ -r "$artifact_manifest" ] || return 1

    jq -e \
        --arg schema "$INSTALL_SCHEMA" \
        --argjson schemaVersion "$INSTALL_SCHEMA_VERSION" \
        --arg tool "$requested_tool" \
        --arg version "$requested_version" \
        --arg platform "$requested_platform" '
        .schema == $schema
        and .schemaVersion == $schemaVersion
        and .tool == $tool
        and .version == $version
        and .platform == $platform
        and (.artifact.file | type) == "string"
        and (.artifact.sha256 | type) == "string"
        and (.binary.sourcePath | type) == "string"
        and (.binary.file | type) == "string"
        and (.binary.sha256 | type) == "string"
    ' "$install_manifest" >/dev/null 2>&1 || return 1

    jq -e \
        --arg schema "$ARTIFACT_SCHEMA" \
        --argjson schemaVersion "$ARTIFACT_SCHEMA_VERSION" \
        --arg tool "$requested_tool" \
        --arg version "$requested_version" \
        --arg platform "$requested_platform" '
        .schema == $schema
        and .schemaVersion == $schemaVersion
        and .tool == $tool
        and .version == $version
        and .platform == $platform
        and (.artifact.file | type) == "string"
        and (.artifact.type | type) == "string"
        and (.artifact.binary | type) == "string"
        and (.artifact.sha256 | type) == "string"
        and (.checksum.file | type) == "string"
        and (.checksum.sha256 | type) == "string"
    ' "$artifact_manifest" >/dev/null 2>&1 || return 1

    recorded_artifact_file="$(jq -r '.artifact.file' "$install_manifest")"
    recorded_artifact_sha256="$(jq -r '.artifact.sha256' "$install_manifest")"
    recorded_source_binary="$(jq -r '.binary.sourcePath' "$install_manifest")"
    binary_file="$(jq -r '.binary.file' "$install_manifest")"
    binary_sha256="$(jq -r '.binary.sha256' "$install_manifest")"

    artifact_file="$(jq -r '.artifact.file' "$artifact_manifest")"
    artifact_type="$(jq -r '.artifact.type' "$artifact_manifest")"
    artifact_binary="$(jq -r '.artifact.binary' "$artifact_manifest")"
    artifact_sha256="$(jq -r '.artifact.sha256' "$artifact_manifest")"
    checksum_file="$(jq -r '.checksum.file' "$artifact_manifest")"
    checksum_sha256="$(jq -r '.checksum.sha256' "$artifact_manifest")"

    recorded_artifact_sha256="${recorded_artifact_sha256,,}"
    binary_sha256="${binary_sha256,,}"
    artifact_sha256="${artifact_sha256,,}"
    checksum_sha256="${checksum_sha256,,}"

    kb_safe_filename "$recorded_artifact_file" || return 1
    kb_safe_filename "$binary_file" || return 1
    kb_safe_filename "$artifact_file" || return 1
    kb_safe_relative_path "$recorded_source_binary" || return 1
    kb_safe_relative_path "$artifact_binary" || return 1
    kb_safe_filename "$checksum_file" || return 1

    [[ "$recorded_artifact_sha256" =~ ^[0-9a-f]{64}$ ]] || return 1
    [[ "$binary_sha256" =~ ^[0-9a-f]{64}$ ]] || return 1
    [[ "$artifact_sha256" =~ ^[0-9a-f]{64}$ ]] || return 1
    [[ "$checksum_sha256" =~ ^[0-9a-f]{64}$ ]] || return 1

    expected_binary_file="$requested_tool"
    case "$requested_platform" in
        windows-*) expected_binary_file="${expected_binary_file}.exe" ;;
    esac

    [ "$binary_file" = "$expected_binary_file" ] || return 1
    [ "$recorded_artifact_file" = "$artifact_file" ] || return 1
    [ "$recorded_artifact_sha256" = "$artifact_sha256" ] || return 1
    [ "$recorded_source_binary" = "$artifact_binary" ] || return 1

    [ -f "$artifact_dir/$artifact_file" ] || return 1
    [ -f "$artifact_dir/$checksum_file" ] || return 1

    actual_sha256="$(sha256sum "$artifact_dir/$artifact_file" | awk '{print $1}')"
    actual_sha256="${actual_sha256,,}"
    [ "$actual_sha256" = "$artifact_sha256" ] || return 1

    actual_sha256="$(sha256sum "$artifact_dir/$checksum_file" | awk '{print $1}')"
    actual_sha256="${actual_sha256,,}"
    [ "$actual_sha256" = "$checksum_sha256" ] || return 1

    if ! source_binary_sha256="$(
        kb_artifact_binary_sha256 \
            "$artifact_dir/$artifact_file" \
            "$artifact_type" \
            "$artifact_binary"
    )"; then
        return 1
    fi

    [ "$source_binary_sha256" = "$binary_sha256" ] || return 1
    [ -f "$install_dir/$binary_file" ] || return 1
    [ -x "$install_dir/$binary_file" ] || return 1

    actual_sha256="$(sha256sum "$install_dir/$binary_file" | awk '{print $1}')"
    actual_sha256="${actual_sha256,,}"
    [ "$actual_sha256" = "$source_binary_sha256" ] || return 1

    VERIFIED_PROFILE_BINARY_FILE="$binary_file"
    VERIFIED_PROFILE_BINARY_SHA256="$source_binary_sha256"
    return 0
}

# ----------------------------------------------------------------------
# Profile resolution / validation
# ----------------------------------------------------------------------

reset_profile_state()
{
    PROFILE_ERROR=""
    PROFILE_CLUSTER_FILE=""
    PROFILE_CLUSTER_NAME=""
    PROFILE_USER_NAME=""
    PROFILE_CONTEXT=""
    PROFILE_CONTEXT_SELECTION=""
    PROFILE_CONTEXT_NAMESPACE=""
    PROFILE_API_SERVER=""
    PROFILE_CLUSTER_DIR=""
    PROFILE_TOOLCHAIN_DIR=""
    PROFILE_TOOLCHAIN_BIN=""
    PROFILE_TOOLCHAIN_MANIFEST=""
    PROFILE_KREW_ROOT=""
    PROFILE_AUTH_TYPE=""
    PROFILE_KUBECONFIG_AUTH_USER=""
    PROFILE_SOURCE_KUBECONFIG=""
    PROFILE_KUBECTL=""
}


resolve_profile()
{
    local selector="$1"

    local cluster_name
    local user_name
    local cluster_file
    local kubeconfig_rel
    local declared_context
    local kubeconfig_json
    local current_context
    local selected_context_count
    local context_cluster
    local context_user
    local context_cluster_count
    local context_user_count
    local tool_name
    local tool_version
    local command_name
    local alias_name
    local alias_path
    local command_path
    local expected_target
    local actual_target
    local expected_sha256
    local actual_sha256
    local command_count
    local tool_count
    local verified_binary_file
    local verified_binary_sha256

    reset_profile_state

    case "$selector" in
        */*)
            cluster_name="${selector%%/*}"
            user_name="${selector#*/}"
            ;;

        *)
            set_profile_error "profile must be specified as cluster/user: $selector"
            return 1
            ;;
    esac

    if [[ "$user_name" == */* ]] || \
       ! kb_safe_name "$cluster_name" || \
       ! kb_safe_name "$user_name"
    then
        set_profile_error "invalid profile selector: $selector"
        return 1
    fi

    if ! cluster_file="$(kb_find_cluster_file "$cluster_name" "${CLUSTER_FILES[@]}")"; then
        set_profile_error "unknown cluster '$cluster_name'"
        return 1
    fi

    if ! jq -e \
        --arg user "$user_name" '
        .users | has($user)
    ' "$cluster_file" >/dev/null 2>&1
    then
        set_profile_error "cluster '$cluster_name' has no user '$user_name'"
        return 1
    fi

    if ! jq -e \
        --arg platform "$HOST_PLATFORM" '
        .toolPlatforms | index($platform) != null
    ' "$cluster_file" >/dev/null 2>&1
    then
        set_profile_error "cluster '$cluster_name' does not declare host platform '$HOST_PLATFORM'"
        return 1
    fi

    PROFILE_CLUSTER_FILE="$cluster_file"
    PROFILE_CLUSTER_NAME="$cluster_name"
    PROFILE_USER_NAME="$user_name"
    PROFILE_CLUSTER_DIR="$CLUSTERS_DIR/$cluster_name"
    PROFILE_TOOLCHAIN_DIR="$PROFILE_CLUSTER_DIR/toolchains/$HOST_PLATFORM"
    PROFILE_TOOLCHAIN_BIN="$PROFILE_TOOLCHAIN_DIR/bin"
    PROFILE_TOOLCHAIN_MANIFEST="$PROFILE_TOOLCHAIN_DIR/manifest.json"

    [ -d "$PROFILE_CLUSTER_DIR" ] || {
        set_profile_error "cluster '$cluster_name' is not materialized"
        return 1
    }

    [ -d "$PROFILE_TOOLCHAIN_BIN" ] || {
        set_profile_error "cluster '$cluster_name' has no materialized toolchain for '$HOST_PLATFORM'"
        return 1
    }

    [ -f "$PROFILE_TOOLCHAIN_MANIFEST" ] || {
        set_profile_error "cluster '$cluster_name' toolchain manifest is missing"
        return 1
    }

    [ -r "$PROFILE_TOOLCHAIN_MANIFEST" ] || {
        set_profile_error "cluster '$cluster_name' toolchain manifest is not readable"
        return 1
    }

    if ! jq -e \
        --arg schema "$TOOLCHAIN_SCHEMA" \
        --argjson schemaVersion "$TOOLCHAIN_SCHEMA_VERSION" \
        --arg cluster "$cluster_name" \
        --arg platform "$HOST_PLATFORM" '
        .schema == $schema
        and
        .schemaVersion == $schemaVersion
        and
        .cluster == $cluster
        and
        .platform == $platform
        and
        (.commands | type) == "object"
    ' "$PROFILE_TOOLCHAIN_MANIFEST" >/dev/null 2>&1
    then
        set_profile_error "cluster '$cluster_name' has an invalid toolchain manifest"
        return 1
    fi

    tool_count="$(jq -r '[.tools | to_entries[] | select(.value.enabled? != false)] | length' "$cluster_file")"
    command_count="$(jq -r '.commands | length' "$PROFILE_TOOLCHAIN_MANIFEST")"

    if [ "$tool_count" -ne "$command_count" ]; then
        set_profile_error "cluster '$cluster_name' toolchain command set does not match configuration"
        return 1
    fi

    while IFS=$'\t' read -r tool_name tool_version; do
        [ -n "$tool_name" ] || continue

        if ! verify_installed_profile_tool \
            "$tool_name" \
            "$tool_version" \
            "$HOST_PLATFORM"
        then
            set_profile_error "cluster '$cluster_name' installed tool failed source verification: $tool_name $tool_version $HOST_PLATFORM"
            return 1
        fi

        verified_binary_file="$VERIFIED_PROFILE_BINARY_FILE"
        verified_binary_sha256="$VERIFIED_PROFILE_BINARY_SHA256"

        command_name="$(kb_tool_command_name "$tool_name")"
        command_path="$PROFILE_TOOLCHAIN_BIN/$command_name"
        expected_target="../../../../../tools/$HOST_PLATFORM/$tool_name/$tool_version/$verified_binary_file"

        if ! jq -e \
            --arg command "$command_name" \
            --arg tool "$tool_name" \
            --arg version "$tool_version" \
            --arg binary "$verified_binary_file" \
            --arg sha256 "$verified_binary_sha256" \
            --arg linkTarget "$expected_target" '
            (.commands[$command] | type) == "object"
            and .commands[$command].tool == $tool
            and .commands[$command].version == $version
            and .commands[$command].binary == $binary
            and ((.commands[$command].sha256 | ascii_downcase) == $sha256)
            and .commands[$command].linkTarget == $linkTarget
        ' "$PROFILE_TOOLCHAIN_MANIFEST" >/dev/null 2>&1
        then
            set_profile_error "cluster '$cluster_name' toolchain entry '$command_name' does not match configuration"
            return 1
        fi

        [ -L "$command_path" ] || {
            set_profile_error "cluster '$cluster_name' toolchain command is not a managed symlink: $command_name"
            return 1
        }

        [ -x "$command_path" ] || {
            set_profile_error "cluster '$cluster_name' toolchain command is not executable: $command_name"
            return 1
        }

        actual_target="$(readlink -- "$command_path")"

        if [ "$actual_target" != "$expected_target" ]; then
            set_profile_error "cluster '$cluster_name' toolchain symlink target changed: $command_name"
            return 1
        fi

        expected_sha256="$verified_binary_sha256"

        actual_sha256="$(
            sha256sum "$command_path" |
            awk '{print $1}'
        )"

        actual_sha256="${actual_sha256,,}"

        if [ "$actual_sha256" != "$expected_sha256" ]; then
            set_profile_error "cluster '$cluster_name' toolchain command failed SHA-256 verification: $command_name"
            return 1
        fi

        while IFS= read -r alias_name; do
            [ -n "$alias_name" ] || continue
            alias_path="$PROFILE_TOOLCHAIN_BIN/$alias_name"

            [ -L "$alias_path" ] || {
                set_profile_error "cluster '$cluster_name' toolchain alias is not a managed symlink: $alias_name"
                return 1
            }

            [ -x "$alias_path" ] || {
                set_profile_error "cluster '$cluster_name' toolchain alias is not executable: $alias_name"
                return 1
            }

            actual_target="$(readlink -- "$alias_path")"
            if [ "$actual_target" != "$expected_target" ]; then
                set_profile_error "cluster '$cluster_name' toolchain alias target changed: $alias_name"
                return 1
            fi

            actual_sha256="$(sha256sum "$alias_path" | awk '{print $1}')"
            actual_sha256="${actual_sha256,,}"
            if [ "$actual_sha256" != "$expected_sha256" ]; then
                set_profile_error "cluster '$cluster_name' toolchain alias failed SHA-256 verification: $alias_name"
                return 1
            fi
        done < <(kb_tool_alias_names "$tool_name")

    done < <(
        jq -r '
            .tools
            | to_entries
            | map(select(.value.enabled? != false))
            | sort_by(.key)
            | .[]
            | [ .key, .value.version ]
            | @tsv
        ' "$cluster_file"
    )

    if jq -e '
        (.tools.krew? | type) == "object"
        and (.tools.krew.enabled? != false)
    ' "$cluster_file" >/dev/null 2>&1; then
        PROFILE_KREW_ROOT="$(
            kb_krew_root_for_cluster \
                "$WORKSPACE_DIR" \
                "$cluster_name" \
                "$HOST_PLATFORM"
        )"
    fi

    PROFILE_AUTH_TYPE="$(kb_user_auth_type "$cluster_file" "$user_name")"

    if [ "$PROFILE_AUTH_TYPE" = "oidc" ]; then
        [ -n "$PROFILE_KREW_ROOT" ] || {
            set_profile_error "cluster '$cluster_name' user '$user_name' OIDC authentication requires enabled Krew"
            return 1
        }

        if [ ! -x "$(kb_oidc_plugin_path "$PROFILE_KREW_ROOT")" ]; then
            set_profile_error "cluster '$cluster_name' user '$user_name' OIDC dependency oidc-login is not prepared; run: kubebase auth prepare"
            return 1
        fi
    fi

    PROFILE_KUBECTL="$PROFILE_TOOLCHAIN_BIN/kubectl"

    [ -x "$PROFILE_KUBECTL" ] || {
        set_profile_error "cluster '$cluster_name' profile requires kubectl in the cluster toolchain"
        return 1
    }

    kubeconfig_rel="$(
        jq -r \
            --arg user "$user_name" '
            .users[$user].kubeconfig
        ' "$cluster_file"
    )"

    if ! kb_safe_relative_path "$kubeconfig_rel"; then
        set_profile_error "cluster '$cluster_name' user '$user_name' has an unsafe kubeconfig path"
        return 1
    fi

    PROFILE_SOURCE_KUBECONFIG="$PROFILE_CLUSTER_DIR/users/$user_name/$kubeconfig_rel"

    [ -f "$PROFILE_SOURCE_KUBECONFIG" ] || {
        set_profile_error "cluster '$cluster_name' user '$user_name' kubeconfig is missing"
        return 1
    }

    [ -r "$PROFILE_SOURCE_KUBECONFIG" ] || {
        set_profile_error "cluster '$cluster_name' user '$user_name' kubeconfig is not readable"
        return 1
    }

    if ! kb_file_permissions_are_private "$PROFILE_SOURCE_KUBECONFIG"; then
        set_profile_error "cluster '$cluster_name' user '$user_name' kubeconfig permissions are too broad"
        return 1
    fi

    if ! kubeconfig_json="$(
        "$PROFILE_KUBECTL" \
            --kubeconfig "$PROFILE_SOURCE_KUBECONFIG" \
            config view \
            -o json
    )"
    then
        set_profile_error "cluster '$cluster_name' user '$user_name' kubeconfig cannot be parsed"
        return 1
    fi

    if ! jq -e '
        (.clusters | type) == "array"
        and
        (.contexts | type) == "array"
        and
        (.users | type) == "array"
        and
        (.clusters | length) > 0
        and
        (.contexts | length) > 0
        and
        (.users | length) > 0
    ' >/dev/null <<< "$kubeconfig_json"
    then
        set_profile_error "cluster '$cluster_name' user '$user_name' kubeconfig has no usable objects"
        return 1
    fi

    kb_profile_select_context \
        "$cluster_file" \
        "$user_name" \
        "$kubeconfig_json"

    PROFILE_CONTEXT="$KB_PROFILE_SELECTED_CONTEXT"
    PROFILE_CONTEXT_SELECTION="$KB_PROFILE_CONTEXT_SELECTION"
    current_context="$KB_PROFILE_CURRENT_CONTEXT"


    [ -n "$PROFILE_CONTEXT" ] || {
        set_profile_error "cluster '$cluster_name' user '$user_name' has no selected context"
        return 1
    }

    selected_context_count="$(
        kb_profile_context_count \
            "$kubeconfig_json" \
            "$PROFILE_CONTEXT"
    )"


    if [ "$selected_context_count" -ne 1 ]; then
        set_profile_error "cluster '$cluster_name' user '$user_name' selected context '$PROFILE_CONTEXT' does not exist exactly once"
        return 1
    fi

    context_cluster="$(
        kb_profile_context_cluster \
            "$kubeconfig_json" \
            "$PROFILE_CONTEXT"
    )"


    context_user="$(
        kb_profile_context_user \
            "$kubeconfig_json" \
            "$PROFILE_CONTEXT"
    )"

    PROFILE_KUBECONFIG_AUTH_USER="$context_user"


    PROFILE_CONTEXT_NAMESPACE="$(
        kb_profile_context_namespace \
            "$kubeconfig_json" \
            "$PROFILE_CONTEXT"
    )"


    [ -n "$context_cluster" ] || {
        set_profile_error "cluster '$cluster_name' user '$user_name' selected context has no cluster"
        return 1
    }

    [ -n "$context_user" ] || {
        set_profile_error "cluster '$cluster_name' user '$user_name' selected context has no auth user"
        return 1
    }

    context_cluster_count="$(
        jq -r \
            --arg cluster "$context_cluster" '
            [ .clusters[] | select(.name == $cluster) ] | length
        ' <<< "$kubeconfig_json"
    )"

    context_user_count="$(
        jq -r \
            --arg user "$context_user" '
            [ .users[] | select(.name == $user) ] | length
        ' <<< "$kubeconfig_json"
    )"

    if [ "$context_cluster_count" -ne 1 ]; then
        set_profile_error "cluster '$cluster_name' user '$user_name' selected context references unknown cluster '$context_cluster'"
        return 1
    fi

    if [ "$context_user_count" -ne 1 ]; then
        set_profile_error "cluster '$cluster_name' user '$user_name' selected context references unknown auth user '$context_user'"
        return 1
    fi

    PROFILE_API_SERVER="$(
        jq -r \
            --arg cluster "$context_cluster" '
            .clusters[]
            | select(.name == $cluster)
            | .cluster.server // ""
        ' <<< "$kubeconfig_json"
    )"

    [ -n "$PROFILE_API_SERVER" ] || {
        set_profile_error "cluster '$cluster_name' user '$user_name' selected cluster has no API server"
        return 1
    }

    return 0
}


# ----------------------------------------------------------------------
# Session state
# ----------------------------------------------------------------------

ensure_session_root()
{
    umask 077

    if [ -L "$INTERNAL_DIR" ]; then
        kb_fail "internal KubeBase state must not be a symlink: $INTERNAL_DIR"
    fi

    if [ -e "$INTERNAL_DIR" ] && [ ! -d "$INTERNAL_DIR" ]; then
        kb_fail "internal KubeBase state is not a directory: $INTERNAL_DIR"
    fi

    if [ ! -d "$INTERNAL_DIR" ]; then
        mkdir -- "$INTERNAL_DIR"
    fi

    chmod 700 "$INTERNAL_DIR"

    if [ -L "$SESSIONS_DIR" ]; then
        kb_fail "KubeBase sessions path must not be a symlink: $SESSIONS_DIR"
    fi

    if [ -e "$SESSIONS_DIR" ] && [ ! -d "$SESSIONS_DIR" ]; then
        kb_fail "KubeBase sessions path is not a directory: $SESSIONS_DIR"
    fi

    if [ ! -d "$SESSIONS_DIR" ]; then
        mkdir -- "$SESSIONS_DIR"
    fi

    chmod 700 "$SESSIONS_DIR"
}


create_profile_session()
{
    local session_dir
    local effective_kubeconfig
    local temp_kubeconfig
    local temp_oidc_kubeconfig
    local session_manifest
    local cleanup_needed=1

    ensure_session_root

    session_dir="$(mktemp -d "$SESSIONS_DIR/session.XXXXXX")"
    effective_kubeconfig="$session_dir/kubeconfig.yaml"
    temp_kubeconfig="$session_dir/.kubeconfig.yaml.tmp"
    temp_oidc_kubeconfig="$session_dir/.kubeconfig.oidc.tmp"
    session_manifest="$session_dir/session.json"

    cleanup_new_session()
    {
        if [ "$cleanup_needed" -ne 0 ] && [ -d "$session_dir" ]; then
            rm -rf -- "$session_dir"
        fi
    }

    trap cleanup_new_session RETURN

    if ! "$PROFILE_KUBECTL" \
        --kubeconfig "$PROFILE_SOURCE_KUBECONFIG" \
        config view \
        --raw \
        --flatten \
        -o json \
        > "$temp_kubeconfig"
    then
        echo "ERROR: failed to create flattened effective kubeconfig" >&2
        return 1
    fi

    if [ "$PROFILE_AUTH_TYPE" = "oidc" ]; then
        if ! kb_oidc_overlay_kubeconfig_json \
            "$PROFILE_CLUSTER_FILE" \
            "$PROFILE_USER_NAME" \
            "$PROFILE_KUBECONFIG_AUTH_USER" \
            "$temp_kubeconfig" \
            "$temp_oidc_kubeconfig"
        then
            echo "ERROR: failed to apply OIDC authentication to effective kubeconfig" >&2
            return 1
        fi

        mv -f -- "$temp_oidc_kubeconfig" "$temp_kubeconfig"
    fi

    chmod 600 "$temp_kubeconfig"
    mv -f -- "$temp_kubeconfig" "$effective_kubeconfig"

    if ! "$PROFILE_KUBECTL" \
        --kubeconfig "$effective_kubeconfig" \
        config use-context "$PROFILE_CONTEXT" \
        >/dev/null
    then
        echo "ERROR: failed to select context '$PROFILE_CONTEXT' in effective kubeconfig" >&2
        return 1
    fi

    if [ "$(
        "$PROFILE_KUBECTL" \
            --kubeconfig "$effective_kubeconfig" \
            config current-context
    )" != "$PROFILE_CONTEXT" ]; then
        echo "ERROR: effective kubeconfig context verification failed" >&2
        return 1
    fi

    jq -n \
        --arg schema "$SESSION_SCHEMA" \
        --argjson schemaVersion "$SESSION_SCHEMA_VERSION" \
        --arg workspace "$WORKSPACE_DIR" \
        --arg cluster "$PROFILE_CLUSTER_NAME" \
        --arg user "$PROFILE_USER_NAME" \
        --arg context "$PROFILE_CONTEXT" \
        --arg contextSelection "$PROFILE_CONTEXT_SELECTION" \
        --arg contextNamespace "$PROFILE_CONTEXT_NAMESPACE" \
        --arg platform "$HOST_PLATFORM" \
        --arg sourceKubeconfig "$PROFILE_SOURCE_KUBECONFIG" \
        --arg effectiveKubeconfig "$effective_kubeconfig" \
        --arg toolchain "$PROFILE_TOOLCHAIN_DIR" \
        --arg krewRoot "$PROFILE_KREW_ROOT" \
        --arg authType "$PROFILE_AUTH_TYPE" '
        {
            schema: $schema,
            schemaVersion: $schemaVersion,
            workspace: $workspace,
            profile: {
                cluster: $cluster,
                user: $user,
                context: $context,
                contextSelection: $contextSelection,
                platform: $platform
            },
            kubeconfig: {
                source: $sourceKubeconfig,
                effective: $effectiveKubeconfig
            },
            navigation: {
                groupFilter: null,
                namespace: (if $contextNamespace == "" then null else $contextNamespace end),
                namespaceGroup: null
            },
            toolchain: $toolchain,
            krewRoot: (if $krewRoot == "" then null else $krewRoot end),
            authType: (if $authType == "" then null else $authType end)
        }
    ' > "$session_manifest"

    chmod 600 "$session_manifest"

    cleanup_needed=0
    trap - RETURN

    PROFILE_SESSION_DIR="$session_dir"
    PROFILE_EFFECTIVE_KUBECONFIG="$effective_kubeconfig"
}


cleanup_profile_session()
{
    local session_dir="$1"
    local session_parent
    local sessions_real
    local parent_real
    local session_name
    local manifest

    [ -n "$session_dir" ] || return 0

    if [ ! -e "$session_dir" ] && [ ! -L "$session_dir" ]; then
        return 0
    fi

    [ ! -L "$session_dir" ] || \
        kb_fail "refusing to remove symlink as KubeBase session: $session_dir"

    [ -d "$session_dir" ] || \
        kb_fail "KubeBase session is not a directory: $session_dir"

    ensure_session_root

    session_parent="$(dirname -- "$session_dir")"
    session_name="$(basename -- "$session_dir")"

    case "$session_name" in
        session.*)
            ;;

        *)
            kb_fail "refusing to remove unexpected KubeBase session path: $session_dir"
            ;;
    esac

    sessions_real="$(
        cd -- "$SESSIONS_DIR"
        pwd -P
    )"

    parent_real="$(
        cd -- "$session_parent"
        pwd -P
    )"

    [ "$parent_real" = "$sessions_real" ] || \
        kb_fail "refusing to remove session outside KubeBase session root: $session_dir"

    manifest="$session_dir/session.json"

    [ -f "$manifest" ] && [ ! -L "$manifest" ] || \
        kb_fail "refusing to remove unrecognized KubeBase session: $session_dir"

    jq -e \
        --arg schema "$SESSION_SCHEMA" \
        --argjson schemaVersion "$SESSION_SCHEMA_VERSION" \
        --arg workspace "$WORKSPACE_DIR" '
        .schema == $schema
        and
        .schemaVersion == $schemaVersion
        and
        .workspace == $workspace
    ' "$manifest" >/dev/null 2>&1 || \
        kb_fail "refusing to remove session with invalid metadata: $session_dir"

    rm -rf -- "$session_dir"
}


# ----------------------------------------------------------------------
# Visible commands
# ----------------------------------------------------------------------

command_profiles()
{
    local selector
    local context
    local status
    local marker
    local active_selector=""

    local profile_width
    local context_width
    local platform_width

    local profile_sep
    local context_sep
    local platform_sep

    local -a selectors=()
    local -a contexts=()
    local -a statuses=()
    local -a not_ready=()

    load_workspace

    if [ "${KUBEBASE_ACTIVE:-}" = "1" ] && \
       [ -n "${KUBEBASE_CLUSTER:-}" ] && \
       [ -n "${KUBEBASE_USER:-}" ]; then
        active_selector="$KUBEBASE_CLUSTER/$KUBEBASE_USER"
    fi

    profile_width=7
    context_width=7
    platform_width=8

    if [ "${#HOST_PLATFORM}" -gt "$platform_width" ]; then
        platform_width="${#HOST_PLATFORM}"
    fi

    while IFS= read -r selector; do
        [ -n "$selector" ] || continue

        if resolve_profile "$selector"; then
            context="$PROFILE_CONTEXT"
            status="READY"
        else
            context="-"
            status="NOT READY"
            not_ready+=("$selector: $PROFILE_ERROR")
        fi

        selectors+=("$selector")
        contexts+=("$context")
        statuses+=("$status")

        if [ "${#selector}" -gt "$profile_width" ]; then
            profile_width="${#selector}"
        fi

        if [ "${#context}" -gt "$context_width" ]; then
            context_width="${#context}"
        fi

    done < <(kb_configured_profile_selectors "${CLUSTER_FILES[@]}")

    printf -v profile_sep '%*s' "$profile_width" ''
    profile_sep="${profile_sep// /-}"

    printf -v context_sep '%*s' "$context_width" ''
    context_sep="${context_sep// /-}"

    printf -v platform_sep '%*s' "$platform_width" ''
    platform_sep="${platform_sep// /-}"

    echo "$PROJECT_NAME profiles"
    echo
    echo "Workspace : $WORKSPACE_DIR"
    echo "Platform  : $HOST_PLATFORM"
    echo

    printf '  %-*s  %-*s  %-*s  %s\n' \
        "$profile_width" "PROFILE" \
        "$context_width" "CONTEXT" \
        "$platform_width" "PLATFORM" \
        "STATUS"

    printf '  %s  %s  %s  %s\n' \
        "$profile_sep" \
        "$context_sep" \
        "$platform_sep" \
        "---------"

    local i

    for ((i = 0; i < ${#selectors[@]}; i++)); do
        marker=" "
        if [ -n "$active_selector" ] && [ "${selectors[$i]}" = "$active_selector" ]; then
            marker="*"
        fi

        printf '%s %-*s  %-*s  %-*s  %s\n' \
            "$marker" \
            "$profile_width" "${selectors[$i]}" \
            "$context_width" "${contexts[$i]}" \
            "$platform_width" "$HOST_PLATFORM" \
            "${statuses[$i]}"
    done

    if [ "${#not_ready[@]}" -gt 0 ]; then
        echo
        echo "Not ready:"

        for status in "${not_ready[@]}"; do
            echo "  $status"
        done
    fi
}

command_select_profile()
{
    local selector
    local answer
    local index
    local -a ready_profiles=()

    load_workspace

    while IFS= read -r selector; do
        [ -n "$selector" ] || continue

        if resolve_profile "$selector"; then
            ready_profiles+=("$selector")
        fi
    done < <(kb_configured_profile_selectors "${CLUSTER_FILES[@]}")

    if [ "${#ready_profiles[@]}" -eq 0 ]; then
        echo "ERROR: no ready KubeBase profiles are available" >&2
        return 1
    fi

    if [ ! -r /dev/tty ] || [ ! -w /dev/tty ]; then
        echo "ERROR: interactive profile selection requires a TTY" >&2
        echo "Use: kubebase use CLUSTER/USER" >&2
        return 1
    fi

    {
        echo "Available profiles:"
        echo

        index=1
        for selector in "${ready_profiles[@]}"; do
            printf '  %d. %s\n' "$index" "$selector"
            index=$((index + 1))
        done

        echo
        printf 'Select profile [1-%d]: ' "${#ready_profiles[@]}"
    } > /dev/tty

    IFS= read -r answer < /dev/tty

    [[ "$answer" =~ ^[0-9]+$ ]] || {
        echo "ERROR: invalid profile selection: $answer" >&2
        return 1
    }

    if [ "$answer" -lt 1 ] || [ "$answer" -gt "${#ready_profiles[@]}" ]; then
        echo "ERROR: profile selection is out of range: $answer" >&2
        return 1
    fi

    printf '%s\n' "${ready_profiles[$((answer - 1))]}"
}


command_emit_use()
{
    local selector="$1"

    load_workspace

    if ! resolve_profile "$selector"; then
        echo "ERROR: $PROFILE_ERROR" >&2
        return 1
    fi

    create_profile_session

    kb_shell_export "KUBEBASE_ACTIVE" "1"
    kb_shell_export "KUBEBASE_WORKSPACE" "$WORKSPACE_DIR"
    kb_shell_export "KUBEBASE_CLUSTER" "$PROFILE_CLUSTER_NAME"
    kb_shell_export "KUBEBASE_USER" "$PROFILE_USER_NAME"
    kb_shell_export "KUBEBASE_CONTEXT" "$PROFILE_CONTEXT"
    kb_shell_export "KUBEBASE_CONTEXT_SELECTION" "$PROFILE_CONTEXT_SELECTION"
    kb_shell_export "KUBEBASE_PLATFORM" "$HOST_PLATFORM"
    kb_shell_export "KUBEBASE_TOOLCHAIN" "$PROFILE_TOOLCHAIN_DIR"
    kb_shell_export "KUBEBASE_TOOLCHAIN_BIN" "$PROFILE_TOOLCHAIN_BIN"

    if [ -n "$PROFILE_KREW_ROOT" ]; then
        mkdir -p -- "$PROFILE_KREW_ROOT/bin"
        chmod 700 "$PROFILE_KREW_ROOT"
        kb_shell_export "KUBEBASE_KREW_ROOT" "$PROFILE_KREW_ROOT"
    else
        kb_shell_unset "KUBEBASE_KREW_ROOT"
    fi

    kb_shell_export "KUBEBASE_SOURCE_KUBECONFIG" "$PROFILE_SOURCE_KUBECONFIG"
    kb_shell_export "KUBEBASE_EFFECTIVE_KUBECONFIG" "$PROFILE_EFFECTIVE_KUBECONFIG"
    kb_shell_export "KUBEBASE_SESSION_DIR" "$PROFILE_SESSION_DIR"

    # Navigation starts clean for every newly activated profile.
    kb_shell_unset "KUBEBASE_GROUP"
    kb_shell_unset "KUBEBASE_NAMESPACE_GROUP"

    if [ -n "$PROFILE_CONTEXT_NAMESPACE" ]; then
        kb_shell_export "KUBEBASE_NAMESPACE" "$PROFILE_CONTEXT_NAMESPACE"
    else
        kb_shell_unset "KUBEBASE_NAMESPACE"
    fi

    kb_shell_export "KUBECONFIG" "$PROFILE_EFFECTIVE_KUBECONFIG"
}


command_current()
{
    local verbose="${1:-0}"
    local namespace=""
    local group_display="(none)"
    local kubectl_version="?"
    local resolved_kubectl=""
    local command_name
    local tool_name
    local version

    if [ "${KUBEBASE_ACTIVE:-}" != "1" ]; then
        echo "$PROJECT_NAME current"
        echo
        echo "Status : inactive"
        return 1
    fi

    if ! kb_verify_active_session_kubectl; then
        echo "ERROR: active KubeBase session failed integrity verification: $KB_ACTIVE_SESSION_ERROR" >&2
        return 1
    fi

    if [ -x "$KB_ACTIVE_KUBECTL_BIN" ] && \
       [ -f "${KUBEBASE_EFFECTIVE_KUBECONFIG:-}" ]; then

        namespace="$(
            "$KB_ACTIVE_KUBECTL_BIN" \
                --kubeconfig "$KUBEBASE_EFFECTIVE_KUBECONFIG" \
                config view \
                -o json 2>/dev/null |
            jq -r \
                --arg context "${KUBEBASE_CONTEXT:-}" '
                [
                    .contexts[]
                    | select(.name == $context)
                    | .context.namespace // ""
                ][0] // ""
            ' 2>/dev/null || true
        )"
    fi

    if [ -n "${KUBEBASE_GROUP:-}" ]; then
        group_display="$KUBEBASE_GROUP (filter)"
    elif [ -n "${KUBEBASE_NAMESPACE_GROUP:-}" ]; then
        group_display="$KUBEBASE_NAMESPACE_GROUP (namespace)"
    fi

    if [ -f "${KUBEBASE_TOOLCHAIN:-}/manifest.json" ]; then
        kubectl_version="$(
            jq -r '.commands.kubectl.version // "?"' \
                "${KUBEBASE_TOOLCHAIN}/manifest.json" 2>/dev/null || printf '?'
        )"
    fi

    echo "$PROJECT_NAME current"
    echo
    echo "Profile   : ${KUBEBASE_CLUSTER:-?}/${KUBEBASE_USER:-?}"
    echo "Context   : ${KUBEBASE_CONTEXT:-?}"
    echo "Group     : $group_display"

    if [ -n "$namespace" ]; then
        echo "Namespace : $namespace"
    else
        echo "Namespace : (default)"
    fi

    echo "Platform  : ${KUBEBASE_PLATFORM:-?}"
    echo "kubectl   : $kubectl_version"

    [ "$verbose" -ne 0 ] || return 0

    echo
    echo "Selection : ${KUBEBASE_CONTEXT_SELECTION:-?}"

    echo
    echo "Kubeconfig:"
    echo "  source    : ${KUBEBASE_SOURCE_KUBECONFIG:-?}"
    echo "  effective : ${KUBEBASE_EFFECTIVE_KUBECONFIG:-?}"

    echo
    echo "Toolchain:"

    if [ -f "${KUBEBASE_TOOLCHAIN:-}/manifest.json" ]; then
        while IFS=$'\t' read -r command_name tool_name version; do
            if [ "$command_name" = "$tool_name" ]; then
                printf '  %-12s : %s\n' "$command_name" "$version"
            else
                printf '  %-12s : %s (%s)\n' "$command_name" "$version" "$tool_name"
            fi
        done < <(
            jq -r '
                .commands
                | to_entries
                | sort_by(.key)
                | .[]
                | [ .key, .value.tool, .value.version ]
                | @tsv
            ' "${KUBEBASE_TOOLCHAIN}/manifest.json"
        )
    else
        echo "  manifest     : MISSING"
    fi

    resolved_kubectl="$(command -v kubectl 2>/dev/null || true)"

    echo
    if [ -n "$resolved_kubectl" ]; then
        echo "kubectl resolved: $resolved_kubectl"
    else
        echo "kubectl resolved: NOT FOUND"
    fi
}


command_shell_init()
{
    local shell_name="$1"

    [ "$shell_name" = "bash" ] || \
        kb_fail "unsupported shell '$shell_name'; KubeBase Linux integration currently supports bash only"

    load_workspace

    kb_shell_export "KUBEBASE_ENTRYPOINT" "$ENTRYPOINT"
    kb_shell_export "KUBEBASE_SHELL_WORKSPACE_NAME" "$WORKSPACE_NAME"
    kb_shell_export "KUBEBASE_SHELL_WORKSPACE_ROOT" "$WORKSPACE_ROOT"

    cat <<'EOF_SHELL'

kubebase()
{
    local __kb_command="${1:-help}"
    local __kb_selector
    local __kb_code
    local __kb_status
    local __kb_old_session
    local __kb_baseline_created=0

    case "$__kb_command" in
        use)
            shift || true

            if [ "$#" -eq 1 ] && { [ "$1" = "-h" ] || [ "$1" = "--help" ]; }; then
                echo "Usage: kubebase use [CLUSTER/USER]"
                return 0
            fi

            if [ "$#" -eq 0 ]; then
                __kb_selector="$(
                    "$KUBEBASE_ENTRYPOINT" \
                        __profile-select \
                        --workspace-name "$KUBEBASE_SHELL_WORKSPACE_NAME" \
                        --workspace-root "$KUBEBASE_SHELL_WORKSPACE_ROOT"
                )"
                __kb_status=$?

                if [ "$__kb_status" -ne 0 ]; then
                    return "$__kb_status"
                fi

            elif [ "$#" -eq 1 ]; then
                __kb_selector="$1"
                shift

            else
                echo "ERROR: usage: kubebase use [CLUSTER/USER]" >&2
                return 2
            fi

            if [ -z "${KUBEBASE_SHELL_BASELINE_SET+x}" ]; then
                export KUBEBASE_SHELL_BASELINE_SET=1
                export KUBEBASE_ORIGINAL_PATH="$PATH"

                if [ -n "${KUBECONFIG+x}" ]; then
                    export KUBEBASE_ORIGINAL_KUBECONFIG_SET=1
                    export KUBEBASE_ORIGINAL_KUBECONFIG="$KUBECONFIG"
                else
                    export KUBEBASE_ORIGINAL_KUBECONFIG_SET=0
                    unset KUBEBASE_ORIGINAL_KUBECONFIG
                fi

                if [ -n "${KREW_ROOT+x}" ]; then
                    export KUBEBASE_ORIGINAL_KREW_ROOT_SET=1
                    export KUBEBASE_ORIGINAL_KREW_ROOT="$KREW_ROOT"
                else
                    export KUBEBASE_ORIGINAL_KREW_ROOT_SET=0
                    unset KUBEBASE_ORIGINAL_KREW_ROOT
                fi

                __kb_baseline_created=1
            fi

            __kb_old_session="${KUBEBASE_SESSION_DIR:-}"

            __kb_code="$(
                "$KUBEBASE_ENTRYPOINT" \
                    __profile-use \
                    "$__kb_selector" \
                    --workspace-name "$KUBEBASE_SHELL_WORKSPACE_NAME" \
                    --workspace-root "$KUBEBASE_SHELL_WORKSPACE_ROOT"
            )"
            __kb_status=$?

            if [ "$__kb_status" -ne 0 ]; then
                if [ "$__kb_baseline_created" -ne 0 ] && \
                   [ "${KUBEBASE_ACTIVE:-}" != "1" ]; then
                    unset KUBEBASE_SHELL_BASELINE_SET
                    unset KUBEBASE_ORIGINAL_PATH
                    unset KUBEBASE_ORIGINAL_KUBECONFIG_SET
                    unset KUBEBASE_ORIGINAL_KUBECONFIG
                    unset KUBEBASE_ORIGINAL_KREW_ROOT_SET
                    unset KUBEBASE_ORIGINAL_KREW_ROOT
                fi

                return "$__kb_status"
            fi

            if ! eval "$__kb_code"; then
                echo "ERROR: failed to activate KubeBase profile environment" >&2
                return 1
            fi

            if [ -n "${KUBEBASE_KREW_ROOT:-}" ]; then
                export KREW_ROOT="$KUBEBASE_KREW_ROOT"
                export PATH="$KUBEBASE_TOOLCHAIN_BIN:$KUBEBASE_KREW_ROOT/bin:$KUBEBASE_ORIGINAL_PATH"
            else
                if [ "${KUBEBASE_ORIGINAL_KREW_ROOT_SET:-0}" = "1" ]; then
                    export KREW_ROOT="${KUBEBASE_ORIGINAL_KREW_ROOT:-}"
                else
                    unset KREW_ROOT
                fi
                export PATH="$KUBEBASE_TOOLCHAIN_BIN:$KUBEBASE_ORIGINAL_PATH"
            fi

            if [ -n "$__kb_old_session" ] && \
               [ "$__kb_old_session" != "$KUBEBASE_SESSION_DIR" ]; then
                if ! "$KUBEBASE_ENTRYPOINT" \
                    __profile-cleanup \
                    "$__kb_old_session" \
                    --workspace-name "$KUBEBASE_SHELL_WORKSPACE_NAME" \
                    --workspace-root "$KUBEBASE_SHELL_WORKSPACE_ROOT" \
                    >/dev/null
                then
                    echo "WARNING: previous KubeBase session could not be removed: $__kb_old_session" >&2
                fi
            fi

            echo "Activated $KUBEBASE_CLUSTER/$KUBEBASE_USER"
            echo "Context: $KUBEBASE_CONTEXT"
            ;;

        ns)
            shift || true

            if [ "$#" -eq 1 ] && { [ "$1" = "-h" ] || [ "$1" = "--help" ]; }; then
                echo "Usage: kubebase ns [NAME|--clear]"
                return 0
            fi

            if [ "$#" -gt 1 ]; then
                echo "ERROR: usage: kubebase ns [NAME|--clear]" >&2
                return 2
            fi

            __kb_code="$(
                "$KUBEBASE_ENTRYPOINT" \
                    __nav-ns \
                    "${1:-}"
            )"
            __kb_status=$?

            if [ "$__kb_status" -ne 0 ]; then
                return "$__kb_status"
            fi

            if ! eval "$__kb_code"; then
                echo "ERROR: failed to update KubeBase namespace navigation" >&2
                return 1
            fi

            echo "Namespace: ${KUBEBASE_NAMESPACE:-(default)}"
            ;;

        group)
            shift || true

            if [ "$#" -eq 1 ] && { [ "$1" = "-h" ] || [ "$1" = "--help" ]; }; then
                echo "Usage: kubebase group [GROUP|--clear]"
                return 0
            fi

            if [ "$#" -gt 1 ]; then
                echo "ERROR: usage: kubebase group [GROUP|--clear]" >&2
                return 2
            fi

            __kb_code="$(
                "$KUBEBASE_ENTRYPOINT" \
                    __nav-group \
                    "${1:-}"
            )"
            __kb_status=$?

            if [ "$__kb_status" -ne 0 ]; then
                return "$__kb_status"
            fi

            if ! eval "$__kb_code"; then
                echo "ERROR: failed to update KubeBase group navigation" >&2
                return 1
            fi

            if [ -n "${KUBEBASE_GROUP:-}" ]; then
                echo "Group: $KUBEBASE_GROUP"
            else
                echo "Group: (none)"
            fi
            echo "Namespace: ${KUBEBASE_NAMESPACE:-(default)}"
            ;;

        namespaces|groups)
            "$KUBEBASE_ENTRYPOINT" "$@"
            ;;

        shell)
            shift || true

            if [ "$#" -eq 2 ] && \
               [ "$1" = "init" ] && \
               [ "$2" = "bash" ]; then
                echo "KubeBase Bash integration is already active."
                return 0
            fi

            "$KUBEBASE_ENTRYPOINT" shell "$@"
            ;;

        off)
            shift || true

            if [ "$#" -eq 1 ] && { [ "$1" = "-h" ] || [ "$1" = "--help" ]; }; then
                echo "Usage: kubebase off"
                return 0
            fi

            if [ "$#" -ne 0 ]; then
                echo "ERROR: usage: kubebase off" >&2
                return 2
            fi

            if [ "${KUBEBASE_ACTIVE:-}" != "1" ]; then
                echo "KubeBase profile is already inactive."
                return 0
            fi

            __kb_old_session="${KUBEBASE_SESSION_DIR:-}"

            if [ -n "${KUBEBASE_ORIGINAL_PATH+x}" ]; then
                export PATH="$KUBEBASE_ORIGINAL_PATH"
            fi

            if [ "${KUBEBASE_ORIGINAL_KUBECONFIG_SET:-0}" = "1" ]; then
                export KUBECONFIG="${KUBEBASE_ORIGINAL_KUBECONFIG:-}"
            else
                unset KUBECONFIG
            fi

            if [ "${KUBEBASE_ORIGINAL_KREW_ROOT_SET:-0}" = "1" ]; then
                export KREW_ROOT="${KUBEBASE_ORIGINAL_KREW_ROOT:-}"
            else
                unset KREW_ROOT
            fi

            unset KUBEBASE_ACTIVE
            unset KUBEBASE_WORKSPACE
            unset KUBEBASE_CLUSTER
            unset KUBEBASE_USER
            unset KUBEBASE_CONTEXT
            unset KUBEBASE_CONTEXT_SELECTION
            unset KUBEBASE_PLATFORM
            unset KUBEBASE_TOOLCHAIN
            unset KUBEBASE_TOOLCHAIN_BIN
            unset KUBEBASE_KREW_ROOT
            unset KUBEBASE_SOURCE_KUBECONFIG
            unset KUBEBASE_EFFECTIVE_KUBECONFIG
            unset KUBEBASE_SESSION_DIR
            unset KUBEBASE_GROUP
            unset KUBEBASE_NAMESPACE
            unset KUBEBASE_NAMESPACE_GROUP

            if [ -n "$__kb_old_session" ]; then
                if ! "$KUBEBASE_ENTRYPOINT" \
                    __profile-cleanup \
                    "$__kb_old_session" \
                    --workspace-name "$KUBEBASE_SHELL_WORKSPACE_NAME" \
                    --workspace-root "$KUBEBASE_SHELL_WORKSPACE_ROOT" \
                    >/dev/null
                then
                    echo "WARNING: KubeBase session could not be removed: $__kb_old_session" >&2
                fi
            fi

            unset KUBEBASE_SHELL_BASELINE_SET
            unset KUBEBASE_ORIGINAL_PATH
            unset KUBEBASE_ORIGINAL_KUBECONFIG_SET
            unset KUBEBASE_ORIGINAL_KUBECONFIG
            unset KUBEBASE_ORIGINAL_KREW_ROOT_SET
            unset KUBEBASE_ORIGINAL_KREW_ROOT

            echo "KubeBase profile deactivated."
            ;;

        profiles)
            shift || true
            "$KUBEBASE_ENTRYPOINT" \
                profiles \
                --workspace-name "$KUBEBASE_SHELL_WORKSPACE_NAME" \
                --workspace-root "$KUBEBASE_SHELL_WORKSPACE_ROOT" \
                "$@"
            ;;

        *)
            "$KUBEBASE_ENTRYPOINT" "$@"
            ;;
    esac
}
EOF_SHELL
}


command_direct_use()
{
    echo "ERROR: 'use' must modify the current shell and requires KubeBase Bash integration." >&2
    echo >&2
    echo "Run once in the current shell:" >&2
    echo >&2
    echo "  eval \"\$(./kubebase.sh shell init bash)\"" >&2
    echo >&2
    echo "Then activate a profile with:" >&2
    echo >&2
    echo "  kubebase use" >&2
    echo "  kubebase use CLUSTER/USER" >&2
    return 2
}


command_direct_off()
{
    echo "ERROR: 'off' must modify the current shell and requires KubeBase Bash integration." >&2
    echo >&2
    echo "Run:" >&2
    echo >&2
    echo "  eval \"\$(./kubebase.sh shell init bash)\"" >&2
    return 2
}


# ----------------------------------------------------------------------
# Dispatch
# ----------------------------------------------------------------------

SUBCOMMAND="${1:-help}"

if [ "$#" -gt 0 ]; then
    shift
fi

case "$SUBCOMMAND" in
    profiles)
        parse_common_args "$@" || exit $?

        if [ "${#POSITIONAL_ARGS[@]}" -gt 0 ]; then
            if [ "${POSITIONAL_ARGS[0]}" = "--help" ]; then
                usage
                exit 0
            fi

            echo "ERROR: profiles takes no positional arguments" >&2
            exit 2
        fi

        command_profiles
        ;;

    shell-init)
        for arg in "$@"; do
            case "$arg" in
                -h|--help)
                    cat <<EOF_USAGE
Usage:
  kubebase shell init bash [--workspace-name NAME] [--workspace-root PATH]
EOF_USAGE
                    exit 0
                    ;;
            esac
        done

        parse_common_args "$@" || exit $?

        if [ "${#POSITIONAL_ARGS[@]}" -ne 1 ]; then
            echo "ERROR: usage: kubebase shell init bash [options]" >&2
            exit 2
        fi

        command_shell_init "${POSITIONAL_ARGS[0]}"
        ;;

    current)
        CURRENT_VERBOSE=0

        while [ "$#" -gt 0 ]; do
            case "$1" in
                --verbose)
                    CURRENT_VERBOSE=1
                    shift
                    ;;

                -h|--help)
                    cat <<EOF_USAGE
Usage:
  kubebase current [--verbose]
EOF_USAGE
                    exit 0
                    ;;

                *)
                    echo "ERROR: unknown current argument: $1" >&2
                    exit 2
                    ;;
            esac
        done

        command_current "$CURRENT_VERBOSE"
        ;;

    use-direct)
        command_direct_use
        ;;

    off-direct)
        command_direct_off
        ;;

    __profile-select)
        parse_common_args "$@" || exit $?

        [ "${#POSITIONAL_ARGS[@]}" -eq 0 ] || {
            echo "ERROR: internal profile selection takes no positional arguments" >&2
            exit 2
        }

        command_select_profile
        ;;

    __profile-use)
        parse_common_args "$@" || exit $?

        [ "${#POSITIONAL_ARGS[@]}" -eq 1 ] || {
            echo "ERROR: internal profile activation requires cluster/user" >&2
            exit 2
        }

        command_emit_use "${POSITIONAL_ARGS[0]}"
        ;;

    __profile-cleanup)
        parse_common_args "$@" || exit $?

        [ "${#POSITIONAL_ARGS[@]}" -eq 1 ] || {
            echo "ERROR: internal session cleanup requires a session path" >&2
            exit 2
        }

        load_workspace
        cleanup_profile_session "${POSITIONAL_ARGS[0]}"
        ;;

    help|-h|--help)
        usage
        ;;

    *)
        echo "ERROR: unknown profile command: $SUBCOMMAND" >&2
        echo >&2
        usage >&2
        exit 2
        ;;
esac
