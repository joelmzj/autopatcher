#!/usr/bin/env python3
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

COMMON_SETTINGS = {
    "useLatestAssetDateAsReleaseDate": True,
    "releaseDateAsVersion": True,
    "versionDetection": False,
}

def build_link(app_id: str, app_name: str, apk_prefix: str) -> str:
    settings = {**COMMON_SETTINGS, "apkFilterRegEx": apk_prefix}
    config = {
        "id": app_id,
        "url": REPO_URL,
        "author": AUTHOR,
        "name": app_name,
        "additionalSettings": json.dumps(settings, separators=(",", ":")),
    }
    json_blob = json.dumps(config, separators=(",", ":"))
    encoded_payload = quote(json_blob, safe="")
    inner = "obtainium://app/" + encoded_payload
    return REDIRECT_BASE + quote(inner, safe="")

def generate_markdown():
    config_path = Path("config.toml")
    vlog_path = Path("versions_log.json")
    
    if not config_path.exists():
        sys.exit("❌ No se encontró config.toml")
        
    data = toml.load(config_path)
    
    # Cargar versions_log.json si existe (para los paquetes modificados)
    vlog = {}
    if vlog_path.exists():
        try:
            vlog = json.loads(vlog_path.read_text(encoding="utf-8"))
        except Exception as e:
            print(f"⚠️ Advertencia: No se pudo leer versions_log.json: {e}")

    lines = [
        "## 📲 Instalar con Obtainium",
        "",
        "Añade cualquiera de estas apps a Obtainium con un solo toque.",
        "",
        "> **Nota para YouTube/YouTube Music:** Las versiones de Teléfono y Tablet comparten el mismo paquete. "
        "Solo puedes añadir **una** de ellas a Obtainium a la vez. Si quieres cambiar de variante, "
        "edita el filtro de APK dentro de Obtainium.",
        "",
    ]

    for table_name, app_config in data.items():
        if table_name == "Morphe-Desktop":
            continue
        if not app_config.get("enabled", True):
            continue
        if app_config.get("build-mode", "apk") == "module":
            continue

        app_name = app_config.get("app-name", table_name)
        
        # Buscar el paquete final en versions_log, si no, usar el del TOML
        app_vlog = vlog.get(table_name, {})
        pkg_name = app_vlog.get("final_pkg_name") or app_config.get("pkg-name")
        
        if not pkg_name:
            print(f"⚠️ Advertencia: {table_name} no tiene pkg-name, se omite.")
            continue
        
        apk_prefix = f"^{table_name}-"
        
        link = build_link(pkg_name, app_name, apk_prefix)
        lines.append(f"- **{app_name}** → [Añadir a Obtainium]({link})")

    lines.append("")
    lines.append("> **Nota:** Solo se instalan los APKs.")
    return "\n".join(lines)

if __name__ == "__main__":
    md = generate_markdown()
    Path("OBTAINIUM_LINKS.md").write_text(md, encoding="utf-8")
    print("✅ Generado OBTAINIUM_LINKS.md")