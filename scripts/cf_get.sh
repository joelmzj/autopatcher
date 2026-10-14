#!/usr/bin/env bash
# scripts/cf_get.sh
# Define la función _cf_get para obtener el HTML de una URL usando cf_get.py
# Esta función debe ser cargada (source) desde utils.sh o build.sh.

_cf_get() {
    local url="${1:-}"

    if [[ -z "$url" ]]; then
        echo "Error: _cf_get requiere una URL como primer argumento." >&2
        return 1
    fi

    # Obtener el directorio donde está este script (scripts/)
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    # Ejecutar cf_get.py pasando la URL. Se asume que imprime el HTML en stdout.
    python3 "${script_dir}/cf_get.py" "$url"
}