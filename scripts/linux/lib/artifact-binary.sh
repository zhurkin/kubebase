#!/usr/bin/env bash

# Shared helpers for resolving the declared executable payload inside a
# verified KubeBase artifact. Callers are responsible for validating artifact
# metadata before passing paths here.

kb_find_tar_member()
{
    local archive="$1"
    local wanted="$2"

    tar --warning=no-unknown-keyword -tzf "$archive" |
        awk \
            -v wanted="$wanted" '
            {
                original = $0
                normalized = $0

                sub(/^\.\//, "", normalized)

                if (!found && normalized == wanted) {
                    print original
                    found = 1
                }
            }
        '
}


kb_find_zip_member()
{
    local archive="$1"
    local wanted="$2"

    unzip -Z1 "$archive" |
        awk \
            -v wanted="$wanted" '
            {
                original = $0
                normalized = $0

                sub(/^\.\//, "", normalized)

                if (!found && normalized == wanted) {
                    print original
                    found = 1
                }
            }
        '
}


kb_artifact_binary_sha256()
{
    local artifact="$1"
    local artifact_type="$2"
    local source_binary="$3"

    local member
    local sha256

    [ -f "$artifact" ] || return 1

    case "$artifact_type" in

        binary)
            sha256="$(
                sha256sum "$artifact" |
                awk '{print $1}'
            )" || return 1
            ;;

        tar.gz)
            command -v tar >/dev/null 2>&1 || return 1

            member="$(
                kb_find_tar_member \
                    "$artifact" \
                    "$source_binary"
            )" || return 1

            [ -n "$member" ] || return 1

            sha256="$(
                tar \
                    --warning=no-unknown-keyword \
                    -xOzf "$artifact" \
                    -- "$member" |
                sha256sum |
                awk '{print $1}'
            )" || return 1
            ;;

        zip)
            command -v unzip >/dev/null 2>&1 || return 1

            member="$(
                kb_find_zip_member \
                    "$artifact" \
                    "$source_binary"
            )" || return 1

            [ -n "$member" ] || return 1

            sha256="$(
                unzip \
                    -p "$artifact" \
                    "$member" |
                sha256sum |
                awk '{print $1}'
            )" || return 1
            ;;

        *)
            return 1
            ;;

    esac

    sha256="${sha256,,}"

    [[ "$sha256" =~ ^[0-9a-f]{64}$ ]] || return 1

    printf '%s\n' "$sha256"
}
