# SWINGKING

Shell + Python helper that marks **buy (demand)** and **sell (supply)** zones from MT5 M5 candles, roughly matching **BigBeluga Smart Money Concepts** order blocks (not a full Pine clone).

## Quick start

```bash
cd SWINGKING
./swingking.sh mark
```

Uses `../var.env` for VPS (`MT5_HOST`, API key). Edit `swingking.env` for symbol/timeframe.

## Commands

| Command | Purpose |
|---------|---------|
| `./swingking.sh mark` | Print zones + write `zones/GOLD-M5-zones.json` |
| `./swingking.sh json` | JSON only |
| `./swingking.sh watch` | Refresh on `LOOP_SLEEP` (default 60s) |
| `../init.sh start` | Starts **swingking_ack** (PSW watcher) with TC workers |
| `./swingking.sh deploy` | Manual one-shot only (debug) |
| `./swingking.sh reset-psw` | Clear deploy lock when PSW flat |

### PSW deploy (one-time)

1. From repo root: `./init.sh -e var.env start` — workers include **maintain_order**, **TC_BUY**, **TC_SELL**, **swingking_ack** (PSW watcher; log `logs/GOLD/swingking_ack.log`).
2. Place a **manual** `buy_stop` **0.14** lot on `GOLD` (ack). Comment can be blank; not `PSW` or grid `L*`.
3. **swingking_ack** polls every `PSW_ACK_POLL_SLEEP` (5s in `var.env`) and auto-deploys once (cancel ack → PSW limits). No `swingking.sh deploy` needed.
4. Deploy deletes the ack order, prints zones, places:
   - `buy_limit` @ first bullish OB mid, comment **`PSW`**, magic `BUY_MAGIC`, TP **2000** pts
   - `sell_limit` @ first bearish OB mid, comment **`PSW`**, magic `SELL_MAGIC`, TP **2000** pts
5. Does **not** re-place until cycle resets; state in `zones/.psw_deployed`. After flat, `./swingking.sh reset-psw` then place ack again.

TC grid treats **`PSW` before `PRIMARY`** (`TC_ANCHOR_COMMENTS` in `var.env`) — same basket close rules as EMA PRIMARY.

## Pine settings mapped

| Pine input | `swingking.env` |
|------------|-----------------|
| Window / bars | `MS_WINDOW`, `CANDLE_COUNT` |
| Algorithm length | `MS_LEN` |
| Show last OBs | `OB_LAST` |
| Construction Length | `OB_LEN`, `OB_MODE` |
| Mitigation Close | `OB_MITI` |
| Hide overlap Recent | `HIDE_OVERLAP`, `OVERLAP_KEEP` |

Zones are **active** (not mitigated). Mitigation runs on **every bar after** the OB forms (Close / Wick / Avg), same as Pine — old demand blocks far above today’s price should disappear after price trades through them. **Supply** zones above price can stay active until price rallies through the top (also like TV).

`swingking.env` matches your TV screenshot: Window 5000, Swing 100, MS length 5, OB last 5, Length 5, Mitigation Close, Hide overlap Recent.

## Output shape

```json
{
  "buy_zones": [{ "side": "buy", "top": 3638.1, "bottom": 3634.5, "mid": 3636.3, "vol_pct": 23.0 }],
  "sell_zones": [{ "side": "sell", "top": 3680.0, "bottom": 3672.0, "mid": 3676.0 }]
}
```

Green demand ≈ buy zones; red supply ≈ sell zones on your chart screenshot.