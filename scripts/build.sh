#!/usr/bin/env bash

set -euo pipefail
shopt -s nullglob

RVB_UTILS_SH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/utils.sh"
source "$RVB_UTILS_SH"
echo '{}' > "$BUILD_JSON_FILE"

trap "abort" INT

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

morphe_channel=$(jq -r '."Morphe-Desktop".morphe_desktop_channel // "stable"' <<<"$__TOML__")
pr "Obteniendo CLI de Morphe Desktop (Canal: $morphe_channel)..."
MORPHE_CLI_JAR=$(get_morphe_desktop_cli "$morphe_channel") || abort "No se pudo obtener la CLI de Morphe Desktop"

pr "Obteniendo APKEditor..."
get_apkeditor || abort "No se pudo obtener APKEditor"
APKEDITOR_JAR="$TEMP_DIR/apkeditor.jar"

pr "Limpiando directorio de build..."
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# ==============================================================================
# Snapshot: tag FIJO (no incremental). Se crea/puebla en upload_release.
# ==============================================================================
SNAPSHOT_TAG="snapshot"
export SNAPSHOT_TAG
pr "Tag de snapshot (fijo): $SNAPSHOT_TAG"

# ==============================================================================
# Logs por app: un archivo por table_name en logs/ (sobrescrito en cada compilación).
# ==============================================================================
LOGS_DIR="logs"
mkdir -p "$LOGS_DIR"
export LOGS_DIR

# ==============================================================================
# versions_log.json es la única fuente de verdad (keyed por app).
# ==============================================================================
if [ ! -f "versions_log.json" ]; then
    echo '{}' > versions_log.json
fi

# Directorio de marcadores de compilación exitosa (uno por app)
COMPILED_MARKER_DIR="$TEMP_DIR/compiled_markers"
rm -rf "$COMPILED_MARKER_DIR"
mkdir -p "$COMPILED_MARKER_DIR"
export COMPILED_MARKER_DIR

# ==============================================================================
# Manifest: basenames de los archivos generados en este run.
# Lo consume build_upload_release.sh para subir SOLO los archivos nuevos.
# ==============================================================================
UPLOADED_FILES_MANIFEST="$TEMP_DIR/uploaded_files.txt"
rm -f "$UPLOADED_FILES_MANIFEST"
touch "$UPLOADED_FILES_MANIFEST"
export UPLOADED_FILES_MANIFEST

# ==============================================================================
# Lista persistente de apps fallidas. Se reintentan automáticamente en el
# siguiente run (aunque no haya cambios de versión), hasta que compilen bien.
# ==============================================================================
FAILED_APPS_FILE="$LOGS_DIR/failed_apps.json"
if [ ! -f "$FAILED_APPS_FILE" ]; then
	echo '{}' > "$FAILED_APPS_FILE"
fi
export FAILED_APPS_FILE

if [ "$(jq 'length' "$FAILED_APPS_FILE" 2>/dev/null || echo 0)" -gt 0 ]; then
	wpr "Apps pendientes de reintento del run anterior:"
	jq -r 'to_entries[] | "  - \(.key) (\(.value.attempts) intento(s))"' "$FAILED_APPS_FILE"
