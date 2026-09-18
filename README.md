# KubeBase

KubeBase is a portable workspace and bootstrap system for working with Kubernetes clusters.

It provides a reproducible local environment for Kubernetes CLI tools, cluster profiles, kubeconfigs, users, and namespace environments without mixing local credentials or downloaded artifacts with the Git repository.

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
├── kubase/                 # Git repository
├── kubebase-config/        # Local cluster configuration
└── kubebase-workspace/     # Local workspace
    ├── artifacts/
    ├── tools/
    ├── clusters/
    └── runtime/
```

## Current workflow

```text
00  init workspace
10  validate configuration
11  validate tool sources
20  fetch and verify artifacts
30  install tools
40  materialize clusters
50  validate users and kubeconfigs
60  validate Kubernetes environments
90  runtime environment (planned)
```

KubeBase currently supports:

- cluster profiles defined as JSON;
- per-cluster tool versions and target platforms;
- shared, deduplicated tool artifacts;
- SHA-256 verification of downloaded artifacts;
- offline installation from the artifact store;
- materialized cluster/user/environment workspaces;
- local kubeconfig validation;
- multiple kubeconfig contexts with explicit context selection;
- Kubernetes API and namespace/environment validation.

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

Validate configured environments against the Kubernetes API:

```bash
./kubebase.sh validate-environments
```

## Configuration model

KubeBase treats a configured cluster as a logical workspace.

A kubeconfig may contain multiple Kubernetes contexts and endpoints. KubeBase can use either:

1. an explicitly configured user context; or
2. the kubeconfig `current-context` as a fallback.

The original kubeconfig is never modified when selecting a context.

## Security

Credentials, kubeconfigs, and downloaded artifacts are intentionally kept outside the Git repository.

KubeBase also validates permissions on sensitive local files and avoids overwriting user-managed credential data.

## Status

KubeBase is currently under active development.

Linux support is being implemented first. Windows and macOS support are planned.

The configuration format and command set may still change while the project is evolving.

## Documentation

Full architecture, configuration reference, and usage documentation will be added later.
