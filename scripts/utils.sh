#!/usr/bin/env bash
# utils.sh - Núcleo central de utilidades y cargador modular

MODULE_TEMPLATE_DIR="module"
CWD=$(pwd)
TEMP_DIR="temp"
BIN_DIR="bin"
BUILD_DIR="build"
DL_SRCS=("cache_repo" "direct" "github" "archive" "apkmirror")
BUILD_JSON_FILE="build.json"

if [ -z "${GITHUB_TOKEN-}" ] && command -v gh >/dev/null 2>&1; then
    GITHUB_TOKEN=$(gh auth token 2>/dev/null || true)
fi
if [ "${GITHUB_TOKEN-}" ]; then GH_HEADER="Authorization: token ${GITHUB_TOKEN}"; else GH_HEADER=; fi
NEXT_VER_CODE=${NEXT_VER_CODE:-$(date +'%Y%m%d%H')}
OS=$(uname -o)
DEFAULT_UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/154.0.0.0 Safari/537.36"

RVB_KEYSTORE="${RVB_KEYSTORE-}"
RVB_KEYSTORE_P12="${RVB_KEYSTORE_P12-}"
RVB_KEYSTORE_PASS="${RVB_KEYSTORE_PASS-}"
RVB_KEY_ALIAS="${RVB_KEY_ALIAS-}"

require_signing_identity() {
    local bad=0 v
    for v in RVB_KEYSTORE RVB_KEYSTORE_P12 RVB_KEYSTORE_PASS RVB_KEY_ALIAS; do
        if [ -z "${!v-}" ]; then epr "$v is not set"; bad=1; fi
    done
    if [ -n "${RVB_KEYSTORE-}" ] && [ ! -f "$RVB_KEYSTORE" ]; then epr "keystore not found: $RVB_KEYSTORE"; bad=1; fi
    if [ -n "${RVB_KEYSTORE_P12-}" ] && [ ! -f "$RVB_KEYSTORE_P12" ]; then epr "keystore not found: $RVB_KEYSTORE_P12"; bad=1; fi
    if [ -n "${RVB_KEYSTORE_PASS-}" ] && [[ "$RVB_KEYSTORE_PASS" =~ [^0-9A-Za-z] ]]; then
        epr "RVB_KEYSTORE_PASS must be alphanumeric"
        bad=1
    fi
    if [ -n "${RVB_KEY_ALIAS-}" ] && [[ "$RVB_KEY_ALIAS" =~ [^0-9A-Za-z_.-] ]]; then
        epr "RVB_KEY_ALIAS contains invalid characters"
        bad=1
    fi
    if [ "$bad" -ne 0 ]; then
        epr "no usable signing identity"
        return 1
    fi
    return 0
}

declare -gA __PREBUILTS_CACHE__
declare -g __PREBUILTS_RESULT=""
declare -gA __PATCHES_LIST_CACHE__
declare -gA __PATCH_VER_CACHE__
declare -gA __PKG_VERS_CACHE__
declare -gA __DL_RESP_CACHE__
declare -g __APKMIRROR_RESP__=""
declare -g __APKMIRROR_CAT__=""
declare -g __APKMIRROR_EXAMPLE_URL__=""

# ==============================================================================
# CARGADOR MODULAR DE SUBSCRIPTS
# ==============================================================================

load_module() {
    local module_path="$1"
    if [ -f "$module_path" ]; then
        source "$module_path"
    else
        echo "FATAL: Módulo requerido no encontrado en $module_path" >&2
        exit 1
    fi
}

# 1. Cargar gestor de parches y estado
load_module "${CWD}/scripts/patch_manager.sh"

# 2. Cargar gestor de la CLI de Morphe Desktop (modularizado)
load_module "${CWD}/scripts/morphe_cli.sh"

# 3. Cargar la función _cf_get para resolver Cloudflare en APKMirror
load_module "${CWD}/scripts/cf_get.sh"


# ==============================================================================
# UTILIDADES DE CONFIGURACIÓN TOML
# ==============================================================================