fi

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
	# Omitir la tabla de configuración global
	if [ "$table_name" = "Morphe-Desktop" ]; then continue; fi
	if [ -z "$table_name" ]; then continue; fi

	# ==========================================================================
	# Detección de reintento EN EL PADRE. La subshell la hereda por ambiente,
	# y así el `); then` puede leerla al evaluar el resultado.
	# ==========================================================================
	was_failed_before=false
	if jq -e --arg app "$table_name" 'has($app)' "$FAILED_APPS_FILE" >/dev/null 2>&1; then
		was_failed_before=true
		prev_attempts=$(jq -r --arg app "$table_name" '.[$app].attempts // 0' "$FAILED_APPS_FILE")
		pr "App '$table_name' en lista de fallos (intentos previos: $prev_attempts). Reintentando..."
	fi

	# ==========================================================================
	# SUBSHELL envuelta en `if` para que set -e no mate al padre cuando la
	# subshell retorna non-zero. El cuerpo se ejecuta en un proceso hijo:
	# un fallo dentro solo mata al hijo, no a la run completa.
	# ==========================================================================
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

		patch_repo=$(toml_get "$t" "patches-source") || abort "Falta la clave 'patches-source' en la sección '$table_name' del config.toml"
		target_apk_ver=$(toml_get "$t" version) || target_apk_ver="auto"

		# Leer array exclude-patches (vacío si no existe)
		mapfile -t exclude_patches < <(
			jq -r --arg t "$table_name" \
				'.[$t]["exclude-patches"] // [] | .[]' <<<"$__TOML__"
		)
		if [ "${#exclude_patches[@]}" -gt 0 ]; then
			pr "Parches a excluir para $table_name: ${exclude_patches[*]}"
		fi

		# Leer array enable-patches (universal patches que el usuario quiere forzar)
		mapfile -t enable_patches < <(
			jq -r --arg t "$table_name" \
				'.[$t]["enable-patches"] // [] | .[]' <<<"$__TOML__"
		)
		if [ "${#enable_patches[@]}" -gt 0 ]; then
			pr "Parches universales a habilitar para $table_name: ${enable_patches[*]}"
		fi

		pr "Procesando aplicación: $table_name (Fuente: $patch_repo)"

		# 1. Preparar directorios temporales para la app
		mkdir -p "$TEMP_DIR/$table_name"
		raw_apk="$TEMP_DIR/$table_name/raw.apk"

		# 2. Resolver la versión objetivo según el parámetro del TOML
		if [ "$target_apk_ver" = "auto" ] || [ "$target_apk_ver" = "experimental" ]; then
			pr "Analizando parches en $patch_repo para resolver versión en modo [$target_apk_ver]..."
			resolved_ver=$(resolve_target_version_from_bundle "$patch_repo" "${app_args[pkg_name]}" "$target_apk_ver" "${app_args[channel]}")
			if [ -n "$resolved_ver" ]; then
				target_apk_ver="$resolved_ver"
				pr "Versión resuelta exitosamente desde patches-list.json: $target_apk_ver"
			else
				abort "No se pudo resolver la versión desde patches-list.json para $table_name (paquete: ${app_args[pkg_name]})."
			fi
		fi

		# ==================================================================
		# Validación inteligente de cambios (REBUILD_APPS + should_build_app)
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
		elif ! should_build_app "$table_name" "$patch_repo" "${app_args[channel]}" "$target_apk_ver" "${app_args[brand]}" "${app_args[arch]}"; then
			pr "Omitiendo app '$table_name' por falta de cambios."
			exit 0
		fi

		# 2b. Obtener el tag actual de parches (para el nombre del APK)
		latest_applied_tag=$(get_latest_remote_tag "github" "$patch_repo" "${app_args[channel]}")
		if [ -z "$latest_applied_tag" ]; then
			latest_applied_tag="unknown"
		fi

		# 2c. Generar el nombre del APK final usando naming.py
		apk_filename=$(python3 "$(dirname "${BASH_SOURCE[0]}")/naming.py" \
			"$table_name" \
			"$target_apk_ver" \
			"${app_args[brand]}" \
			"$latest_applied_tag" \
			"${app_args[arch]}")

		patched_apk="$BUILD_DIR/$apk_filename"
		pr "Nombre del APK: $apk_filename"

		# ==================================================================
		# 2d. Inicializar log de parcheo para esta app
		# ==================================================================
		app_log="$LOGS_DIR/${table_name}.log"
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
			echo ""
		} > "$app_log"

		# ==================================================================
		# 3. Descargar la APK limpia (APKMirror principal, Telegram como fallback)
		# ==================================================================
		downloaded_via_fallback=false
		
		# User-Agent de navegador real para evitar que Telegram bloquee la petición (Error 500)
		TELEGRAM_UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

		if [ -n "${app_args[apkmirror_dlurl]:-}" ]; then
			# --- INICIO DEL FLUJO NORMAL DE APKMIRROR ---
			get_apkmirror_resp "${app_args[apkmirror_dlurl]}" || {
				wpr "No se pudo conectar a APKMirror para $table_name"
				exit 1
			}

			version_codes_whitelist=""
			patches_list_url_vc="https://raw.githubusercontent.com/${patch_repo}/${app_args[channel]}/patches-list.json"
			if [ "${app_args[channel]}" = "stable" ]; then
				patches_list_url_vc="https://raw.githubusercontent.com/${patch_repo}/main/patches-list.json"
			fi

			pl_json=$(curl -fsSL "$patches_list_url_vc" 2>/dev/null || echo "")
			if [ -n "$pl_json" ]; then
				version_codes_whitelist=$(echo "$pl_json" | \
					python3 "$(dirname "${BASH_SOURCE[0]}")/apkmirror_search.py" versioncodes \
						"${app_args[pkg_name]}" "$target_apk_ver" "${app_args[arch]}" 2>/dev/null || echo "")
			fi

			if [ -n "$version_codes_whitelist" ]; then
				pr "  versionCodes permitidos: $version_codes_whitelist"
			fi

			pr "Descargando versión $target_apk_ver para $table_name desde APKMirror..."
			
			# Intentar descargar desde APKMirror
			if ! dl_apkmirror "${app_args[apkmirror_dlurl]}" "$target_apk_ver" "$raw_apk" "${app_args[arch]}" "" false "$version_codes_whitelist"; then
				# Si APKMirror falla, revisar si tenemos el fallback de Telegram
				if [ -n "${app_args[telegram_download_url]:-}" ]; then
					wpr "Fallo en APKMirror. Usando fallback directo desde Telegram..."
					if ! curl -L -f -s -S --retry 3 --retry-delay 5 -A "$TELEGRAM_UA" -o "$raw_apk" "${app_args[telegram_download_url]}"; then
						wpr "Fallo al descargar la APK desde la web oficial de Telegram (incluso con User-Agent)"
						exit 1
					fi
					pr "APK descargada vía fallback de Telegram: $raw_apk"
					downloaded_via_fallback=true
				else
					wpr "Fallo al descargar la APK para $table_name desde APKMirror (y no tiene fallback directo)"
					exit 1
				fi
			else
				pr "APK descargada desde APKMirror: $raw_apk"
			fi
			# --- FIN DEL FLUJO NORMAL DE APKMIRROR ---
		elif [ -n "${app_args[telegram_download_url]:-}" ]; then
			# Por si alguna app solo tiene Telegram configurado (sin APKMirror)
			pr "Descargando APK directamente desde Telegram: ${app_args[telegram_download_url]}"
			if ! curl -L -f -s -S --retry 3 --retry-delay 5 -A "$TELEGRAM_UA" -o "$raw_apk" "${app_args[telegram_download_url]}"; then
				wpr "Fallo al descargar la APK desde la web oficial de Telegram (incluso con User-Agent)"
				exit 1
			fi
			pr "APK descargada: $raw_apk"
			downloaded_via_fallback=true
		else
			wpr "La aplicación $table_name no tiene definida una URL de descarga válida."
			exit 1
		fi

		# ==================================================================
		# Verificación EXCLUSIVA: Solo si se descargó usando el link de Telegram
		# ==================================================================
		if [ "$downloaded_via_fallback" = "true" ]; then
			pr "Verificando metadatos del APK (descarga directa)..."
			
			# Capturamos stdout Y stderr
			apk_info=$(java -jar "$APKEDITOR_JAR" info -i "$raw_apk" 2>&1)
			
			# Mostramos la salida cruda en el log para debug futuro
			echo "$apk_info" | while read -r line; do pr "  [APKEditor] $line"; done

			# Extracción robusta (soporta "Package:", "Package Name:", "VersionName:", "Version Name:")
			real_pkg=$(echo "$apk_info" | grep -iE "package(name)?[:=]" | awk -F'[:=]' '{print $2}' | tr -d " \"'" | head -n1)
			real_ver=$(echo "$apk_info" | grep -iE "versionname[:=]" | awk -F'[:=]' '{print $2}' | tr -d " \"'" | head -n1)

			if [ -z "$real_ver" ]; then
				wpr "No se pudo extraer la versión del APK usando APKEditor."
				exit 1
			fi

			pr "  Package detectado: $real_pkg"
			pr "  Versión detectada: $real_ver"

			if [ "$real_pkg" != "${app_args[pkg_name]}" ]; then
				wpr "El APK no corresponde al paquete ${app_args[pkg_name]} (detectado: $real_pkg)"
				exit 1
			fi

			if [ "$real_ver" != "$target_apk_ver" ]; then
				wpr "La versión del APK ($real_ver) no coincide con la requerida por los parches ($target_apk_ver)"
				exit 1
			fi
			pr "Verificación exitosa: el APK es el correcto."
		fi

		# ==================================================================
		# 3b. Mergear bundle a APK monolítico si es necesario
		# ==================================================================
		was_merged=false
		splits_dir=""
		if [ -f "$raw_apk" ] && ! unzip -l "$raw_apk" 2>/dev/null | grep -qE '[[:space:]]+AndroidManifest\.xml[[:space:]]*$'; then
			was_merged=true
			
			# 🆕 Extraer los splits originales ANTES del merge para el módulo
			splits_dir="$TEMP_DIR/$table_name/splits"
			mkdir -p "$splits_dir"
			pr "Detectado bundle, extrayendo splits originales para el módulo..."
			unzip -j -o "$raw_apk" "*.apk" -d "$splits_dir" >/dev/null 2>&1 || true
			
			pr "Mergeando bundle con APKEditor para parchear el APK..."
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

		# 3c. Construir argumentos -d / -e para morphe
		declare -a morphe_patch_args=()

		# (a) exclude-patches → -d=
		for pname in "${exclude_patches[@]}"; do
			[ -z "$pname" ] && continue
			morphe_patch_args+=( "-d=$pname" )
		done

		# (b) enable-patches → -e= (universales forzados explícitamente)
		for pname in "${enable_patches[@]}"; do
			[ -z "$pname" ] && continue
			morphe_patch_args+=( "-e=$pname" )
		done

		# (c) inclusive-patches=true → -e= para disabled-by-default (sin universales, sin excluidos)
		if [ "${app_args[inclusive_patches]}" = "true" ]; then
			patches_list_url="https://raw.githubusercontent.com/${patch_repo}/${app_args[channel]}/patches-list.json"
			if [ "${app_args[channel]}" = "stable" ]; then
				patches_list_url="https://raw.githubusercontent.com/${patch_repo}/main/patches-list.json"
			fi
			pr "  Leyendo lista de parches desde: $patches_list_url"

			declare -a disabled_patches=()
			mapfile -t disabled_patches < <(
				curl -fsSL "$patches_list_url" 2>/dev/null | \
				jq -r '
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

		# 3d. force_flag
		declare -a force_flag=()
		if [ "${app_args[force_patch]}" = "true" ]; then
			force_flag=("--force")
			pr "  force-patch activo: saltando verificación de versión"
		fi

		# 3e. channel_flag: --prerelease si el canal es "dev"
		declare -a channel_flag=()
		if [ "${app_args[channel]}" = "dev" ]; then
			channel_flag=("--prerelease")
			pr "  Canal 'dev': forzando parches pre-release (--prerelease)"
		fi

		# Escribir los args al log antes de invocar a morphe
		{
			echo "--- Argumentos de parches (${#morphe_patch_args[@]}) ---"
			for arg in "${morphe_patch_args[@]}"; do
				echo "  $arg"
			done
			if [ "${#force_flag[@]}" -gt 0 ]; then
				echo ""
				echo "--- Force flag ---"
				echo "  ${force_flag[*]}"
			fi
			echo ""
			echo "--- Salida de Morphe CLI (APK principal) ---"
			echo ""
		} >> "$app_log"

		# 4. Ejecutar el parcheo con la CLI de Morphe Desktop
		pr "Aplicando parches con Morphe CLI..."
		java -jar "$MORPHE_CLI_JAR" patch \
			-p="https://github.com/$patch_repo" \
			"${channel_flag[@]}" \
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
				wpr "Error durante el proceso de parcheo de $table_name"
				exit 1
			}

		if [ ! -f "$patched_apk" ]; then
			wpr "Morphe no generó el APK parcheado para $table_name"
			exit 1
		fi

		# 🆕 BUG-04: Registrar el APK en el manifest SOLO si el modo es apk o both
		if [ "${app_args[build_mode]}" = "apk" ] || [ "${app_args[build_mode]}" = "both" ]; then
			echo "$apk_filename" >> "$UPLOADED_FILES_MANIFEST"
			pr "  APK registrado en el manifest (modo: ${app_args[build_mode]})"
		else
			pr "  Modo '${app_args[build_mode]}': el APK no se subirá a releases"
		fi

		# ==================================================================
		# 4b. Módulo Magisk/KernelSU (si build-mode lo requiere)
		# ==================================================================
		module_zip_filename=""
		if [ "${app_args[build_mode]}" = "both" ] || [ "${app_args[build_mode]}" = "module" ]; then
			# 🆕 Determinar qué usar como "stock" para el módulo
			module_stock_src="$raw_apk"
			if [ "$was_merged" = true ] && [ -d "$splits_dir" ]; then
				module_stock_src="$splits_dir"
				pr "  Usando splits originales para el módulo (preservando firma de Google)"
			fi
			
			gmscore_present=false
			patches_list_url_4b="https://raw.githubusercontent.com/${patch_repo}/${app_args[channel]}/patches-list.json"
			if [ "${app_args[channel]}" = "stable" ]; then
				patches_list_url_4b="https://raw.githubusercontent.com/${patch_repo}/main/patches-list.json"
			fi
			if curl -fsSL "$patches_list_url_4b" 2>/dev/null | \
			   jq -e '(.patches // .)[]? | select(.name == "GmsCore support")' >/dev/null 2>&1; then
				gmscore_present=true
				pr "  Parche 'GmsCore support' detectado en el bundle"
			fi

			module_id=$(echo "$table_name" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '_' | sed 's/_$//')
			module_zip="$BUILD_DIR/${apk_filename%.apk}.zip"
			module_zip_filename=$(basename "$module_zip")
			pkg_version_code="${NEXT_VER_CODE}"
			module_apk_src="$patched_apk"

			if [ "$gmscore_present" = true ]; then
				pr "  Compilando variante para módulo (sin 'GmsCore support')..."
				module_apk_tmp="$TEMP_DIR/$table_name/module.apk"

				{
					echo ""
					echo "--- Salida de Morphe CLI (variante módulo, sin 'GmsCore support') ---"
					echo ""
				} >> "$app_log"

				java -jar "$MORPHE_CLI_JAR" patch \
					-p="https://github.com/$patch_repo" \
					"${channel_flag[@]}" \
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
					2>&1 | tee -a "$app_log" \
					|| {
						wpr "Error al compilar la variante para módulo de $table_name"
						exit 1
					}
				if [ -f "$module_apk_tmp" ]; then
					module_apk_src="$module_apk_tmp"
					pr "  Variante para módulo generada: $module_apk_tmp"
				fi
			fi

			pr "Generando módulo Magisk/KernelSU para $table_name..."
			if python3 "$(dirname "${BASH_SOURCE[0]}")/module_builder.py" \
				"module" \
				"$module_stock_src" \  # 🆕 Usamos la carpeta de splits o el APK monolítico
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

				# ==================================================================
				# NUEVO: Volcar module.prop al log para debug
				# ==================================================================
				if [ -f "$module_zip" ]; then
					{
						echo ""
						echo "--- Contenido de module.prop ---"
						unzip -p "$module_zip" module.prop 2>/dev/null || echo "Error al leer module.prop del ZIP"
						echo "--------------------------------"
					} >> "$app_log"
					pr "  Contenido de module.prop añadido al log"
				fi
			else
				wpr "Fallo al generar el módulo para $table_name"
			fi
		fi

		# 5. Actualizar versions_log.json
		# Leer la entrada previa (si existe) para conservar snapshot_file
		# y detectar el stable anterior (que será promovido al snapshot).
		prev_snapshot_file=""
		prev_snapshot_zip=""
		prev_stable_file=""
		prev_stable_zip=""
		prev_patch_ver="" # 🆕 BUG-06
		
		if [ -f "versions_log.json" ]; then
			prev_snapshot_file=$(jq -r --arg app "$table_name" '.[$app].snapshot_file // ""' versions_log.json)
			prev_snapshot_zip=$(jq -r --arg app "$table_name" '.[$app].snapshot_zip // ""' versions_log.json)
			prev_stable_file=$(jq -r --arg app "$table_name" '.[$app].stable_file // .[$app].file // ""' versions_log.json)
			prev_stable_zip=$(jq -r --arg app "$table_name" '.[$app].stable_zip // ""' versions_log.json)
			prev_patch_ver=$(jq -r --arg app "$table_name" '.[$app].patches_version // ""' versions_log.json) # 🆕 BUG-06
		fi

		# 🆕 BUG-06: Si la versión de parches es la misma, no mover a snapshot
		if [ "$latest_applied_tag" == "$prev_patch_ver" ]; then
			pr "  La versión de parches no cambió ($latest_applied_tag). No se moverá a snapshot."
			prev_stable_file=""
			prev_stable_zip=""
		fi

		# 🆕 BUG-05: Ajustar qué formato va a stable según el modo
		final_stable_file="$apk_filename"
		final_stable_zip="$module_zip_filename"
		
		if [ "${app_args[build_mode]}" = "module" ]; then
			final_stable_file=""  # Sin APK en stable
		fi
		if [ "${app_args[build_mode]}" = "apk" ]; then
			final_stable_zip=""   # Sin ZIP en stable
		fi

		tmp_vlog=$(mktemp)
		jq --arg app "$table_name" \
		   --arg src "$patch_repo" \
		   --arg ch "${app_args[channel]}" \
		   --arg patch_ver "$latest_applied_tag" \
		   --arg apk_ver "$target_apk_ver" \
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
				apk_version: $apk_ver,
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

		# Cerrar el log con resumen
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

		# Marcar como compilada exitosamente
		touch "$COMPILED_MARKER_DIR/$table_name"
		exit 0
	); then
		# Éxito: si estaba en la lista de fallos, removerla
		if [ "$was_failed_before" = "true" ]; then
			tmp_failed=$(mktemp)
			jq --arg app "$table_name" 'del(.[$app])' "$FAILED_APPS_FILE" > "$tmp_failed" \
				&& mv "$tmp_failed" "$FAILED_APPS_FILE"
			pr "  ✓ '$table_name' removida de la lista de fallos"
		fi
	else
		wpr "App '$table_name' falló. Continuando con la siguiente."

		# Añadir/actualizar en la lista de fallos
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

# ==============================================================================
# Contar apps recompiladas y exportar para el script de upload
# ==============================================================================
apps_compiled=$(find "$COMPILED_MARKER_DIR" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')
export APPS_COMPILED="$apps_compiled"

# Archivos generados en este run (uno por línea)
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

# Apps que quedan pendientes de reintento (fallaron en este run)
failed_count=$(jq 'length' "$FAILED_APPS_FILE" 2>/dev/null || echo 0)
if [ "$failed_count" -gt 0 ]; then
	wpr "App(s) pendiente(s) de reintento: $failed_count"
	jq -r 'to_entries[] | "  - \(.key): \(.value.attempts) intento(s)"' "$FAILED_APPS_FILE"
fi

# Subir artefactos 
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