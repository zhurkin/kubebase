# KubeBase

KubeBase is a portable workspace and bootstrap system for working with Kubernetes clusters.

It provides a reproducible local environment for Kubernetes CLI tools, cluster profiles, kubeconfigs, users, and live namespace/group navigation without mixing local credentials or downloaded artifacts with the Git repository.

## Goals

KubeBase is designed to make a Kubernetes working environment:

- reproducible;
- portable between machines;
- usable offline after artifacts are downloaded;
- independent from globally installed Kubernetes tools;
- safe for local credentials and configuration;
- suitable for both humans and automation/agents.

## How it works

The Git repository contains only the bootstrap logic and default configuration templates.

Local configuration, credentials, downloaded artifacts, and installed tools live outside the repository.

Example layout:

```text
kuber/
├── kubebase/               # Git repository
├── kubebase-config/        # Local cluster configuration
└── kubebase-workspace/     # Local workspace
    ├── artifacts/
    ├── tools/
    ├── clusters/
    └── .kubebase/       # sessions and discovery cache
```

## Current workflow

```text
00  init workspace
10  validate configuration
11  validate tool sources
20  fetch and verify artifacts
30  install tools
40  materialize clusters
50  validate users and kubeconfigs locally
60  validate profiles against the live Kubernetes API
70  activate cluster/user profiles
80  namespace and optional group navigation
```

KubeBase currently supports:

- cluster profiles defined as JSON;
- per-cluster tool versions and target platforms;
- shared, deduplicated tool artifacts;
- SHA-256 verification of downloaded artifacts;
- offline installation from the artifact store;
- materialized cluster/user workspaces and per-cluster toolchains;
- local kubeconfig validation;
- multiple kubeconfig contexts with explicit context selection;
- live Kubernetes API validation;
- best-effort namespace discovery with cache fallback;
- optional namespace grouping derived from namespace metadata when available.

## Basic usage

Initialize the workspace:

```bash
./kubebase.sh init
```

Validate configuration:

```bash
./kubebase.sh validate-config
./kubebase.sh validate-sources --offline
```

Download and install required tools:

```bash
./kubebase.sh fetch
./kubebase.sh install
```

Materialize cluster workspaces:

```bash
./kubebase.sh materialize-clusters
```

Validate users and kubeconfigs locally:

```bash
./kubebase.sh validate-users
```

Validate configured profiles against the Kubernetes API and refresh the namespace cache:

```bash
./kubebase.sh validate-live
```

Activate a profile and navigate namespaces/groups:

```bash
eval "$(./kubebase.sh shell-init bash)"
kubebase use my-cluster/default
kubebase namespaces
kubebase groups
kubebase ns stats-hydra-data
```

## Configuration model

KubeBase treats a configured cluster as a logical workspace.

A kubeconfig may contain multiple Kubernetes contexts and endpoints. KubeBase can use either:

1. an explicitly configured user context; or
2. the kubeconfig `current-context` as a fallback.

The original kubeconfig is never modified when selecting a context.

Namespace groups are optional KubeBase navigation metadata, not a Kubernetes core resource. A cluster may expose no groups at all; in that case namespace discovery and navigation continue to work normally.

## Security

Credentials, kubeconfigs, and downloaded artifacts are intentionally kept outside the Git repository.

KubeBase also validates permissions on sensitive local files and avoids overwriting user-managed credential data.

## Status

KubeBase is currently under active development.

Linux support is being implemented first. Windows and macOS support are planned.

The configuration format and command set may still change while the project is evolving.

## Documentation

Full architecture, configuration reference, and usage documentation will be added later.
