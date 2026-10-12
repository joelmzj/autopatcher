#!/usr/bin/env bash
# patch_manager.sh - Gestor de versiones y estado para compilación condicional

STATE_FILE="${RVB_STATE_FILE:-state/patch_sources.json}"

init_state() {
    local dir
    dir=$(dirname "$STATE_FILE")
    [ -d "$dir" ] || mkdir -p "$dir"
    [ -f "$STATE_FILE" ] || echo "{}" > "$STATE_FILE"
}

# Petición segura adaptada por tipo de host (GitHub, Codeberg, GitLab)
source_release_req() {
    local host="${1,,}"
    local url="$2"
    local op="${3:--}"
    case "$host" in
        github)
            if declare -f gh_req >/dev/null; then
                gh_req "$url" "$op"
            else
                local headers=()
                [ -n "${GH_HEADER:-}" ] && headers=(-H "$GH_HEADER")
                _req "$url" "$op" "${headers[@]}"
            fi
            ;;
        codeberg | gitlab)
            _req "$url" "$op"
            ;;
        *)
            _req "$url" "$op"
            ;;
    esac
}

# Obtiene la última versión remota de los parches
get_latest_remote_tag() {
    local host="${1:-github}"
    local repo="$2"
    local channel="${3:-stable}"
    
    if declare -f source_release_list_url >/dev/null; then
        local list_url
        list_url=$(source_release_list_url "$host" "$repo") || return 1
        local resp
        resp=$(source_release_req "$host" "$list_url" -) || return 1
        source_release_pick_from_list "$host" "$channel" <<<"$resp" | jq -r '.tag_name // empty'
    else
        # Fallback directo si las funciones base no están cargadas
        local api_url="https://api.github.com/repos/${repo}/releases"
        local resp
        resp=$(source_release_req "$host" "$api_url" -) || return 1
        if [ "$channel" = "beta" ]; then
            jq -r 'map(select(.prerelease == true and .draft != true)) | sort_by(.published_at) | reverse | .[0].tag_name // empty' <<<"$resp"
        else
            jq -r 'map(select(.prerelease != true and .draft != true)) | sort_by(.published_at) | reverse | .[0].tag_name // empty' <<<"$resp"
        fi
    fi
}

# Evalúa si la app debe compilarse (Condición 1 o Condición 2)
should_build_app() {
    local repo="$1"
    local host="${2:-github}"
    local channel="${3:-stable}"
    local current_apk_ver="$4"
    
    init_state

    local latest_patch_ver
    latest_patch_ver=$(get_latest_remote_tag "$host" "$repo" "$channel")

    if [ -z "$latest_patch_ver" ]; then
        echo -e "\033[0;33m[!] No se pudo consultar la versión remota para $repo ($host). Forzando compilación por seguridad.\033[0m" >&2
        return 0
    fi

    local cached_patch_ver last_built_ver
    cached_patch_ver=$(jq -r --arg r "$repo" --arg ch "$channel" '.[$r][$ch] // ""' "$STATE_FILE")
    last_built_ver=$(jq -r --arg r "$repo" '.[$r].last_built_apk_version // ""' "$STATE_FILE")

    # Condición 1: Nueva versión de parches
    if [ "$latest_patch_ver" != "$cached_patch_ver" ]; then
        echo -e "\033[0;32m[+] ¡Nueva versión de parches detectada para $repo! [$cached_patch_ver -> $latest_patch_ver]\033[0m" >&2
        return 0
    fi

    # Condición 2: Nueva versión de APK objetivo (no parchada previamente)
    if [ "$current_apk_ver" != "$last_built_ver" ]; then
        echo -e "\033[0;32m[+] ¡Nueva versión de APK objetivo detectada para $repo! [$last_built_ver -> $current_apk_ver]\033[0m" >&2
        return 0
    fi

    echo -e "\033[0;32m[+] Sin cambios en parches ($cached_patch_ver) ni en la APK ($current_apk_ver). Omitiendo compilación.\033[0m" >&2
    return 1
}

# Actualiza el registro de estado tras una compilación exitosa
update_build_state() {
    local repo="$1"
    local channel="${2:-stable}"
    local patch_ver="$3"
    local apk_ver="$4"
    
    init_state
    local tmp
    tmp=$(mktemp)
    jq --arg r "$repo" --arg ch "$channel" --arg pv "$patch_ver" --arg av "$apk_ver" \
       '.[$r][$ch] = $pv | .[$r].last_built_apk_version = $av | .[$r].last_build_timestamp = (now | floor)' \
       "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
}