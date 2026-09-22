#!/usr/bin/env bash

# Shared helpers for the KubeBase-managed OIDC authentication overlay.
#
# KubeBase does not manage arbitrary Krew plugins. oidc-login is the single
# system dependency installed on demand when a profile explicitly declares
# auth.type=oidc. Runtime/cache data remains owned by oidc-login itself.

kb_user_auth_type()
{
    local cluster_file="$1"
    local user_name="$2"

    jq -r \
        --arg user "$user_name" '
        .users[$user].auth.type // ""
    ' "$cluster_file"
}


kb_user_uses_oidc()
{
    local cluster_file="$1"
    local user_name="$2"

    [ "$(kb_user_auth_type "$cluster_file" "$user_name")" = "oidc" ]
}


kb_cluster_has_oidc_users()
{
    local cluster_file="$1"

    jq -e '
        [.users[] | select(.auth?.type == "oidc")] | length > 0
    ' "$cluster_file" >/dev/null 2>&1
}


kb_krew_root_for_cluster()
{
    local workspace="$1"
    local cluster="$2"
    local platform="$3"

    printf '%s/krew/%s/%s\n' "$workspace" "$cluster" "$platform"
}


kb_oidc_plugin_path()
{
    local krew_root="$1"

    printf '%s/bin/kubectl-oidc_login\n' "$krew_root"
}


kb_oidc_overlay_kubeconfig_json()
{
    local cluster_file="$1"
    local user_name="$2"
    local auth_user="$3"
    local input_file="$4"
    local output_file="$5"

    local issuer_url
    local client_id
    local grant_type

    issuer_url="$(
        jq -r \
            --arg user "$user_name" '
            .users[$user].auth.issuerUrl
        ' "$cluster_file"
    )"

    client_id="$(
        jq -r \
            --arg user "$user_name" '
            .users[$user].auth.clientId
        ' "$cluster_file"
    )"

    grant_type="$(
        jq -r \
            --arg user "$user_name" '
            .users[$user].auth.grantType // ""
        ' "$cluster_file"
    )"

    jq \
        --arg authUser "$auth_user" \
        --arg issuerUrl "$issuer_url" \
        --arg clientId "$client_id" \
        --arg grantType "$grant_type" '

        def oidc_args:
            [
                "oidc-login",
                "get-token",
                "--oidc-issuer-url=" + $issuerUrl,
                "--oidc-client-id=" + $clientId
            ]
            +
            (
                if $grantType == "" then
                    []
                else
                    ["--grant-type=" + $grantType]
                end
            );

        if ([.users[] | select(.name == $authUser)] | length) != 1 then
            error("selected auth user is not unique in flattened kubeconfig")
        else
            (.users[] | select(.name == $authUser).user) = {
                exec: {
                    apiVersion: "client.authentication.k8s.io/v1",
                    command: "kubectl",
                    args: oidc_args,
                    interactiveMode: "Never"
                }
            }
        end
    ' "$input_file" > "$output_file"
}
