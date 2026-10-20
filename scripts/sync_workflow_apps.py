#!/usr/bin/env python3
# sync_workflow_apps.py
#
# Lee config.toml y regenera el bloque de apps entre los marcadores
#   # BEGIN: AUTO-GENERATED-APPS
#   # END: AUTO-GENERATED-APPS
# en TODOS los workflows de .github/workflows/ que los contengan.
#
# Uso:
#   python3 scripts/sync_workflow_apps.py
#
# Exit codes:
#   0 → todo OK (con o sin cambios)
#   1 → error (config.toml ausente, sin apps, o directorio workflows no existe)

import re
import sys
from pathlib import Path

try:
    import toml
except ImportError:
    print("ERROR: falta el módulo 'toml'. Instala con: pip install toml", file=sys.stderr)
    sys.exit(1)


CONFIG = Path("config.toml")
WORKFLOW_DIR = Path(".github/workflows")

BEGIN_MARKER = "# BEGIN: AUTO-GENERATED-APPS"
END_MARKER = "# END: AUTO-GENERATED-APPS"

# Tablas que no son apps (configuración global)
EXCLUDED_TABLES = {"Morphe-Desktop"}


def get_apps() -> list:
    """Lee config.toml y devuelve la lista de nombres de tabla (apps)."""
    with open(CONFIG, "r", encoding="utf-8") as f:
        data = toml.load(f)

    apps = []
    for key, value in data.items():
        if key in EXCLUDED_TABLES:
            continue
        if not isinstance(value, dict):
            continue
        apps.append(key)
    return apps


def update_file(path: Path, apps: list) -> bool:
    """
    Regenera el bloque entre marcadores en un archivo.
    Devuelve True si hubo cambios, False si no.
    Si no tiene marcadores, devuelve False sin tocar nada.
    """
    content = path.read_text(encoding="utf-8")

    # 1. Encontrar el marcador de inicio
    m = re.search(r"^([ \t]*)" + re.escape(BEGIN_MARKER), content, re.MULTILINE)
    if not m:
        return False  # No tiene marcadores, no aplica

    # 2. Buscar la línea padre (ej. "options:") hacia atrás
    before = content[:m.start()]
    parent_indent = ""
    for line in reversed(before.splitlines()):
        stripped = line.rstrip()
        if stripped.endswith(":") and not stripped.lstrip().startswith("#"):
            if "options" in stripped:
                parent_indent = re.match(r"^([ \t]*)", line).group(1)
                break
    
    # Fallback seguro si no se encuentra "options:" (evita usar la indentación corrupta)
    if not parent_indent:
        parent_indent = "        " # 8 espacios

    # 3. La indentación correcta para los items es parent_indent + 2 espacios
    item_indent = parent_indent + "  "

    # 4. Construir el bloque nuevo
    lines = [f"{item_indent}{BEGIN_MARKER}"]
    lines.append(f'{item_indent}- ""')
    lines.append(f'{item_indent}- "*"')
    for app in apps:
        lines.append(f'{item_indent}- "{app}"')
    lines.append(f"{item_indent}{END_MARKER}")
    new_block = "\n".join(lines)

    # 5. Reemplazar el bloque.
    # OJO: Esta regex ahora consume los espacios iniciales (^[ \t]*) 
    # para destruir cualquier indentación corrupta que exista antes del marcador.
    pattern = re.compile(
        r"^[ \t]*" + re.escape(BEGIN_MARKER) + r".*?" + re.escape(END_MARKER),
        re.MULTILINE | re.DOTALL,
    )
    new_content = pattern.sub(new_block, content)

    if new_content == content:
        return False

    path.write_text(new_content, encoding="utf-8")
    return True


def main():
    if not CONFIG.is_file():
        print(f"ERROR: {CONFIG} no existe en el directorio actual", file=sys.stderr)
        sys.exit(1)

    if not WORKFLOW_DIR.is_dir():
        print(f"ERROR: {WORKFLOW_DIR} no existe", file=sys.stderr)
        sys.exit(1)

    apps = get_apps()
    if not apps:
        print("ERROR: no se encontraron apps en config.toml (revisar formato)", file=sys.stderr)
        sys.exit(1)

    print(f"[i] Apps detectadas en config.toml: {len(apps)}")
    for app in apps:
        print(f"    - {app}")

    # Buscar en todos los .yml y .yaml
    workflow_files = sorted(
        list(WORKFLOW_DIR.glob("*.yml")) + list(WORKFLOW_DIR.glob("*.yaml"))
    )

    if not workflow_files:
        print(f"ERROR: no hay workflows en {WORKFLOW_DIR}", file=sys.stderr)
        sys.exit(1)

    updated = []
    skipped = []

    for wf in workflow_files:
        try:
            if update_file(wf, apps):
                updated.append(wf.name)
            else:
                # Verificar si el archivo tenía marcadores o no
                content = wf.read_text(encoding="utf-8")
                if BEGIN_MARKER in content:
                    skipped.append(wf.name)  # tenía marcadores pero sin cambios
                # else: no tenía marcadores, se ignora silenciosamente
        except Exception as e:
            print(f"[!] Error procesando {wf.name}: {e}", file=sys.stderr)

    print("")
    if updated:
        print(f"[+] Workflows actualizados: {', '.join(updated)}")
    if skipped:
        print(f"[i] Sin cambios (ya sincronizados): {', '.join(skipped)}")
    if not updated and not skipped:
        print(f"[i] Ningún workflow contenía los marcadores AUTO-GENERATED-APPS")


if __name__ == "__main__":
    main()