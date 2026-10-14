#!/usr/bin/env python3
# apkmirror_search.py
#
# Extrae enlaces de APKMirror a partir del HTML recibido por stdin.
#
# Modos:
#   uploads            → URL de uploads (página base → href con ?appcategory=)
#   list <allow_all>   → versiones + hrefs de release (página uploads)
#   variant <arch>     → URL de la variante óptima (página de release)
#   download           → URL del botón de descarga (página de variante)
#   final              → URL del archivo .apk (página intermedia)
#   pkg                → nombre de paquete (página base)
#   vers <allow_all>   → (legacy) lista de versiones sin href
#
# Uso:
#   cat base.html     | python3 apkmirror_search.py uploads
#   cat uploads.html  | python3 apkmirror_search.py list true
#   cat release.html  | python3 apkmirror_search.py variant arm64-v8a
#   cat variant.html  | python3 apkmirror_search.py download
#   cat step2.html    | python3 apkmirror_search.py final
#   cat base.html     | python3 apkmirror_search.py pkg

import sys
import re
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


# ---------------------------------------------------------------------------
# Paso 1: parsear una variante desde la página de release
# ---------------------------------------------------------------------------

def _parse_variant(html: str, match) -> dict:
    url = _abs_url(match.group(1))
    window = html[match.end():match.end() + WINDOW_BYTES]

    # Tipo: primer badge con texto BUNDLE o APK
    tipo = "APK"
    m = re.search(r'class="apkm-badge[^"]*"[^>]*>\s*(BUNDLE|APK)\s*<', window)
    if m:
        tipo = m.group(1)
    elif re.search(r'class="apkm-badge[^"]*"[^>]*>\s*\d+\s*S\s*<', window):
        tipo = "BUNDLE"

    # Splits
    splits = 0
    m = re.search(r'class="apkm-badge[^"]*"[^>]*>\s*(\d+)\s*S\s*<', window)
    if m:
        splits = int(m.group(1))

    # Celdas dowrap": arch, minAndroid, dpi
    celdas = re.findall(r'class="[^"]*dowrap"[^>]*>([^<]+)</div>', window)
    arch        = celdas[0].strip() if len(celdas) > 0 else ""
    min_android = celdas[1].strip() if len(celdas) > 1 else ""
    dpi         = celdas[2].strip() if len(celdas) > 2 else ""

    # Version code
    vc = ""
    m = re.search(r'<span class="colorLightBlack">(\d{5,})</span>', window)
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

def _elegir_mejor(candidatos: list):
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

    # Desempate por DPI
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

    # Desempate por splits
    grupo.sort(key=lambda c: c["splits"])
    min_splits = grupo[0]["splits"]
    grupo = [c for c in grupo if c["splits"] == min_splits]

    # Desempate por VC
    grupo.sort(key=lambda c: int(c["vc"] or 0), reverse=True)
    return grupo[0]


# ---------------------------------------------------------------------------
# Modo: variant
# ---------------------------------------------------------------------------

def cmd_variant():
    arch = sys.argv[2] if len(sys.argv) > 2 else ""

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
    print(f"INFO: {len(pasan)} variantes pasan filtro arch='{arch}'", file=sys.stderr)

    if not pasan:
        print(f"ERROR: ninguna variante sirve para arch='{arch}'", file=sys.stderr)
        sys.exit(1)

    mejor = _elegir_mejor(pasan)
    if not mejor:
        print("ERROR: no se pudo elegir variante", file=sys.stderr)
        sys.exit(1)

    print(
        f"INFO: elegida {mejor['tipo']} arch={mejor['arch']} "
        f"dpi={mejor['dpi']} splits={mejor['splits']} vc={mejor['vc']}",
        file=sys.stderr,
    )

    print(mejor["url"])


# ---------------------------------------------------------------------------
# Modo: download
# ---------------------------------------------------------------------------

