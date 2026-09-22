#!/usr/bin/env bash

set -euo pipefail

# ----------------------------------------------------------------------
# KubeBase
# Step 55 - Authentication dependency preparation
# Linux
#
# OIDC is the only authentication mode with a KubeBase-managed external
# dependency. When a profile declares auth.type=oidc, this step ensures the
# cluster-scoped Krew environment contains oidc-login.
#
# KubeBase does not enumerate, upgrade, remove, or otherwise manage arbitrary
# user-installed Krew plugins. Krew owns everything below KREW_ROOT.
# ----------------------------------------------------------------------

PROJECT_NAME="KubeBase"
CLUSTER_SCHEMA="kubebase.cluster"
CLUSTER_SCHEMA_VERSION=1
DEFAULT_WORKSPACE_NAME="kubebase-workspace"

SCRIPT_DIR="$(
    cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
    pwd -P
)"

LIB_DIR="$SCRIPT_DIR/lib"
source "$LIB_DIR/common.sh"
source "$LIB_DIR/workspace.sh"
source "$LIB_DIR/oidc.sh"
source "$LIB_DIR/tool-integrity.sh"

REPO_ROOT="$(
    cd -- "$SCRIPT_DIR/../.."
    pwd -P
)"
REPO_PARENT="$(dirname -- "$REPO_ROOT")"
DEFAULT_WORKSPACE_ROOT="$REPO_PARENT"
CONFIG_VALIDATOR="$SCRIPT_DIR/10-validate-config.sh"

WORKSPACE_NAME="$DEFAULT_WORKSPACE_NAME"
WORKSPACE_ROOT="$DEFAULT_WORKSPACE_ROOT"
CHECK_ONLY=0

OIDC_PROFILES=0
KREW_ENVIRONMENTS=0
PLUGIN_INSTALLED=0
PLUGIN_EXISTING=0
PLUGIN_MISSING=0
ERRORS=0


usage()
{
    cat <<EOF_USAGE
$PROJECT_NAME authentication preparation

Usage:
  kubebase auth prepare [options]

Options:
  --check
      Verify declared authentication dependencies without changing Krew
      state and without network access.

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
  kubebase auth prepare
  kubebase auth prepare --check
EOF_USAGE
}


record_error()
{
    echo "ERROR: $*" >&2
    ERRORS=$((ERRORS + 1))
}


ensure_directory_not_symlink()
{
    local path="$1"
    local description="$2"

    if [ -L "$path" ]; then
        record_error "$description must not be a symlink: $path"
        return 1
    fi

    if [ -e "$path" ] && [ ! -d "$path" ]; then
        record_error "$description is not a directory: $path"
        return 1
    fi

    if [ ! -d "$path" ]; then
        mkdir -- "$path"
    fi
}


while [ "$#" -gt 0 ]; do
    case "$1" in
        --check)
            CHECK_ONLY=1
            shift
            ;;

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

command -v jq >/dev/null 2>&1 || kb_fail "jq is required"
command -v sha256sum >/dev/null 2>&1 || kb_fail "sha256sum is required"

kb_safe_name "$WORKSPACE_NAME" || kb_fail "invalid workspace name: $WORKSPACE_NAME"
[ -d "$WORKSPACE_ROOT" ] || kb_fail "workspace root not found: $WORKSPACE_ROOT"

WORKSPACE_ROOT="$(cd -- "$WORKSPACE_ROOT" && pwd -P)"
WORKSPACE_DIR="$WORKSPACE_ROOT/$WORKSPACE_NAME"
WORKSPACE_FILE="$WORKSPACE_DIR/workspace.json"
ARTIFACTS_DIR="$WORKSPACE_DIR/artifacts"
TOOLS_DIR="$WORKSPACE_DIR/tools"
KREW_DIR="$WORKSPACE_DIR/krew"

kb_require_readable_file "$WORKSPACE_FILE" "workspace configuration"
[ -d "$ARTIFACTS_DIR" ] || kb_fail "artifact directory not found: $ARTIFACTS_DIR"
[ -d "$TOOLS_DIR" ] || kb_fail "tools directory not found: $TOOLS_DIR"

"$CONFIG_VALIDATOR" \
    --workspace-name "$WORKSPACE_NAME" \
    --workspace-root "$WORKSPACE_ROOT" \
    --quiet

CONFIG_DIR="$(kb_workspace_config_dir "$WORKSPACE_DIR" "$WORKSPACE_FILE")" || \
    kb_fail "configuration directory could not be resolved"

HOST_PLATFORM="$(kb_detect_host_platform "authentication preparation")"
mapfile -d '' -t CLUSTER_FILES < <(
    kb_config_cluster_files \
        "$CONFIG_DIR" \
        "$CLUSTER_SCHEMA" \
        "$CLUSTER_SCHEMA_VERSION"
)

if [ "$CHECK_ONLY" -eq 0 ]; then
    if [ -L "$KREW_DIR" ]; then
        kb_fail "Krew workspace root must not be a symlink: $KREW_DIR"
    fi
    if [ -e "$KREW_DIR" ] && [ ! -d "$KREW_DIR" ]; then
        kb_fail "Krew workspace root is not a directory: $KREW_DIR"
    fi
    if [ ! -d "$KREW_DIR" ]; then
        mkdir -- "$KREW_DIR"
    fi
fi

