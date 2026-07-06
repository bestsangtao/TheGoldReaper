# GeminiAI_EA — MT5 Expert Advisor powered by Google Gemini

An MT5 (MQL5) Expert Advisor that uses the Google Gemini API as its trading
decision engine. It ships with **10 fully independent gating strategies**,
each watching its own indicator(s) **and** a higher-timeframe trend filter —
every strategy is multi-timeframe by construction, not just single-TF pattern
matching. When a strategy's condition fires (own-TF indicator signal AND
higher-TF confirmation agree), the EA packages recent OHLC candles + a full
indicator basket for **both timeframes** + account context into JSON and asks
Gemini for a concrete trade decision (BUY/SELL, order type, entry, stop loss,
take profit) — Gemini is explicitly instructed to cross-check both timeframes
before deciding. Once the resulting position is open, a separate
**momentum-based management gate** periodically re-asks Gemini (again with
both-timeframe data) how to manage the trade (trail the stop, lock in profit,
move SL/TP, close early, partial close).

## How it works

```
Strategy gate fires:
  own-timeframe indicator signal (e.g. EMA cross, MACD cross, breakout...)
  AND higher-timeframe EMA trend filter agrees (multi-timeframe gating)
        |
        v
Build JSON: OHLC + full indicator basket for the WORKING timeframe
          + OHLC + full indicator basket for the HIGHER timeframe
        |
        v
Ask Gemini (instructed to cross-check both timeframes) ->
  { decision_mode, action, entry/zone, stop_loss, take_profit, confidence, reason }
        |
        +--> decision_mode = ENTER_NOW: validate vs broker stops, size lot, send order
        |
        +--> decision_mode = WATCH: arm a real-time plan (entry zone + invalidation
        |      + expiry). The EA then watches price EVERY TICK, like a human with an
        |      alert set, and enters with a market order the moment price reaches the
        |      zone - or cancels if price hits invalidation / the higher-TF trend flips
        |      / the plan expires. No extra API call happens at the trigger moment.
        |
        v
Position opens (market fill, pending order triggered, or watch-plan trigger)
        |
        v
Momentum Gate re-checks every tick per open position:
  profit-in-ATR ratchet reached AND Momentum(N) indicator confirms it
  OR higher-timeframe EMA trend flips against the position (overrides ratchet)
        |
        v
Ask Gemini again (same multi-timeframe data + trigger_reason) ->
{ action: HOLD | MOVE_SL | MOVE_TP | TRAIL_SL | CLOSE | CLOSE_PARTIAL, ... }
```

The strategies never decide direction/entry/SL/TP themselves — they only
decide **when** it's worth asking the AI, using their own indicator(s) plus
multi-timeframe confirmation. All trading decisions and all trade-management
decisions come back from Gemini, constrained by a strict JSON response schema
(`responseSchema` / `responseMimeType: application/json`) so replies are
always machine-parseable.

## Conversation memory (so the AI "remembers")

The Gemini `generateContent` endpoint is **stateless** — each call is a fresh
model instance that only "knows" what the request resends. (The web chat feels
like it remembers only because the browser resends the whole thread each time.)
Rather than scrape the web UI — which breaks the JSON schema, violates Google's
terms, and is fragile — the EA reproduces that behavior the correct way: it
keeps a rolling conversation history and replays it in the API's multi-turn
`contents` array, so the model has genuine continuity across calls.

Two independent memory scopes:

- **Per-strategy entry memory** (`InpEntryMemoryTurns`, default 3): each
  strategy remembers its own recent entry decisions, so the AI stays
  consistent instead of flip-flopping between calls.
- **Per-position management memory** (`InpManageMemoryTurns`, default 6): every
  open position gets its own conversation thread from open to close, so at each
  management checkpoint the AI recalls what it already did earlier for *that
  same position* (e.g. it won't undo a break-even stop it just set). The thread
  is freed automatically when the position closes.

To keep token cost bounded, history stores the model's past replies in full but
only a **compact summary** of each past request (not the full OHLC snapshot);
the current turn always carries the complete multi-timeframe data. Set either
input to `0` to return to fully stateless calls (useful for A/B comparison).

## Real-time Watch Plans (waiting for entry like a human)

A human trader rarely enters the instant a signal appears — they analyse the
chart, decide "I'll buy on a pullback to this level", set an alert, and **watch
price in real time**, entering when it arrives (or walking away if the setup
breaks first). The EA can do the same without hammering the API.

The AI cannot be called every tick — `WebRequest` is blocking and would exhaust
quota — and evaluating indicators mid-candle "repaints" (signals flicker and
vanish by bar close). So the split is: **the AI thinks once, the EA watches
continuously.** When a strategy fires on a closed bar, Gemini returns a
`decision_mode`:

- **`ENTER_NOW`** — the setup is ready; enter immediately (market, or a
  limit/stop pending order).
- **`WATCH`** — the idea is good but the ideal entry is at a price not reached
  yet. The AI returns an **entry zone** `[watch_entry_low, watch_entry_high]`, an
  **`invalidate_price`**, and an optional `expiry_minutes`. The EA arms the plan
  and, on **every tick**, checks it locally (no API call): it enters with a
  market order the moment price reaches the zone, or cancels the plan if price
  passes `invalidate_price` first, if the higher-timeframe EMA trend flips
  against the trade, or when the plan expires.
- **`NONE`** — no trade.

Because the decision was already made when the plan was armed, the tick-by-tick
watching is cheap and instant — the AI is the analyst, the EA is the alert that
never blinks. There is at most one armed plan per strategy (a newer plan
replaces the old one), and a triggered plan flows into the same momentum-gate
management as any other position. Toggle the whole feature with
`InpEnableWatchPlans`; `InpWatchDefaultExpiryMin` bounds how long a plan waits
if the AI doesn't set its own expiry.

## The 10 independent strategies

Every strategy checks its own-timeframe indicator condition **and** requires
the higher-timeframe EMA(fast)/EMA(slow) trend filter to agree with the
signal's direction before it fires (strategy 10 uses dual-timeframe RSI
directly instead of the shared EMA filter, since its own gate already is a
cross-timeframe check). The AI payload always contains OHLC + indicators for
both timeframes regardless of which mechanism gated the call.