toml_file_to_json() {
    local f="$1"
    if [ ! -f "$f" ]; then return 1; fi
    if [[ "$f" == *.toml ]]; then
        local res=""
        
        if command -v python3 >/dev/null 2>&1 || command -v python >/dev/null 2>&1; then
            local py_bin="python3"
            command -v python3 >/dev/null 2>&1 || py_bin="python"
            
            res=$("$py_bin" - << 'EOF' "$f" 2>&1
import json, sys, traceback
filename = sys.argv[1]
data = None
try:
    import toml
    with open(filename, 'r', encoding='utf-8') as f_in:
        data = toml.load(f_in)
except Exception as e:
    sys.stderr.write(f"PYTHON_TOML_ERROR: {e}\n")
    traceback.print_exc(file=sys.stderr)
    sys.exit(1)

if data is not None:
    print(json.dumps(data))
else:
    sys.exit(1)
EOF
            )
            local py_exit=$?
            
            if [ $py_exit -eq 0 ] && [ -n "$res" ]; then
                echo "$res"
                return 0
            else
                echo "[-] Salida de error de Python:" >&2
                echo "$res" >&2
            fi
        fi
        
        abort "Failed to parse $f using Python"
    elif [[ "$f" == *.json ]]; then
        cat "$f"
    else
        abort "config extension not supported: $f"
    fi
}