def _extract_download_url(html: str):
    # Nivel 1: cualquier <a> con "downloadButton" en class y href (sin importar orden)
    for attrs in re.findall(r'<a\b([^>]*)>', html):
        if "downloadButton" not in attrs:
            continue
        m = re.search(r'href="([^"]+)"', attrs)
        if m:
            return _abs_url(_unescape(m.group(1)))

    # Nivel 2: cualquier href a /download/?key=
    m = re.search(r'href="([^"]*/download/\?key=[^"]+)"', html)
    if m:
        return _abs_url(_unescape(m.group(1)))

    # Nivel 3: cualquier href con ?key=
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
    # Nivel 1: cualquier <a> con id="download-link" y href (sin importar orden)
    for attrs in re.findall(r'<a\b([^>]*)>', html):
        if 'id="download-link"' not in attrs:
            continue
        m = re.search(r'href="([^"]+)"', attrs)
        if m:
            return _abs_url(_unescape(m.group(1)))

    # Nivel 2: cualquier href a download.php?id=
    m = re.search(r'href="([^"]*download\.php\?id=[^"]+)"', html)
    if m:
        return _abs_url(_unescape(m.group(1)))

    # Nivel 3: cualquier href a /wp-content/themes/APKMirror/
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
# Modo: uploads (página base → URL de uploads)
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
# Modo: list (página uploads → versiones con sus hrefs)
# ---------------------------------------------------------------------------

def cmd_list():
    """
    Devuelve líneas con formato: version<TAB>href_absoluto
    Enfoque de dos pasadas: no depende del orden de atributos en el <a>.
    """
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

    # Pasada 1: capturar TODOS los <a>...</a> con sus atributos y texto
    all_anchors = re.findall(r'<a\b([^>]*)>(.*?)</a>', content, re.DOTALL)
    print(f"DEBUG: {len(all_anchors)} anchors totales", file=sys.stderr)

    seen = set()
    out = []
    for attrs, text in all_anchors:
        # Pasada 2a: filtrar por class="fontBlack" (en cualquier posición)
        if "fontBlack" not in attrs:
            continue
        # Pasada 2b: extraer href que termine en -release/
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
        m2 = re.search(r'(\d+\.\d+.*)$', clean)
        ver = m2.group(1).strip() if m2 else clean.split()[-1]
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
# Modo: vers (legacy, sin hrefs)
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
        m2 = re.search(r'(\d+\.\d+.*)$', clean)
        ver = m2.group(1).strip() if m2 else clean.split()[-1]
        if ver and ver not in seen:
            seen.add(ver)
            versions.append(ver)

    if versions:
        print("\n".join(versions))
        sys.exit(0)
    sys.exit(1)

# ---------------------------------------------------------------------------
# Modo: next (página uploads → URL de la página siguiente)
# ---------------------------------------------------------------------------

def cmd_next():
    """
    Busca en el HTML de uploads el enlace real a la página siguiente.
    Devuelve la URL absoluta, o falla si no hay más páginas.
    """
    html = sys.stdin.read()
    if not html:
        print("ERROR: HTML vacío en stdin", file=sys.stderr)
        sys.exit(1)

    patterns = [
        r'href="([^"]*uploads/\?appcategory=[^"]*(?:page|paged)=\d+[^"]*)"',
        r'class="[^"]*(?:next|pagination-next|page-numbers next)[^"]*"[^>]*href="([^"]+)"',
        r'href="([^"]*uploads/[^"]*(?:page|paged)=\d+[^"]*)"',
        r'rel="next"[^>]*href="([^"]+)"',
    ]

    for pat in patterns:
        m = re.search(pat, html)
        if m:
            url = _abs_url(_unescape(m.group(1)))
            print(f"INFO: siguiente página: {url}", file=sys.stderr)
            print(url)
            sys.exit(0)

    print("INFO: no hay más páginas", file=sys.stderr)
    sys.exit(1)

# ---------------------------------------------------------------------------
# Modo: pkg (página base)
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
    elif modo == "pkg":
        cmd_pkg()
    else:
        print(f"ERROR: modo desconocido '{modo}'", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()