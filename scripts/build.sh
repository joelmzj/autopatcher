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

# Leer el canal global de Morphe Desktop configurado en el TOML
morphe_channel=$(jq -r '."Morphe-Desktop".morphe_desktop_channel // "stable"' <<<"$__TOML__")
pr "Obteniendo CLI de Morphe Desktop (Canal: $morphe_channel)..."
MORPHE_CLI_JAR=$(get_morphe_desktop_cli "$morphe_channel") || abort "No se pudo obtener la CLI de Morphe Desktop"

# Obtener APKEditor (usa el helper de utils.sh)
pr "Obteniendo APKEditor..."
get_apkeditor || abort "No se pudo obtener APKEditor"
APKEDITOR_JAR="$TEMP_DIR/apkeditor.jar"

# ==============================================================================
# FIX C3: Limpiar el directorio de build al inicio para evitar artefactos viejos
# ==============================================================================
pr "Limpiando directorio de build..."
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# ==============================================================================
# FIX C5: Generar tag de snapshot único para este run
# ==============================================================================
export SNAPSHOT_TAG="snapshot-$(date -u +%Y%m%d-%H%M%S)-${GITHUB_SHA:0:7}"
pr "Tag de snapshot para este run: $SNAPSHOT_TAG"

# ==============================================================================
# FIX C4: Inicializar versions_log.json si no existe
# ==============================================================================
if [ ! -f "versions_log.json" ]; then
    echo '{}' > versions_log.json
fi

