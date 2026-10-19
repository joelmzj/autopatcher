#!/usr/bin/env bash
# build_upload_release.sh
#
# Sube los artefactos compilados a GitHub Releases con la estrategia de 2 releases:
#
#   stable   → foto completa con las últimas versiones parcheadas
#   snapshot → foto de las versiones inmediatamente anteriores a stable
#              (solo aparecen apps que alguna vez cambiaron)
#
# Flujo:
#   1. Leer manifest de archivos generados en este run
#   2. Asegurar que ambos releases existen
#   3. Promover versiones previas: stable → snapshot (con el mismo nombre)
#   4. Subir archivos nuevos al stable
#   5. Limpiar obsoletos del stable comparando contra versions_log.json

set -euo pipefail
shopt -s nullglob

RELEASE_TAG="${RELEASE_TAG:-stable}"
SNAPSHOT_TAG="${SNAPSHOT_TAG:-snapshot}"
REPO="${GITHUB_REPOSITORY:-}"
APPS_COMPILED="${APPS_COMPILED:--1}"
MANIFEST="${UPLOADED_FILES_MANIFEST:-}"
VERSIONS_LOG="${VERSIONS_LOG:-versions_log.json}"

pr()  { echo -e "\033[0;32m[+] $1\033[0m"; }
wpr() { echo -e "\033[0;33m[!] $1\033[0m"; }
epr() { echo -e "\033[0;31m[-] $1\033[0m"; }

# ==============================================================================
# Guard: si no se recompiló ninguna app, no tocar los releases.
# ==============================================================================
if [ "$APPS_COMPILED" = "0" ]; then
    pr "Sin apps recompiladas en este run (APPS_COMPILED=0)."
    pr "Omitiendo creación de snapshot y sincronización del release stable."
    exit 0
fi

# ==============================================================================
# Validaciones previas
# ==============================================================================
command -v gh >/dev/null 2>&1 || { epr "gh CLI no encontrado"; exit 1; }
[ -n "$REPO" ] || { epr "GITHUB_REPOSITORY no está definido"; exit 1; }
[ -n "$MANIFEST" ] || { epr "UPLOADED_FILES_MANIFEST no está definido"; exit 1; }
[ -f "$MANIFEST" ] || { epr "Manifest no encontrado: $MANIFEST"; exit 1; }
[ -f "$VERSIONS_LOG" ] || { epr "No existe $VERSIONS_LOG"; exit 1; }

# ==============================================================================
# 1. Leer el manifest (solo basenames de archivos generados en este run)
# ==============================================================================
declare -A manifest_set=()
declare -a files=()

while IFS= read -r fname; do
    [ -z "$fname" ] && continue
    case "$fname" in
        *raw_stock*) continue ;;
    esac
    manifest_set["$fname"]=1
    if [ -f "./build/$fname" ]; then
        files+=("./build/$fname")
    else
        wpr "Manifest menciona '$fname' pero no existe en ./build/"
    fi
done < "$MANIFEST"

if [ "${#files[@]}" -eq 0 ]; then
    epr "Manifest vacío o archivos no encontrados en ./build/"
    exit 1
fi

pr "Archivos generados en este run: ${#files[@]}"
for f in "${files[@]}"; do
    size=$(du -h "$f" 2>/dev/null | cut -f1 || echo "?")
    pr "  - $f ($size)"
done

# ==============================================================================
# 2. Asegurar que ambos releases existen
# ==============================================================================
pr "=== Preparando releases ==="

# Snapshot (prerelease, tag fijo)
if ! gh release view "$SNAPSHOT_TAG" -R "$REPO" >/dev/null 2>&1; then
    pr "El release '$SNAPSHOT_TAG' no existe, se creará vacío"
    gh release create "$SNAPSHOT_TAG" \
        -R "$REPO" \
        --title "Snapshot (versiones previas)" \
        --notes "Backup de las versiones inmediatamente anteriores a stable. Se puebla cuando una app se recompila por primera vez." \
        --prerelease
else
    pr "El release '$SNAPSHOT_TAG' ya existe"
fi

# Stable
if ! gh release view "$RELEASE_TAG" -R "$REPO" >/dev/null 2>&1; then
    pr "El release '$RELEASE_TAG' no existe, se creará vacío"
    gh release create "$RELEASE_TAG" \
        -R "$REPO" \
        --title "$RELEASE_TAG" \
        --notes "Últimas versiones parcheadas"
