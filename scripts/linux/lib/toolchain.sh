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


# Additional direct command aliases for a tool. Canonical kubectl plugins keep
# kubectl-<name> so kubectl can discover them; aliases are convenience names.
kb_tool_alias_names()
{
    local tool="$1"

    case "$tool" in
        krew)
            printf 'krew\n'
            ;;
    esac
}
