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
                "description": "",
                "default": True,
                "use": True,
                "compatiblePackages": {},
                "compatibility": []
            }
            in_version_codes = False
            pkg_current = None
        elif current is not None:
            if stripped.startswith("Name:"):
                current["name"] = stripped.split(":", 1)[1].strip()
            elif stripped.startswith("Description:"):
                current["description"] = stripped.split(":", 1)[1].strip()
            elif stripped.startswith("Enabled:"):
                enabled = stripped.split(":", 1)[1].strip().lower() == "true"
                current["default"] = enabled
                current["use"] = enabled
            elif stripped.startswith("Package name:"):
                pkg_current = stripped.split(":", 1)[1].strip()
                current["compatiblePackages"][pkg_current] = []
                in_version_codes = False
                # Init compatibility entry for this package
                current["compatibility"].append({
                    "packageName": pkg_current,
                    "targets": []
                })
            elif stripped.startswith("Compatible versions:"):
                in_version_codes = False
            elif stripped.startswith("Version codes:"):
                in_version_codes = True
            elif in_version_codes:
                # Formato: 451.0.0.53.80: ARM64_V8A=385713073, ARMEABI_V7A=385713072
                m = re.match(r'^([\d\.]+[^:]*):\s*(.*)$', stripped)
                if m:
                    version_raw = m.group(1).strip()
                    vm = re.match(r'^([\d\.]+)', version_raw)
                    version = vm.group(1) if vm else version_raw

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

                    if codes_dict:
                        # 1) Formato estándar: compatibility[].targets[].versionCodes
                        if pkg_current:
                            for comp in current["compatibility"]:
                                if comp.get("packageName") == pkg_current:
                                    comp["targets"].append({
                                        "version": version,
                                        "versionCodes": codes_dict
                                    })
                                    break
                        # 2) Formato plano por versión (backward compat)
                        if "versionCodesByVersion" not in current:
                            current["versionCodesByVersion"] = {}
                        current["versionCodesByVersion"][version] = codes_dict
            elif re.match(r'^\d+\.\d+', stripped):
                if pkg_current:
                    current["compatiblePackages"][pkg_current].append(stripped)

    if current:
        patches.append(current)

    # Limpieza
    for p in patches:
        if not p["compatiblePackages"]:
            p["compatiblePackages"] = None
        # Quitar entradas de compatibility sin targets
        p["compatibility"] = [c for c in p.get("compatibility", []) if c.get("targets")]
        if not p["compatibility"]:
            p["compatibility"] = None
        # Default del description
        if not p.get("description"):
            p.pop("description", None)

    return {"patches": patches}


if __name__ == "__main__":
    text = sys.stdin.read()
    result = parse_morphe_cli(text)
    print(json.dumps(result, indent=2))