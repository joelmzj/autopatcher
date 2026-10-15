#!/usr/bin/env python3
# module_builder.py
#
# Empaqueta un APK parcheado dentro de la plantilla del módulo Magisk/KernelSU
# y genera un ZIP instalable.
#
# Estructura del ZIP resultante:
#   <zip>/
#   ├── module.prop                 ← metadata del módulo
#   ├── config                      ← PKG_NAME, PKG_VER, MODULE_ARCH (leído por utils.sh)
#   ├── stock/base.apk              ← APK stock monolítico (se instala en customize.sh)
#   ├── base.apk                    ← APK parcheado (se mueve a /data/adb/rvhc/)
#   ├── customize.sh, service.sh, action.sh, uninstall.sh, utils.sh
#   ├── bin/<arch>/...
#   └── META-INF/com/google/android/...
#
# Uso:
#   module_builder.py <template_dir> <stock_apk> <patched_apk> <output_zip> \
#                     <module_id> <module_name> <pkg_name> <pkg_version> \
#                     <pkg_version_code> <brand> <arch>

import os
import sys
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
    # 4. Generar module.prop
    # ------------------------------------------------------------------
    module_prop_path = os.path.join(temp_dir, "module.prop")
    with open(module_prop_path, "w", encoding="utf-8") as f:
        f.write(f"id={module_id}\n")
        f.write(f"name={module_name}\n")
        f.write(f"version={pkg_version}-{brand}\n")
        f.write(f"versionCode={pkg_version_code}\n")
        f.write(f"author={brand}\n")
        f.write(f"description={module_name} — patched with {brand}\n")
    _log(f"module.prop generado: id={module_id} version={pkg_version}-{brand}")

    # ------------------------------------------------------------------
    # 5. Comprimir todo en el ZIP
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
    # 6. Limpieza
    # ------------------------------------------------------------------
    shutil.rmtree(temp_dir)

    size_mb = os.path.getsize(output_zip) / (1024 * 1024)
    _log(f"módulo generado: {output_zip} ({size_mb:.2f} MB)")


def main():
    # script + 11 args = 12
    if len(sys.argv) != 12:
        print(
            "Uso: module_builder.py <template_dir> <stock_apk> <patched_apk> <output_zip> "
            "<module_id> <module_name> <pkg_name> <pkg_version> <pkg_version_code> "
            "<brand> <arch>",
            file=sys.stderr,
        )
        sys.exit(1)

    create_magisk_module(
        template_dir      = sys.argv[1],
        stock_apk         = sys.argv[2],
        patched_apk       = sys.argv[3],
        output_zip        = sys.argv[4],
        module_id         = sys.argv[5],
        module_name       = sys.argv[6],
        pkg_name          = sys.argv[7],
        pkg_version       = sys.argv[8],
        pkg_version_code  = sys.argv[9],
        brand             = sys.argv[10],
        arch              = sys.argv[11],
    )


if __name__ == "__main__":
    main()