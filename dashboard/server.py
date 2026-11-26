#!/usr/bin/env python3
"""MAKING worker dashboard — serves UI + JSON API (run on EC2; nginx /making/ → here)."""
from __future__ import annotations

import base64
import hashlib
import hmac
import json
import os
import re
import subprocess
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from http.cookies import SimpleCookie
from pathlib import Path
from urllib.parse import parse_qs, urlparse

import env_lib
import stats_lib
import threading

ROOT = Path(os.environ.get("MAKING_ROOT", Path(__file__).resolve().parent.parent)).resolve()
STATIC = Path(__file__).resolve().parent / "static"
STATIC_VER_FILE = Path(__file__).resolve().parent / "STATIC_VER"
CONFIG = Path(__file__).resolve().parent / "dashboard.env"
BASE_PATH = os.environ.get("DASHBOARD_BASE_PATH", "/making").rstrip("/") or "/making"
SESSION_COOKIE = "making_session"
SESSION_DAYS = 14

ENV_FILE_RE = re.compile(r"^[a-zA-Z0-9._/-]+\.env$")


def static_version() -> str:
    if STATIC_VER_FILE.is_file():
        return STATIC_VER_FILE.read_text().strip() or "1"
    return os.environ.get("STATIC_V", "1")


def inject_static_version(html: str) -> str:
    return html.replace("{{STATIC_V}}", static_version())


def static_cache_headers() -> list[tuple[str, str]]:
    return [
        ("Cache-Control", "no-store, no-cache, must-revalidate"),
        ("Pragma", "no-cache"),
    ]


def load_config() -> dict[str, str]:
    cfg = {
        "BIND": "127.0.0.1",
        "PORT": "8877",
        "DASHBOARD_PASSWORD": "alphafx",
    }
    if CONFIG.is_file():
        for line in CONFIG.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            cfg[k.strip()] = v.strip()
    for k in list(cfg.keys()):
        if k in os.environ and os.environ[k]:
            cfg[k] = os.environ[k]
    # Legacy env files
    if not cfg.get("DASHBOARD_PASSWORD") and cfg.get("DASHBOARD_TOKEN"):
        cfg["DASHBOARD_PASSWORD"] = cfg["DASHBOARD_TOKEN"]
    return cfg


def cookie_path() -> str:
    return BASE_PATH if BASE_PATH.startswith("/") else f"/{BASE_PATH}"


def _session_key(cfg: dict[str, str]) -> bytes:
    secret = cfg.get("DASHBOARD_PASSWORD") or "alphafx"
    return hashlib.sha256(secret.encode()).digest()


def make_session_token(cfg: dict[str, str]) -> str:
    exp = int(time.time()) + SESSION_DAYS * 86400
    payload = str(exp).encode()
    sig = hmac.new(_session_key(cfg), payload, hashlib.sha256).digest()
    raw = base64.urlsafe_b64encode(payload + b"." + sig).decode().rstrip("=")
    return raw


def verify_session_token(token: str, cfg: dict[str, str]) -> bool:
    if not token:
        return False
    pad = "=" * (-len(token) % 4)
    try:
        raw = base64.urlsafe_b64decode(token + pad)
        exp_b, sig = raw.split(b".", 1)
        exp = int(exp_b.decode())
    except (ValueError, UnicodeDecodeError):
        return False
    if time.time() > exp:
        return False
    expected = hmac.new(_session_key(cfg), exp_b, hashlib.sha256).digest()
    return hmac.compare_digest(sig, expected)


def get_session_cookie(headers) -> str:
    raw = headers.get("Cookie", "")
    if not raw:
        return ""
    jar = SimpleCookie()
    jar.load(raw)
    if SESSION_COOKIE in jar:
        return jar[SESSION_COOKIE].value
    return ""


def is_logged_in(headers, cfg: dict[str, str]) -> bool:
    pwd = cfg.get("DASHBOARD_PASSWORD") or ""
    if not pwd:
        return True
    return verify_session_token(get_session_cookie(headers), cfg)


