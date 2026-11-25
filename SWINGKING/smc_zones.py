#!/usr/bin/env python3
"""
Simplified BigBeluga-style SMC: swing structure + volumetric order blocks.
Inspired by TradingView indicator; not a line-by-line port.
"""
from __future__ import annotations

import json
import math
import sys
from dataclasses import dataclass, field
from typing import Any


@dataclass
class OrderBlock:
    bull: bool
    top: float
    btm: float
    avg: float
    bar_index: int
    time: str
    vol: float
    mitigated: bool = False


@dataclass
class MarketState:
    start: int = 0
    trend: int = 0
    bos: float | None = None
    choch: float | None = None
    loc: int = 0
    temp: int = 0
    main: float = 0.0
    xloc: int = 0


def atr_series(highs: list[float], lows: list[float], closes: list[float], period: int = 200) -> list[float]:
    n = len(closes)
    tr = [highs[0] - lows[0]]
    for i in range(1, n):
        tr.append(max(highs[i] - lows[i], abs(highs[i] - closes[i - 1]), abs(lows[i] - closes[i - 1])))
    out: list[float] = []
    for i in range(n):
        if i < period:
            out.append(sum(tr[: i + 1]) / (i + 1))
        else:
            out.append(sum(tr[i - period + 1 : i + 1]) / period)
    return out


def find_idx(
    highs: list[float],
    lows: list[float],
    loc: int,
    cur: int,
    use_max: bool,
    use_ob_adj: bool,
) -> int:
    if loc < 0 or cur <= loc:
        return 0
    span = cur - loc - 1 if cur - loc - 1 > 0 else cur - loc
    start = 0
    end = span
    best_idx = 0
    if use_max:
        best = -math.inf
        for i in range(start, end + 1):
            h = highs[cur - i]
            if h > best:
                best = h
                best_idx = i
        if use_ob_adj and cur - best_idx - 1 >= 0 and highs[cur - best_idx - 1] > highs[cur - best_idx]:
            best_idx += 1
    else:
        best = math.inf
        for i in range(start, end + 1):
            lo = lows[cur - i]
            if lo < best:
                best = lo
                best_idx = i
        if use_ob_adj and cur - best_idx - 1 >= 0 and lows[cur - best_idx - 1] < lows[cur - best_idx]:
            best_idx += 1
    return best_idx


def ob_top_bottom(
    bull: bool,
    i_bull: int,
    i_bear: int,
    highs: list[float],
    lows: list[float],
    atr: list[float],
    cur: int,
    ob_mode: str,
    ob_len: int,
) -> tuple[float, float, int]:
    scale = atr[cur] / (5.0 / max(ob_len, 1)) if atr[cur] else 0.0
    if bull:
        raw_top = highs[cur - i_bull]
        if ob_mode == "Length":
            adj = highs[cur - i_bull] - scale
            top = raw_top if lows[cur - i_bull] > adj else adj
        else:
            top = raw_top
        btm = lows[cur - i_bull]
        return top, btm, cur - i_bull
    raw_btm = lows[cur - i_bear]
    if ob_mode == "Length":
        adj = lows[cur - i_bear] + scale
        btm = raw_btm if highs[cur - i_bear] < adj else adj
    else:
        btm = raw_btm
    top = highs[cur - i_bear]
    return top, btm, cur - i_bear


def overlap_filter(blocks: list[OrderBlock], keep_recent: bool) -> list[OrderBlock]:
    if len(blocks) <= 1:
        return blocks
    out = list(blocks)

    def overlaps(a: OrderBlock, b: OrderBlock) -> bool:
        return not (a.btm > b.top or a.top < b.btm)

    changed = True
    while changed:
        changed = False
        for i in range(len(out) - 1, 0, -1):
            cur = out[i]
            ref = out[0] if keep_recent else out[i - 1]
            v = i if keep_recent else 0
            if overlaps(cur, ref) and cur != ref:
                out.pop(v)
                changed = True
                break
    return out


def _bar_mitigates_ob(ob: OrderBlock, o: float, h: float, l: float, c: float, method: str) -> bool:
    if ob.bull:
        if method == "Close":
            return min(c, o) < ob.btm
        if method == "Wick":
            return l < ob.btm
        return l < ob.avg
    if method == "Close":
        return max(c, o) > ob.top
    if method == "Wick":
        return h > ob.top
    return h > ob.avg


def mitigate_through_bar(
    blocks: list[OrderBlock],
    bar: int,
    opens: list[float],
    highs: list[float],
    lows: list[float],
    closes: list[float],
    method: str,
) -> None:
    """Pine: mitigation on each confirmed bar after the OB forms."""
    for ob in blocks:
        if ob.mitigated or bar <= ob.bar_index:
            continue
        if _bar_mitigates_ob(ob, opens[bar], highs[bar], lows[bar], closes[bar], method):
            ob.mitigated = True


