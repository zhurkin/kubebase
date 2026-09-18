#!/usr/bin/env bash

set -euo pipefail


# ----------------------------------------------------------------------
# KubeBase
# Step 60 - Environment validation
# Linux
#
# Online, read-only Kubernetes validation.
#
# For each configured cluster/user:
#
#   selected context
#       ↓
#   API connectivity/authentication
#       ↓
#   effective KubeBase environments
#       ↓
#   namespace visibility
#       ↓
#   Kubernetes authorization review
#
# Context selection is identical to Step 50:
#
#   users.<name>.context
#           ↓ if absent
#   kubeconfig current-context
#
# The kubeconfig is never modified.
# ----------------------------------------------------------------------

PROJECT_NAME="KubeBase"

CLUSTER_SCHEMA="kubebase.cluster"

DEFAULT_WORKSPACE_NAME="kubebase-workspace"
DEFAULT_REQUEST_TIMEOUT="10s"


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

USER_VALIDATOR="$SCRIPT_DIR/50-validate-users.sh"


# ----------------------------------------------------------------------
# Defaults
# ----------------------------------------------------------------------

WORKSPACE_NAME="$DEFAULT_WORKSPACE_NAME"
WORKSPACE_ROOT="$DEFAULT_WORKSPACE_ROOT"

REQUEST_TIMEOUT="$DEFAULT_REQUEST_TIMEOUT"


# ----------------------------------------------------------------------
# Counters
# ----------------------------------------------------------------------

CLUSTERS=0
USERS=0
ENVIRONMENTS=0

READY=0
PARTIAL=0
INVALID=0
SKIPPED=0

API_FAILURES=0

WARNINGS=0
ERRORS=0


# ----------------------------------------------------------------------
# Runtime
# ----------------------------------------------------------------------

CONFIG_FILES=()
CLUSTER_FILES=()

TEMP_DIR=""


# ----------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------

fail()
{
    echo "ERROR: $*" >&2
    exit 1
}


record_error()
{
    echo "ERROR: $*" >&2
    ERRORS=$((ERRORS + 1))
}


record_warning()
{
    echo "WARNING: $*" >&2
    WARNINGS=$((WARNINGS + 1))
}


cleanup()
{
    if [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ]; then
        rm -rf -- "$TEMP_DIR"
    fi
}


trap cleanup EXIT HUP INT TERM


usage()
{
    cat <<EOF_USAGE
$PROJECT_NAME environment validation

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

  --request-timeout DURATION
      Kubernetes request timeout.

      Default:
        $DEFAULT_REQUEST_TIMEOUT

      Example:
        5s
        15s
        1m

  -h, --help
      Show this help.

Examples:
  $(basename "$0")

  $(basename "$0") --request-timeout 5s
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
                "unsupported host operating system: $(uname -s)"
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


first_error_line()
{
    local file="$1"

    awk '
        NF {
            print
            exit
        }
    ' "$file"
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


        --request-timeout)

            [ "$#" -ge 2 ] || {
                echo "ERROR: --request-timeout requires a value" >&2
                exit 2
            }

            REQUEST_TIMEOUT="$2"

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

command -v mktemp >/dev/null 2>&1 || \
    fail "mktemp is required"


[ -x "$USER_VALIDATOR" ] || \
    fail \
        "user validator not found or not executable: $USER_VALIDATOR"


# ----------------------------------------------------------------------
# Local preflight
#
# Step 50 must succeed before Step 60 performs any network requests.
# ----------------------------------------------------------------------

"$USER_VALIDATOR" \
    --workspace-name "$WORKSPACE_NAME" \
    --workspace-root "$WORKSPACE_ROOT" \
    >/dev/null


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

CLUSTERS_DIR="$WORKSPACE_DIR/clusters"
TOOLS_DIR="$WORKSPACE_DIR/tools"
RUNTIME_DIR="$WORKSPACE_DIR/runtime"


[ -f "$WORKSPACE_FILE" ] || \
    fail \
        "workspace configuration not found: $WORKSPACE_FILE"

[ -d "$CLUSTERS_DIR" ] || \
    fail \
        "cluster directory not found: $CLUSTERS_DIR"

[ -d "$TOOLS_DIR" ] || \
    fail \
        "tools directory not found: $TOOLS_DIR"

[ -d "$RUNTIME_DIR" ] || \
    fail \
        "runtime directory not found: $RUNTIME_DIR"


HOST_PLATFORM="$(
    detect_host_platform
)"


