#!/usr/bin/env python3
# sync_workflow_apps.py
#
# Lee config.toml y regenera el bloque de apps entre marcadores
# AUTO-GENERATED-APPS en TODOS los workflows que lo contengan.

import re
import sys
from pathlib import Path

import toml

CONFIG = Path("config.toml")

# Workflows que pueden contener el bloque
WORKFLOW_DIR = Path(".github/workflows")

BEGIN_MARKER = "# BEGIN: AUTO-GENERATED-APPS"
END_MARKER = "# END: AUTO-GENERATED-APPS"


def get_apps():
    with open(CONFIG, "r", encoding="utf-8") as f:
        data = toml.load(f)

    apps = []
    for key, value in data.items():
        if key == "Morphe-Desktop":
            continue
        if not isinstance(value, dict):
            continue
        apps.append(key)
    return apps


def update_file(path: Path, apps: list) -> bool:
    content = path.read_text(encoding="utf-8")

    # Detectar indentación real de los marcadores en el archivo
    m = re.search(r"^([ \t]*)" + re.escape(BEGIN_MARKER), content, re.MULTILINE)
    if not m:
        return False  # No tiene marcadores, no hay nada que hacer
    indent = m.group(1)

    lines = [f"{indent}{BEGIN_MARKER}"]
    lines.append(f'{indent}- ""')
    lines.append(f'{indent}- "*"')
    for app in apps:
        lines.append(f'{indent}- "{app}"')
    lines.append(f"{indent}{END_MARKER}")
    new_block = "\n".join(lines)

    pattern = re.compile(
        re.escape(BEGIN_MARKER) + r".*?" + re.escape(END_MARKER),
        re.DOTALL,
    )

    new_content = pattern.sub(new_block, content)

    if new_content == content:
        return False

    path.write_text(new_content, encoding="utf-8")
    return True


def main():
    if not CONFIG.is_file():
        print(f"ERROR: {CONFIG} no existe", file=sys.stderr)
        sys.exit(1)

    apps = get_apps()
    if not apps:
        print("ERROR: no se encontraron apps en config.toml", file=sys.stderr)
        sys.exit(1)

    updated = []
    for wf in WORKFLOW_DIR.glob("*.yml"):
        if update_file(wf, apps):
            updated.append(wf.name)

    if updated:
        print(f"[+] Workflows actualizados: {', '.join(updated)}")
    else:
        print("[i] Sin cambios en los workflows")


if __name__ == "__main__":
    main()