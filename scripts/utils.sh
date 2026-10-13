#!/usr/bin/env bash
# utils.sh - Núcleo central de utilidades y cargador modular

MODULE_TEMPLATE_DIR="module"
CWD=$(pwd)
TEMP_DIR="temp"
BIN_DIR="bin"
BUILD_DIR="build"
DL_SRCS=("cache_repo" "direct" "github" "archive" "apkmirror")
BUILD_JSON_FILE="build.json"
PATCH_OUTPUT=""

if [ -z "${GITHUB_TOKEN-}" ] && command -v gh >/dev/null 2>&1; then
    GITHUB_TOKEN=$(gh auth token 2>/dev/null || true)
fi
if [ "${GITHUB_TOKEN-}" ]; then GH_HEADER="Authorization: token ${GITHUB_TOKEN}"; else GH_HEADER=; fi
NEXT_VER_CODE=${NEXT_VER_CODE:-$(date +'%Y%m%d')}
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

RVB_INSTAFEL_FALLBACK_COMMIT="${RVB_INSTAFEL_FALLBACK_COMMIT:-8e4756f}"
RVB_INSTAFEL_DEFAULT_PATCHES="${RVB_INSTAFEL_DEFAULT_PATCHES:-unlock_developer_options remove_snooze_warning remove_ads amoled_theme instafel}"
RVB_MORPHE_PASSTHROUGH="${RVB_MORPHE_PASSTHROUGH:-true}"

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

failure_slug() {
    printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-//; s/-$//'
}

write_build_failure_descriptor() {
    [ -n "${TEMP_DIR:-}" ] || return 0
    local dir="$TEMP_DIR/failures"
    mkdir -p "$dir" 2> /dev/null || return 0
    jq -n --arg type "build_failed" --arg app "$2" --arg version "$3" \
        --arg vc "$4" --arg arch "$5" --arg patches_src "$6" \
        '{type:$type, app:$app, version:$version, vc:$vc, arch:$arch, patches_src:$patches_src}' \
        > "$dir/$1.json" 2> /dev/null || true
}

write_dl_failure_descriptor() {
    [ -n "${TEMP_DIR:-}" ] || return 0
    local dir="$TEMP_DIR/failures"
    mkdir -p "$dir" 2> /dev/null || return 0
    jq -n --arg type "dl_exhausted" --arg app "$2" --arg version "$3" \
        --arg vc "$4" --arg arch "$5" --arg pkg "$6" \
        '{type:$type, app:$app, version:$version, vc:$vc, arch:$arch, pkg:$pkg}' \
        > "$dir/$1_dl.json" 2> /dev/null || true
}


# ==============================================================================
# ENTORNO JAVA Y PETICIONES HTTP
# ==============================================================================

java() {
    local -a java_env=(PATH="$PATH" HOME="$HOME" LANG="${LANG:-en_US.UTF-8}")
    [ -n "${XDG_DATA_HOME:-}" ] && java_env+=(XDG_DATA_HOME="$XDG_DATA_HOME")
    env -i "${java_env[@]}" java --enable-native-access=ALL-UNNAMED "$@";
}

source_release_api_base() {
    local host=${1,,} src=$2 encoded
    case "$host" in
        github) echo "https://api.github.com/repos/${src}/releases" ;;
        codeberg) echo "https://codeberg.org/api/v1/repos/${src}/releases" ;;
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
    codeberg) echo "${base}?limit=50" ;;
    *) echo "${base}?per_page=100" ;;
    esac
}

source_release_web_url() {
    local host=${1,,} src=$2 tag=$3
    case "$host" in
        github) echo "https://github.com/${src}/releases/tag/${tag}" ;;
        codeberg) echo "https://codeberg.org/${src}/releases/tag/${tag}" ;;
        gitlab) echo "https://gitlab.com/${src}/-/releases/${tag}" ;;
        *) return 1 ;;
    esac
}

source_release_tag_api() {
    local host=${1,,} src=$2 tag=$3 base
    base=$(source_release_api_base "$host" "$src") || return 1
    case "$host" in
        github | codeberg) echo "${base}/tags/${tag}" ;;
        gitlab) echo "${base}/${tag}" ;;
        *) return 1 ;;
    esac
}

