#!/usr/bin/env bash

set -euo pipefail


# ----------------------------------------------------------------------
# KubeBase
# Step 30 - Tool installation
# Linux
#
# Installs verified artifacts from:
#
#   artifacts/<platform>/<tool>/<version>/
#
# into:
#
#   tools/<platform>/<tool>/<version>/
#
# No network access is used here.
#
# Artifact identity:
#
#   tool + version + platform
#
# Multiple clusters may use the same installed tool.
# ----------------------------------------------------------------------

PROJECT_NAME="KubeBase"

CLUSTER_SCHEMA="kubebase.cluster"

ARTIFACT_SCHEMA="kubebase.artifact"
ARTIFACT_SCHEMA_VERSION=1

INSTALL_SCHEMA="kubebase.toolInstall"
INSTALL_SCHEMA_VERSION=1

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

PLATFORM_FILTER=""
ALL_PLATFORMS=0

DRY_RUN=0


# ----------------------------------------------------------------------
# Runtime state
# ----------------------------------------------------------------------

ACTIVE_STAGE=""
PLAN_FILE=""

CLUSTER_BINDINGS=0
PLANNED=0

INSTALLED=0
EXISTING=0

CONFIG_FILES=()
CLUSTER_FILES=()

declare -A REQUIREMENTS=()
declare -A REQUIREMENT_CLUSTERS=()


# ----------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------

fail()
{
    echo "ERROR: $*" >&2
    exit 1
}


cleanup()
{
    if [ -n "$ACTIVE_STAGE" ] && [ -d "$ACTIVE_STAGE" ]; then
        rm -rf -- "$ACTIVE_STAGE"
    fi

    if [ -n "$PLAN_FILE" ] && [ -f "$PLAN_FILE" ]; then
        rm -f -- "$PLAN_FILE"
    fi
}


trap cleanup EXIT HUP INT TERM


usage()
{
    cat <<EOF_USAGE
$PROJECT_NAME tool installation

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

  --platform PLATFORM
      Install tools for PLATFORM instead of the current host platform.

      Examples:
        linux-amd64
        windows-amd64

  --all-platforms
      Install all toolPlatforms required by all configured clusters.

  --dry-run
      Verify artifacts and display the installation plan
      without writing tools/.

  -h, --help
      Show this help.

Examples:
  $(basename "$0")

  $(basename "$0") --dry-run

  $(basename "$0") --platform windows-amd64

  $(basename "$0") --all-platforms
EOF_USAGE
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
            fail \
                "unsupported host operating system for Linux installer: $(uname -s)"
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
            fail \
                "unsupported host architecture: $(uname -m)"
            ;;

    esac


    printf '%s-%s\n' \
        "$os_name" \
        "$arch_name"
}


safe_component()
{
    local value="$1"

    [[ "$value" =~ ^[A-Za-z0-9][A-Za-z0-9._+~-]*$ ]] &&
    [ "$value" != "." ] &&
    [ "$value" != ".." ]
}


safe_filename()
{
    local value="$1"

    [[ "$value" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]]
}


