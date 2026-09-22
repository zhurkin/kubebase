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
    ├── krew/               # persistent per-cluster Krew environments
    └── .kubebase/          # KubeBase sessions and discovery cache
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
55  prepare declared authentication dependencies
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
- best-effort namespace discovery with context-specific cache fallback;
- separate latest, complete, and partial namespace inventory snapshots;
- optional typed namespace grouping derived from namespace metadata when available.

## Basic usage

Initialize the workspace:

```bash
./kubebase.sh init
```

Validate configuration and tool sources:

```bash
./kubebase.sh validate config
./kubebase.sh validate sources --offline
```

Download and install required tools:

```bash
./kubebase.sh fetch
./kubebase.sh install
```

Materialize cluster workspaces and validate users locally:

```bash
./kubebase.sh materialize
./kubebase.sh validate users
```

Prepare authentication dependencies declared by profiles (currently the
`oidc-login` dependency for OIDC users):

```bash
./kubebase.sh auth prepare
```

Validate configured profiles against the Kubernetes API and refresh namespace inventory:

```bash
./kubebase.sh validate live
```

Initialize Bash integration in the current shell:

```bash
eval "$(./kubebase.sh shell init bash)"
```

The executable form emits shell code intentionally. After integration is loaded, running `kubebase shell init bash` reports that Bash integration is already active instead of printing the generated function body.

For regular use, the same expression can be placed in `.bashrc` with the absolute path to the workspace entrypoint, for example:

```bash
eval "$(/home/user/kuber/kubebase-workspace/kubebase.sh shell init bash)"
```

Activate a profile and navigate:

```bash
kubebase profiles
kubebase use my-cluster/default
kubebase current
kubebase namespaces
kubebase groups
kubebase ns my-namespace
```

Commands that change shell state print a short result. Detailed diagnostics are available explicitly:

```bash
kubebase current --verbose
kubebase namespaces --verbose
kubebase groups --verbose
```

Namespace/group inventory has three discovery modes:

```bash
kubebase namespaces           # live first, cache fallback
kubebase namespaces --cached  # cache only, no network
kubebase namespaces --live    # live only, no cache fallback
```

The same discovery flags apply to `kubebase groups`.

`kubebase ns` and `kubebase group` without an argument open an interactive selector when a TTY is available.

## Configuration model

KubeBase treats a configured cluster as a logical workspace.

A kubeconfig may contain multiple Kubernetes contexts and endpoints. KubeBase can use either:

1. an explicitly configured user context; or
2. the kubeconfig `current-context` as a fallback.

The original kubeconfig is never modified when selecting a context.

Cluster tools are selected independently per cluster. A tool entry may set `"enabled": false`; disabled tools are excluded from source validation requirements, fetch/install planning, and that cluster's materialized toolchain. If `enabled` is omitted it defaults to `true`. Clusters with users must keep `kubectl` enabled.

Krew is exposed in an active profile as both `kubectl krew` and the convenience command `krew`. Its binary version is selected per cluster like any other tool, while identical versions remain deduplicated in the shared tool store. Each cluster/platform has one persistent Krew environment at `workspace/krew/<cluster>/<platform>`. That directory is the cluster's `KREW_ROOT` and survives a Krew binary version change. Krew owns its indexes, store, installed plugins, and plugin links below that root; KubeBase does not enumerate or upgrade arbitrary user-installed plugins.

OIDC is an explicit per-user authentication override. A user may declare:

```json
"auth": {
  "type": "oidc",
  "issuerUrl": "https://identity.example.test/realms/kubernetes",
  "clientId": "kubernetes",
  "grantType": "device-code"
}
```

`grantType` is optional and, when present, may be `authcode` or `device-code`. OIDC requires Krew to be configured and enabled for the cluster. KubeBase treats `oidc-login` as the one system Krew dependency needed to implement this authentication mode; all other plugins remain entirely user-managed.

Authentication dependencies are prepared explicitly:

```bash
kubebase auth prepare
kubebase auth prepare --check
```

`auth prepare` verifies the configured Krew binary against the KubeBase artifact/install trust chain and installs `oidc-login` only when an OIDC profile requires it and it is missing. It never runs a blanket Krew upgrade and does not modify other plugins. `--check` performs no network or Krew-state changes. Profile activation never installs plugins or downloads data; an OIDC profile whose dependency has not been prepared fails closed with an instruction to run `kubebase auth prepare`.

For OIDC profiles, KubeBase creates the normal session-local effective kubeconfig and replaces only the selected auth user's credentials in that copy with the `kubectl oidc-login get-token` exec credential configuration. The source kubeconfig remains unchanged. Runtime/cache data created by `oidc-login` or any other plugin uses that plugin's own defaults; KubeBase does not attempt to relocate or interpret arbitrary plugin state.

Namespace groups are optional KubeBase navigation metadata, not a Kubernetes core resource. A cluster may expose no groups at all; in that case namespace discovery and navigation continue to work normally. Rancher project metadata is represented as a typed `rancher-project` group rather than treating every group as a Rancher project.

Namespace inventory cache is scoped by cluster, user, and Kubernetes context. KubeBase keeps the latest discovery separately from the last complete and last partial snapshots. A partial refresh never destroys the last complete snapshot; an older complete snapshot is historical information and is not treated as proof of current access.

## Security

Credentials, kubeconfigs, and downloaded artifacts are intentionally kept outside the Git repository.

KubeBase also validates permissions on sensitive local files and avoids overwriting user-managed credential data.

KubeBase workspaces are intended to be operated by their owning user. Running normal KubeBase commands with `sudo` can create root-owned session/cache files that the regular user cannot access later. Permission problems are reported separately from malformed JSON; use elevated privileges only to repair ownership when required.

## Status

KubeBase is currently under active development.

Linux support is being implemented first. Windows and macOS support are planned.

The configuration format and command set may still change while the project is evolving.

## Documentation

Full architecture, configuration reference, and usage documentation will be added later.
