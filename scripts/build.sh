#!/usr/bin/env bash

set -euo pipefail
shopt -s nullglob

RVB_UTILS_SH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/utils.sh"
source "$RVB_UTILS_SH"
echo '{}' > "$BUILD_JSON_FILE"

trap "abort" INT

RUN_START_TS=$(date +%s)

# ==============================================================================
# 🧮 Helper: hash estable de los parches aplicables a un paquete
# ------------------------------------------------------------------------------
# Firma: compute_patches_hash_for_pkg <json_source> <pkg_name>
#   json_source: URL http(s) o ruta local a un patches-list.json
# Devuelve SHA-256 del array ordenado de parches compatibles con el paquete.
# Un array vacío "[]" produce un hash estable y distinguible de un fallo real.
# ==============================================================================
compute_patches_hash_for_pkg() {
	local json_source="$1"
	local pkg="$2"

	local json_content
	if [ -f "$json_source" ]; then
		json_content=$(cat "$json_source" 2>/dev/null) || return 1
	elif [[ "$json_source" == http* ]]; then
		json_content=$(curl -fsSL "$json_source" 2>/dev/null) || return 1
	else
		return 1
	fi

	# Normaliza formato: {"patches":[...]} o [...] top-level
	local normalized
	normalized=$(echo "$json_content" | jq -c '
		if (.patches | type) == "array" then .patches
		elif type == "array" then .
		else error("no patches array") end
	' 2>/dev/null) || return 1

	# Hash sobre el subconjunto compatible, soportando ambos formatos:
	#   - array:  [{ "packageName": "...", "targets": [...] }, ...]  (ReVanced/Morphe)
	#   - object: { "pkg": ["ver", ...], ... }                        (Hush*)
	echo "$normalized" \
		| jq -S --arg pkg "$pkg" '
			[.[] | select(
				(.compatiblePackages // []) as $cp |
				if ($cp | type) == "array" then
					($cp | any((.packageName // "") == $pkg))
				elif ($cp | type) == "object" then
					$cp | has($pkg)
				else
					false
				end
			)]
		' \
		| sha256sum | cut -d' ' -f1
}

# ==============================================================================
# 🎨 Helpers de log con banners visibles (stdout + logfile opcional)
# ==============================================================================
_BANNER_LINE="═══════════════════════════════════════════════════════════════"

_format_duration() {
    local secs="${1:-0}"
    if [ "$secs" -lt 60 ]; then echo "${secs}s"
    elif [ "$secs" -lt 3600 ]; then echo "$((secs / 60))m$((secs % 60))s"
    else echo "$((secs / 3600))h$(( (secs % 3600) / 60 ))m$((secs % 60))s"
    fi
}

# Escribe el mismo bloque a stdout (con color) y al logfile (sin color)
_emit_banner() {
    local color="$1"; shift
    local logfile="$1"; shift
    local plain_block="$1"; shift

    echo ""
    echo -e "\033[${color}m${_BANNER_LINE}\033[0m"
    while IFS= read -r line; do
        echo -e "\033[${color}m${line}\033[0m"
    done <<< "$plain_block"
    echo -e "\033[${color}m${_BANNER_LINE}\033[0m"

    if [ -n "$logfile" ] && [ -d "$(dirname "$logfile")" ]; then
        {
            echo ""
            echo "$_BANNER_LINE"
            echo "$plain_block"
            echo "$_BANNER_LINE"
            echo ""
        } >> "$logfile"
    fi
}

print_run_header() {
    local config="${1:-config.toml}"
    local total failed
    total=$(toml_get_table_names 2>/dev/null | grep -vc '^Morphe-Desktop$' || echo 0)
    failed=$(jq 'length' "$FAILED_APPS_FILE" 2>/dev/null || echo 0)
    _emit_banner "1;34" "" "$(printf '  🏁 RUN DE COMPILACIÓN\n     Inicio:         %s\n     Config:         %s\n     REBUILD_APPS:   %s\n     Release tag:    %s\n     Apps en config: %s\n     Fallos previos: %s' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$config" "${REBUILD_APPS:-<vacío>}" "${RELEASE_TAG:-stable}" "$total" "$failed")"
    echo ""
}

print_run_footer() {
    local duration="$1"
    local total compiled failed
    total=$(toml_get_table_names 2>/dev/null | grep -vc '^Morphe-Desktop$' || echo 0)
    compiled=$(find "$COMPILED_MARKER_DIR" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')
    failed=$(jq 'length' "$FAILED_APPS_FILE" 2>/dev/null || echo 0)
    _emit_banner "1;34" "" "$(printf '  🏁 RUN FINALIZADO\n     Duración:       %s\n     Apps en config: %s\n     Compiladas:     %s\n     Fallidas:       %s' \
        "$(_format_duration "$duration")" "$total" "$compiled" "$failed")"
}

print_app_header() {
    local app="$1" repo="$2" channel="$3" pkg="$4" brand="$5" arch="$6" logfile="${7:-}"
    _emit_banner "1;36" "$logfile" "$(printf '  🚀 PROCESANDO: %s\n     Repo:    %s\n     Pkg:     %s\n     Canal:   %s  |  Brand: %s  |  Arch: %s\n     Inicio:  %s' \
        "$app" "$repo" "$pkg" "$channel" "$brand" "$arch" "$(date -u +%Y-%m-%dT%H:%M:%SZ)")"
}

print_app_success() {
    local app="$1" apk="$2" hash="$3" apk_ver="$4" patch_ver="$5" start_ts="$6" logfile="${7:-}"
    local dur=$(( $(date +%s) - start_ts ))
    _emit_banner "1;32" "$logfile" "$(printf '  ✅ ÉXITO: %s  (%s)\n     APK:      %s\n     APK ver:  %s\n     Parches:  %s\n     Hash:     %s...' \
        "$app" "$(_format_duration "$dur")" "$(basename "$apk")" "$apk_ver" "$patch_ver" "${hash:0:32}")"
}

print_app_skipped() {
    local app="$1" reason="${2:-sin cambios}"
    _emit_banner "1;33" "" "$(printf '  ⏭️  OMITIDA: %s  (%s)' "$app" "$reason")"
}

print_app_failure() {
    local app="$1" start_ts="$2" logfile="${3:-}"
    local dur=$(( $(date +%s) - start_ts ))
    _emit_banner "1;31" "$logfile" "$(printf '  ❌ FALLÓ: %s  (%s)\n     Revisa logs/%s.log para detalles' \
        "$app" "$(_format_duration "$dur")" "$app")"
}

if [ "${1-}" = "clean" ]; then
	rm -r "$TEMP_DIR" "$BUILD_DIR" build.md
	exit 0
fi

jq --version >/dev/null || abort "jq is not installed."
java --version >/dev/null || abort "java is not installed."
zip --version >/dev/null || abort "zip is not installed."

# 1. Materializar la identidad de firma antes de validar
pr "Configurando keystore de firma..."
if [ -f "$(dirname "${BASH_SOURCE[0]}")/install_keystore.sh" ]; then
    source "$(dirname "${BASH_SOURCE[0]}")/install_keystore.sh"
elif [ -f "scripts/install_keystore.sh" ]; then
    source scripts/install_keystore.sh
elif [ -f "install_keystore.sh" ]; then
    source install_keystore.sh
fi

require_signing_identity || abort "cannot build without a signing identity"

set_prebuilts

toml_prep "${1:-config.toml}" || abort "could not find config file"

# ==============================================================================
# 🧹 LIMPIEZA: Eliminar de versions_log.json las apps que ya no están en config.toml
# ==============================================================================
if [ -f "versions_log.json" ]; then
    valid_apps=$(toml_get_table_names | grep -v "^Morphe-Desktop$" || true)

    if [ -n "$valid_apps" ]; then
        valid_apps_json=$(echo "$valid_apps" | jq -R . | jq -s .)
        tmp_vlog=$(mktemp)
        jq --argjson valid "$valid_apps_json" \
           'with_entries(select(.key as $k | $valid | index($k)))' \
           versions_log.json > "$tmp_vlog" && mv "$tmp_vlog" versions_log.json
        pr "  Limpieza de versions_log.json completada (apps huérfanas eliminadas)"
    fi
fi

morphe_channel=$(jq -r '."Morphe-Desktop".morphe_desktop_channel // "stable"' <<<"$__TOML__")
pr "Obteniendo CLI de Morphe Desktop (Canal: $morphe_channel)..."
MORPHE_CLI_JAR=$(get_morphe_desktop_cli "$morphe_channel") || abort "No se pudo obtener la CLI de Morphe Desktop"

pr "Obteniendo APKEditor..."
get_apkeditor || abort "No se pudo obtener APKEditor"
APKEDITOR_JAR="$TEMP_DIR/apkeditor.jar"

pr "Limpiando directorio de build..."
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

SNAPSHOT_TAG="snapshot"
export SNAPSHOT_TAG
pr "Tag de snapshot (fijo): $SNAPSHOT_TAG"

LOGS_DIR="logs"
mkdir -p "$LOGS_DIR"
export LOGS_DIR

if [ ! -f "versions_log.json" ]; then
    echo '{}' > versions_log.json
fi

COMPILED_MARKER_DIR="$TEMP_DIR/compiled_markers"
rm -rf "$COMPILED_MARKER_DIR"
mkdir -p "$COMPILED_MARKER_DIR"
export COMPILED_MARKER_DIR

UPLOADED_FILES_MANIFEST="$TEMP_DIR/uploaded_files.txt"
rm -f "$UPLOADED_FILES_MANIFEST"
touch "$UPLOADED_FILES_MANIFEST"
export UPLOADED_FILES_MANIFEST

FAILED_APPS_FILE="$LOGS_DIR/failed_apps.json"
if [ ! -f "$FAILED_APPS_FILE" ]; then
	echo '{}' > "$FAILED_APPS_FILE"
fi
export FAILED_APPS_FILE

# 🆕 Reporte por-run de apps que no pudieron obtener/generar patches-list.json
JSON_FAILURES_FILE="$LOGS_DIR/json_failures.txt"
rm -f "$JSON_FAILURES_FILE"
touch "$JSON_FAILURES_FILE"
export JSON_FAILURES_FILE

if [ "$(jq 'length' "$FAILED_APPS_FILE" 2>/dev/null || echo 0)" -gt 0 ]; then
	wpr "Apps pendientes de reintento del run anterior:"
	jq -r 'to_entries[] | "  - \(.key) (\(.value.attempts) intento(s))"' "$FAILED_APPS_FILE"
fi

# 🆕 Banner global de inicio
print_run_header "${1:-config.toml}"

# Preservar APKs del release anterior para no perder las apps omitidas
if [ -n "${GITHUB_REPOSITORY:-}" ] && [ -n "${RELEASE_TAG:-stable}" ]; then
    pr "Preservando APKs previos del release '$RELEASE_TAG'..."
    prev_assets=$(gh release view "$RELEASE_TAG" -R "$GITHUB_REPOSITORY" \
        --json assets --jq '.assets[] | select(.name | test("\\.(apk|zip)$")) | .name' \
        2>/dev/null || echo "")

    if [ -n "$prev_assets" ]; then
        prev_count=0
        while IFS= read -r asset; do
            [ -z "$asset" ] && continue
            if gh release download "$RELEASE_TAG" -R "$GITHUB_REPOSITORY" \
                --pattern "$asset" --dir "$BUILD_DIR" --clobber 2>/dev/null; then
                prev_count=$((prev_count + 1))
            fi
        done <<< "$prev_assets"
        pr "  $prev_count archivos previos preservados en $BUILD_DIR"
    else
        pr "  No había APKs/ZIPs previos en el release"
    fi
fi

for table_name in $(toml_get_table_names); do
	if [ "$table_name" = "Morphe-Desktop" ]; then continue; fi
	if [ -z "$table_name" ]; then continue; fi

	app_start_ts=$(date +%s)

	was_failed_before=false
	if jq -e --arg app "$table_name" 'has($app)' "$FAILED_APPS_FILE" >/dev/null 2>&1; then
		was_failed_before=true
		prev_attempts=$(jq -r --arg app "$table_name" '.[$app].attempts // 0' "$FAILED_APPS_FILE")
		pr "App '$table_name' en lista de fallos (intentos previos: $prev_attempts). Reintentando..."
	fi

	if (
		t=$(toml_get_table "$table_name")
		enabled=$(toml_get "$t" enabled) || enabled=true
		if [ "$enabled" = false ]; then exit 0; fi

		declare -A app_args
		app_args[apkmirror_dlurl]=$(toml_get "$t" "apkmirror-dlurl") || app_args[apkmirror_dlurl]=""
		app_args[telegram_download_url]=$(toml_get "$t" "telegram-download-url") || app_args[telegram_download_url]=""
		app_args[pkg_name]=$(toml_get "$t" pkg-name) || app_args[pkg_name]=""
		app_args[app_name]=$(toml_get "$t" app-name) || app_args[app_name]=$table_name
		app_args[arch]=$(toml_get "$t" arch) || app_args[arch]="arm64-v8a"
		app_args[brand]=$(toml_get "$t" brand) || app_args[brand]="Patched"
		app_args[channel]=$(toml_get "$t" channel) || app_args[channel]="stable"
		app_args[inclusive_patches]=$(toml_get "$t" inclusive-patches) || app_args[inclusive_patches]="false"
		app_args[build_mode]=$(toml_get "$t" build-mode) || app_args[build_mode]="apk"
		app_args[force_patch]=$(toml_get "$t" force-patch) || app_args[force_patch]="false"
		app_args[patches_list_in_release]=$(toml_get "$t" "patches-list-in-release") || app_args[patches_list_in_release]="false"

		patch_repo=$(toml_get "$t" "patches-source") || abort "Falta la clave 'patches-source' en la sección '$table_name' del config.toml"
		target_apk_ver=$(toml_get "$t" version) || target_apk_ver="auto"

		mapfile -t exclude_patches < <(
			jq -r --arg t "$table_name" \
				'.[$t]["exclude-patches"] // [] | .[]' <<<"$__TOML__"
		)
		if [ "${#exclude_patches[@]}" -gt 0 ]; then
			pr "Parches a excluir para $table_name: ${exclude_patches[*]}"
		fi

		mapfile -t enable_patches < <(
			jq -r --arg t "$table_name" \
				'.[$t]["enable-patches"] // [] | .[]' <<<"$__TOML__"
		)
		if [ "${#enable_patches[@]}" -gt 0 ]; then
			pr "Parches universales a habilitar para $table_name: ${enable_patches[*]}"
		fi

		mkdir -p "$TEMP_DIR/$table_name"
		raw_apk="$TEMP_DIR/$table_name/raw.apk"

		# 🆕 Definir el log de la app ANTES del header para que el banner lo incluya
		app_log="$LOGS_DIR/${table_name}.log"
		: > "$app_log"

		print_app_header "$table_name" "$patch_repo" "${app_args[channel]}" "${app_args[pkg_name]}" "${app_args[brand]}" "${app_args[arch]}" "$app_log"

		# ==================================================================
		# 2. Obtener tag, construir URL, validar JSON y generar fallback
		# ==================================================================
		latest_applied_tag=$(get_latest_remote_tag "github" "$patch_repo" "${app_args[channel]}")
		if [ -z "$latest_applied_tag" ]; then
			latest_applied_tag="unknown"
		fi
		pr "  Tag de parches remoto: $latest_applied_tag (canal: ${app_args[channel]})"

		if [ "${app_args[patches_list_in_release]}" = "true" ] && [ "$latest_applied_tag" != "unknown" ]; then
			patches_json_url="https://github.com/${patch_repo}/releases/download/${latest_applied_tag}/patches-list.json"
		else
			patches_json_url="https://raw.githubusercontent.com/${patch_repo}/${app_args[channel]}/patches-list.json"
			if [ "${app_args[channel]}" = "stable" ]; then
				patches_json_url="https://raw.githubusercontent.com/${patch_repo}/main/patches-list.json"
			fi
		fi

		json_is_valid=false
		pr "  → Descargando patches-list.json desde: $patches_json_url"          # 🆕 2a
		if curl -fsSL "$patches_json_url" 2>/dev/null | jq -e 'type == "object" and has("patches")' >/dev/null 2>&1; then
			json_is_valid=true
			pr "    ✓ JSON válido desde URL principal"                              # 🆕
		else
			wpr "    ✗ URL principal inválida o inexistente; probando alternativa..."  # 🆕
			if [ "$latest_applied_tag" != "unknown" ]; then
				alt_url=""
				if [ "${app_args[patches_list_in_release]}" = "true" ]; then
					alt_url="https://raw.githubusercontent.com/${patch_repo}/${app_args[channel]}/patches-list.json"
					if [ "${app_args[channel]}" = "stable" ]; then alt_url="https://raw.githubusercontent.com/${patch_repo}/main/patches-list.json"; fi
				else
					alt_url="https://github.com/${patch_repo}/releases/download/${latest_applied_tag}/patches-list.json"
				fi

				pr "  → Reintentando patches-list.json desde: $alt_url"             # 🆕 2b
				if curl -fsSL "$alt_url" 2>/dev/null | jq -e 'type == "object" and has("patches")' >/dev/null 2>&1; then
					patches_json_url="$alt_url"
					json_is_valid=true
					pr "    ✓ JSON válido desde URL alternativa"                     # 🆕
				else
					wpr "    ✗ URL alternativa inválida o inexistente"              # 🆕
				fi
			fi
		fi

		if [ "$json_is_valid" = "false" ]; then
			pr "  → Generando patches-list.json vía Morphe CLI (repo: $patch_repo, pkg: ${app_args[pkg_name]})"  # 🆕 2c
			generated_json="$TEMP_DIR/$table_name/generated_patches.json"

			rel_flag=""
			if [ "${app_args[channel]}" = "dev" ]; then
				rel_flag="--prerelease"
			fi

			if java -jar "$MORPHE_CLI_JAR" list-patches \
				--patches="https://github.com/$patch_repo" \
				$rel_flag \
				-p -v -f "${app_args[pkg_name]}" 2>/dev/null | \
				python3 "$(dirname "${BASH_SOURCE[0]}")/parse_cli_list.py" > "$generated_json" \
				&& jq -e 'type == "object" and has("patches")' "$generated_json" >/dev/null 2>&1; then

				patches_json_url="$generated_json"
				json_is_valid=true
				pr "    ✓ JSON generado exitosamente en: $patches_json_url"         # 🆕
			else
				wpr "    ✗ Falló la generación del JSON desde el CLI"               # 🆕
			fi
		fi

		# 🆕 Sin JSON válido → se detiene la compilación de ESTA app.
		# Se registra en JSON_FAILURES_FILE para que quede visible al final del run.
		# Se usa exit 1 (no 0) para que la app quede en failed_apps y se reintente
		# el próximo run (preserva el estado si ya venía de un fallo previo).
		if [ "$json_is_valid" = "false" ]; then
			wpr "  ❌ No se pudo obtener ni generar patches-list.json para $table_name"
			wpr "     Posible cambio incompatible en el CLI o en el repo de parches ($patch_repo, ${app_args[channel]})."
			wpr "     Revisa scripts/build.sh, el CLI o el formato del repo antes de reintentar."
			echo "${table_name}|${app_args[pkg_name]}|${patch_repo}|${app_args[channel]}|no_json" >> "$JSON_FAILURES_FILE"
			exit 1
		fi

		# 🆕 Calcular hash de los parches aplicables a esta app
		new_patches_hash=$(compute_patches_hash_for_pkg "$patches_json_url" "${app_args[pkg_name]}") || new_patches_hash=""
		if [ -z "$new_patches_hash" ]; then
			wpr "  ❌ No se pudo calcular el hash de parches para $table_name"
			echo "${table_name}|${app_args[pkg_name]}|${patch_repo}|${app_args[channel]}|hash_failed" >> "$JSON_FAILURES_FILE"
			exit 1
		fi
		pr "  Hash de parches para ${app_args[pkg_name]}: $new_patches_hash"

		# ==================================================================
		# 2a. Resolver la versión objetivo
		# ==================================================================
		if [ "$target_apk_ver" = "auto" ] || [ "$target_apk_ver" = "experimental" ]; then
			pr "Analizando parches en $patch_repo para resolver versión en modo [$target_apk_ver]..."
			resolved_ver=$(resolve_target_version_from_bundle "$patches_json_url" "${app_args[pkg_name]}" "$target_apk_ver")
			if [ -n "$resolved_ver" ]; then
				target_apk_ver="$resolved_ver"
				pr "Versión resuelta exitosamente desde patches-list.json: $target_apk_ver"
			else
				abort "No se pudo resolver la versión desde patches-list.json para $table_name (paquete: ${app_args[pkg_name]})."
			fi
		fi

		# ==================================================================
		# 2b. should_build_app
		# ==================================================================
		_force_this=false
		if [ -n "${REBUILD_APPS:-}" ]; then
			_rebuild_lower=$(echo "${REBUILD_APPS}" | tr '[:upper:]' '[:lower:]')
			_table_lower=$(echo "${table_name}" | tr '[:upper:]' '[:lower:]')

			if [ "${_rebuild_lower}" = "*" ]; then
				_force_this=true
			elif echo ",${_rebuild_lower}," | grep -qF ",${_table_lower},"; then
				_force_this=true
			fi
		fi

		if [ "$_force_this" = "true" ]; then
			pr "  REBUILD_APPS activo: forzando recompilación de $table_name"
		elif [ "$was_failed_before" = "true" ]; then
			pr "  Reintentando por fallo previo (ignorando comparación de versiones)"
		elif ! should_build_app "$table_name" "$patch_repo" "${app_args[channel]}" "$target_apk_ver" "${app_args[brand]}" "${app_args[arch]}" "${app_args[pkg_name]}" "$new_patches_hash"; then
			pr "Omitiendo app '$table_name' por falta de cambios."
			print_app_skipped "$table_name" "sin cambios"
			exit 0
		fi

		# 2c. Nombre del APK
		apk_filename=$(python3 "$(dirname "${BASH_SOURCE[0]}")/naming.py" \
			"$table_name" \
			"$target_apk_ver" \
			"${app_args[brand]}" \
			"$latest_applied_tag" \
			"${app_args[arch]}")

		patched_apk="$BUILD_DIR/$apk_filename"
		pr "Nombre del APK: $apk_filename"

		# 2d. Init log (append: el banner del header ya escribió al inicio)
		{
			echo "=== Parcheo: $table_name ==="
			echo "Fecha: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
			echo "APK version: $target_apk_ver"
			echo "Patches version: $latest_applied_tag"
			echo "Patches source: $patch_repo"
			echo "Channel: ${app_args[channel]}"
			echo "Brand: ${app_args[brand]}"
			echo "Arch: ${app_args[arch]}"
			echo "Build mode: ${app_args[build_mode]}"
			echo "Force patch: ${app_args[force_patch]}"
			echo "Inclusive patches: ${app_args[inclusive_patches]}"
			echo "Patches hash: $new_patches_hash"
			echo ""
		} >> "$app_log"

		# 3d. force_flag (no cambia entre reintentos)
		declare -a force_flag=()
		if [ "${app_args[force_patch]}" = "true" ]; then
			force_flag=("--force")
			pr "  force-patch activo: saltando verificación de versión"
		fi

		# 3e. channel_flag (no cambia entre reintentos)
		declare -a channel_flag=()
		if [ "${app_args[channel]}" = "dev" ]; then
			channel_flag=("--prerelease")
			pr "  Canal 'dev': forzando parches pre-release (--prerelease)"
		fi

		# ==================================================================
		# Preflight: conectividad APKMirror (una vez)
		# ==================================================================
		if [ -n "${app_args[apkmirror_dlurl]:-}" ]; then
			get_apkmirror_resp "${app_args[apkmirror_dlurl]}" || {
				wpr "No se pudo conectar a APKMirror para $table_name"
				exit 1
			}
		fi

		# ==================================================================
		# 3-4. Bucle de descarga + merge + morphe + detección de skew
		# ==================================================================
		retry_attempt=0
		max_retries=1
		final_success=false
		json_for_whitelist="$patches_json_url"
		validation_json=""
		TELEGRAM_UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

		while [ "$retry_attempt" -le "$max_retries" ]; do
			# ---- Reset de estado por iteración ----
			rm -f "$raw_apk" "${raw_apk%.apk}.apkm" "$patched_apk"
			downloaded_via_fallback=false
			was_merged=false
			splits_dir=""

			if [ "$retry_attempt" -gt 0 ]; then
				pr ""
				pr "═══════════════════════════════════════════════════════════════"
				pr "  🔄 REINTENTO $retry_attempt/$max_retries con versión $target_apk_ver"
				pr "═══════════════════════════════════════════════════════════════"
				{
					echo ""
					echo "═══════════════════════════════════════════════════════════════"
					echo "  🔄 REINTENTO $retry_attempt/$max_retries con versión $target_apk_ver"
					echo "═══════════════════════════════════════════════════════════════"
					echo ""
				} >> "$app_log"
			fi

			log_size_before=$(wc -c < "$app_log" 2>/dev/null || echo 0)

			# ---- Whitelist de versionCodes (del JSON correspondiente) ----
			version_codes_whitelist=""
			if [ -n "$json_for_whitelist" ]; then
				pl_json=""
				if [ -f "$json_for_whitelist" ]; then
					pl_json=$(cat "$json_for_whitelist")
				else
					pl_json=$(curl -fsSL "$json_for_whitelist" 2>/dev/null || echo "")
				fi

				if [ -n "$pl_json" ]; then
					version_codes_whitelist=$(echo "$pl_json" | \
						python3 "$(dirname "${BASH_SOURCE[0]}")/apkmirror_search.py" versioncodes \
							"${app_args[pkg_name]}" "$target_apk_ver" "${app_args[arch]}" 2>/dev/null || echo "")
				fi
			fi

			if [ -n "$version_codes_whitelist" ]; then
				pr "  versionCodes permitidos: $version_codes_whitelist"
			else
				pr "  (sin whitelist de versionCodes)"
			fi

			# ---- Descarga ----
			if [ -n "${app_args[apkmirror_dlurl]:-}" ]; then
				pr "Descargando versión $target_apk_ver para $table_name desde APKMirror..."

				if ! dl_apkmirror "${app_args[apkmirror_dlurl]}" "$target_apk_ver" "$raw_apk" "${app_args[arch]}" "" false "$version_codes_whitelist"; then
					if [ -n "${app_args[telegram_download_url]:-}" ]; then
						wpr "Fallo en APKMirror. Usando fallback directo desde Telegram..."
						if ! curl -L -f -s -S --retry 3 --retry-delay 5 -A "$TELEGRAM_UA" -o "$raw_apk" "${app_args[telegram_download_url]}"; then
							wpr "Fallo al descargar la APK desde Telegram"
							exit 1
						fi
						pr "APK descargada vía fallback de Telegram: $raw_apk"
						downloaded_via_fallback=true
					else
						wpr "Fallo al descargar la APK para $table_name desde APKMirror (sin fallback)"
						exit 1
					fi
				else
					pr "APK descargada desde APKMirror: $raw_apk"
				fi
			elif [ -n "${app_args[telegram_download_url]:-}" ]; then
				pr "Descargando APK directamente desde Telegram..."
				if ! curl -L -f -s -S --retry 3 --retry-delay 5 -A "$TELEGRAM_UA" -o "$raw_apk" "${app_args[telegram_download_url]}"; then
					wpr "Fallo al descargar la APK desde Telegram"
					exit 1
				fi
				pr "APK descargada: $raw_apk"
				downloaded_via_fallback=true
			else
				wpr "La aplicación $table_name no tiene URL de descarga válida."
				exit 1
			fi

			# ---- Verificación Telegram ----
			if [ "$downloaded_via_fallback" = "true" ]; then
				pr "Verificando metadatos del APK..."
				apk_info=$(java -jar "$APKEDITOR_JAR" info -i "$raw_apk" 2>&1)
				echo "$apk_info" | while read -r line; do pr "  [APKEditor] $line"; done

				real_pkg=$(echo "$apk_info" | grep -iE "package(name)?[:=]" | awk -F'[:=]' '{print $2}' | tr -d " \"'" | head -n1)
				real_ver=$(echo "$apk_info" | grep -iE "versionname[:=]" | awk -F'[:=]' '{print $2}' | tr -d " \"'" | head -n1)

				if [ -z "$real_ver" ]; then
					wpr "No se pudo extraer la versión del APK"
					exit 1
				fi

				pr "  Package detectado: $real_pkg"
				pr "  Versión detectada: $real_ver"

				if [ "$real_pkg" != "${app_args[pkg_name]}" ]; then
					wpr "El APK no corresponde al paquete ${app_args[pkg_name]}"
					exit 1
				fi

				if [ "$real_ver" != "$target_apk_ver" ]; then
					wpr "La versión del APK ($real_ver) no coincide con $target_apk_ver"
					exit 1
				fi
				pr "Verificación exitosa."
			fi

			# ---- Merge bundle si aplica ----
			if [ -f "$raw_apk" ] && ! unzip -l "$raw_apk" 2>/dev/null | grep -qE '[[:space:]]+AndroidManifest\.xml[[:space:]]*$'; then
				was_merged=true

				splits_dir="$TEMP_DIR/$table_name/splits"
				rm -rf "$splits_dir"
				mkdir -p "$splits_dir"
				pr "Detectado bundle, extrayendo splits originales para el módulo..."
				unzip -j -o "$raw_apk" "*.apk" -d "$splits_dir" >/dev/null 2>&1 || true

				pr "Mergeando bundle con APKEditor..."
				apkm_file="${raw_apk%.apk}.apkm"
				mv "$raw_apk" "$apkm_file"
				if ! java -jar "$APKEDITOR_JAR" m -i "$apkm_file" -o "$raw_apk"; then
					wpr "Fallo el merge del bundle para $table_name"
					exit 1
				fi
				pr "Bundle mergeado: $raw_apk"
			else
				pr "APK con firma original (válido como stock para módulo)"
			fi

			# ==================================================================
			# Construir argumentos -d / -e para morphe (RECALCULADO POR ITERACIÓN)
			# ==================================================================
			declare -a morphe_patch_args=()

			for pname in "${exclude_patches[@]}"; do
				[ -z "$pname" ] && continue
				morphe_patch_args+=( "-d=$pname" )
			done

			for pname in "${enable_patches[@]}"; do
				[ -z "$pname" ] && continue
				morphe_patch_args+=( "-e=$pname" )
			done

			if [ "${app_args[inclusive_patches]}" = "true" ]; then
				pr "  Leyendo lista de parches para forzar disabled-by-default..."

				declare -a disabled_patches=()
				mapfile -t disabled_patches < <(
					if [ -f "$json_for_whitelist" ]; then
						cat "$json_for_whitelist"
					else
						curl -fsSL "$json_for_whitelist" 2>/dev/null
					fi | jq -r '
						(.patches // .)[]? |
						select(
							((has("default") and .default == false) or
							 (has("use") and .use == false))
							and
							(.compatiblePackages != null)
						) |
						.name // empty
					' 2>/dev/null
				)

				declare -a disabled_filtered=()
				for dp in "${disabled_patches[@]}"; do
					[ -z "$dp" ] && continue
					_is_excluded=false
					for ep in "${exclude_patches[@]}"; do
						if [ "$dp" = "$ep" ]; then
							_is_excluded=true
							break
						fi
					done
					[ "$_is_excluded" = "false" ] && disabled_filtered+=( "$dp" )
				done
				disabled_patches=( "${disabled_filtered[@]}" )

				if [ "${#disabled_patches[@]}" -gt 0 ]; then
					pr "  Forzando ${#disabled_patches[@]} parches disabled-by-default (excluye universales)"
					for pname in "${disabled_patches[@]}"; do
						[ -z "$pname" ] && continue
						morphe_patch_args+=( "-e=$pname" )
					done
				else
					wpr "  No se encontraron parches disabled-by-default no-universales"
				fi
			fi

			if [ "${#morphe_patch_args[@]}" -gt 0 ]; then
				pr "  Total argumentos de parches: ${#morphe_patch_args[@]}"
			fi

			{
				echo ""
				echo "--- Argumentos de parches (${#morphe_patch_args[@]}) ---"
				for arg in "${morphe_patch_args[@]}"; do
					echo "  $arg"
				done
				echo ""
				echo "--- Salida de Morphe CLI (APK principal) ---"
				echo ""
			} >> "$app_log"

			# ---- Morphe ----
			pr "Aplicando parches con Morphe CLI..."
			java -jar "$MORPHE_CLI_JAR" patch \
				-p="https://github.com/$patch_repo" \
				"${channel_flag[@]}" \
				--continue-on-error \
				-o="$patched_apk" \
				--keystore="$RVB_KEYSTORE" \
				--keystore-password="$RVB_KEYSTORE_PASS" \
				--keystore-entry-alias="$RVB_KEY_ALIAS" \
				--keystore-entry-password="$RVB_KEYSTORE_PASS" \
				--signer="Morphe" \
				--striplibs="${app_args[arch]}" \
				"${force_flag[@]}" \
				"${morphe_patch_args[@]}" \
				"$raw_apk" \
				2>&1 | tee -a "$app_log" \
				|| {
					wpr "Error durante el parcheo de $table_name"
					exit 1
				}

		if [ ! -f "$patched_apk" ]; then
			wpr "Morphe no generó el APK parcheado"
			exit 1
		fi

		# 🆕 EXTRAER EL ID REAL DEL APK COMPILADO
		final_pkg_name=$(java -jar "$APKEDITOR_JAR" info -i "$patched_apk" 2>&1 | grep -iE "package(name)?[:=]" | awk -F'[:=]' '{print $2}' | tr -d " \"'" | head -n1)
		
		if [ -z "$final_pkg_name" ]; then
			final_pkg_name="${app_args[pkg_name]}"
		fi
		
		pr "  ID del paquete final (instalado): $final_pkg_name"

			# ---- Detección de skew ----
			new_log=$(tail -c +$((log_size_before + 1)) "$app_log" 2>/dev/null || echo "")
			applied=$(echo "$new_log" | grep -oP 'INFO: Applying \K\d+(?= patches)' | tail -1)
			applied=${applied:-0}
			skipped=$(echo "$new_log" | grep -c 'WARNING: Skipping "' || true)
			skipped=${skipped:-0}
			failed=$(echo "$new_log" | grep -c 'ERROR: FAILED:' || true)
			failed=${failed:-0}
			total=$((applied + skipped))

			if [ "$failed" -gt 0 ]; then
				wpr "  ⚠️  $failed parche(s) fallaron individualmente (continue-on-error)"
			fi

			bad_patch=false
			if [ "$applied" -eq 0 ] && [ "$skipped" -gt 0 ]; then
				bad_patch=true
				pr "  ⚠️  Morphe aplicó 0 parches ($skipped skipped) → posible skew"
			elif [ "$applied" -eq "$failed" ] && [ "$failed" -gt 0 ]; then
				# Todos los parches intentados fallaron → APK inservible
				bad_patch=true
				pr "  ⚠️  Todos los $failed parches fallaron → APK sin cambios reales"
			elif [ "$total" -ge 5 ]; then
				ratio=$(( skipped * 100 / total ))
				if [ "$ratio" -ge 50 ]; then
					bad_patch=true
					pr "  ⚠️  Morphe saltó $skipped de $total (${ratio}%) → posible skew"
				fi
			fi

			# 🆕 CRÍTICO: si el parcheo fue OK, salir del bucle ANTES de borrar el APK
			if [ "$bad_patch" = "false" ]; then
				final_success=true
				break
			fi

			# ---- APK basura: eliminar antes de decidir retry ----
			rm -f "$patched_apk"

			if [ "$retry_attempt" -ge "$max_retries" ]; then
				wpr "  ❌ Reintentos agotados. Marcando $table_name para siguiente run."
				exit 1
			fi

			# ---- Validación vía CLI ----
			pr "  Consultando CLI para determinar versión real del .mpp..."
			validation_json="$TEMP_DIR/$table_name/cli_validation.json"
			rel_flag=""
			if [ "${app_args[channel]}" = "dev" ]; then rel_flag="--prerelease"; fi

			if ! java -jar "$MORPHE_CLI_JAR" list-patches \
				--patches="https://github.com/$patch_repo" \
				$rel_flag -p -v -f "${app_args[pkg_name]}" 2>/dev/null | \
				python3 "$(dirname "${BASH_SOURCE[0]}")/parse_cli_list.py" > "$validation_json"; then
				wpr "  ❌ Falló la validación vía CLI"
				exit 1
			fi

			cli_ver=$(resolve_target_version_from_bundle "$validation_json" "${app_args[pkg_name]}" "auto")

			if [ -z "$cli_ver" ]; then
				wpr "  ❌ No se pudo resolver versión desde CLI"
				exit 1
			fi

			if [ "$cli_ver" = "$target_apk_ver" ]; then
				wpr "  ❌ CLI confirma $target_apk_ver. El .mpp no tiene parches compatibles."
				exit 1
			fi

			pr "  ✓ Versión correcta según CLI: $cli_ver (era: $target_apk_ver)"

			target_apk_ver="$cli_ver"
			apk_filename=$(python3 "$(dirname "${BASH_SOURCE[0]}")/naming.py" \
				"$table_name" "$target_apk_ver" "${app_args[brand]}" "$latest_applied_tag" "${app_args[arch]}")
			patched_apk="$BUILD_DIR/$apk_filename"
			json_for_whitelist="$validation_json"

			retry_attempt=$((retry_attempt + 1))
		done

		if [ "$final_success" = "false" ]; then
			wpr "  ❌ No se pudo parchear $table_name tras reintentos"
			exit 1
		fi

		# ==================================================================
		# Registrar APK en manifest
		# ==================================================================
		if [ "${app_args[build_mode]}" = "apk" ] || [ "${app_args[build_mode]}" = "both" ]; then
			echo "$apk_filename" >> "$UPLOADED_FILES_MANIFEST"
			pr "  APK registrado en el manifest (modo: ${app_args[build_mode]})"
		else
			pr "  Modo '${app_args[build_mode]}': el APK no se subirá a releases"
		fi

		# ==================================================================
		# 4b. Módulo Magisk/KernelSU
		# ==================================================================
		module_zip_filename=""
		module_ok=true
		if [ "${app_args[build_mode]}" = "both" ] || [ "${app_args[build_mode]}" = "module" ]; then
			module_stock_src="$raw_apk"
			if [ "$was_merged" = true ] && [ -d "$splits_dir" ]; then
				module_stock_src="$splits_dir"
				pr "  Usando splits originales para el módulo"
			fi

			gmscore_present=false
			json_content=""
			if [ -f "$patches_json_url" ]; then
				json_content=$(cat "$patches_json_url")
			else
				json_content=$(curl -fsSL "$patches_json_url" 2>/dev/null || echo "")
			fi

			if echo "$json_content" | jq -e '(.patches // .)[]? | select(.name == "GmsCore support")' >/dev/null 2>&1; then
				gmscore_present=true
				pr "  Parche 'GmsCore support' detectado"
			fi

			module_id=$(echo "$table_name" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '_' | sed 's/_$//')
			module_zip="$BUILD_DIR/${apk_filename%.apk}.zip"
			module_zip_filename=$(basename "$module_zip")
			pkg_version_code="${NEXT_VER_CODE}"
			module_apk_src="$patched_apk"

			if [ "$gmscore_present" = true ]; then
				pr "  Compilando variante para módulo (sin 'GmsCore support')..."
				module_apk_tmp="$TEMP_DIR/$table_name/module.apk"

				module_log_marker=$(wc -c < "$app_log" 2>/dev/null || echo 0)
				{
					echo ""
					echo "--- Salida de Morphe CLI (variante módulo) ---"
					echo ""
				} >> "$app_log"

				if java -jar "$MORPHE_CLI_JAR" patch \
					-p="https://github.com/$patch_repo" \
					"${channel_flag[@]}" \
					--continue-on-error \
					-o="$module_apk_tmp" \
					--keystore="$RVB_KEYSTORE" \
					--keystore-password="$RVB_KEYSTORE_PASS" \
					--keystore-entry-alias="$RVB_KEY_ALIAS" \
					--keystore-entry-password="$RVB_KEYSTORE_PASS" \
					--signer="Morphe" \
					--striplibs="${app_args[arch]}" \
					"${force_flag[@]}" \
					"${morphe_patch_args[@]}" \
					-d="GmsCore support" \
					"$raw_apk" \
					2>&1 | tee -a "$app_log"; then

					if [ -f "$module_apk_tmp" ]; then
						module_log_content=$(tail -c +$((module_log_marker + 1)) "$app_log" 2>/dev/null || echo "")
						module_applied=$(echo "$module_log_content" | grep -oP 'INFO: Applying \K\d+(?= patches)' | tail -1)
						module_applied=${module_applied:-0}

						if [ "$module_applied" -gt 0 ]; then
							module_apk_src="$module_apk_tmp"
							pr "  Variante módulo generada: $module_apk_tmp ($module_applied parches)"
						else
							wpr "  ⚠️  Variante módulo aplicó 0 parches. Usando APK principal para el módulo."
							rm -f "$module_apk_tmp"
						fi
					fi
				else
					wpr "  ⚠️  Error al compilar variante módulo. Usando APK principal para el módulo."
					rm -f "$module_apk_tmp"
				fi
			fi

			if [ "$module_ok" = "true" ]; then
				pr "Generando módulo Magisk/KernelSU para $table_name..."
				if python3 "$(dirname "${BASH_SOURCE[0]}")/module_builder.py" \
					"module" \
					"$module_stock_src" \
					"$module_apk_src" \
					"$module_zip" \
					"$module_id" \
					"$table_name (${app_args[brand]})" \
					"${app_args[pkg_name]}" \
					"$target_apk_ver" \
					"$pkg_version_code" \
					"${app_args[brand]}" \
					"${app_args[arch]}" \
					"$latest_applied_tag" \
					"${RELEASE_TAG:-stable}"; then
					pr "Módulo generado: $module_zip"
					echo "$module_zip_filename" >> "$UPLOADED_FILES_MANIFEST"

					if [ -f "$module_zip" ]; then
						{
							echo ""
							echo "--- Contenido de module.prop ---"
							unzip -p "$module_zip" module.prop 2>/dev/null || echo "Error al leer module.prop"
							echo "--------------------------------"
						} >> "$app_log"
						pr "  module.prop añadido al log"
					fi
				else
					wpr "Fallo al generar el módulo para $table_name"
				fi
			fi
		fi

		# ==================================================================
		# 5. Actualizar versions_log.json
		# ==================================================================
		prev_snapshot_file=""
		prev_snapshot_zip=""
		prev_stable_file=""
		prev_stable_zip=""
		prev_patch_ver=""

		if [ -f "versions_log.json" ]; then
			prev_snapshot_file=$(jq -r --arg app "$table_name" '.[$app].snapshot_file // ""' versions_log.json)
			prev_snapshot_zip=$(jq -r --arg app "$table_name" '.[$app].snapshot_zip // ""' versions_log.json)
			prev_stable_file=$(jq -r --arg app "$table_name" '.[$app].stable_file // .[$app].file // ""' versions_log.json)
			prev_stable_zip=$(jq -r --arg app "$table_name" '.[$app].stable_zip // ""' versions_log.json)
			prev_patch_ver=$(jq -r --arg app "$table_name" '.[$app].patches_version // ""' versions_log.json)
		fi

		if [ "$latest_applied_tag" == "$prev_patch_ver" ]; then
			pr "  La versión de parches no cambió ($latest_applied_tag). No se moverá a snapshot."
			prev_stable_file=""
			prev_stable_zip=""
		fi

		final_stable_file="$apk_filename"
		final_stable_zip="$module_zip_filename"

		if [ "${app_args[build_mode]}" = "module" ]; then
			final_stable_file=""
		fi
		if [ "${app_args[build_mode]}" = "apk" ]; then
			final_stable_zip=""
		fi

		tmp_vlog=$(mktemp)
		jq --arg app "$table_name" \
		   --arg src "$patch_repo" \
		   --arg ch "${app_args[channel]}" \
		   --arg patch_ver "$latest_applied_tag" \
		   --arg patches_hash "$new_patches_hash" \
		   --arg apk_ver "$target_apk_ver" \
		   --arg final_pkg "$final_pkg_name" \
		   --arg brand "${app_args[brand]}" \
		   --arg arch "${app_args[arch]}" \
		   --arg stable_file "$final_stable_file" \
		   --arg stable_zip "$final_stable_zip" \
		   --arg snapshot_file "$prev_snapshot_file" \
		   --arg snapshot_zip "$prev_snapshot_zip" \
		   --arg prev_stable_file "$prev_stable_file" \
		   --arg prev_stable_zip "$prev_stable_zip" \
		   --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
		   '.[$app] = {
				patches_source: $src,
				channel: $ch,
				patches_version: $patch_ver,
				patches_hash: $patches_hash,
				apk_version: $apk_ver,
				final_pkg_name: $final_pkg,
				brand: $brand,
				arch: $arch,
				stable_file: (if $stable_file == "" then null else $stable_file end),
				stable_zip: (if $stable_zip == "" then null else $stable_zip end),
				snapshot_file: (if $snapshot_file == "" then null else $snapshot_file end),
				snapshot_zip: (if $snapshot_zip == "" then null else $snapshot_zip end),
				prev_stable_file: (if $prev_stable_file == "" then null else $prev_stable_file end),
				prev_stable_zip: (if $prev_stable_zip == "" then null else $prev_stable_zip end),
				timestamp: $ts
			}' \
			versions_log.json > "$tmp_vlog" && mv "$tmp_vlog" versions_log.json

		print_app_success "$table_name" "$patched_apk" "$new_patches_hash" "$target_apk_ver" "$latest_applied_tag" "$app_start_ts" "$app_log"

		{
			echo ""
			echo "--- Fin del parcheo ---"
			echo "APK final: $patched_apk"
			if [ -n "$module_zip_filename" ]; then
				echo "Módulo: $module_zip"
			fi
			echo "Fecha de fin: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
		} >> "$app_log"

		pr "versions_log.json actualizado para $table_name"
		pr "¡Aplicación '$table_name' procesada y guardada en $patched_apk!"
		pr "Log de parcheo: $app_log"

		touch "$COMPILED_MARKER_DIR/$table_name"
		exit 0
	); then
		if [ "$was_failed_before" = "true" ]; then
			tmp_failed=$(mktemp)
			jq --arg app "$table_name" 'del(.[$app])' "$FAILED_APPS_FILE" > "$tmp_failed" \
				&& mv "$tmp_failed" "$FAILED_APPS_FILE"
			pr "  ✓ '$table_name' removida de la lista de fallos"
		fi
	else
		wpr "App '$table_name' falló. Continuando con la siguiente."
		print_app_failure "$table_name" "$app_start_ts" "$LOGS_DIR/${table_name}.log"

		tmp_failed=$(mktemp)
		jq --arg app "$table_name" \
		   --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
		   '.[$app] = {
				first_failed_at: (.[$app].first_failed_at // $ts),
				last_attempt_at: $ts,
				attempts: ((.[$app].attempts // 0) + 1)
			}' \
			"$FAILED_APPS_FILE" > "$tmp_failed" && mv "$tmp_failed" "$FAILED_APPS_FILE"
		wpr "  '$table_name' añadida a la lista de fallos (reintentará en el próximo run)"
	fi
done

pr "Compilación finalizada."

apps_compiled=$(find "$COMPILED_MARKER_DIR" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')
export APPS_COMPILED="$apps_compiled"

manifest_count=0
if [ -f "$UPLOADED_FILES_MANIFEST" ]; then
	manifest_count=$(grep -c . "$UPLOADED_FILES_MANIFEST" 2>/dev/null || echo 0)
fi

if [ "$apps_compiled" -gt 0 ]; then
	pr "App(s) recompilada(s) en este run: $apps_compiled"
	pr "Archivo(s) generado(s) en este run: $manifest_count"
else
	pr "Sin apps recompiladas en este run. El release no se tocará."
fi

failed_count=$(jq 'length' "$FAILED_APPS_FILE" 2>/dev/null || echo 0)
if [ "$failed_count" -gt 0 ]; then
	wpr "App(s) pendiente(s) de reintento: $failed_count"
	jq -r 'to_entries[] | "  - \(.key): \(.value.attempts) intento(s)"' "$FAILED_APPS_FILE"
fi

# 🆕 Reporte de apps que no pudieron obtener/generar patches-list.json
if [ -s "$JSON_FAILURES_FILE" ]; then
	wpr "App(s) con fallo al obtener/generar patches-list.json en este run:"
	while IFS='|' read -r app pkg repo chan reason; do
		wpr "  - $app ($pkg) desde $repo [$chan] (${reason:-unknown})"
	done < "$JSON_FAILURES_FILE"
	wpr "  Revisa el CLI de Morphe y el formato del repo de parches antes del próximo run."
fi

# 🆕 Banner global de cierre
print_run_footer "$(( $(date +%s) - RUN_START_TS ))"

pr "Subiendo artefactos al Release de GitHub..."
export RELEASE_TAG="${RELEASE_TAG:-stable}"
export UPLOAD_FILES="./build/*.apk ./build/*.zip"

if [ -f "$(dirname "${BASH_SOURCE[0]}")/build_upload_release.sh" ]; then
    bash "$(dirname "${BASH_SOURCE[0]}")/build_upload_release.sh"
elif [ -f "scripts/build_upload_release.sh" ]; then
    bash scripts/build_upload_release.sh
elif [ -f "build_upload_release.sh" ]; then
    bash build_upload_release.sh
else
    echo "::error:: No se encontró build_upload_release.sh"
    exit 1
fi