#!/usr/bin/env python3
# apkmirror_search.py
#
# Extrae enlaces de APKMirror a partir del HTML recibido por stdin.

import sys
import re
import json
import html as html_module
import urllib.parse

BASE_SITE = "https://www.apkmirror.com"
WINDOW_BYTES = 2500


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _abs_url(url: str) -> str:
    if url.startswith("http"):
        return url
    return urllib.parse.urljoin(BASE_SITE, url)


def _unescape(s: str) -> str:
    return html_module.unescape(s)


def _clean_text(s: str) -> str:
    return re.sub(r'<[^>]+>', '', s).strip()


def _es_universal(c: dict) -> bool:
    a = c["arch"].lower()
    return "universal" in a or "noarch" in a


def _extract_version(clean: str) -> str:
    """
    Extrae la versión del texto del enlace.
    Soporta formatos como:
      - "App Name 88800 (8.8.8)" -> "8.8.8"
      - "App Name (2.0.3-rc0)" -> "2.0.3-rc0"
      - "App Name 5.3" -> "5.3"
    """
    # 1. Buscar si hay paréntesis al final (ej. "(8.8.8)")
    m_paren = re.search(r'\(([^)]+)\)\s*$', clean)
    if m_paren:
        return m_paren.group(1).strip()
    
    # 2. Si no hay paréntesis, buscar el primer número con formato de versión
    m2 = re.search(r'(\d+\.\d+.*)$', clean)
    if m2:
        return m2.group(1).strip()
    
    # 3. Fallback: última palabra
    return clean.split()[-1]


# ---------------------------------------------------------------------------
# Paso 1: parsear una variante desde la página de release
# ---------------------------------------------------------------------------

def _parse_variant(html: str, match) -> dict:
    url = _abs_url(match.group(1))
    window = html[match.end():match.end() + WINDOW_BYTES]

    tipo = "APK"
    m = re.search(r'class="apkm-badge[^"]*"[^>]*>\s*(BUNDLE|APK)\s*<', window)
    if m:
        tipo = m.group(1)
    elif re.search(r'class="apkm-badge[^"]*"[^>]*>\s*\d+\s*S\s*<', window):
        tipo = "BUNDLE"

    splits = 0
    m = re.search(r'class="apkm-badge[^"]*"[^>]*>\s*(\d+)\s*S\s*<', window)
    if m:
        splits = int(m.group(1))

    celdas = re.findall(r'class="[^"]*dowrap"[^>]*>([^<]+)</div>', window)
    arch        = celdas[0].strip() if len(celdas) > 0 else ""
    min_android = celdas[1].strip() if len(celdas) > 1 else ""
    dpi         = celdas[2].strip() if len(celdas) > 2 else ""

    vc = ""
    m = re.search(r'class="colorLightBlack"[^>]*>\s*(\d{5,})\s*<', window)
    if m:
        vc = m.group(1)

    return {
        "url":         url,
        "tipo":        tipo,
        "splits":      splits,
        "arch":        arch,
        "min_android": min_android,
        "dpi":         dpi,
        "vc":          vc,
    }


# ---------------------------------------------------------------------------
# Filtro por arquitectura
# ---------------------------------------------------------------------------

def _arch_pasa(variant_arch: str, target_arch: str) -> bool:
    if not target_arch:
        return True
    va = variant_arch.lower()
    ta = target_arch.lower()
    if "universal" in va or "noarch" in va:
        return True
    return ta in va


# ---------------------------------------------------------------------------
# Selección de la mejor variante
# ---------------------------------------------------------------------------

