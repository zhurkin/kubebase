#!/usr/bin/env bash

set -euo pipefail


# ----------------------------------------------------------------------
# KubeBase
# Step 00 - Workspace initialization
# Linux
# ----------------------------------------------------------------------

PROJECT_NAME="KubeBase"

WORKSPACE_SCHEMA="kubebase.workspace"
WORKSPACE_SCHEMA_VERSION=1

DEFAULT_WORKSPACE_CONFIG_NAME="workspace.default.json"
AUTO_WORKSPACE_CONFIG_NAME="workspace.json"
WORKSPACE_ENTRYPOINT_NAME="kubebase.sh"


# ----------------------------------------------------------------------
# Paths
# ----------------------------------------------------------------------

SCRIPT_DIR="$(
    cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
    pwd -P
)"

LIB_DIR="$SCRIPT_DIR/lib"
source "$LIB_DIR/common.sh"

REPO_ROOT="$(
    cd -- "$SCRIPT_DIR/../.."
    pwd -P
)"

REPO_PARENT="$(dirname -- "$REPO_ROOT")"

DEFAULT_WORKSPACE_ROOT="$REPO_PARENT"

DEFAULT_WORKSPACE_CONFIG="$REPO_ROOT/$DEFAULT_WORKSPACE_CONFIG_NAME"
AUTO_WORKSPACE_CONFIG="$REPO_PARENT/$AUTO_WORKSPACE_CONFIG_NAME"


# ----------------------------------------------------------------------
# Arguments / defaults
# ----------------------------------------------------------------------

WORKSPACE_ROOT="$DEFAULT_WORKSPACE_ROOT"

WORKSPACE_CONFIG_FILE=""
WORKSPACE_CONFIG_EXPLICIT=0

WORKSPACE_NAME_OVERRIDE=""


# ----------------------------------------------------------------------
# Help
# ----------------------------------------------------------------------

usage()
{
    cat <<EOF
$PROJECT_NAME workspace initialization

Usage:
  $(basename "$0") [options]

Options:
  --workspace-config PATH
      Use PATH as workspace configuration override.

      If omitted, KubeBase checks:

        $AUTO_WORKSPACE_CONFIG

      If that file does not exist, only the built-in
      workspace.default.json is used.

  --workspace-name NAME
      Override workspace name from configuration.

  --workspace-root PATH
      Parent directory where the workspace will be created.

      Default:
        $DEFAULT_WORKSPACE_ROOT

  -h, --help
      Show this help.

Examples:
  $(basename "$0")

  $(basename "$0") \\
      --workspace-name my-workspace

  $(basename "$0") \\
      --workspace-config /etc/kubebase/workspace.json

  $(basename "$0") \\
      --workspace-root /srv/kubernetes
EOF
}


# ----------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------

validate_workspace_envelope()
{
    local file="$1"

    jq -e \
        --arg schema "$WORKSPACE_SCHEMA" \
        --argjson version "$WORKSPACE_SCHEMA_VERSION" '
        .schema == $schema
        and
        .schemaVersion == $version
    ' "$file" >/dev/null 2>&1
}


validate_effective_workspace()
{
    local json="$1"

    jq -e \
        --arg schema "$WORKSPACE_SCHEMA" \
        --argjson version "$WORKSPACE_SCHEMA_VERSION" '
        .schema == $schema
        and
        .schemaVersion == $version

        and

        (.workspace | type) == "object"
        and
        (.workspace.name | type) == "string"
        and
        (.workspace.name | length > 0)

        and

        (.configuration | type) == "object"
        and
        (.configuration.path | type) == "string"
        and
        (.configuration.path | length > 0)
    ' >/dev/null 2>&1 <<< "$json"
}


workspace_entrypoint_target()
{
    local workspace_dir="$1"

    local workspace_parent
    local repo_parent
    local repo_name

    workspace_parent="$(dirname -- "$workspace_dir")"
    repo_parent="$(dirname -- "$REPO_ROOT")"
    repo_name="$(basename -- "$REPO_ROOT")"

    # Prefer a relative sibling link for the normal portable layout.
    # For an explicitly relocated workspace root, fall back to an
    # absolute repository entrypoint. Re-running init repairs the link.

    if [ "$workspace_parent" = "$repo_parent" ]; then

        printf '../%s/%s\n' \
            "$repo_name" \
            "$WORKSPACE_ENTRYPOINT_NAME"

    else

        printf '%s/%s\n' \
            "$REPO_ROOT" \
            "$WORKSPACE_ENTRYPOINT_NAME"

    fi
}


