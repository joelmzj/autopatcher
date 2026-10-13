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
main_config_t=$(toml_get_table_main)
COMPRESSION_LEVEL=$(toml_get "$main_config_t" compression-level) || COMPRESSION_LEVEL="9"
DEDUP_MODE=$(toml_get "$main_config_t" dedup-mode) || DEDUP_MODE="log"
RVB_DEDUP_MODE="$DEDUP_MODE"

# Leer el canal global de Morphe Desktop configurado en el TOML
morphe_channel=$(jq -r '."Morphe-Desktop".morphe_desktop_channel // "stable"' <<<"$__TOML__")
pr "Obteniendo CLI de Morphe Desktop (Canal: $morphe_channel)..."
MORPHE_CLI_JAR=$(get_morphe_desktop_cli "$morphe_channel") || abort "No se pudo obtener la CLI de Morphe Desktop"

for table_name in $(toml_get_table_names); do
	# Omitir la tabla de configuración global
	if [ "$table_name" = "Morphe-Desktop" ]; then continue; fi
	if [ -z "$table_name" ]; then continue; fi
	
	t=$(toml_get_table "$table_name")
	enabled=$(toml_get "$t" enabled) || enabled=true
	if [ "$enabled" = false ]; then continue; fi

	declare -A app_args
	app_args[apkmirror_dlurl]=$(toml_get "$t" "apkmirror-dlurl") || app_args[apkmirror_dlurl]=""
	app_args[pkg_name]=$(toml_get "$t" pkg-name) || app_args[pkg_name]=""
	app_args[app_name]=$(toml_get "$t" app-name) || app_args[app_name]=$table_name
	app_args[arch]=$(toml_get "$t" arch) || app_args[arch]="arm64-v8a"
	
	patch_repo=$(toml_get "$t" "patches-source") || abort "Falta la clave 'patches-source' en la sección '$table_name' del config.toml"
	target_apk_ver=$(toml_get "$t" version) || target_apk_ver="auto"

	# Validación inteligente: Omitir si no hay cambios
	if ! should_build_app "$patch_repo" "github" "stable" "$target_apk_ver"; then
		pr "Omitiendo app '$table_name' por falta de cambios."
		continue
	fi

	pr "Procesando aplicación: $table_name (Fuente: $patch_repo)"
	
	# 1. Preparar directorios temporales para la app
    mkdir -p "$TEMP_DIR/$table_name"
    raw_apk="$TEMP_DIR/$table_name/raw.apk"
    
    # 2. Resolver la versión objetivo según el parámetro del TOML (auto, experimental o fija)
    if [ "$target_apk_ver" = "auto" ] || [ "$target_apk_ver" = "experimental" ]; then
        pr "Analizando parches en $patch_repo para resolver versión en modo [$target_apk_ver]..."
        resolved_ver=$(resolve_target_version_from_bundle "$patch_repo" "${app_args[pkg_name]}" "$target_apk_ver" 2>/dev/null || true)
        if [ -n "$resolved_ver" ]; then
            target_apk_ver="$resolved_ver"
            pr "Versión resuelta exitosamente desde el bundle: $target_apk_ver"
        else
            wpr "No se pudo resolver la versión desde el bundle para $table_name. Usando 'latest' como fallback."
            target_apk_ver="latest"
        fi
    fi

    # Si aún quedó en 'latest' (fallback extremo), consultamos la última de APKMirror
    if [ "$target_apk_ver" = "latest" ]; then
        if [ -n "${app_args[apkmirror_dlurl]}" ]; then
            get_apkmirror_resp "${app_args[apkmirror_dlurl]}" || true
            versions_list=$(get_apkmirror_vers)
            target_apk_ver=$(head -n 1 <<< "$versions_list")
            [ -z "$target_apk_ver" ] && target_apk_ver="latest"
        fi
    fi

    patched_apk="$BUILD_DIR/${table_name}-${target_apk_ver}.apk"

    # 3. Descargar la APK limpia desde APKMirror usando la versión exacta resuelta
    if [ -n "${app_args[apkmirror_dlurl]}" ]; then
        get_apkmirror_resp "${app_args[apkmirror_dlurl]}" || {
            wpr "No se pudo conectar a APKMirror para $table_name"
            continue
        }

        pr "Descargando versión $target_apk_ver para $table_name..."
        dl_apkmirror "${app_args[apkmirror_dlurl]}" "$target_apk_ver" "$raw_apk" "${app_args[arch]}" "" false "" || {
            wpr "Fallo al descargar la APK para $table_name"
            continue
        }
    else
        wpr "La aplicación $table_name no tiene definida una URL de APKMirror válida."
        continue
    fi

    # 4. Ejecutar el parcheo utilizando la CLI de Morphe Desktop en Java
    pr "Aplicando parches con Morphe CLI..."
    java -jar "$MORPHE_CLI_JAR" patch \
        --apk "$raw_apk" \
        --out "$patched_apk" \
        --patches "$patch_repo" \
        || {
            wpr "Error durante el proceso de parcheo de $table_name"
            continue
        }

	# 5. Actualizar el registro de estado tras el éxito
	latest_applied_tag=$(get_latest_remote_tag "github" "$patch_repo" "stable")
	update_build_state "$patch_repo" "stable" "$latest_applied_tag" "$target_apk_ver"
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
