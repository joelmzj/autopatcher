#!/usr/bin/env python3
import sys
import os

try:
    from curl_cffi import requests
except ImportError:
    # Exit 2: curl_cffi not installed, caller should fall back to curl/solver
    sys.exit(2)


def is_challenge(status_code: int, text: str, headers: dict = None) -> bool:
    if status_code in (403, 503):
        return True
    if headers and "cf-mitigated" in headers:
        return True
    lower = (text or "").lower()
    return any(phrase in lower for phrase in (
        "just a moment...",
        "attention required!",
        "please wait... | cloudflare",
        "verify you are human",
        "turnstile",
        "challenges.cloudflare.com",
    ))


def get_impersonate_targets() -> list:
    targets = []
    BrowserType = None
    for module_name in (
        "curl_cffi.requests",
        "curl_cffi.requests.session",
        "curl_cffi.requests.impersonate",
        "curl_cffi",
    ):
        try:
            mod = __import__(module_name, fromlist=["BrowserType"])
            bt = getattr(mod, "BrowserType", None)
            if bt:
                BrowserType = bt
                break
        except Exception:
            continue

    if BrowserType:
        try:
            import re
            members = [m.value for m in BrowserType if hasattr(m, "value")]

            def sort_key(name: str):
                m_num = re.search(r"\d+", str(name))
                ver = int(m_num.group(0)) if m_num else 0
                name_str = str(name).lower()
                if "chrome" in name_str and "android" not in name_str:
                    return (3, ver)
                elif "safari" in name_str:
                    return (2, ver)
                elif "edge" in name_str:
                    return (1, ver)
                return (0, ver)

            sorted_members = sorted(members, key=sort_key, reverse=True)
            for t in sorted_members:
                if t not in targets:
                    targets.append(t)
        except Exception:
            pass

    if "chrome" not in targets:
        targets.insert(0, "chrome")
    if "safari" not in targets:
        targets.append("safari")

    return targets[:8]


def load_cookies(session, cookie_file: str):
    if not cookie_file or not os.path.isfile(cookie_file):
        return
    try:
        with open(cookie_file, "r", encoding="utf-8", errors="ignore") as f:
            for line in f:
                parts = line.strip().split("\t")
                if len(parts) >= 7 and not line.startswith("#"):
                    session.cookies.set(
                        parts[5], parts[6], domain=parts[0], path=parts[2])
    except Exception:
        pass

    temp_dir = os.path.dirname(os.path.abspath(cookie_file))
    ua_path = os.path.join(temp_dir, "cf_ua.txt")
    if os.path.isfile(ua_path):
        try:
            with open(ua_path, "r", encoding="utf-8", errors="ignore") as f:
                ua = f.read().strip()
                if ua:
                    session.headers["User-Agent"] = ua
        except Exception:
            pass


def save_cookies(session, cookie_file: str, user_agent: str = ""):
    if not cookie_file:
        return
    try:
        temp_dir = os.path.dirname(os.path.abspath(cookie_file))
        os.makedirs(temp_dir, exist_ok=True)
        jar = getattr(session.cookies, "jar", None)
        with open(cookie_file, "w", encoding="utf-8") as f:
            f.write("# Netscape HTTP Cookie File\n")
            if jar is not None:
                for c in jar:
                    domain = getattr(c, "domain", "") or ""
                    path = getattr(c, "path", "/") or "/"
                    secure = "TRUE" if getattr(c, "secure", False) else "FALSE"
                    expires = str(int(getattr(c, "expires", 0) or 0))
                    name = getattr(c, "name", "")
                    val = getattr(c, "value", "")
                    f.write(
                        f"{domain}\tTRUE\t{path}\t{secure}\t{expires}\t{name}\t{val}\n")
            elif hasattr(session.cookies, "items"):
                for name, val in session.cookies.items():
                    f.write(f"\tTRUE\t/\tFALSE\t0\t{name}\t{val}\n")

        if user_agent:
            with open(os.path.join(temp_dir, "cf_ua.txt"), "w", encoding="utf-8") as f:
                f.write(user_agent)

    except Exception:
        pass