echo "$PROJECT_NAME authentication preparation"
echo
echo "Repository : $REPO_ROOT"
echo "Workspace  : $WORKSPACE_DIR"
echo "Config dir : $CONFIG_DIR"
echo "Platform   : $HOST_PLATFORM"
if [ "$CHECK_ONLY" -eq 1 ]; then
    echo "Mode       : check only"
else
    echo "Mode       : prepare"
fi

for CLUSTER_FILE in "${CLUSTER_FILES[@]}"; do
    CLUSTER_NAME="$(jq -r '.name' "$CLUSTER_FILE")"

    mapfile -t OIDC_USERS < <(
        jq -r '
            .users
            | to_entries[]
            | select(.value.auth?.type == "oidc")
            | .key
        ' "$CLUSTER_FILE"
    )

    KREW_ENABLED=0
    if jq -e '
        (.tools.krew? | type) == "object"
        and (.tools.krew.enabled? != false)
    ' "$CLUSTER_FILE" >/dev/null 2>&1; then
        KREW_ENABLED=1
    fi

    [ "$KREW_ENABLED" -eq 1 ] || continue

    OIDC_PROFILES=$((OIDC_PROFILES + ${#OIDC_USERS[@]}))
    KREW_ENVIRONMENTS=$((KREW_ENVIRONMENTS + 1))

    echo
    echo "Cluster: $CLUSTER_NAME"
    if [ "${#OIDC_USERS[@]}" -gt 0 ]; then
        echo "  OIDC users : ${OIDC_USERS[*]}"
    else
        echo "  OIDC users : none"
    fi

    KREW_VERSION="$(jq -r '.tools.krew.version' "$CLUSTER_FILE")"
    echo "  krew       : $KREW_VERSION"

    if ! kb_verify_installed_tool_source_bound \
        "$WORKSPACE_DIR" \
        "krew" \
        "$KREW_VERSION" \
        "$HOST_PLATFORM"
    then
        record_error "cluster '$CLUSTER_NAME': required Krew $KREW_VERSION $HOST_PLATFORM is missing or not source-bound; run: kubebase fetch && kubebase install"
        continue
    fi

    KREW_BIN="$KB_VERIFIED_TOOL_BINARY"
    NEW_ROOT="$(kb_krew_root_for_cluster "$WORKSPACE_DIR" "$CLUSTER_NAME" "$HOST_PLATFORM")"
    PLUGIN_PATH="$(kb_oidc_plugin_path "$NEW_ROOT")"

    echo "  KREW_ROOT  : $NEW_ROOT"

    if [ -e "$NEW_ROOT" ] && [ -L "$NEW_ROOT" ]; then
        record_error "cluster '$CLUSTER_NAME': KREW_ROOT must not be a symlink: $NEW_ROOT"
        continue
    fi

    # No legacy Krew-root migration is supported. KubeBase is not released yet,
    # so workspace/krew/<cluster>/<platform> is the only accepted persistent
    # layout. Older development roots may simply be removed and recreated.

    if [ "$CHECK_ONLY" -eq 0 ]; then
        CLUSTER_KREW_PARENT="$(dirname -- "$NEW_ROOT")"
        mkdir -p -- "$CLUSTER_KREW_PARENT"

        if [ ! -d "$NEW_ROOT" ]; then
            mkdir -- "$NEW_ROOT"
        fi

        chmod 700 "$NEW_ROOT"
        mkdir -p -- "$NEW_ROOT/bin"
    fi

    # Krew environments without OIDC remain entirely user-managed. The only
    # KubeBase-managed plugin dependency is oidc-login for declared OIDC users.
    if [ "${#OIDC_USERS[@]}" -eq 0 ]; then
        echo "  oidc-login : not required"
        continue
    fi

    if [ -x "$PLUGIN_PATH" ]; then
        PLUGIN_EXISTING=$((PLUGIN_EXISTING + 1))
        echo "  oidc-login : ready"
        continue
    fi

    if [ "$CHECK_ONLY" -eq 1 ]; then
        PLUGIN_MISSING=$((PLUGIN_MISSING + 1))
        echo "  oidc-login : MISSING"
        record_error "cluster '$CLUSTER_NAME': OIDC requires oidc-login; run: kubebase auth prepare"
        continue
    fi

    command -v git >/dev/null 2>&1 || {
        record_error "cluster '$CLUSTER_NAME': git is required by Krew to initialize/update its plugin index"
        continue
    }

    echo "  oidc-login : installing"

    if ! KREW_ROOT="$NEW_ROOT" "$KREW_BIN" install oidc-login; then
        record_error "cluster '$CLUSTER_NAME': failed to install Krew plugin 'oidc-login'"
        continue
    fi

    if [ ! -x "$PLUGIN_PATH" ]; then
        record_error "cluster '$CLUSTER_NAME': Krew reported success but oidc-login is not executable at $PLUGIN_PATH"
        continue
    fi

    PLUGIN_INSTALLED=$((PLUGIN_INSTALLED + 1))
    echo "  oidc-login : installed"
done

echo
echo "Authentication preparation complete."
echo
echo "Summary:"
echo "  OIDC profiles     : $OIDC_PROFILES"
echo "  Krew environments : $KREW_ENVIRONMENTS"
echo "  oidc-login ready  : $PLUGIN_EXISTING"
echo "  oidc-login install: $PLUGIN_INSTALLED"
echo "  oidc-login missing: $PLUGIN_MISSING"
echo "  errors            : $ERRORS"

if [ "$ERRORS" -ne 0 ]; then
    echo
    echo "Authentication preparation FAILED."
    exit 1
fi

echo
echo "Authentication preparation OK"
