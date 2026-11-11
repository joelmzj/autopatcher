import subprocess
import sys


def get_patcher_command(cli_source: str, cli_path: str, patches_source: str, package_name: str = None) -> list:
    """
    Construye el comando CLI adecuado para Morphe Desktop.
    """
    tool = cli_source.lower()

    if "morphe" not in tool:
        raise ValueError(f"Herramienta CLI no soportada: {cli_source}")

    cmd = [cli_path, "--patches", patches_source, "list-patches"]
    if package_name:
        cmd.extend([f"--filter-package-name={package_name}", "--with-versions", "--with-packages"])
    return cmd


def fetch_available_patches(cli_source: str, cli_path: str, patches_source: str, package_name: str = None):
    """
    Ejecuta la consulta de parches disponible para Morphe.
    """
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