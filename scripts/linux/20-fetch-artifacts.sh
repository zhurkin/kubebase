#!/usr/bin/env bash

set -euo pipefail


# ----------------------------------------------------------------------
# KubeBase
# Step 20 - Artifact fetch
# Linux
#
# Downloads the unique set of:
#
#   tool + version + platform
#
# required by all kubebase.cluster documents.
#
# Multiple clusters may require the same artifact. The artifact is kept
# once in the shared workspace artifact store and is downloaded once.
# ----------------------------------------------------------------------

PROJECT_NAME="KubeBase"

CLUSTER_SCHEMA="kubebase.cluster"
TOOL_SOURCES_SCHEMA="kubebase.toolSources"

ARTIFACT_SCHEMA="kubebase.artifact"
ARTIFACT_SCHEMA_VERSION=2

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
SOURCE_VALIDATOR="$SCRIPT_DIR/11-validate-sources.sh"


# ----------------------------------------------------------------------
# Defaults
# ----------------------------------------------------------------------

WORKSPACE_NAME="$DEFAULT_WORKSPACE_NAME"
WORKSPACE_ROOT="$DEFAULT_WORKSPACE_ROOT"

TOOL_SOURCES_FILE=""
TOOL_SOURCES_EXPLICIT=0

PLATFORM_FILTER=""
DRY_RUN=0


# ----------------------------------------------------------------------
# Runtime state
# ----------------------------------------------------------------------

ACTIVE_STAGE=""
ACTIVE_AUTH_FILE=""
PLAN_FILE=""

CLUSTER_BINDINGS=0
PLANNED=0
FETCHED=0
EXISTING=0

CONFIG_FILES=()
CLUSTER_FILES=()
TOOL_SOURCE_FILES=()

# Artifact identity is:
#
#   tool <US> version <US> platform
#
# where US = ASCII Unit Separator 0x1f.

declare -A REQUIREMENTS=()
declare -A REQUIREMENT_CLUSTERS=()


# ----------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------

cleanup()
{
    if [ -n "$ACTIVE_STAGE" ] && [ -d "$ACTIVE_STAGE" ]; then
        rm -rf -- "$ACTIVE_STAGE"
    fi

    if [ -n "$ACTIVE_AUTH_FILE" ] && [ -f "$ACTIVE_AUTH_FILE" ]; then
        rm -f -- "$ACTIVE_AUTH_FILE"
    fi

    if [ -n "$PLAN_FILE" ] && [ -f "$PLAN_FILE" ]; then
        rm -f -- "$PLAN_FILE"
    fi
}


trap cleanup EXIT HUP INT TERM


usage()
{
    cat <<EOF_USAGE
$PROJECT_NAME artifact fetch

Usage:
  kubebase fetch [options]

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
      Temporarily use PATH as kubebase.toolSources override.

  --platform PLATFORM
      Fetch only requirements for PLATFORM.

      Example:
        linux-amd64
        windows-amd64

  --dry-run
      Resolve and display the artifact plan without downloading.

  -h, --help
      Show this help.

Examples:
  kubebase fetch --dry-run

  kubebase fetch

  kubebase fetch --platform windows-amd64

  kubebase fetch \
      --tool-sources /etc/kubebase/sources.json
EOF_USAGE
}


resolve_version_url()
{
    local template="$1"
    local version="$2"

    printf '%s\n' "${template//\{version\}/$version}"
}


url_basename()
{
    local url="$1"

    url="${url%%#*}"
    url="${url%%\?*}"
    url="${url%/}"

    basename -- "$url"
}


safe_version()
{
    local version="$1"

    [[ "$version" =~ ^[A-Za-z0-9][A-Za-z0-9._+~-]*$ ]] &&
    [ "$version" != "." ] &&
    [ "$version" != ".." ]
}


sorted_cluster_list()
{
    local value="$1"

    printf '%s\n' "$value" |
        tr ',' '\n' |
        LC_ALL=C sort -u |
        awk '
            NF {
                if (first) {
                    printf ", "
                }

                printf "%s", $0
                first = 1
            }

            END {
                print ""
            }
        '
}


# ----------------------------------------------------------------------
# Authentication helpers
# ----------------------------------------------------------------------