def effective_url(resp, fallback: str) -> str:
    try:
        u = str(getattr(resp, "url", "") or "")
    except Exception:
        u = ""
    return u or fallback


# ==============================================================================
# 🔧 FIX B1: solve_challenge con POST /cookies primero (API real de sarperavci)
# ------------------------------------------------------------------------------
# Problema anterior: solo usaba GET contra /cookies. Si el solver expone
# /cookies como POST (que es lo estándar), el GET devuelve 404 y la función
# fallaba silenciosamente → el solve_challenge "no hacía nada" en el log.
#
# Cambios:
#   1. POST /cookies primero, GET como fallback por compatibilidad
#   2. Timeout 120s (antes 60s, corto para download.php)
#   3. Acepta respuesta {cookies: {...}, user_agent: "..."} Y dict plano
#   4. Log de cada intento (antes: silencio total)
# ==============================================================================
def solve_challenge(url: str, session) -> tuple[bool, str]:
    import urllib.parse

    solver_url = os.getenv("CF_SOLVER_URL", "http://localhost:8000").rstrip("/")

    attempts = [
        ("POST /cookies", lambda: requests.post(
            f"{solver_url}/cookies",
            json={"url": url},
            timeout=120,
        )),
        ("GET /cookies", lambda: requests.get(
            f"{solver_url}/cookies",
            params={"url": url},
            timeout=120,
        )),
    ]

    for name, call in attempts:
        try:
            sys.stderr.write(f"[cf_get] solver intento: {name}\n")
            resp = call()
            if resp.status_code != 200:
                sys.stderr.write(
                    f"[cf_get] {name} → HTTP {resp.status_code}: "
                    f"{(resp.text or '')[:120]}\n")
                continue

            data = {}
            try:
                data = resp.json()
            except Exception:
                pass

            # Algunos solvers devuelven {cookies: {...}, user_agent: "..."}
            # Otros devuelven directamente un dict plano de cookies
            cookies = data.get("cookies") if isinstance(data, dict) else None
            if cookies is None and isinstance(data, dict) and data:
                cookies = data

            user_agent = (
                data.get("user_agent") if isinstance(data, dict) else ""
            ) or ""

            parsed_host = urllib.parse.urlparse(url).hostname or ""
            parts = parsed_host.split(".")
            default_domain = (
                f".{'.'.join(parts[-2:])}" if len(parts) >= 2 else parsed_host)

            if isinstance(cookies, dict) and cookies:
                for k, v in cookies.items():
                    session.cookies.set(k, v, domain=default_domain)
            elif isinstance(cookies, list) and cookies:
                for c in cookies:
                    if isinstance(c, dict) and "name" in c and "value" in c:
                        session.cookies.set(
                            c["name"], c["value"],
                            domain=c.get("domain") or default_domain,
                            path=c.get("path", "/"))
            else:
                sys.stderr.write(
                    f"[cf_get] {name} → 200 pero sin cookies: "
                    f"{str(data)[:120]}\n")
                continue

            if user_agent:
                session.headers["User-Agent"] = user_agent

            sys.stderr.write(
                f"[cf_get] {name} → OK ({len(session.cookies)} cookies)\n")
            return True, user_agent

        except Exception as e:
            sys.stderr.write(
                f"[cf_get] {name} excepción: {type(e).__name__}: {e}\n")
            continue

    sys.stderr.write("[cf_get] solver: todos los intentos fallaron\n")
    return False, ""


def write_source_note(cookie_file: str, note: str):
    if not cookie_file:
        return
    try:
        temp_dir = os.path.dirname(os.path.abspath(cookie_file))
        with open(os.path.join(temp_dir, "cf_source.txt"), "w", encoding="utf-8") as f:
            f.write(note)
    except Exception:
        pass


