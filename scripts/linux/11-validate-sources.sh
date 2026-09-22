#!/usr/bin/env bash

set -euo pipefail


# ----------------------------------------------------------------------
# KubeBase
# Step 11 - Tool source validation
# Linux
#
# Validates:
#
#   - tool source configuration
#   - optional tool source override
#   - source/platform definitions
#   - all tool requirements declared by kubebase.cluster documents
#   - source reachability unless --offline is used
#
# A cluster requirement is:
#
#   tool + version + toolPlatform
#
# Multiple clusters may require the same tuple. It is validated once as
# an artifact requirement, but all cluster bindings are checked.
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

DEFAULT_SOURCES_FILE="$REPO_ROOT/tool-sources.default.json"

CONFIG_VALIDATOR="$SCRIPT_DIR/10-validate-config.sh"


# ----------------------------------------------------------------------
# Defaults
# ----------------------------------------------------------------------

WORKSPACE_NAME="$DEFAULT_WORKSPACE_NAME"
WORKSPACE_ROOT="$DEFAULT_WORKSPACE_ROOT"

TOOL_SOURCES_FILE=""
TOOL_SOURCES_EXPLICIT=0

PLATFORM_FILTER=""

OFFLINE=0

VALIDATION_ERRORS=0


# ----------------------------------------------------------------------
# Collected state
# ----------------------------------------------------------------------

CONFIG_FILES=()
CLUSTER_FILES=()
TOOL_SOURCE_FILES=()

SOURCE_NAMES=()

declare -A REQUIREMENTS=()
declare -A REQUIREMENT_CLUSTERS=()

REQUIREMENT_BINDINGS=0
UNIQUE_REQUIREMENTS=0


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
$PROJECT_NAME tool source validation

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

  --tool-sources PATH
      Temporarily use PATH instead of an automatically
      discovered kubebase.toolSources configuration.

  --platform PLATFORM
      Validate only cluster requirements for this tool platform.

      Example:
        linux-amd64
        windows-amd64

      If omitted, requirements for all toolPlatforms declared by all
      clusters are validated.

  --offline
      Validate configuration and cluster requirements only.
      Skip network reachability checks.

  -h, --help
      Show this help.

Examples:
  $(basename "$0") --offline

  $(basename "$0")

  $(basename "$0") --platform windows-amd64 --offline

  $(basename "$0") \\
      --tool-sources /etc/kubebase/sources.json \\
      --offline
EOF
}


# ----------------------------------------------------------------------
# Authentication validation
# ----------------------------------------------------------------------

