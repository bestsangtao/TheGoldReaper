# GeminiAI_EA — MT5 Expert Advisor powered by Google Gemini

An MT5 (MQL5) Expert Advisor that uses the Google Gemini API as its trading
decision engine. It ships with **10 fully independent gating strategies**,
each watching its own indicators on its own timeframe. When a strategy's
condition fires, the EA packages recent OHLC candles + indicator values +
timeframe/account context into JSON and asks Gemini for a concrete trade
decision (BUY/SELL, order type, entry, stop loss, take profit). Once the
resulting position is open, a separate **momentum-based management gate**
periodically re-asks Gemini how to manage the trade (trail the stop, lock in
profit, move SL/TP, close early, partial close).

## How it works

```
Strategy gate fires (its own indicators/logic)
        |
        v
Build JSON: OHLC candles + common indicator basket + strategy indicators
        |
        v
Ask Gemini -> { action, order_type, entry_price, stop_loss, take_profit, confidence, reason }
        |
        v
Validate against broker stop/freeze levels, size the lot, send the order
        |
        v
Position opens (market fill or pending order triggered)
        |
        v
Momentum Gate watches profit-in-ATR-units; each time it crosses the next
ratcheted threshold it asks Gemini again:
{ action: HOLD | MOVE_SL | MOVE_TP | TRAIL_SL | CLOSE | CLOSE_PARTIAL, ... }
```

The strategies never decide direction/entry/SL/TP themselves — they only
decide **when** it's worth asking the AI. All trading decisions and all
trade-management decisions come back from Gemini, constrained by a strict
JSON response schema (`responseSchema` / `responseMimeType: application/json`)
so replies are always machine-parseable.

## The 10 independent strategies

| # | Name | Gate condition | Default timeframe |
|---|------|-----------------|--------------------|
| 1 | Trend EMA | EMA(fast)/EMA(slow) cross confirmed by ADX trend strength | H1 |
| 2 | Bollinger + RSI | Price tags outer Bollinger band while RSI is overbought/oversold | M15 |
| 3 | Donchian Breakout | Close breaks the N-bar high/low channel on above-average volume | H1 |
| 4 | MACD Momentum | MACD/signal cross with histogram sign flip | M30 |
| 5 | Stochastic Reversal | %K/%D cross inside overbought/oversold zone | M15 |
| 6 | Ichimoku Cloud | Tenkan/Kijun cross with price outside the Kumo cloud | H1 |
| 7 | ATR Volatility Breakout | Bar range expands beyond ATR × multiplier with a breakout close | M30 |
| 8 | Parabolic SAR Flip | SAR dot flips to the opposite side of price | H1 |
| 9 | CCI Extreme Reversal | CCI re-enters normal range from an extreme (±100) reading | M15 |
| 10 | Multi-Timeframe RSI | RSI crosses 50 on the working TF, confirmed by RSI bias on a higher TF | H1 (confirmed by H4) |

Every strategy has its own magic number (`InpMagicBase + strategy id`), own
cooldown, own indicator handles, and can be enabled/disabled independently
via its `InpSx_Enable` input.

## Project layout

```
MQL5/
  Experts/GeminiAI_EA/GeminiAI_EA.mq5     Main EA (inputs, event handlers, wiring)
  Include/GeminiAI/
    Json.mqh                              Minimal dependency-free JSON parser/writer
    GeminiClient.mqh                      Gemini REST client (WebRequest + schema + parsing)
    MarketSnapshot.mqh                    Builds the OHLC + indicator JSON sent to the AI
    TradeManager.mqh                      Order validation, sizing, sending, modify/close
    StrategyBase.mqh                      Abstract base every strategy derives from
    MomentumGate.mqh                      Post-entry management gate (ATR ratchet -> AI call)
    Strategies/Strategy01..10_*.mqh       The 10 independent gating strategies
```

## Setup

1. **Copy files**: In MT5, go to *File > Open Data Folder*, then copy the
   `MQL5/Experts/GeminiAI_EA` and `MQL5/Include/GeminiAI` folders from this
   repo into the corresponding `MQL5/Experts` and `MQL5/Include` folders of
   your terminal's data folder.
2. **Compile**: Open `GeminiAI_EA.mq5` in MetaEditor and press F7. Fix any
   path issues if your data folder structure differs.
3. **Whitelist the API endpoint**: In MT5, *Tools > Options > Expert
   Advisors*, enable "Allow WebRequest for listed URL" and add:
   `https://generativelanguage.googleapis.com`
   The EA will refuse to place any trade and log errors until this is done.
4. **Get a Gemini API key** from Google AI Studio and paste it into the
   `InpApiKey` input when attaching the EA to a chart.
5. **Attach the EA** to any chart (each strategy sets its own symbol from
   the chart and its own timeframe from its inputs — the chart's own
   timeframe does not matter). Enable AlgoTrading.
6. **Tune risk**: set `InpFixedLot` or `InpRiskPercent`, `InpMaxTotalPositions`,
   `InpMinConfidence`, and the momentum-gate thresholds
   (`InpMomentumStartATR`, `InpMomentumStepATR`, `InpManageCooldownSec`).
7. **Test on a demo account first.** AI-generated trade decisions can be
   wrong; this EA can lose money. Start with a small `InpFixedLot` /
   `InpRiskPercent` and monitor the Experts log closely.

## Notes & limitations

- `WebRequest` is a blocking (synchronous) call — a slow or unreachable
  Gemini endpoint will stall `OnTick`/`OnTimer` for up to `InpApiTimeoutMs`.
  Run on a stable VPS with reliable outbound HTTPS.
- Strategy Tester support for `WebRequest` varies by MT5 build/broker;
  forward-test on a demo account rather than relying on backtests.
- Every AI entry decision is validated/repaired against the broker's
  minimum stop/freeze distance before an order is sent, and trades below
  `InpMinConfidence` are skipped — but the EA still trusts Gemini's price
  levels, so keep risk sizing conservative.