# ==============================================================================
# 🔧 FIX B3 (bonus): fetch_from_solver_html con POST /html primero
# ------------------------------------------------------------------------------
# Mismo patrón que B1. El endpoint /html también soporta POST con body JSON
# {url, method}. Si el solver usa POST-only, el GET anterior daba 404/405.
# ==============================================================================
def fetch_from_solver_html(url: str) -> tuple[str | None, str]:
    solver_url = os.getenv("CF_SOLVER_URL", "http://localhost:8000").rstrip("/")

    attempts = [
        ("POST /html", lambda: requests.post(
            f"{solver_url}/html",
            json={"url": url, "method": "GET"},
            timeout=120,
        )),
        ("GET /html", lambda: requests.get(
            f"{solver_url}/html",
            params={"url": url},
            timeout=120,
        )),
    ]

    for name, call in attempts:
        try:
            resp = call()
        except Exception as e:
            sys.stderr.write(f"[cf_get] solver {name} failed for {url}: {e}\n")
            continue

        if resp.status_code == 200 and resp.text and not is_challenge(
                resp.status_code, resp.text, getattr(resp, "headers", None)):
            return resp.text, str(resp.headers.get("x-cf-bypasser-final-url") or url)

        sys.stderr.write(
            f"[cf_get] solver {name} gave no usable page for {url} "
            f"(status {resp.status_code}, {len(resp.text or '')} chars)\n")

    return None, ""


# ==============================================================================
# 🔧 FIX B2: download_file con multi-impersonate target
# ------------------------------------------------------------------------------
# Problema anterior: solo probaba "chrome". Si APKMirror bloquea Chrome
# específicamente en download.php (mientras /uploads/ sí pasa), la descarga
# fallaba siempre. El path HTML ya probaba 8 targets, pero la descarga no.
#
# Cambios:
#   1. Itera get_impersonate_targets() (8 targets) en lugar de solo chrome
#   2. Por cada target: directo → si 403, solver → si sigue 403, siguiente
#   3. Valida que la descarga no sea HTML disfrazado (antes solo validaba 200)
#   4. Limpia .part en cada fallo (antes podía quedar basura)
#   5. Log de cada target (antes: solo un mensaje si todo fallaba)
# ==============================================================================
def download_file(url: str, dest_path: str, referer: str = "",
                  cookie_file: str = "") -> bool:
    os.makedirs(os.path.dirname(os.path.abspath(dest_path)), exist_ok=True)
    temp_dest = f"{dest_path}.part"

    # Asegurar chrome primero (es el que funcionó históricamente)
    targets = get_impersonate_targets()
    if "chrome" in targets:
        targets.remove("chrome")
        targets.insert(0, "chrome")

    headers_base = {}
    if referer:
        headers_base["Referer"] = referer

    for target in targets:
        sys.stderr.write(f"[cf_get] download: probando impersonate={target}\n")

        s = requests.Session(impersonate=target)
        load_cookies(s, cookie_file)

        try:
            resp = s.get(url, headers=headers_base, timeout=(15, 600),
                         stream=True, allow_redirects=True)

            # Si 403/503, intentar solver
            if resp.status_code in (403, 503):
                sys.stderr.write(
                    f"[cf_get] {target} → HTTP {resp.status_code}, "
                    f"intentando solver\n")
                solved, ua = solve_challenge(url, s)
                if solved:
                    save_cookies(s, cookie_file, ua)
                    resp = s.get(url, headers=headers_base,
                                 timeout=(15, 600), stream=True,
                                 allow_redirects=True)
                    sys.stderr.write(
                        f"[cf_get] {target} post-solver → "
                        f"HTTP {resp.status_code}\n")

            if resp.status_code != 200:
                sys.stderr.write(
                    f"[cf_get] {target} → HTTP {resp.status_code}, "
                    f"siguiente target\n")
                if os.path.isfile(temp_dest):
                    try:
                        os.remove(temp_dest)
                    except Exception:
                        pass
                continue

            # Descargar a .part
            with open(temp_dest, "wb") as f:
                for chunk in resp.iter_content(chunk_size=1048576):
                    if chunk:
                        f.write(chunk)

            # Validar tamaño mínimo (evita HTML de error pequeño)
            size = os.path.getsize(temp_dest)
            if size < 1024 * 1024:
                sys.stderr.write(
                    f"[cf_get] {target} → archivo muy pequeño "
                    f"({size} bytes), descartado\n")
                os.remove(temp_dest)
                continue

            # Validar que no sea HTML disfrazado
            with open(temp_dest, "rb") as f:
                head = f.read(64).lstrip()
                if head[:1] == b"<":
                    sys.stderr.write(
                        f"[cf_get] {target} → el archivo es HTML "
                        f"(bloqueo disfrazado), descartado\n")
                    os.remove(temp_dest)
                    continue

            # Mover a destino final
            if os.path.isfile(dest_path):
                os.remove(dest_path)
            os.rename(temp_dest, dest_path)
            save_cookies(s, cookie_file)
            sys.stderr.write(
                f"[cf_get] {target} → descarga OK ({size} bytes)\n")
            return True

        except Exception as e:
            sys.stderr.write(
                f"[cf_get] {target} excepción: {type(e).__name__}: {e}\n")
            if os.path.isfile(temp_dest):
                try:
                    os.remove(temp_dest)
                except Exception:
                    pass
            continue

    sys.stderr.write(
        f"[cf_get] todos los targets fallaron ({len(targets)} intentos)\n")
    return False