auth_is_valid()
{
    local auth_json="$1"

    jq -e '

        def nonempty:
            type == "string"
            and length > 0;

        def only_keys($allowed):
            (
                (keys_unsorted - $allowed)
                | length
            ) == 0;

        def exactly_one_present($object; $names):
            (
                [
                    $names[] as $name
                    |
                    select(
                        $object
                        | has($name)
                    )
                ]
                | length
            ) == 1;


        . as $auth

        |

        if ($auth | type) != "object" then

            false


        elif $auth.type == "none" then

            (
                $auth
                | only_keys([
                    "type"
                ])
            )


        elif $auth.type == "basic" then

            (
                $auth
                |
                only_keys([
                    "type",
                    "username",
                    "password",
                    "passwordEnv",
                    "passwordFile"
                ])
            )

            and

            ($auth.username | nonempty)

            and

            exactly_one_present(
                $auth;
                [
                    "password",
                    "passwordEnv",
                    "passwordFile"
                ]
            )

            and

            (
                if ($auth | has("password")) then

                    ($auth.password | nonempty)

                elif ($auth | has("passwordEnv")) then

                    ($auth.passwordEnv | nonempty)

                else

                    ($auth.passwordFile | nonempty)

                end
            )


        elif $auth.type == "bearer" then

            (
                $auth
                |
                only_keys([
                    "type",
                    "token",
                    "tokenEnv",
                    "tokenFile"
                ])
            )

            and

            exactly_one_present(
                $auth;
                [
                    "token",
                    "tokenEnv",
                    "tokenFile"
                ]
            )

            and

            (
                if ($auth | has("token")) then

                    ($auth.token | nonempty)

                elif ($auth | has("tokenEnv")) then

                    ($auth.tokenEnv | nonempty)

                else

                    ($auth.tokenFile | nonempty)

                end
            )


        elif $auth.type == "header" then

            (
                $auth
                |
                only_keys([
                    "type",
                    "name",
                    "value",
                    "valueEnv",
                    "valueFile"
                ])
            )

            and

            ($auth.name | nonempty)

            and

            exactly_one_present(
                $auth;
                [
                    "value",
                    "valueEnv",
                    "valueFile"
                ]
            )

            and

            (
                if ($auth | has("value")) then

                    ($auth.value | nonempty)

                elif ($auth | has("valueEnv")) then

                    ($auth.valueEnv | nonempty)

                else

                    ($auth.valueFile | nonempty)

                end
            )


        else

            false

        end

    ' >/dev/null 2>&1 <<< "$auth_json"
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


        --tool-sources)

            if [ "$#" -lt 2 ]; then
                echo "ERROR: --tool-sources requires a value" >&2
                exit 2
            fi

            TOOL_SOURCES_FILE="$2"
            TOOL_SOURCES_EXPLICIT=1

            shift 2
            ;;


        --platform)

            if [ "$#" -lt 2 ]; then
                echo "ERROR: --platform requires a value" >&2
                exit 2
            fi

            PLATFORM_FILTER="$2"

            shift 2
            ;;


        --offline)

            OFFLINE=1
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


if [ "$OFFLINE" -eq 0 ]; then

    command -v curl >/dev/null 2>&1 || \
        kb_fail "curl is required; use --offline to skip network checks"

fi


[ -x "$CONFIG_VALIDATOR" ] || \
    kb_fail "configuration validator not found or not executable: $CONFIG_VALIDATOR"


# ----------------------------------------------------------------------
# Validate complete configuration directory first
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
# Discover configuration documents
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

    CONFIG_SCHEMA="$(
        jq -r '
            .schema
        ' "$CONFIG_FILE"
    )"


    case "$CONFIG_SCHEMA" in

        "$CLUSTER_SCHEMA")

            CLUSTER_FILES+=("$CONFIG_FILE")
            ;;


        "$TOOL_SOURCES_SCHEMA")

            TOOL_SOURCE_FILES+=("$CONFIG_FILE")
            ;;

    esac

done


# ----------------------------------------------------------------------
# Built-in tool source configuration
# ----------------------------------------------------------------------

kb_require_readable_json_file \
    "$DEFAULT_SOURCES_FILE" \
    "default tool source configuration"


if ! jq -e \
    --arg schema "$TOOL_SOURCES_SCHEMA" \
    --argjson version "$TOOL_SOURCES_SCHEMA_VERSION" '

    .schema == $schema
    and
    .schemaVersion == $version

' "$DEFAULT_SOURCES_FILE" >/dev/null 2>&1
then

    kb_fail \
        "invalid default tool source schema: $DEFAULT_SOURCES_FILE"

fi


# ----------------------------------------------------------------------
# Select optional source override
#
# Priority:
#
#   1. --tool-sources PATH
#   2. kubebase.toolSources document in config directory
#   3. defaults only
# ----------------------------------------------------------------------

if [ "$TOOL_SOURCES_EXPLICIT" -eq 1 ]; then

    kb_require_readable_file \
        "$TOOL_SOURCES_FILE" \
        "tool source override"


    TOOL_SOURCES_FILE="$(
        kb_canonical_file "$TOOL_SOURCES_FILE"
    )"