ensure_workspace_entrypoint()
{
    local workspace_dir="$1"

    local link_path
    local link_target
    local current_target
    local tmp_link

    link_path="$workspace_dir/$WORKSPACE_ENTRYPOINT_NAME"
    link_target="$(workspace_entrypoint_target "$workspace_dir")"


    if [ -L "$link_path" ]; then

        current_target="$(readlink -- "$link_path")"

        if [ "$current_target" = "$link_target" ]; then

            WORKSPACE_ENTRYPOINT_STATUS="existing"
            WORKSPACE_ENTRYPOINT_TARGET="$link_target"

            return 0
        fi


        tmp_link="$workspace_dir/.${WORKSPACE_ENTRYPOINT_NAME}.tmp.$$"

        rm -f -- "$tmp_link"

        ln -s \
            -- "$link_target" \
            "$tmp_link"

        mv -Tf \
            -- "$tmp_link" \
            "$link_path"

        WORKSPACE_ENTRYPOINT_STATUS="updated"
        WORKSPACE_ENTRYPOINT_TARGET="$link_target"

        return 0
    fi


    if [ -e "$link_path" ]; then

        kb_fail \
            "refusing to overwrite non-symlink workspace entrypoint: $link_path"

    fi


    ln -s \
        -- "$link_target" \
        "$link_path"

    WORKSPACE_ENTRYPOINT_STATUS="created"
    WORKSPACE_ENTRYPOINT_TARGET="$link_target"
}


# ----------------------------------------------------------------------
# Arguments
# ----------------------------------------------------------------------

while [ "$#" -gt 0 ]; do
    case "$1" in

        --workspace-config)

            if [ "$#" -lt 2 ]; then
                echo "ERROR: --workspace-config requires a value" >&2
                exit 2
            fi

            WORKSPACE_CONFIG_FILE="$2"
            WORKSPACE_CONFIG_EXPLICIT=1

            shift 2
            ;;


        --workspace-name)

            if [ "$#" -lt 2 ]; then
                echo "ERROR: --workspace-name requires a value" >&2
                exit 2
            fi

            WORKSPACE_NAME_OVERRIDE="$2"

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

if ! command -v jq >/dev/null 2>&1; then

    cat >&2 <<EOF
ERROR: jq is required to process KubeBase workspace configuration.

Install jq and run this command again.

Example on Debian/Ubuntu:
  apt install jq
EOF

    exit 1

fi


[ -f "$REPO_ROOT/$WORKSPACE_ENTRYPOINT_NAME" ] || \
    kb_fail \
        "repository entrypoint not found: $REPO_ROOT/$WORKSPACE_ENTRYPOINT_NAME"


# ----------------------------------------------------------------------
# Default workspace configuration
# ----------------------------------------------------------------------

if [ ! -f "$DEFAULT_WORKSPACE_CONFIG" ]; then

    kb_fail \
        "default workspace configuration not found: $DEFAULT_WORKSPACE_CONFIG"

fi


if ! jq empty "$DEFAULT_WORKSPACE_CONFIG" >/dev/null 2>&1; then

    kb_fail \
        "invalid JSON: $DEFAULT_WORKSPACE_CONFIG"

fi


if ! validate_workspace_envelope "$DEFAULT_WORKSPACE_CONFIG"; then

    kb_fail \
        "invalid workspace schema: $DEFAULT_WORKSPACE_CONFIG"

fi


# ----------------------------------------------------------------------
# Optional workspace override
#
# Priority:
#
#   1. --workspace-config PATH
#   2. workspace.json beside repository
#   3. built-in workspace.default.json only
# ----------------------------------------------------------------------

if [ "$WORKSPACE_CONFIG_EXPLICIT" -eq 1 ]; then

    if [ ! -f "$WORKSPACE_CONFIG_FILE" ]; then

        kb_fail \
            "workspace configuration override not found: $WORKSPACE_CONFIG_FILE"

    fi

    WORKSPACE_CONFIG_FILE="$(
        kb_canonical_file "$WORKSPACE_CONFIG_FILE"
    )"