def overlap_bull_bear(
    bull: list[OrderBlock],
    bear: list[OrderBlock],
    keep_recent: bool,
) -> tuple[list[OrderBlock], list[OrderBlock]]:
    if not bull or not bear:
        return bull, bear
    b, r = list(bull), list(bear)

    def overlaps(a: OrderBlock, b: OrderBlock) -> bool:
        return not (a.btm > b.top or a.top < b.btm)

    changed = True
    while changed:
        changed = False
        for i in range(len(b) - 1, -1, -1):
            if b and r and overlaps(b[i if not keep_recent else 0], r[0]):
                idx = i if keep_recent else 0
                b.pop(idx)
                changed = True
                break
        if changed:
            continue
        for i in range(len(r) - 1, -1, -1):
            if b and r and overlaps(r[i if not keep_recent else 0], b[0]):
                idx = i if keep_recent else 0
                r.pop(idx)
                changed = True
                break
    return b, r


def run_smc(
    candles: list[dict[str, Any]],
    *,
    mslen: int = 5,
    ob_last: int = 5,
    ob_len: int = 5,
    ob_mode: str = "Length",
    ob_miti: str = "Close",
    ms_window: int = 5000,
    ms_window_enabled: bool = True,
    hide_overlap: bool = True,
    overlap_keep_recent: bool = True,
) -> dict[str, Any]:
    n = len(candles)
    if n < mslen * 4 + 10:
        return {"ok": False, "error": "not enough candles"}

    opens = [float(c["open"]) for c in candles]
    highs = [float(c["high"]) for c in candles]
    lows = [float(c["low"]) for c in candles]
    closes = [float(c["close"]) for c in candles]
    vols = [float(c.get("tick_volume") or c.get("volume") or 0) for c in candles]
    times = [c.get("time", "") for c in candles]

    atr = atr_series(highs, lows, closes, 200)
    if ms_window_enabled and ms_window > 0:
        start = max(0, n - ms_window)
    else:
        start = 0

    ms = MarketState()
    bull_obs: list[OrderBlock] = []
    bear_obs: list[OrderBlock] = []

    ph_p: list[float] = []
    ph_n: list[int] = []
    pl_p: list[float] = []
    pl_n: list[int] = []

    up = highs[start]
    dn = lows[start]

    def add_ob(bull: bool, top: float, btm: float, bi: int):
        ob = OrderBlock(
            bull=bull,
            top=top,
            btm=btm,
            avg=(top + btm) / 2.0,
            bar_index=bi,
            time=times[bi] if bi < len(times) else "",
            vol=vols[bi] if bi < len(vols) else 0.0,
        )
        if bull:
            bull_obs.insert(0, ob)
        else:
            bear_obs.insert(0, ob)

    for cur in range(start, n):
        if cur >= 2 * mslen:
            pi = cur - mslen
            if highs[pi] == max(highs[pi - mslen : pi + mslen + 1]):
                ph_n.insert(0, pi)
                ph_p.insert(0, highs[pi])
            if lows[pi] == min(lows[pi - mslen : pi + mslen + 1]):
                pl_n.insert(0, pi)
                pl_p.insert(0, lows[pi])

        if ph_p and highs[cur] > ph_p[0]:
            ph_p.clear()
            ph_n.clear()
        if pl_p and lows[cur] < pl_p[0]:
            pl_p.clear()
            pl_n.clear()

        crossup = highs[cur] > up
        crossdn = lows[cur] < dn
        up = max(up, highs[cur])
        dn = min(dn, lows[cur])

        if ms.start == 0:
            ms = MarketState(start=1, trend=0, bos=highs[cur], choch=lows[cur], loc=cur, temp=cur, main=highs[cur], xloc=cur)
            continue

        id_bull = find_idx(highs, lows, ms.loc, cur, False, True)
        id_bear = find_idx(highs, lows, ms.loc, cur, True, True)

        if ms.start == 1:
            if closes[cur] <= ms.choch:
                top, btm, bi = ob_top_bottom(True, id_bull, id_bear, highs, lows, atr, cur, ob_mode, ob_len)
                add_ob(True, top, btm, bi)
                ms.trend = -1
                ms.choch = ms.bos
                ms.bos = None
                ms.start = 2
                ms.loc = cur
                ms.main = lows[cur]
                ms.temp = cur
                ms.xloc = cur
            elif closes[cur] >= ms.bos:
                top, btm, bi = ob_top_bottom(False, id_bull, id_bear, highs, lows, atr, cur, ob_mode, ob_len)
                add_ob(False, top, btm, bi)
                ms.trend = 1
                ms.choch = ms.choch
                ms.bos = None
                ms.start = 2
                ms.loc = cur
                ms.main = highs[cur]
                ms.temp = cur
                ms.xloc = cur

        elif ms.start == 2:
            if ms.trend == -1:
                if lows[cur] <= ms.main:
                    ms.main = lows[cur]
                    ms.temp = cur
                if ms.bos is None and crossup and closes[cur] > opens[cur] and closes[cur - 1] > opens[cur - 1]:
                    ms.bos = ms.main
                    ms.loc = ms.temp
                    ms.xloc = ms.loc
                if ms.bos is not None and closes[cur] <= ms.bos:
                    top, btm, bi = ob_top_bottom(False, id_bull, id_bear, highs, lows, atr, cur, ob_mode, ob_len)
                    add_ob(False, top, btm, bi)
                    ms.bos = None
                    fid = find_idx(highs, lows, ms.xloc, cur, True, False)
                    ms.choch = highs[cur - fid]
                    ms.loc = cur - fid
                if closes[cur] >= ms.choch:
                    top, btm, bi = ob_top_bottom(True, id_bull, id_bear, highs, lows, atr, cur, ob_mode, ob_len)
                    add_ob(True, top, btm, bi)
                    ms.bos = None
                    ms.main = highs[cur]
                    ms.trend = 1
                    ms.loc = cur
                    ms.temp = cur
                    ms.xloc = cur
            elif ms.trend == 1:
                if highs[cur] >= ms.main:
                    ms.main = highs[cur]
                    ms.temp = cur
                if ms.bos is None and crossdn and closes[cur] < opens[cur] and closes[cur - 1] < opens[cur - 1]:
                    ms.bos = ms.main
                    ms.loc = ms.temp
                    ms.xloc = ms.loc
                if ms.bos is not None and closes[cur] >= ms.bos:
                    top, btm, bi = ob_top_bottom(True, id_bull, id_bear, highs, lows, atr, cur, ob_mode, ob_len)
                    add_ob(True, top, btm, bi)
                    ms.bos = None
                    fid = find_idx(highs, lows, ms.xloc, cur, False, False)
                    ms.choch = lows[cur - fid]
                    ms.loc = cur - fid
                if closes[cur] <= ms.choch:
                    top, btm, bi = ob_top_bottom(False, id_bull, id_bear, highs, lows, atr, cur, ob_mode, ob_len)
                    add_ob(False, top, btm, bi)
                    ms.bos = None
                    ms.main = lows[cur]
                    ms.trend = -1
                    ms.loc = cur
                    ms.temp = cur
                    ms.xloc = cur

        mitigate_through_bar(bull_obs, cur, opens, highs, lows, closes, ob_miti)
        mitigate_through_bar(bear_obs, cur, opens, highs, lows, closes, ob_miti)

    bull_active = [o for o in bull_obs if not o.mitigated][:ob_last]
    bear_active = [o for o in bear_obs if not o.mitigated][:ob_last]
    if hide_overlap:
        bull_active = overlap_filter(bull_active, overlap_keep_recent)
        bear_active = overlap_filter(bear_active, overlap_keep_recent)
        bull_active, bear_active = overlap_bull_bear(bull_active, bear_active, overlap_keep_recent)

    def pack(obs: list[OrderBlock], kind: str) -> list[dict]:
        total_vol = sum(o.vol for o in obs) or 1.0
        rows = []
        for o in obs:
            rows.append(
                {
                    "side": kind,
                    "top": round(o.top, 5),
                    "bottom": round(o.btm, 5),
                    "mid": round(o.avg, 5),
                    "time": o.time,
                    "bar_index": o.bar_index,
                    "volume": round(o.vol, 3),
                    "vol_pct": round(100.0 * o.vol / total_vol, 1),
                }
            )
        return rows

    return {
        "ok": True,
        "symbol": candles[0].get("_symbol", ""),
        "bars": n,
        "trend": ms.trend,
        "buy_zones": pack(bull_active, "buy"),
        "sell_zones": pack(bear_active, "sell"),
        "last_close": closes[-1],
        "last_time": times[-1],
    }


def main():
    cfg = json.loads(sys.argv[1]) if len(sys.argv) > 1 else {}
    raw = json.load(sys.stdin)
    if not raw.get("ok"):
        print(json.dumps(raw, indent=2))
        sys.exit(1)
    candles = raw.get("candles") or []
    candles = [{**c, "_symbol": raw.get("symbol", "")} for c in candles]
    out = run_smc(
        candles,
        mslen=int(cfg.get("MS_LEN", 5)),
        ob_last=int(cfg.get("OB_LAST", 5)),
        ob_len=int(cfg.get("OB_LEN", 5)),
        ob_mode=str(cfg.get("OB_MODE", "Length")),
        ob_miti=str(cfg.get("OB_MITI", "Close")),
        ms_window=int(cfg.get("MS_WINDOW", 5000)),
        ms_window_enabled=str(cfg.get("MS_WINDOW_ENABLED", "1")) == "1",
        hide_overlap=str(cfg.get("HIDE_OVERLAP", "1")) == "1",
        overlap_keep_recent=str(cfg.get("OVERLAP_KEEP", "Recent")) == "Recent",
    )
    print(json.dumps(out, indent=2))


if __name__ == "__main__":
    main()