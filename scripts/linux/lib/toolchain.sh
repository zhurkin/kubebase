#!/usr/bin/env bash

# Shared KubeBase toolchain helpers.

kb_tool_command_name()
{
    local tool="$1"

    case "$tool" in
        krew)
            printf 'kubectl-krew\n'
            ;;
        *)
            printf '%s\n' "$tool"
            ;;
    esac
}
