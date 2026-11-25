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

## Pine settings mapped

| Pine input | `swingking.env` |
|------------|-----------------|
| Window / bars | `MS_WINDOW`, `CANDLE_COUNT` |
| Algorithm length | `MS_LEN` |
| Show last OBs | `OB_LAST` |
| Construction Length | `OB_LEN`, `OB_MODE` |
| Mitigation Close | `OB_MITI` |
| Hide overlap Recent | `HIDE_OVERLAP`, `OVERLAP_KEEP` |

Zones are **active** (not mitigated by price). Compare levels to TradingView; VPS candle history may differ slightly from the chart feed.

## Output shape

```json
{
  "buy_zones": [{ "side": "buy", "top": 3638.1, "bottom": 3634.5, "mid": 3636.3, "vol_pct": 23.0 }],
  "sell_zones": [{ "side": "sell", "top": 3680.0, "bottom": 3672.0, "mid": 3676.0 }]
}
```

Green demand ≈ buy zones; red supply ≈ sell zones on your chart screenshot.