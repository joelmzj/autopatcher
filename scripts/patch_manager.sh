#!/usr/bin/env bash
# patch_manager.sh - Gestor de decisión de compilación
# La fuente única de verdad es versions_log.json (keyed por app).
# Se eliminó patch_sources.json (keyed por repo → colisión entre apps).

VERSIONS_LOG_FILE="${RVB_VERSIONS_LOG:-versions_log.json}"

# ==============================================================================
# Obtiene la última versión remota de los parches
# ==============================================================================
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
        local api_url="https://api.github.com/repos/${repo}/releases"
        local resp
        resp=$(source_release_req "$host" "$api_url" -) || return 1
        if [ "$channel" = "beta" ] || [ "$channel" = "dev" ]; then
            jq -r 'map(select(.prerelease == true and .draft != true)) | sort_by(.published_at) | reverse | .[0].tag_name // empty' <<<"$resp"
        else
            jq -r 'map(select(.prerelease != true and .draft != true)) | sort_by(.published_at) | reverse | .[0].tag_name // empty' <<<"$resp"
        fi
    fi
}

# ==============================================================================
# Decisión de compilación (keyed por app, sin colisiones)
#
# Firma: should_build_app TABLE_NAME PATCH_REPO CHANNEL APK_VERSION BRAND ARCH PKG_NAME NEW_PATCHES_HASH IS_SINGLE_APP NEW_MPP_SIZE NEW_MPP_UPDATED_AT PATCHES_HOST
#
# Retorna 0 → compilar, 1 → omitir
# ==============================================================================
should_build_app() {
    local table_name="$1"
    local repo="$2"
    local channel="${3:-stable}"
    local current_apk_ver="$4"
    local current_brand="${5:-}"
    local current_arch="${6:-}"
    local pkg_name="${7:-}"
    local new_patches_hash="${8:-}"
    local is_single_app="${9:-false}"
    local new_mpp_size="${10:-}"
    local new_mpp_updated_at="${11:-}"
    local patches_host="${12:-github}"   # 🆕 Host del repo (github, gitlab, codeberg)

    if [ ! -f "$VERSIONS_LOG_FILE" ]; then
        echo '{}' > "$VERSIONS_LOG_FILE"
    fi

    # Consultar última versión remota de parches (usando el host correcto)
    local latest_patch_ver
    latest_patch_ver=$(get_latest_remote_tag "$patches_host" "$repo" "$channel")

    if [ -z "$latest_patch_ver" ]; then
        echo -e "\033[0;33m[!] No se pudo consultar la versión remota para $repo. Forzando compilación por seguridad.\033[0m" >&2
        return 0
    fi

    # Leer estado guardado para esta app
    local cached_patch_ver cached_apk_ver cached_brand cached_arch cached_patches_hash
    local cached_mpp_size cached_mpp_updated_at
    cached_patch_ver=$(jq -r --arg app "$table_name" '.[$app].patches_version // ""' "$VERSIONS_LOG_FILE")
    cached_apk_ver=$(jq -r --arg app "$table_name" '.[$app].apk_version // ""' "$VERSIONS_LOG_FILE")
    cached_brand=$(jq -r --arg app "$table_name" '.[$app].brand // ""' "$VERSIONS_LOG_FILE")
    cached_arch=$(jq -r --arg app "$table_name" '.[$app].arch // ""' "$VERSIONS_LOG_FILE")
    cached_patches_hash=$(jq -r --arg app "$table_name" '.[$app].patches_hash // ""' "$VERSIONS_LOG_FILE")
    cached_mpp_size=$(jq -r --arg app "$table_name" '.[$app].mpp_size // ""' "$VERSIONS_LOG_FILE")
    cached_mpp_updated_at=$(jq -r --arg app "$table_name" '.[$app].mpp_updated_at // ""' "$VERSIONS_LOG_FILE")

    # Condición 1: nueva versión de parches
    if [ "$latest_patch_ver" != "$cached_patch_ver" ]; then

        # 🆕 Opción 3 (KISS): Single-app bundle -> cualquier tag nuevo requiere compilar
        if [ "$is_single_app" = "true" ]; then
            echo -e "\033[0;32m[+] Tag nuevo en bundle single-app para $table_name. Compilando.\033[0m" >&2
            return 0
        fi

        # 🆕 Filtro 1: ¿Cambió el hash del JSON filtrado por CLI?
        if [ -n "$cached_patches_hash" ] && [ "$new_patches_hash" != "$cached_patches_hash" ]; then
            echo -e "\033[0;32m[+] Hash de parches cambió para $table_name. Compilando.\033[0m" >&2
            return 0
        fi

        # 🆕 Filtro 2: ¿Cambió el peso o la fecha del .mpp? (Detección de fixes silenciosos)
        local mpp_changed=false
        if [ -n "$new_mpp_size" ] && [ -n "$cached_mpp_size" ] && [ "$new_mpp_size" != "$cached_mpp_size" ]; then
            mpp_changed=true
        fi
        if [ -n "$new_mpp_updated_at" ] && [ -n "$cached_mpp_updated_at" ] && [ "$new_mpp_updated_at" != "$cached_mpp_updated_at" ]; then
            mpp_changed=true
        fi
        # Si no tenemos caché previa del .mpp, lo tratamos como cambio para forzar la siembra
        if [ -z "$cached_mpp_size" ] || [ -z "$cached_mpp_updated_at" ]; then
            mpp_changed=true
        fi

        if [ "$mpp_changed" = "true" ]; then
            echo -e "\033[0;32m[+] Peso/Fecha del .mpp cambió para $table_name. Compilando.\033[0m" >&2
            return 0
        fi

        # Si llegamos aquí, el tag cambió pero ni el JSON ni el .mpp cambiaron
        echo -e "\033[0;33m[!] Tag nuevo ($cached_patch_ver -> $latest_patch_ver) pero sin cambios en JSON ni .mpp para $table_name. Omitiendo.\033[0m" >&2
        return 1
    fi

    # Condición 2: cambió brand
    if [ -n "$cached_brand" ] && [ "$current_brand" != "$cached_brand" ]; then
        echo -e "\033[0;32m[+] Cambio de brand detectado para $table_name [$cached_brand -> $current_brand]\033[0m" >&2
        return 0
    fi

    # Condición 3: cambió arch
    if [ -n "$cached_arch" ] && [ "$current_arch" != "$cached_arch" ]; then
        echo -e "\033[0;32m[+] Cambio de arch detectado para $table_name [$cached_arch -> $current_arch]\033[0m" >&2
        return 0
    fi

    echo -e "\033[0;32m[+] Sin cambios para $table_name (parches: $cached_patch_ver, APK: $cached_apk_ver, brand: $cached_brand, arch: $cached_arch). Omitiendo compilación.\033[0m" >&2
    return 1
}