safe_member_path()
{
    local value="$1"
    local part

    local -a parts


    [[ "$value" =~ ^[A-Za-z0-9][A-Za-z0-9._+~/-]*$ ]] || \
        return 1

    [[ "$value" != /* ]] || \
        return 1

    [[ "$value" != */ ]] || \
        return 1

    [[ "$value" != *//* ]] || \
        return 1


    IFS='/' read -r -a parts <<< "$value"


    for part in "${parts[@]}"; do

        [ -n "$part" ] || \
            return 1

        [ "$part" != "." ] || \
            return 1

        [ "$part" != ".." ] || \
            return 1

    done


    return 0
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
# Checksum helpers
# ----------------------------------------------------------------------

extract_expected_sha256()
{
    local checksum_type="$1"
    local checksum_file="$2"
    local artifact_filename="$3"

    local expected=""


    case "$checksum_type" in

        sha256-raw|sha256sum)

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
# Artifact verification
#
# Artifact is verified again before installation.
# ----------------------------------------------------------------------

verify_artifact_store()
{
    local dir="$1"

    local requested_tool="$2"
    local requested_version="$3"
    local requested_platform="$4"

    local manifest="$dir/manifest.json"

    local artifact_file
    local artifact_type
    local source_binary

    local checksum_file
    local checksum_type

    local expected
    local checksum_expected
    local actual


    [ -f "$manifest" ] || \
        return 1


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

        (.artifact | type) == "object"
        and
        (.artifact.file | type) == "string"
        and
        (.artifact.type | type) == "string"
        and
        (.artifact.binary | type) == "string"
        and
        (.artifact.sha256 | type) == "string"

        and

        (.checksum | type) == "object"
        and
        (.checksum.file | type) == "string"
        and
        (.checksum.type | type) == "string"

    ' "$manifest" >/dev/null 2>&1
    then

        return 1

    fi


    artifact_file="$(
        jq -r '
            .artifact.file
        ' "$manifest"
    )"

    artifact_type="$(
        jq -r '
            .artifact.type
        ' "$manifest"
    )"

    source_binary="$(
        jq -r '
            .artifact.binary
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

    expected="$(
        jq -r '
            .artifact.sha256
        ' "$manifest"
    )"

    expected="${expected,,}"


    safe_filename "$artifact_file" || \
        return 1

    safe_filename "$checksum_file" || \
        return 1

    safe_member_path "$source_binary" || \
        return 1


    case "$artifact_type" in

        binary|tar.gz|zip)
            ;;

        *)
            return 1
            ;;

    esac


    [ -f "$dir/$artifact_file" ] || \
        return 1

    [ -f "$dir/$checksum_file" ] || \
        return 1


    actual="$(
        sha256sum "$dir/$artifact_file" |
        awk '{print $1}'
    )"

    actual="${actual,,}"


    [ "$actual" = "$expected" ] || \
        return 1


    if ! checksum_expected="$(
        extract_expected_sha256 \
            "$checksum_type" \
            "$dir/$checksum_file" \
            "$artifact_file"
    )"
    then

        return 1

    fi


    [ "$checksum_expected" = "$expected" ] || \
        return 1


    return 0
}


# ----------------------------------------------------------------------
# Archive member lookup
# ----------------------------------------------------------------------

find_tar_member()
{
    local archive="$1"
    local wanted="$2"


    tar --warning=no-unknown-keyword -tzf "$archive" |
        awk \
            -v wanted="$wanted" '
            {
                original = $0
                normalized = $0

                sub(/^\.\//, "", normalized)

                if (!found && normalized == wanted) {
                    print original
                    found = 1
                }
            }
        '
}


find_zip_member()
{
    local archive="$1"
    local wanted="$2"


    unzip -Z1 "$archive" |
        awk \
            -v wanted="$wanted" '
            {
                original = $0
                normalized = $0

                sub(/^\.\//, "", normalized)

                if (!found && normalized == wanted) {
                    print original
                    found = 1
                }
            }
        '
}


# ----------------------------------------------------------------------
# Installed filename
#
# Source archive path may be platform-specific:
#
#   linux-amd64/helm
#   krew-linux_amd64
#
# The shared tool store uses the logical tool name:
#
#   helm
#   krew
#
# Windows gets .exe.
# ----------------------------------------------------------------------

installed_filename()
{
    local tool="$1"
    local source_binary="$2"

    local base


    base="$(
        basename -- "$source_binary"
    )"


    case "$base" in

        *.exe)
            printf '%s.exe\n' "$tool"
            ;;

        *)
            printf '%s\n' "$tool"
            ;;

    esac
}


# ----------------------------------------------------------------------
# Existing installation verification
# ----------------------------------------------------------------------