def _elegir_mejor(candidatos: list, use_vc_priority: bool = False):
    if not candidatos:
        return None

    grupo = [c for c in candidatos if c["tipo"] == "APK"      and _es_universal(c)]
    if not grupo:
        grupo = [c for c in candidatos if c["tipo"] == "BUNDLE" and _es_universal(c)]
    if not grupo:
        grupo = [c for c in candidatos if c["tipo"] == "APK"]
    if not grupo:
        grupo = [c for c in candidatos if c["tipo"] == "BUNDLE"]
    if not grupo:
        return None

    if use_vc_priority:
        grupo.sort(key=lambda c: (int(c["vc"] or 0), -c["splits"]), reverse=True)
        return grupo[0]

    nodpi = [c for c in grupo if c["dpi"].lower() == "nodpi"]
    if nodpi:
        grupo = nodpi
    else:
        dpi480 = [c for c in grupo if c["dpi"].lower() == "480dpi"]
        if dpi480:
            grupo = dpi480
        else:
            con480 = [c for c in grupo if "480" in c["dpi"]]
            if con480:
                grupo = con480

    grupo.sort(key=lambda c: c["splits"])
    min_splits = grupo[0]["splits"]
    grupo = [c for c in grupo if c["splits"] == min_splits]

    grupo.sort(key=lambda c: int(c["vc"] or 0), reverse=True)
    return grupo[0]


# ---------------------------------------------------------------------------
# Modo: variant
# ---------------------------------------------------------------------------

def cmd_variant():
    arch = sys.argv[2] if len(sys.argv) > 2 else ""

    priority_vcs = set()
    if len(sys.argv) > 3 and sys.argv[3]:
        priority_vcs = set(v.strip() for v in sys.argv[3].split(",") if v.strip())

    html = sys.stdin.read()
    if not html:
        print("ERROR: HTML vacío en stdin", file=sys.stderr)
        sys.exit(1)

    matches = list(re.finditer(r'href="([^"]*-android-apk-download/)"', html))
    if not matches:
        print("ERROR: no se encontraron variantes en el HTML", file=sys.stderr)
        sys.exit(1)

    variantes = [_parse_variant(html, m) for m in matches]

    print(f"INFO: {len(variantes)} variantes encontradas", file=sys.stderr)
    for v in variantes:
        print(
            f"  - {v['tipo']:6} arch={v['arch']:22} "
            f"dpi={v['dpi']:14} splits={v['splits']:2} "
            f"vc={v['vc']:12} {v['url']}",
            file=sys.stderr,
        )

    pasan = [v for v in variantes if _arch_pasa(v["arch"], arch)]

    if priority_vcs:
        con_vc = [v for v in pasan if v["vc"] in priority_vcs]
        if con_vc:
            print(f"INFO: {len(con_vc)} variantes con vc permitido", file=sys.stderr)
            pasan = con_vc
        else:
            print(f"WARN: whitelist de {len(priority_vcs)} codes no coincide con ninguna variante", file=sys.stderr)
            vcs_presentes = sorted(set(v["vc"] or "?" for v in pasan))
            print(f"WARN: vcs presentes en el HTML: {', '.join(vcs_presentes)}", file=sys.stderr)
            print(f"WARN: whitelist buscada: {', '.join(sorted(priority_vcs))}", file=sys.stderr)
    else:
        print("INFO: sin whitelist, sin filtro por versionCode", file=sys.stderr)

    if not pasan:
        print(f"ERROR: ninguna variante sirve para arch='{arch}'", file=sys.stderr)
        sys.exit(1)

    mejor = _elegir_mejor(pasan, use_vc_priority=bool(priority_vcs))
    if not mejor:
        print("ERROR: no se pudo elegir variante", file=sys.stderr)
        sys.exit(1)

    print(f"INFO: elegida {mejor['tipo']} arch={mejor['arch']} dpi={mejor['dpi']} splits={mejor['splits']} vc={mejor['vc']}", file=sys.stderr)
    print(mejor["url"])


# ---------------------------------------------------------------------------
# Modo: download
# ---------------------------------------------------------------------------

def _extract_download_url(html: str):
    for attrs in re.findall(r'<a\b([^>]*)>', html):
        if "downloadButton" not in attrs:
            continue
        m = re.search(r'href="([^"]+)"', attrs)
        if m:
            return _abs_url(_unescape(m.group(1)))

    m = re.search(r'href="([^"]*/download/\?key=[^"]+)"', html)
    if m:
        return _abs_url(_unescape(m.group(1)))

    m = re.search(r'href="([^"]*\?key=[^"]+)"', html)
    if m:
        return _abs_url(_unescape(m.group(1)))

    return None