source_release_assets_json() {
    local host=${1,,}
    case "$host" in
        github | codeberg) jq -e '[.assets[]? | select(.name | (endswith("asc") or endswith("json")) | not)]' ;;
        gitlab) jq -e '[.assets.links[]? | select(.name | (endswith("asc") or endswith("json")) | not)]' ;;
        *) return 1 ;;
    esac
}

source_release_asset_url() {
    local host=${1,,}
    case "$host" in
        github) jq -r '.url' ;;
        codeberg) jq -r '.browser_download_url // .url' ;;
        gitlab) jq -r '.direct_asset_url // .url' ;;
        *) return 1 ;;
    esac
}

source_release_pick_from_list() {
    local host=${1,,} mode=$2
    case "$host" in
        github | codeberg)
            if [ "$mode" = beta ]; then
                jq -e -c 'map(select(.prerelease == true and .draft != true and .tag_name != null and .tag_name != "")) | sort_by(.published_at // .created_at // "") | reverse | .[0] // empty'
            else
                jq -e -c 'map(select(.prerelease != true and .draft != true and .tag_name != null and .tag_name != "")) | sort_by(.published_at // .created_at // "") | reverse | .[0] // empty'
            fi
            ;;
        gitlab)
            if [ "$mode" = beta ]; then
                jq -e -c 'map(select(.tag_name != null and .tag_name != "" and (.tag_name | test("(?i)(dev|alpha|beta|rc)")))) | sort_by(.released_at // .created_at // "") | reverse | .[0] // empty'
            else
                jq -e -c 'map(select(.tag_name != null and .tag_name != "" and (.tag_name | test("(?i)(dev|alpha|beta|rc)") | not))) | sort_by(.released_at // .created_at // "") | reverse | .[0] // empty'
            fi
            ;;
        *) return 1 ;;
    esac
}