verify_existing_install()
{
    local dir="$1"

    local requested_tool="$2"
    local requested_version="$3"
    local requested_platform="$4"

    local artifact_sha256="$5"

    local manifest="$dir/manifest.json"

    local binary_file

    local expected_binary_sha256
    local actual_binary_sha256

    local recorded_artifact_sha256


    [ -f "$manifest" ] || \
        return 1


    if ! jq -e \
        --arg schema "$INSTALL_SCHEMA" \
        --argjson schemaVersion "$INSTALL_SCHEMA_VERSION" \
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

        (.artifact.sha256 | type) == "string"

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

    expected_binary_sha256="$(
        jq -r '
            .binary.sha256
        ' "$manifest"
    )"

    recorded_artifact_sha256="$(
        jq -r '
            .artifact.sha256
        ' "$manifest"
    )"


    expected_binary_sha256="${expected_binary_sha256,,}"
    recorded_artifact_sha256="${recorded_artifact_sha256,,}"
    artifact_sha256="${artifact_sha256,,}"


    safe_filename "$binary_file" || \
        return 1


    [ -f "$dir/$binary_file" ] || \
        return 1


    [ "$recorded_artifact_sha256" = "$artifact_sha256" ] || \
        return 1


    actual_binary_sha256="$(
        sha256sum "$dir/$binary_file" |
        awk '{print $1}'
    )"

    actual_binary_sha256="${actual_binary_sha256,,}"


    [ "$actual_binary_sha256" = "$expected_binary_sha256" ] || \
        return 1


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


        --platform)

            [ "$#" -ge 2 ] || {
                echo "ERROR: --platform requires a value" >&2
                exit 2
            }


            if [ "$ALL_PLATFORMS" -ne 0 ]; then
                fail \
                    "--platform and --all-platforms cannot be used together"
            fi


            PLATFORM_FILTER="$2"

            shift 2
            ;;


        --all-platforms)

            if [ -n "$PLATFORM_FILTER" ]; then
                fail \
                    "--platform and --all-platforms cannot be used together"
            fi


            ALL_PLATFORMS=1

            shift
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
    fail "jq is required"

command -v sha256sum >/dev/null 2>&1 || \
    fail "sha256sum is required"

command -v mktemp >/dev/null 2>&1 || \
    fail "mktemp is required"


[ -x "$CONFIG_VALIDATOR" ] || \
    fail \
        "configuration validator not found or not executable: $CONFIG_VALIDATOR"


# ----------------------------------------------------------------------
# Configuration preflight
#
# Step 30 intentionally does NOT use tool source configuration.
#
# Installation must work completely offline from already fetched
# artifacts.
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
    fail \
        "workspace root not found: $WORKSPACE_ROOT"


WORKSPACE_ROOT="$(
    cd -- "$WORKSPACE_ROOT"
    pwd -P
)"

WORKSPACE_DIR="$WORKSPACE_ROOT/$WORKSPACE_NAME"

WORKSPACE_FILE="$WORKSPACE_DIR/workspace.json"

ARTIFACTS_DIR="$WORKSPACE_DIR/artifacts"
TOOLS_DIR="$WORKSPACE_DIR/tools"


[ -f "$WORKSPACE_FILE" ] || \
    fail \
        "workspace configuration not found: $WORKSPACE_FILE"

[ -d "$ARTIFACTS_DIR" ] || \
    fail \
        "artifact directory not found: $ARTIFACTS_DIR"

[ -d "$TOOLS_DIR" ] || \
    fail \
        "tools directory not found: $TOOLS_DIR"


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
    fail \
        "configuration directory not found: $CONFIG_DIR_CANDIDATE"


CONFIG_DIR="$(
    cd -- "$CONFIG_DIR_CANDIDATE"
    pwd -P
)"


# ----------------------------------------------------------------------
# Discover cluster documents
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


    if [ "$CONFIG_SCHEMA" = "$CLUSTER_SCHEMA" ]; then

        CLUSTER_FILES+=(
            "$CONFIG_FILE"
        )

    fi

done


# ----------------------------------------------------------------------
# Platform selection
#
# Default:
#   current host platform
#
# Explicit:
#   --platform windows-amd64
#
# Everything:
#   --all-platforms
# ----------------------------------------------------------------------

