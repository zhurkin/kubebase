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
PROFILE_SOURCE_KUBECONFIG=""
PROFILE_KUBECTL=""


# ----------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------

fail()
{
    echo "ERROR: $*" >&2
    exit 1
}


usage()
{
    cat <<EOF_USAGE
$PROJECT_NAME profile management

Usage:
  $(basename "$0") profiles [options]
  $(basename "$0") shell-init bash [options]
  $(basename "$0") current

Internal activation is normally reached through the Bash function emitted
by 'kubebase.sh shell-init bash'.

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


safe_name()
{
    local value="$1"

    [[ "$value" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]
}


safe_relative_path()
{
    local value="$1"
    local part
    local -a parts

    [ -n "$value" ] || return 1
    [[ "$value" != /* ]] || return 1

    case "$value" in
        *$'\n'*|*$'\r'*|*$'\t'*)
            return 1
            ;;
    esac

    IFS='/' read -r -a parts <<< "$value"

    for part in "${parts[@]}"; do
        [ -n "$part" ] || return 1
        [ "$part" != "." ] || return 1
        [ "$part" != ".." ] || return 1
    done

    return 0
}


file_permissions_are_private()
{
    local path="$1"
    local mode
    local mode_value

    mode="$(stat -Lc '%a' "$path")"

    [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1

    mode_value=$((8#$mode))

    (( (mode_value & 077) == 0 ))
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
            fail "unsupported host operating system for Linux profile manager: $(uname -s)"
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


command_name_for_tool()
{
    local tool="$1"

    case "$tool" in
        krew)
            printf 'kubectl-krew\n'
            ;;

        *)
            printf '%s\n' "$tool"
            ;;
    esac
}


set_profile_error()
{
    PROFILE_ERROR="$1"
    return 1
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
    command -v jq >/dev/null 2>&1 || fail "jq is required"
    command -v sha256sum >/dev/null 2>&1 || fail "sha256sum is required"
    command -v stat >/dev/null 2>&1 || fail "stat is required"
    command -v mktemp >/dev/null 2>&1 || fail "mktemp is required"

    [ -x "$CONFIG_VALIDATOR" ] || \
        fail "configuration validator not found: $CONFIG_VALIDATOR"

    safe_name "$WORKSPACE_NAME" || \
        fail "invalid workspace name: $WORKSPACE_NAME"

    [ -d "$WORKSPACE_ROOT" ] || \
        fail "workspace root not found: $WORKSPACE_ROOT"

    WORKSPACE_ROOT="$(
        cd -- "$WORKSPACE_ROOT"
        pwd -P
    )"

    WORKSPACE_DIR="$WORKSPACE_ROOT/$WORKSPACE_NAME"
    WORKSPACE_FILE="$WORKSPACE_DIR/workspace.json"
    CLUSTERS_DIR="$WORKSPACE_DIR/clusters"
    TOOLS_DIR="$WORKSPACE_DIR/tools"
    INTERNAL_DIR="$WORKSPACE_DIR/.kubebase"
    SESSIONS_DIR="$INTERNAL_DIR/sessions"

    [ -f "$WORKSPACE_FILE" ] || \
        fail "workspace configuration not found: $WORKSPACE_FILE"

    [ -d "$CLUSTERS_DIR" ] || \
        fail "cluster directory not found: $CLUSTERS_DIR"

    [ -d "$TOOLS_DIR" ] || \
        fail "tools directory not found: $TOOLS_DIR"

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
        fail "configuration directory not found: $CONFIG_DIR_CANDIDATE"

    CONFIG_DIR="$(
        cd -- "$CONFIG_DIR_CANDIDATE"
        pwd -P
    )"

    HOST_PLATFORM="$(detect_host_platform)"

    CONFIG_FILES=()
    CLUSTER_FILES=()

    mapfile -d '' -t CONFIG_FILES < <(
        find "$CONFIG_DIR" \
            -maxdepth 1 \
            \( -type f -o -type l \) \
            -name '*.json' \
            -print0 |
        sort -z
    )

    for CONFIG_FILE in "${CONFIG_FILES[@]}"; do
        CONFIG_SCHEMA="$(jq -r '.schema' "$CONFIG_FILE")"

        if [ "$CONFIG_SCHEMA" = "$CLUSTER_SCHEMA" ]; then
            CLUSTER_FILES+=("$CONFIG_FILE")
        fi
    done
}


find_cluster_file()
{
    local cluster_name="$1"
    local file
    local found=""

    for file in "${CLUSTER_FILES[@]}"; do
        if [ "$(jq -r '.name' "$file")" = "$cluster_name" ]; then
            if [ -n "$found" ]; then
                return 1
            fi

            found="$file"
        fi
    done

    [ -n "$found" ] || return 1

    printf '%s\n' "$found"
}


configured_profile_selectors()
{
    local cluster_file
    local cluster_name
    local user_name

    for cluster_file in "${CLUSTER_FILES[@]}"; do
        cluster_name="$(jq -r '.name' "$cluster_file")"

        while IFS= read -r user_name; do
            [ -n "$user_name" ] || continue
            printf '%s/%s\n' "$cluster_name" "$user_name"
        done < <(
            jq -r '.users | keys[]' "$cluster_file"
        )
    done
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
    local command_path
    local expected_target
    local actual_target
    local expected_sha256
    local actual_sha256
    local command_count
    local tool_count

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
       ! safe_name "$cluster_name" || \
       ! safe_name "$user_name"
    then
        set_profile_error "invalid profile selector: $selector"
        return 1
    fi

    if ! cluster_file="$(find_cluster_file "$cluster_name")"; then
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

    tool_count="$(jq -r '.tools | length' "$cluster_file")"
    command_count="$(jq -r '.commands | length' "$PROFILE_TOOLCHAIN_MANIFEST")"

    if [ "$tool_count" -ne "$command_count" ]; then
        set_profile_error "cluster '$cluster_name' toolchain command set does not match configuration"
        return 1
    fi

    while IFS=$'\t' read -r tool_name tool_version; do
        [ -n "$tool_name" ] || continue

        command_name="$(command_name_for_tool "$tool_name")"
        command_path="$PROFILE_TOOLCHAIN_BIN/$command_name"

        if ! jq -e \
            --arg command "$command_name" \
            --arg tool "$tool_name" \
            --arg version "$tool_version" '
            (.commands[$command] | type) == "object"
            and
            .commands[$command].tool == $tool
            and
            .commands[$command].version == $version
            and
            (.commands[$command].sha256 | type) == "string"
            and
            (.commands[$command].linkTarget | type) == "string"
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

        expected_target="$(
            jq -r \
                --arg command "$command_name" '
                .commands[$command].linkTarget
            ' "$PROFILE_TOOLCHAIN_MANIFEST"
        )"

        actual_target="$(readlink -- "$command_path")"

        if [ "$actual_target" != "$expected_target" ]; then
            set_profile_error "cluster '$cluster_name' toolchain symlink target changed: $command_name"
            return 1
        fi

        expected_sha256="$(
            jq -r \
                --arg command "$command_name" '
                .commands[$command].sha256
            ' "$PROFILE_TOOLCHAIN_MANIFEST"
        )"

        expected_sha256="${expected_sha256,,}"

        [[ "$expected_sha256" =~ ^[0-9a-f]{64}$ ]] || {
            set_profile_error "cluster '$cluster_name' toolchain has invalid SHA-256 metadata: $command_name"
            return 1
        }

        actual_sha256="$(
            sha256sum "$command_path" |
            awk '{print $1}'
        )"

        actual_sha256="${actual_sha256,,}"

        if [ "$actual_sha256" != "$expected_sha256" ]; then
            set_profile_error "cluster '$cluster_name' toolchain command failed SHA-256 verification: $command_name"
            return 1
        fi

    done < <(
        jq -r '
            .tools
            | to_entries
            | sort_by(.key)
            | .[]
            | [ .key, .value.version ]
            | @tsv
        ' "$cluster_file"
    )

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

    if ! safe_relative_path "$kubeconfig_rel"; then
        set_profile_error "cluster '$cluster_name' user '$user_name' has an unsafe kubeconfig path"
        return 1
    fi

    PROFILE_SOURCE_KUBECONFIG="$PROFILE_CLUSTER_DIR/users/$user_name/$kubeconfig_rel"

    [ -f "$PROFILE_SOURCE_KUBECONFIG" ] || {
        set_profile_error "cluster '$cluster_name' user '$user_name' kubeconfig is missing"
        return 1
    }

    if ! file_permissions_are_private "$PROFILE_SOURCE_KUBECONFIG"; then
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

    current_context="$(jq -r '."current-context" // ""' <<< "$kubeconfig_json")"

    declared_context="$(
        jq -r \
            --arg user "$user_name" '
            .users[$user].context // ""
        ' "$cluster_file"
    )"

    if [ -n "$declared_context" ]; then
        PROFILE_CONTEXT="$declared_context"
        PROFILE_CONTEXT_SELECTION="KubeBase user.context"
    else
        PROFILE_CONTEXT="$current_context"
        PROFILE_CONTEXT_SELECTION="kubeconfig current-context"
    fi

    [ -n "$PROFILE_CONTEXT" ] || {
        set_profile_error "cluster '$cluster_name' user '$user_name' has no selected context"
        return 1
    }

    selected_context_count="$(
        jq -r \
            --arg context "$PROFILE_CONTEXT" '
            [
                .contexts[]
                | select(.name == $context)
            ]
            | length
        ' <<< "$kubeconfig_json"
    )"

    if [ "$selected_context_count" -ne 1 ]; then
        set_profile_error "cluster '$cluster_name' user '$user_name' selected context '$PROFILE_CONTEXT' does not exist exactly once"
        return 1
    fi

    context_cluster="$(
        jq -r \
            --arg context "$PROFILE_CONTEXT" '
            .contexts[]
            | select(.name == $context)
            | .context.cluster // ""
        ' <<< "$kubeconfig_json"
    )"

    context_user="$(
        jq -r \
            --arg context "$PROFILE_CONTEXT" '
            .contexts[]
            | select(.name == $context)
            | .context.user // ""
        ' <<< "$kubeconfig_json"
    )"

    PROFILE_CONTEXT_NAMESPACE="$(
        jq -r \
            --arg context "$PROFILE_CONTEXT" '
            .contexts[]
            | select(.name == $context)
            | .context.namespace // ""
        ' <<< "$kubeconfig_json"
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
        fail "internal KubeBase state must not be a symlink: $INTERNAL_DIR"
    fi

    if [ -e "$INTERNAL_DIR" ] && [ ! -d "$INTERNAL_DIR" ]; then
        fail "internal KubeBase state is not a directory: $INTERNAL_DIR"
    fi

    if [ ! -d "$INTERNAL_DIR" ]; then
        mkdir -- "$INTERNAL_DIR"
    fi

    chmod 700 "$INTERNAL_DIR"

    if [ -L "$SESSIONS_DIR" ]; then
        fail "KubeBase sessions path must not be a symlink: $SESSIONS_DIR"
    fi

    if [ -e "$SESSIONS_DIR" ] && [ ! -d "$SESSIONS_DIR" ]; then
        fail "KubeBase sessions path is not a directory: $SESSIONS_DIR"
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
    local session_manifest
    local cleanup_needed=1

    ensure_session_root

    session_dir="$(mktemp -d "$SESSIONS_DIR/session.XXXXXX")"
    effective_kubeconfig="$session_dir/kubeconfig.yaml"
    temp_kubeconfig="$session_dir/.kubeconfig.yaml.tmp"
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
        -o yaml \
        > "$temp_kubeconfig"
    then
        echo "ERROR: failed to create flattened effective kubeconfig" >&2
        return 1
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
        --arg toolchain "$PROFILE_TOOLCHAIN_DIR" '
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
            toolchain: $toolchain
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
        fail "refusing to remove symlink as KubeBase session: $session_dir"

    [ -d "$session_dir" ] || \
        fail "KubeBase session is not a directory: $session_dir"

    ensure_session_root

    session_parent="$(dirname -- "$session_dir")"
    session_name="$(basename -- "$session_dir")"

    case "$session_name" in
        session.*)
            ;;

        *)
            fail "refusing to remove unexpected KubeBase session path: $session_dir"
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
        fail "refusing to remove session outside KubeBase session root: $session_dir"

    manifest="$session_dir/session.json"

    [ -f "$manifest" ] && [ ! -L "$manifest" ] || \
        fail "refusing to remove unrecognized KubeBase session: $session_dir"

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
        fail "refusing to remove session with invalid metadata: $session_dir"

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
    local -a not_ready=()

    load_workspace

    echo "$PROJECT_NAME profiles"
    echo
    echo "Workspace : $WORKSPACE_DIR"
    echo "Platform  : $HOST_PLATFORM"
    echo

    printf '%-36s %-28s %-14s %s\n' \
        "PROFILE" \
        "CONTEXT" \
        "PLATFORM" \
        "STATUS"

    printf '%-36s %-28s %-14s %s\n' \
        "------------------------------------" \
        "----------------------------" \
        "--------------" \
        "---------"

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

        printf '%-36s %-28s %-14s %s\n' \
            "$selector" \
            "$context" \
            "$HOST_PLATFORM" \
            "$status"

    done < <(configured_profile_selectors)

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
    done < <(configured_profile_selectors)

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

    shell_export "KUBEBASE_ACTIVE" "1"
    shell_export "KUBEBASE_WORKSPACE" "$WORKSPACE_DIR"
    shell_export "KUBEBASE_CLUSTER" "$PROFILE_CLUSTER_NAME"
    shell_export "KUBEBASE_USER" "$PROFILE_USER_NAME"
    shell_export "KUBEBASE_CONTEXT" "$PROFILE_CONTEXT"
    shell_export "KUBEBASE_CONTEXT_SELECTION" "$PROFILE_CONTEXT_SELECTION"
    shell_export "KUBEBASE_PLATFORM" "$HOST_PLATFORM"
    shell_export "KUBEBASE_TOOLCHAIN" "$PROFILE_TOOLCHAIN_DIR"
    shell_export "KUBEBASE_TOOLCHAIN_BIN" "$PROFILE_TOOLCHAIN_BIN"
    shell_export "KUBEBASE_SOURCE_KUBECONFIG" "$PROFILE_SOURCE_KUBECONFIG"
    shell_export "KUBEBASE_EFFECTIVE_KUBECONFIG" "$PROFILE_EFFECTIVE_KUBECONFIG"
    shell_export "KUBEBASE_SESSION_DIR" "$PROFILE_SESSION_DIR"

    # Navigation starts clean for every newly activated profile.
    shell_unset "KUBEBASE_SCOPE"
    shell_unset "KUBEBASE_GROUP"
    shell_unset "KUBEBASE_NAMESPACE_GROUP"

    # Compatibility cleanup for older Step 80 shells.
    shell_unset "KUBEBASE_PROJECT"
    shell_unset "KUBEBASE_NAMESPACE_PROJECT"

    if [ -n "$PROFILE_CONTEXT_NAMESPACE" ]; then
        shell_export "KUBEBASE_NAMESPACE" "$PROFILE_CONTEXT_NAMESPACE"
    else
        shell_unset "KUBEBASE_NAMESPACE"
    fi

    shell_export "KUBECONFIG" "$PROFILE_EFFECTIVE_KUBECONFIG"
}


command_current()
{
    local namespace=""
    local resolved_kubectl=""
    local command_name
    local tool_name
    local version

    if [ "${KUBEBASE_ACTIVE:-}" != "1" ]; then
        echo "$PROJECT_NAME current profile"
        echo
        echo "Status : inactive"
        return 1
    fi

    echo "$PROJECT_NAME current profile"
    echo
    echo "Cluster   : ${KUBEBASE_CLUSTER:-?}"
    echo "User      : ${KUBEBASE_USER:-?}"
    echo "Context   : ${KUBEBASE_CONTEXT:-?}"
    echo "Selection : ${KUBEBASE_CONTEXT_SELECTION:-?}"
    echo "Platform  : ${KUBEBASE_PLATFORM:-?}"

    if [ -x "${KUBEBASE_TOOLCHAIN_BIN:-}/kubectl" ] && \
       [ -f "${KUBEBASE_EFFECTIVE_KUBECONFIG:-}" ]; then

        namespace="$(
            "${KUBEBASE_TOOLCHAIN_BIN}/kubectl" \
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
        echo "Group     : $KUBEBASE_GROUP (filter)"
    elif [ -n "${KUBEBASE_NAMESPACE_GROUP:-}" ]; then
        echo "Group     : $KUBEBASE_NAMESPACE_GROUP (namespace)"
    elif [ -n "${KUBEBASE_PROJECT:-}" ]; then
        echo "Group     : $KUBEBASE_PROJECT (legacy filter)"
    elif [ -n "${KUBEBASE_NAMESPACE_PROJECT:-}" ]; then
        echo "Group     : $KUBEBASE_NAMESPACE_PROJECT (legacy namespace)"
    else
        echo "Group     : (none)"
    fi

    if [ -n "$namespace" ]; then
        echo "Namespace : $namespace"
    else
        echo "Namespace : (default)"
    fi

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
        fail "unsupported shell '$shell_name'; Step 70 currently supports bash only"

    load_workspace

    shell_export "KUBEBASE_ENTRYPOINT" "$ENTRYPOINT"
    shell_export "KUBEBASE_SHELL_WORKSPACE_NAME" "$WORKSPACE_NAME"
    shell_export "KUBEBASE_SHELL_WORKSPACE_ROOT" "$WORKSPACE_ROOT"

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
                fi

                return "$__kb_status"
            fi

            if ! eval "$__kb_code"; then
                echo "ERROR: failed to activate KubeBase profile environment" >&2
                return 1
            fi

            export PATH="$KUBEBASE_TOOLCHAIN_BIN:$KUBEBASE_ORIGINAL_PATH"

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

            "$KUBEBASE_ENTRYPOINT" current
            ;;

        ns)
            shift || true

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

            "$KUBEBASE_ENTRYPOINT" current
            ;;

        group|project)
            shift || true

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

            "$KUBEBASE_ENTRYPOINT" current
            ;;

        namespaces|groups|projects)
            "$KUBEBASE_ENTRYPOINT" "$@"
            ;;

        off)
            shift || true

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

            unset KUBEBASE_ACTIVE
            unset KUBEBASE_WORKSPACE
            unset KUBEBASE_CLUSTER
            unset KUBEBASE_USER
            unset KUBEBASE_CONTEXT
            unset KUBEBASE_CONTEXT_SELECTION
            unset KUBEBASE_PLATFORM
            unset KUBEBASE_TOOLCHAIN
            unset KUBEBASE_TOOLCHAIN_BIN
            unset KUBEBASE_SOURCE_KUBECONFIG
            unset KUBEBASE_EFFECTIVE_KUBECONFIG
            unset KUBEBASE_SESSION_DIR
            unset KUBEBASE_SCOPE
            unset KUBEBASE_GROUP
            unset KUBEBASE_NAMESPACE
            unset KUBEBASE_NAMESPACE_GROUP
            unset KUBEBASE_PROJECT
            unset KUBEBASE_NAMESPACE_PROJECT

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
    echo "  eval \"\$(./kubebase.sh shell-init bash)\"" >&2
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
    echo "  eval \"\$(./kubebase.sh shell-init bash)\"" >&2
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
        parse_common_args "$@" || exit $?

        if [ "${#POSITIONAL_ARGS[@]}" -eq 1 ] && \
           [ "${POSITIONAL_ARGS[0]}" = "--help" ]; then
            usage
            exit 0
        fi

        if [ "${#POSITIONAL_ARGS[@]}" -ne 1 ]; then
            echo "ERROR: usage: shell-init bash [options]" >&2
            exit 2
        fi

        command_shell_init "${POSITIONAL_ARGS[0]}"
        ;;

    current)
        [ "$#" -eq 0 ] || {
            echo "ERROR: current takes no arguments" >&2
            exit 2
        }

        command_current
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