def main():
    if len(sys.argv) < 2:
        sys.exit(2)

    if sys.argv[1] == "download":
        if len(sys.argv) < 4:
            sys.exit(2)
        dl_url = sys.argv[2]
        dest = sys.argv[3]
        referer = sys.argv[4] if len(sys.argv) > 4 else ""
        cookie_file = sys.argv[5] if len(sys.argv) > 5 else ""
        success = download_file(dl_url, dest, referer, cookie_file)
        sys.exit(0 if success else 1)

    url = sys.argv[1]
    cookie_file = sys.argv[2] if len(sys.argv) > 2 else ""

    impersonate_targets = get_impersonate_targets()

    for imp in impersonate_targets:
        try:
            s = requests.Session(impersonate=imp)
            load_cookies(s, cookie_file)

            resp = s.get(url, timeout=15, allow_redirects=True)
            if is_challenge(resp.status_code, resp.text, getattr(resp, "headers", None)):
                solved, ua = solve_challenge(effective_url(resp, url), s)
                if solved:
                    save_cookies(s, cookie_file, ua)
                    resp = s.get(url, timeout=15, allow_redirects=True)
                    if not is_challenge(resp.status_code, resp.text, getattr(resp, "headers", None)) and resp.status_code == 200:
                        write_source_note(cookie_file, "curl_cffi")
                        sys.stdout.write(resp.text)
                        sys.exit(0)

                solver_html, solver_final = fetch_from_solver_html(
                    effective_url(resp, url))
                if solver_html:
                    write_source_note(
                        cookie_file, f"solver_html {solver_final}")
                    sys.stdout.write(solver_html)
                    sys.exit(0)

                continue

            if resp.status_code == 200 and resp.text:
                save_cookies(s, cookie_file)
                write_source_note(cookie_file, "curl_cffi")
                sys.stdout.write(resp.text)
                sys.exit(0)
            else:
                continue
        except Exception:
            continue

    solver_html, solver_final = fetch_from_solver_html(url)
    if solver_html:
        write_source_note(cookie_file, f"solver_html {solver_final}")
        sys.stdout.write(solver_html)
        sys.exit(0)

    sys.exit(1)


if __name__ == "__main__":
    main()