"""Read/write MAKING env files under env/ and var.env (dashboard only)."""
from __future__ import annotations

import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ENV_DIR = ROOT / "env"
FILENAME_RE = re.compile(r"^[a-zA-Z0-9][a-zA-Z0-9._-]*\.env$")
ENV_REL_RE = re.compile(r"^(var\.env|env/[a-zA-Z0-9][a-zA-Z0-9._-]*\.env)$")

REQUIRED_KEYS = [
    "RUN_TAG",
    "SYMBOL",
    "PERIOD",
    "METHOD",
    "EMA_TIMEFRAME",
    "BUY_MAGIC",
    "SELL_MAGIC",
    "PRIMARY_VOLUME",
    "PRIMARY_VOLUME_MIN",
    "PRIMARY_VOLUME_MAX",
    "COMMENT",
    "LOOP_SLEEP",
    "PRICE_EPS",
    "POINTS_PROFIT_MIN",
    "RETRY_DELAY",
    "GAP",
    "BASKET_PCT",
    "MAX_LEVEL",
    "PLACE_COOLDOWN",
    "GRID_PRICE_EPS",
    "TC_LOOP_SLEEP",
    "TC_GRID_ARM_LOSS_PTS",
    "TC_BUY_TARGETBASKET",
    "TC_SELL_TARGETBASKET",
    "MT5_HOST",
    "MT5_PORT",
    "API_KEY",
    "MT5_CURL_MAX",
    "MT5_CMD",
]

OPTIONAL_KEYS = [
    "EMA_CANDLE_COUNT",
    "EMA_BARS_MULT",
    "MT5_CONNECT_TIMEOUT",
    "LOG_DIR",
    "PID_DIR",
    "LOG_CLEAN_EVERY_HOURS",
    "PSW_COMMENT",
    "PSW_TP_POINTS",
    "PSW_ACK_ORDER_TYPE",
    "PSW_ACK_VOLUME",
    "PSW_ACK_VOL_EPS",
    "PSW_VOLUME",
    "TC_ANCHOR_COMMENTS",
    "PSW_ACK_POLL_SLEEP",
    "PSW_STATE_FILE",
]

KEY_HELP: dict[str, str] = {
    "RUN_TAG": "Log/PID folder name (unique per stack)",
    "SYMBOL": "MT5 symbol",
    "BUY_MAGIC": "Unique vs other stacks",
    "SELL_MAGIC": "Unique vs other stacks",
}


def normalize_env_rel(rel: str) -> str:
    rel = (rel or "").strip().replace("\\", "/").lstrip("./")
    if not ENV_REL_RE.match(rel):
        raise ValueError(f"invalid env path: {rel}")
    return rel


def env_path(rel: str) -> Path:
    rel = normalize_env_rel(rel)
    path = (ROOT / rel).resolve()
    if not str(path).startswith(str(ROOT.resolve())):
        raise ValueError("path escape")
    return path


def list_env_files() -> list[str]:
    out: list[str] = []
    if (ROOT / "var.env").is_file():
        out.append("var.env")
    if ENV_DIR.is_dir():
        for p in sorted(ENV_DIR.glob("*.env")):
            if p.name.startswith("_"):
                continue
            out.append(f"env/{p.name}")
    return out


def is_deletable(rel: str) -> bool:
    rel = normalize_env_rel(rel)
    return rel.startswith("env/")


def parse_env_vars(content: str) -> dict[str, str]:
    out: dict[str, str] = {}
    for line in content.splitlines():
        s = line.strip()
        if not s or s.startswith("#") or "=" not in s:
            continue
        key, _, val = s.partition("=")
        key = key.strip()
        if re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", key):
            out[key] = val.strip().strip('"').strip("'")
    return out


