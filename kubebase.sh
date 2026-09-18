#!/bin/sh

set -eu


PROJECT_NAME="KubeBase"

REPO_ROOT=$(
    CDPATH= cd -- "$(dirname -- "$0")"
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
      Materialize configured clusters, users and environments
      inside the workspace.

  validate-users
      Validate materialized users and kubeconfig files locally.

  validate-environments
      Validate configured environments against the Kubernetes API.

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