get_apkeditor() {
    if [ -f "$TEMP_DIR/apkeditor.jar" ]; then return 0; fi
    local api_resp dl_url
    api_resp=$(gh_req "https://api.github.com/repos/REAndroid/APKEditor/releases/latest" -) || true
    dl_url=$(echo "$api_resp" | jq -r '.assets[]? | select(.name | endswith(".jar")) | .browser_download_url' | head -1) || true
    if [ -z "$dl_url" ] || [ "$dl_url" = "null" ]; then
        dl_url="https://github.com/REAndroid/APKEditor/releases/download/V1.4.9/APKEditor-1.4.9.jar"
    fi
    gh_dl "$TEMP_DIR/apkeditor.jar" "$dl_url" >/dev/null || return 1
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

_cf_get() {
    local target_url="$1"
    html=""
    local py_script="${CWD}/scripts/cf_get.py"
    if [ ! -f "$py_script" ] && [ -n "${BASH_SOURCE[0]:-}" ]; then
        py_script="$(dirname "${BASH_SOURCE[0]}")/cf_get.py"
    fi
    if command -v python3 >/dev/null 2>&1 && [ -f "$py_script" ]; then
        html=$(python3 "$py_script" "$target_url" "$TEMP_DIR/cookie.txt" 2>/dev/null) || true
    fi
    if [ -z "$html" ]; then
        html=$(curl -s -L -b "$TEMP_DIR/cookie.txt" -c "$TEMP_DIR/cookie.txt" -H "User-Agent: ${DEFAULT_UA}" "$target_url" 2>/dev/null) || true
    fi
    [ -n "$html" ]
}

get_apkmirror_resp() {
    local url="${1}"
    if [ -n "${__DL_RESP_CACHE__["apkmirror_resp_$url"]:-}" ]; then
        __APKMIRROR_RESP__="${__DL_RESP_CACHE__["apkmirror_resp_$url"]}"
        __APKMIRROR_CAT__="${__DL_RESP_CACHE__["apkmirror_cat_$url"]}"
        return 0
    fi
    local html=""
    _cf_get "${url}" || return 1
    __APKMIRROR_RESP__="$html"
    local clean_url="${url%/}"
    __APKMIRROR_CAT__="${clean_url##*/}"
    __DL_RESP_CACHE__["apkmirror_resp_$url"]="$__APKMIRROR_RESP__"
    __DL_RESP_CACHE__["apkmirror_cat_$url"]="$__APKMIRROR_CAT__"
    set +u
    __APKMIRROR_EXAMPLE_URL__="${args[apkmirror_example_url]:-}" 
    set -u
}

get_apkmirror_vers() {
    local vers apkm_resp html=""
    _cf_get "https://www.apkmirror.com/uploads/?appcategory=${__APKMIRROR_CAT__}" || return 1
    apkm_resp="$html"

    local py_cmd=""
    if command -v python3 >/dev/null 2>&1; then
        py_cmd="python3"
    elif command -v python >/dev/null 2>&1; then
        py_cmd="python"
    fi

    local py_script="${CWD}/scripts/apkmirror_search.py"
    [ ! -f "$py_script" ] && [ -n "${BASH_SOURCE[0]:-}" ] && py_script="$(dirname "${BASH_SOURCE[0]}")/apkmirror_search.py"

    local allow_all="${__AAV__:-false}"
    if [ -n "$py_cmd" ] && [ -f "$py_script" ]; then
        local py_vers
        if py_vers=$("$py_cmd" "$py_script" vers "$allow_all" <<<"$apkm_resp") && [ -n "$py_vers" ]; then
            echo "$py_vers"
            return 0
        fi
    fi
    echo ""
}

_apkmirror_html_pkg_name() {
    local resp="$1"
    local py_cmd=""
    if command -v python3 >/dev/null 2>&1; then
        py_cmd="python3"
    elif command -v python >/dev/null 2>&1; then
        py_cmd="python"
    fi
    local py_script="${CWD}/scripts/apkmirror_search.py"
    [ ! -f "$py_script" ] && [ -n "${BASH_SOURCE[0]:-}" ] && py_script="$(dirname "${BASH_SOURCE[0]}")/apkmirror_search.py"
    if [ -n "$py_cmd" ] && [ -f "$py_script" ]; then
        local py_pkg
        if py_pkg=$("$py_cmd" "$py_script" pkg <<<"$resp") && [ -n "$py_pkg" ]; then
            echo "$py_pkg"
            return 0
        fi
    fi
    echo ""
}

get_apkmirror_pkg_name() {
    _apkmirror_html_pkg_name "$__APKMIRROR_RESP__"
}

dl_apkmirror() {
    local url=$1 version=${2// /-} output=$3 arch=$4 dpi=$5 is_bundle=false get_latest_ver=${6:-false} version_code=${7:-}
    
    if [ -f "${output%.apk}.apkm" ]; then
        _bundle_to_apk "${output%.apk}.apkm" "${output}"
        return 0
    fi

    if [ "$arch" = "arm-v7a" ]; then arch="armeabi-v7a"; fi
    local clean_version="${version//[^0-9.]/}"
    local search_version="${version//./-}"
    local apk_bundle="APK"
    [ "$is_bundle" = true ] && apk_bundle="BUNDLE"

    local apkmname
    apkmname=$($HTMLQ "h1.marginZero" --text <<<"$__APKMIRROR_RESP__" 2>/dev/null || echo "")
    [ -z "$apkmname" ] && apkmname=$(basename "${url%/}")
    apkmname="${apkmname,,}" apkmname="${apkmname// /-}" apkmname="${apkmname//[^a-z0-9-]/}"
    local release_url="${url%/}/${apkmname}-${search_version}-release/"
    
    pr "Obteniendo página de release con cf_get.py: $release_url"
    local release_html
    release_html=$(python3 "${CWD}/scripts/cf_get.py" "$release_url" 2>/dev/null)
    
    if [ -z "$release_html" ]; then
        epr "No se pudo obtener el HTML de la versión $version con cf_get.py"
        return 1
    fi

    local search_py="${CWD}/scripts/apkmirror_search.py"
    local cf_py="${CWD}/scripts/cf_get.py"

    pr "Buscando variante con apkmirror_search.py..."
    local variant_page_url
    variant_page_url=$(echo "$release_html" | python3 "$search_py" "$dpi" "$arch" "$apk_bundle" "$clean_version" "$search_version" "$version_code" 2>/dev/null)

    if [ -z "$variant_page_url" ] || [[ "$variant_page_url" != http* ]]; then
        epr "apkmirror_search.py no retornó un enlace de variante válido"
        return 1
    fi

    pr "Variante encontrada: $variant_page_url"
    pr "Obteniendo página de descarga de la variante..."
    
    local var_html
    var_html=$(python3 "$cf_py" "$variant_page_url" 2>/dev/null)
    
    if [ -z "$var_html" ]; then
        epr "No se pudo obtener el HTML de la variante"
        return 1
    fi

    local final_dl_link
    final_dl_link=$(python3 - "$var_html" << 'PYEOF'
import sys, re, urllib.parse
html = sys.argv[1]
base_site = "https://www.apkmirror.com"
m = re.search(r'href="([^"]+/download/\?id=\d+)"', html)
if m:
print(urllib.parse.urljoin(base_site, m.group(1)))
else:
m2 = re.search(r'href="([^"]+/key/[^"]+)"', html)
if m2:
    print(urllib.parse.urljoin(base_site, m2.group(1)))
PYEOF
    )

    if [ -z "$final_dl_link" ]; then
        epr "No se pudo extraer el enlace directo de descarga"
        return 1
    fi

    pr "Descargando APK final con cf_get.py..."
    mkdir -p "$(dirname "$output")"
    if python3 "$cf_py" download "$final_dl_link" "$output" "$variant_page_url" "$TEMP_DIR/cookie.txt"; then
        if [ -f "$output" ] && [ -s "$output" ]; then
            pr "APK descargada y verificada: $output"
            return 0
        fi
    fi
    
    return 1
}

_bundle_to_apk() {
    local bundle=$1 output=$2
    if [ "${MORPHE_PASSTHROUGH_ACTIVE:-false}" = true ]; then
        if ! _bundle_extract_base "$bundle" "$output"; then
            return 1
        fi
        return 0
    fi
    merge_splits "$bundle" "$output"
}

# ==============================================================================
# RESOLUCIÓN INTELIGENTE DE VERSIONES DESDE EL BUNDLE DE PARCHES
# ==============================================================================

resolve_target_version_from_bundle() {
    local repo="$1"
    local pkg_name="$2"
    local mode="$3" # "auto" o "experimental"
    
    python3 - "$repo" "$pkg_name" "$mode" << 'EOF'
import urllib.request
import json
import sys

repo = sys.argv[1]
target_pkg = sys.argv[2]
mode = sys.argv[3]

urls = [
    f"https://raw.githubusercontent.com/{repo}/main/patches-list.json",
    f"https://raw.githubusercontent.com/{repo}/dev/patches-list.json"
]

data = None
for url in urls:
    try:
        req = urllib.request.urlopen(url)
        data = json.loads(req.read().decode('utf-8'))
        break
    except Exception:
        continue

if not data:
    sys.exit(1)

patches = data.get('patches', [])
stable_versions = []
exp_versions = []

for patch in patches:
    compat_pkgs = patch.get('compatiblePackages', {})
    compatibility = patch.get('compatibility', [])
    
    # 1. Formato diccionario o lista simple de versiones (ej. anddea, hush)
    if isinstance(compat_pkgs, dict):
        for p, v_list in compat_pkgs.items():
            if p == target_pkg and isinstance(v_list, list):
                for v in v_list:
                    if v not in stable_versions:
                        stable_versions.append(v)
                        
    # 2. Formato estructurado con objetos y targets (ej. Morphe)
    targets_pool = []
    for comp in compatibility:
        targets_pool.extend(comp.get('targets', []))
    if isinstance(compat_pkgs, list):
        for pkg in compat_pkgs:
            if pkg.get('packageName') == target_pkg or pkg.get('name') == target_pkg:
                targets_pool.extend(pkg.get('targets', []))
                
    for t in targets_pool:
        ver = t.get('version')
        if ver:
            is_exp = t.get('isExperimental', t.get('experimental', False))
            if is_exp and ver not in exp_versions:
                exp_versions.append(ver)
            elif not is_exp and ver not in stable_versions:
                stable_versions.append(ver)

if mode == 'experimental' and exp_versions:
    print(exp_versions[0])
elif stable_versions:
    print(stable_versions[0])
elif exp_versions:
    print(exp_versions[0])
else:
    sys.exit(1)
EOF
}