if [ "$ALL_PLATFORMS" -eq 0 ] &&
   [ -z "$PLATFORM_FILTER" ]
then

    PLATFORM_FILTER="$(
        detect_host_platform
    )"

    PLATFORM_DESCRIPTION="$PLATFORM_FILTER (current host)"


elif [ "$ALL_PLATFORMS" -eq 1 ]; then

    PLATFORM_DESCRIPTION="all cluster toolPlatforms"


else

    PLATFORM_DESCRIPTION="$PLATFORM_FILTER"

fi


# ----------------------------------------------------------------------
# Build unique installation plan
#
# Identity:
#
#   tool + version + platform
#
# Cluster name is only a consumer.
# ----------------------------------------------------------------------

PLAN_FILE="$(
    mktemp \
        "$RUNTIME_DIR/install-plan.XXXXXX"
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

        [ -n "$TOOL_NAME" ] || \
            continue


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
            --arg platformFilter "$PLATFORM_FILTER" \
            --argjson allPlatforms "$ALL_PLATFORMS" '

            .toolPlatforms[] as $platform

            |

            select(
                ($allPlatforms == 1)
                or
                $platform == $platformFilter
            )

            |

            .tools
            | to_entries[]

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

echo "$PROJECT_NAME tool installation"

echo
echo "Repository : $REPO_ROOT"
echo "Workspace  : $WORKSPACE_DIR"
echo "Config dir : $CONFIG_DIR"
echo "Artifacts  : $ARTIFACTS_DIR"
echo "Tools      : $TOOLS_DIR"
echo "Platform   : $PLATFORM_DESCRIPTION"

if [ "$DRY_RUN" -eq 1 ]; then
    echo "Mode       : dry-run"
else
    echo "Mode       : install"
fi


echo
echo "Installation plan:"
echo "  cluster bindings : $CLUSTER_BINDINGS"
echo "  unique tools     : $PLANNED"


if [ "$PLANNED" -eq 0 ]; then

    echo
    echo "Nothing to install."

    exit 0

fi


# ----------------------------------------------------------------------
# Install
# ----------------------------------------------------------------------

while IFS=$'\t' read -r \
    TOOL_NAME \
    TOOL_VERSION \
    TOOL_PLATFORM