read_auth_secret()
{
    local auth_json="$1"
    local direct_field="$2"
    local env_field="$3"
    local file_field="$4"

    local env_name
    local file_name
    local value


    if jq -e \
        --arg field "$direct_field" '
        has($field)
    ' >/dev/null <<< "$auth_json"
    then
        jq -r \
            --arg field "$direct_field" '
            .[$field]
        ' <<< "$auth_json"

        return 0
    fi


    if jq -e \
        --arg field "$env_field" '
        has($field)
    ' >/dev/null <<< "$auth_json"
    then
        env_name="$(
            jq -r \
                --arg field "$env_field" '
                .[$field]
            ' <<< "$auth_json"
        )"

        if [[ ! "$env_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
            kb_fail "invalid authentication environment variable name: $env_name"
        fi

        if ! value="$(printenv "$env_name")"; then
            kb_fail "authentication environment variable is not set: $env_name"
        fi

        if [ -z "$value" ]; then
            kb_fail "authentication environment variable is empty: $env_name"
        fi

        printf '%s' "$value"
        return 0
    fi


    if jq -e \
        --arg field "$file_field" '
        has($field)
    ' >/dev/null <<< "$auth_json"
    then
        file_name="$(
            jq -r \
                --arg field "$file_field" '
                .[$field]
            ' <<< "$auth_json"
        )"

        if [[ "$file_name" != /* ]]; then
            kb_fail "authentication secret file must currently use an absolute path: $file_name"
        fi

        [ -f "$file_name" ] || \
            kb_fail "authentication secret file not found: $file_name"

        [ -r "$file_name" ] || \
            kb_fail "authentication secret file is not readable: $file_name"

        cat -- "$file_name"
        return 0
    fi


    kb_fail "authentication secret is not configured"
}


curl_config_escape()
{
    local value="$1"

    case "$value" in
        *$'\n'*|*$'\r'*)
            kb_fail "authentication value contains newline characters"
            ;;
    esac

    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"

    printf '%s' "$value"
}


prepare_auth_file()
{
    local source_name="$1"
    local destination="$2"

    local auth_json
    local auth_type

    local username
    local password
    local token

    local header_name
    local header_value

    local escaped


    auth_json="$(
        jq -c \
            --arg source "$source_name" '
            .sources[$source].auth
            //
            .defaults.auth
            //
            {"type":"none"}
        ' <<< "$EFFECTIVE_JSON"
    )"


    auth_type="$(
        jq -r '
            .type
        ' <<< "$auth_json"
    )"


    : > "$destination"
    chmod 600 "$destination"


    case "$auth_type" in

        none)
            ;;


        basic)
            username="$(
                jq -r '
                    .username
                ' <<< "$auth_json"
            )"

            if [[ "$username" == *:* ]]; then
                kb_fail "basic authentication username must not contain ':'"
            fi

            password="$(
                read_auth_secret \
                    "$auth_json" \
                    "password" \
                    "passwordEnv" \
                    "passwordFile"
            )"

            escaped="$(
                curl_config_escape "$username:$password"
            )"

            printf 'user = "%s"\n' \
                "$escaped" \
                >> "$destination"
            ;;


        bearer)
            token="$(
                read_auth_secret \
                    "$auth_json" \
                    "token" \
                    "tokenEnv" \
                    "tokenFile"
            )"

            escaped="$(
                curl_config_escape "Authorization: Bearer $token"
            )"

            printf 'header = "%s"\n' \
                "$escaped" \
                >> "$destination"
            ;;


        header)
            header_name="$(
                jq -r '
                    .name
                ' <<< "$auth_json"
            )"

            if [[ ! "$header_name" =~ ^[A-Za-z0-9-]+$ ]]; then
                kb_fail "invalid HTTP authentication header name: $header_name"
            fi

            header_value="$(
                read_auth_secret \
                    "$auth_json" \
                    "value" \
                    "valueEnv" \
                    "valueFile"
            )"

            escaped="$(
                curl_config_escape "$header_name: $header_value"
            )"

            printf 'header = "%s"\n' \
                "$escaped" \
                >> "$destination"
            ;;


        *)
            kb_fail "unsupported authentication type: $auth_type"
            ;;

    esac
}


# ----------------------------------------------------------------------
# Download
# ----------------------------------------------------------------------

download_file()
{
    local url="$1"
    local destination="$2"

    curl \
        --config "$ACTIVE_AUTH_FILE" \
        --fail \
        --silent \
        --show-error \
        --location \
        --max-redirs 5 \
        --connect-timeout 10 \
        --max-time 600 \
        --retry 2 \
        --retry-delay 1 \
        --proto '=http,https' \
        --proto-redir '=http,https' \
        --output "$destination" \
        "$url"
}


# ----------------------------------------------------------------------
# Checksum helpers
# ----------------------------------------------------------------------

extract_expected_sha256()
{
    local checksum_type="$1"
    local checksum_file="$2"
    local artifact_filename="$3"

    local expected=""


    case "$checksum_type" in

        sha256-raw)
            expected="$(
                awk '
                    NF {
                        print $1
                        exit
                    }
                ' "$checksum_file"
            )"
            ;;


        sha256sum)
            expected="$(
                awk '
                    NF {
                        print $1
                        exit
                    }
                ' "$checksum_file"
            )"
            ;;


        sha256sum-list)
            expected="$(
                awk \
                    -v target="$artifact_filename" '
                    NF >= 2 {
                        hash = $1
                        name = $2

                        sub(/^\*/, "", name)
                        sub(/^\.\//, "", name)

                        shortname = name
                        sub(/^.*\//, "", shortname)

                        if (name == target || shortname == target) {
                            print hash
                            exit
                        }
                    }
                ' "$checksum_file"
            )"
            ;;


        *)
            return 1
            ;;

    esac


    expected="${expected,,}"


    if [[ ! "$expected" =~ ^[0-9a-f]{64}$ ]]; then
        return 1
    fi


    printf '%s\n' "$expected"
}