def cmd_download():
    html = sys.stdin.read()
    if not html:
        print("ERROR: HTML vacío en stdin", file=sys.stderr)
        sys.exit(1)

    url = _extract_download_url(html)
    if not url:
        print("ERROR: no se encontró el botón de descarga", file=sys.stderr)
        sys.exit(1)

    print(f"INFO: botón de descarga: {url}", file=sys.stderr)
    print(url)


# ---------------------------------------------------------------------------
# Modo: final
# ---------------------------------------------------------------------------

def _extract_final_url(html: str):
    for attrs in re.findall(r'<a\b([^>]*)>', html):
        if 'id="download-link"' not in attrs:
            continue
        m = re.search(r'href="([^"]+)"', attrs)
        if m:
            return _abs_url(_unescape(m.group(1)))

    m = re.search(r'href="([^"]*download\.php\?id=[^"]+)"', html)
    if m:
        return _abs_url(_unescape(m.group(1)))

    m = re.search(r'href="([^"]*/wp-content/themes/APKMirror/[^"]+)"', html)
    if m:
        return _abs_url(_unescape(m.group(1)))

    return None


def cmd_final():
    html = sys.stdin.read()
    if not html:
        print("ERROR: HTML vacío en stdin", file=sys.stderr)
        sys.exit(1)

    url = _extract_final_url(html)
    if not url:
        print("ERROR: no se encontró el enlace final", file=sys.stderr)
        sys.exit(1)

    print(f"INFO: enlace final: {url}", file=sys.stderr)
    print(url)


# ---------------------------------------------------------------------------
# Modo: uploads
# ---------------------------------------------------------------------------

def cmd_uploads():
    html = sys.stdin.read()
    if not html:
        print("ERROR: HTML vacío en stdin", file=sys.stderr)
        sys.exit(1)

    m = re.search(r'href="([^"]*uploads/\?appcategory=[^"]+)"', html)
    if not m:
        print("ERROR: no se encontró 'uploads/?appcategory=' en el HTML", file=sys.stderr)
        sys.exit(1)

    url = _abs_url(_unescape(m.group(1)))
    print(f"INFO: URL de uploads: {url}", file=sys.stderr)
    print(url)


# ---------------------------------------------------------------------------
# Modo: list
# ---------------------------------------------------------------------------

def cmd_list():
    allow_all = (sys.argv[2].lower() == "true") if len(sys.argv) > 2 else False
    html = sys.stdin.read()
    if not html:
        print("ERROR: HTML vacío en stdin", file=sys.stderr)
        sys.exit(1)

    print(f"DEBUG: HTML de uploads = {len(html)} bytes", file=sys.stderr)

    content = html
    m = re.search(r'(?:id="primary"|class="[^"]*listWidget[^"]*")(.*)', html, re.DOTALL)
    if m:
        content = m.group(1)
    print(f"DEBUG: content tras filtro primary = {len(content)} bytes", file=sys.stderr)

    all_anchors = re.findall(r'<a\b([^>]*)>(.*?)</a>', content, re.DOTALL)
    print(f"DEBUG: {len(all_anchors)} anchors totales", file=sys.stderr)

    seen = set()
    out = []
    for attrs, text in all_anchors:
        if "fontBlack" not in attrs:
            continue
        href_m = re.search(r'href="([^"]*-release/)"', attrs)
        if not href_m:
            continue
        href = href_m.group(1)

        clean = _clean_text(text)
        if not clean:
            continue
        low = clean.lower()
        if not allow_all and any(k in low for k in ("beta", "alpha", "secondary")):
            continue
        
        # 🆕 Uso de la nueva función _extract_version
        ver = _extract_version(clean)
        
        if ver and ver not in seen:
            seen.add(ver)
            full_url = _abs_url(_unescape(href))
            out.append(f"{ver}\t{full_url}")

    print(f"DEBUG: versiones únicas = {len(out)}", file=sys.stderr)
    for line in out[:5]:
        print(f"DEBUG   {line}", file=sys.stderr)

    if out:
        print("\n".join(out))
        sys.exit(0)
    sys.exit(1)


