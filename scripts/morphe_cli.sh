#!/usr/bin/env bash
# morphe_cli.sh - Gestor de descarga para la CLI de Morphe Desktop

get_morphe_desktop_cli() {
    local channel="${1:-stable}"
    local morphe_repo="MorpheApp/morphe-desktop"
    local dir="temp/morphe"
    [ -d "$dir" ] || mkdir -p "$dir"

    pr "Consultando la última versión de Morphe Desktop CLI (Canal: $channel)..."
    local api_url="https://api.github.com/repos/${morphe_repo}/releases"
    
    local resp
    if declare -f source_release_req >/dev/null; then
        resp=$(source_release_req "github" "$api_url" -) || return 1
    else
        resp=$(curl -s -L "$api_url") || return 1
    fi

    local release
    if [ "$channel" = "dev" ]; then
        release=$(jq -e -c 'map(select(.draft != true)) | sort_by(.published_at) | reverse | .[0] // empty' <<<"$resp")
    else
        release=$(jq -e -c 'map(select(.prerelease != true and .draft != true)) | sort_by(.published_at) | reverse | .[0] // empty' <<<"$resp")
    fi

    local tag_name
    tag_name=$(jq -r '.tag_name // empty' <<<"$release")
    if [ -z "$tag_name" ]; then
        epr "No se encontró una versión válida de Morphe Desktop para el canal $channel"
        return 1
    fi

    local cli_jar="$dir/morphe-desktop-${tag_name}-all.jar"
    if [ -f "$cli_jar" ]; then
        echo "$cli_jar"
        return 0
    fi

    local dl_url
    dl_url=$(jq -r '.assets[]? | select(.name | endswith(".jar")) | .browser_download_url' <<<"$release" | head -1)

    if [ -z "$dl_url" ] || [ "$dl_url" = "null" ]; then
        epr "No se encontró el archivo ejecutable .jar en el release $tag_name de Morphe Desktop"
        return 1
    fi

    pr "Descargando Morphe Desktop CLI ($tag_name) desde: $dl_url"
    if declare -f gh_dl >/dev/null; then
        gh_dl "$cli_jar" "$dl_url" || curl -L -s -S "$dl_url" -o "$cli_jar" || return 1
    else
        curl -L -s -S "$dl_url" -o "$cli_jar" || return 1
    fi

    echo "$cli_jar"
}