else

    case "${#TOOL_SOURCE_FILES[@]}" in

        0)

            TOOL_SOURCES_FILE=""
            ;;


        1)

            TOOL_SOURCES_FILE="${TOOL_SOURCE_FILES[0]}"
            ;;


        *)

            echo \
                "ERROR: multiple $TOOL_SOURCES_SCHEMA documents found:" \
                >&2

            for FILE in "${TOOL_SOURCE_FILES[@]}"; do
                echo "  $FILE" >&2
            done

            exit 1
            ;;

    esac

fi


# ----------------------------------------------------------------------
# Validate override envelope
# ----------------------------------------------------------------------

if [ -n "$TOOL_SOURCES_FILE" ]; then

    kb_require_readable_json_file \
        "$TOOL_SOURCES_FILE" \
        "tool source override"


    if ! jq -e \
        --arg schema "$TOOL_SOURCES_SCHEMA" \
        --argjson version "$TOOL_SOURCES_SCHEMA_VERSION" '

        .schema == $schema
        and
        .schemaVersion == $version

    ' "$TOOL_SOURCES_FILE" >/dev/null 2>&1
    then

        kb_fail \
            "invalid tool source schema: $TOOL_SOURCES_FILE"

    fi

fi


# ----------------------------------------------------------------------
# Inline secret permissions
# ----------------------------------------------------------------------

if [ -n "$TOOL_SOURCES_FILE" ]; then

    if jq -e '

        [
            ..
            | objects
            | .auth?
            | select(type == "object")
            | select(
                has("password")
                or
                has("token")
                or
                has("value")
            )
        ]

        | length > 0

    ' "$TOOL_SOURCES_FILE" >/dev/null
    then

        FILE_MODE="$(
            stat -c '%a' "$TOOL_SOURCES_FILE"
        )"

        FILE_MODE_NUM=$((8#$FILE_MODE))


        if (( (FILE_MODE_NUM & 077) != 0 )); then

            kb_fail \
                "$TOOL_SOURCES_FILE contains inline credentials but permissions are $FILE_MODE; use chmod 600"

        fi

    fi

fi


# ----------------------------------------------------------------------
# Override safety
#
# If an override changes platform configuration, it must explicitly
# supply probeUrl as well. This prevents probing the public upstream
# while artifacts actually point to a private mirror.
# ----------------------------------------------------------------------

if [ -n "$TOOL_SOURCES_FILE" ]; then

    mapfile -t OVERRIDE_SOURCE_NAMES < <(

        jq -r '

            if (.sources | type) == "object" then
                .sources | keys[]
            else
                empty
            end

        ' "$TOOL_SOURCES_FILE"

    )


    for SOURCE_NAME in "${OVERRIDE_SOURCE_NAMES[@]}"; do

        if jq -e \
            --arg source "$SOURCE_NAME" '

            .sources[$source]
            | has("platforms")

        ' "$TOOL_SOURCES_FILE" >/dev/null 2>&1
        then

            if ! jq -e \
                --arg source "$SOURCE_NAME" '

                .sources[$source].probeUrl
                |
                type == "string"
                and
                length > 0

            ' "$TOOL_SOURCES_FILE" >/dev/null 2>&1
            then

                kb_fail \
                    "override source '$SOURCE_NAME' changes platforms but does not define probeUrl"

            fi

        fi

    done

fi


# ----------------------------------------------------------------------
# Merge source configuration
#
# Objects are deep-merged except auth, which is replaced atomically.
# ----------------------------------------------------------------------

if [ -n "$TOOL_SOURCES_FILE" ]; then

    EFFECTIVE_JSON="$(
        jq -s '

            def deepmerge($base; $override):

                reduce ($override | keys_unsorted[]) as $key
                    (
                        $base;

                        if $key == "auth" then

                            .[$key] = $override[$key]

                        elif
                            ((.[$key] | type) == "object")
                            and
                            (($override[$key] | type) == "object")
                        then

                            .[$key] =
                                deepmerge(
                                    .[$key];
                                    $override[$key]
                                )

                        else

                            .[$key] = $override[$key]

                        end
                    );

            deepmerge(.[0]; .[1])

        ' \
        "$DEFAULT_SOURCES_FILE" \
        "$TOOL_SOURCES_FILE"
    )"

else

    EFFECTIVE_JSON="$(
        jq '.' "$DEFAULT_SOURCES_FILE"
    )"

