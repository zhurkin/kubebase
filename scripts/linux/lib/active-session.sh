#!/usr/bin/env bash

# Integrity verification for an already active KubeBase shell session.
#
# This helper intentionally does not mutate or repair state. It verifies that
# the shell environment still refers to the session created by `kubebase use`
# and that the materialized kubectl remains source-bound to the verified
# artifact/install store before callers execute it.

_KB_ACTIVE_SESSION_LIB_DIR="$(
    cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
    pwd -P
)"

if ! declare -F kb_fail >/dev/null 2>&1; then
    source "$_KB_ACTIVE_SESSION_LIB_DIR/common.sh"
fi

if ! declare -F kb_artifact_binary_sha256 >/dev/null 2>&1; then
    source "$_KB_ACTIVE_SESSION_LIB_DIR/artifact-binary.sh"
fi

if ! declare -F kb_user_auth_type >/dev/null 2>&1; then
    source "$_KB_ACTIVE_SESSION_LIB_DIR/oidc.sh"
fi

unset _KB_ACTIVE_SESSION_LIB_DIR

KB_ACTIVE_SESSION_SCHEMA="kubebase.session"
KB_ACTIVE_SESSION_SCHEMA_VERSION=1
KB_ACTIVE_CLUSTER_SCHEMA="kubebase.cluster"
KB_ACTIVE_CLUSTER_SCHEMA_VERSION=1
KB_ACTIVE_TOOLCHAIN_SCHEMA="kubebase.clusterToolchain"
KB_ACTIVE_TOOLCHAIN_SCHEMA_VERSION=1
KB_ACTIVE_INSTALL_SCHEMA="kubebase.toolInstall"
KB_ACTIVE_INSTALL_SCHEMA_VERSION=1
KB_ACTIVE_ARTIFACT_SCHEMA="kubebase.artifact"
KB_ACTIVE_ARTIFACT_SCHEMA_VERSION=2

KB_ACTIVE_KUBECTL_BIN=""
KB_ACTIVE_KUBECTL_VERSION=""
KB_ACTIVE_TOOLCHAIN_DIR=""
KB_ACTIVE_SESSION_ERROR=""


kb_active_session_error()
{
    KB_ACTIVE_SESSION_ERROR="$1"
    return 1
}