# ---------------------------------------------------------------------------
# Modo: vers (legacy)
# ---------------------------------------------------------------------------

def cmd_vers():
    allow_all = (sys.argv[2].lower() == "true") if len(sys.argv) > 2 else False
    html = sys.stdin.read()
    if not html:
        print("ERROR: HTML vacío en stdin", file=sys.stderr)
        sys.exit(1)

    content = html
    m = re.search(r'(?:id="primary"|class="[^"]*listWidget[^"]*")(.*)', html, re.DOTALL)
    if m:
        content = m.group(1)

    all_anchors = re.findall(r'<a\b([^>]*)>(.*?)</a>', content, re.DOTALL)

    seen = set()
    versions = []
    for attrs, text in all_anchors:
        if "fontBlack" not in attrs:
            continue
        if not re.search(r'href="[^"]*-release/"', attrs):
            continue

        clean = _clean_text(text)
        if not clean:
            continue
        low = clean.lower()
        if not allow_all and any(k in low for k in ("beta", "alpha", "secondary")):
            continue
        
        # 🆕 Uso de la nueva función _extract_version
        ver = _extract_version(clean)
        
        if ver and ver not in seen:
            seen.add(ver)
            versions.append(ver)

    if versions:
        print("\n".join(versions))
        sys.exit(0)
    sys.exit(1)


# ---------------------------------------------------------------------------
# Modo: next
# ---------------------------------------------------------------------------

def cmd_next():
    html = sys.stdin.read()
    if not html:
        print("ERROR: HTML vacío en stdin", file=sys.stderr)
        sys.exit(1)

    patterns = [
        r'<a[^>]*class="[^"]*(?:nextpostslink|next)[^"]*"[^>]*href="([^"]+)"',
        r'<a[^>]*href="([^"]+)"[^>]*class="[^"]*(?:nextpostslink|next)[^"]*"',
        r'<a[^>]*rel="next"[^>]*href="([^"]+)"',
        r'<a[^>]*href="([^"]+)"[^>]*rel="next"',
    ]

    for pat in patterns:
        matches = list(re.finditer(pat, html))
        if matches:
            for m in matches:
                url = _abs_url(_unescape(m.group(1)))
                if "/uploads/page/" in url or "/page/" in url:
                    print(f"INFO: siguiente página: {url}", file=sys.stderr)
                    print(url)
                    sys.exit(0)

    print("INFO: no hay más páginas (no se encontró botón 'Next')", file=sys.stderr)
    sys.exit(1)


# ---------------------------------------------------------------------------
# Modo: versioncodes
# ---------------------------------------------------------------------------