elif [ -f "$AUTO_WORKSPACE_CONFIG" ]; then

    WORKSPACE_CONFIG_FILE="$(
        kb_canonical_file "$AUTO_WORKSPACE_CONFIG"
    )"


else

    WORKSPACE_CONFIG_FILE=""

fi


# ----------------------------------------------------------------------
# Load / merge workspace configuration
# ----------------------------------------------------------------------

if [ -n "$WORKSPACE_CONFIG_FILE" ]; then

    if ! jq empty "$WORKSPACE_CONFIG_FILE" >/dev/null 2>&1; then

        kb_fail \
            "invalid JSON: $WORKSPACE_CONFIG_FILE"

    fi


    if ! validate_workspace_envelope "$WORKSPACE_CONFIG_FILE"; then

        kb_fail \
            "invalid workspace schema: $WORKSPACE_CONFIG_FILE"

    fi


    EFFECTIVE_WORKSPACE="$(
        jq -s '
            .[0] * .[1]
        ' \
        "$DEFAULT_WORKSPACE_CONFIG" \
        "$WORKSPACE_CONFIG_FILE"
    )"

else

    EFFECTIVE_WORKSPACE="$(
        jq '.' "$DEFAULT_WORKSPACE_CONFIG"
    )"

fi


# ----------------------------------------------------------------------
# CLI workspace name has highest priority
# ----------------------------------------------------------------------

if [ -n "$WORKSPACE_NAME_OVERRIDE" ]; then

    if [[ ! "$WORKSPACE_NAME_OVERRIDE" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then

        kb_fail \
            "invalid workspace name: $WORKSPACE_NAME_OVERRIDE"

    fi


    EFFECTIVE_WORKSPACE="$(
        jq \
            --arg name "$WORKSPACE_NAME_OVERRIDE" '
            .workspace.name = $name
        ' <<< "$EFFECTIVE_WORKSPACE"
    )"

fi


# ----------------------------------------------------------------------
# Validate effective workspace configuration
# ----------------------------------------------------------------------

if ! validate_effective_workspace "$EFFECTIVE_WORKSPACE"; then

    kb_fail \
        "effective workspace configuration is invalid"

fi


WORKSPACE_NAME="$(
    jq -r '
        .workspace.name
    ' <<< "$EFFECTIVE_WORKSPACE"
)"


if [[ ! "$WORKSPACE_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then

    kb_fail \
        "invalid workspace name: $WORKSPACE_NAME"

fi


# ----------------------------------------------------------------------
# Workspace path
# ----------------------------------------------------------------------

mkdir -p -- "$WORKSPACE_ROOT"

WORKSPACE_ROOT="$(
    cd -- "$WORKSPACE_ROOT"
    pwd -P
)"

WORKSPACE_DIR="$WORKSPACE_ROOT/$WORKSPACE_NAME"
WORKSPACE_FILE="$WORKSPACE_DIR/workspace.json"

mkdir -p -- "$WORKSPACE_DIR"


# ----------------------------------------------------------------------
# Existing workspace
#
# Never overwrite workspace.json.
# ----------------------------------------------------------------------

if [ -e "$WORKSPACE_FILE" ] || [ -L "$WORKSPACE_FILE" ]; then

    kb_require_readable_json_file \
        "$WORKSPACE_FILE" \
        "existing workspace configuration"


    EXISTING_WORKSPACE="$(
        jq '.' "$WORKSPACE_FILE"
    )"


    if ! validate_effective_workspace "$EXISTING_WORKSPACE"; then

        kb_fail \
            "unsupported existing workspace configuration: $WORKSPACE_FILE"

    fi


    EXISTING_NAME="$(
        jq -r '
            .workspace.name
        ' <<< "$EXISTING_WORKSPACE"
    )"


    if [ "$EXISTING_NAME" != "$WORKSPACE_NAME" ]; then

        kb_fail \
            "existing workspace name does not match requested workspace"

    fi


    EFFECTIVE_WORKSPACE="$EXISTING_WORKSPACE"
    WORKSPACE_CREATED=0

