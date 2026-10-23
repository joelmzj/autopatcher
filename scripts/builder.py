import os
import subprocess
import sys

def build_patch_command(
    cli_source: str,
    cli_path: str,
    patches_sources: str,
    apk_input: str,
    apk_output: str,
    arch: str = None,
    included_patches: list = None,
    excluded_patches: list = None,
    patcher_args: list = None,
    keystore_config: dict = None
) -> list:
    """
    Construye el comando completo para ejecutar el parcheo de la APK,
    soportando múltiples bundles, exclusiones/inclusiones, filtrado nativo de arquitectura y firma segura.
    """
    tool = cli_source.lower()
    cmd = []

    # 1. Resolución inicial según la herramienta
    if "morphe" in tool:
        cmd = [cli_path, "patch", apk_input, "-o", apk_output]
    elif "revanced" in tool:
        cmd = ["java", "-jar", cli_path, "patch", apk_input, "-o", apk_output]
    elif tool in ["xposed", "lspatch", "npatch"]:
        # Lógica para inyección directa de módulos Xposed/LSPatch
        cmd = [cli_path, "patch", apk_input, "-o", apk_output]
    else:
        raise ValueError(f"Herramienta CLI no soportada para compilación: {cli_source}")

    # 2. Soporte para Múltiples Bundles (separados por '|')
    if patches_sources:
        bundles = [b.strip() for b in patches_sources.split("|")]
        for bundle in bundles:
            if "morphe" in tool:
                cmd.extend(["--patches", bundle])
            elif "revanced" in tool:
                cmd.extend(["-b", bundle])

    # 3. Filtrado nativo de arquitectura (ABIs)
    if arch:
        if "morphe" in tool:
            # Morphe CLI utiliza --striplibs para retener/limpiar librerías
            cmd.extend(["--striplibs", arch])
        elif "revanced" in tool:
            # ReVanced CLI utiliza --rip-lib para descartar arquitecturas no deseadas.
            # Como requerimos una arquitectura específica (ej. arm64-v8a), descartamos las demás comunes:
            all_arches = ["armeabi-v7a", "arm64-v8a", "x86", "x86_64"]
            for a in all_arches:
                if a != arch:
                    cmd.extend(["--rip-lib", a])

    # 4. Mapeo de Argumentos, Inclusiones (-e) y Exclusiones (-d)
    if included_patches:
        for patch in included_patches:
            cmd.extend(["-e", patch])
            
    if excluded_patches:
        for patch in excluded_patches:
            cmd.extend(["-d", patch])

    if patcher_args:
        # Argumentos personalizados adicionales definidos en el TOML
        cmd.extend(patcher_args)

    # 5. Firma Segura (Keystore BKS o PKCS12)
    if keystore_config:
        store_path = keystore_config.get("path")
        store_pass = keystore_config.get("password")
        key_alias = keystore_config.get("alias")
        
        if store_path and store_pass and key_alias:
            if "morphe" in tool or "revanced" in tool:
                cmd.extend(["-k", store_path, store_pass, key_alias])

    return cmd

def execute_build(cmd: list):
    """
    Ejecuta el comando de parcheo generado.
    """
    print(f"Ejecutando compilación: {' '.join(cmd)}")
    try:
        subprocess.run(cmd, check=True)
        print("¡Parcheo y compilación completados con éxito!")
    except subprocess.CalledProcessError as e:
        print(f"Error durante el proceso de parcheo: {e}", file=sys.stderr)
        sys.exit(1)