kb_verify_active_session_kubectl()
{
    local workspace="${KUBEBASE_WORKSPACE:-}"
    local cluster="${KUBEBASE_CLUSTER:-}"
    local user="${KUBEBASE_USER:-}"
    local context="${KUBEBASE_CONTEXT:-}"
    local platform="${KUBEBASE_PLATFORM:-}"
    local toolchain="${KUBEBASE_TOOLCHAIN:-}"
    local toolchain_bin="${KUBEBASE_TOOLCHAIN_BIN:-}"
    local source_kubeconfig="${KUBEBASE_SOURCE_KUBECONFIG:-}"
    local effective_kubeconfig="${KUBEBASE_EFFECTIVE_KUBECONFIG:-}"
    local session_dir="${KUBEBASE_SESSION_DIR:-}"
    local krew_root="${KUBEBASE_KREW_ROOT:-}"

    local cluster_dir
    local cluster_file
    local expected_toolchain
    local expected_toolchain_bin
    local expected_krew_root=""
    local expected_auth_type=""
    local session_manifest
    local sessions_dir
    local session_parent
    local session_name
    local kubectl_version
    local install_dir
    local install_manifest
    local artifact_dir
    local artifact_manifest
    local toolchain_manifest
    local command_path
    local recorded_artifact_file
    local recorded_artifact_sha256
    local recorded_source_binary
    local binary_file
    local binary_sha256
    local artifact_file
    local artifact_type
    local artifact_binary
    local artifact_sha256
    local checksum_file
    local checksum_sha256
    local expected_target
    local actual_target
    local actual_sha256
    local source_binary_sha256

    KB_ACTIVE_KUBECTL_BIN=""
    KB_ACTIVE_KUBECTL_VERSION=""
    KB_ACTIVE_TOOLCHAIN_DIR=""
    KB_ACTIVE_SESSION_ERROR=""

    [ "${KUBEBASE_ACTIVE:-}" = "1" ] || { kb_active_session_error "no active KubeBase profile; run 'kubebase use' first"; return 1; }

    [ -n "$workspace" ] || { kb_active_session_error "active profile has no workspace"; return 1; }
    [ -n "$cluster" ] || { kb_active_session_error "active profile has no cluster"; return 1; }
    [ -n "$user" ] || { kb_active_session_error "active profile has no user"; return 1; }
    [ -n "$context" ] || { kb_active_session_error "active profile has no context"; return 1; }
    [ -n "$platform" ] || { kb_active_session_error "active profile has no platform"; return 1; }
    [ -n "$toolchain" ] || { kb_active_session_error "active profile has no toolchain"; return 1; }
    [ -n "$toolchain_bin" ] || { kb_active_session_error "active profile has no toolchain bin"; return 1; }
    [ -n "$source_kubeconfig" ] || { kb_active_session_error "active profile has no source kubeconfig"; return 1; }
    [ -n "$effective_kubeconfig" ] || { kb_active_session_error "active profile has no effective kubeconfig"; return 1; }
    [ -n "$session_dir" ] || { kb_active_session_error "active profile has no session directory"; return 1; }

    [ -d "$workspace" ] && [ ! -L "$workspace" ] || { kb_active_session_error "active workspace is missing or unsafe: $workspace"; return 1; }

    kb_safe_name "$cluster" || { kb_active_session_error "active cluster name is unsafe: $cluster"; return 1; }
    kb_safe_name "$user" || { kb_active_session_error "active user name is unsafe: $user"; return 1; }
    kb_safe_name "$platform" || { kb_active_session_error "active platform name is unsafe: $platform"; return 1; }

    cluster_dir="$workspace/clusters/$cluster"
    cluster_file="$cluster_dir/cluster.json"
    expected_toolchain="$cluster_dir/toolchains/$platform"
    expected_toolchain_bin="$expected_toolchain/bin"
    sessions_dir="$workspace/.kubebase/sessions"
    session_manifest="$session_dir/session.json"

    [ "$toolchain" = "$expected_toolchain" ] || { kb_active_session_error "active toolchain does not match the selected cluster/platform"; return 1; }

    [ "$toolchain_bin" = "$expected_toolchain_bin" ] || { kb_active_session_error "active toolchain bin does not match the selected cluster/platform"; return 1; }

    [ "${KUBECONFIG:-}" = "$effective_kubeconfig" ] || { kb_active_session_error "KUBECONFIG no longer matches the active KubeBase session"; return 1; }

    [ -d "$sessions_dir" ] && [ ! -L "$sessions_dir" ] || { kb_active_session_error "KubeBase sessions directory is missing or unsafe: $sessions_dir"; return 1; }

    [ -d "$session_dir" ] && [ ! -L "$session_dir" ] || { kb_active_session_error "active KubeBase session is missing or unsafe: $session_dir"; return 1; }

    session_parent="$(dirname -- "$session_dir")"
    session_name="$(basename -- "$session_dir")"

    [ "$session_parent" = "$sessions_dir" ] || { kb_active_session_error "active KubeBase session is outside the session root"; return 1; }

    case "$session_name" in
        session.*) ;;
        *) kb_active_session_error "active KubeBase session has an unexpected name: $session_name"; return 1 ;;
    esac

    [ -f "$session_manifest" ] && [ ! -L "$session_manifest" ] && [ -r "$session_manifest" ] || { kb_active_session_error "active KubeBase session metadata is missing or unsafe"; return 1; }

    [ -f "$effective_kubeconfig" ] && [ ! -L "$effective_kubeconfig" ] && [ -r "$effective_kubeconfig" ] || { kb_active_session_error "effective kubeconfig is missing or unsafe: $effective_kubeconfig"; return 1; }

    [ -f "$source_kubeconfig" ] && [ -r "$source_kubeconfig" ] || { kb_active_session_error "source kubeconfig is missing: $source_kubeconfig"; return 1; }

    jq -e \
        --arg schema "$KB_ACTIVE_SESSION_SCHEMA" \
        --argjson version "$KB_ACTIVE_SESSION_SCHEMA_VERSION" \
        --arg workspace "$workspace" \
        --arg cluster "$cluster" \
        --arg user "$user" \
        --arg context "$context" \
        --arg platform "$platform" \
        --arg sourceKubeconfig "$source_kubeconfig" \
        --arg effectiveKubeconfig "$effective_kubeconfig" \
        --arg toolchain "$toolchain" \
        --arg krewRoot "$krew_root" \
        --arg authType "$(jq -r --arg user "$user" '.users[$user].auth.type // ""' "$cluster_file" 2>/dev/null || true)" '
        .schema == $schema
        and .schemaVersion == $version
        and .workspace == $workspace
        and .profile.cluster == $cluster
        and .profile.user == $user
        and .profile.context == $context
        and .profile.platform == $platform
        and .kubeconfig.source == $sourceKubeconfig
        and .kubeconfig.effective == $effectiveKubeconfig
        and .toolchain == $toolchain
        and ((.krewRoot // "") == $krewRoot)
        and ((.authType // "") == $authType)
    ' "$session_manifest" >/dev/null 2>&1 || { kb_active_session_error "active KubeBase session metadata does not match the shell profile"; return 1; }

    [ -f "$cluster_file" ] && [ -r "$cluster_file" ] || { kb_active_session_error "active cluster definition is missing: $cluster_file"; return 1; }

    jq -e \
        --arg schema "$KB_ACTIVE_CLUSTER_SCHEMA" \
        --argjson version "$KB_ACTIVE_CLUSTER_SCHEMA_VERSION" \
        --arg cluster "$cluster" \
        --arg platform "$platform" '
        .schema == $schema
        and .schemaVersion == $version
        and .name == $cluster
        and (.toolPlatforms | index($platform) != null)
        and (.tools.kubectl.version | type) == "string"
        and (.tools.kubectl.enabled? != false)
    ' "$cluster_file" >/dev/null 2>&1 || { kb_active_session_error "active cluster definition is invalid"; return 1; }

    if jq -e '
        (.tools.krew? | type) == "object"
        and (.tools.krew.enabled? != false)
    ' "$cluster_file" >/dev/null 2>&1; then
        expected_krew_root="$(kb_krew_root_for_cluster "$workspace" "$cluster" "$platform")"
        [ "$krew_root" = "$expected_krew_root" ] || { kb_active_session_error "active Krew root does not match the selected cluster/platform"; return 1; }
        [ "${KREW_ROOT:-}" = "$expected_krew_root" ] || { kb_active_session_error "KREW_ROOT no longer matches the active KubeBase profile"; return 1; }
    else
        [ -z "$krew_root" ] || { kb_active_session_error "active profile unexpectedly declares a Krew root"; return 1; }
    fi

    expected_auth_type="$(kb_user_auth_type "$cluster_file" "$user")"
    if [ "$expected_auth_type" = "oidc" ]; then
        [ -n "$expected_krew_root" ] || { kb_active_session_error "OIDC profile has no active Krew root"; return 1; }
        [ -x "$(kb_oidc_plugin_path "$expected_krew_root")" ] || { kb_active_session_error "OIDC dependency oidc-login is missing from the active Krew environment"; return 1; }
    fi

    kubectl_version="$(jq -r '.tools.kubectl.version' "$cluster_file")"
    kb_safe_name "$kubectl_version" || { kb_active_session_error "active cluster declares an unsafe kubectl version"; return 1; }

    install_dir="$workspace/tools/$platform/kubectl/$kubectl_version"
    install_manifest="$install_dir/manifest.json"
    artifact_dir="$workspace/artifacts/$platform/kubectl/$kubectl_version"
    artifact_manifest="$artifact_dir/manifest.json"
    toolchain_manifest="$toolchain/manifest.json"
    command_path="$toolchain_bin/kubectl"

    [ -f "$install_manifest" ] && [ -r "$install_manifest" ] || { kb_active_session_error "installed kubectl manifest is missing"; return 1; }

    [ -f "$artifact_manifest" ] && [ -r "$artifact_manifest" ] || { kb_active_session_error "kubectl artifact manifest is missing"; return 1; }

    [ -f "$toolchain_manifest" ] && [ -r "$toolchain_manifest" ] || { kb_active_session_error "active toolchain manifest is missing"; return 1; }

    jq -e \
        --arg schema "$KB_ACTIVE_INSTALL_SCHEMA" \
        --argjson version "$KB_ACTIVE_INSTALL_SCHEMA_VERSION" \
        --arg tool "kubectl" \
        --arg toolVersion "$kubectl_version" \
        --arg platform "$platform" '
        .schema == $schema
        and .schemaVersion == $version
        and .tool == $tool
        and .version == $toolVersion
        and .platform == $platform
        and (.artifact.file | type) == "string"
        and (.artifact.sha256 | type) == "string"
        and (.binary.sourcePath | type) == "string"
        and (.binary.file | type) == "string"
        and (.binary.sha256 | type) == "string"
    ' "$install_manifest" >/dev/null 2>&1 || { kb_active_session_error "installed kubectl manifest is invalid"; return 1; }

    jq -e \
        --arg schema "$KB_ACTIVE_ARTIFACT_SCHEMA" \
        --argjson version "$KB_ACTIVE_ARTIFACT_SCHEMA_VERSION" \
        --arg tool "kubectl" \
        --arg toolVersion "$kubectl_version" \
        --arg platform "$platform" '
        .schema == $schema
        and .schemaVersion == $version
        and .tool == $tool
        and .version == $toolVersion
        and .platform == $platform
        and (.artifact.file | type) == "string"
        and (.artifact.type | type) == "string"
        and (.artifact.binary | type) == "string"
        and (.artifact.sha256 | type) == "string"
        and (.checksum.file | type) == "string"
        and (.checksum.sha256 | type) == "string"
    ' "$artifact_manifest" >/dev/null 2>&1 || { kb_active_session_error "kubectl artifact manifest is invalid"; return 1; }

    recorded_artifact_file="$(jq -r '.artifact.file' "$install_manifest")"
    recorded_artifact_sha256="$(jq -r '.artifact.sha256' "$install_manifest")"
    recorded_source_binary="$(jq -r '.binary.sourcePath' "$install_manifest")"
    binary_file="$(jq -r '.binary.file' "$install_manifest")"
    binary_sha256="$(jq -r '.binary.sha256' "$install_manifest")"

    artifact_file="$(jq -r '.artifact.file' "$artifact_manifest")"
    artifact_type="$(jq -r '.artifact.type' "$artifact_manifest")"
    artifact_binary="$(jq -r '.artifact.binary' "$artifact_manifest")"
    artifact_sha256="$(jq -r '.artifact.sha256' "$artifact_manifest")"
    checksum_file="$(jq -r '.checksum.file' "$artifact_manifest")"
    checksum_sha256="$(jq -r '.checksum.sha256' "$artifact_manifest")"

    recorded_artifact_sha256="${recorded_artifact_sha256,,}"
    binary_sha256="${binary_sha256,,}"
    artifact_sha256="${artifact_sha256,,}"
    checksum_sha256="${checksum_sha256,,}"

    kb_safe_filename "$recorded_artifact_file" || { kb_active_session_error "installed kubectl artifact filename is unsafe"; return 1; }
    kb_safe_filename "$binary_file" || { kb_active_session_error "installed kubectl binary filename is unsafe"; return 1; }
    kb_safe_filename "$artifact_file" || { kb_active_session_error "kubectl artifact filename is unsafe"; return 1; }
    kb_safe_relative_path "$recorded_source_binary" || { kb_active_session_error "installed kubectl source path is unsafe"; return 1; }
    kb_safe_relative_path "$artifact_binary" || { kb_active_session_error "kubectl artifact binary path is unsafe"; return 1; }
    kb_safe_filename "$checksum_file" || { kb_active_session_error "kubectl checksum filename is unsafe"; return 1; }

    [[ "$recorded_artifact_sha256" =~ ^[0-9a-f]{64}$ ]] || { kb_active_session_error "installed kubectl artifact SHA-256 is invalid"; return 1; }
    [[ "$binary_sha256" =~ ^[0-9a-f]{64}$ ]] || { kb_active_session_error "installed kubectl binary SHA-256 is invalid"; return 1; }
    [[ "$artifact_sha256" =~ ^[0-9a-f]{64}$ ]] || { kb_active_session_error "kubectl artifact SHA-256 is invalid"; return 1; }
    [[ "$checksum_sha256" =~ ^[0-9a-f]{64}$ ]] || { kb_active_session_error "kubectl checksum SHA-256 is invalid"; return 1; }

    [ "$binary_file" = "kubectl" ] || { kb_active_session_error "installed kubectl binary filename changed"; return 1; }
    [ "$recorded_artifact_file" = "$artifact_file" ] || { kb_active_session_error "installed kubectl artifact binding changed"; return 1; }
    [ "$recorded_artifact_sha256" = "$artifact_sha256" ] || { kb_active_session_error "installed kubectl artifact SHA-256 binding changed"; return 1; }
    [ "$recorded_source_binary" = "$artifact_binary" ] || { kb_active_session_error "installed kubectl source path binding changed"; return 1; }

    [ -f "$artifact_dir/$artifact_file" ] || { kb_active_session_error "kubectl artifact payload is missing"; return 1; }
    [ -f "$artifact_dir/$checksum_file" ] || { kb_active_session_error "kubectl checksum sidecar is missing"; return 1; }

    actual_sha256="$(sha256sum "$artifact_dir/$artifact_file" | awk '{print $1}')"
    actual_sha256="${actual_sha256,,}"
    [ "$actual_sha256" = "$artifact_sha256" ] || { kb_active_session_error "kubectl artifact payload failed SHA-256 verification"; return 1; }

    actual_sha256="$(sha256sum "$artifact_dir/$checksum_file" | awk '{print $1}')"
    actual_sha256="${actual_sha256,,}"
    [ "$actual_sha256" = "$checksum_sha256" ] || { kb_active_session_error "kubectl checksum sidecar failed SHA-256 verification"; return 1; }

    if ! source_binary_sha256="$(
        kb_artifact_binary_sha256 \
            "$artifact_dir/$artifact_file" \
            "$artifact_type" \
            "$artifact_binary"
    )"; then
        kb_active_session_error "kubectl executable payload could not be verified from the artifact"
        return 1
    fi

    [ "$source_binary_sha256" = "$binary_sha256" ] || { kb_active_session_error "installed kubectl binary is not source-bound to the artifact"; return 1; }
    [ -f "$install_dir/$binary_file" ] || { kb_active_session_error "installed kubectl binary is missing"; return 1; }
    [ -x "$install_dir/$binary_file" ] || { kb_active_session_error "installed kubectl binary is not executable"; return 1; }

    actual_sha256="$(sha256sum "$install_dir/$binary_file" | awk '{print $1}')"
    actual_sha256="${actual_sha256,,}"
    [ "$actual_sha256" = "$source_binary_sha256" ] || { kb_active_session_error "installed kubectl binary failed SHA-256 verification"; return 1; }

    expected_target="../../../../../tools/$platform/kubectl/$kubectl_version/$binary_file"

    jq -e \
        --arg schema "$KB_ACTIVE_TOOLCHAIN_SCHEMA" \
        --argjson version "$KB_ACTIVE_TOOLCHAIN_SCHEMA_VERSION" \
        --arg cluster "$cluster" \
        --arg platform "$platform" \
        --arg toolVersion "$kubectl_version" \
        --arg binary "$binary_file" \
        --arg sha256 "$source_binary_sha256" \
        --arg target "$expected_target" '
        .schema == $schema
        and .schemaVersion == $version
        and .cluster == $cluster
        and .platform == $platform
        and (.commands.kubectl | type) == "object"
        and .commands.kubectl.tool == "kubectl"
        and .commands.kubectl.version == $toolVersion
        and .commands.kubectl.binary == $binary
        and ((.commands.kubectl.sha256 | ascii_downcase) == $sha256)
        and .commands.kubectl.linkTarget == $target
    ' "$toolchain_manifest" >/dev/null 2>&1 || { kb_active_session_error "active toolchain kubectl entry failed integrity verification"; return 1; }

    [ -L "$command_path" ] || { kb_active_session_error "active toolchain kubectl is not a managed symlink"; return 1; }
    [ -x "$command_path" ] || { kb_active_session_error "active toolchain kubectl is not executable"; return 1; }

    actual_target="$(readlink -- "$command_path")"
    [ "$actual_target" = "$expected_target" ] || { kb_active_session_error "active toolchain kubectl symlink target changed"; return 1; }

    actual_sha256="$(sha256sum "$command_path" | awk '{print $1}')"
    actual_sha256="${actual_sha256,,}"
    [ "$actual_sha256" = "$source_binary_sha256" ] || { kb_active_session_error "active toolchain kubectl failed SHA-256 verification"; return 1; }

    KB_ACTIVE_KUBECTL_BIN="$command_path"
    KB_ACTIVE_KUBECTL_VERSION="$kubectl_version"
    KB_ACTIVE_TOOLCHAIN_DIR="$toolchain"
    return 0
}
