#!/usr/bin/env bash

set -euo pipefail


# ----------------------------------------------------------------------
# KubeBase
# Step 10 - Configuration validation
# Linux
# ----------------------------------------------------------------------

PROJECT_NAME="KubeBase"

WORKSPACE_SCHEMA="kubebase.workspace"
WORKSPACE_SCHEMA_VERSION=1

CLUSTER_SCHEMA="kubebase.cluster"
CLUSTER_SCHEMA_VERSION=1

TOOL_SOURCES_SCHEMA="kubebase.toolSources"
TOOL_SOURCES_SCHEMA_VERSION=1

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

REPO_ROOT="$(
    cd -- "$SCRIPT_DIR/../.."
    pwd -P
)"

REPO_PARENT="$(dirname -- "$REPO_ROOT")"

DEFAULT_WORKSPACE_ROOT="$REPO_PARENT"


# ----------------------------------------------------------------------
# Defaults
# ----------------------------------------------------------------------

WORKSPACE_NAME="$DEFAULT_WORKSPACE_NAME"
WORKSPACE_ROOT="$DEFAULT_WORKSPACE_ROOT"

QUIET=0

VALIDATION_ERRORS=0
CONFIG_FILE_COUNT=0
CLUSTER_COUNT=0

declare -A CLUSTER_FILES=()
TOOL_SOURCE_FILES=()


# ----------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------

validation_error()
{
    echo "ERROR: $*" >&2
    VALIDATION_ERRORS=$((VALIDATION_ERRORS + 1))
}



usage()
{
    cat <<EOF
$PROJECT_NAME configuration validation

Usage:
  kubebase validate config [options]

Options:
  --workspace-name NAME
      Workspace directory name.

      Default:
        $DEFAULT_WORKSPACE_NAME

  --workspace-root PATH
      Parent directory containing workspace.

      Default:
        $DEFAULT_WORKSPACE_ROOT

  --quiet
      Suppress successful validation output.
      Errors are always printed.

  -h, --help
      Show this help.

Examples:
  kubebase validate config

  kubebase validate config --quiet

  kubebase validate config \\
      --workspace-name my-workspace

  kubebase validate config \\
      --workspace-root /srv/kubernetes
EOF
}


cluster_unsupported_fields()
{
    local file="$1"

    jq -r '
        [
            (
                (keys - ["name", "schema", "schemaVersion", "toolPlatforms", "tools", "users"])[]?
            ),
            (
                if (.tools | type) == "object" then
                    .tools
                    | to_entries[]?
                    | . as $tool
                    | (($tool.value | keys) - ["version"])[]?
                    | "tools.\($tool.key)." + .
                else
                    empty
                end
            ),
            (
                if (.users | type) == "object" then
                    .users
                    | to_entries[]?
                    | . as $user
                    | (($user.value | keys) - ["context", "kubeconfig"])[]?
                    | "users.\($user.key)." + .
                else
                    empty
                end
            )
        ]
        | join(", ")
    ' "$file"
}


validate_cluster_structure()
{
    local file="$1"

    jq -e \
        --arg schema "$CLUSTER_SCHEMA" \
        --argjson version "$CLUSTER_SCHEMA_VERSION" '

        def nonempty_string:
            type == "string"
            and length > 0;

        def safe_name:
            nonempty_string
            and test("^[A-Za-z0-9][A-Za-z0-9._-]*$");

        def safe_version:
            nonempty_string
            and test("^[A-Za-z0-9][A-Za-z0-9._+~-]*$")
            and . != "."
            and . != "..";

        def safe_relative_path:
            nonempty_string
            and (startswith("/") | not)
            and (test("[\n\r\t]") | not)
            and (
                split("/")
                | all(.[]; length > 0 and . != "." and . != "..")
            );

        .schema == $schema
        and
        .schemaVersion == $version

        and

        ((keys - ["name", "schema", "schemaVersion", "toolPlatforms", "tools", "users"]) | length == 0)

        and

        (.name | safe_name)

        and

        (.toolPlatforms | type) == "array"
        and
        all(.toolPlatforms[]; safe_name)
        and
        (
            (.toolPlatforms | length)
            ==
            (.toolPlatforms | unique | length)
        )

        and

        (.tools | type) == "object"
        and
        all(
            (.tools | to_entries[]);

            (.key | safe_name)
            and
            (.value | type) == "object"
            and
            (((.value | keys) - ["version"]) | length == 0)
            and
            (.value.version | safe_version)
        )

        and

        (.users | type) == "object"
        and
        all(
            (.users | to_entries[]);

            (.key | safe_name)
            and
            (.value | type) == "object"
            and
            (((.value | keys) - ["context", "kubeconfig"]) | length == 0)
            and
            (.value.kubeconfig | safe_relative_path)

            and

            (
                (.value | has("context") | not)
                or
                (.value.context | nonempty_string)
            )
        )

    ' "$file" >/dev/null 2>&1
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


        --quiet)

            QUIET=1
            shift
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


