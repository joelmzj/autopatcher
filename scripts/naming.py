import os

def generate_apk_filename(app_name: str, apk_version: str, brand: str, patches_version: str, arch: str) -> str:
    """
    Genera el nombre del archivo APK siguiendo la estructura:
    {app_name}-{apk_version}-{brand}-{patches-version}-{arch}.apk
    """
    # Aseguramos los prefijos de versión si es necesario
    v_apk = apk_version if apk_version.startswith("v") else f"v{apk_version}"
    v_patches = patches_version if patches_version.startswith("v") else f"v{patches_version}"
    
    filename = f"{app_name}-{v_apk}-{brand}-{v_patches}-{arch}.apk"
    return filename

if __name__ == "__main__":
    # Ejemplo de prueba con los datos del bloque [Instagram] del config.toml
    app = "Instagram"
    version = "439.0.0.37.89"
    brand_name = "HushGram"
    patches_ver = "2.21.0"
    target_arch = "arm64-v8a"
    
    print(generate_apk_filename(app, version, brand_name, patches_ver, target_arch))