#!/usr/bin/env bash
# build_upload_release.sh
#
# Sube los artefactos compilados a GitHub Releases (solo release `stable`).
#
# Flujo:
#   1. Leer manifest de archivos generados en este run
#   2. Asegurar que el release existe
#   3. Subir archivos nuevos al stable (--clobber)
#   4. Limpiar obsoletos del stable comparando contra versions_log.json

set -euo pipefail
shopt -s nullglob

RELEASE_TAG="${RELEASE_TAG:-stable}"
REPO="${GITHUB_REPOSITORY:-}"
APPS_COMPILED="${APPS_COMPILED:--1}"
MANIFEST="${UPLOADED_FILES_MANIFEST:-}"
VERSIONS_LOG="${VERSIONS_LOG:-versions_log.json}"

pr()  { echo -e "\033[0;32m[+] $1\033[0m"; }
wpr() { echo -e "\033[0;33m[!] $1\033[0m"; }
epr() { echo -e "\033[0;31m[-] $1\033[0m"; }

# ==============================================================================
# Guard: si no se recompiló ninguna app, no tocar el release.
# ==============================================================================
if [ "$APPS_COMPILED" = "0" ]; then
    pr "Sin apps recompiladas en este run (APPS_COMPILED=0)."
    pr "Omitiendo sincronización del release stable."
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
# 2. Asegurar que el release existe
# ==============================================================================
pr "=== Preparando release ==="

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
# 3. Subir archivos nuevos al release stable (--clobber)
# ==============================================================================
pr "=== Subiendo archivos al release $RELEASE_TAG ==="
gh release upload "$RELEASE_TAG" "${files[@]}" --clobber -R "$REPO"
pr "Release $RELEASE_TAG actualizado con ${#files[@]} archivos"

# ==============================================================================
# 4. Limpiar assets obsoletos del stable
# ==============================================================================
pr "=== Verificando assets obsoletos en $RELEASE_TAG ==="

declare -A current_stable_set=()
while IFS= read -r fname; do
    [ -z "$fname" ] && continue
    current_stable_set["$fname"]=1
done < <(jq -r '.[] | .stable_file // empty, .stable_zip // empty' "$VERSIONS_LOG" 2>/dev/null)

# Recargar assets después de la subida para tener los nombres exactos
existing_assets=$(gh release view "$RELEASE_TAG" -R "$REPO" --json assets --jq '.assets[].name' 2>/dev/null || echo "")

if [ -n "$existing_assets" ]; then
    removed=0
    preserved=0
    while IFS= read -r asset; do
        [ -z "$asset" ] && continue
        if [ -z "${current_stable_set[$asset]:-}" ]; then
            if gh release delete-asset "$RELEASE_TAG" "$asset" -R "$REPO" -y >/dev/null 2>&1; then
                pr "  ✗ Eliminado (obsoleto): $asset"
                removed=$((removed + 1))
            fi
        else
            preserved=$((preserved + 1))
        fi
    done <<< "$existing_assets"
    pr "  Eliminados $removed assets obsoletos, $preserved assets vigentes"
else
    pr "  No había assets previos en el release"
fi

# ==============================================================================
# 5. Resumen final
# ==============================================================================
pr "=== ¡Proceso de subida completado! ==="
pr "  Stable: https://github.com/${REPO}/releases/tag/${RELEASE_TAG}"