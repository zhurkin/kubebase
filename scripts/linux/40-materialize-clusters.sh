#!/usr/bin/env bash

set -euo pipefail


# ----------------------------------------------------------------------
# KubeBase
# Step 40 - Cluster workspace materialization
# Linux
# ----------------------------------------------------------------------

PROJECT_NAME="KubeBase"

WORKSPACE_SCHEMA="kubebase.workspace"
WORKSPACE_SCHEMA_VERSION=1

CLUSTER_SCHEMA="kubebase.cluster"
CLUSTER_SCHEMA_VERSION=1

TOOL_INSTALL_SCHEMA="kubebase.toolInstall"
TOOL_INSTALL_SCHEMA_VERSION=1

TOOLCHAIN_SCHEMA="kubebase.clusterToolchain"
TOOLCHAIN_SCHEMA_VERSION=1

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

REPO_ROOT="$(
    cd -- "$SCRIPT_DIR/../.."
    pwd -P
)"

REPO_PARENT="$(dirname -- "$REPO_ROOT")"

DEFAULT_WORKSPACE_ROOT="$REPO_PARENT"

CONFIG_VALIDATOR="$SCRIPT_DIR/10-validate-config.sh"


# ----------------------------------------------------------------------
# Defaults
# ----------------------------------------------------------------------

WORKSPACE_NAME="$DEFAULT_WORKSPACE_NAME"
WORKSPACE_ROOT="$DEFAULT_WORKSPACE_ROOT"

CREATED_DIRS=0
EXISTING_DIRS=0

CREATED_LINKS=0
UPDATED_LINKS=0
EXISTING_LINKS=0

CLUSTER_COUNT=0
USER_COUNT=0

TOOLCHAIN_COUNT=0
TOOLCHAIN_SKIPPED=0
TOOLCHAIN_CREATED=0
TOOLCHAIN_UPDATED=0
TOOLCHAIN_EXISTING=0
TOOLCHAIN_COMMANDS=0


# ----------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------

usage()
{
    cat <<EOF
$PROJECT_NAME cluster materialization

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

  -h, --help
      Show this help.

Examples:
  $(basename "$0")

  $(basename "$0") \\
      --workspace-name my-workspace

  $(basename "$0") \\
      --workspace-root /srv/kubernetes
EOF
}


ensure_directory()
{
    local path="$1"

    if [ -L "$path" ]; then

        kb_fail \
            "expected directory but found symlink: $path"

    fi


    if [ -e "$path" ]; then

        if [ ! -d "$path" ]; then

            kb_fail \
                "expected directory but found another filesystem object: $path"

        fi

        EXISTING_DIRS=$((EXISTING_DIRS + 1))

        return 0

    fi


    mkdir -- "$path"

    CREATED_DIRS=$((CREATED_DIRS + 1))
}



ensure_cluster_link()
{
    local cluster_dir="$1"
    local config_file="$2"

    local config_basename
    local link_path
    local link_target
    local current_target
    local tmp_link


    config_basename="$(basename -- "$config_file")"

    link_path="$cluster_dir/cluster.json"

    # Always go through workspace/config.
    #
    # clusters/<name>/cluster.json
    #     -> ../../config/<original-file>.json
    #
    # This keeps the materialized cluster portable relative to
    # the workspace and preserves the external config directory
    # as the single source of truth.

    link_target="../../config/$config_basename"


    if [ -L "$link_path" ]; then

        current_target="$(
            readlink -- "$link_path"
        )"


        if [ "$current_target" = "$link_target" ]; then

            EXISTING_LINKS=$((EXISTING_LINKS + 1))

            return 0

        fi


        tmp_link="$cluster_dir/.cluster.json.tmp.$$"

        rm -f -- "$tmp_link"

        ln -s \
            -- "$link_target" \
            "$tmp_link"

        mv -Tf \
            -- "$tmp_link" \
            "$link_path"

        UPDATED_LINKS=$((UPDATED_LINKS + 1))

        return 0

    fi


    if [ -e "$link_path" ]; then

        kb_fail \
            "refusing to overwrite non-symlink cluster definition: $link_path"

    fi


    ln -s \
        -- "$link_target" \
        "$link_path"

    CREATED_LINKS=$((CREATED_LINKS + 1))
}