toml_prep() {
    if [ ! -f "$1" ]; then return 1; fi
    __TOML__=$(toml_file_to_json "$1") || abort "failed to parse config file: $1"
}
toml_get_table_names() { jq -r -e 'to_entries[] | select(.value | type == "object") | .key' <<<"$__TOML__" | tr -d '\r'; }
toml_get_table_main() { jq -r -e 'to_entries | map(select(.value | type != "object")) | from_entries' <<<"$__TOML__"; }
toml_get_table() { jq -r -e ".\"${1}\"" <<<"$__TOML__"; }
toml_get() {
    local op quote_placeholder=$'\001'
    op=$(jq -r ".\"${2}\" | values" <<<"$1")
    if [ "$op" ]; then
        op="${op#"${op%%[![:space:]]*}"}"
        op="${op%"${op##*[![:space:]]}"}"
        op=${op//\\\'/$quote_placeholder}
        op=${op//"''"/$quote_placeholder}
        op=${op//"'"/'"'}
        op=${op//$quote_placeholder/$'\''}
        echo "$op"
    else return 1; fi
}


# ==============================================================================
# LOGS Y GESTIÓN DE ERRORES
# ==============================================================================

pr() { echo >&2 -e "\033[0;32m[+] ${1}\033[0m"; }
epr() {
    echo >&2 -e "\033[0;31m[-] ${1}\033[0m"
    if [ "${GITHUB_REPOSITORY-}" ]; then echo >&2 -e "::error::utils.sh [-] ${1}\n"; fi
}
wpr() {
    echo >&2 -e "\033[0;33m[!] ${1}\033[0m"
    if [ "${GITHUB_REPOSITORY-}" ]; then echo >&2 -e "::warning::utils.sh [!] ${1}\n"; fi
}
abort() {
    epr "ABORT: ${1-}"
    if [ "${RVB_CHILD-}" = 1 ]; then
        trap - SIGTERM SIGINT EXIT
        exit 1
    fi
    rm -rf ./${TEMP_DIR}/*tmp.* ./${TEMP_DIR}/*/*tmp.* ./${TEMP_DIR}/*-temporary-files ./${TEMP_DIR}/*.apk-temporary-files ./*-temporary-files
    trap - SIGTERM SIGINT EXIT
    exit 1
}


# ==============================================================================
# ENTORNO JAVA Y PETICIONES HTTP
# ==============================================================================

java() {
    local -a java_env=(PATH="$PATH" HOME="$HOME" LANG="${LANG:-en_US.UTF-8}")
    [ -n "${XDG_DATA_HOME:-}" ] && java_env+=(XDG_DATA_HOME="$XDG_DATA_HOME")
    [ -n "${GITHUB_TOKEN:-}" ]  && java_env+=(GITHUB_TOKEN="$GITHUB_TOKEN")
    [ -n "${GH_TOKEN:-}" ]      && java_env+=(GH_TOKEN="$GH_TOKEN")
    [ -n "${JAVA_HOME:-}" ]     && java_env+=(JAVA_HOME="$JAVA_HOME")
    env -i "${java_env[@]}" java --enable-native-access=ALL-UNNAMED "$@";
}

source_release_api_base() {
    local host=${1,,} src=$2 encoded
    case "$host" in
        github) echo "https://api.github.com/repos/${src}/releases" ;;
        gitlab)
            encoded=$(jq -nr --arg v "$src" '$v | @uri')
            echo "https://gitlab.com/api/v4/projects/${encoded}/releases"
            ;;
        *) return 1 ;;
    esac
}

source_release_list_url() {
    local host=${1,,} src=$2 base
    base=$(source_release_api_base "$host" "$src") || return 1
    case "$host" in
    *) echo "${base}?per_page=100" ;;
    esac
}

source_release_pick_from_list() {
    local host=${1,,} mode=$2
    case "$host" in
        github)
            if [ "$mode" = beta ] || [ "$mode" = dev ]; then
                jq -e -c 'map(select(.prerelease == true and .draft != true and .tag_name != null and .tag_name != "")) | sort_by(.published_at // .created_at // "") | reverse | .[0] // empty'
            else
                jq -e -c 'map(select(.prerelease != true and .draft != true and .tag_name != null and .tag_name != "")) | sort_by(.published_at // .created_at // "") | reverse | .[0] // empty'
            fi
            ;;
        gitlab)
            if [ "$mode" = beta ] || [ "$mode" = dev ]; then
                jq -e -c 'map(select(.tag_name != null and .tag_name != "" and (.tag_name | test("(?i)(dev|alpha|beta|rc)")))) | sort_by(.released_at // .created_at // "") | reverse | .[0] // empty'
            else
                jq -e -c 'map(select(.tag_name != null and .tag_name != "" and (.tag_name | test("(?i)(dev|alpha|beta|rc)") | not))) | sort_by(.released_at // .created_at // "") | reverse | .[0] // empty'
            fi
            ;;
        *) return 1 ;;
    esac
}

# ==============================================================================
# DESCARGA DE APKs DESDE RELEASES DE GITHUB / GITLAB
# ------------------------------------------------------------------------------
# Firma: dl_from_release_page URL OUTPUT [ARCH]
#   URL    : "https://github.com/user/repo/releases"
#            "https://gitlab.com/user/repo/-/releases"
#            "https://algo.com/cualquier-cosa.apk" (URL directa)
#   OUTPUT : ruta local del archivo destino (ej. temp/App/raw.apk)
#   ARCH   : arquitectura preferida (default: arm64-v8a)
# ==============================================================================
dl_from_release_page() {
    local url="$1"
    local output="$2"
    local arch="${3:-arm64-v8a}"

    mkdir -p "$(dirname "$output")"

    # Caso 1: URL directa a un .apk → descarga simple
    if [[ "$url" =~ \.apk(\?|$) ]]; then
        pr "  Descarga directa: $url"
        if [[ "$url" == *github.com/* ]]; then
            gh_req "$url" "$output" >/dev/null || return 1
        else
            req "$url" "$output" >/dev/null || return 1
        fi
        [ -s "$output" ]
        return $?
    fi

    # Caso 2: URL de página de releases → parsear host + path
    local host path
    if [[ "$url" =~ ^https://github\.com/([^/]+)/([^/]+)/releases/?$ ]]; then
        host="github"
        path="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
    elif [[ "$url" =~ ^https://gitlab\.com/(.+?)/-/releases/?$ ]]; then
        host="gitlab"
        path="${BASH_REMATCH[1]}"
    else
        epr "URL de releases no reconocida: $url"
        return 1
    fi

    # Obtener último release
    local list_url resp release_json
    list_url=$(source_release_list_url "$host" "$path") || return 1
    resp=$(source_release_req "$host" "$list_url" -) || return 1
    release_json=$(source_release_pick_from_list "$host" stable <<<"$resp")

    if [ -z "$release_json" ] || [ "$release_json" = "null" ]; then
        epr "No hay releases en $host/$path"
        return 1
    fi

    # Mapear arch a regex de tokens habituales (ARMv8, ARM64, aarch64…)
    local arch_regex
    case "${arch,,}" in
        arm64-v8a)   arch_regex="arm64|armv8|aarch64|arm[-_]?v?8" ;;
        armeabi-v7a) arch_regex="armv7|armeabi|arm[-_]?v?7" ;;
        x86_64)      arch_regex="x86_64|x64" ;;
        x86)         arch_regex="x86" ;;
        *)           arch_regex="${arch,,}" ;;
    esac

    # Elegir asset con prioridad: 0=match arch, 1=universal, 2=resto
    local asset_url
    case "$host" in
        github)
            asset_url=$(echo "$release_json" | jq -r --arg re "$arch_regex" '
                [.assets[]? | select(.name | endswith(".apk"))
                 | {url: .browser_download_url, prio: (
                     if (.name | ascii_downcase | test($re)) then 0
                     elif (.name | ascii_downcase | contains("universal")) then 1
                     else 2 end
                 )}]
                | sort_by(.prio)
                | .[0].url // empty
            ')
            ;;
        gitlab)
            asset_url=$(echo "$release_json" | jq -r --arg re "$arch_regex" '
                [.assets.links[]? | select(.name | endswith(".apk"))
                 | {url: .direct_asset_url, prio: (
                     if (.name | ascii_downcase | test($re)) then 0
                     elif (.name | ascii_downcase | contains("universal")) then 1
                     else 2 end
                 )}]
                | sort_by(.prio)
                | .[0].url // empty
            ')
            ;;
    esac

    if [ -z "$asset_url" ] || [ "$asset_url" = "null" ]; then
        epr "No hay assets .apk en el release de $host/$path"
        return 1
    fi

    pr "  Asset elegido: $asset_url"

    if [ "$host" = "github" ]; then
        gh_req "$asset_url" "$output" >/dev/null || return 1
    else
        req "$asset_url" "$output" >/dev/null || return 1
    fi

    [ -s "$output" ]
}

get_apkeditor() {
    if [ -f "$TEMP_DIR/apkeditor.jar" ]; then return 0; fi
    local api_resp dl_url
    api_resp=$(gh_req "https://api.github.com/repos/REAndroid/APKEditor/releases/latest" -) || true
    dl_url=$(echo "$api_resp" | jq -r '.assets[]? | select(.name | endswith(".jar")) | .browser_download_url' | head -1) || true
    if [ -z "$dl_url" ] || [ "$dl_url" = "null" ]; then
        dl_url="https://github.com/REAndroid/APKEditor/releases/download/V1.4.9/APKEditor-1.4.9.jar"
    fi
    gh_req "$dl_url" "$TEMP_DIR/apkeditor.jar" >/dev/null || return 1
}

set_prebuilts() {
    APKSIGNER="${BIN_DIR}/apksigner.jar"
    local arch
    arch=$(uname -m)
    if [ "$arch" = aarch64 ]; then arch=arm64; elif [ "${arch:0:5}" = "armv7" ]; then arch=arm; fi
    HTMLQ="${BIN_DIR}/htmlq/htmlq-${arch}"
    if [ ! -x "$HTMLQ" ] && command -v htmlq >/dev/null 2>&1; then HTMLQ="htmlq"; fi
    AAPT2="${BIN_DIR}/aapt2/aapt2-${arch}"
    if [ ! -x "$AAPT2" ] && command -v aapt2 >/dev/null 2>&1; then AAPT2="aapt2"; fi
    TOML="${BIN_DIR}/toml/tq-${arch}"
    if [ ! -x "$TOML" ] && command -v tq >/dev/null 2>&1; then TOML="tq"; fi

    local sdk_root="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
    if [ -n "$sdk_root" ] && [ -d "$sdk_root/build-tools" ]; then
        local latest_bt
        latest_bt=$(ls -1d "$sdk_root"/build-tools/* 2>/dev/null | sort -V | tail -1)
        if [ -n "$latest_bt" ] && [ -f "$latest_bt/lib/apksigner.jar" ]; then
            APKSIGNER="$latest_bt/lib/apksigner.jar"
        fi
        if [ ! -x "$AAPT2" ] && [ -n "$latest_bt" ] && [ -x "$latest_bt/aapt2" ]; then
            AAPT2="$latest_bt/aapt2"
        fi
    fi
}

_req() {
    local ip="$1" op="$2"
    shift 2
    local dlp="$op"
    local _req_lock=""
    if [ "$op" != - ]; then
        if [ -f "$op" ]; then return; fi
        if command -v flock >/dev/null 2>&1; then
            mkdir -p "${TEMP_DIR}/dllocks"
            exec 204>"${TEMP_DIR}/dllocks/$(tr -cs 'a-zA-Z0-9._-' '_' <<<"$op").lock"
            flock -x 204
            _req_lock=1
            if [ -f "$op" ]; then exec 204>&-; return 0; fi
        fi
        dlp="$(dirname "$op")/tmp.$(basename "$op")"
        if [ -f "$dlp" ]; then
            local wait_c=0
            while [ -f "$dlp" ] && [ $wait_c -lt 300 ]; do 
                sleep 1
                wait_c=$((wait_c+1))
            done
            if [ -f "$op" ]; then return 0; fi
        fi
    fi
    if ! curl -L -c "$TEMP_DIR/cookie.txt" -b "$TEMP_DIR/cookie.txt" \
        --connect-timeout 10 --retry 1 --max-time "${RVB_DL_MAX_TIME:-1800}" \
        --speed-limit 1024 --speed-time 120 \
        --fail -s -S "$@" "$ip" -o "$dlp"; then
        epr "Request failed: $ip"
        if [ "$dlp" != - ]; then rm -f "$dlp"; fi
        if [ -n "$_req_lock" ]; then exec 204>&-; fi
        return 1
    fi
    if [ "$dlp" != - ]; then
        mv -f "$dlp" "$op"
    fi
    if [ -n "$_req_lock" ]; then exec 204>&-; fi
}
req() { _req "$1" "$2" -H "User-Agent: ${DEFAULT_UA}"; }
gh_req() { _req "$1" "$2" -H "$GH_HEADER"; }


# ==============================================================================
# INTEGRACIÓN EXCLUSIVA DE APKMIRROR
# ==============================================================================

get_apkmirror_resp() {
    local url="${1}"
    if [ -n "${__DL_RESP_CACHE__["apkmirror_resp_$url"]:-}" ]; then
        __APKMIRROR_RESP__="${__DL_RESP_CACHE__["apkmirror_resp_$url"]}"
        __APKMIRROR_CAT__="${__DL_RESP_CACHE__["apkmirror_cat_$url"]}"
        return 0
    fi

    local html
    html=$(_cf_get "${url}") || return 1
    if [ -z "$html" ]; then
        epr "Respuesta vacía de APKMirror para: $url"
        return 1
    fi

    __APKMIRROR_RESP__="$html"
    local clean_url="${url%/}"
    __APKMIRROR_CAT__="${clean_url##*/}"
    __DL_RESP_CACHE__["apkmirror_resp_$url"]="$__APKMIRROR_RESP__"
    __DL_RESP_CACHE__["apkmirror_cat_$url"]="$__APKMIRROR_CAT__"
    set +u
    __APKMIRROR_EXAMPLE_URL__="${args[apkmirror_example_url]:-}"
    set -u
}

dl_apkmirror() {
    local url=$1 version=${2// /-} output=$3 arch=$4 dpi=$5 is_bundle=false get_latest_ver=${6:-false} version_code=${7:-}

    if [ "$arch" = "arm-v7a" ]; then arch="armeabi-v7a"; fi
    local clean_version="${version//[^0-9.]/}"
    local search_version="${version//./-}"

    local search_py="${CWD}/scripts/apkmirror_search.py"
    local cf_py="${CWD}/scripts/cf_get.py"
    local log_stderr="${TEMP_DIR}/search_stderr_$(basename "${output%.apk}").log"

    # ------------------------------------------------------------------
    # Detectar si la URL del config apunta directamente a un release
    # (formato: .../app-name-version-release/). Si sí, saltarse el lookup
    # y usar esa URL como release_url directamente.
    # ------------------------------------------------------------------
    local release_url=""
    if [[ "$url" =~ -release/?$ ]]; then
        pr "URL de release directa detectada en config: $url"
        release_url="$url"
    fi

    if [ -z "$release_url" ]; then
        # --------------------------------------------------------------
        # Paso 0a: HTML de la página base de la app (la del config.toml)
        # --------------------------------------------------------------
        pr "Obteniendo página base de la app: $url"
        local base_html
        base_html=$(python3 "$cf_py" "$url" 2>/dev/null) || {
            epr "No se pudo obtener el HTML de la página base"
            return 1
        }
        if [ -z "$base_html" ]; then
            epr "HTML vacío de la página base"
            return 1
        fi

        # --------------------------------------------------------------
        # Paso 0b: extraer la URL real de uploads
        # --------------------------------------------------------------
        local uploads_url
        uploads_url=$(echo "$base_html" | python3 "$search_py" uploads 2>"$log_stderr")
        if [ -s "$log_stderr" ]; then cat "$log_stderr" >&2; fi
        if [ -z "$uploads_url" ] || [[ "$uploads_url" != http* ]]; then
            epr "No se pudo obtener la URL de uploads desde la página base"
            return 1
        fi
        pr "URL de uploads: $uploads_url"

        # --------------------------------------------------------------
        # Paso 0c: iterar páginas siguiendo el enlace real de "next"
        # --------------------------------------------------------------
        local current_url="$uploads_url"
        local page=1
        local max_pages=15
        while [ "$page" -le "$max_pages" ] && [ -n "$current_url" ]; do
            pr "  → Buscando en página $page: $current_url"

            local uploads_html
            uploads_html=$(python3 "$cf_py" "$current_url" 2>/dev/null) || {
                wpr "No se pudo obtener el HTML de uploads (página $page)"
                break
            }

            local vers_output
            vers_output=$(echo "$uploads_html" | python3 "$search_py" list true 2>"$log_stderr")
            if [ -s "$log_stderr" ]; then cat "$log_stderr" >&2; fi

            # 1. Intentar coincidencia exacta (ej. "2.0.3-rc0")
            release_url=$(echo "$vers_output" | awk -v v="$version" -F'\t' '$1 == v { print $2; exit }')
            
            # 2. Si falla, intentar con la versión limpia (ej. "2.0.30")
            if [ -z "$release_url" ]; then
                release_url=$(echo "$vers_output" | awk -v v="$clean_version" -F'\t' '$1 == v { print $2; exit }')
            fi
            
            # 3. Si falla, intentar con la versión con guiones (ej. "2-0-3-rc0")
            if [ -z "$release_url" ]; then
                release_url=$(echo "$vers_output" | awk -v v="$search_version" -F'\t' '$1 == v { print $2; exit }')
            fi

            if [ -n "$release_url" ]; then
                pr "  → Encontrada en página $page"
                break
            fi

            local next_url
            next_url=$(echo "$uploads_html" | python3 "$search_py" next 2>/dev/null)
            if [ -z "$next_url" ] || [[ "$next_url" != http* ]] || [ "$next_url" = "$current_url" ]; then
                pr "  → No hay más páginas disponibles"
                break
            fi
            current_url="$next_url"
            page=$((page + 1))
        done

        # --------------------------------------------------------------
        # Si llegamos aquí, la versión no estaba en las 15 páginas.
        # Fallback eliminado para evitar falsos positivos.
        # --------------------------------------------------------------
        if [ -z "$release_url" ]; then
            epr "No se encontró la versión '$clean_version' en las páginas de APKMirror"
            return 1
        fi
    fi

    pr "URL de release: $release_url"

    # ------------------------------------------------------------------
    # Paso 1: HTML del release + búsqueda de variante
    # ------------------------------------------------------------------
    pr "Obteniendo página de release..."
    local release_html
    release_html=$(python3 "$cf_py" "$release_url" 2>/dev/null) || {
        epr "No se pudo obtener el HTML del release"
        return 1
    }

    pr "Buscando variante (arch='$arch')..."
    local variant_page_url
    if [ -n "$version_code" ]; then
        pr "  Con whitelist de versionCodes: $version_code"
        variant_page_url=$(echo "$release_html" | python3 "$search_py" variant "$arch" "$version_code" 2>"$log_stderr")
    else
        variant_page_url=$(echo "$release_html" | python3 "$search_py" variant "$arch" 2>"$log_stderr")
    fi
    if [ -s "$log_stderr" ]; then
        pr "--- diagnóstico paso 1 ---"; cat "$log_stderr" >&2; pr "--- fin diagnóstico ---"
    fi
    if [ -z "$variant_page_url" ] || [[ "$variant_page_url" != http* ]]; then
        epr "Paso 1 falló: no se encontró variante para arch='$arch'"
        return 1
    fi
    pr "Variante elegida: $variant_page_url"

    # ------------------------------------------------------------------
    # Paso 2: variante HTML → URL del botón de descarga
    # ------------------------------------------------------------------
    pr "Obteniendo HTML de la variante..."
    local variant_html
    variant_html=$(python3 "$cf_py" "$variant_page_url" 2>/dev/null) || {
        epr "No se pudo obtener el HTML de la variante"
        return 1
    }

    local download_url
    download_url=$(echo "$variant_html" | python3 "$search_py" download 2>"$log_stderr")
    if [ -s "$log_stderr" ]; then
        cat "$log_stderr" >&2
    fi

    if [ -z "$download_url" ] || [[ "$download_url" != http* ]]; then
        epr "Paso 2 falló: no se encontró el botón de descarga"
        return 1
    fi
    pr "Botón de descarga: $download_url"

    # ------------------------------------------------------------------
    # Paso 3: página intermedia → URL final del APK
    # ------------------------------------------------------------------
    pr "Obteniendo HTML intermedio..."
    local step2_html
    step2_html=$(python3 "$cf_py" "$download_url" 2>/dev/null) || {
        epr "No se pudo obtener el HTML intermedio"
        return 1
    }

    local final_url
    final_url=$(echo "$step2_html" | python3 "$search_py" final 2>"$log_stderr")
    if [ -s "$log_stderr" ]; then
        cat "$log_stderr" >&2
    fi

    if [ -z "$final_url" ] || [[ "$final_url" != http* ]]; then
        epr "Paso 3 falló: no se encontró el enlace final"
        return 1
    fi
    pr "Enlace final: $final_url"

    # ------------------------------------------------------------------
    # Descarga final del archivo
    # ------------------------------------------------------------------
    pr "Descargando APK final..."
    mkdir -p "$(dirname "$output")"

    local CURL_UA="$DEFAULT_UA"

    _try_download_apkmirror() {
        local target_url="$1"
        local referer_url="$2"

        # Intento 1: curl
        if curl -L -f -s -S --retry 3 --retry-delay 5 \
            --connect-timeout 30 --max-time 1800 \
            -A "$CURL_UA" \
            -e "$referer_url" \
            -H "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8" \
            -H "Accept-Language: en-US,en;q=0.5" \
            -H "Accept-Encoding: gzip, deflate, br" \
            -H "Connection: keep-alive" \
            -H "Upgrade-Insecure-Requests: 1" \
            -H "Sec-Fetch-Dest: document" \
            -H "Sec-Fetch-Mode: navigate" \
            -H "Sec-Fetch-Site: same-origin" \
            -b "$TEMP_DIR/cookie.txt" \
            -c "$TEMP_DIR/cookie.txt" \
            -o "$output" "$target_url"; then
            if [ -f "$output" ] && [ -s "$output" ]; then
                return 0
            fi
        fi

        # Intento 2: cf_get.py (solver CF)
        pr "Curl falló, reintentando con cf_get.py..."
        if python3 "$cf_py" download "$target_url" "$output" "$referer_url" "$TEMP_DIR/cookie.txt"; then
            if [ -f "$output" ] && [ -s "$output" ]; then
                return 0
            fi
        fi
        return 1
    }

    # Intento inicial con la URL que ya tenemos
    if _try_download_apkmirror "$final_url" "$download_url"; then
        pr "APK descargada y verificada: $output"
        return 0
    fi

    # Si falla, refrescar la página intermedia para obtener una key fresca
    pr "Descarga falló. Refrescando key de descarga y reintentando..."
    sleep 3   # margen para que el rate-limit de APKMirror se relaje

    local fresh_step2_html fresh_final
    fresh_step2_html=$(python3 "$cf_py" "$download_url" 2>/dev/null) || true

    if [ -n "$fresh_step2_html" ]; then
        fresh_final=$(echo "$fresh_step2_html" | python3 "$search_py" final 2>/dev/null)
        if [ -n "$fresh_final" ] && [[ "$fresh_final" == http* ]] && [ "$fresh_final" != "$final_url" ]; then
            pr "Nuevo enlace final obtenido: $fresh_final"
            if _try_download_apkmirror "$fresh_final" "$download_url"; then
                pr "APK descargada (retry con key fresca): $output"
                return 0
            fi
        else
            pr "No se pudo obtener una key nueva (mismo enlace o vacío)"
        fi
    fi

    epr "No se pudo descargar la APK tras múltiples intentos (CF/403)"
    return 1
}

# ==============================================================================
# RESOLUCIÓN INTELIGENTE DE VERSIONES DESDE EL BUNDLE DE PARCHES
# ==============================================================================
resolve_target_version_from_bundle() {
    local json_source="$1"
    local pkg_name="$2"
    local mode="$3"                     # "auto" o "experimental"

    python3 - "$json_source" "$pkg_name" "$mode" << 'EOF'
import urllib.request
import json
import sys
import re

source     = sys.argv[1]
target_pkg = sys.argv[2]
mode       = sys.argv[3]

data = None

if source.startswith("http"):
    try:
        req = urllib.request.urlopen(source)
        data = json.loads(req.read().decode('utf-8'))
    except Exception:
        sys.exit(1)
else:
    try:
        with open(source, 'r', encoding='utf-8') as f:
            data = json.load(f)
    except Exception:
        sys.exit(1)

if not data:
    sys.exit(1)

patches = data.get('patches', []) if isinstance(data, dict) else data
stable_versions = []
exp_versions = []

def _add(lst, v):
    if v and v not in lst:
        lst.append(v)

def _iter_targets_from_compatibility(compatibility):
    """Solo targets cuyo packageName == target_pkg."""
    if not isinstance(compatibility, list):
        return
    for comp in compatibility:
        if not isinstance(comp, dict):
            continue
        if comp.get('packageName') != target_pkg:
            continue
        for t in comp.get('targets') or []:
            if isinstance(t, dict):
                yield t

def _iter_targets_from_compatible_packages(compat_pkgs):
    """Soporta array (ReVanced/Morphe) y dict (Hush)."""
    if isinstance(compat_pkgs, dict):
        for v in (compat_pkgs.get(target_pkg) or []):
            if isinstance(v, str):
                yield {"version": v, "experimental": False}
    elif isinstance(compat_pkgs, list):
        for pkg in compat_pkgs:
            if not isinstance(pkg, dict):
                continue
            if pkg.get('packageName') == target_pkg:
                for t in pkg.get('targets') or []:
                    if isinstance(t, dict):
                        yield t

for patch in patches:
    if isinstance(patch, str):
        continue

    compat_pkgs   = patch.get('compatiblePackages') or {}
    compatibility = patch.get('compatibility') or []

    # Prioridad 1: compatibility[] (filtra por packageName dentro del generador)
    targets = list(_iter_targets_from_compatibility(compatibility))
    # Prioridad 2: si compatibility no aportó nada para este paquete, usar compatiblePackages
    if not targets:
        targets = list(_iter_targets_from_compatible_packages(compat_pkgs))

    for t in targets:
        ver = t.get('version')
        if not ver:
            continue
        is_exp = bool(t.get('isExperimental', t.get('experimental', False)))
        if is_exp:
            _add(exp_versions, ver)
        else:
            _add(stable_versions, ver)

def _version_key(v):
    return tuple(int(x) for x in re.findall(r'\d+', v))

if not stable_versions and not exp_versions:
    sys.exit(1)

if mode == 'experimental':
    pool = exp_versions or stable_versions
else:
    # auto / stable / cualquier otro → prefiere estable
    pool = stable_versions or exp_versions

print(max(pool, key=_version_key))
EOF
}