# ----------------------------------------------------------------------
# Existing artifact verification
# ----------------------------------------------------------------------

verify_existing_artifact()
{
    local dir="$1"
    local requested_tool="$2"
    local requested_version="$3"
    local requested_platform="$4"

    local manifest="$dir/manifest.json"

    local artifact_file
    local checksum_file
    local checksum_type

    local expected
    local checksum_sha256
    local checksum_expected
    local actual
    local checksum_actual


    [ -f "$manifest" ] || return 1


    if ! jq -e \
        --arg schema "$ARTIFACT_SCHEMA" \
        --argjson schemaVersion "$ARTIFACT_SCHEMA_VERSION" \
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

        (.artifact.file | type) == "string"
        and
        (.artifact.sha256 | type) == "string"

        and

        (.checksum.file | type) == "string"
        and
        (.checksum.type | type) == "string"
        and
        (.checksum.sha256 | type) == "string"

    ' "$manifest" >/dev/null 2>&1
    then
        return 1
    fi


    artifact_file="$(
        jq -r '
            .artifact.file
        ' "$manifest"
    )"

    checksum_file="$(
        jq -r '
            .checksum.file
        ' "$manifest"
    )"

    checksum_type="$(
        jq -r '
            .checksum.type
        ' "$manifest"
    )"

    checksum_sha256="$(
        jq -r '
            .checksum.sha256
        ' "$manifest"
    )"

    checksum_sha256="${checksum_sha256,,}"

    expected="$(
        jq -r '
            .artifact.sha256
        ' "$manifest"
    )"

    expected="${expected,,}"


    kb_safe_filename "$artifact_file" || return 1
    kb_safe_filename "$checksum_file" || return 1


    [ -f "$dir/$artifact_file" ] || return 1
    [ -f "$dir/$checksum_file" ] || return 1


    checksum_actual="$(
        sha256sum "$dir/$checksum_file" |
        awk '{print $1}'
    )"

    checksum_actual="${checksum_actual,,}"


    [ "$checksum_actual" = "$checksum_sha256" ] || return 1


    actual="$(
        sha256sum "$dir/$artifact_file" |
        awk '{print $1}'
    )"

    actual="${actual,,}"


    [ "$actual" = "$expected" ] || return 1


    if ! checksum_expected="$(
        extract_expected_sha256 \
            "$checksum_type" \
            "$dir/$checksum_file" \
            "$artifact_file"
    )"
    then
        return 1
    fi


    [ "$checksum_expected" = "$expected" ] || return 1


    return 0
}