verify_installed_tool()
{
    local install_dir="$1"
    local requested_tool="$2"
    local requested_version="$3"
    local requested_platform="$4"

    local manifest="$install_dir/manifest.json"
    local binary_file
    local expected_sha256
    local actual_sha256


    VERIFIED_BINARY_FILE=""
    VERIFIED_BINARY_SHA256=""


    [ -f "$manifest" ] || \
        return 1


    if ! jq -e \
        --arg schema "$TOOL_INSTALL_SCHEMA" \
        --argjson schemaVersion "$TOOL_INSTALL_SCHEMA_VERSION" \
        --arg tool "$requested_tool" \
        --arg version "$requested_version" \
        --arg platform "$requested_platform" '

        .schema == $schema
        and
        .schemaVersion == $schemaVersion

        and

        .tool == $tool
        and
        .version == $version
        and
        .platform == $platform

        and

        (.binary | type) == "object"
        and
        (.binary.file | type) == "string"
        and
        (.binary.sha256 | type) == "string"

    ' "$manifest" >/dev/null 2>&1
    then

        return 1

    fi


    binary_file="$(
        jq -r '
            .binary.file
        ' "$manifest"
    )"

    expected_sha256="$(
        jq -r '
            .binary.sha256
        ' "$manifest"
    )"

    expected_sha256="${expected_sha256,,}"


    kb_safe_filename "$binary_file" || \
        return 1

    [[ "$expected_sha256" =~ ^[0-9a-f]{64}$ ]] || \
        return 1

    [ -f "$install_dir/$binary_file" ] || \
        return 1

    [ -x "$install_dir/$binary_file" ] || \
        return 1


    actual_sha256="$(
        sha256sum "$install_dir/$binary_file" |
        awk '{print $1}'
    )"

    actual_sha256="${actual_sha256,,}"


    [ "$actual_sha256" = "$expected_sha256" ] || \
        return 1


    VERIFIED_BINARY_FILE="$binary_file"
    VERIFIED_BINARY_SHA256="$expected_sha256"

    return 0
}


validate_existing_toolchain_manifest()
{
    local manifest="$1"
    local cluster_name="$2"
    local platform="$3"

    jq -e \
        --arg schema "$TOOLCHAIN_SCHEMA" \
        --argjson schemaVersion "$TOOLCHAIN_SCHEMA_VERSION" \
        --arg cluster "$cluster_name" \
        --arg platform "$platform" '

        .schema == $schema
        and
        .schemaVersion == $schemaVersion
        and
        .cluster == $cluster
        and
        .platform == $platform
        and
        (.commands | type) == "object"

    ' "$manifest" >/dev/null 2>&1
}


ensure_toolchain_link()
{
    local link_path="$1"
    local link_target="$2"

    local current_target
    local tmp_link


    TOOLCHAIN_LINK_CHANGED=0


    if [ -L "$link_path" ]; then

        current_target="$(readlink -- "$link_path")"

        if [ "$current_target" = "$link_target" ]; then

            EXISTING_LINKS=$((EXISTING_LINKS + 1))

            return 0
        fi


        tmp_link="$(dirname -- "$link_path")/.${link_path##*/}.tmp.$$"

        rm -f -- "$tmp_link"

        ln -s \
            -- "$link_target" \
            "$tmp_link"

        mv -Tf \
            -- "$tmp_link" \
            "$link_path"

        UPDATED_LINKS=$((UPDATED_LINKS + 1))
        TOOLCHAIN_LINK_CHANGED=1

        return 0
    fi


    if [ -e "$link_path" ]; then

        kb_fail \
            "refusing to overwrite non-symlink toolchain command: $link_path"

    fi


    ln -s \
        -- "$link_target" \
        "$link_path"

    CREATED_LINKS=$((CREATED_LINKS + 1))
    TOOLCHAIN_LINK_CHANGED=1
}