fi


# ----------------------------------------------------------------------
# Effective source document
# ----------------------------------------------------------------------

if ! jq -e \
    --arg schema "$TOOL_SOURCES_SCHEMA" \
    --argjson version "$TOOL_SOURCES_SCHEMA_VERSION" '

    .schema == $schema
    and
    .schemaVersion == $version

    and

    (.defaults | type) == "object"

    and

    (.sources | type) == "object"

' >/dev/null 2>&1 <<< "$EFFECTIVE_JSON"
then

    validation_error \
        "invalid effective $TOOL_SOURCES_SCHEMA configuration"

fi


# ----------------------------------------------------------------------
# Default auth
# ----------------------------------------------------------------------

DEFAULT_AUTH="$(
    jq -c '
        .defaults.auth // {"type":"none"}
    ' <<< "$EFFECTIVE_JSON"
)"


if ! auth_is_valid "$DEFAULT_AUTH"; then

    validation_error \
        "invalid defaults.auth configuration"

fi


# ----------------------------------------------------------------------
# Validate complete source catalog
#
# This is deliberately not limited to cluster requirements.
# Broken source definitions should be detected even if a current
# cluster does not use them yet.
# ----------------------------------------------------------------------

mapfile -t SOURCE_NAMES < <(

    jq -r '
        .sources
        | keys[]
    ' <<< "$EFFECTIVE_JSON"

)