else

    TMP_WORKSPACE_FILE="$WORKSPACE_DIR/.workspace.json.tmp.$$"

    printf '%s\n' "$EFFECTIVE_WORKSPACE" \
        > "$TMP_WORKSPACE_FILE"

    # workspace.json contains routing/configuration metadata, not credentials.
    # Keep it readable even when the workspace was initialized by another
    # administrative user; sensitive kubeconfigs remain mode 600 elsewhere.
    chmod 644 "$TMP_WORKSPACE_FILE"

    mv \
        "$TMP_WORKSPACE_FILE" \
        "$WORKSPACE_FILE"

    WORKSPACE_CREATED=1

fi


# ----------------------------------------------------------------------
# Resolve configuration directory
#
# Relative configuration.path is resolved from workspace root.
# ----------------------------------------------------------------------

CONFIG_PATH="$(
    jq -r '
        .configuration.path
    ' <<< "$EFFECTIVE_WORKSPACE"
)"


if [[ "$CONFIG_PATH" = /* ]]; then

    CONFIG_DIR_CANDIDATE="$CONFIG_PATH"

else

    CONFIG_DIR_CANDIDATE="$WORKSPACE_DIR/$CONFIG_PATH"

fi


mkdir -p -- "$CONFIG_DIR_CANDIDATE"

CONFIG_DIR="$(
    cd -- "$CONFIG_DIR_CANDIDATE"
    pwd -P
)"


# ----------------------------------------------------------------------
# Standard workspace directories
# ----------------------------------------------------------------------

mkdir -p \
    "$WORKSPACE_DIR/artifacts" \
    "$WORKSPACE_DIR/tools" \
    "$WORKSPACE_DIR/clusters"


# ----------------------------------------------------------------------
# config symlink
#
# workspace/config -> configured external directory
# ----------------------------------------------------------------------

CONFIG_LINK="$WORKSPACE_DIR/config"


if [ "$CONFIG_DIR" != "$WORKSPACE_DIR/config" ]; then

    if [ -L "$CONFIG_LINK" ]; then

        CURRENT_LINK_TARGET="$(
            readlink -f "$CONFIG_LINK" 2>/dev/null || true
        )"


        if [ "$CURRENT_LINK_TARGET" != "$CONFIG_DIR" ]; then

            kb_fail \
                "existing config symlink points to another directory: $CONFIG_LINK"

        fi


    elif [ -e "$CONFIG_LINK" ]; then

        kb_fail \
            "workspace path is reserved for config symlink: $CONFIG_LINK"


    else

        ln -s \
            "$CONFIG_PATH" \
            "$CONFIG_LINK"

    fi

fi


# ----------------------------------------------------------------------
# Workspace entrypoint
#
# workspace/kubebase.sh -> repository/kubebase.sh
# ----------------------------------------------------------------------

WORKSPACE_ENTRYPOINT_STATUS=""
WORKSPACE_ENTRYPOINT_TARGET=""

ensure_workspace_entrypoint \
    "$WORKSPACE_DIR"


# ----------------------------------------------------------------------
# Result
# ----------------------------------------------------------------------

echo "$PROJECT_NAME workspace initialization"
echo
echo "Repository : $REPO_ROOT"
echo "Workspace  : $WORKSPACE_DIR"

echo
echo "Workspace configuration:"
echo "  default  : $DEFAULT_WORKSPACE_CONFIG"

if [ -n "$WORKSPACE_CONFIG_FILE" ]; then
    echo "  override : $WORKSPACE_CONFIG_FILE"
else
    echo "  override : none"
fi

echo
echo "Configuration:"
echo "  path     : $CONFIG_DIR"

if [ "$CONFIG_DIR" != "$WORKSPACE_DIR/config" ]; then
    echo "  link     : $CONFIG_LINK -> $CONFIG_PATH"
fi

echo

if [ "$WORKSPACE_CREATED" -eq 1 ]; then
    echo "Created: $WORKSPACE_FILE"
else
    echo "Exists : $WORKSPACE_FILE"
fi

echo
echo "Entrypoint:"
echo "  link     : $WORKSPACE_DIR/$WORKSPACE_ENTRYPOINT_NAME"
echo "  target   : $WORKSPACE_ENTRYPOINT_TARGET"
echo "  status   : $WORKSPACE_ENTRYPOINT_STATUS"

echo
echo "Directories:"
echo "  artifacts : $WORKSPACE_DIR/artifacts"
echo "  tools     : $WORKSPACE_DIR/tools"
echo "  clusters  : $WORKSPACE_DIR/clusters"

echo
echo "Initialization complete."
