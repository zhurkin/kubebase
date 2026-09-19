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

Commands:
  init
      Initialize the KubeBase workspace.

  validate-config
      Validate all configuration documents.

  validate-sources
      Validate tool source configuration and cluster requirements.

  fetch
      Download and verify required tool artifacts.

  install
      Install verified artifacts into the shared tool store.

  materialize-clusters
      Materialize configured clusters, host toolchains, users and
      environments inside the workspace.

  validate-users
      Validate materialized users and kubeconfig files locally.

  validate-environments
      Validate configured environments against the Kubernetes API.

  profiles
      List configured cluster/user profiles and local readiness.

  shell-init bash
      Emit Bash integration for profile activation.

  use [CLUSTER/USER]
      Activate a profile in the current shell (requires shell-init).

  current
      Show the currently active KubeBase profile.

  off
      Deactivate the current profile (requires shell-init).

  help
      Show this help.

Examples:
  $(basename "$0") init

  $(basename "$0") validate-config

  $(basename "$0") validate-sources --offline

  $(basename "$0") fetch --dry-run

  $(basename "$0") fetch

  $(basename "$0") install --dry-run

  $(basename "$0") install

  $(basename "$0") materialize-clusters

  $(basename "$0") validate-users

  $(basename "$0") profiles

  eval "\$(./kubebase.sh shell-init bash)"

  kubebase use rancher-main/admin

  kubebase current

  kubebase off
EOF_USAGE
}


COMMAND="${1:-help}"


case "$COMMAND" in

    init)

        shift

        exec \
            "$SCRIPTS_DIR/00-init-workspace.sh" \
            "$@"
        ;;


    validate-config)

        shift

        exec \
            "$SCRIPTS_DIR/10-validate-config.sh" \
            "$@"
        ;;


    validate-sources)

        shift

        exec \
            "$SCRIPTS_DIR/11-validate-sources.sh" \
            "$@"
        ;;


    fetch|fetch-artifacts)

        shift

        exec \
            "$SCRIPTS_DIR/20-fetch-artifacts.sh" \
            "$@"
        ;;


    install|install-tools)

        shift

        exec \
            "$SCRIPTS_DIR/30-install-tools.sh" \
            "$@"
        ;;


    materialize-clusters)

        shift

        exec \
            "$SCRIPTS_DIR/40-materialize-clusters.sh" \
            "$@"
        ;;


    validate-users|validate-credentials)

        shift

        exec \
            "$SCRIPTS_DIR/50-validate-users.sh" \
            "$@"
        ;;


    validate-environments|validate-envs)

        shift

        exec \
            "$SCRIPTS_DIR/60-validate-environments.sh" \
            "$@"
        ;;


    profiles)

        shift

        exec \
            "$SCRIPTS_DIR/70-profile.sh" \
            profiles \
            "$@"
        ;;


    shell-init)

        shift

        exec \
            "$SCRIPTS_DIR/70-profile.sh" \
            shell-init \
            "$@"
        ;;


    use)

        shift

        exec \
            "$SCRIPTS_DIR/70-profile.sh" \
            use-direct \
            "$@"
        ;;


    current)

        shift

        exec \
            "$SCRIPTS_DIR/70-profile.sh" \
            current \
            "$@"
        ;;


    off)

        shift

        exec \
            "$SCRIPTS_DIR/70-profile.sh" \
            off-direct \
            "$@"
        ;;


    __profile-select)

        shift

        exec \
            "$SCRIPTS_DIR/70-profile.sh" \
            __profile-select \
            "$@"
        ;;


    __profile-use)

        shift

        exec \
            "$SCRIPTS_DIR/70-profile.sh" \
            __profile-use \
            "$@"
        ;;


    __profile-cleanup)

        shift

        exec \
            "$SCRIPTS_DIR/70-profile.sh" \
            __profile-cleanup \
            "$@"
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
