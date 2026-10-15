#!/usr/bin/env bash
# build_upload_release.sh
#
# Sube los artefactos compilados a GitHub Releases con la estrategia:
#   1. Crear un release "snapshot" (prerelease) con el set completo del run
#   2. Limpiar los assets del release "stable" (URL limpia para descargas)
#   3. Subir el set completo al release "stable"
#   4. Aplicar retención: borrar snapshots de más de N días
#
# Variables de entorno esperadas:
#   RELEASE_TAG               (default: stable)       Tag del release estable
#   SNAPSHOT_TAG              (default: "")           Tag del snapshot (lo setea build.sh)
#   UPLOAD_FILES              (default: ./build/*.apk ./build/*.zip)
#   GITHUB_REPOSITORY         (requerido)             owner/repo
#   SNAPSHOT_RETENTION_DAYS   (default: 30)           Días de retención
#   VERSIONS_LOG              (default: versions_log.json)

set -euo pipefail
shopt -s nullglob

RELEASE_TAG="${RELEASE_TAG:-stable}"
SNAPSHOT_TAG="${SNAPSHOT_TAG:-}"
UPLOAD_FILES="${UPLOAD_FILES:-./build/*.apk ./build/*.zip}"
REPO="${GITHUB_REPOSITORY:-}"
SNAPSHOT_RETENTION_DAYS="${SNAPSHOT_RETENTION_DAYS:-30}"
VERSIONS_LOG="${VERSIONS_LOG:-versions_log.json}"

pr()  { echo -e "\033[0;32m[+] $1\033[0m"; }
wpr() { echo -e "\033[0;33m[!] $1\033[0m"; }
epr() { echo -e "\033[0;31m[-] $1\033[0m"; }

# ==============================================================================
# Validaciones previas
# ==============================================================================

command -v gh >/dev/null 2>&1 || { epr "gh CLI no encontrado"; exit 1; }
[ -n "$REPO" ] || { epr "GITHUB_REPOSITORY no está definido"; exit 1; }

# ==============================================================================
# Recolectar archivos a subir (excluyendo raw_stock_*)
# ==============================================================================

declare -a files=()
for pattern in $UPLOAD_FILES; do
    for f in $pattern; do
        case "$f" in
            *raw_stock*) continue ;;
        esac
        [ -f "$f" ] && files+=("$f")
    done
done

# Añadir versions_log.json si existe
if [ -f "$VERSIONS_LOG" ]; then
    files+=("$VERSIONS_LOG")
fi

if [ "${#files[@]}" -eq 0 ]; then
    epr "No se encontraron archivos para subir (patrón: $UPLOAD_FILES)"
    exit 1
fi

pr "Archivos a subir: ${#files[@]}"
for f in "${files[@]}"; do
    size=$(du -h "$f" 2>/dev/null | cut -f1 || echo "?")
    pr "  - $f ($size)"
done

# ==============================================================================
# 1. Crear release snapshot (prerelease)
# ==============================================================================

if [ -n "$SNAPSHOT_TAG" ]; then
    pr "=== Creando snapshot release: $SNAPSHOT_TAG ==="

    if gh release view "$SNAPSHOT_TAG" -R "$REPO" >/dev/null 2>&1; then
        wpr "El release $SNAPSHOT_TAG ya existe, se subirán/actualizarán assets"
        pr "Subiendo ${#files[@]} archivos al snapshot..."
        gh release upload "$SNAPSHOT_TAG" "${files[@]}" --clobber -R "$REPO"
    else
        pr "Subiendo ${#files[@]} archivos al nuevo snapshot..."
        gh release create "$SNAPSHOT_TAG" "${files[@]}" \
            -R "$REPO" \
            --title "Snapshot $SNAPSHOT_TAG" \
            --notes "Automated snapshot of build $(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            --prerelease
    fi

    pr "Snapshot $SNAPSHOT_TAG completado"
else
    wpr "SNAPSHOT_TAG no definido, se omite creación de snapshot"
fi

# ==============================================================================
# 2. Asegurar que el release stable existe
# ==============================================================================

pr "=== Preparando release $RELEASE_TAG ==="

if ! gh release view "$RELEASE_TAG" -R "$REPO" >/dev/null 2>&1; then
    pr "El release $RELEASE_TAG no existe, se creará vacío"
    gh release create "$RELEASE_TAG" \
        -R "$REPO" \
        --title "$RELEASE_TAG" \
        --notes "Latest stable build — rebuilt on every run"
fi

# ==============================================================================
# 3. Limpiar assets viejos del release stable
# ==============================================================================

pr "Limpiando assets antiguos del release $RELEASE_TAG..."

existing_assets=$(gh release view "$RELEASE_TAG" -R "$REPO" --json assets --jq '.assets[].name' 2>/dev/null || echo "")

if [ -n "$existing_assets" ]; then
    removed=0
    while IFS= read -r asset; do
        [ -z "$asset" ] && continue
        if gh release delete-asset "$RELEASE_TAG" "$asset" -R "$REPO" -y >/dev/null 2>&1; then
            removed=$((removed + 1))
        fi
    done <<< "$existing_assets"
    pr "  Eliminados $removed assets antiguos"
else
    pr "  No había assets que eliminar"
fi

# ==============================================================================
# 4. Subir archivos al release stable
# ==============================================================================

pr "Subiendo ${#files[@]} archivos al release $RELEASE_TAG..."
gh release upload "$RELEASE_TAG" "${files[@]}" --clobber -R "$REPO"
pr "Release $RELEASE_TAG actualizado"

# ==============================================================================
# 5. Retención: borrar snapshots antiguos
# ==============================================================================

if [ "$SNAPSHOT_RETENTION_DAYS" -gt 0 ]; then
    pr "=== Aplicando retención de snapshots (${SNAPSHOT_RETENTION_DAYS} días) ==="

    # jq filtra in-situ: tags que empiezan por "snapshot-" y son más antiguos
    # que el cutoff calculado como (now - N * 86400)
    old_snapshots=$(gh release list -R "$REPO" --limit 200 \
        --json tagName,createdAt --jq \
        ".[] | select(.tagName | startswith(\"snapshot-\")) | select((.createdAt | fromdateiso8601) < (now - ${SNAPSHOT_RETENTION_DAYS} * 86400)) | .tagName" \
        2>/dev/null || echo "")

    if [ -n "$old_snapshots" ]; then
        count=0
        while IFS= read -r tag; do
            [ -z "$tag" ] && continue
            pr "  Eliminando snapshot antiguo: $tag"
            if gh release delete "$tag" -R "$REPO" -y --cleanup-tag >/dev/null 2>&1; then
                count=$((count + 1))
            fi
        done <<< "$old_snapshots"
        pr "  Eliminados $count snapshots antiguos"
    else
        pr "  No hay snapshots antiguos que eliminar"
    fi
fi

# ==============================================================================
# 6. Resumen final
# ==============================================================================

pr "=== ¡Proceso de subida completado! ==="
pr "  Release estable: https://github.com/${REPO}/releases/tag/${RELEASE_TAG}"
if [ -n "$SNAPSHOT_TAG" ]; then
    pr "  Snapshot actual: https://github.com/${REPO}/releases/tag/${SNAPSHOT_TAG}"
fi