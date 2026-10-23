#!/usr/bin/env python3
"""
Genera los enlaces de redirección de Obtainium para joelmzj/autopatcher
leyendo dinámicamente todas las apps configuradas en config.toml.
"""
import json
import sys
from pathlib import Path
from urllib.parse import quote

try:
    import toml
except ImportError:
    sys.exit("❌ Falta el módulo 'toml'. Instala con: pip install toml")

REPO_URL = "https://github.com/joelmzj/autopatcher"
AUTHOR = "joelmzj"
REDIRECT_BASE = "https://apps.obtainium.imranr.dev/redirect?r="

# Opciones obligatorias para que funcione con el tag fijo "stable"
COMMON_SETTINGS = {
    "useLatestAssetDateAsReleaseDate": True,
    "releaseDateAsVersion": True,
    "versionDetection": False,
}


def build_link(app_id: str, app_name: str, apk_prefix: str) -> str:
    """Construye la URL de redirección de Obtainium con doble codificación."""
    settings = {**COMMON_SETTINGS, "apkFilterRegEx": apk_prefix}
    config = {
        "id": app_id,
        "url": REPO_URL,
        "author": AUTHOR,
        "name": app_name,
        # additionalSettings DEBE ser un string serializado
        "additionalSettings": json.dumps(settings, separators=(",", ":")),
    }
    json_blob = json.dumps(config, separators=(",", ":"))
    encoded_payload = quote(json_blob, safe="")
    inner = "obtainium://app/" + encoded_payload
    return REDIRECT_BASE + quote(inner, safe="")


def generate_markdown():
    config_path = Path("config.toml")
    if not config_path.exists():
        sys.exit("❌ No se encontró config.toml")

    data = toml.load(config_path)
    
    lines = [
        "## 📲 Instalar con Obtainium",
        "",
        "Añade cualquiera de estas apps a Obtainium con un solo toque. "
        "Los enlaces ya incluyen la configuración necesaria para el tag fijo `stable`.",
        "",
    ]

    for table_name, app_config in data.items():
        # 1. Ignorar la configuración global
        if table_name == "Morphe-Desktop":
            continue
            
        # 2. Omitir apps deshabilitadas
        if not app_config.get("enabled", True):
            continue
            
        # 3. Obtainium solo acepta APKs. Omitir si el modo es exclusivamente "module"
        build_mode = app_config.get("build-mode", "apk")
        if build_mode == "module":
            continue

        # 4. Nombre visible (usa 'app-name' o el nombre de la tabla por defecto)
        app_name = app_config.get("app-name", table_name)
        
        # 5. Generar el regex dinámicamente.
        # Usar "^" + table_name + "-" garantiza que seleccione exactamente 
        # el APK de esta app y evite confusiones (ej. X vs X-new).
        apk_prefix = f"^{table_name}-"
        
        link = build_link(table_name, app_name, apk_prefix)
        lines.append(f"- **{app_name}** → [Añadir a Obtainium]({link})")

    lines.append("")
    lines.append("> **Nota:** Solo se instalan los APKs. "
                 "Los ZIPs de módulos Magisk/KernelSU no son compatibles con Obtainium.")
    return "\n".join(lines)


if __name__ == "__main__":
    md = generate_markdown()
    Path("OBTAINIUM_LINKS.md").write_text(md, encoding="utf-8")
    print("✅ Generado OBTAINIUM_LINKS.md dinámicamente desde config.toml")