do

    [ -n "$TOOL_NAME" ] || \
        continue


    safe_component "$TOOL_NAME" || \
        fail \
            "unsafe tool name: $TOOL_NAME"

    safe_component "$TOOL_VERSION" || \
        fail \
            "unsafe tool version: $TOOL_VERSION"

    safe_component "$TOOL_PLATFORM" || \
        fail \
            "unsafe tool platform: $TOOL_PLATFORM"


    REQUIREMENT_KEY="${TOOL_NAME}"$'\x1f'"${TOOL_VERSION}"$'\x1f'"${TOOL_PLATFORM}"


    REQUIRED_BY="$(
        sorted_cluster_list \
            "${REQUIREMENT_CLUSTERS[$REQUIREMENT_KEY]}"
    )"


    ARTIFACT_DIR="$ARTIFACTS_DIR/$TOOL_PLATFORM/$TOOL_NAME/$TOOL_VERSION"
    ARTIFACT_MANIFEST="$ARTIFACT_DIR/manifest.json"


    FINAL_PARENT="$TOOLS_DIR/$TOOL_PLATFORM/$TOOL_NAME"
    FINAL_DIR="$FINAL_PARENT/$TOOL_VERSION"


    echo

    printf '[%-8s] %s %s %s\n' \
        "PLAN" \
        "$TOOL_NAME" \
        "$TOOL_VERSION" \
        "$TOOL_PLATFORM"

    echo "  required by : $REQUIRED_BY"


    # ------------------------------------------------------------------
    # Artifact must already exist.
    # ------------------------------------------------------------------

    [ -d "$ARTIFACT_DIR" ] || \
        fail \
            "required artifact is missing: $ARTIFACT_DIR; run './kubebase.sh fetch --platform $TOOL_PLATFORM'"


    # ------------------------------------------------------------------
    # Reverify downloaded artifact before using it.
    # ------------------------------------------------------------------

    if ! verify_artifact_store \
        "$ARTIFACT_DIR" \
        "$TOOL_NAME" \
        "$TOOL_VERSION" \
        "$TOOL_PLATFORM"
    then

        fail \
            "artifact verification failed: $ARTIFACT_DIR"

    fi


    ARTIFACT_FILE="$(
        jq -r '
            .artifact.file
        ' "$ARTIFACT_MANIFEST"
    )"

    ARTIFACT_TYPE="$(
        jq -r '
            .artifact.type
        ' "$ARTIFACT_MANIFEST"
    )"

    SOURCE_BINARY="$(
        jq -r '
            .artifact.binary
        ' "$ARTIFACT_MANIFEST"
    )"

    ARTIFACT_SHA256="$(
        jq -r '
            .artifact.sha256
        ' "$ARTIFACT_MANIFEST"
    )"

    ARTIFACT_SHA256="${ARTIFACT_SHA256,,}"


    INSTALLED_FILE="$(
        installed_filename \
            "$TOOL_NAME" \
            "$SOURCE_BINARY"
    )"


    echo "  artifact    : verified"
    echo "  source      : $ARTIFACT_DIR/$ARTIFACT_FILE"


    # ------------------------------------------------------------------
    # Existing installation
    # ------------------------------------------------------------------

    if [ -d "$FINAL_DIR" ]; then

        if verify_existing_install \
            "$FINAL_DIR" \
            "$TOOL_NAME" \
            "$TOOL_VERSION" \
            "$TOOL_PLATFORM" \
            "$ARTIFACT_SHA256"
        then

            echo "  status      : already installed in shared store"
            echo "  location    : $FINAL_DIR/$INSTALLED_FILE"

            EXISTING=$((EXISTING + 1))

            continue

        fi


        fail \
            "existing tool installation is incomplete or corrupt: $FINAL_DIR"

    fi


    if [ -e "$FINAL_DIR" ]; then

        fail \
            "tool destination exists and is not a directory: $FINAL_DIR"

    fi


    # ------------------------------------------------------------------
    # Dry run stops before filesystem mutation.
    # ------------------------------------------------------------------

    if [ "$DRY_RUN" -eq 1 ]; then

        echo "  status      : would install"
        echo "  location    : $FINAL_DIR/$INSTALLED_FILE"

        continue

    fi


    # ------------------------------------------------------------------
    # Temporary staging directory
    # ------------------------------------------------------------------

    ACTIVE_STAGE="$(
        mktemp -d \
            "$TOOLS_DIR/.install-${TOOL_NAME}-${TOOL_PLATFORM}.XXXXXX"
    )"


    STAGED_BINARY="$ACTIVE_STAGE/$INSTALLED_FILE"


    # ------------------------------------------------------------------
    # Extract/copy only the declared binary.
    #
    # We do not unpack whole archives into the workspace.
    # ------------------------------------------------------------------

    case "$ARTIFACT_TYPE" in

        binary)

            cp \
                -- "$ARTIFACT_DIR/$ARTIFACT_FILE" \
                "$STAGED_BINARY"
            ;;


        tar.gz)

            command -v tar >/dev/null 2>&1 || \
                fail \
                    "tar is required to install $TOOL_NAME"


            TAR_MEMBER="$(
                find_tar_member \
                    "$ARTIFACT_DIR/$ARTIFACT_FILE" \
                    "$SOURCE_BINARY"
            )"


            [ -n "$TAR_MEMBER" ] || \
                fail \
                    "binary '$SOURCE_BINARY' not found in archive: $ARTIFACT_FILE"


            tar \
                --warning=no-unknown-keyword \
                -xOzf "$ARTIFACT_DIR/$ARTIFACT_FILE" \
                -- "$TAR_MEMBER" \
                > "$STAGED_BINARY"
            ;;


        zip)

            command -v unzip >/dev/null 2>&1 || \
                fail \
                    "unzip is required to install $TOOL_NAME"


            ZIP_MEMBER="$(
                find_zip_member \
                    "$ARTIFACT_DIR/$ARTIFACT_FILE" \
                    "$SOURCE_BINARY"
            )"


            [ -n "$ZIP_MEMBER" ] || \
                fail \
                    "binary '$SOURCE_BINARY' not found in archive: $ARTIFACT_FILE"


            unzip \
                -p "$ARTIFACT_DIR/$ARTIFACT_FILE" \
                "$ZIP_MEMBER" \
                > "$STAGED_BINARY"
            ;;


        *)

            fail \
                "unsupported artifact type '$ARTIFACT_TYPE' for $TOOL_NAME"
            ;;

    esac


    # ------------------------------------------------------------------
    # Extracted binary validation
    # ------------------------------------------------------------------

    [ -s "$STAGED_BINARY" ] || \
        fail \
            "installed binary is empty: $TOOL_NAME $TOOL_VERSION $TOOL_PLATFORM"


    chmod 755 \
        "$STAGED_BINARY"


    BINARY_SHA256="$(
        sha256sum "$STAGED_BINARY" |
        awk '{print $1}'
    )"

    BINARY_SHA256="${BINARY_SHA256,,}"


    # ------------------------------------------------------------------
    # Installation manifest
    #
    # This links the installed binary to the verified source artifact.
    # requiredBy is intentionally not stored.
    # ------------------------------------------------------------------

    jq -n \
        --arg schema "$INSTALL_SCHEMA" \
        --argjson schemaVersion "$INSTALL_SCHEMA_VERSION" \
        --arg tool "$TOOL_NAME" \
        --arg version "$TOOL_VERSION" \
        --arg platform "$TOOL_PLATFORM" \
        --arg artifactSha256 "$ARTIFACT_SHA256" \
        --arg artifactFile "$ARTIFACT_FILE" \
        --arg sourceBinary "$SOURCE_BINARY" \
        --arg binaryFile "$INSTALLED_FILE" \
        --arg binarySha256 "$BINARY_SHA256" '

        {
            schema: $schema,
            schemaVersion: $schemaVersion,

            tool: $tool,
            version: $version,
            platform: $platform,

            artifact: {
                file: $artifactFile,
                sha256: $artifactSha256
            },

            binary: {
                sourcePath: $sourceBinary,
                file: $binaryFile,
                sha256: $binarySha256
            }
        }

    ' > "$ACTIVE_STAGE/manifest.json"


    chmod 644 \
        "$ACTIVE_STAGE/manifest.json"

    chmod 755 \
        "$ACTIVE_STAGE"


    # ------------------------------------------------------------------
    # Atomic commit
    # ------------------------------------------------------------------

    mkdir -p \
        -- "$FINAL_PARENT"


    if [ -e "$FINAL_DIR" ]; then

        fail \
            "tool destination appeared during installation: $FINAL_DIR"

    fi


    mv \
        -- "$ACTIVE_STAGE" \
        "$FINAL_DIR"


    ACTIVE_STAGE=""


    echo "  binary      : $INSTALLED_FILE"
    echo "  sha256      : $BINARY_SHA256"
    echo "  status      : installed and verified"
    echo "  location    : $FINAL_DIR/$INSTALLED_FILE"


    INSTALLED=$((INSTALLED + 1))

done < "$PLAN_FILE"


# ----------------------------------------------------------------------
# Result
# ----------------------------------------------------------------------

echo
echo "Tool installation complete."

echo
echo "Summary:"
echo "  cluster bindings : $CLUSTER_BINDINGS"
echo "  unique tools     : $PLANNED"
echo "  installed        : $INSTALLED"
echo "  existing         : $EXISTING"

if [ "$DRY_RUN" -eq 1 ]; then
    echo "  mode             : dry-run"
fi
