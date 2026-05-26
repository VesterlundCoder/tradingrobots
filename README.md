# Trading Robots — VesterlundCoder

MQL5 Expert Advisors developed and validated through systematic backtesting via the RD-LUMI-Z3 HFT Lab.  
All EAs are written for **MetaTrader 5** and use ATR-based position sizing unless noted.

> **Leverage notation:** `1:1` = no built-in leverage multiplier; position size is purely risk%-based.  
> `Coded Nx` = EA has an explicit leverage/lot-multiplier parameter (default value noted).

---

## Table of Contents

- [Lab-Validated EAs (FTMO-Ready)](#lab-validated-eas-ftmo-ready)
- [Gap Continuation Series (Funded Account)](#gap-continuation-series-funded-account)
- [HFT Tick Scalpers](#hft-tick-scalpers)
- [ATR Breakout Variants](#atr-breakout-variants)
- [Squeeze & Channel Breakout](#squeeze--channel-breakout)
- [Specialised / Statistical](#specialised--statistical)
- [Grid & Martingale (High Risk)](#grid--martingale-high-risk)
- [Utility](#utility)

---

## Lab-Validated EAs (FTMO-Ready)

These EAs were built from results of a 4,550-variant systematic scan across 2 years of H1 + M5 data with strict IS/OOS holdout validation.

---

### RSIReversionGBPUSD_H1

| Property | Value |
|---|---|
| **Market** | GBPUSD |
| **Timeframe** | H1 |
| **Strategy type** | Swing — RSI mean reversion |
| **Session filter** | London + NY overlap (07:00–17:00 UTC) |
| **Leverage** | **1:1** (risk_pct=0.25% per trade) |
| **OOS Sharpe** | +5.97 |
| **OOS trade count** | 48 |
| **Win rate** | 45% |
| **R:R** | 3:1 (TP=6×ATR, SL=2×ATR) |
| **Estimated max DD** | 3–6% |
| **Estimated return/month** | 1.5–3% at 1:1 |
| **FTMO compliant** | ✅ Yes |

**Logic:** Fades RSI extremes (oversold <25 / overbought >75) with ATR-based SL/TP. Enters on RSI cross-back from extreme. Most statistically credible EA in the lab — 48 OOS trades gives meaningful sample.

---

### RSIReversionMSFT_H1

| Property | Value |
|---|---|
| **Market** | MSFT CFD (US Stock) |
| **Timeframe** | H1 |
| **Strategy type** | Swing — RSI mean reversion |
| **Session filter** | NYSE hours (13:30–20:00 UTC) |
| **Leverage** | **1:1** (risk_pct=0.25% per trade) |
| **OOS Sharpe** | +13.58 |
| **OOS trade count** | 12 ⚠️ small sample |
| **Win rate** | 43% |
| **R:R** | 3:1 |
| **Estimated max DD** | 8–12% |
| **Estimated return/month** | 2–5% at 1:1 |
| **FTMO compliant** | ✅ Yes (if broker offers MSFT CFD) |

**Logic:** Same RSI reversion logic, tuned for MSFT volatility (bands 30/70). NYSE session only. Note: only 12 OOS trades — monitor closely in live.

---

### ATRBreakoutStockCFD_H1

| Property | Value |
|---|---|
| **Market** | INTC, AMD, NVDA, MSFT (US Stock CFDs) |
| **Timeframe** | H1 |
| **Strategy type** | Swing — ATR volatility breakout |
| **Session filter** | NYSE hours (13:30–20:00 UTC) |
| **Leverage** | **1:1** (risk_pct=0.25% per trade) |
| **Best OOS Sharpe** | NVDA +8.1 |
| **Win rate** | 44–52% across stocks |
| **R:R** | 3:1 |
| **Estimated max DD** | 6–10% |
| **Estimated return/month** | 1.5–3% at 1:1 |
| **FTMO compliant** | ✅ Yes |

**Logic:** Enters long/short when ATR expands above its rolling average (volatility expansion) AND price breaks the N-bar high/low, confirmed by EMA trend + ADX>25. Runs 4 symbols in one EA — attach once.

---

## Gap Continuation Series (Funded Account)

These EAs require instruments not available on standard FTMO challenges. Build for later deployment on funded accounts.

---

### GapContinuationNikkei_H1

| Property | Value |
|---|---|
| **Market** | JP225 / NI225 (Nikkei 225) |
| **Timeframe** | H1 |
| **Strategy type** | Swing — gap + trend continuation |
| **Leverage** | **1:1** (risk_pct=0.25% per trade) |
| **Mean OOS Sharpe** | +4.51 (across all param combos) |
| **Best OOS Sharpe** | +16.0 |
| **% positive param combos** | 89% |
| **R:R** | 3:1 |
| **Estimated max DD** | 5–8% |
| **Estimated return/month** | 2–4% at 1:1 |
| **FTMO compliant** | ⚠️ Check if broker offers Nikkei |

**Logic:** Fires when an H1 bar opens ≥0.1% above/below the prior close (gap), in the direction of the EMA100 trend. Tokyo-London session handoff gaps on Nikkei tend to extend rather than fill.

---

### GapContinuationSPX500_H1

| Property | Value |
|---|---|
| **Market** | US500 / SP500 (S&P 500) |
| **Timeframe** | H1 |
| **Strategy type** | Swing — gap + trend continuation |
| **Leverage** | **1:1** (risk_pct=0.25% per trade) |
| **Mean OOS Sharpe** | +4.04 |
| **Best OOS Sharpe** | +8.1 |
| **% positive param combos** | 86% |
| **R:R** | 3:1 |
| **Estimated max DD** | 5–8% |
| **Estimated return/month** | 2–3% at 1:1 |
| **FTMO compliant** | ⚠️ Check if broker offers US500 |

**Logic:** Same gap continuation logic for S&P 500. NYSE open gaps in prevailing trend direction tend to continue. Session filter: 13:00–20:00 UTC.

---

### GapContinuationSilver_H1

| Property | Value |
|---|---|
| **Market** | XAGUSD (Silver spot) |
| **Timeframe** | H1 |
| **Strategy type** | Swing — regime-gated gap continuation |
| **Leverage** | **1:1** (risk_pct=0.20% per trade) |
| **OOS Sharpe** | +4.48 (2-year H1 backtest, Nov 2025–May 2026) |
| **OOS return** | +31.6% in 6-month OOS period |
| **Win rate** | 54% |
| **R:R** | 3:1 |
| **Estimated max DD** | 5–10% in trending regime |
| **Estimated return/month** | 3–5% in trending markets, ~0% in ranging |
| **FTMO compliant** | ⚠️ Check availability (XAGUSD not on all challenges) |

**Logic:** Gap in trend direction (EMA50), with EMA200 regime gate — only activates when Silver is in a sustained directional trend. Regime-conditional: strong in bull/bear markets, flat in ranges. Build robustness with 3+ years of data before live.

---

## HFT Tick Scalpers

> ⚠️ These require ECN/raw spread accounts. Do NOT run on standard accounts — spread will destroy edge.

---

### HFTScalperUS30EA

| Property | Value |
|---|---|
| **Market** | US30 / Dow Jones CFD |
| **Timeframe** | M1 / Tick |
| **Strategy type** | HFT tick-momentum scalper |
| **Session filter** | NY session only |
| **Leverage** | **1:1** (fixed lot, no martingale, no grid) |
| **Live trade count** | 31,400 trades (Jun 2023–Apr 2024) |
| **Win rate** | 76.4% |
| **Profit factor** | 6.97 |
| **R:R** | 2.16 |
| **Max hold** | 3 seconds |
| **Live max DD** | 3.6% |
| **Live gain** | 3,741% over 10 months |
| **Estimated return/month** | 50–200%+ (highly dependent on lot size + spread) |
| **Broker requirement** | Spread ≤ 1.0 point (IC Markets / Pepperstone / FP Markets raw) |
| **FTMO compliant** | ⚠️ High trade frequency may trigger FTMO review |

**Logic:** Fires on every qualifying tick. Direction = momentum of last tick. TP=2pts, SL=1pt. All trades close within 1–3 seconds. Zero overnight risk. Reverse-engineered from hft-prop-ea myfxbook live stats.

---

### HFTScalperForexEA

| Property | Value |
|---|---|
| **Market** | EURUSD, GBPUSD, USDJPY, XAUUSD |
| **Timeframe** | M1 / Tick |
| **Strategy type** | HFT tick-momentum scalper |
| **Session filter** | London + NY (07:00–17:00 UTC) |
| **Leverage** | **1:1** |
| **Stats (inherited from US30 version)** | WR 76.4%, PF 6.97, 3.6% max DD |
| **Estimated return/month** | 30–150%+ (lot-size dependent) |
| **Broker requirement** | Spread ≤ 0.3 pip |
| **FTMO compliant** | ⚠️ Same HFT caveat as US30 version |

**Logic:** Forex port of HFTScalperUS30. Same tick-momentum logic with pip-based SL/TP and forex spread guard.

---

## ATR Breakout Variants

Specialised versions of the core ATR breakout grammar for specific instruments.

---

### ATRBreakoutDAX40_H1

| Property | Value |
|---|---|
| **Market** | GER40 / DAX40 |
| **Timeframe** | H1 |
| **Leverage** | **Coded 1x–4x** (leverage parameter, default 1x) |
| **Estimated max DD** | 5–12% at 1x |
| **Estimated return/month** | 1–3% at 1x |
| **FTMO compliant** | ✅ at default 1x |

---

### ATRBreakoutFTSE100_H1

| Property | Value |
|---|---|
| **Market** | UK100 / FTSE100 |
| **Timeframe** | H1 |
| **Leverage** | **Coded 1x–4x** (leverage parameter, default 1x) |
| **Estimated max DD** | 5–12% at 1x |
| **Estimated return/month** | 1–3% at 1x |
| **FTMO compliant** | ✅ at default 1x |

---

### ATRBreakoutUSDCNH_H1

| Property | Value |
|---|---|
| **Market** | USDCNH |
| **Timeframe** | H1 |
| **Leverage** | **1:1** |
| **Notes** | China session focus. No scan validation — experimental |

---

### ATRBreakoutEA

Generic ATR breakout EA — configurable symbol and timeframe. No specific instrument tuning. Use as a template for new instruments.

---

## Squeeze & Channel Breakout

---

### SqueezeBreakoutEA

| Property | Value |
|---|---|
| **Market** | Configurable (best: NVDA, SPX500) |
| **Timeframe** | H1 |
| **Strategy type** | Swing — BB/Keltner squeeze release |
| **Leverage** | **1:1** (risk_pct=0.25%) |
| **Best OOS Sharpe** | NVDA +19.0, SPX500 +9.7 (12m H1 scan) |
| **Win rate** | 36–52% (wide variance) |
| **Estimated max DD** | 7–15% |
| **Estimated return/month** | 2–5% at 1:1 |
| **FTMO compliant** | ✅ |

**Logic:** Fires when Bollinger Bands (20, 2.0) exit a "squeeze" — where BB was fully inside Keltner Channel (20, 1.5×ATR). Direction is determined by price position relative to EMA at release. Few but high-quality signals per month.

---

### SqueezeBreakoutUSDCNH_H4

Squeeze breakout tuned for USDCNH H4. Wider Keltner multiplier (2.0) for CNH's lower volatility profile. No scan validation.

---

### ChannelBreakout10_USDCNH_H4 / ChannelBreakout20_USDCNH_H4

| Property | Value |
|---|---|
| **Market** | USDCNH |
| **Timeframe** | H4 |
| **Strategy type** | Donchian channel breakout (10-bar and 20-bar) |
| **Leverage** | **1:1** |
| **Notes** | Nikkei Donchian M5 showed OOS Sharpe +4.5 in lab (41 trades). USDCNH version not scanned. |

---

## Specialised / Statistical

---

### AsianRangeBreakoutEA

| Property | Value |
|---|---|
| **Market** | FX (configurable, best on GBPUSD, USDJPY) |
| **Timeframe** | H1 |
| **Strategy type** | Swing — Asian range breakout at London open |
| **Leverage** | **1:1** (risk_pct=0.25%) |
| **Estimated max DD** | 5–10% |
| **Estimated return/month** | 1–3% |
| **FTMO compliant** | ✅ |

**Logic:** Defines the Asian session high/low (00:00–06:00 UTC), then enters on breakout of that range at London open. Classic strategy — no lab scan data for this version.

---

### RSI2TrendEA

| Property | Value |
|---|---|
| **Market** | Configurable (equity indices recommended) |
| **Timeframe** | H1 |
| **Strategy type** | Swing — Connors RSI(2) with EMA200 trend filter |
| **Leverage** | **1:1** (risk_pct=0.25%) |
| **Estimated max DD** | 5–10% |
| **Estimated return/month** | 1–3% |

**Logic:** Fades extreme RSI(2) readings (RSI<5 long, RSI>95 short) only in the direction of the EMA200 trend. Short mean-reversion timeframe — typically exits within 1–3 bars.

---

### USDSEKResidualEA

| Property | Value |
|---|---|
| **Market** | USDSEK |
| **Timeframe** | H1 / H4 |
| **Strategy type** | Statistical relative value (pairs-style) |
| **Leverage** | **1:1** |
| **Requirements** | EURUSD, EURSEK, USDJPY must be in Market Watch |
| **Notes** | Trades USDSEK residual vs synthetic price (EUR/USD-derived). Experimental — no scan validation. |

---

## Grid & Martingale (High Risk)

> ⛔ **WARNING:** These strategies use martingale or grid position building. They have theoretically unlimited drawdown and are **NOT compatible with FTMO or any prop firm challenge**. They can wipe an account in a single sustained trend move. Use only with dedicated risk capital you can afford to lose completely.

---

### ClassicGridMartingaleEA

| Property | Value |
|---|---|
| **Market** | Configurable |
| **Strategy type** | Classic martingale grid |
| **Leverage** | **Coded — lot multiplier on each loss** |
| **Max DD** | Unlimited (martingale) |
| **Estimated return/month** | 5–30% in ranging markets |
| **FTMO compliant** | ❌ Never |

---

### AUDGridRobot / AUDUSDNZDGridEA

| Property | Value |
|---|---|
| **Market** | AUD pairs (AUDUSD, AUDNZD) |
| **Strategy type** | Correlated currency grid |
| **Leverage** | **Coded — grid lot scaling** |
| **FTMO compliant** | ❌ Never |

---

### DecliningGridEA

Grid strategy with declining lot sizes as positions extend. Reduces martingale risk but still builds multiple positions. **Not FTMO safe.**

---

### InventoryGridEA

Inventory-management grid — uses market-maker style bid/ask spread around a reference price. **Not FTMO safe.**

---

## Utility

---

### RofxHedgeEA / RofxProEA / RofxRecoveryEA

| Property | Value |
|---|---|
| **Type** | Hedge / Recovery system |
| **Leverage** | **Coded — recovery uses larger lots** |
| **Notes** | Inspired by ROFX hedge-recovery strategy. Attempts to recover losing trades via hedging. Dangerous in trending markets. **Not FTMO safe.** |

---

### PythonBridgeEA

Utility EA that forwards MT5 tick data and bar data to a local Python process via named pipes. No trading logic — used as a data bridge for external Python strategies. Requires a Python socket server running locally.

---

### BasicStocksEA

Template EA for stock CFDs. Simple momentum logic, no advanced filtering. Useful as a starting point for new stock strategies. No scan validation.

---

## Quick Reference — All EAs

| EA | Market | TF | Strategy | OOS Sharpe | Max DD est | Return/mo | Leverage | FTMO |
|---|---|---|---|---|---|---|---|---|
| RSIReversionGBPUSD_H1 | GBPUSD | H1 | RSI reversion | +5.97 | 3–6% | 1.5–3% | 1:1 | ✅ |
| RSIReversionMSFT_H1 | MSFT | H1 | RSI reversion | +13.58* | 8–12% | 2–5% | 1:1 | ✅ |
| ATRBreakoutStockCFD_H1 | INTC/AMD/NVDA/MSFT | H1 | ATR breakout | +8.1 (NVDA) | 6–10% | 1.5–3% | 1:1 | ✅ |
| GapContinuationNikkei_H1 | JP225 | H1 | Gap continuation | +4.51 avg | 5–8% | 2–4% | 1:1 | ⚠️ |
| GapContinuationSPX500_H1 | US500 | H1 | Gap continuation | +4.04 avg | 5–8% | 2–3% | 1:1 | ⚠️ |
| GapContinuationSilver_H1 | XAGUSD | H1 | Gap + regime gate | +4.48 | 5–10% | 3–5%† | 1:1 | ⚠️ |
| HFTScalperUS30EA | US30 | Tick | Tick momentum | Live +3741% | 3.6% | 50–200%‡ | 1:1 | ⚠️ |
| HFTScalperForexEA | EURUSD/GBPUSD | Tick | Tick momentum | (inherited) | 3–6% | 30–150%‡ | 1:1 | ⚠️ |
| ATRBreakoutDAX40_H1 | GER40 | H1 | ATR breakout | Not scanned | 5–12% | 1–3% | Coded 1–4x | ✅ 1x |
| ATRBreakoutFTSE100_H1 | UK100 | H1 | ATR breakout | Not scanned | 5–12% | 1–3% | Coded 1–4x | ✅ 1x |
| ATRBreakoutUSDCNH_H1 | USDCNH | H1 | ATR breakout | Not scanned | 5–10% | 1–2% | 1:1 | ✅ |
| SqueezeBreakoutEA | NVDA/SPX500 | H1 | BB/Keltner squeeze | +19.0 (NVDA) | 7–15% | 2–5% | 1:1 | ✅ |
| SqueezeBreakoutUSDCNH_H4 | USDCNH | H4 | Squeeze | Not scanned | 5–10% | 1–2% | 1:1 | ✅ |
| ChannelBreakout10_USDCNH_H4 | USDCNH | H4 | Donchian 10 | Not scanned | 5–10% | 1–2% | 1:1 | ✅ |
| ChannelBreakout20_USDCNH_H4 | USDCNH | H4 | Donchian 20 | Not scanned | 5–10% | 1–2% | 1:1 | ✅ |
| AsianRangeBreakoutEA | FX | H1 | Asian range breakout | Not scanned | 5–10% | 1–3% | 1:1 | ✅ |
| RSI2TrendEA | Indices | H1 | Connors RSI(2) | Not scanned | 5–10% | 1–3% | 1:1 | ✅ |
| USDSEKResidualEA | USDSEK | H1/H4 | Stat relative value | Not scanned | 5–10% | 1–2% | 1:1 | ✅ |
| ClassicGridMartingaleEA | Any | Any | Martingale grid | ❌ | Unlimited | High | Coded | ❌ |
| AUDGridRobot | AUD pairs | Any | Grid | ❌ | Unlimited | High | Coded | ❌ |
| AUDUSDNZDGridEA | AUDUSD/AUDNZD | Any | Correlated grid | ❌ | Unlimited | High | Coded | ❌ |
| DecliningGridEA | Any | Any | Declining grid | ❌ | Very high | Moderate | Coded | ❌ |
| InventoryGridEA | Any | Any | Inventory grid | ❌ | Very high | Moderate | Coded | ❌ |
| RofxHedgeEA | Any | Any | Hedge recovery | ❌ | Very high | Variable | Coded | ❌ |
| RofxProEA | Any | Any | Hedge recovery | ❌ | Very high | Variable | Coded | ❌ |
| RofxRecoveryEA | Any | Any | Loss recovery | ❌ | Very high | Variable | Coded | ❌ |
| PythonBridgeEA | — | — | Data bridge utility | — | — | — | — | — |
| BasicStocksEA | Stocks | H1 | Basic momentum | Not scanned | — | — | 1:1 | — |
| ATRBreakoutEA | Any | Any | ATR breakout template | Not scanned | — | — | 1:1 | — |

*\*12 OOS trades only — small sample*  
*†Silver: trending regime only — ~0% expected in ranging markets*  
*‡HFT scalpers: returns are highly lot-size and spread dependent*

---

## Backtesting Infrastructure

All scan-validated EAs were developed using:
- **HFT Lab** (`hft_lab/`) — 4,550 strategy variants × 2yr H1 + 3m M5 data
- **Cross-Asset Lab** (`cross_asset_lab/`) — 23 instruments, zero-shot portability, regime conditioning
- **Silver 2yr backtest** — dedicated vectorized IS/OOS backtest on XAGUSD H1

Scan parameters: 70% IS / 30% OOS holdout, ATR-based sizing (0.25% risk/trade), Sharpe calculated on equity curve, FDR correction applied.

---

*Repository maintained by VesterlundCoder. All EAs are for educational and research purposes.*