for SOURCE_NAME in "${SOURCE_NAMES[@]}"; do

    if [[ ! "$SOURCE_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then

        validation_error \
            "invalid source name '$SOURCE_NAME'"

        continue

    fi


    # ------------------------------------------------------------------
    # probeUrl
    # ------------------------------------------------------------------

    if ! jq -e \
        --arg source "$SOURCE_NAME" '

        .sources[$source].probeUrl

        |

        type == "string"
        and
        length > 0
        and
        test("^https?://")
        and
        (
            test("^https?://[^/]*@")
            | not
        )

    ' >/dev/null 2>&1 <<< "$EFFECTIVE_JSON"
    then

        validation_error \
            "sources.$SOURCE_NAME.probeUrl is invalid"

    fi


    # ------------------------------------------------------------------
    # effective auth
    # ------------------------------------------------------------------

    SOURCE_AUTH="$(
        jq -c \
            --arg source "$SOURCE_NAME" '

            .sources[$source].auth
            //
            .defaults.auth
            //
            {"type":"none"}

        ' <<< "$EFFECTIVE_JSON"
    )"


    if ! auth_is_valid "$SOURCE_AUTH"; then

        validation_error \
            "sources.$SOURCE_NAME effective auth configuration is invalid"

    fi


    # ------------------------------------------------------------------
    # platforms
    # ------------------------------------------------------------------

    if ! jq -e \
        --arg source "$SOURCE_NAME" '

        .sources[$source].platforms

        |

        type == "object"
        and
        length > 0

    ' >/dev/null 2>&1 <<< "$EFFECTIVE_JSON"
    then

        validation_error \
            "sources.$SOURCE_NAME.platforms must be a non-empty object"

        continue

    fi


    mapfile -t SOURCE_PLATFORMS < <(

        jq -r \
            --arg source "$SOURCE_NAME" '

            .sources[$source].platforms
            | keys[]

        ' <<< "$EFFECTIVE_JSON"

    )


    for SOURCE_PLATFORM in "${SOURCE_PLATFORMS[@]}"; do

        if [[ ! "$SOURCE_PLATFORM" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then

            validation_error \
                "sources.$SOURCE_NAME has invalid platform name '$SOURCE_PLATFORM'"

            continue

        fi


        if ! jq -e \
            --arg source "$SOURCE_NAME" \
            --arg platform "$SOURCE_PLATFORM" '

            .sources[$source]
            .platforms[$platform]

            |

            (.artifact | type) == "object"

            and

            (.artifact.url | type) == "string"
            and
            (.artifact.url | length > 0)
            and
            (.artifact.url | test("^https?://"))
            and
            (.artifact.url | contains("{version}"))
            and
            (
                .artifact.url
                | test("^https?://[^/]*@")
                | not
            )

            and

            (
                .artifact.type == "binary"
                or
                .artifact.type == "tar.gz"
                or
                .artifact.type == "zip"
            )

            and

            (.artifact.binary | type) == "string"
            and
            (.artifact.binary | length > 0)

            and

            (.checksum | type) == "object"

            and

            (.checksum.url | type) == "string"
            and
            (.checksum.url | length > 0)
            and
            (.checksum.url | test("^https?://"))
            and
            (.checksum.url | contains("{version}"))
            and
            (
                .checksum.url
                | test("^https?://[^/]*@")
                | not
            )

            and

            (
                .checksum.type == "sha256-raw"
                or
                .checksum.type == "sha256sum"
                or
                .checksum.type == "sha256sum-list"
            )

        ' >/dev/null 2>&1 <<< "$EFFECTIVE_JSON"
        then

            validation_error \
                "invalid source definition: $SOURCE_NAME / $SOURCE_PLATFORM"

        fi

    done

done


# ----------------------------------------------------------------------
# Cluster requirements
#
# Each cluster contributes:
#
#   tools x toolPlatforms
#
# Example:
#
#   kubectl 1.33.5 x linux-amd64
#   kubectl 1.33.5 x windows-amd64
# ----------------------------------------------------------------------

for CLUSTER_FILE in "${CLUSTER_FILES[@]}"; do

    CLUSTER_NAME="$(
        jq -r '
            .name
        ' "$CLUSTER_FILE"
    )"


    mapfile -t CLUSTER_PLATFORMS < <(

        jq -r '
            .toolPlatforms[]
        ' "$CLUSTER_FILE"

    )


    mapfile -t CLUSTER_TOOLS < <(

        jq -r '
            .tools
            | keys[]
        ' "$CLUSTER_FILE"

    )


    for CLUSTER_PLATFORM in "${CLUSTER_PLATFORMS[@]}"; do

        if [ -n "$PLATFORM_FILTER" ] &&
           [ "$CLUSTER_PLATFORM" != "$PLATFORM_FILTER" ]
        then
            continue
        fi


        for TOOL_NAME in "${CLUSTER_TOOLS[@]}"; do

            TOOL_VERSION="$(
                jq -r \
                    --arg tool "$TOOL_NAME" '

                    .tools[$tool].version

                ' "$CLUSTER_FILE"
            )"


            REQUIREMENT_BINDINGS=$((REQUIREMENT_BINDINGS + 1))


            # ----------------------------------------------------------
            # Tool source exists
            # ----------------------------------------------------------

            if ! jq -e \
                --arg tool "$TOOL_NAME" '

                .sources[$tool]
                | type == "object"

            ' >/dev/null 2>&1 <<< "$EFFECTIVE_JSON"
            then

                validation_error \
                    "cluster '$CLUSTER_NAME' requires unknown tool '$TOOL_NAME' version '$TOOL_VERSION'"

                continue

            fi


            # ----------------------------------------------------------
            # Tool source supports requested platform
            # ----------------------------------------------------------

            if ! jq -e \
                --arg tool "$TOOL_NAME" \
                --arg platform "$CLUSTER_PLATFORM" '

                .sources[$tool]
                .platforms[$platform]

                | type == "object"

            ' >/dev/null 2>&1 <<< "$EFFECTIVE_JSON"
            then

                validation_error \
                    "cluster '$CLUSTER_NAME': tool '$TOOL_NAME' version '$TOOL_VERSION' has no source for platform '$CLUSTER_PLATFORM'"

                continue

            fi


            # ----------------------------------------------------------
            # Unique artifact requirement
            # ----------------------------------------------------------

            REQUIREMENT_KEY="${TOOL_NAME}"$'\x1f'"${TOOL_VERSION}"$'\x1f'"${CLUSTER_PLATFORM}"


            if [[ -z "${REQUIREMENTS[$REQUIREMENT_KEY]+x}" ]]; then

                REQUIREMENTS["$REQUIREMENT_KEY"]=1

                REQUIREMENT_CLUSTERS["$REQUIREMENT_KEY"]="$CLUSTER_NAME"

                UNIQUE_REQUIREMENTS=$((UNIQUE_REQUIREMENTS + 1))

            else

                EXISTING_CLUSTERS="${REQUIREMENT_CLUSTERS[$REQUIREMENT_KEY]}"

                case ",$EXISTING_CLUSTERS," in
                    *",$CLUSTER_NAME,"*)
                        ;;
                    *)
                        REQUIREMENT_CLUSTERS["$REQUIREMENT_KEY"]="$EXISTING_CLUSTERS,$CLUSTER_NAME"
                        ;;
                esac

            fi

        done

    done