def validate_content(content: str) -> list[str]:
    vars_ = parse_env_vars(content)
    missing = [k for k in REQUIRED_KEYS if not vars_.get(k)]
    if vars_.get("RUN_TAG"):
        tag = vars_["RUN_TAG"]
        if not re.match(r"^[a-zA-Z0-9._-]+$", tag):
            missing.append("RUN_TAG(invalid)")
    run_tag = vars_.get("RUN_TAG", "TAG")
    if not vars_.get("EMA_CANDLE_COUNT") and not vars_.get("EMA_BARS_MULT"):
        pass  # load_env derives default
    if vars_.get("EMA_CANDLE_COUNT"):
        try:
            period = int(vars_.get("PERIOD", "0"))
            count = int(vars_["EMA_CANDLE_COUNT"])
            if count < period + 50:
                missing.append("EMA_CANDLE_COUNT(too low)")
        except ValueError:
            missing.append("EMA_CANDLE_COUNT(invalid)")
    if vars_.get("PSW_STATE_FILE") and "RUN_TAG" in vars_:
        if vars_["RUN_TAG"] not in vars_.get("PSW_STATE_FILE", ""):
            pass  # warn only in UI
    _ = run_tag
    return missing


def load_env_file(rel: str) -> dict:
    path = env_path(rel)
    if not path.is_file():
        raise FileNotFoundError(rel)
    content = path.read_text()
    return {
        "env_file": rel,
        "content": content,
        "vars": parse_env_vars(content),
        "deletable": is_deletable(rel),
        "missing": validate_content(content),
    }


def template_content(clone_from: str | None = None) -> str:
    src = env_path(clone_from) if clone_from else ROOT / "var.env"
    if not src.is_file():
        src = ROOT / "var.env"
    text = src.read_text()
    if not clone_from:
        text = re.sub(r"(?m)^(RUN_TAG=).*$", r"\1NEWSTACK", text)
        text = re.sub(r"(?m)^(SYMBOL=).*$", r"\1NEWSTACK", text)
        text = re.sub(
            r"(?m)^(PSW_STATE_FILE=).*$",
            r"\1./SWINGKING/zones/.psw_deployed_NEWSTACK",
            text,
        )
    return text


def new_env_filename(name: str) -> str:
    name = (name or "").strip()
    if "/" in name:
        name = name.rsplit("/", 1)[-1]
    if not name.endswith(".env"):
        name = f"{name}.env"
    if not FILENAME_RE.match(name):
        raise ValueError("filename must be like ETHUSD.env")
    return f"env/{name}"


def write_env_file(rel: str, content: str, *, create: bool = False) -> dict:
    rel = normalize_env_rel(rel)
    missing = validate_content(content)
    if missing:
        raise ValueError(f"missing or invalid: {', '.join(missing)}")
    path = env_path(rel)
    if create:
        if path.is_file():
            raise ValueError(f"already exists: {rel}")
        if not rel.startswith("env/"):
            raise ValueError("new stacks must be under env/")
    else:
        if not path.is_file():
            raise ValueError(f"not found: {rel}")
    path.parent.mkdir(parents=True, exist_ok=True)
    if not content.endswith("\n"):
        content += "\n"
    path.write_text(content)
    return load_env_file(rel)


def delete_env_file(rel: str, *, stop_workers: bool = True) -> dict:
    rel = normalize_env_rel(rel)
    if not is_deletable(rel):
        raise ValueError("cannot delete var.env from dashboard — edit only")
    path = env_path(rel)
    if not path.is_file():
        raise ValueError(f"not found: {rel}")
    log = []
    if stop_workers:
        proc = subprocess.run(
            [str(ROOT / "init.sh"), "-e", rel, "stop"],
            cwd=ROOT,
            capture_output=True,
            text=True,
            timeout=120,
        )
        log.append(proc.stdout + proc.stderr)
    path.unlink()
    return {"env_file": rel, "deleted": True, "stop_log": "".join(log)[-4000:]}


def schema_payload() -> dict:
    return {
        "required": REQUIRED_KEYS,
        "optional": OPTIONAL_KEYS,
        "help": KEY_HELP,
    }