#!/usr/bin/env python3
import sys
import re
import json

def parse_morphe_cli(text):
    patches = []
    current = None
    pkg_current = None
    in_version_codes = False
    
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped:
            continue
            
        if stripped.startswith("Index:"):
            if current:
                patches.append(current)
            current = {
                "name": "",
                "default": True,
                "compatiblePackages": {}
            }
            in_version_codes = False
            pkg_current = None
        elif current is not None:
            if stripped.startswith("Name:"):
                current["name"] = stripped.split(":", 1)[1].strip()
            elif stripped.startswith("Enabled:"):
                current["default"] = stripped.split(":", 1)[1].strip().lower() == "true"
            elif stripped.startswith("Package name:"):
                pkg_current = stripped.split(":", 1)[1].strip()
                current["compatiblePackages"][pkg_current] = []
                in_version_codes = False
            elif stripped.startswith("Compatible versions:"):
                in_version_codes = False
            elif stripped.startswith("Version codes:"):
                in_version_codes = True
            elif in_version_codes:
                # Formato: 583.0.0.39.55: ARM64_V8A=475614366, ARMEABI_V7A=475614365
                m = re.match(r'^([\d\.]+[^:]*):\s*(.*)$', stripped)
                if m:
                    codes_str = m.group(2)
                    codes_dict = {}
                    for pair in codes_str.split(','):
                        pair = pair.strip()
                        if '=' in pair:
                            arch, code = pair.split('=', 1)
                            try:
                                codes_dict[arch.strip()] = int(code.strip())
                            except ValueError:
                                pass
                    
                    if "versionCodes" not in current:
                        current["versionCodes"] = {}
                    current["versionCodes"].update(codes_dict)
            elif re.match(r'^\d+\.\d+', stripped):
                if pkg_current:
                    current["compatiblePackages"][pkg_current].append(stripped)
                    
    if current:
        patches.append(current)
        
    # Limpieza: si no hay paquetes, es universal (null)
    for p in patches:
        if not p["compatiblePackages"]:
            p["compatiblePackages"] = None
            
    return {"patches": patches}

if __name__ == "__main__":
    text = sys.stdin.read()
    result = parse_morphe_cli(text)
    print(json.dumps(result, indent=2))