done


# ----------------------------------------------------------------------
# Fail before doing any network operations
# ----------------------------------------------------------------------

if [ "$VALIDATION_ERRORS" -ne 0 ]; then

    echo >&2

    echo \
        "Source validation FAILED: $VALIDATION_ERRORS error(s)." \
        >&2

    exit 1

fi


# ----------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------

echo "$PROJECT_NAME tool source validation"

echo
echo "Repository : $REPO_ROOT"
echo "Workspace  : $WORKSPACE_DIR"
echo "Config dir : $CONFIG_DIR"
echo "Default    : $DEFAULT_SOURCES_FILE"

if [ -n "$TOOL_SOURCES_FILE" ]; then
    echo "Override   : $TOOL_SOURCES_FILE"
else
    echo "Override   : none"
fi

if [ -n "$PLATFORM_FILTER" ]; then
    echo "Platform   : $PLATFORM_FILTER (filter)"
else
    echo "Platform   : all cluster toolPlatforms"
fi

if [ "$OFFLINE" -eq 1 ]; then
    echo "Network    : offline"
else
    echo "Network    : enabled"
fi


# ----------------------------------------------------------------------
# Sources
# ----------------------------------------------------------------------

echo
echo "Sources:"


for SOURCE_NAME in "${SOURCE_NAMES[@]}"; do

    SOURCE_PLATFORM_LIST="$(
        jq -r \
            --arg source "$SOURCE_NAME" '

            .sources[$source].platforms
            | keys
            | join(", ")

        ' <<< "$EFFECTIVE_JSON"
    )"


    printf '  %-12s %-8s %s\n' \
        "$SOURCE_NAME" \
        "VALID" \
        "[$SOURCE_PLATFORM_LIST]"

done


# ----------------------------------------------------------------------
# Cluster requirements
# ----------------------------------------------------------------------

echo
echo "Cluster requirements:"
echo "  cluster bindings : $REQUIREMENT_BINDINGS"
echo "  unique artifacts : $UNIQUE_REQUIREMENTS"


if [ "$UNIQUE_REQUIREMENTS" -gt 0 ]; then

    echo


    mapfile -t REQUIREMENT_KEYS < <(
        printf '%s\n' "${!REQUIREMENTS[@]}" |
        sort
    )


    for REQUIREMENT_KEY in "${REQUIREMENT_KEYS[@]}"; do

        IFS=$'\x1f' read -r \
            TOOL_NAME \
            TOOL_VERSION \
            TOOL_PLATFORM \
            <<< "$REQUIREMENT_KEY"


        REQUIRED_BY="${REQUIREMENT_CLUSTERS[$REQUIREMENT_KEY]}"


        printf '  %-12s %-12s %-16s VALID  [%s]\n' \
            "$TOOL_NAME" \
            "$TOOL_VERSION" \
            "$TOOL_PLATFORM" \
            "$REQUIRED_BY"

    done