else
    pr "El release '$RELEASE_TAG' ya existe"
fi

# ==============================================================================
# 3. PROMOTE: mover versiones previas de stable → snapshot
# ==============================================================================
pr "=== Promoviendo versiones previas al snapshot ==="

# 🆕 BUG-02: Set para proteger archivos que no pudieron promocionarse
declare -A pending_promotions=()

promoted=0
while IFS=$'\t' read -r app stable_file stable_zip snapshot_file snapshot_zip prev_stable_file prev_stable_zip; do
    [ -z "$app" ] && continue

    # Solo apps recompiladas en este run
    app_is_compiled=false
    if [ -n "$stable_file" ] && [ "${manifest_set[$stable_file]+_}" ]; then
        app_is_compiled=true
    elif [ -n "$stable_zip" ] && [ "${manifest_set[$stable_zip]+_}" ]; then
        app_is_compiled=true
    fi

    if [ "$app_is_compiled" = "false" ]; then
        continue
    fi

    # --- APK ---
    if [ -n "$prev_stable_file" ]; then
        # 🆕 BUG-05: Si cambió de both -> module, borrar de stable sin promover
        if [ -z "$stable_file" ]; then
            pr "  [$app] Removiendo APK de stable (cambio a modo module): $prev_stable_file"
            gh release delete-asset "$RELEASE_TAG" "$prev_stable_file" -R "$REPO" -y >/dev/null 2>&1 || true
        elif [ "$prev_stable_file" != "$stable_file" ]; then
            pr "  [$app] Promoviendo APK: $prev_stable_file"

            if [ ! -f "./build/$prev_stable_file" ]; then
                pr "    Descargando $prev_stable_file desde stable..."
                gh release download "$RELEASE_TAG" -R "$REPO" \
                    --pattern "$prev_stable_file" --dir "./build/" --clobber 2>/dev/null || true
            fi

            uploaded=false
            if [ -f "./build/$prev_stable_file" ]; then
                if gh release upload "$SNAPSHOT_TAG" "./build/$prev_stable_file" --clobber -R "$REPO" >/dev/null 2>&1; then
                    uploaded=true
                else
                    wpr "    Falló la subida de $prev_stable_file al snapshot"
                fi
            else
                wpr "    No se pudo obtener $prev_stable_file para el snapshot"
            fi

            # 🆕 BUG-01: Solo borrar de stable si la subida fue exitosa
            if [ "$uploaded" = "true" ]; then
                if [ -n "$snapshot_file" ] && [ "$snapshot_file" != "$prev_stable_file" ]; then
                    gh release delete-asset "$SNAPSHOT_TAG" "$snapshot_file" -R "$REPO" -y >/dev/null 2>&1 || true
                fi
                gh release delete-asset "$RELEASE_TAG" "$prev_stable_file" -R "$REPO" -y >/dev/null 2>&1 || true
                promoted=$((promoted + 1))

                # 🆕 BUG-03: Actualizar versions_log.json con el snapshot_file
                tmp_vlog=$(mktemp)
                jq --arg app "$app" --arg sf "$prev_stable_file" \
                   '.[$app].snapshot_file = $sf' "$VERSIONS_LOG" > "$tmp_vlog" \
                   && mv "$tmp_vlog" "$VERSIONS_LOG"
            else
                wpr "    $prev_stable_file NO se borrará de stable porque no se pudo subir al snapshot"
                # 🆕 BUG-02: Proteger el archivo para que la limpieza no lo borre
                pending_promotions["$prev_stable_file"]=1
            fi
        fi
    fi

    # --- ZIP (módulo) ---
    if [ -n "$prev_stable_zip" ]; then
        # 🆕 BUG-05: Si cambió de both -> apk, borrar de stable sin promover
        if [ -z "$stable_zip" ]; then
            pr "  [$app] Removiendo ZIP de stable (cambio a modo apk): $prev_stable_zip"
            gh release delete-asset "$RELEASE_TAG" "$prev_stable_zip" -R "$REPO" -y >/dev/null 2>&1 || true
        elif [ "$prev_stable_zip" != "$stable_zip" ]; then
            pr "  [$app] Promoviendo ZIP: $prev_stable_zip"

            if [ ! -f "./build/$prev_stable_zip" ]; then
                pr "    Descargando $prev_stable_zip desde stable..."
                gh release download "$RELEASE_TAG" -R "$REPO" \
                    --pattern "$prev_stable_zip" --dir "./build/" --clobber 2>/dev/null || true
            fi

            uploaded_zip=false
            if [ -f "./build/$prev_stable_zip" ]; then
                if gh release upload "$SNAPSHOT_TAG" "./build/$prev_stable_zip" --clobber -R "$REPO" >/dev/null 2>&1; then
                    uploaded_zip=true
                else
                    wpr "    Falló la subida de $prev_stable_zip al snapshot"
                fi
            else
                wpr "    No se pudo obtener $prev_stable_zip para el snapshot"
            fi

            # 🆕 BUG-01: Solo borrar de stable si la subida fue exitosa
            if [ "$uploaded_zip" = "true" ]; then
                if [ -n "$snapshot_zip" ] && [ "$snapshot_zip" != "$prev_stable_zip" ]; then
                    gh release delete-asset "$SNAPSHOT_TAG" "$snapshot_zip" -R "$REPO" -y >/dev/null 2>&1 || true
                fi
                gh release delete-asset "$RELEASE_TAG" "$prev_stable_zip" -R "$REPO" -y >/dev/null 2>&1 || true
                promoted=$((promoted + 1))

                # 🆕 BUG-03: Actualizar versions_log.json con el snapshot_zip
                tmp_vlog=$(mktemp)
                jq --arg app "$app" --arg sz "$prev_stable_zip" \
                   '.[$app].snapshot_zip = $sz' "$VERSIONS_LOG" > "$tmp_vlog" \
                   && mv "$tmp_vlog" "$VERSIONS_LOG"
            else
                wpr "    $prev_stable_zip NO se borrará de stable porque no se pudo subir al snapshot"
                # 🆕 BUG-02: Proteger el archivo para que la limpieza no lo borre
                pending_promotions["$prev_stable_zip"]=1
            fi
        fi
    fi