materialize_cluster_toolchain()
{
    local cluster_name="$1"
    local cluster_file="$2"
    local cluster_dir="$3"
    local platform="$4"

    local toolchains_dir="$cluster_dir/toolchains"
    local toolchain_dir="$toolchains_dir/$platform"
    local bin_dir="$toolchain_dir/bin"
    local manifest="$toolchain_dir/manifest.json"

    local toolchain_existed=0
    local toolchain_changed=0

    local tool_name
    local tool_version
    local command_name
    local install_dir
    local link_path
    local link_target

    local existing_path
    local existing_name

    local manifest_json
    local old_manifest_canonical=""
    local new_manifest_canonical
    local tmp_manifest

    local -a expected_order=()
    local -A expected_commands=()
    local -A expected_targets=()


    if ! jq -e \
        --arg platform "$platform" '
        .toolPlatforms | index($platform) != null
    ' "$cluster_file" >/dev/null 2>&1
    then

        TOOLCHAIN_SKIPPED=$((TOOLCHAIN_SKIPPED + 1))

        return 0
    fi


    TOOLCHAIN_COUNT=$((TOOLCHAIN_COUNT + 1))


    # ------------------------------------------------------------------
    # Preflight complete toolchain before touching cluster state.
    # ------------------------------------------------------------------

    manifest_json="$(
        jq -n \
            --arg schema "$TOOLCHAIN_SCHEMA" \
            --argjson schemaVersion "$TOOLCHAIN_SCHEMA_VERSION" \
            --arg cluster "$cluster_name" \
            --arg platform "$platform" '

            {
                schema: $schema,
                schemaVersion: $schemaVersion,
                cluster: $cluster,
                platform: $platform,
                commands: {}
            }

        '
    )"


    while IFS=$'\t' read -r tool_name tool_version; do

        [ -n "$tool_name" ] || continue


        command_name="$(
            kb_tool_command_name "$tool_name"
        )"

        kb_safe_filename "$command_name" || \
            kb_fail \
                "invalid toolchain command name '$command_name' for tool '$tool_name'"


        if [ -n "${expected_commands[$command_name]+x}" ]; then

            kb_fail \
                "cluster '$cluster_name' maps multiple tools to command '$command_name'"

        fi


        install_dir="$TOOLS_DIR/$platform/$tool_name/$tool_version"

        if ! verify_installed_tool \
            "$install_dir" \
            "$tool_name" \
            "$tool_version" \
            "$platform"
        then

            kb_fail \
                "cluster '$cluster_name' requires missing or corrupt installed tool: $tool_name $tool_version $platform; run: kubebase install"

        fi


        link_target="../../../../../tools/$platform/$tool_name/$tool_version/$VERIFIED_BINARY_FILE"

        expected_commands["$command_name"]=1
        expected_targets["$command_name"]="$link_target"
        expected_order+=("$command_name")


        manifest_json="$(
            jq \
                --arg command "$command_name" \
                --arg tool "$tool_name" \
                --arg version "$tool_version" \
                --arg binary "$VERIFIED_BINARY_FILE" \
                --arg sha256 "$VERIFIED_BINARY_SHA256" \
                --arg linkTarget "$link_target" '

                .commands[$command] = {
                    tool: $tool,
                    version: $version,
                    binary: $binary,
                    sha256: $sha256,
                    linkTarget: $linkTarget
                }

            ' <<< "$manifest_json"
        )"


        TOOLCHAIN_COMMANDS=$((TOOLCHAIN_COMMANDS + 1))

    done < <(
        jq -r '
            .tools
            | to_entries
            | sort_by(.key)
            | .[]
            | [
                .key,
                .value.version
              ]
            | @tsv
        ' "$cluster_file"
    )


    # ------------------------------------------------------------------
    # Existing managed state.
    # ------------------------------------------------------------------

    ensure_directory "$toolchains_dir"


    if [ -L "$toolchain_dir" ]; then

        kb_fail \
            "expected toolchain directory but found symlink: $toolchain_dir"

    fi


    if [ -e "$toolchain_dir" ]; then

        [ -d "$toolchain_dir" ] || \
            kb_fail \
                "expected toolchain directory but found another filesystem object: $toolchain_dir"

        [ -f "$manifest" ] || \
            kb_fail \
                "refusing to adopt unmanaged toolchain directory: $toolchain_dir"

        validate_existing_toolchain_manifest \
            "$manifest" \
            "$cluster_name" \
            "$platform" || \
            kb_fail \
                "invalid existing KubeBase toolchain manifest: $manifest"

        toolchain_existed=1
        EXISTING_DIRS=$((EXISTING_DIRS + 1))

        old_manifest_canonical="$(
            jq -S -c '.' "$manifest"
        )"

    else

        mkdir -- "$toolchain_dir"
        CREATED_DIRS=$((CREATED_DIRS + 1))

    fi


    ensure_directory "$bin_dir"


    # The bin directory is fully KubeBase-managed. Recoverable stale
    # symlinks are allowed, but user-owned filesystem objects are not.

    while IFS= read -r -d '' existing_path; do

        if [ ! -L "$existing_path" ]; then

            kb_fail \
                "unexpected non-symlink object in toolchain bin directory: $existing_path"

        fi

    done < <(
        find "$bin_dir" \
            -mindepth 1 \
            -maxdepth 1 \
            -print0
    )


    new_manifest_canonical="$(
        jq -S -c '.' <<< "$manifest_json"
    )"


    if [ "$toolchain_existed" -eq 0 ] ||
       [ "$old_manifest_canonical" != "$new_manifest_canonical" ]
    then
        toolchain_changed=1
    fi


    # Commit the desired manifest before reconciling symlinks. If the
    # process is interrupted, a later materialization can safely repair
    # missing or stale managed links from this manifest/config state.

    tmp_manifest="$toolchain_dir/.manifest.json.tmp.$$"

    printf '%s\n' "$manifest_json" \
        > "$tmp_manifest"

    chmod 644 \
        "$tmp_manifest"

    mv -f \
        -- "$tmp_manifest" \
        "$manifest"


    # ------------------------------------------------------------------
    # Reconcile expected commands.
    # ------------------------------------------------------------------

    for command_name in "${expected_order[@]}"; do

        link_path="$bin_dir/$command_name"
        link_target="${expected_targets[$command_name]}"


        ensure_toolchain_link \
            "$link_path" \
            "$link_target"

        if [ "$TOOLCHAIN_LINK_CHANGED" -ne 0 ]; then
            toolchain_changed=1
        fi


        [ -x "$link_path" ] || \
            kb_fail \
                "materialized toolchain command does not resolve to an executable: $link_path"

    done


    # Remove only stale symlinks from the KubeBase-managed bin directory.

    while IFS= read -r -d '' existing_path; do

        existing_name="$(basename -- "$existing_path")"

        if [ -n "${expected_commands[$existing_name]+x}" ]; then
            continue
        fi


        [ -L "$existing_path" ] || \
            kb_fail \
                "refusing to remove non-symlink toolchain object: $existing_path"

        rm -- "$existing_path"
        toolchain_changed=1

    done < <(
        find "$bin_dir" \
            -mindepth 1 \
            -maxdepth 1 \
            -print0
    )


    if [ "$toolchain_existed" -eq 0 ]; then

        TOOLCHAIN_CREATED=$((TOOLCHAIN_CREATED + 1))

    elif [ "$toolchain_changed" -ne 0 ]; then

        TOOLCHAIN_UPDATED=$((TOOLCHAIN_UPDATED + 1))

    else

        TOOLCHAIN_EXISTING=$((TOOLCHAIN_EXISTING + 1))

    fi
}