else

    echo
    echo "  No artifact requirements selected."

fi


echo
echo "Configuration valid."


# ----------------------------------------------------------------------
# Offline mode
# ----------------------------------------------------------------------

if [ "$OFFLINE" -eq 1 ]; then

    echo
    echo "Reachability:"
    echo "  SKIPPED (--offline)"

    echo
    echo "Validation OK"

    exit 0

fi


# ----------------------------------------------------------------------
# Reachability
#
# Keep probe behavior independent from specific artifact versions.
# Actual artifact/checksum availability is verified later by Step 20.
# ----------------------------------------------------------------------

NETWORK_ERRORS=0

echo
echo "Reachability:"


for SOURCE_NAME in "${SOURCE_NAMES[@]}"; do

    PROBE_URL="$(
        jq -r \
            --arg source "$SOURCE_NAME" '

            .sources[$source].probeUrl

        ' <<< "$EFFECTIVE_JSON"
    )"


    HTTP_CODE=""
    CURL_RESULT=0


    if HTTP_CODE="$(
        curl \
            --silent \
            --show-error \
            --location \
            --max-redirs 5 \
            --head \
            --connect-timeout 5 \
            --max-time 15 \
            --proto '=http,https' \
            --proto-redir '=http,https' \
            --output /dev/null \
            --write-out '%{http_code}' \
            "$PROBE_URL"
    )"
    then

        CURL_RESULT=0

    else

        CURL_RESULT=$?

    fi


    # ------------------------------------------------------------------
    # Some servers reject HEAD.
    # Fall back to a one-byte GET.
    # ------------------------------------------------------------------

    if [ "$CURL_RESULT" -eq 0 ] &&
       {
           [ "$HTTP_CODE" = "405" ] ||
           [ "$HTTP_CODE" = "501" ];
       }
    then

        if HTTP_CODE="$(
            curl \
                --silent \
                --show-error \
                --location \
                --max-redirs 5 \
                --range 0-0 \
                --connect-timeout 5 \
                --max-time 15 \
                --proto '=http,https' \
                --proto-redir '=http,https' \
                --output /dev/null \
                --write-out '%{http_code}' \
                "$PROBE_URL"
        )"
        then

            CURL_RESULT=0

        else

            CURL_RESULT=$?

        fi

    fi


    if [ "$CURL_RESULT" -ne 0 ]; then

        printf '  %-12s %-16s %s\n' \
            "$SOURCE_NAME" \
            "UNREACHABLE" \
            "$PROBE_URL"

        NETWORK_ERRORS=$((NETWORK_ERRORS + 1))


    elif [[ "$HTTP_CODE" =~ ^[23][0-9][0-9]$ ]]; then

        printf '  %-12s %-16s HTTP %s  %s\n' \
            "$SOURCE_NAME" \
            "REACHABLE" \
            "$HTTP_CODE" \
            "$PROBE_URL"


    else

        printf '  %-12s %-16s HTTP %s  %s\n' \
            "$SOURCE_NAME" \
            "NOT-ACCESSIBLE" \
            "$HTTP_CODE" \
            "$PROBE_URL"

        NETWORK_ERRORS=$((NETWORK_ERRORS + 1))

    fi

done


echo


if [ "$NETWORK_ERRORS" -ne 0 ]; then

    echo \
        "Reachability FAILED: $NETWORK_ERRORS source(s)." \
        >&2

    exit 1

fi


echo "Reachability OK"

echo
echo "NOTE:"
echo "  Probe URL reachability was checked."
echo "  Exact artifact and checksum URLs are not downloaded here."
echo "  Exact version availability will be verified by Step 20."

echo
echo "Validation OK"