# ----------------------------------------------------------------------
# Arguments
# ----------------------------------------------------------------------

while [ "$#" -gt 0 ]; do

    case "$1" in

        --workspace-name)
            [ "$#" -ge 2 ] || {
                echo "ERROR: --workspace-name requires a value" >&2
                exit 2
            }

            WORKSPACE_NAME="$2"
            shift 2
            ;;


        --workspace-root)
            [ "$#" -ge 2 ] || {
                echo "ERROR: --workspace-root requires a value" >&2
                exit 2
            }

            WORKSPACE_ROOT="$2"
            shift 2
            ;;


        --tool-sources)
            [ "$#" -ge 2 ] || {
                echo "ERROR: --tool-sources requires a value" >&2
                exit 2
            }

            TOOL_SOURCES_FILE="$2"
            TOOL_SOURCES_EXPLICIT=1

            shift 2
            ;;


        --platform)
            [ "$#" -ge 2 ] || {
                echo "ERROR: --platform requires a value" >&2
                exit 2
            }

            PLATFORM_FILTER="$2"
            shift 2
            ;;


        --dry-run)
            DRY_RUN=1
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

command -v curl >/dev/null 2>&1 || \
    kb_fail "curl is required"

command -v sha256sum >/dev/null 2>&1 || \
    kb_fail "sha256sum is required"

command -v mktemp >/dev/null 2>&1 || \
    kb_fail "mktemp is required"


[ -x "$SOURCE_VALIDATOR" ] || \
    kb_fail "source validator not found or not executable: $SOURCE_VALIDATOR"


# ----------------------------------------------------------------------
# Source/configuration preflight
# ----------------------------------------------------------------------

PREFLIGHT_ARGS=(
    --workspace-name "$WORKSPACE_NAME"
    --workspace-root "$WORKSPACE_ROOT"
    --offline
)


if [ "$TOOL_SOURCES_EXPLICIT" -eq 1 ]; then
    PREFLIGHT_ARGS+=(
        --tool-sources "$TOOL_SOURCES_FILE"
    )
fi


if [ -n "$PLATFORM_FILTER" ]; then
    PREFLIGHT_ARGS+=(
        --platform "$PLATFORM_FILTER"
    )
fi


"$SOURCE_VALIDATOR" \
    "${PREFLIGHT_ARGS[@]}" \
    >/dev/null


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
ARTIFACTS_DIR="$WORKSPACE_DIR/artifacts"


[ -f "$WORKSPACE_FILE" ] || \
    kb_fail "workspace configuration not found: $WORKSPACE_FILE"

[ -d "$ARTIFACTS_DIR" ] || \
    kb_fail "artifact directory not found: $ARTIFACTS_DIR"


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
# Configuration discovery
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
# Source override selection
# ----------------------------------------------------------------------

[ -f "$DEFAULT_SOURCES_FILE" ] || \
    kb_fail "default tool source configuration not found: $DEFAULT_SOURCES_FILE"


if [ "$TOOL_SOURCES_EXPLICIT" -eq 1 ]; then

    [ -f "$TOOL_SOURCES_FILE" ] || \
        kb_fail "tool source override not found: $TOOL_SOURCES_FILE"

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
            kb_fail "multiple $TOOL_SOURCES_SCHEMA documents found"
            ;;

    esac

fi


# ----------------------------------------------------------------------
# Effective tool sources
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
# Build unique artifact plan
#
# Artifact identity:
#
#   tool + version + platform
#
# Cluster names are consumers of an artifact, not part of its identity.
# ----------------------------------------------------------------------

PLAN_FILE="$(
    mktemp
)"


