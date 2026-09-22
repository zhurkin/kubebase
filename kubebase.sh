#!/bin/sh

set -eu


PROJECT_NAME="KubeBase"


# ----------------------------------------------------------------------
# Resolve the real repository entrypoint.
#
# kubebase.sh may be invoked through the workspace symlink created by
# Step 00. Resolve symlinks before deriving REPO_ROOT so all commands
# continue to execute from the Git repository.
# ----------------------------------------------------------------------

SELF="$0"

case "$SELF" in
    /*)
        ;;

    *)
        SELF="$(pwd -P)/$SELF"
        ;;
esac

SYMLINK_DEPTH=0

while [ -L "$SELF" ]; do

    SYMLINK_DEPTH=$((SYMLINK_DEPTH + 1))

    if [ "$SYMLINK_DEPTH" -gt 40 ]; then
        echo "ERROR: too many kubebase.sh symlink levels" >&2
        exit 1
    fi

    SELF_DIR=$(
        CDPATH= cd -- "$(dirname -- "$SELF")"
        pwd -P
    )

    SELF_TARGET=$(readlink -- "$SELF")

    case "$SELF_TARGET" in
        /*)
            SELF="$SELF_TARGET"
            ;;

        *)
            SELF="$SELF_DIR/$SELF_TARGET"
            ;;
    esac
done

REPO_ROOT=$(
    CDPATH= cd -- "$(dirname -- "$SELF")"
    pwd -P
)

SCRIPTS_DIR="$REPO_ROOT/scripts/linux"


usage()
{
    cat <<EOF_USAGE
$PROJECT_NAME

Usage:
  $(basename "$0") COMMAND [options]

Setup:
  init
      Initialize the KubeBase workspace.

  validate config
      Validate configuration documents.

  validate sources [--offline]
      Validate tool sources and cluster requirements.

  fetch
      Download and verify required tool artifacts.

  install
      Install verified artifacts into the shared tool store.

  materialize
      Materialize configured clusters, host toolchains and users.

  validate users
      Validate materialized users and kubeconfigs locally.

  validate live
      Validate profiles against the live Kubernetes API and refresh
      namespace inventory cache.

Profiles:
  profiles
      List configured cluster/user profiles and local readiness.

  use [CLUSTER/USER]
      Activate a profile in the current shell.

  current [--verbose]
      Show the active profile. --verbose includes kubeconfig and full
      toolchain diagnostics.

  off
      Deactivate the current profile.

Navigation:
  namespaces [--cached|--live] [--verbose]
      List namespaces visible to the active profile.

  ns [NAME|--clear]
      Select or clear the active Kubernetes namespace.

  groups [--cached|--live] [--verbose]
      List namespace groups discovered from namespace metadata.

  group [GROUP|--clear]
      Select or clear the namespace group filter.

Shell:
  shell init bash
      Emit Bash integration for commands that modify the current shell.

Other:
  help
      Show this help.

Examples:
  $(basename "$0") init
  $(basename "$0") validate config
  $(basename "$0") validate sources --offline
  $(basename "$0") fetch
  $(basename "$0") install
  $(basename "$0") materialize
  $(basename "$0") validate users
  $(basename "$0") validate live
  $(basename "$0") profiles

  eval "\$(./kubebase.sh shell init bash)"

  kubebase use my-cluster/default
  kubebase current
  kubebase current --verbose
  kubebase namespaces
  kubebase namespaces --verbose
  kubebase ns default
  kubebase groups
  kubebase group GROUP-ID
  kubebase off
EOF_USAGE
}


COMMAND="${1:-help}"


case "$COMMAND" in

    init)
        shift
        exec "$SCRIPTS_DIR/00-init-workspace.sh" "$@"
        ;;

    validate)
        shift
        VALIDATE_TARGET="${1:-}"

        if [ -n "$VALIDATE_TARGET" ]; then
            shift
        fi

        case "$VALIDATE_TARGET" in
            config)
                exec "$SCRIPTS_DIR/10-validate-config.sh" "$@"
                ;;

            sources)
                exec "$SCRIPTS_DIR/11-validate-sources.sh" "$@"
                ;;

            users)
                exec "$SCRIPTS_DIR/50-validate-users.sh" "$@"
                ;;

            live)
                exec "$SCRIPTS_DIR/60-validate-live.sh" "$@"
                ;;

            "")
                echo "ERROR: usage: $(basename "$0") validate {config|sources|users|live} [options]" >&2
                exit 2
                ;;

            *)
                echo "ERROR: unknown validation target: $VALIDATE_TARGET" >&2
                echo "Usage: $(basename "$0") validate {config|sources|users|live} [options]" >&2
                exit 2
                ;;
        esac
        ;;

    fetch)
        shift
        exec "$SCRIPTS_DIR/20-fetch-artifacts.sh" "$@"
        ;;

    install)
        shift
        exec "$SCRIPTS_DIR/30-install-tools.sh" "$@"
        ;;

    materialize)
        shift
        exec "$SCRIPTS_DIR/40-materialize-clusters.sh" "$@"
        ;;

    profiles)
        shift
        exec "$SCRIPTS_DIR/70-profile.sh" profiles "$@"
        ;;

    shell)
        shift
        SHELL_TARGET="${1:-}"

        if [ -n "$SHELL_TARGET" ]; then
            shift
        fi

        case "$SHELL_TARGET" in
            init)
                exec "$SCRIPTS_DIR/70-profile.sh" shell-init "$@"
                ;;

            "")
                echo "ERROR: usage: $(basename "$0") shell init bash [options]" >&2
                exit 2
                ;;

            *)
                echo "ERROR: unknown shell command: $SHELL_TARGET" >&2
                echo "Usage: $(basename "$0") shell init bash [options]" >&2
                exit 2
                ;;
        esac
        ;;

    use)
        shift
        exec "$SCRIPTS_DIR/70-profile.sh" use-direct "$@"
        ;;

    current)
        shift
        exec "$SCRIPTS_DIR/70-profile.sh" current "$@"
        ;;

    namespaces)
        shift
        exec "$SCRIPTS_DIR/80-navigation.sh" namespaces "$@"
        ;;

    ns)
        shift
        exec "$SCRIPTS_DIR/80-navigation.sh" ns-direct "$@"
        ;;

    groups)
        shift
        exec "$SCRIPTS_DIR/80-navigation.sh" groups "$@"
        ;;

    group)
        shift
        exec "$SCRIPTS_DIR/80-navigation.sh" group-direct "$@"
        ;;

    off)
        shift
        exec "$SCRIPTS_DIR/70-profile.sh" off-direct "$@"
        ;;

    __profile-select)
        shift
        exec "$SCRIPTS_DIR/70-profile.sh" __profile-select "$@"
        ;;

    __profile-use)
        shift
        exec "$SCRIPTS_DIR/70-profile.sh" __profile-use "$@"
        ;;

    __profile-cleanup)
        shift
        exec "$SCRIPTS_DIR/70-profile.sh" __profile-cleanup "$@"
        ;;

    __nav-ns)
        shift
        exec "$SCRIPTS_DIR/80-navigation.sh" __nav-ns "$@"
        ;;

    __nav-group)
        shift
        exec "$SCRIPTS_DIR/80-navigation.sh" __nav-group "$@"
        ;;

    help|-h|--help)
        usage
        ;;

    *)
        echo "ERROR: unknown command: $COMMAND" >&2
        echo >&2
        usage >&2
        exit 2
        ;;
esac