| # | Name | Own-timeframe indicator condition | Working TF | Higher TF filter |
|---|------|-----------------------------------|-------------|-------------------|
| 1 | Trend EMA | EMA(fast)/EMA(slow) cross confirmed by ADX trend strength | H1 | H4 EMA50/200 |
| 2 | Bollinger + RSI | Price tags outer Bollinger band while RSI is overbought/oversold | M15 | H1 EMA50/200 |
| 3 | Donchian Breakout | Close breaks the N-bar high/low channel on above-average volume | H1 | H4 EMA50/200 |
| 4 | MACD Momentum | MACD/signal cross with histogram sign flip | M30 | H4 EMA50/200 |
| 5 | Stochastic Reversal | %K/%D cross inside overbought/oversold zone | M15 | H1 EMA50/200 |
| 6 | Ichimoku Cloud | Tenkan/Kijun cross with price outside the Kumo cloud | H1 | H4 EMA50/200 |
| 7 | ATR Volatility Breakout | Bar range expands beyond ATR × multiplier with a breakout close | M30 | H4 EMA50/200 |
| 8 | Parabolic SAR Flip | SAR dot flips to the opposite side of price | H1 | H4 EMA50/200 |
| 9 | CCI Extreme Reversal | CCI re-enters normal range from an extreme (±100) reading | M15 | H1 EMA50/200 |
| 10 | Multi-Timeframe RSI | RSI crosses 50 on the working TF, confirmed by RSI bias on the higher TF | H1 | H4 RSI (own dual-TF gate) |

Every strategy has its own magic number (`InpMagicBase + strategy id`), own
cooldown, own indicator handles, own higher-timeframe input (`InpSx_HigherTF`),
and can be enabled/disabled independently via its `InpSx_Enable` input. The
higher-timeframe EMA filter periods (`InpHtfEmaFast`/`InpHtfEmaSlow`) and how
many higher-TF candles are sent to the AI (`InpHtfBars`) are shared, global
inputs under "Multi-Timeframe Filter".

## Trade management trigger (Momentum Gate)

Once a position is open (market fill, or a pending limit/stop order that just
got triggered), it is registered with the Momentum Gate, which decides **when**
to call Gemini for management — using indicators and multi-timeframe data,
the same way entries are gated, not just a raw price distance:

1. **Profit ratchet + Momentum indicator confirmation.** Once floating profit
   reaches the next ATR-based ratchet level (`InpMomentumStartATR`, then
   `+ InpMomentumStepATR` for every subsequent check), the gate also requires
   a genuine `Momentum(InpMomentumPeriod)` indicator reading — `|Momentum-100|`
   must be at least `InpMomentumMinDeviation` — confirming the move is real
   momentum and not noise before Gemini is asked to manage the trade.
2. **Higher-timeframe trend flip (multi-timeframe override).** Independently
   of the ratchet, the gate re-evaluates the same higher-timeframe EMA
   fast/slow trend filter used for entries on every tick. If that trend flips
   against the position's direction, it immediately triggers a management call
   regardless of the ratchet level — an early warning the working timeframe
   hasn't caught up to yet.

Either trigger sends Gemini the same multi-timeframe OHLC + indicator snapshot
used for entries, plus a `position.trigger_reason` field explaining which of
the two fired (and the Momentum/HTF values behind it), so the AI can weigh a
trend-flip trigger more toward `CLOSE`/`CLOSE_PARTIAL` and a momentum-ratchet
trigger more toward trailing/locking in profit. Both mechanisms respect
`InpManageCooldownSec` so a position can't be re-queried faster than that.

## Project layout

```
MQL5/
  Experts/GeminiAI_EA/GeminiAI_EA.mq5     Main EA (inputs, event handlers, wiring)
  Include/GeminiAI/
    Json.mqh                              Minimal dependency-free JSON parser/writer
    Conversation.mqh                      Rolling multi-turn history (AI memory across calls)
    GeminiClient.mqh                      Gemini REST client (WebRequest + schema + parsing)
    MarketSnapshot.mqh                    Builds the OHLC + indicator JSON sent to the AI
    TradeManager.mqh                      Order validation, sizing, sending, modify/close
    StrategyBase.mqh                      Abstract base every strategy derives from
    MomentumGate.mqh                      Post-entry management gate (ATR ratchet -> AI call)
    WatchPlan.mqh                         Real-time watch-and-wait entry engine (tick-level)
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
