#!/usr/bin/env bash

set -euo pipefail


# ----------------------------------------------------------------------
# KubeBase
# Step 50 - User / kubeconfig validation
# Linux
#
# Completely local validation.
# No Kubernetes API requests are made.
#
# Context selection:
#
#   users.<name>.context
#           ↓ if absent
#   kubeconfig current-context
#
# A kubeconfig may contain multiple contexts/endpoints.
# They remain part of one logical KubeBase cluster/user definition.
# ----------------------------------------------------------------------

PROJECT_NAME="KubeBase"

CLUSTER_SCHEMA="kubebase.cluster"

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


# ----------------------------------------------------------------------
# Counters
# ----------------------------------------------------------------------

CLUSTERS=0
USERS=0

READY=0
INVALID=0

WARNINGS=0
ERRORS=0


# ----------------------------------------------------------------------
# Runtime
# ----------------------------------------------------------------------

CONFIG_FILES=()
CLUSTER_FILES=()


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


usage()
{
    cat <<EOF_USAGE
$PROJECT_NAME user validation

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
            fail "unsupported host operating system: $(uname -s)"
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


safe_filename()
{
    local value="$1"

    [[ "$value" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]]
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

    mode="$(
        stat -Lc '%a' "$path"
    )"

    [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1

    mode_value=$((8#$mode))

    (( (mode_value & 077) == 0 ))
}


file_mode()
{
    stat -Lc '%a' "$1"
}


credential_summary()
{
    local json="$1"

    jq -r '
        [
            (
                if
                    ((."client-certificate" // "") != "")
                    or
                    ((."client-certificate-data" // "") != "")
                then
                    "client-certificate"
                else
                    empty
                end
            ),

            (
                if ((.token // "") != "") then
                    "token"
                else
                    empty
                end
            ),

            (
                if ((.tokenFile // "") != "") then
                    "token-file"
                else
                    empty
                end
            ),

            (
                if (.exec? | type) == "object" then
                    "exec"
                else
                    empty
                end
            ),

            (
                if (."auth-provider"? | type) == "object" then
                    "auth-provider"
                else
                    empty
                end
            ),

            (
                if
                    ((.username // "") != "")
                    or
                    ((.password // "") != "")
                then
                    "basic-auth"
                else
                    empty
                end
            )
        ]

        |

        if length == 0 then
            "none"
        else
            join(", ")
        end
    ' <<< "$json"
}


# ----------------------------------------------------------------------
# Installed kubectl verification
# ----------------------------------------------------------------------

verify_installed_kubectl()
{
    local dir="$1"
    local requested_version="$2"
    local requested_platform="$3"

    local manifest="$dir/manifest.json"

    local binary_file
    local expected_sha256
    local actual_sha256

    [ -f "$manifest" ] || return 1

    if ! jq -e \
        --arg schema "$INSTALL_SCHEMA" \
        --argjson schemaVersion "$INSTALL_SCHEMA_VERSION" \
        --arg version "$requested_version" \
        --arg platform "$requested_platform" '

        .schema == $schema
        and
        .schemaVersion == $schemaVersion

        and

        .tool == "kubectl"
        and
        .version == $version
        and
        .platform == $platform

        and

        (.binary.file | type) == "string"
        and
        (.binary.sha256 | type) == "string"

    ' "$manifest" >/dev/null 2>&1
    then
        return 1
    fi

    binary_file="$(
        jq -r '.binary.file' "$manifest"
    )"

    expected_sha256="$(
        jq -r '.binary.sha256' "$manifest"
    )"

    expected_sha256="${expected_sha256,,}"

    safe_filename "$binary_file" || return 1

    [ -f "$dir/$binary_file" ] || return 1
    [ -x "$dir/$binary_file" ] || return 1

    actual_sha256="$(
        sha256sum "$dir/$binary_file" |
        awk '{print $1}'
    )"

    actual_sha256="${actual_sha256,,}"

    [ "$actual_sha256" = "$expected_sha256" ]
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


        -h|--help)
            usage
            exit 0
            ;;


        *)
            echo "ERROR: unknown argument: $1" >&2
            exit 2
            ;;

    esac

done


# ----------------------------------------------------------------------
# Prerequisites
# ----------------------------------------------------------------------

command -v jq >/dev/null 2>&1 || fail "jq is required"
command -v sha256sum >/dev/null 2>&1 || fail "sha256sum is required"
command -v stat >/dev/null 2>&1 || fail "stat is required"

[ -x "$CONFIG_VALIDATOR" ] || \
    fail "configuration validator not found: $CONFIG_VALIDATOR"


# ----------------------------------------------------------------------
# Configuration preflight
# ----------------------------------------------------------------------

"$CONFIG_VALIDATOR" \
    --workspace-name "$WORKSPACE_NAME" \
    --workspace-root "$WORKSPACE_ROOT" \
    --quiet


# ----------------------------------------------------------------------
# Workspace
# ----------------------------------------------------------------------

if [[ ! "$WORKSPACE_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    fail "invalid workspace name: $WORKSPACE_NAME"
fi


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


[ -f "$WORKSPACE_FILE" ] || \
    fail "workspace configuration not found: $WORKSPACE_FILE"

[ -d "$CLUSTERS_DIR" ] || \
    fail "cluster directory not found: $CLUSTERS_DIR"

[ -d "$TOOLS_DIR" ] || \
    fail "tools directory not found: $TOOLS_DIR"


HOST_PLATFORM="$(
    detect_host_platform
)"


# ----------------------------------------------------------------------
# Configuration directory
# ----------------------------------------------------------------------

CONFIG_PATH="$(
    jq -r '.configuration.path' "$WORKSPACE_FILE"
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
        jq -r '.schema' "$CONFIG_FILE"
    )"

    if [ "$CONFIG_SCHEMA" = "$CLUSTER_SCHEMA" ]; then
        CLUSTER_FILES+=("$CONFIG_FILE")
    fi

done


# ----------------------------------------------------------------------
# Header
# ----------------------------------------------------------------------

echo "$PROJECT_NAME user validation"

echo
echo "Repository : $REPO_ROOT"
echo "Workspace  : $WORKSPACE_DIR"
echo "Config dir : $CONFIG_DIR"
echo "Clusters   : $CLUSTERS_DIR"
echo "Tools      : $TOOLS_DIR"
echo "Platform   : $HOST_PLATFORM"
echo "Network    : disabled"


# ----------------------------------------------------------------------
# Clusters
# ----------------------------------------------------------------------

for CLUSTER_FILE in "${CLUSTER_FILES[@]}"; do

    CLUSTER_NAME="$(
        jq -r '.name' "$CLUSTER_FILE"
    )"

    CLUSTERS=$((CLUSTERS + 1))

    CLUSTER_DIR="$CLUSTERS_DIR/$CLUSTER_NAME"
    CLUSTER_LINK="$CLUSTER_DIR/cluster.json"


    echo
    echo "Cluster: $CLUSTER_NAME"


    if [ ! -d "$CLUSTER_DIR" ]; then
        record_error \
            "cluster '$CLUSTER_NAME' is not materialized: $CLUSTER_DIR"
    fi


    if [ ! -L "$CLUSTER_LINK" ]; then
        record_error \
            "cluster '$CLUSTER_NAME' has no managed cluster.json symlink"
    fi


    # ------------------------------------------------------------------
    # kubectl parser
    # ------------------------------------------------------------------

    KUBECTL_VERSION="$(
        jq -r '.tools.kubectl.version // ""' "$CLUSTER_FILE"
    )"

    KUBECTL_READY=0
    KUBECTL_BIN=""


    if [ -z "$KUBECTL_VERSION" ]; then

        echo "  kubectl      : NOT DECLARED"

    else

        KUBECTL_DIR="$TOOLS_DIR/$HOST_PLATFORM/kubectl/$KUBECTL_VERSION"

        if verify_installed_kubectl \
            "$KUBECTL_DIR" \
            "$KUBECTL_VERSION" \
            "$HOST_PLATFORM"
        then

            KUBECTL_FILE="$(
                jq -r '.binary.file' "$KUBECTL_DIR/manifest.json"
            )"

            KUBECTL_BIN="$KUBECTL_DIR/$KUBECTL_FILE"

            KUBECTL_READY=1

            echo "  kubectl      : $KUBECTL_VERSION (verified)"

        else

            echo "  kubectl      : $KUBECTL_VERSION (not available)"

        fi

    fi


    mapfile -t USER_NAMES < <(
        jq -r '.users | keys[]' "$CLUSTER_FILE"
    )


    if [ "${#USER_NAMES[@]}" -eq 0 ]; then
        echo "  users        : none"
        continue
    fi


    for USER_NAME in "${USER_NAMES[@]}"; do

        USERS=$((USERS + 1))
        USER_ERROR_BASE="$ERRORS"

        USER_DIR="$CLUSTER_DIR/users/$USER_NAME"
        CERTS_DIR="$USER_DIR/certs"


        KUBECONFIG_REL="$(
            jq -r \
                --arg user "$USER_NAME" '
                .users[$user].kubeconfig
            ' "$CLUSTER_FILE"
        )"


        DECLARED_CONTEXT="$(
            jq -r \
                --arg user "$USER_NAME" '
                .users[$user].context // ""
            ' "$CLUSTER_FILE"
        )"


        echo
        echo "  User: $USER_NAME"


        # --------------------------------------------------------------
        # Materialized paths
        # --------------------------------------------------------------

        if [ ! -d "$USER_DIR" ]; then
            record_error \
                "cluster '$CLUSTER_NAME' user '$USER_NAME': user directory is missing"
        fi


        if [ ! -d "$CERTS_DIR" ]; then
            record_error \
                "cluster '$CLUSTER_NAME' user '$USER_NAME': certs directory is missing"
        fi


        if ! safe_relative_path "$KUBECONFIG_REL"; then

            record_error \
                "cluster '$CLUSTER_NAME' user '$USER_NAME': unsafe kubeconfig path '$KUBECONFIG_REL'"

            echo "    kubeconfig   : INVALID PATH"
            echo "    status       : NOT READY"

            INVALID=$((INVALID + 1))
            continue

        fi


        KUBECONFIG_FILE="$USER_DIR/$KUBECONFIG_REL"


        if [ ! -f "$KUBECONFIG_FILE" ]; then

            echo "    kubeconfig   : MISSING"
            echo "    expected     : $KUBECONFIG_FILE"

            record_error \
                "cluster '$CLUSTER_NAME' user '$USER_NAME': kubeconfig is missing"

            INVALID=$((INVALID + 1))

            echo "    status       : NOT READY"

            continue

        fi


        KUBECONFIG_MODE="$(
            file_mode "$KUBECONFIG_FILE"
        )"

        echo "    kubeconfig   : $KUBECONFIG_FILE"
        echo "    mode         : $KUBECONFIG_MODE"


        if ! file_permissions_are_private "$KUBECONFIG_FILE"; then

            record_error \
                "cluster '$CLUSTER_NAME' user '$USER_NAME': kubeconfig permissions are too broad ($KUBECONFIG_MODE)"

        fi


        if [ "$KUBECTL_READY" -ne 1 ]; then

            record_error \
                "cluster '$CLUSTER_NAME' user '$USER_NAME': verified kubectl is not installed"

            INVALID=$((INVALID + 1))

            echo "    status       : NOT READY"

            continue

        fi


        # --------------------------------------------------------------
        # Parse kubeconfig locally
        # --------------------------------------------------------------

        if ! KUBECONFIG_JSON="$(
            "$KUBECTL_BIN" \
                config view \
                --kubeconfig "$KUBECONFIG_FILE" \
                -o json
        )"
        then

            record_error \
                "cluster '$CLUSTER_NAME' user '$USER_NAME': kubeconfig cannot be parsed"

            INVALID=$((INVALID + 1))

            echo "    status       : NOT READY"

            continue

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
        ' >/dev/null <<< "$KUBECONFIG_JSON"
        then

            record_error \
                "cluster '$CLUSTER_NAME' user '$USER_NAME': kubeconfig has no usable clusters/contexts/users"

        fi


        # --------------------------------------------------------------
        # Duplicate object names
        # --------------------------------------------------------------

        if ! jq -e '
            ([.clusters[].name] | length)
            ==
            ([.clusters[].name] | unique | length)
        ' >/dev/null <<< "$KUBECONFIG_JSON"
        then
            record_error \
                "cluster '$CLUSTER_NAME' user '$USER_NAME': duplicate cluster names"
        fi


        if ! jq -e '
            ([.contexts[].name] | length)
            ==
            ([.contexts[].name] | unique | length)
        ' >/dev/null <<< "$KUBECONFIG_JSON"
        then
            record_error \
                "cluster '$CLUSTER_NAME' user '$USER_NAME': duplicate context names"
        fi


        if ! jq -e '
            ([.users[].name] | length)
            ==
            ([.users[].name] | unique | length)
        ' >/dev/null <<< "$KUBECONFIG_JSON"
        then
            record_error \
                "cluster '$CLUSTER_NAME' user '$USER_NAME': duplicate auth user names"
        fi


        # --------------------------------------------------------------
        # Context selection
        # --------------------------------------------------------------

        CURRENT_CONTEXT="$(
            jq -r '."current-context" // ""' <<< "$KUBECONFIG_JSON"
        )"


        if [ -n "$DECLARED_CONTEXT" ]; then

            SELECTED_CONTEXT="$DECLARED_CONTEXT"
            CONTEXT_SELECTION="KubeBase user.context"

        else

            SELECTED_CONTEXT="$CURRENT_CONTEXT"
            CONTEXT_SELECTION="kubeconfig current-context"

        fi


        if [ -z "$SELECTED_CONTEXT" ]; then

            record_error \
                "cluster '$CLUSTER_NAME' user '$USER_NAME': no context selected"

            echo "    selected ctx : MISSING"
            echo "    status       : NOT READY"

            INVALID=$((INVALID + 1))
            continue

        fi


        SELECTED_CONTEXT_COUNT="$(
            jq -r \
                --arg context "$SELECTED_CONTEXT" '
                [
                    .contexts[]
                    |
                    select(.name == $context)
                ]
                | length
            ' <<< "$KUBECONFIG_JSON"
        )"


        if [ "$SELECTED_CONTEXT_COUNT" -ne 1 ]; then

            record_error \
                "cluster '$CLUSTER_NAME' user '$USER_NAME': selected context '$SELECTED_CONTEXT' does not exist exactly once"

            echo "    selected ctx : $SELECTED_CONTEXT"
            echo "    status       : NOT READY"

            INVALID=$((INVALID + 1))
            continue

        fi


        # --------------------------------------------------------------
        # Context overview
        # --------------------------------------------------------------

        echo "    contexts:"


        while IFS=$'\t' read -r \
            CONTEXT_NAME \
            CONTEXT_CLUSTER_NAME \
            CONTEXT_SERVER
        do

            MARKERS=""

            if [ "$CONTEXT_NAME" = "$CURRENT_CONTEXT" ]; then
                MARKERS="current"
            fi

            if [ "$CONTEXT_NAME" = "$SELECTED_CONTEXT" ]; then

                if [ -n "$MARKERS" ]; then
                    MARKERS="$MARKERS, selected"
                else
                    MARKERS="selected"
                fi

            fi


            if [ -n "$MARKERS" ]; then
                echo "      $CONTEXT_NAME [$MARKERS]"
            else
                echo "      $CONTEXT_NAME"
            fi

            echo "        cluster : $CONTEXT_CLUSTER_NAME"
            echo "        server  : $CONTEXT_SERVER"

        done < <(

            jq -r '

                . as $root

                |

                .contexts[]

                |

                . as $ctx

                |

                (
                    [
                        $root.clusters[]
                        |
                        select(.name == $ctx.context.cluster)
                        |
                        .cluster.server // ""
                    ][0]
                    // ""
                ) as $server

                |

                [
                    $ctx.name,
                    ($ctx.context.cluster // ""),
                    $server
                ]

                | @tsv

            ' <<< "$KUBECONFIG_JSON"

        )


        echo "    selected ctx : $SELECTED_CONTEXT"
        echo "    selection    : $CONTEXT_SELECTION"


        # --------------------------------------------------------------
        # Selected context object
        # --------------------------------------------------------------

        CONTEXT_JSON="$(
            jq -c \
                --arg context "$SELECTED_CONTEXT" '
                .contexts[]
                |
                select(.name == $context)
                |
                .context
            ' <<< "$KUBECONFIG_JSON"
        )"


        CONTEXT_CLUSTER="$(
            jq -r '.cluster // ""' <<< "$CONTEXT_JSON"
        )"

        CONTEXT_USER="$(
            jq -r '.user // ""' <<< "$CONTEXT_JSON"
        )"

        CONTEXT_NAMESPACE="$(
            jq -r '.namespace // ""' <<< "$CONTEXT_JSON"
        )"


        if [ -n "$CONTEXT_NAMESPACE" ]; then
            echo "    ctx namespace: $CONTEXT_NAMESPACE"
        else
            echo "    ctx namespace: (default)"
        fi


        # --------------------------------------------------------------
        # Selected cluster
        # --------------------------------------------------------------

        SELECTED_CLUSTER_JSON=""

        if [ -z "$CONTEXT_CLUSTER" ]; then

            record_error \
                "cluster '$CLUSTER_NAME' user '$USER_NAME': selected context has no cluster"

        else

            CONTEXT_CLUSTER_COUNT="$(
                jq -r \
                    --arg cluster "$CONTEXT_CLUSTER" '
                    [
                        .clusters[]
                        |
                        select(.name == $cluster)
                    ]
                    | length
                ' <<< "$KUBECONFIG_JSON"
            )"


            if [ "$CONTEXT_CLUSTER_COUNT" -ne 1 ]; then

                record_error \
                    "cluster '$CLUSTER_NAME' user '$USER_NAME': selected context references unknown cluster '$CONTEXT_CLUSTER'"

            else

                SELECTED_CLUSTER_JSON="$(
                    jq -c \
                        --arg cluster "$CONTEXT_CLUSTER" '
                        .clusters[]
                        |
                        select(.name == $cluster)
                        |
                        .cluster
                    ' <<< "$KUBECONFIG_JSON"
                )"


                API_SERVER="$(
                    jq -r '.server // ""' <<< "$SELECTED_CLUSTER_JSON"
                )"


                echo "    kube cluster : $CONTEXT_CLUSTER"


                if [ -n "$API_SERVER" ]; then
                    echo "    api server   : $API_SERVER"
                else
                    echo "    api server   : MISSING"

                    record_error \
                        "cluster '$CLUSTER_NAME' user '$USER_NAME': selected cluster has no API server"
                fi

            fi

        fi


        # --------------------------------------------------------------
        # Selected auth user
        # --------------------------------------------------------------

        AUTH_JSON=""

        if [ -z "$CONTEXT_USER" ]; then

            record_error \
                "cluster '$CLUSTER_NAME' user '$USER_NAME': selected context has no auth user"

            echo "    auth user    : MISSING"
            echo "    credentials  : none"

        else

            CONTEXT_USER_COUNT="$(
                jq -r \
                    --arg authUser "$CONTEXT_USER" '
                    [
                        .users[]
                        |
                        select(.name == $authUser)
                    ]
                    | length
                ' <<< "$KUBECONFIG_JSON"
            )"


            if [ "$CONTEXT_USER_COUNT" -ne 1 ]; then

                record_error \
                    "cluster '$CLUSTER_NAME' user '$USER_NAME': selected context references unknown auth user '$CONTEXT_USER'"

                echo "    auth user    : $CONTEXT_USER"
                echo "    credentials  : INVALID"

            else

                AUTH_JSON="$(
                    jq -c \
                        --arg authUser "$CONTEXT_USER" '
                        .users[]
                        |
                        select(.name == $authUser)
                        |
                        .user
                    ' <<< "$KUBECONFIG_JSON"
                )"


                echo "    auth user    : $CONTEXT_USER"
                echo "    credentials  : $(credential_summary "$AUTH_JSON")"

            fi

        fi


        # --------------------------------------------------------------
        # External references for SELECTED path only.
        #
        # Unused contexts are informational and do not make the selected
        # user unusable.
        # --------------------------------------------------------------

        KUBECONFIG_DIR="$(
            cd -- "$(dirname -- "$KUBECONFIG_FILE")"
            pwd -P
        )"


        EXTERNAL_REFS=""


        if [ -n "$SELECTED_CLUSTER_JSON" ]; then

            CLUSTER_CA="$(
                jq -r '."certificate-authority" // ""' \
                    <<< "$SELECTED_CLUSTER_JSON"
            )"


            if [ -n "$CLUSTER_CA" ]; then
                EXTERNAL_REFS+="certificate-authority"$'\t'"$CONTEXT_CLUSTER"$'\t'"$CLUSTER_CA"$'\n'
            fi

        fi


        if [ -n "$AUTH_JSON" ]; then

            CLIENT_CERT="$(
                jq -r '."client-certificate" // ""' <<< "$AUTH_JSON"
            )"

            CLIENT_KEY="$(
                jq -r '."client-key" // ""' <<< "$AUTH_JSON"
            )"

            TOKEN_FILE="$(
                jq -r '.tokenFile // ""' <<< "$AUTH_JSON"
            )"


            if [ -n "$CLIENT_CERT" ]; then
                EXTERNAL_REFS+="client-certificate"$'\t'"$CONTEXT_USER"$'\t'"$CLIENT_CERT"$'\n'
            fi

            if [ -n "$CLIENT_KEY" ]; then
                EXTERNAL_REFS+="client-key"$'\t'"$CONTEXT_USER"$'\t'"$CLIENT_KEY"$'\n'
            fi

            if [ -n "$TOKEN_FILE" ]; then
                EXTERNAL_REFS+="token-file"$'\t'"$CONTEXT_USER"$'\t'"$TOKEN_FILE"$'\n'
            fi

        fi


        if [ -z "$EXTERNAL_REFS" ]; then

            echo "    external refs: none"

        else

            echo "    external refs:"


            while IFS=$'\t' read -r \
                REF_KIND \
                REF_OWNER \
                REF_PATH
            do

                [ -n "$REF_KIND" ] || continue


                if [[ "$REF_PATH" = /* ]]; then
                    RESOLVED_REF="$REF_PATH"
                else
                    RESOLVED_REF="$KUBECONFIG_DIR/$REF_PATH"
                fi


                echo "      $REF_KIND [$REF_OWNER]"
                echo "        path     : $REF_PATH"


                if [ -f "$RESOLVED_REF" ]; then

                    echo "        status   : OK"


                    if [ "$REF_KIND" = "client-key" ] ||
                       [ "$REF_KIND" = "token-file" ]
                    then

                        REF_MODE="$(
                            file_mode "$RESOLVED_REF"
                        )"

                        echo "        mode     : $REF_MODE"


                        if ! file_permissions_are_private "$RESOLVED_REF"; then

                            record_error \
                                "cluster '$CLUSTER_NAME' user '$USER_NAME': $REF_KIND permissions are too broad ($REF_MODE)"

                        fi

                    fi

                else

                    echo "        status   : MISSING"

                    record_error \
                        "cluster '$CLUSTER_NAME' user '$USER_NAME': referenced $REF_KIND file is missing: $RESOLVED_REF"

                fi

            done <<< "$EXTERNAL_REFS"

        fi


        # --------------------------------------------------------------
        # Result
        # --------------------------------------------------------------

        if [ "$ERRORS" -eq "$USER_ERROR_BASE" ]; then

            READY=$((READY + 1))

            echo "    status       : READY"

        else

            INVALID=$((INVALID + 1))

            echo "    status       : NOT READY"

        fi

    done

done


# ----------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------

echo
echo "User validation complete."

echo
echo "Summary:"
echo "  clusters : $CLUSTERS"
echo "  users    : $USERS"
echo "  ready    : $READY"
echo "  invalid  : $INVALID"
echo "  warnings : $WARNINGS"
echo "  errors   : $ERRORS"


if [ "$ERRORS" -ne 0 ]; then

    echo
    echo "Validation FAILED."

    exit 1

fi


echo
echo "Validation OK"
