import subprocess
import sys

def get_patcher_command(cli_source: str, cli_path: str, patches_source: str, package_name: str = None) -> list:
    """
    Construye el comando CLI adecuado según la herramienta configurada (cli-source).
    """
    tool = cli_source.lower()
    
    if "morphe" in tool:
        # Morphe Desktop CLI
        cmd = [cli_path, "--patches", patches_source, "list-patches"]
        if package_name:
            cmd.extend([f"--filter-package-name={package_name}", "--with-versions", "--with-packages"])
        return cmd
        
    elif "revanced" in tool:
        # ReVanced CLI oficial
        cmd = ["java", "-jar", cli_path, "list-patches", "-b", patches_source]
        return cmd
        
    elif tool in ["xposed", "lspatch", "npatch"]:
        # Herramientas sin listado complejo de parches (has_list = false)
        return []
        
    else:
        raise ValueError(f"Herramienta CLI no soportada: {cli_source}")

def fetch_available_patches(cli_source: str, cli_path: str, patches_source: str, package_name: str = None):
    """
    Verifica si la herramienta soporta listados de parches y ejecuta la consulta correspondiente.
    """
    tool = cli_source.lower()
    
    # Manejo para herramientas con has_list = false
    if tool in ["xposed", "lspatch", "npatch"]:
        print(f"[{cli_source}] has_list = false. Omitiendo listado dinámico de parches (inyección directa).")
        return {
            "has_list": False,
            "patches": []
        }
    
    cmd = get_patcher_command(cli_source, cli_path, patches_source, package_name)
    print(f"Ejecutando consulta de parches: {' '.join(cmd)}")
    
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, check=True)
        return {
            "has_list": True,
            "output": result.stdout
        }
    except subprocess.CalledProcessError as e:
        print(f"Error al obtener la lista de parches: {e.stderr}", file=sys.stderr)
        sys.exit(1)