# ----------------------------------------------------------------------
# Workspace
# ----------------------------------------------------------------------

if [[ ! "$WORKSPACE_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    kb_fail "invalid workspace name: $WORKSPACE_NAME"
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


kb_require_readable_json_file \
    "$WORKSPACE_FILE" \
    "workspace configuration"


if ! jq -e \
    --arg schema "$WORKSPACE_SCHEMA" \
    --argjson version "$WORKSPACE_SCHEMA_VERSION" \
    --arg workspaceName "$WORKSPACE_NAME" '

    .schema == $schema
    and
    .schemaVersion == $version

    and

    (.workspace | type) == "object"
    and
    .workspace.name == $workspaceName

    and

    (.configuration | type) == "object"
    and
    (.configuration.path | type) == "string"
    and
    (.configuration.path | length > 0)

' "$WORKSPACE_FILE" >/dev/null 2>&1
then

    kb_fail \
        "unsupported or invalid workspace configuration: $WORKSPACE_FILE"

fi


# ----------------------------------------------------------------------
# Configuration directory
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
# Discover JSON configuration files
#
# File name has no semantic meaning.
# Document type is determined only by:
#
#   schema
#   schemaVersion
# ----------------------------------------------------------------------

mapfile -d '' -t CONFIG_FILES < <(
    find "$CONFIG_DIR" \
        -maxdepth 1 \
        \( -type f -o -type l \) \
        -name '*.json' \
        -print0 |
    sort -z
)


for CONFIG_FILE in "${CONFIG_FILES[@]}"; do

    CONFIG_FILE_COUNT=$((CONFIG_FILE_COUNT + 1))


    if [ ! -f "$CONFIG_FILE" ]; then

        validation_error \
            "$CONFIG_FILE: configuration entry is not a regular file"

        continue

    fi


    if [ ! -r "$CONFIG_FILE" ]; then

        validation_error \
            "$CONFIG_FILE: configuration file is not readable"

        continue

    fi


    # --------------------------------------------------------------
    # JSON syntax
    # --------------------------------------------------------------

    if ! jq empty "$CONFIG_FILE" >/dev/null 2>&1; then

        validation_error \
            "$CONFIG_FILE: invalid JSON"

        continue

    fi


    # --------------------------------------------------------------
    # Common schema envelope
    # --------------------------------------------------------------

    if ! jq -e '

        (.schema | type) == "string"
        and
        (.schema | length > 0)

        and

        (.schemaVersion | type) == "number"
        and
        (
            .schemaVersion
            ==
            (.schemaVersion | floor)
        )

    ' "$CONFIG_FILE" >/dev/null 2>&1
    then

        validation_error \
            "$CONFIG_FILE: invalid or missing schema/schemaVersion"

        continue

    fi


    CONFIG_SCHEMA="$(
        jq -r '
            .schema
        ' "$CONFIG_FILE"
    )"

    CONFIG_SCHEMA_VERSION="$(
        jq -r '
            .schemaVersion
        ' "$CONFIG_FILE"
    )"


    # --------------------------------------------------------------
    # Dispatch by document schema
    # --------------------------------------------------------------

    case "$CONFIG_SCHEMA" in

        "$CLUSTER_SCHEMA")

            if [ "$CONFIG_SCHEMA_VERSION" -ne "$CLUSTER_SCHEMA_VERSION" ]; then

                validation_error \
                    "$CONFIG_FILE: unsupported $CLUSTER_SCHEMA schemaVersion $CONFIG_SCHEMA_VERSION"

                continue

            fi


            UNSUPPORTED_FIELDS="$(cluster_unsupported_fields "$CONFIG_FILE")"

            if [ -n "$UNSUPPORTED_FIELDS" ]; then

                validation_error \
                    "$CONFIG_FILE: unsupported kubebase.cluster field(s): $UNSUPPORTED_FIELDS"

                continue

            fi


            if ! validate_cluster_structure "$CONFIG_FILE"; then

                validation_error \
                    "$CONFIG_FILE: invalid kubebase.cluster structure"

                continue

            fi


            CLUSTER_NAME="$(
                jq -r '
                    .name
                ' "$CONFIG_FILE"
            )"


            if [[ -n "${CLUSTER_FILES[$CLUSTER_NAME]+x}" ]]; then

                validation_error \
                    "duplicate cluster '$CLUSTER_NAME': ${CLUSTER_FILES[$CLUSTER_NAME]} and $CONFIG_FILE"

                continue

            fi


            CLUSTER_FILES["$CLUSTER_NAME"]="$CONFIG_FILE"
            CLUSTER_COUNT=$((CLUSTER_COUNT + 1))

            ;;


        "$TOOL_SOURCES_SCHEMA")

            if [ "$CONFIG_SCHEMA_VERSION" -ne "$TOOL_SOURCES_SCHEMA_VERSION" ]; then

                validation_error \
                    "$CONFIG_FILE: unsupported $TOOL_SOURCES_SCHEMA schemaVersion $CONFIG_SCHEMA_VERSION"

                continue

            fi


            TOOL_SOURCE_FILES+=("$CONFIG_FILE")
            ;;


        *)

            validation_error \
                "$CONFIG_FILE: unsupported configuration schema '$CONFIG_SCHEMA' version $CONFIG_SCHEMA_VERSION"
            ;;

    esac