def check_password(password: str, cfg: dict[str, str]) -> bool:
    expected = cfg.get("DASHBOARD_PASSWORD") or ""
    if not expected:
        return True
    return hmac.compare_digest(password, expected)


def run_init_json() -> dict:
    proc = subprocess.run(
        [str(ROOT / "init.sh"), "ps", "--all", "--json"],
        cwd=ROOT,
        capture_output=True,
        text=True,
        timeout=120,
        check=False,
    )
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr or proc.stdout or f"init ps failed ({proc.returncode})")
    return json.loads(proc.stdout)


def allowed_env_files() -> set[str]:
    return set(env_lib.list_env_files())


def run_stack_action(env_file: str, action: str, skip_primary: bool) -> dict:
    env_lib.normalize_env_rel(env_file)
    if env_file not in allowed_env_files():
        raise ValueError(f"env not allowed: {env_file}")
    if action not in ("start", "stop", "restart"):
        raise ValueError(f"unknown action: {action}")
    env = os.environ.copy()
    if skip_primary:
        env["INIT_SKIP_PRIMARY"] = "1"
    proc = subprocess.run(
        [str(ROOT / "init.sh"), "-e", env_file, action],
        cwd=ROOT,
        capture_output=True,
        text=True,
        timeout=600,
        env=env,
        check=False,
    )
    return {
        "ok": proc.returncode == 0,
        "exit_code": proc.returncode,
        "stdout": proc.stdout[-12000:] if proc.stdout else "",
        "stderr": proc.stderr[-12000:] if proc.stderr else "",
    }


