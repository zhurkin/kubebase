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
ENVIRONMENT_COUNT=0


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

        fail \
            "expected directory but found symlink: $path"

    fi


    if [ -e "$path" ]; then

        if [ ! -d "$path" ]; then

            fail \
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

        fail \
            "refusing to overwrite non-symlink cluster definition: $link_path"

    fi


    ln -s \
        -- "$link_target" \
        "$link_path"

    CREATED_LINKS=$((CREATED_LINKS + 1))
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
    fail "jq is required"


[ -x "$CONFIG_VALIDATOR" ] || \
    fail "configuration validator not found or not executable: $CONFIG_VALIDATOR"


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

    fail \
        "invalid workspace name: $WORKSPACE_NAME"

fi


[ -d "$WORKSPACE_ROOT" ] || \
    fail "workspace root not found: $WORKSPACE_ROOT"


WORKSPACE_ROOT="$(
    cd -- "$WORKSPACE_ROOT"
    pwd -P
)"

WORKSPACE_DIR="$WORKSPACE_ROOT/$WORKSPACE_NAME"
WORKSPACE_FILE="$WORKSPACE_DIR/workspace.json"


[ -d "$WORKSPACE_DIR" ] || \
    fail "workspace not found: $WORKSPACE_DIR"


[ -f "$WORKSPACE_FILE" ] || \
    fail "workspace configuration not found: $WORKSPACE_FILE"


# ----------------------------------------------------------------------
# Workspace structure
# ----------------------------------------------------------------------

CLUSTERS_DIR="$WORKSPACE_DIR/clusters"
CONFIG_LINK="$WORKSPACE_DIR/config"


if [ ! -d "$CLUSTERS_DIR" ]; then

    fail \
        "workspace clusters directory not found: $CLUSTERS_DIR"

fi


if [ ! -d "$CONFIG_LINK" ]; then

    fail \
        "workspace config path not found: $CONFIG_LINK; run KubeBase init"

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
    fail "configuration directory not found: $CONFIG_DIR_CANDIDATE"


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
    ENVIRONMENTS_DIR="$CLUSTER_DIR/environments"


    ensure_directory "$CLUSTER_DIR"
    ensure_directory "$USERS_DIR"
    ensure_directory "$ENVIRONMENTS_DIR"


    # ------------------------------------------------------------------
    # Link materialized cluster back to its source definition.
    # ------------------------------------------------------------------

    ensure_cluster_link \
        "$CLUSTER_DIR" \
        "$CONFIG_FILE"


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


    # ------------------------------------------------------------------
    # Environments
    # ------------------------------------------------------------------

    while IFS= read -r ENVIRONMENT_NAME; do

        [ -n "$ENVIRONMENT_NAME" ] || continue


        ENVIRONMENT_COUNT=$((ENVIRONMENT_COUNT + 1))


        ENVIRONMENT_DIR="$ENVIRONMENTS_DIR/$ENVIRONMENT_NAME"


        ensure_directory "$ENVIRONMENT_DIR"

    done < <(
        jq -r '
            .environments
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

echo
echo "Definitions:"
echo "  clusters     : $CLUSTER_COUNT"
echo "  users        : $USER_COUNT"
echo "  environments : $ENVIRONMENT_COUNT"

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
