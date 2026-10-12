#!/usr/bin/env bash
set -euo pipefail

# Uploader unificado de releases usando la CLI nativa `gh` con reintentos y clobber.
#
# Entradas (vía variables de entorno):
#   RELEASE_TAG / TAG     : Nombre de la etiqueta del release (ej. stable)
#   RELEASE_TITLE / TITLE : Título del release (opcional)
#   UPLOAD_FILES          : Patrones o archivos a subir (por defecto: "./build/*")
#   GITHUB_REPOSITORY     : owner/repo (requerido)
#   GH_TOKEN / GITHUB_TOKEN: Token de GitHub (requerido)

TAG="${RELEASE_TAG:-${TAG:?RELEASE_TAG o TAG no definido}}"
REPO="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY no definido}"
TITLE="${RELEASE_TITLE:-${TITLE:-}}"
FILES_PATTERN="${UPLOAD_FILES:-./build/*}"

echo "=== Subiendo artefactos al release: $TAG ==="

# 1. Asegurar que el release existe; si no, crearlo
if gh release view "$TAG" -R "$REPO" >/dev/null 2>&1; then
    echo "El release $TAG ya existe. Omitiendo creación."
else
    echo "Creando el release $TAG..."
    if [ -n "$TITLE" ]; then
        gh release create "$TAG" -t "$TITLE" -R "$REPO"
    else
        gh release create "$TAG" -R "$REPO"
    fi
fi

# 2. Recopilar archivos a subir
shopt -s nullglob
FILES=()
for pattern in $FILES_PATTERN; do
    for f in $pattern; do
        [ -f "$f" ] && FILES+=("$f")
    done
done
shopt -u nullglob

if [ ${#FILES[@]} -eq 0 ]; then
    echo "::error:: No se encontraron archivos que coincidan con '$FILES_PATTERN' para subir."
    exit 1
fi

PARALLEL_JOBS="${UPLOAD_CONCURRENCY:-4}"
echo "Subiendo ${#FILES[@]} archivo(s) al release $TAG (concurrencia:$PARALLEL_JOBS)..."

# 3. Subir archivos en paralelo con reintentos por archivo
FAILED_LOG=$(mktemp)
trap 'rm -f "$FAILED_LOG"' EXIT

upload_file() {
    local file="$1"
    local filename
    filename=$(basename "$file")
    echo "⬆️ Subiendo $filename..."
    for attempt in 1 2 3; do
        if gh release upload "$TAG" "$file" --clobber -R "$REPO"; then
            echo "✅ $filename subido con éxito."
            return 0
        fi
        echo "::warning::Intento $attempt/3 falló para $filename, reintentando en 5s..."
        sleep 5
    done
    echo "::error::Fallo al subir $filename después de 3 intentos."
    echo "$filename" >> "$FAILED_LOG"
    return 1
}

job_count=0
for file in "${FILES[@]}"; do
    upload_file "$file" &
    ((job_count++)) || true
    if [ "$job_count" -ge "$PARALLEL_JOBS" ]; then
        wait -n || true
        ((job_count--)) || true
    fi
done
wait

if [ -s "$FAILED_LOG" ]; then
    echo "::error::Los siguientes archivos fallaron al subir:"
    cat "$FAILED_LOG"
    exit 1
fi

echo "=== ¡Todos los artefactos se subieron exitosamente al Release! ==="