done < <(jq -r '
    to_entries[] |
    [
        .key,
        (.value.stable_file // ""),
        (.value.stable_zip // ""),
        (.value.snapshot_file // ""),
        (.value.snapshot_zip // ""),
        (.value.prev_stable_file // ""),
        (.value.prev_stable_zip // "")
    ] | @tsv
' "$VERSIONS_LOG")

if [ "$promoted" -gt 0 ]; then
    pr "Promovidos $promoted archivos al snapshot"
else
    pr "No hay archivos previos que promover en este run"
fi

# ==============================================================================
# 4. Subir archivos nuevos al release stable (--clobber)
# ==============================================================================
pr "=== Subiendo archivos al release $RELEASE_TAG ==="
gh release upload "$RELEASE_TAG" "${files[@]}" --clobber -R "$REPO"
pr "Release $RELEASE_TAG actualizado con ${#files[@]} archivos"

# ==============================================================================
# 5. Limpiar assets obsoletos del stable
# ==============================================================================
pr "=== Verificando assets obsoletos en $RELEASE_TAG ==="

declare -A current_stable_set=()
while IFS= read -r fname; do
    [ -z "$fname" ] && continue
    current_stable_set["$fname"]=1
done < <(jq -r '.[] | .stable_file // empty, .stable_zip // empty' "$VERSIONS_LOG" 2>/dev/null)

existing_assets=$(gh release view "$RELEASE_TAG" -R "$REPO" --json assets --jq '.assets[].name' 2>/dev/null || echo "")

if [ -n "$existing_assets" ]; then
    removed=0
    preserved=0
    while IFS= read -r asset; do
        [ -z "$asset" ] && continue
        # 🆕 BUG-02: No borrar si está en stable_set o si está pendiente de promoción
        if [ -z "${current_stable_set[$asset]:-}" ] && [ -z "${pending_promotions[$asset]:-}" ]; then
            if gh release delete-asset "$RELEASE_TAG" "$asset" -R "$REPO" -y >/dev/null 2>&1; then
                pr "  ✗ Eliminado (obsoleto): $asset"
                removed=$((removed + 1))
            fi
        else
            preserved=$((preserved + 1))
        fi
    done <<< "$existing_assets"
    pr "  Eliminados $removed assets obsoletos, $preserved assets vigentes/protegidos"
else
    pr "  No había assets previos en el release"
fi

# ==============================================================================
# 6. Resumen final
# ==============================================================================
pr "=== ¡Proceso de subida completado! ==="
pr "  Stable:   https://github.com/${REPO}/releases/tag/${RELEASE_TAG}"
pr "  Snapshot: https://github.com/${REPO}/releases/tag/${SNAPSHOT_TAG}"