#!/usr/bin/env python3
# naming.py
#
# Genera el nombre del APK final con la estructura:
#   {app_name}-v{apk_version}-{brand}-v{patches_version}-{arch}.apk
#
# Uso desde CLI:
#   python3 naming.py <app_name> <apk_version> <brand> <patches_version> <arch>

import sys


def generate_apk_filename(app_name: str, apk_version: str, brand: str,
                          patches_version: str, arch: str) -> str:
    """
    Genera el nombre del archivo APK siguiendo la estructura:
    {app_name}-v{apk_version}-{brand}-v{patches_version}-{arch}.apk
    """
    v_apk = apk_version if apk_version.startswith("v") else f"v{apk_version}"
    v_patches = patches_version if patches_version.startswith("v") else f"v{patches_version}"

    return f"{app_name}-{v_apk}-{brand}-{v_patches}-{arch}.apk"


def main():
    if len(sys.argv) != 6:
        print(
            "Uso: naming.py <app_name> <apk_version> <brand> <patches_version> <arch>",
            file=sys.stderr,
        )
        sys.exit(1)

    app_name, apk_version, brand, patches_version, arch = sys.argv[1:6]
    print(generate_apk_filename(app_name, apk_version, brand, patches_version, arch))


if __name__ == "__main__":
    main()