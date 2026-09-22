#!/usr/bin/env bash

# Shared KubeBase Linux/Bash helpers.
#
# This file is a library. Sourcing it must not change shell options,
# install traps, parse arguments, or perform I/O beyond function calls.

kb_fail()
{
    echo "ERROR: $*" >&2
    exit 1
}


kb_warn()
{
    echo "WARNING: $*" >&2
}


kb_canonical_file()
{
    local path="$1"
    local dir
    local file

    dir="$(dirname -- "$path")"
    file="$(basename -- "$path")"

    (
        cd -- "$dir"
        printf '%s/%s\n' "$(pwd -P)" "$file"
    )
}


kb_safe_name()
{
    local value="$1"

    [[ "$value" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]
}


kb_safe_filename()
{
    local value="$1"

    [[ "$value" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]]
}


kb_safe_relative_path()
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


kb_require_readable_file()
{
    local path="$1"
    local description="${2:-file}"
    local owner=""
    local mode=""
    local current_user=""

    if [ ! -e "$path" ] && [ ! -L "$path" ]; then
        kb_fail "$description not found: $path"
    fi

    [ -f "$path" ] || \
        kb_fail "$description is not a regular file: $path"

    if [ ! -r "$path" ]; then
        echo "ERROR: $description is not readable: $path" >&2

        if command -v id >/dev/null 2>&1; then
            current_user="$(id -un 2>/dev/null || true)"
            if [ -n "$current_user" ]; then
                echo "  current user : $current_user" >&2
            fi
        fi

        if command -v stat >/dev/null 2>&1; then
            owner="$(stat -Lc '%U:%G' "$path" 2>/dev/null || true)"
            mode="$(stat -Lc '%a' "$path" 2>/dev/null || true)"

            if [ -n "$owner" ]; then
                echo "  file owner   : $owner" >&2
            fi

            if [ -n "$mode" ]; then
                echo "  file mode    : $mode" >&2
            fi
        fi

        exit 1
    fi
}


kb_require_readable_json_file()
{
    local path="$1"
    local description="${2:-JSON file}"

    kb_require_readable_file "$path" "$description"

    jq empty "$path" >/dev/null 2>&1 || \
        kb_fail "invalid JSON in $description: $path"
}


kb_file_permissions_are_private()
{
    local path="$1"
    local mode
    local mode_value

    mode="$(stat -Lc '%a' "$path")"

    [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1

    mode_value=$((8#$mode))

    (( (mode_value & 077) == 0 ))
}


kb_file_mode()
{
    stat -Lc '%a' "$1"
}


kb_shell_export()
{
    local name="$1"
    local value="$2"

    printf 'export %s=%q\n' "$name" "$value"
}


kb_shell_unset()
{
    local name="$1"

    printf 'unset %s\n' "$name"
}


kb_detect_host_platform()
{
    local component="${1:-}"
    local os_name
    local arch_name

    case "$(uname -s)" in
        Linux)
            os_name="linux"
            ;;
        *)
            if [ -n "$component" ]; then
                kb_fail "unsupported host operating system for $component: $(uname -s)"
            else
                kb_fail "unsupported host operating system: $(uname -s)"
            fi
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
            kb_fail "unsupported host architecture: $(uname -m)"
            ;;
    esac

    printf '%s-%s\n' "$os_name" "$arch_name"
}


kb_first_nonempty_line_file()
{
    awk 'NF { print; exit }' "$1"
}


kb_first_nonempty_line_text()
{
    local text="$1"

    awk '
        NF {
            print
            exit
        }
    ' <<< "$text"
}