TEMP_DIR="$(
    mktemp -d \
        "$RUNTIME_DIR/environment-validation.XXXXXX"
)"


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
# Header
# ----------------------------------------------------------------------

echo "$PROJECT_NAME environment validation"

echo
echo "Repository : $REPO_ROOT"
echo "Workspace  : $WORKSPACE_DIR"
echo "Config dir : $CONFIG_DIR"
echo "Clusters   : $CLUSTERS_DIR"
echo "Tools      : $TOOLS_DIR"
echo "Platform   : $HOST_PLATFORM"
echo "Network    : enabled"
echo "Timeout    : $REQUEST_TIMEOUT"


# ----------------------------------------------------------------------
# Clusters
# ----------------------------------------------------------------------

for CLUSTER_FILE in "${CLUSTER_FILES[@]}"; do

    CLUSTER_NAME="$(
        jq -r '
            .name
        ' "$CLUSTER_FILE"
    )"


    CLUSTERS=$((CLUSTERS + 1))


    CLUSTER_DIR="$CLUSTERS_DIR/$CLUSTER_NAME"


    KUBECTL_VERSION="$(
        jq -r '
            .tools.kubectl.version
        ' "$CLUSTER_FILE"
    )"


    KUBECTL_DIR="$TOOLS_DIR/$HOST_PLATFORM/kubectl/$KUBECTL_VERSION"
    KUBECTL_MANIFEST="$KUBECTL_DIR/manifest.json"


    [ -f "$KUBECTL_MANIFEST" ] || \
        fail \
            "verified kubectl installation is missing for cluster '$CLUSTER_NAME'"


    KUBECTL_FILE="$(
        jq -r '
            .binary.file
        ' "$KUBECTL_MANIFEST"
    )"


    KUBECTL_BIN="$KUBECTL_DIR/$KUBECTL_FILE"


    [ -x "$KUBECTL_BIN" ] || \
        fail \
            "kubectl binary is missing or not executable: $KUBECTL_BIN"


    echo
    echo "Cluster: $CLUSTER_NAME"
    echo "  kubectl      : $KUBECTL_VERSION"


    mapfile -t USER_NAMES < <(

        jq -r '
            .users
            | keys[]
        ' "$CLUSTER_FILE"

    )


    for USER_NAME in "${USER_NAMES[@]}"; do

        USERS=$((USERS + 1))


        USER_DIR="$CLUSTER_DIR/users/$USER_NAME"


        KUBECONFIG_REL="$(
            jq -r \
                --arg user "$USER_NAME" '
                .users[$user].kubeconfig
            ' "$CLUSTER_FILE"
        )"


        KUBECONFIG_FILE="$USER_DIR/$KUBECONFIG_REL"


        DECLARED_CONTEXT="$(
            jq -r \
                --arg user "$USER_NAME" '
                .users[$user].context // ""
            ' "$CLUSTER_FILE"
        )"


        # --------------------------------------------------------------
        # Determine selected context.
        #
        # Step 50 already verified that it exists.
        # --------------------------------------------------------------

        if [ -n "$DECLARED_CONTEXT" ]; then

            SELECTED_CONTEXT="$DECLARED_CONTEXT"
            CONTEXT_SELECTION="KubeBase user.context"

        else

            SELECTED_CONTEXT="$(
                "$KUBECTL_BIN" \
                    --kubeconfig "$KUBECONFIG_FILE" \
                    config current-context
            )"

            CONTEXT_SELECTION="kubeconfig current-context"

        fi


        # --------------------------------------------------------------
        # Local kubeconfig view for endpoint information.
        # --------------------------------------------------------------

        KUBECONFIG_JSON="$(
            "$KUBECTL_BIN" \
                --kubeconfig "$KUBECONFIG_FILE" \
                config view \
                -o json
        )"


        CONTEXT_CLUSTER="$(
            jq -r \
                --arg context "$SELECTED_CONTEXT" '

                .contexts[]
                |
                select(.name == $context)
                |
                .context.cluster

            ' <<< "$KUBECONFIG_JSON"
        )"


        API_SERVER="$(
            jq -r \
                --arg cluster "$CONTEXT_CLUSTER" '

                .clusters[]
                |
                select(.name == $cluster)
                |
                .cluster.server

            ' <<< "$KUBECONFIG_JSON"
        )"


        echo
        echo "  User: $USER_NAME"
        echo "    kubeconfig   : $KUBECONFIG_FILE"
        echo "    context      : $SELECTED_CONTEXT"
        echo "    selection    : $CONTEXT_SELECTION"
        echo "    api server   : $API_SERVER"


        # --------------------------------------------------------------
        # Effective environments
        # --------------------------------------------------------------

        mapfile -t ENVIRONMENT_NAMES < <(

            jq -r \
                --arg user "$USER_NAME" '

                def ordered_unique:
                    reduce .[] as $item
                        (
                            [];

                            if index($item) == null then
                                . + [$item]
                            else
                                .
                            end
                        );

                . as $root

                |

                (
                    [
                        (
                            $root.users[$user].access.profiles
                            // []
                        )[] as $profile

                        |

                        (
                            $root.accessProfiles[$profile].environments
                            // []
                        )[]
                    ]

                    +

                    (
                        $root.users[$user].access.environments
                        // []
                    )
                )

                | ordered_unique
                | .[]

            ' "$CLUSTER_FILE"

        )


        # --------------------------------------------------------------
        # API connectivity + authentication
        #
        # This is a read-only request to /version.
        # --------------------------------------------------------------

        API_ERROR_FILE="$TEMP_DIR/api-error.txt"

        : > "$API_ERROR_FILE"


        if API_VERSION_JSON="$(
            "$KUBECTL_BIN" \
                --kubeconfig "$KUBECONFIG_FILE" \
                --context "$SELECTED_CONTEXT" \
                --request-timeout="$REQUEST_TIMEOUT" \
                get \
                --raw=/version \
                2>"$API_ERROR_FILE"
        )"
        then

            API_GIT_VERSION="$(
                jq -r '
                    .gitVersion // "unknown"
                ' <<< "$API_VERSION_JSON"
            )"

            echo "    api status   : OK"
            echo "    server ver   : $API_GIT_VERSION"


        else

            API_ERROR="$(
                first_error_line \
                    "$API_ERROR_FILE"
            )"


            echo "    api status   : FAILED"


            record_error \
                "cluster '$CLUSTER_NAME' user '$USER_NAME': Kubernetes API request failed: $API_ERROR"

            API_FAILURES=$((API_FAILURES + 1))


            for ENVIRONMENT_NAME in "${ENVIRONMENT_NAMES[@]}"; do

                ENVIRONMENTS=$((ENVIRONMENTS + 1))
                SKIPPED=$((SKIPPED + 1))


                NAMESPACE="$(
                    jq -r \
                        --arg environment "$ENVIRONMENT_NAME" '
                        .environments[$environment].namespace
                    ' "$CLUSTER_FILE"
                )"


                echo
                echo "    Environment: $ENVIRONMENT_NAME"
                echo "      namespace    : $NAMESPACE"
                echo "      status       : SKIPPED (API unreachable)"

            done


            continue

        fi


        # --------------------------------------------------------------
        # Environments
        # --------------------------------------------------------------

        for ENVIRONMENT_NAME in "${ENVIRONMENT_NAMES[@]}"; do

            ENVIRONMENTS=$((ENVIRONMENTS + 1))


            NAMESPACE="$(
                jq -r \
                    --arg environment "$ENVIRONMENT_NAME" '
                    .environments[$environment].namespace
                ' "$CLUSTER_FILE"
            )"


            ENV_PARTIAL=0
            ENV_INVALID=0


            echo
            echo "    Environment: $ENVIRONMENT_NAME"
            echo "      namespace    : $NAMESPACE"


            # ----------------------------------------------------------
            # Namespace object probe
            #
            # Namespaced users often do NOT have permission to read the
            # Namespace object itself.
            #
            # Therefore:
            #
            #   success   -> VERIFIED
            #   NotFound  -> error
            #   Forbidden -> PARTIAL, not an error
            # ----------------------------------------------------------

            NAMESPACE_ERROR_FILE="$TEMP_DIR/namespace-error.txt"

            : > "$NAMESPACE_ERROR_FILE"


            if "$KUBECTL_BIN" \
                --kubeconfig "$KUBECONFIG_FILE" \
                --context "$SELECTED_CONTEXT" \
                --request-timeout="$REQUEST_TIMEOUT" \
                get namespace "$NAMESPACE" \
                -o name \
                >/dev/null \
                2>"$NAMESPACE_ERROR_FILE"
            then

                echo "      namespace obj: VERIFIED"


            else

                NAMESPACE_ERROR="$(
                    cat "$NAMESPACE_ERROR_FILE"
                )"


                if grep -qi \
                    'not found' \
                    "$NAMESPACE_ERROR_FILE"
                then

                    echo "      namespace obj: NOT FOUND"

                    record_error \
                        "cluster '$CLUSTER_NAME' user '$USER_NAME' environment '$ENVIRONMENT_NAME': namespace '$NAMESPACE' was not found"

                    ENV_INVALID=1


                elif grep -qi \
                    'forbidden' \
                    "$NAMESPACE_ERROR_FILE"
                then

                    echo "      namespace obj: UNVERIFIED (forbidden)"

                    record_warning \
                        "cluster '$CLUSTER_NAME' user '$USER_NAME' environment '$ENVIRONMENT_NAME': namespace object '$NAMESPACE' cannot be read; namespaced access may still be valid"

                    ENV_PARTIAL=1


                else

                    NAMESPACE_ERROR_LINE="$(
                        first_error_line \
                            "$NAMESPACE_ERROR_FILE"
                    )"

                    echo "      namespace obj: FAILED"

                    record_error \
                        "cluster '$CLUSTER_NAME' user '$USER_NAME' environment '$ENVIRONMENT_NAME': namespace probe failed: $NAMESPACE_ERROR_LINE"

                    ENV_INVALID=1

                fi

            fi


            # ----------------------------------------------------------
            # SelfSubjectRulesReview via kubectl auth can-i --list
            #
            # We do NOT interpret this as proof of any particular
            # required permission.
            #
            # It only verifies that Kubernetes can evaluate the current
            # user's authorization rules for this namespace.
            # ----------------------------------------------------------

            AUTH_ERROR_FILE="$TEMP_DIR/auth-error.txt"

            : > "$AUTH_ERROR_FILE"


            if "$KUBECTL_BIN" \
                --kubeconfig "$KUBECONFIG_FILE" \
                --context "$SELECTED_CONTEXT" \
                --request-timeout="$REQUEST_TIMEOUT" \
                auth can-i \
                --list \
                --namespace "$NAMESPACE" \
                >/dev/null \
                2>"$AUTH_ERROR_FILE"
            then

                echo "      auth review  : OK"


            else

                AUTH_ERROR_LINE="$(
                    first_error_line \
                        "$AUTH_ERROR_FILE"
                )"


                echo "      auth review  : UNAVAILABLE"

                record_warning \
                    "cluster '$CLUSTER_NAME' user '$USER_NAME' environment '$ENVIRONMENT_NAME': authorization review unavailable: $AUTH_ERROR_LINE"

                ENV_PARTIAL=1

            fi


            # ----------------------------------------------------------
            # Environment result
            # ----------------------------------------------------------

            if [ "$ENV_INVALID" -ne 0 ]; then

                INVALID=$((INVALID + 1))

                echo "      status       : NOT READY"


            elif [ "$ENV_PARTIAL" -ne 0 ]; then

                PARTIAL=$((PARTIAL + 1))

                echo "      status       : PARTIAL"


            else

                READY=$((READY + 1))

                echo "      status       : READY"

            fi

        done

    done

done


# ----------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------

echo
echo "Environment validation complete."

echo
echo "Summary:"
echo "  clusters     : $CLUSTERS"
echo "  users        : $USERS"
echo "  environments : $ENVIRONMENTS"
echo "  ready        : $READY"
echo "  partial      : $PARTIAL"
echo "  invalid      : $INVALID"
echo "  skipped      : $SKIPPED"
echo "  api failures : $API_FAILURES"
echo "  warnings     : $WARNINGS"
echo "  errors       : $ERRORS"


if [ "$ERRORS" -ne 0 ]; then

    echo
    echo "Validation FAILED."

    exit 1

fi


if [ "$WARNINGS" -ne 0 ]; then

    echo
    echo "Validation OK with warnings."

else

    echo
    echo "Validation OK"

fi