done


# ----------------------------------------------------------------------
# Singleton schemas
# ----------------------------------------------------------------------

if [ "${#TOOL_SOURCE_FILES[@]}" -gt 1 ]; then

    echo "ERROR: multiple $TOOL_SOURCES_SCHEMA documents found:" >&2

    for CONFIG_FILE in "${TOOL_SOURCE_FILES[@]}"; do
        echo "  $CONFIG_FILE" >&2
    done

    VALIDATION_ERRORS=$((VALIDATION_ERRORS + 1))

fi


# ----------------------------------------------------------------------
# Result
# ----------------------------------------------------------------------

if [ "$VALIDATION_ERRORS" -ne 0 ]; then

    echo >&2
    echo \
        "Configuration validation FAILED: $VALIDATION_ERRORS error(s)." \
        >&2

    exit 1

fi


if [ "$QUIET" -eq 0 ]; then

    echo "$PROJECT_NAME configuration validation"
    echo
    echo "Repository : $REPO_ROOT"
    echo "Workspace  : $WORKSPACE_DIR"
    echo "Config dir : $CONFIG_DIR"

    echo
    echo "Documents:"
    echo "  JSON files   : $CONFIG_FILE_COUNT"
    echo "  clusters     : $CLUSTER_COUNT"
    echo "  toolSources  : ${#TOOL_SOURCE_FILES[@]}"


    if [ "$CLUSTER_COUNT" -gt 0 ]; then

        echo
        echo "Clusters:"

        while IFS= read -r CLUSTER_NAME; do

            [ -n "$CLUSTER_NAME" ] || continue

            printf '  %-24s %s\n' \
                "$CLUSTER_NAME" \
                "${CLUSTER_FILES[$CLUSTER_NAME]}"

        done < <(
            printf '%s\n' "${!CLUSTER_FILES[@]}" |
            sort
        )

    fi


    if [ "${#TOOL_SOURCE_FILES[@]}" -eq 1 ]; then

        echo
        echo "Tool source override:"
        echo "  ${TOOL_SOURCE_FILES[0]}"

    fi

    echo
    echo "Configuration valid."

fi