def cmd_versioncodes():
    if len(sys.argv) < 5:
        print("Uso: versioncodes <package> <version> <arch>", file=sys.stderr)
        sys.exit(1)

    target_pkg = sys.argv[2]
    target_ver = sys.argv[3]
    raw_arch = sys.argv[4].lower()

    arch_variants = {
        raw_arch,
        raw_arch.replace("-", "_"),
        raw_arch.replace("-", ""),
        raw_arch.replace("-", "").upper(),
        raw_arch.replace("-", "_").upper(),
    }
    if raw_arch == "arm64-v8a":
        arch_variants |= {"arm64", "ARM64", "ARM64_V8A", "arm64_v8a", "ARM64V8A"}
    elif raw_arch == "armeabi-v7a":
        arch_variants |= {"arm", "ARM", "ARMEABI_V7A", "armeabi_v7a"}
    elif raw_arch == "x86_64":
        arch_variants |= {"x64", "X64", "X86_64", "x86_64"}
    elif raw_arch == "x86":
        arch_variants |= {"x86", "X86"}

    raw = sys.stdin.read()
    if not raw:
        sys.exit(1)

    try:
        data = json.loads(raw)
    except Exception as e:
        print(f"ERROR: JSON inválido: {e}", file=sys.stderr)
        sys.exit(1)

    if isinstance(data, list):
        patches = data
    elif isinstance(data, dict):
        patches = data.get("patches", [])
    else:
        sys.exit(1)

    codes = set()

    def _from_dict(vcs_dict):
        for k, v in vcs_dict.items():
            if k.upper() in {x.upper() for x in arch_variants}:
                if v is not None:
                    codes.add(str(v))

    def _from_versioncodes(vcs):
        if vcs is None:
            return
        if isinstance(vcs, dict):
            _from_dict(vcs)
        elif isinstance(vcs, list):
            for v in vcs:
                if v is not None:
                    codes.add(str(v))
        elif isinstance(vcs, (str, int)):
            s = str(vcs)
            if "," in s:
                for part in s.split(","):
                    part = part.strip()
                    if part.isdigit():
                        codes.add(part)
            elif s.isdigit():
                codes.add(s)

    def _from_description(desc):
        if not desc or not isinstance(desc, str):
            return
        for m in re.finditer(r'\b(\d{8,10})\b', desc):
            codes.add(m.group(1))

    def _process_target(tgt):
        if not isinstance(tgt, dict):
            return
        tgt_ver = tgt.get("version")
        if tgt_ver and tgt_ver != target_ver:
            return
        _from_versioncodes(tgt.get("versionCodes"))
        _from_description(tgt.get("description"))
        _from_versioncodes(tgt.get("versionCode"))

    def _process_compatibility(comp):
        if not isinstance(comp, dict):
            return
        pkg = comp.get("packageName") or comp.get("name")
        if pkg != target_pkg:
            return
        _from_versioncodes(comp.get("versionCodes"))
        _from_description(comp.get("description"))
        for tgt in comp.get("targets", []) or []:
            _process_target(tgt)

    def _process_compatible_packages(cp):
        if isinstance(cp, list):
            for entry in cp:
                if not isinstance(entry, dict):
                    continue
                pkg = entry.get("packageName") or entry.get("name")
                if pkg != target_pkg:
                    continue
                _from_versioncodes(entry.get("versionCodes"))
                _from_description(entry.get("description"))
                for tgt in entry.get("targets", []) or []:
                    _process_target(tgt)

    for patch in patches:
        if not isinstance(patch, dict):
            continue
        for comp in patch.get("compatibility", []) or []:
            _process_compatibility(comp)
        _process_compatible_packages(patch.get("compatiblePackages"))
        _from_versioncodes(patch.get("versionCodes"))
        _from_description(patch.get("description"))

    if codes:
        print(",".join(sorted(codes, key=lambda x: int(x))))
        sys.exit(0)
    sys.exit(1)


# ---------------------------------------------------------------------------
# Modo: pkg
# ---------------------------------------------------------------------------

def cmd_pkg():
    html = sys.stdin.read()
    m = re.search(r'play\.google\.com/store/apps/details\?id=([a-zA-Z0-9_.]+)', html)
    if m:
        print(m.group(1))
        sys.exit(0)
    m = re.search(r'id=([a-zA-Z0-9_.]+)"\s+class="[^"]*accent_color', html)
    if m:
        print(m.group(1))
        sys.exit(0)
    sys.exit(1)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    if len(sys.argv) < 2:
        print("Uso: apkmirror_search.py <modo> [args...]", file=sys.stderr)
        sys.exit(1)

    modo = sys.argv[1]

    if modo == "variant":
        cmd_variant()
    elif modo == "download":
        cmd_download()
    elif modo == "final":
        cmd_final()
    elif modo == "uploads":
        cmd_uploads()
    elif modo == "list":
        cmd_list()
    elif modo == "vers":
        cmd_vers()
    elif modo == "next":
        cmd_next()
    elif modo == "versioncodes":
        cmd_versioncodes()
    elif modo == "pkg":
        cmd_pkg()
    else:
        print(f"ERROR: modo desconocido '{modo}'", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()