# ----------------------------------------------------------------------
# Arguments
# ----------------------------------------------------------------------

while [ "$#" -gt 0 ]; do

    case "$1" in

        --workspace-name)

            if [ "$#" -lt 2 ]; then
                echo "ERROR: --workspace-name requires a value" >&2
                exit 2
            fi

            WORKSPACE_NAME="$2"

            shift 2
            ;;


        --workspace-root)

            if [ "$#" -lt 2 ]; then
                echo "ERROR: --workspace-root requires a value" >&2
                exit 2
            fi

            WORKSPACE_ROOT="$2"

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
# Prerequisites
# ----------------------------------------------------------------------

command -v jq >/dev/null 2>&1 || \
    kb_fail "jq is required"

command -v sha256sum >/dev/null 2>&1 || \
    kb_fail "sha256sum is required"


[ -x "$CONFIG_VALIDATOR" ] || \
    kb_fail "configuration validator not found or not executable: $CONFIG_VALIDATOR"


# ----------------------------------------------------------------------
# Validate whole configuration before touching workspace
# ----------------------------------------------------------------------

"$CONFIG_VALIDATOR" \
    --workspace-name "$WORKSPACE_NAME" \
    --workspace-root "$WORKSPACE_ROOT" \
    --quiet


# ----------------------------------------------------------------------
# Workspace
# ----------------------------------------------------------------------

