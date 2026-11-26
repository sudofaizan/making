"""Derive per-stack broker/worker health from recent worker log tails."""
from __future__ import annotations

import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TAIL_BYTES = 48_000
LOG_WORKERS = ("maintain_order", "TC_BUY", "TC_SELL", "swingking_ack")

_JSON_RE = re.compile(r"\{.*\}", re.DOTALL)


def _log_dir(run_tag: str) -> Path:
    return ROOT / "logs" / run_tag


def _tail(path: Path) -> str:
    if not path.is_file():
        return ""
    try:
        with path.open("rb") as f:
            f.seek(0, 2)
            size = f.tell()
            f.seek(max(0, size - TAIL_BYTES))
            return f.read().decode("utf-8", errors="replace")
    except OSError:
        return ""


def _combined_tail(run_tag: str) -> str:
    parts: list[str] = []
    base = _log_dir(run_tag)
    for name in LOG_WORKERS:
        text = _tail(base / f"{run_tag}_{name}.log")
        if text:
            parts.append(text)
    return "\n".join(parts)


def _parse_json_line(line: str) -> dict | None:
    m = _JSON_RE.search(line)
    if not m:
        return None
    try:
        return json.loads(m.group())
    except json.JSONDecodeError:
        return None


def _normalize_broker_message(comment: str, retcode: int | None) -> str:
    c = (comment or "").strip()
    if retcode == 10018 or "market closed" in c.lower():
        return "MARKET CLOSED"
    if c:
        return c.upper()
    if retcode is not None:
        return f"BROKER REJECT (retcode {retcode})"
    return "BROKER ERROR"


def _latest_broker_issue(text: str) -> dict | None:
    if not text:
        return None
    lines = text.splitlines()
    for line in reversed(lines[-400:]):
        if "broker: market closed" in line.lower():
            return {
                "kind": "broker",
                "code": 10018,
                "message": "MARKET CLOSED",
                "raw": line.strip()[:240],
            }
        if '"retcode"' in line or '"ok":false' in line.replace(" ", ""):
            payload = _parse_json_line(line)
            if not payload or payload.get("ok") is True:
                continue
            result = payload.get("result") if isinstance(payload.get("result"), dict) else {}
            retcode = result.get("retcode")
            if isinstance(retcode, str) and retcode.isdigit():
                retcode = int(retcode)
            comment = str(result.get("comment") or payload.get("error_message") or "")
            if retcode == 10018 or "market closed" in comment.lower():
                return {
                    "kind": "broker",
                    "code": retcode or 10018,
                    "message": "MARKET CLOSED",
                    "raw": line.strip()[:240],
                }
            if payload.get("ok") is False or result:
                return {
                    "kind": "broker",
                    "code": retcode,
                    "message": _normalize_broker_message(comment, retcode),
                    "raw": line.strip()[:240],
                }
        low = line.lower()
        if low.startswith("warn:") or "tick failed" in low or "error" in low:
            msg = line.strip()
            if len(msg) > 120:
                msg = msg[:117] + "..."
            return {"kind": "worker", "code": None, "message": msg, "raw": msg}
    return None


def stack_health(stack: dict) -> dict:
    """Returns {level, label, detail, broker?} for dashboard."""
    summary = stack.get("summary") or {}
    up = int(summary.get("up") or 0)
    exited = int(summary.get("exited") or 0)
    total = int(summary.get("total") or 0)
    run_tag = str(stack.get("run_tag") or "")

    if total > 0 and exited > 0:
        return {
            "level": "error",
            "label": f"ERROR: {exited} worker(s) exited",
            "detail": "See worker table",
        }
    if up == 0:
        return {"level": "muted", "label": "Stopped", "detail": ""}

    issue = _latest_broker_issue(_combined_tail(run_tag))
    if issue:
        msg = issue.get("message") or "BROKER ERROR"
        return {
            "level": "error",
            "label": f"ERROR: {msg}",
            "detail": issue.get("raw") or "",
            "broker": issue,
        }

    return {
        "level": "ok",
        "label": "Healthy — running",
        "detail": "Workers up; no recent broker error in logs",
    }


def enrich_stacks(stacks: list[dict]) -> list[dict]:
    out = []
    for stack in stacks:
        row = dict(stack)
        row["health"] = stack_health(stack)
        out.append(row)
    return out