for CLUSTER_FILE in "${CLUSTER_FILES[@]}"; do

    CLUSTER_NAME="$(
        jq -r '
            .name
        ' "$CLUSTER_FILE"
    )"


    while IFS=$'\t' read -r \
        TOOL_NAME \
        TOOL_VERSION \
        TOOL_PLATFORM
    do
        [ -n "$TOOL_NAME" ] || continue


        CLUSTER_BINDINGS=$((CLUSTER_BINDINGS + 1))

        REQUIREMENT_KEY="${TOOL_NAME}"$'\x1f'"${TOOL_VERSION}"$'\x1f'"${TOOL_PLATFORM}"


        if [[ -z "${REQUIREMENTS[$REQUIREMENT_KEY]+x}" ]]; then

            REQUIREMENTS["$REQUIREMENT_KEY"]=1
            REQUIREMENT_CLUSTERS["$REQUIREMENT_KEY"]="$CLUSTER_NAME"

            printf '%s\t%s\t%s\n' \
                "$TOOL_NAME" \
                "$TOOL_VERSION" \
                "$TOOL_PLATFORM" \
                >> "$PLAN_FILE"


        else

            CURRENT_CLUSTERS="${REQUIREMENT_CLUSTERS[$REQUIREMENT_KEY]}"

            case ",$CURRENT_CLUSTERS," in
                *",$CLUSTER_NAME,"*)
                    ;;

                *)
                    REQUIREMENT_CLUSTERS["$REQUIREMENT_KEY"]="${CURRENT_CLUSTERS},${CLUSTER_NAME}"
                    ;;
            esac

        fi

    done < <(
        jq -r \
            --arg platformFilter "$PLATFORM_FILTER" '

            .toolPlatforms[] as $platform

            |

            select(
                $platformFilter == ""
                or
                $platform == $platformFilter
            )

            |

            .tools
            | to_entries[]
            | select(.value.enabled? != false)

            |

            [
                .key,
                .value.version,
                $platform
            ]

            | @tsv

        ' "$CLUSTER_FILE"
    )

done


LC_ALL=C sort \
    "$PLAN_FILE" \
    -o "$PLAN_FILE"


PLANNED="${#REQUIREMENTS[@]}"


# ----------------------------------------------------------------------
# Header
# ----------------------------------------------------------------------

echo "$PROJECT_NAME artifact fetch"

echo
echo "Repository : $REPO_ROOT"
echo "Workspace  : $WORKSPACE_DIR"
echo "Config dir : $CONFIG_DIR"
echo "Artifacts  : $ARTIFACTS_DIR"

if [ -n "$TOOL_SOURCES_FILE" ]; then
    echo "Override   : $TOOL_SOURCES_FILE"
else
    echo "Override   : none"
fi

if [ -n "$PLATFORM_FILTER" ]; then
    echo "Platform   : $PLATFORM_FILTER"
else
    echo "Platform   : all cluster toolPlatforms"
fi

if [ "$DRY_RUN" -eq 1 ]; then
    echo "Mode       : dry-run"
else
    echo "Mode       : fetch"
fi


echo
echo "Artifact plan:"
echo "  cluster bindings : $CLUSTER_BINDINGS"
echo "  unique artifacts : $PLANNED"


if [ "$PLANNED" -eq 0 ]; then
    echo
    echo "Nothing to fetch."
    exit 0
fi


# ----------------------------------------------------------------------
# Fetch requirements
# ----------------------------------------------------------------------

while IFS=$'\t' read -r \
    TOOL_NAME \
    TOOL_VERSION \
    TOOL_PLATFORM