# ==============================================================================
# FIX D1: Preservar APKs del release actual en build/ para no perder las apps
#         que se omitirán por "sin cambios" durante este run.
# ==============================================================================
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

	# Inicializar variables del bucle (evita 'unbound variable' con set -u)
	latest_applied_tag="unknown"

	t=$(toml_get_table "$table_name")
	enabled=$(toml_get "$t" enabled) || enabled=true
	if [ "$enabled" = false ]; then continue; fi

	declare -A app_args
	app_args[apkmirror_dlurl]=$(toml_get "$t" "apkmirror-dlurl") || app_args[apkmirror_dlurl]=""
	app_args[pkg_name]=$(toml_get "$t" pkg-name) || app_args[pkg_name]=""
	app_args[app_name]=$(toml_get "$t" app-name) || app_args[app_name]=$table_name
	app_args[arch]=$(toml_get "$t" arch) || app_args[arch]="arm64-v8a"
	app_args[brand]=$(toml_get "$t" brand) || app_args[brand]="Patched"
	app_args[channel]=$(toml_get "$t" channel) || app_args[channel]="stable"
	app_args[inclusive_patches]=$(toml_get "$t" inclusive-patches) || app_args[inclusive_patches]="false"
	app_args[build_mode]=$(toml_get "$t" build-mode) || app_args[build_mode]="apk"

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

	pr "Procesando aplicación: $table_name (Fuente: $patch_repo)"

	# 1. Preparar directorios temporales para la app
	mkdir -p "$TEMP_DIR/$table_name"
	raw_apk="$TEMP_DIR/$table_name/raw.apk"

	# 2. Resolver la versión objetivo según el parámetro del TOML (auto, experimental o fija)
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
	# Validación inteligente de cambios.
	# REBUILD_APPS permite forzar recompilación selectiva para debug:
	#   ""                              → solo apps con cambios
	#   "Messenger"                     → fuerza solo Messenger
	#   "Messenger,Instagram,Telegram"  → fuerza esas 3
	#   "*"                             → fuerza todas
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
	elif ! should_build_app "$patch_repo" "github" "${app_args[channel]}" "$target_apk_ver"; then
		pr "Omitiendo app '$table_name' por falta de cambios."
		continue
	fi

	# ==================================================================
	# 2b. Obtener el tag actual de parches (para el nombre del APK)
	# ==================================================================
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

	# 3. Descargar la APK limpia desde APKMirror usando la versión exacta resuelta
	if [ -n "${app_args[apkmirror_dlurl]}" ]; then
		get_apkmirror_resp "${app_args[apkmirror_dlurl]}" || {
			wpr "No se pudo conectar a APKMirror para $table_name"
			continue
		}

		# --------------------------------------------------------------
		# Leer versionCodes válidos del patches-list.json (si existen)
		# --------------------------------------------------------------
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
			continue
		}
	else
		wpr "La aplicación $table_name no tiene definida una URL de APKMirror válida."
		continue
	fi

	# 3b. Mergear bundle a APK monolítico si es necesario.
	#     was_merged indica si el stock perdió su firma original (necesario
	#     para decidir si se puede generar un módulo Magisk/KernelSU).
	was_merged=false
	if [ -f "$raw_apk" ] && ! unzip -l "$raw_apk" 2>/dev/null | grep -qE '[[:space:]]+AndroidManifest\.xml[[:space:]]*$'; then
		was_merged=true
		pr "Detectado bundle, mergeando con APKEditor..."
		apkm_file="${raw_apk%.apk}.apkm"
		mv "$raw_apk" "$apkm_file"
		if ! java -jar "$APKEDITOR_JAR" m -i "$apkm_file" -o "$raw_apk"; then
			wpr "Fallo el merge del bundle para $table_name"
			continue
		fi
		pr "Bundle mergeado: $raw_apk"
	else
		pr "APK con firma original (válido como stock para módulo)"
	fi

	# 3c. Construir argumentos -d / -e para morphe
	declare -a morphe_patch_args=()

	# (a) exclude-patches → -d= para cada uno
	for pname in "${exclude_patches[@]}"; do
		[ -z "$pname" ] && continue
		morphe_patch_args+=( "-d=$pname" )
	done

	# (b) inclusive-patches=true → -e= para cada patch disabled-by-default
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
					(has("default") and .default == false) or
					(has("use") and .use == false)
				) |
				.name // empty
			' 2>/dev/null
		)

		if [ "${#disabled_patches[@]}" -gt 0 ]; then
			pr "  Forzando ${#disabled_patches[@]} parches disabled-by-default"
			for pname in "${disabled_patches[@]}"; do
				[ -z "$pname" ] && continue
				morphe_patch_args+=( "-e=$pname" )
			done
		else
			wpr "  No se encontraron parches disabled-by-default"
		fi
	fi

	if [ "${#morphe_patch_args[@]}" -gt 0 ]; then
		pr "  Total argumentos de parches: ${#morphe_patch_args[@]}"
	fi

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
    --force \
		"${morphe_patch_args[@]}" \
		"$raw_apk" \
		|| {
			wpr "Error durante el proceso de parcheo de $table_name"
			continue
		}

	if [ ! -f "$patched_apk" ]; then
		wpr "Morphe no generó el APK parcheado para $table_name"
		continue
	fi

	# 4b. Generar módulo Magisk/KernelSU si build-mode lo requiere.
	#     Se omite si el stock fue mergeado (firma perdida → módulo roto).
	#     Si el bundle publica el parche "GmsCore support", se hace un segundo
	#     build excluyéndolo para el módulo (que monta sobre GmsCore ya instalado).
	if [ "${app_args[build_mode]}" = "both" ] || [ "${app_args[build_mode]}" = "module" ]; then
		if [ "$was_merged" = true ]; then
			wpr "Saltando módulo para $table_name: el stock fue mergeado desde un bundle."
		else
			# ------------------------------------------------------------
			# Detectar si el MPP tiene el parche "GmsCore support"
			# ------------------------------------------------------------
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
			pkg_version_code="${NEXT_VER_CODE}"
			module_apk_src="$patched_apk"

			if [ "$gmscore_present" = true ]; then
				pr "  Compilando variante para módulo (sin 'GmsCore support')..."
				module_apk_tmp="$TEMP_DIR/$table_name/module.apk"
				java -jar "$MORPHE_CLI_JAR" patch \
					-p="https://github.com/$patch_repo" \
					-o="$module_apk_tmp" \
					--keystore="$RVB_KEYSTORE" \
					--keystore-password="$RVB_KEYSTORE_PASS" \
					--keystore-entry-alias="$RVB_KEY_ALIAS" \
					--keystore-entry-password="$RVB_KEYSTORE_PASS" \
					--signer="Morphe" \
					--striplibs="${app_args[arch]}" \
          --force \
					"${morphe_patch_args[@]}" \
					-d="GmsCore support" \
					"$raw_apk" \
					|| {
						wpr "Error al compilar la variante para módulo de $table_name"
						continue
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
				"${app_args[arch]}"; then
				pr "Módulo generado: $module_zip"
			else
				wpr "Fallo al generar el módulo para $table_name"
			fi
		fi
	fi

	# 5. Actualizar el registro de estado tras el éxito
	update_build_state "$patch_repo" "${app_args[channel]}" "$latest_applied_tag" "$target_apk_ver"

	# 5b. FIX C4: Actualizar versions_log.json
	if [ -f "versions_log.json" ]; then
		tmp_vlog=$(mktemp)
		jq --arg app "$table_name" \
		   --arg apk_ver "$target_apk_ver" \
		   --arg patch_tag "$latest_applied_tag" \
		   --arg apk_file "$apk_filename" \
		   --arg brand "${app_args[brand]}" \
		   --arg arch "${app_args[arch]}" \
		   --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
		   '.[$app] = {
				apk_version: $apk_ver,
				patches_version: $patch_tag,
				brand: $brand,
				arch: $arch,
				file: $apk_file,
				timestamp: $ts
			}' \
			versions_log.json > "$tmp_vlog" && mv "$tmp_vlog" versions_log.json
		pr "versions_log.json actualizado para $table_name"
	fi

	pr "¡Aplicación '$table_name' procesada y guardada en $patched_apk!"
done

pr "Compilación finalizada con éxito."

# Subir automáticamente las APKs generadas a los GitHub Releases
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