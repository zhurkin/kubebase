#!/usr/bin/env bash

# Source-bound verification of one installed KubeBase tool against the
# immutable artifact store. This is intentionally side-effect free.

_KB_TOOL_INTEGRITY_LIB_DIR="$(
    cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
    pwd -P
)"

if ! declare -F kb_safe_filename >/dev/null 2>&1; then
    source "$_KB_TOOL_INTEGRITY_LIB_DIR/common.sh"
fi

if ! declare -F kb_artifact_binary_sha256 >/dev/null 2>&1; then
    source "$_KB_TOOL_INTEGRITY_LIB_DIR/artifact-binary.sh"
fi

unset _KB_TOOL_INTEGRITY_LIB_DIR

KB_TOOL_INSTALL_SCHEMA="kubebase.toolInstall"
KB_TOOL_INSTALL_SCHEMA_VERSION=1
KB_TOOL_ARTIFACT_SCHEMA="kubebase.artifact"
KB_TOOL_ARTIFACT_SCHEMA_VERSION=2

KB_VERIFIED_TOOL_BINARY=""
KB_VERIFIED_TOOL_SHA256=""


kb_verify_installed_tool_source_bound()
{
    local workspace="$1"
    local requested_tool="$2"
    local requested_version="$3"
    local requested_platform="$4"

    local install_dir="$workspace/tools/$requested_platform/$requested_tool/$requested_version"
    local install_manifest="$install_dir/manifest.json"
    local artifact_dir="$workspace/artifacts/$requested_platform/$requested_tool/$requested_version"
    local artifact_manifest="$artifact_dir/manifest.json"

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
    local actual_sha256
    local source_binary_sha256
    local expected_binary_file

    KB_VERIFIED_TOOL_BINARY=""
    KB_VERIFIED_TOOL_SHA256=""

    [ -f "$install_manifest" ] && [ -r "$install_manifest" ] || return 1
    [ -f "$artifact_manifest" ] && [ -r "$artifact_manifest" ] || return 1

    jq -e \
        --arg schema "$KB_TOOL_INSTALL_SCHEMA" \
        --argjson schemaVersion "$KB_TOOL_INSTALL_SCHEMA_VERSION" \
        --arg tool "$requested_tool" \
        --arg version "$requested_version" \
        --arg platform "$requested_platform" '
        .schema == $schema
        and .schemaVersion == $schemaVersion
        and .tool == $tool
        and .version == $version
        and .platform == $platform
        and (.artifact.file | type) == "string"
        and (.artifact.sha256 | type) == "string"
        and (.binary.sourcePath | type) == "string"
        and (.binary.file | type) == "string"
        and (.binary.sha256 | type) == "string"
    ' "$install_manifest" >/dev/null 2>&1 || return 1

    jq -e \
        --arg schema "$KB_TOOL_ARTIFACT_SCHEMA" \
        --argjson schemaVersion "$KB_TOOL_ARTIFACT_SCHEMA_VERSION" \
        --arg tool "$requested_tool" \
        --arg version "$requested_version" \
        --arg platform "$requested_platform" '
        .schema == $schema
        and .schemaVersion == $schemaVersion
        and .tool == $tool
        and .version == $version
        and .platform == $platform
        and (.artifact.file | type) == "string"
        and (.artifact.type | type) == "string"
        and (.artifact.binary | type) == "string"
        and (.artifact.sha256 | type) == "string"
        and (.checksum.file | type) == "string"
        and (.checksum.sha256 | type) == "string"
    ' "$artifact_manifest" >/dev/null 2>&1 || return 1

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

    kb_safe_filename "$recorded_artifact_file" || return 1
    kb_safe_filename "$binary_file" || return 1
    kb_safe_filename "$artifact_file" || return 1
    kb_safe_relative_path "$recorded_source_binary" || return 1
    kb_safe_relative_path "$artifact_binary" || return 1
    kb_safe_filename "$checksum_file" || return 1

    [[ "$recorded_artifact_sha256" =~ ^[0-9a-f]{64}$ ]] || return 1
    [[ "$binary_sha256" =~ ^[0-9a-f]{64}$ ]] || return 1
    [[ "$artifact_sha256" =~ ^[0-9a-f]{64}$ ]] || return 1
    [[ "$checksum_sha256" =~ ^[0-9a-f]{64}$ ]] || return 1

    expected_binary_file="$requested_tool"
    case "$requested_platform" in
        windows-*) expected_binary_file="${expected_binary_file}.exe" ;;
    esac

    [ "$binary_file" = "$expected_binary_file" ] || return 1
    [ "$recorded_artifact_file" = "$artifact_file" ] || return 1
    [ "$recorded_artifact_sha256" = "$artifact_sha256" ] || return 1
    [ "$recorded_source_binary" = "$artifact_binary" ] || return 1

    [ -f "$artifact_dir/$artifact_file" ] || return 1
    [ -f "$artifact_dir/$checksum_file" ] || return 1

    actual_sha256="$(sha256sum "$artifact_dir/$artifact_file" | awk '{print $1}')"
    actual_sha256="${actual_sha256,,}"
    [ "$actual_sha256" = "$artifact_sha256" ] || return 1

    actual_sha256="$(sha256sum "$artifact_dir/$checksum_file" | awk '{print $1}')"
    actual_sha256="${actual_sha256,,}"
    [ "$actual_sha256" = "$checksum_sha256" ] || return 1

    source_binary_sha256="$(
        kb_artifact_binary_sha256 \
            "$artifact_dir/$artifact_file" \
            "$artifact_type" \
            "$artifact_binary"
    )" || return 1

    [ "$source_binary_sha256" = "$binary_sha256" ] || return 1
    [ -f "$install_dir/$binary_file" ] || return 1
    [ -x "$install_dir/$binary_file" ] || return 1

    actual_sha256="$(sha256sum "$install_dir/$binary_file" | awk '{print $1}')"
    actual_sha256="${actual_sha256,,}"
    [ "$actual_sha256" = "$source_binary_sha256" ] || return 1

    KB_VERIFIED_TOOL_BINARY="$install_dir/$binary_file"
    KB_VERIFIED_TOOL_SHA256="$source_binary_sha256"
    return 0
}