do
    [ -n "$TOOL_NAME" ] || continue


    safe_version "$TOOL_VERSION" || \
        kb_fail "unsafe tool version '$TOOL_VERSION' for tool '$TOOL_NAME'"


    REQUIREMENT_KEY="${TOOL_NAME}"$'\x1f'"${TOOL_VERSION}"$'\x1f'"${TOOL_PLATFORM}"

    REQUIRED_BY="$(
        sorted_cluster_list \
            "${REQUIREMENT_CLUSTERS[$REQUIREMENT_KEY]}"
    )"


    ARTIFACT_URL_TEMPLATE="$(
        jq -r \
            --arg tool "$TOOL_NAME" \
            --arg platform "$TOOL_PLATFORM" '
            .sources[$tool]
            .platforms[$platform]
            .artifact.url
        ' <<< "$EFFECTIVE_JSON"
    )"


    ARTIFACT_TYPE="$(
        jq -r \
            --arg tool "$TOOL_NAME" \
            --arg platform "$TOOL_PLATFORM" '
            .sources[$tool]
            .platforms[$platform]
            .artifact.type
        ' <<< "$EFFECTIVE_JSON"
    )"


    ARTIFACT_BINARY="$(
        jq -r \
            --arg tool "$TOOL_NAME" \
            --arg platform "$TOOL_PLATFORM" '
            .sources[$tool]
            .platforms[$platform]
            .artifact.binary
        ' <<< "$EFFECTIVE_JSON"
    )"


    CHECKSUM_URL_TEMPLATE="$(
        jq -r \
            --arg tool "$TOOL_NAME" \
            --arg platform "$TOOL_PLATFORM" '
            .sources[$tool]
            .platforms[$platform]
            .checksum.url
        ' <<< "$EFFECTIVE_JSON"
    )"


    CHECKSUM_TYPE="$(
        jq -r \
            --arg tool "$TOOL_NAME" \
            --arg platform "$TOOL_PLATFORM" '
            .sources[$tool]
            .platforms[$platform]
            .checksum.type
        ' <<< "$EFFECTIVE_JSON"
    )"


    ARTIFACT_URL="$(
        resolve_version_url \
            "$ARTIFACT_URL_TEMPLATE" \
            "$TOOL_VERSION"
    )"


    CHECKSUM_URL="$(
        resolve_version_url \
            "$CHECKSUM_URL_TEMPLATE" \
            "$TOOL_VERSION"
    )"


    ARTIFACT_FILENAME="$(
        url_basename "$ARTIFACT_URL"
    )"


    CHECKSUM_FILENAME="$(
        url_basename "$CHECKSUM_URL"
    )"


    kb_safe_filename "$ARTIFACT_FILENAME" || \
        kb_fail "unsafe artifact filename resolved from URL: $ARTIFACT_URL"

    kb_safe_filename "$CHECKSUM_FILENAME" || \
        kb_fail "unsafe checksum filename resolved from URL: $CHECKSUM_URL"

    [ "$ARTIFACT_FILENAME" != "$CHECKSUM_FILENAME" ] || \
        kb_fail "artifact and checksum resolve to the same filename: $ARTIFACT_FILENAME"


    FINAL_PARENT="$ARTIFACTS_DIR/$TOOL_PLATFORM/$TOOL_NAME"
    FINAL_DIR="$FINAL_PARENT/$TOOL_VERSION"


    echo

    printf '[%-8s] %s %s %s\n' \
        "PLAN" \
        "$TOOL_NAME" \
        "$TOOL_VERSION" \
        "$TOOL_PLATFORM"

    echo "  required by : $REQUIRED_BY"


    if [ -d "$FINAL_DIR" ]; then

        if verify_existing_artifact \
            "$FINAL_DIR" \
            "$TOOL_NAME" \
            "$TOOL_VERSION" \
            "$TOOL_PLATFORM"
        then
            echo "  status      : already verified in shared store"
            echo "  location    : $FINAL_DIR"

            EXISTING=$((EXISTING + 1))
            continue
        fi


        kb_fail "existing artifact directory is incomplete or corrupt: $FINAL_DIR"
    fi


    if [ -e "$FINAL_DIR" ]; then
        kb_fail "artifact destination exists and is not a directory: $FINAL_DIR"
    fi


    echo "  artifact    : $ARTIFACT_URL"
    echo "  checksum    : $CHECKSUM_URL"


    if [ "$DRY_RUN" -eq 1 ]; then
        echo "  status      : would fetch"
        continue
    fi


    # ------------------------------------------------------------------
    # Stage
    # ------------------------------------------------------------------

    ACTIVE_STAGE="$(
        mktemp -d \
            "$ARTIFACTS_DIR/.fetch-${TOOL_NAME}-${TOOL_PLATFORM}.XXXXXX"
    )"


    ACTIVE_AUTH_FILE="$(
        mktemp
    )"


    prepare_auth_file \
        "$TOOL_NAME" \
        "$ACTIVE_AUTH_FILE"


    STAGED_ARTIFACT="$ACTIVE_STAGE/$ARTIFACT_FILENAME"
    STAGED_CHECKSUM="$ACTIVE_STAGE/$CHECKSUM_FILENAME"


    # ------------------------------------------------------------------
    # Download
    # ------------------------------------------------------------------

    echo "  download    : artifact"

    download_file \
        "$ARTIFACT_URL" \
        "$STAGED_ARTIFACT"


    echo "  download    : checksum"

    download_file \
        "$CHECKSUM_URL" \
        "$STAGED_CHECKSUM"


    # ------------------------------------------------------------------
    # SHA-256 verification
    # ------------------------------------------------------------------

    if ! EXPECTED_SHA256="$(
        extract_expected_sha256 \
            "$CHECKSUM_TYPE" \
            "$STAGED_CHECKSUM" \
            "$ARTIFACT_FILENAME"
    )"
    then
        kb_fail "unable to extract SHA-256 for $TOOL_NAME $TOOL_VERSION $TOOL_PLATFORM"
    fi


    ACTUAL_SHA256="$(
        sha256sum "$STAGED_ARTIFACT" |
        awk '{print $1}'
    )"

    ACTUAL_SHA256="${ACTUAL_SHA256,,}"


    CHECKSUM_SHA256="$(
        sha256sum "$STAGED_CHECKSUM" |
        awk '{print $1}'
    )"

    CHECKSUM_SHA256="${CHECKSUM_SHA256,,}"


    if [ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]; then
        kb_fail "SHA-256 mismatch for $TOOL_NAME $TOOL_VERSION $TOOL_PLATFORM: expected $EXPECTED_SHA256, got $ACTUAL_SHA256"
    fi


    echo "  sha256      : $ACTUAL_SHA256"


    # ------------------------------------------------------------------
    # Manifest
    #
    # requiredBy is intentionally not stored here.
    #
    # The manifest describes the immutable artifact itself.
    # Cluster consumers can change independently.
    # ------------------------------------------------------------------

    jq -n \
        --arg schema "$ARTIFACT_SCHEMA" \
        --argjson schemaVersion "$ARTIFACT_SCHEMA_VERSION" \
        --arg tool "$TOOL_NAME" \
        --arg version "$TOOL_VERSION" \
        --arg platform "$TOOL_PLATFORM" \
        --arg artifactFile "$ARTIFACT_FILENAME" \
        --arg artifactUrl "$ARTIFACT_URL" \
        --arg artifactType "$ARTIFACT_TYPE" \
        --arg artifactBinary "$ARTIFACT_BINARY" \
        --arg artifactSha256 "$ACTUAL_SHA256" \
        --arg checksumFile "$CHECKSUM_FILENAME" \
        --arg checksumUrl "$CHECKSUM_URL" \
        --arg checksumType "$CHECKSUM_TYPE" \
        --arg checksumSha256 "$CHECKSUM_SHA256" '

        {
            schema: $schema,
            schemaVersion: $schemaVersion,

            tool: $tool,
            version: $version,
            platform: $platform,

            artifact: {
                file: $artifactFile,
                url: $artifactUrl,
                type: $artifactType,
                binary: $artifactBinary,
                sha256: $artifactSha256
            },

            checksum: {
                file: $checksumFile,
                url: $checksumUrl,
                type: $checksumType,
                sha256: $checksumSha256
            }
        }

    ' > "$ACTIVE_STAGE/manifest.json"


    chmod 644 \
        "$STAGED_ARTIFACT" \
        "$STAGED_CHECKSUM" \
        "$ACTIVE_STAGE/manifest.json"

    chmod 755 \
        "$ACTIVE_STAGE"


    # ------------------------------------------------------------------
    # Commit
    #
    # FINAL_DIR appears only after a fully verified download.
    # ------------------------------------------------------------------

    mkdir -p -- "$FINAL_PARENT"


    if [ -e "$FINAL_DIR" ]; then
        kb_fail "artifact destination appeared during fetch: $FINAL_DIR"
    fi


    mv \
        -- "$ACTIVE_STAGE" \
        "$FINAL_DIR"


    ACTIVE_STAGE=""


    rm -f -- "$ACTIVE_AUTH_FILE"
    ACTIVE_AUTH_FILE=""


    echo "  status      : fetched and verified"
    echo "  location    : $FINAL_DIR"


    FETCHED=$((FETCHED + 1))

done < "$PLAN_FILE"


# ----------------------------------------------------------------------
# Result
# ----------------------------------------------------------------------

echo
echo "Artifact fetch complete."

echo
echo "Summary:"
echo "  cluster bindings : $CLUSTER_BINDINGS"
echo "  unique artifacts : $PLANNED"
echo "  fetched          : $FETCHED"
echo "  existing         : $EXISTING"

if [ "$DRY_RUN" -eq 1 ]; then
    echo "  mode             : dry-run"
fi