if [[ ! "$WORKSPACE_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then

    kb_fail \
        "invalid workspace name: $WORKSPACE_NAME"

fi


[ -d "$WORKSPACE_ROOT" ] || \
    kb_fail "workspace root not found: $WORKSPACE_ROOT"


WORKSPACE_ROOT="$(
    cd -- "$WORKSPACE_ROOT"
    pwd -P
)"

WORKSPACE_DIR="$WORKSPACE_ROOT/$WORKSPACE_NAME"
WORKSPACE_FILE="$WORKSPACE_DIR/workspace.json"


[ -d "$WORKSPACE_DIR" ] || \
    kb_fail "workspace not found: $WORKSPACE_DIR"


[ -f "$WORKSPACE_FILE" ] || \
    kb_fail "workspace configuration not found: $WORKSPACE_FILE"


# ----------------------------------------------------------------------
# Workspace structure
# ----------------------------------------------------------------------

CLUSTERS_DIR="$WORKSPACE_DIR/clusters"
TOOLS_DIR="$WORKSPACE_DIR/tools"
CONFIG_LINK="$WORKSPACE_DIR/config"

HOST_PLATFORM="$(
    kb_detect_host_platform "Linux materializer"
)"


if [ ! -d "$CLUSTERS_DIR" ]; then

    kb_fail \
        "workspace clusters directory not found: $CLUSTERS_DIR"

fi


if [ ! -d "$TOOLS_DIR" ]; then

    kb_fail \
        "workspace tools directory not found: $TOOLS_DIR; run: kubebase init"

fi


if [ ! -d "$CONFIG_LINK" ]; then

    kb_fail \
        "workspace config path not found: $CONFIG_LINK; run: kubebase init"

fi


# ----------------------------------------------------------------------
# Resolve configuration directory
# ----------------------------------------------------------------------

CONFIG_PATH="$(
    jq -r '
        .configuration.path
    ' "$WORKSPACE_FILE"
)"


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


# ----------------------------------------------------------------------
# Discover cluster documents
#
# File name has no semantic meaning.
# ----------------------------------------------------------------------

mapfile -d '' -t CONFIG_FILES < <(
    find "$CONFIG_DIR" \
        -maxdepth 1 \
        \( -type f -o -type l \) \
        -name '*.json' \
        -print0 |
    sort -z
)


# ----------------------------------------------------------------------
# Materialize clusters
# ----------------------------------------------------------------------

