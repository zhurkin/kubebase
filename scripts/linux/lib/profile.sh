#!/usr/bin/env bash

# Shared KubeBase profile/kubeconfig query helpers.
# These functions do not perform network access and do not mutate kubeconfig.

kb_profile_select_context()
{
    local cluster_file="$1"
    local user="$2"
    local kubeconfig_json="$3"
    local declared_context

    KB_PROFILE_CURRENT_CONTEXT="$(
        jq -r '."current-context" // ""' <<< "$kubeconfig_json"
    )"

    declared_context="$(
        jq -r \
            --arg user "$user" '
            .users[$user].context // ""
        ' "$cluster_file"
    )"

    if [ -n "$declared_context" ]; then
        KB_PROFILE_SELECTED_CONTEXT="$declared_context"
        KB_PROFILE_CONTEXT_SELECTION="KubeBase user.context"
    else
        KB_PROFILE_SELECTED_CONTEXT="$KB_PROFILE_CURRENT_CONTEXT"
        KB_PROFILE_CONTEXT_SELECTION="kubeconfig current-context"
    fi
}


kb_profile_context_count()
{
    local kubeconfig_json="$1"
    local context="$2"

    jq -r \
        --arg context "$context" '
        [
            .contexts[]
            | select(.name == $context)
        ]
        | length
    ' <<< "$kubeconfig_json"
}


kb_profile_context_cluster()
{
    local kubeconfig_json="$1"
    local context="$2"

    jq -r \
        --arg context "$context" '
        .contexts[]
        | select(.name == $context)
        | .context.cluster // ""
    ' <<< "$kubeconfig_json"
}


kb_profile_context_user()
{
    local kubeconfig_json="$1"
    local context="$2"

    jq -r \
        --arg context "$context" '
        .contexts[]
        | select(.name == $context)
        | .context.user // ""
    ' <<< "$kubeconfig_json"
}


kb_profile_context_namespace()
{
    local kubeconfig_json="$1"
    local context="$2"

    jq -r \
        --arg context "$context" '
        .contexts[]
        | select(.name == $context)
        | .context.namespace // ""
    ' <<< "$kubeconfig_json"
}
