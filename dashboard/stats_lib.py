"""Aggregate per-RUN_TAG stats from data/<RUN_TAG>/events.jsonl."""
from __future__ import annotations

import json
import subprocess
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import env_lib

ROOT = Path(__file__).resolve().parent.parent


def _parse_ts(ts: str) -> datetime:
    return datetime.strptime(ts, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)


def _load_events(run_tag: str) -> list[dict[str, Any]]:
    path = ROOT / "data" / run_tag / "events.jsonl"
    if not path.is_file():
        return []
    rows: list[dict[str, Any]] = []
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            rows.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    return rows


def _session_start_ts(events: list[dict]) -> str | None:
    for row in reversed(events):
        if row.get("type") == "session_start":
            return row.get("ts")
    return None


def _filter_range(events: list[dict], range_key: str) -> list[dict]:
    if range_key != "session":
        return events
    start = _session_start_ts(events)
    if not start:
        return events
    t0 = _parse_ts(start)
    return [e for e in events if _parse_ts(e["ts"]) >= t0]


def _mt5_floating_pnl(env_rel: str) -> float | None:
    path = env_lib.env_path(env_rel)
    if not path.is_file():
        return None
    vars_ = env_lib.parse_env_vars(path.read_text())
    sym = vars_.get("SYMBOL")
    if not sym:
        return None
    out = subprocess.run(
        [str(ROOT / "mt5"), "get_pnl", sym],
        cwd=ROOT,
        capture_output=True,
        text=True,
        timeout=45,
        env={**dict(__import__("os").environ), "ENV_FILE": str(path)},
    )
    if out.returncode != 0:
        return None
    try:
        data = json.loads(out.stdout)
    except json.JSONDecodeError:
        return None
    if not data.get("ok"):
        return None
    buys = {str(vars_.get("BUY_MAGIC", ""))}
    sells = {str(vars_.get("SELL_MAGIC", ""))}
    magics = buys | sells
    total = 0.0
    for p in data.get("positions") or []:
        if str(p.get("magic")) not in magics:
            continue
        try:
            total += float(p.get("profit") or 0)
        except (TypeError, ValueError):
            pass
    return round(total, 2)


def aggregate(run_tag: str, range_key: str = "session") -> dict[str, Any]:
    range_key = range_key if range_key in ("session", "all") else "session"
    all_events = _load_events(run_tag)
    events = _filter_range(all_events, range_key)
    session_from = _session_start_ts(all_events) if range_key == "session" else None

    counters = {
        "orders_created": 0,
        "baskets_closed": 0,
        "buy_closed": 0,
        "sell_closed": 0,
        "realized_pnl": 0.0,
    }
    pnl_series: list[dict[str, Any]] = []
    cum = 0.0
    if events:
        pnl_series.append({"ts": events[0]["ts"], "realized_cum": 0.0, "floating": None})

    for e in events:
        et = e.get("type")
        if et == "order_created":
            counters["orders_created"] += 1
        elif et == "basket_closed":
            counters["baskets_closed"] += 1
            try:
                delta = float(e.get("pnl_delta") or 0)
            except (TypeError, ValueError):
                delta = 0.0
            counters["realized_pnl"] += delta
            cum += delta
            counters["buy_closed"] += int(e.get("buy_closed") or 0)
            counters["sell_closed"] += int(e.get("sell_closed") or 0)
            pnl_series.append(
                {
                    "ts": e["ts"],
                    "realized_cum": round(cum, 2),
                    "floating": None,
                    "event": "basket_closed",
                }
            )
        elif et == "pnl_sample":
            try:
                fl = float(e.get("floating_pnl") or 0)
            except (TypeError, ValueError):
                fl = None
            pnl_series.append(
                {
                    "ts": e["ts"],
                    "realized_cum": round(cum, 2),
                    "floating": fl,
                    "total_est": round(cum + (fl or 0), 2) if fl is not None else None,
                }
            )

    counters["realized_pnl"] = round(counters["realized_pnl"], 2)

    env_rel = None
    for ef in env_lib.list_env_files():
        try:
            info = env_lib.load_env_file(ef)
            if info["vars"].get("RUN_TAG") == run_tag:
                env_rel = ef
                break
        except (FileNotFoundError, ValueError):
            continue
    floating = _mt5_floating_pnl(env_rel) if env_rel else None
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    total_pnl = counters["realized_pnl"] + (floating or 0)
    pnl_series.append(
        {
            "ts": now,
            "realized_cum": counters["realized_pnl"],
            "floating": floating,
            "total_est": round(total_pnl, 2) if floating is not None else counters["realized_pnl"],
            "event": "live",
        }
    )

    return {
        "run_tag": run_tag,
        "range": range_key,
        "session_from": session_from,
        "counters": counters,
        "current_floating_pnl": floating,
        "total_pnl_est": round(total_pnl, 2) if floating is not None else counters["realized_pnl"],
        "pnl_series": pnl_series[-200:],
        "has_data": len(events) > 0,
    }


def sample_all_stacks() -> None:
    for ef in env_lib.list_env_files():
        try:
            info = env_lib.load_env_file(ef)
            tag = info["vars"].get("RUN_TAG")
            if not tag:
                continue
            fl = _mt5_floating_pnl(ef)
            if fl is None:
                continue
            path = ROOT / "data" / tag / "events.jsonl"
            path.parent.mkdir(parents=True, exist_ok=True)
            row = {
                "ts": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                "run_tag": tag,
                "type": "pnl_sample",
                "floating_pnl": fl,
            }
            with path.open("a", encoding="utf-8") as fp:
                fp.write(json.dumps(row, separators=(",", ":")) + "\n")
        except Exception:
            continue