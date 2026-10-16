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
	# SUBSHELL: aísla el procesamiento de esta app. Un fallo aquí no detiene
	# la run completa. Los "continue" del loop original se traducen a
	# "exit 0" (éxito/omitida) o "exit 1" (fallo) dentro de la subshell.
	# ==========================================================================
	(
		t=$(toml_get_table "$table_name")
		enabled=$(toml_get "$t" enabled) || enabled=true
		if [ "$enabled" = false ]; then exit 0; fi

		declare -A app_args
		app_args[apkmirror_dlurl]=$(toml_get "$t" "apkmirror-dlurl") || app_args[apkmirror_dlurl]=""
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

		# 3. Descargar la APK limpia desde APKMirror
		if [ -n "${app_args[apkmirror_dlurl]}" ]; then
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

			pr "Descargando versión $target_apk_ver para $table_name..."
			dl_apkmirror "${app_args[apkmirror_dlurl]}" "$target_apk_ver" "$raw_apk" "${app_args[arch]}" "" false "$version_codes_whitelist" || {
				wpr "Fallo al descargar la APK para $table_name"
				exit 1
			}
		else
			wpr "La aplicación $table_name no tiene definida una URL de APKMirror válida."
			exit 1
		fi

		# 3b. Mergear bundle a APK monolítico si es necesario
		was_merged=false
		if [ -f "$raw_apk" ] && ! unzip -l "$raw_apk" 2>/dev/null | grep -qE '[[:space:]]+AndroidManifest\.xml[[:space:]]*$'; then
			was_merged=true
			pr "Detectado bundle, mergeando con APKEditor..."
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

		# Registrar el APK en el manifest (para upload selectivo)
		echo "$apk_filename" >> "$UPLOADED_FILES_MANIFEST"

		# 4b. Módulo Magisk/KernelSU (si build-mode lo requiere)
		module_zip_filename=""
		if [ "${app_args[build_mode]}" = "both" ] || [ "${app_args[build_mode]}" = "module" ]; then
			if [ "$was_merged" = true ]; then
				wpr "Saltando módulo para $table_name: el stock fue mergeado desde un bundle."
			else
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
					"$raw_apk" \
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
				else
					wpr "Fallo al generar el módulo para $table_name"
				fi
			fi
		fi

		# 5. Actualizar versions_log.json
		# Leer la entrada previa (si existe) para conservar snapshot_file
		# y detectar el stable anterior (que será promovido al snapshot).
		prev_snapshot_file=""
		prev_snapshot_zip=""
		prev_stable_file=""
		prev_stable_zip=""
		if [ -f "versions_log.json" ]; then
			prev_snapshot_file=$(jq -r --arg app "$table_name" '.[$app].snapshot_file // ""' versions_log.json)
			prev_snapshot_zip=$(jq -r --arg app "$table_name" '.[$app].snapshot_zip // ""' versions_log.json)
			prev_stable_file=$(jq -r --arg app "$table_name" '.[$app].stable_file // .[$app].file // ""' versions_log.json)
			prev_stable_zip=$(jq -r --arg app "$table_name" '.[$app].stable_zip // ""' versions_log.json)
		fi

		tmp_vlog=$(mktemp)
		jq --arg app "$table_name" \
		   --arg src "$patch_repo" \
		   --arg ch "${app_args[channel]}" \
		   --arg patch_ver "$latest_applied_tag" \
		   --arg apk_ver "$target_apk_ver" \
		   --arg brand "${app_args[brand]}" \
		   --arg arch "${app_args[arch]}" \
		   --arg stable_file "$apk_filename" \
		   --arg stable_zip "$module_zip_filename" \
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
				stable_file: $stable_file,
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
	)
	rc=$?
	if [ "$rc" -ne 0 ]; then
		wpr "App '$table_name' falló (código $rc). Continuando con la siguiente."
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