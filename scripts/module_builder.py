#!/usr/bin/env python3
# module_builder.py
#
# Empaqueta un APK parcheado dentro de la plantilla del módulo Magisk/KernelSU
# y genera un ZIP instalable con module.prop y update.json.
#
# Estructura del ZIP resultante:
#   <zip>/
#   ├── module.prop                 ← metadata del módulo (con updateJson)
#   ├── update.json                 ← metadata para Magisk/KernelSU
#   ├── config                      ← PKG_NAME, PKG_VER, MODULE_ARCH
#   ├── stock/base.apk              ← APK stock monolítico
#   ├── base.apk                    ← APK parcheado
#   ├── customize.sh, service.sh, action.sh, uninstall.sh, utils.sh
#   ├── bin/<arch>/...
#   └── META-INF/com/google/android/...
#
# Uso:
#   module_builder.py <template_dir> <stock_apk> <patched_apk> <output_zip> \
#                     <module_id> <module_name> <pkg_name> <pkg_version> \
#                     <pkg_version_code> <brand> <arch> <latest_applied_tag> <channel>

import os
import sys
import json
import shutil
import zipfile


# Mapeo: arquitectura Android → nombre que usa customize.sh (ARCH)
ARCH_MAP = {
    "arm64-v8a":    "arm64",
    "armeabi-v7a":  "arm",
    "armeabi":      "arm",
    "x86_64":       "x64",
    "x86":          "x86",
}


def _log(msg: str):
    print(f"[module_builder] {msg}", file=sys.stderr)


def _die(msg: str):
    print(f"[module_builder] ERROR: {msg}", file=sys.stderr)
    sys.exit(1)


def _arch_suffix(arch: str) -> str:
    """'arm64-v8a' → 'arm64', 'armeabi-v7a' → 'arm', resto igual."""
    if arch == "arm64-v8a":
        return "arm64"
    if arch == "armeabi-v7a":
        return "arm"
    return arch


def _format_patch_short(tag: str) -> str:
    """
    Convierte el tag del bundle en una etiqueta corta para el 'version'.
      'v1.48.0-dev.9' -> 'dev.9.mpp'
      'v0.0.11'       -> '0.0.11.mpp'
      'v4.4.0-dev.2'  -> 'dev.2.mpp'
    """
    if not tag or tag == "unknown":
        return "unknown.mpp"
    if "-dev." in tag:
        return "dev." + tag.split("-dev.")[-1] + ".mpp"
    if tag.startswith("v"):
        return tag[1:] + ".mpp"
    return tag + ".mpp"


