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
    "autoApkFilterByArch": True,
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
    
    vlog = {}
    if vlog_path.exists():
        try:
            vlog = json.loads(vlog_path.read_text(encoding="utf-8"))
        except Exception as e:
            print(f"⚠️ Advertencia: No se pudo leer versions_log.json: {e}")

    # 🆕 Instrucciones para Android TV (con bloques de código para el botón copiar)
    lines = [
        "## 📲 Instalar con Obtainium",
        "",
        "Añade cualquiera de estas apps a Obtainium con un solo toque (móvil) o manualmente (TV).",
        "",
        "### 📺 Añadir manualmente (especial para Android TV)",
        "Los enlaces directos (`obtainium://`) no siempre funcionan en Android TV. Para añadir una app manualmente:",
        "1. Abre Obtainium en tu TV y pulsa **+** (Añadir App).",
        "2. Pega esta URL como fuente:",
        "```text",
        REPO_URL,
        "```",
        "3. Selecciona la fuente **GitHub**.",
        "4. Ve a **Ajustes Avanzados** de la app y configura lo siguiente:",
        "   - **Filter APKs by regular expression**: Pega la cadena regex específica de la app (ver tabla abajo).",
        "   - **Version detection**: Desactivado (OFF).",
        "   - **Release date as version**: Activado (ON).",
        "   - **Use latest asset upload date as release date**: Activado (ON).",
        "   - **Attempt to filter APKs by CPU architecture if possible**: Activado (ON).",
        "5. Guarda la app.",
        "",
        "> **Nota:** Si notas que un ID de paquete ha cambiado repentinamente (por ejemplo, por un nuevo parche de clonación), "
        "significa que el desarrollador ha modificado el paquete base. Revisa la configuración de esa app.",
        "",
        "---",
        "",
    ]

    for table_name, app_config in data.items():
        if table_name == "Morphe-Desktop":
            continue
        if not app_config.get("enabled", True):
            continue
        if app_config.get("build-mode", "apk") == "module":
            continue

        app_name = table_name
        
        app_vlog = vlog.get(table_name, {})
        pkg_name = app_vlog.get("final_pkg_name") or app_config.get("pkg-name")
        
        if not pkg_name:
            print(f"⚠️ Advertencia: {table_name} no tiene pkg-name, se omite.")
            continue
        
        apk_prefix = f"^{table_name}-"
        
        link = build_link(pkg_name, app_name, apk_prefix)
        
        lines.append(f"### {app_name} (`{pkg_name}`)")
        lines.append(f"- **Enlace directo (móvil):** [Añadir a Obtainium]({link})")
        lines.append("- **Cadena regex (manual):**")
        lines.append("```text")
        lines.append(apk_prefix)
        lines.append("```")
        lines.append("")

    lines.append("---")
    lines.append("> **Nota:** Solo se instalan los APKs (no los módulos).")
    return "\n".join(lines)

if __name__ == "__main__":
    md = generate_markdown()
    Path("OBTAINIUM_LINKS.md").write_text(md, encoding="utf-8")
    print("✅ Generado OBTAINIUM_LINKS.md dinámicamente (con soporte para TV y configuración manual)")