for CONFIG_FILE in "${CONFIG_FILES[@]}"; do

    if ! jq -e \
        --arg schema "$CLUSTER_SCHEMA" \
        --argjson version "$CLUSTER_SCHEMA_VERSION" '

        .schema == $schema
        and
        .schemaVersion == $version

    ' "$CONFIG_FILE" >/dev/null 2>&1
    then

        continue

    fi


    CLUSTER_NAME="$(
        jq -r '
            .name
        ' "$CONFIG_FILE"
    )"


    CLUSTER_COUNT=$((CLUSTER_COUNT + 1))


    CLUSTER_DIR="$CLUSTERS_DIR/$CLUSTER_NAME"
    USERS_DIR="$CLUSTER_DIR/users"
    ensure_directory "$CLUSTER_DIR"
    ensure_directory "$USERS_DIR"

    # ------------------------------------------------------------------
    # Link materialized cluster back to its source definition.
    # ------------------------------------------------------------------

    ensure_cluster_link \
        "$CLUSTER_DIR" \
        "$CONFIG_FILE"


    # ------------------------------------------------------------------
    # Cluster toolchain
    #
    # Materialize only the current host platform. The shared tools store
    # remains the single physical owner of binaries; the cluster exposes
    # the versions selected by its configuration through managed symlinks.
    # ------------------------------------------------------------------

    materialize_cluster_toolchain \
        "$CLUSTER_NAME" \
        "$CONFIG_FILE" \
        "$CLUSTER_DIR" \
        "$HOST_PLATFORM"


    # ------------------------------------------------------------------
    # Users
    #
    # KubeBase creates only the managed directory structure.
    #
    # It does NOT create:
    #   kubeconfig.yaml
    #   certificates
    #   credentials
    #
    # User-provided files are never overwritten here.
    # ------------------------------------------------------------------

    while IFS= read -r USER_NAME; do

        [ -n "$USER_NAME" ] || continue


        USER_COUNT=$((USER_COUNT + 1))


        USER_DIR="$USERS_DIR/$USER_NAME"
        USER_CERTS_DIR="$USER_DIR/certs"


        ensure_directory "$USER_DIR"
        ensure_directory "$USER_CERTS_DIR"

    done < <(
        jq -r '
            .users
            | keys[]
        ' "$CONFIG_FILE"
    )



done


# ----------------------------------------------------------------------
# Result
# ----------------------------------------------------------------------

echo "$PROJECT_NAME cluster materialization"

echo
echo "Repository : $REPO_ROOT"
echo "Workspace  : $WORKSPACE_DIR"
echo "Config dir : $CONFIG_DIR"
echo "Platform   : $HOST_PLATFORM"

echo
echo "Definitions:"
echo "  clusters : $CLUSTER_COUNT"
echo "  users    : $USER_COUNT"

echo
echo "Toolchains:"
echo "  materialized : $TOOLCHAIN_COUNT"
echo "  skipped      : $TOOLCHAIN_SKIPPED"
echo "  commands     : $TOOLCHAIN_COMMANDS"
echo "  created      : $TOOLCHAIN_CREATED"
echo "  updated      : $TOOLCHAIN_UPDATED"
echo "  existing     : $TOOLCHAIN_EXISTING"

echo
echo "Filesystem:"
echo "  created dirs   : $CREATED_DIRS"
echo "  existing dirs  : $EXISTING_DIRS"
echo "  created links  : $CREATED_LINKS"
echo "  updated links  : $UPDATED_LINKS"
echo "  existing links : $EXISTING_LINKS"

echo

if [ "$CLUSTER_COUNT" -eq 0 ]; then

    echo "No cluster definitions found."

else

    echo "Clusters:"

    while IFS= read -r CLUSTER_NAME; do

        [ -n "$CLUSTER_NAME" ] || continue

        printf '  %s\n' "$CLUSTER_NAME"

    done < <(

        for CONFIG_FILE in "${CONFIG_FILES[@]}"; do

            jq -r \
                --arg schema "$CLUSTER_SCHEMA" \
                --argjson version "$CLUSTER_SCHEMA_VERSION" '

                select(
                    .schema == $schema
                    and
                    .schemaVersion == $version
                )

                | .name

            ' "$CONFIG_FILE"

        done |
        sort

    )

fi


echo
echo "Materialization complete."