class Handler(BaseHTTPRequestHandler):
    server_version = "MakingDashboard/1.0"
    cfg: dict[str, str] = {}

    def log_message(self, fmt: str, *args) -> None:
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

    def _path_under_base(self) -> str:
        p = urlparse(self.path).path
        if BASE_PATH != "/" and p.startswith(BASE_PATH):
            rest = p[len(BASE_PATH) :] or "/"
            return rest if rest.startswith("/") else "/" + rest
        return p

    def _send_json(self, code: int, body: dict, extra_headers: list[tuple[str, str]] | None = None) -> None:
        raw = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(raw)))
        if extra_headers:
            for k, v in extra_headers:
                self.send_header(k, v)
        self.end_headers()
        self.wfile.write(raw)

    def _send_bytes(
        self, code: int, data: bytes, content_type: str, extra_headers: list[tuple[str, str]] | None = None
    ) -> None:
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        if extra_headers:
            for k, v in extra_headers:
                self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)

    def _set_session_cookie(self) -> str:
        token = make_session_token(self.cfg)
        path = cookie_path()
        return f"{SESSION_COOKIE}={token}; Path={path}; HttpOnly; SameSite=Lax; Max-Age={SESSION_DAYS * 86400}"

    def _clear_session_cookie(self) -> str:
        path = cookie_path()
        return f"{SESSION_COOKIE}=; Path={path}; HttpOnly; SameSite=Lax; Max-Age=0"

    def _require_login(self) -> bool:
        if is_logged_in(self.headers, self.cfg):
            return True
        self._send_json(401, {"ok": False, "error": "login_required"})
        return False

    def _read_json_body(self) -> dict:
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length) if length else b"{}"
        try:
            return json.loads(raw.decode() or "{}")
        except json.JSONDecodeError:
            return {}

    def do_GET(self) -> None:
        sub = self._path_under_base()
        if sub in ("/login", "/login.html"):
            body = inject_static_version((STATIC / "login.html").read_text(encoding="utf-8"))
            self._send_bytes(
                200, body.encode("utf-8"), "text/html; charset=utf-8", extra_headers=static_cache_headers()
            )
            return
        if sub in ("/", "/index.html"):
            if not is_logged_in(self.headers, self.cfg) and (self.cfg.get("DASHBOARD_PASSWORD")):
                self.send_response(302)
                self.send_header("Location", f"{cookie_path()}/login")
                self.end_headers()
                return
            body = inject_static_version((STATIC / "index.html").read_text(encoding="utf-8"))
            self._send_bytes(
                200, body.encode("utf-8"), "text/html; charset=utf-8", extra_headers=static_cache_headers()
            )
            return
        if sub.startswith("/static/"):
            rel = sub[len("/static/") :].split("?", 1)[0]
            if ".." in rel or rel.startswith("/"):
                self.send_error(404)
                return
            fp = STATIC / rel
            if not fp.is_file():
                self.send_error(404)
                return
            ct = "text/plain"
            if fp.suffix == ".css":
                ct = "text/css; charset=utf-8"
            elif fp.suffix == ".js":
                ct = "application/javascript; charset=utf-8"
            self._send_bytes(200, fp.read_bytes(), ct, extra_headers=static_cache_headers())
            return
        if sub == "/api/health":
            self._send_json(200, {"ok": True, "making_root": str(ROOT)})
            return
        if sub == "/api/session":
            self._send_json(200, {"ok": True, "logged_in": is_logged_in(self.headers, self.cfg)})
            return
        if sub == "/api/status":
            if not self._require_login():
                return
            try:
                data = run_init_json()
                self._send_json(200, {"ok": True, **data})
            except Exception as e:
                self._send_json(500, {"ok": False, "error": str(e)})
            return
        if sub == "/api/envs":
            if not self._require_login():
                return
            self._send_json(200, {"ok": True, "env_files": sorted(allowed_env_files())})
            return
        if sub == "/api/env/schema":
            if not self._require_login():
                return
            self._send_json(200, {"ok": True, **env_lib.schema_payload()})
            return
        if sub == "/api/env/template":
            if not self._require_login():
                return
            qs = parse_qs(urlparse(self.path).query)
            clone = (qs.get("clone") or [""])[0].strip() or None
            try:
                if clone:
                    env_lib.normalize_env_rel(clone)
                content = env_lib.template_content(clone)
                self._send_json(200, {"ok": True, "clone": clone, "content": content})
            except Exception as e:
                self._send_json(400, {"ok": False, "error": str(e)})
            return
        if sub == "/api/env/file":
            if not self._require_login():
                return
            qs = parse_qs(urlparse(self.path).query)
            rel = (qs.get("path") or qs.get("env_file") or [""])[0].strip()
            if not rel:
                self._send_json(400, {"ok": False, "error": "path required"})
                return
            try:
                data = env_lib.load_env_file(rel)
                self._send_json(200, {"ok": True, **data})
            except FileNotFoundError:
                self._send_json(404, {"ok": False, "error": "not found"})
            except Exception as e:
                self._send_json(400, {"ok": False, "error": str(e)})
            return
        if sub == "/api/stats":
            if not self._require_login():
                return
            qs = parse_qs(urlparse(self.path).query)
            run_tag = (qs.get("run_tag") or [""])[0].strip()
            range_key = (qs.get("range") or ["session"])[0].strip()
            if not run_tag:
                self._send_json(400, {"ok": False, "error": "run_tag required"})
                return
            try:
                data = stats_lib.aggregate(run_tag, range_key)
                self._send_json(200, {"ok": True, **data})
            except Exception as e:
                self._send_json(500, {"ok": False, "error": str(e)})
            return
        self.send_error(404)

    def do_POST(self) -> None:
        sub = self._path_under_base()
        if sub == "/api/login":
            body = self._read_json_body()
            password = (body.get("password") or "").strip()
            if not check_password(password, self.cfg):
                self._send_json(401, {"ok": False, "error": "wrong_password"})
                return
            self._send_json(200, {"ok": True}, extra_headers=[("Set-Cookie", self._set_session_cookie())])
            return
        if sub == "/api/logout":
            self._send_json(200, {"ok": True}, extra_headers=[("Set-Cookie", self._clear_session_cookie())])
            return
        if not self._require_login():
            return
        if sub == "/api/env/save":
            body = self._read_json_body()
            content = body.get("content")
            if content is None:
                self._send_json(400, {"ok": False, "error": "content required"})
                return
            create = bool(body.get("create"))
            try:
                if create:
                    fname = (body.get("filename") or body.get("env_file") or "").strip()
                    rel = env_lib.new_env_filename(fname)
                else:
                    rel = env_lib.normalize_env_rel((body.get("env_file") or "").strip())
                data = env_lib.write_env_file(rel, str(content), create=create)
                self._send_json(200, {"ok": True, **data})
            except ValueError as e:
                self._send_json(400, {"ok": False, "error": str(e)})
            except Exception as e:
                self._send_json(500, {"ok": False, "error": str(e)})
            return
        if sub == "/api/env/import":
            body = self._read_json_body()
            content = body.get("content")
            if not content:
                self._send_json(400, {"ok": False, "error": "content required"})
                return
            try:
                fname = (body.get("filename") or "").strip()
                if fname:
                    rel = env_lib.new_env_filename(fname)
                else:
                    vars_ = env_lib.parse_env_vars(str(content))
                    tag = vars_.get("RUN_TAG") or vars_.get("SYMBOL") or "STACK"
                    rel = env_lib.new_env_filename(f"{tag}.env")
                data = env_lib.write_env_file(rel, str(content), create=True)
                self._send_json(200, {"ok": True, **data})
            except ValueError as e:
                self._send_json(400, {"ok": False, "error": str(e)})
            return
        if sub == "/api/env/delete":
            body = self._read_json_body()
            rel = (body.get("env_file") or "").strip()
            stop = body.get("stop_workers", True)
            try:
                data = env_lib.delete_env_file(rel, stop_workers=bool(stop))
                self._send_json(200, {"ok": True, **data})
            except ValueError as e:
                self._send_json(400, {"ok": False, "error": str(e)})
            except Exception as e:
                self._send_json(500, {"ok": False, "error": str(e)})
            return
        if sub != "/api/control":
            self.send_error(404)
            return
        body = self._read_json_body()
        if not body:
            self._send_json(400, {"ok": False, "error": "invalid json"})
            return
        env_file = (body.get("env_file") or "").strip()
        action = (body.get("action") or "").strip()
        skip_primary = bool(body.get("skip_primary"))
        if not ENV_FILE_RE.match(env_file):
            self._send_json(400, {"ok": False, "error": "bad env_file"})
            return
        try:
            env_lib.normalize_env_rel(env_file)
            result = run_stack_action(env_file, action, skip_primary)
            self._send_json(200, {"ok": result["ok"], "result": result})
        except ValueError as e:
            self._send_json(400, {"ok": False, "error": str(e)})
        except Exception as e:
            self._send_json(500, {"ok": False, "error": str(e)})


def _stats_poller_loop(interval: int) -> None:
    while True:
        time.sleep(interval)
        try:
            stats_lib.sample_all_stacks()
        except Exception as exc:
            sys.stderr.write(f"stats poller: {exc}\n")


def main() -> None:
    cfg = load_config()
    Handler.cfg = cfg
    bind = cfg.get("BIND", "127.0.0.1")
    port = int(cfg.get("PORT", "8877"))
    poll = int(cfg.get("STATS_POLL_SEC", "60"))
    threading.Thread(target=_stats_poller_loop, args=(poll,), daemon=True).start()
    httpd = ThreadingHTTPServer((bind, port), Handler)
    print(f"MAKING dashboard on http://{bind}:{port}{BASE_PATH}/ (root {ROOT})", flush=True)
    if not cfg.get("DASHBOARD_PASSWORD"):
        print("WARN: DASHBOARD_PASSWORD unset — no login required", flush=True)
    httpd.serve_forever()


if __name__ == "__main__":
    main()