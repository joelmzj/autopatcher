import os
import shutil
import zipfile

def create_magisk_module(
    module_template_dir: str,
    apk_path: str,
    output_zip_path: str,
    app_name: str,
    version: str
):
    """
    Empaqueta el APK parcheado dentro de la plantilla del módulo Magisk/KernelSU
    ubicada en la carpeta 'module/' y genera un archivo ZIP instalable.
    """
    temp_dir = "temp_module_build"
    
    # 1. Copiar la plantilla base del módulo a un directorio temporal de trabajo
    if os.path.exists(temp_dir):
        shutil.rmtree(temp_dir)
    shutil.copytree(module_template_dir, temp_dir)
    
    # 2. Definir la ruta de destino del APK dentro del módulo (según la convención del proyecto)
    # Por lo general, los módulos de overlay/app colocan el APK en system/app o una ruta similar
    target_app_dir = os.path.join(temp_dir, "system", "app", app_name)
    os.makedirs(target_app_dir, exist_ok=True)
    
    # Copiar el APK parcheado al directorio del módulo
    shutil.copy(apk_path, os.path.join(target_app_dir, f"{app_name}.apk"))
    
    # 3. Opcional: Actualizar dinámicamente el archivo module.prop con la versión actual
    prop_path = os.path.join(temp_dir, "module.prop")
    if os.path.exists(prop_path):
        with open(prop_path, "r", encoding="utf-8") as f:
            content = f.read()
        
        # Reemplazos básicos de metadatos si es necesario
        content = content.replace("version=1.0", f"version={version}")
        content = content.replace("versionCode=1", f"versionCode={version.replace('.', '')}")
        
        with open(prop_path, "w", encoding="utf-8") as f:
            f.write(content)

    # 4. Comprimir el directorio temporal en un archivo ZIP manteniendo la estructura META-INF
    with zipfile.ZipFile(output_zip_path, 'w', zipfile.ZIP_DEFLATED) as zipf:
        for root, dirs, files in os.walk(temp_dir):
            for file in files:
                file_path = os.path.join(root, file)
                # Calcular la ruta relativa para el archivo dentro del zip
                arcname = os.path.relpath(file_path, temp_dir)
                zipf.write(file_path, arcname)
                
    # Limpiar el directorio temporal
    shutil.rmtree(temp_dir)
    print(f"Módulo Magisk/KernelSU creado exitosamente en: {output_zip_path}")

if __name__ == "__main__":
    # Ejemplo de prueba local
    pass