def create_magisk_module(
    template_dir: str,
    stock_apk: str,
    patched_apk: str,
    output_zip: str,
    module_id: str,
    module_name: str,
    pkg_name: str,
    pkg_version: str,
    pkg_version_code: str,
    brand: str,
    arch: str,
    latest_applied_tag: str = "",
    channel: str = "stable",
):
    # ------------------------------------------------------------------
    # Validaciones
    # ------------------------------------------------------------------
    if not os.path.isdir(template_dir):
        _die(f"template_dir no existe: {template_dir}")
    if not os.path.isfile(stock_apk):
        _die(f"stock_apk no existe: {stock_apk}")
    if not os.path.isfile(patched_apk):
        _die(f"patched_apk no existe: {patched_apk}")

    module_arch = ARCH_MAP.get(arch.lower())
    if not module_arch:
        _die(f"arquitectura desconocida: {arch}")

    if not pkg_version_code:
        pkg_version_code = "1"

    # ------------------------------------------------------------------
    # Preparar directorio temporal
    # ------------------------------------------------------------------
    temp_dir = "temp_module_build"
    if os.path.exists(temp_dir):
        shutil.rmtree(temp_dir)
    shutil.copytree(template_dir, temp_dir)

    # ------------------------------------------------------------------
    # 1. Copiar el APK stock a stock/base.apk
    # ------------------------------------------------------------------
    stock_dir = os.path.join(temp_dir, "stock")
    os.makedirs(stock_dir, exist_ok=True)
    stock_dst = os.path.join(stock_dir, "base.apk")
    shutil.copy(stock_apk, stock_dst)
    _log(f"stock APK copiado: {stock_dst}")

    # ------------------------------------------------------------------
    # 2. Copiar el APK parcheado como base.apk en la raíz del módulo
    # ------------------------------------------------------------------
    patched_dst = os.path.join(temp_dir, "base.apk")
    shutil.copy(patched_apk, patched_dst)
    _log(f"patched APK copiado: {patched_dst}")

    # ------------------------------------------------------------------
    # 3. Generar el archivo config (lo lee utils.sh del módulo)
    # ------------------------------------------------------------------
    config_path = os.path.join(temp_dir, "config")
    with open(config_path, "w", encoding="utf-8") as f:
        f.write(f'PKG_NAME="{pkg_name}"\n')
        f.write(f'PKG_VER="{pkg_version}"\n')
        f.write(f'MODULE_ARCH="{module_arch}"\n')
    _log(f"config generado: PKG_NAME={pkg_name} PKG_VER={pkg_version} MODULE_ARCH={module_arch}")

    # ------------------------------------------------------------------
    # 4. Construir slug único del módulo
    #    Formato: {app_slug}-{channel}-{arch}
    #    Ej: "youtubemusic-morphe-stable-arm64"
    # ------------------------------------------------------------------
    app_slug = module_id.replace("_", "-")
    arch_sfx = _arch_suffix(arch)
    module_slug = f"{app_slug}-{channel}-{arch_sfx}"

    # ------------------------------------------------------------------
    # 5. Formatear version string
    #    Formato: "v{apk_version} (patches {patch_short})"
    #    Ej: "v9.20.53 (patches dev.9.mpp)"
    # ------------------------------------------------------------------
    patch_short = _format_patch_short(latest_applied_tag)
    version_string = f"v{pkg_version} (patches {patch_short})"

    # versionCode: usar el pkg_version_code (numérico). Si no lo es, hash determinista.
    try:
        vc_int = int(pkg_version_code)
    except ValueError:
        vc_int = abs(hash(f"{module_slug}-{pkg_version}")) % 1000000

    # ------------------------------------------------------------------
    # 6. Generar module.prop con formato nuevo
    # ------------------------------------------------------------------
    github_repo = os.environ.get("GITHUB_REPOSITORY", "OWNER/REPO")
    update_json_url = (
        f"https://raw.githubusercontent.com/{github_repo}"
        f"/update/{channel}/{app_slug}-{arch_sfx}.json"
    )

    module_prop_path = os.path.join(temp_dir, "module.prop")
    with open(module_prop_path, "w", encoding="utf-8") as f:
        f.write(f"id={module_slug}\n")
        f.write(f"name={module_name}\n")
        f.write(f"version={version_string}\n")
        f.write(f"versionCode={vc_int}\n")
        f.write(f"author={brand}\n")
        f.write(f"description={module_name} module\n")
        f.write(f"updateJson={update_json_url}\n")
    _log(f"module.prop generado: id={module_slug} version={version_string}")

    # ------------------------------------------------------------------
    # 7. Generar update.json (para Magisk/KernelSU)
    # ------------------------------------------------------------------
    zip_filename = os.path.basename(output_zip)
    zip_url = (
        f"https://github.com/{github_repo}"
        f"/releases/download/{channel}/{zip_filename}"
    )
    changelog_url = (
        f"https://raw.githubusercontent.com/{github_repo}"
        f"/update/changelogs/{pkg_version_code}.md"
    )

    update_json_path = os.path.join(temp_dir, "update.json")
    with open(update_json_path, "w", encoding="utf-8") as f:
        json.dump({
            "version": version_string,
            "versionCode": vc_int,
            "zipUrl": zip_url,
            "changelog": changelog_url,
        }, f, indent=2, ensure_ascii=False)
    _log(f"update.json generado: version={version_string} versionCode={vc_int}")

    # ------------------------------------------------------------------
    # 8. Comprimir todo en el ZIP
    # ------------------------------------------------------------------
    if os.path.exists(output_zip):
        os.remove(output_zip)

    with zipfile.ZipFile(output_zip, "w", zipfile.ZIP_DEFLATED) as zipf:
        for root, dirs, files in os.walk(temp_dir):
            for file in files:
                file_path = os.path.join(root, file)
                arcname = os.path.relpath(file_path, temp_dir)
                zipf.write(file_path, arcname)

    # ------------------------------------------------------------------
    # 9. Limpieza
    # ------------------------------------------------------------------
    shutil.rmtree(temp_dir)

    size_mb = os.path.getsize(output_zip) / (1024 * 1024)
    _log(f"módulo generado: {output_zip} ({size_mb:.2f} MB)")


def main():
    # script + 13 args = 14
    if len(sys.argv) != 14:
        print(
            "Uso: module_builder.py <template_dir> <stock_apk> <patched_apk> <output_zip> "
            "<module_id> <module_name> <pkg_name> <pkg_version> <pkg_version_code> "
            "<brand> <arch> <latest_applied_tag> <channel>",
            file=sys.stderr,
        )
        sys.exit(1)

    create_magisk_module(
        template_dir       = sys.argv[1],
        stock_apk          = sys.argv[2],
        patched_apk        = sys.argv[3],
        output_zip         = sys.argv[4],
        module_id          = sys.argv[5],
        module_name        = sys.argv[6],
        pkg_name           = sys.argv[7],
        pkg_version        = sys.argv[8],
        pkg_version_code   = sys.argv[9],
        brand              = sys.argv[10],
        arch               = sys.argv[11],
        latest_applied_tag = sys.argv[12],
        channel            = sys.argv[13],
    )


if __name__ == "__main__":
    main()