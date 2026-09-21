# SingleAnchor vNext Strategy Specification

## 1. Purpose and plain-English summary

SingleAnchor manages one basket around one fixed anchor price.

For each basket:

- create one anchor;
- create one fixed upper level and one fixed lower level around that anchor;
- open the first trade when price reaches one of those levels;
- after the first trade, BUY and SELL entries must alternate strictly;
- trades 1 through 4 use arithmetic lot sizing;
- trade 5 and every later trade use hard fixed-breakeven sizing;
- once hard-BE mode is active, breakeven is not allowed to drift beyond the configured ceiling;
- manage and close the whole basket as one unit using escape, fixed take-profit, or basket trailing.

The intent is simple: ordinary baskets keep the original early-trade behavior, while long-lived baskets switch to lot sizes calculated specifically to keep recovery breakeven within a fixed distance from the original anchor.

---

## 2. Anchor and fixed grid levels

When no basket is active, create the anchor from the current midpoint:

```text
A = (Bid + Ask) / 2
```

where:

- `A` = basket anchor price;
- `Bid` = current bid price;
- `Ask` = current ask price.

Calculate the grid-step distance:

```text
S = A * P / 100
```

where:

- `S` = grid-step distance in price units;
- `A` = basket anchor price;
- `P` = configured grid-step percentage of the anchor.

Calculate the fixed upper and lower levels:

```text
Upper = A + S
Lower = A - S
```

where:

- `Upper` = fixed upper entry level;
- `Lower` = fixed lower entry level;
- `A` = basket anchor price;
- `S` = grid-step distance.

### Plain English

Each basket gets one anchor and two boundaries. The anchor, upper level, and lower level stay fixed until that basket closes.

---

## 3. Entry rules

Open a BUY when:

```text
Ask >= Upper
```

where:

- `Ask` = current ask price;
- `Upper` = fixed upper basket level.

Open a SELL when:

```text
Bid <= Lower
```

where:

- `Bid` = current bid price;
- `Lower` = fixed lower basket level.

After the first entry, sides must alternate strictly:

```text
BUY -> SELL -> BUY -> SELL -> ...
```

or:

```text
SELL -> BUY -> SELL -> BUY -> ...
```

A BUY cannot directly follow a BUY. A SELL cannot directly follow a SELL.

After the first entry, strict alternation has absolute priority. Only the opposite side of the previous trade is eligible:

```text
previous trade BUY  -> evaluate only the SELL condition
previous trade SELL -> evaluate only the BUY condition
```

Even if a later quote also satisfies the other numerical boundary inequality, that other side cannot open; the opposite side of the previous trade is the only eligible side.

Before the first entry the basket is empty and has no previous side. If one quote satisfies both rules at the same time:

```text
Ask >= Upper
AND
Bid <= Lower
```

the basket must not start on that quote:

- no BUY priority;
- no SELL priority;
- no double entry;
- a single quote does not establish which side crossed first.

The basket stays with zero trades and waits for a later quote that satisfies exactly one rule and therefore determines the first side unambiguously. Skipping such a quote is a validity condition for starting the basket, not a trade decision, and it never ends the run.

### Plain English

The basket grows only when price moves back and forth between the same two fixed boundaries. If one quote is wide enough to touch both boundaries at once, the basket simply does not start on that quote.

---

## 4. Trades 1 through 4: arithmetic lot sizing

For the first four trades:

```text
Q_n = B * n
```

where:

- `Q_n` = requested lot size for trade number `n`;
- `B` = configured base lot size;
- `n` = trade number inside the basket, starting from 1.

Example when `B = 0.01` lots:

```text
Trade 1 = 0.01
Trade 2 = 0.02
Trade 3 = 0.03
Trade 4 = 0.04
```

Normalize the requested lot to a valid broker volume step.

### Plain English

The first four trades use the simple increasing sequence based on trade number.

---

## 5. Hard-BE mode starts at trade 5

Define:

```text
Nnormal = 4
```

where:

- `Nnormal` = number of trades that use arithmetic lot sizing.

If trade 5 is required, hard-BE mode becomes active for the remainder of that basket.

From trade 5 onward:

- arithmetic lot sizing stops;
- every new lot is calculated from the hard breakeven target;
- hard-BE mode remains active until the basket closes;
- no intentional BE drift beyond the configured ceiling is permitted.

### Plain English

Reaching trade 5 means the basket has entered the tail. From then on, lot size is determined by where basket breakeven must be, not by trade number.

---

## 6. Hard fixed breakeven ceiling

Basket breakeven (BE) means:

> the market level at which every currently open BUY and SELL position is closed at the same instant and the total executable basket P/L is exactly zero.

Let `C` be the configured maximum BE distance from the original anchor, expressed as a percentage.

For an upper basket recovery:

```text
T_up = A * (1 + C / 100)

Bid = T_up
```

where:

- `T_up` = maximum permitted upper basket-BE **Bid** level;
- `A` = original basket anchor price;
- `C` = configured hard-BE ceiling percentage;
- `Bid = T_up` = the hard-BE market level: the upper basket BE may not be above it.

At that instant the complete basket closes: BUY positions close using the Bid-side executable price at `Bid = T_up`, and SELL positions close at the same instant using the Ask-side executable price of that same quote.

For a downward recovery:

```text
T_down = A * (1 - C / 100)

Ask = T_down
```

where:

- `T_down` = maximum permitted lower basket-BE **Ask** level;
- `Ask = T_down` = the hard-BE market level: the lower basket BE may not be below it.

At that instant the complete basket closes: SELL positions close using the Ask-side executable price at `Ask = T_down`, and BUY positions close at the same instant using the Bid-side executable price of that same quote.

The hard-BE target itself is exactly `T_up` on the Bid or `T_down` on the Ask. Spread, slippage and commission are execution economics used to calculate the executable P/L of that simultaneous basket closure; they do not shift or redefine the target.

For forward projection under a configured target spread `W` (used only to reconstruct the opposite quote side of the projected simultaneous closure):

```text
upper recovery projection: Bid = T_up, Ask = T_up + W
lower recovery projection: Ask = T_down, Bid = T_down - W
```

`W` is never added to or subtracted from the BE level. `T_up + W` and `T_down - W` are projected quote sides, not BE levels.

Current research starting value:

```text
C ~= 4.478%
```

This is a calibration starting value, not a permanently proven optimum.

Target selection:

- if the next required tail trade is BUY, use `T_up` (upper recovery, Bid side);
- if the next required tail trade is SELL, use `T_down` (lower recovery, Ask side).

### Plain English

Once tail mode starts, the strategy fixes the farthest acceptable recovery point from the original anchor. Every later order must be large enough that the basket's true zero-loss breakeven stays at or inside that limit.

---

## 7. Tail lot sizing: hard-BE requirement

For trade 5 and every later trade, choose the smallest new lot that makes the full basket break even at or before the applicable hard target.

The authoritative requirement is:

```text
PL_after(T, Q) >= 0
```

where:

- `PL_after(T, Q)` = projected executable profit/loss of the complete basket at target price `T` after adding a new order of size `Q`;
- `T` = applicable hard target, either `T_up` or `T_down`;
- `Q` = candidate lot size for the new required BUY or SELL order.

The strategy must choose the smallest valid `Q` that satisfies that condition.

When projected P/L is linear in the new lot size, the required lot can be calculated as:

```text
Q_BE = -PL_existing(T) / PL_1lot(T)
```

where:

- `Q_BE` = mathematically required lot size for the next tail order;
- `PL_existing(T)` = projected executable profit/loss of all already-open basket positions at target price `T`;
- `PL_1lot(T)` = projected executable profit/loss at `T` contributed by one lot of the new required side;
- `T` = applicable hard target;
- `PL` = profit/loss in account currency.

This ratio is valid only when:

```text
PL_1lot(T) > 0
```

where:

- `PL_1lot(T)` = profit/loss contribution at the target from one lot of the proposed new side.

The ratio is a convenience, not the rule. When `PL_1lot(T) <= 0` the primary requirement (`PL_after(T, Q) >= 0`, smallest valid `Q`) still governs directly: if the basket already projects at or inside the ceiling, the minimum broker lot is the smallest valid positive order; if the minimum lot makes `PL_after` negative, no larger lot can help, because the marginal contribution of the required side is not positive, so the sizing is infeasible. This is a consequence of the primary rule, not a separate strategy decision.

The tail calculation must use executable basket economics: the configured target spread `W` reconstructs the opposite quote side at the projected simultaneous close, and configured slippage and commission are applied to the executable close of every position. The target level itself is never shifted by them.

Financing (swap) is not supported in this revision: the value of a basket's projected P/L at the hard target can change after the entry when financing accrues, so a strategy-qualified run requires a zero financing configuration (see sections 9 and 17).

### Plain English

There is no fixed tail sequence such as 0.05, 0.06, 0.07. Each tail order is calculated specifically to pull the basket's recovery point back to the hard BE limit.

---

## 8. Volume normalization under the hard ceiling

Let:

- `Q_BE` = mathematically required tail lot;
- `V_step` = broker volume step;
- `Q_normalized` = actual broker-valid tail lot.

Round upward:

```text
Q_normalized = ceil(Q_BE / V_step) * V_step
```

where:

- `ceil(x)` = round `x` upward to the next integer;
- `Q_BE` = exact required lot size;
- `V_step` = minimum broker lot increment;
- `Q_normalized` = final broker-valid lot size.

After normalization, recalculate:

```text
PL_after(T, Q_normalized) >= 0
```

where:

- `PL_after(T, Q_normalized)` = projected executable basket profit/loss at target `T` using the normalized lot;
- `T` = applicable hard target;
- `Q_normalized` = actual broker-valid lot.

If the condition is not satisfied, increase the lot to the next valid volume step and check again.

There is no fallback to a smaller lot that permits BE drift beyond the hard ceiling.

If broker constraints make the required hard-BE lot impossible to place, that is an infeasible hard-BE condition and must be surfaced explicitly; it must not be silently converted into BE drift.

### Plain English

Because the BE limit is hard, volume rounding must be conservative. If 0.1234 lots are required and the broker allows 0.01-lot increments, use 0.13, not 0.12.

---

## 9. Basket profit used for exits

Raw basket profit is the combined current profit of all positions in the basket.

Financing (swap) is not supported in this revision: only a zero financing configuration can produce a strategy-qualified run (sections 7 and 17).

If an optional commission buffer is enabled:

```text
Profit = RawProfit - CommissionBuffer
```

where:

- `Profit` = basket profit used for exit decisions;
- `RawProfit` = combined basket profit before the optional commission buffer;
- `CommissionBuffer` = configured estimated commission deduction.

### Plain English

Escape, take-profit, and trailing decisions are based on the basket as a whole, not on individual positions.

---

## 10. Net exposure and step-money calculation

Calculate signed net exposure:

```text
N = BuyLots - SellLots
```

where:

- `N` = signed net basket exposure in lots;
- `BuyLots` = total open BUY volume;
- `SellLots` = total open SELL volume.

When net exposure is meaningfully non-zero:

```text
E = abs(N)
```

where:

- `E` = exit-sensitivity lot size;
- `N` = signed net basket exposure;
- `abs(N)` = absolute value of `N`.

If the basket is effectively net-flat:

```text
E = MinLot
```

where:

- `E` = exit-sensitivity lot size;
- `MinLot` = smallest currently open position size.

Calculate one strategy step in account currency:

```text
M_step = S * E * V
```

where:

- `M_step` = money value of one strategy step;
- `S` = fixed grid-step distance in price units;
- `E` = exit-sensitivity lot size;
- `V` = money value of a one-price-unit move for one lot.

### Plain English

The basket's exit thresholds scale with its current directional exposure.

---

## 11. Escape exit

Default configuration:

```text
Escape enabled = true
Escape profit units = 0.05
Minimum open positions = 2
```

Calculate the escape threshold:

```text
M_escape = U_escape * M_step
```

where:

- `M_escape` = basket profit required for an escape close;
- `U_escape` = configured escape-profit units;
- `M_step` = current money value of one strategy step.

Close the whole basket when:

```text
Profit >= M_escape
```

where:

- `Profit` = current basket profit;
- `M_escape` = escape threshold.

Escape applies only when the basket has at least two open positions. The minimum-open-positions input may be raised above two for research, but it must never be configured below two.

### Plain English

Once the basket contains multiple trades, a small positive recovery can be enough to close the complete basket.

---

## 12. Fixed basket take-profit

Default configuration:

```text
Fixed TP units = 0.0
```

A value of 0 disables fixed TP.

When fixed TP is enabled:

```text
M_TP = U_TP * M_step
```

where:

- `M_TP` = money profit required for fixed take-profit;
- `U_TP` = configured fixed-TP units;
- `M_step` = current money value of one strategy step.

Close the whole basket when:

```text
Profit >= M_TP
```

where:

- `Profit` = current basket profit;
- `M_TP` = fixed take-profit threshold.

### Plain English

Fixed TP closes the complete basket once total basket profit reaches the configured target.

---

## 13. Basket trailing profit

Default configuration:

```text
Trailing enabled = true
Trailing activation units = 0.50
Trailing drop units = 0.25
```

Calculate the trailing activation threshold:

```text
M_activate = U_activate * M_step
```

where:

- `M_activate` = basket profit required to activate trailing;
- `U_activate` = configured trailing-activation units;
- `M_step` = current money value of one strategy step.

Trailing activates when:

```text
Profit >= M_activate
```

where:

- `Profit` = current basket profit;
- `M_activate` = trailing activation threshold.

At activation:

```text
PeakProfit = current Profit
```

where:

- `PeakProfit` = highest basket profit recorded since trailing activation;
- `Profit` = current basket profit.

Whenever basket profit reaches a new high:

```text
PeakProfit = new higher Profit
```

Calculate the permitted trailing drop:

```text
M_drop = U_drop * M_step
```

where:

- `M_drop` = permitted decline from peak basket profit;
- `U_drop` = configured trailing-drop units;
- `M_step` = current money value of one strategy step.

Close the whole basket when:

```text
Profit <= PeakProfit - M_drop
```

where:

- `Profit` = current basket profit;
- `PeakProfit` = highest basket profit observed since trailing activated;
- `M_drop` = allowed decline from that peak.

Opening another grid trade does not by itself reset trailing state. Trailing state resets when the basket closes/resets.

### Plain English

After the basket earns enough profit, trailing begins protecting that profit. It remembers the best basket profit reached and closes the basket when profit falls far enough from that peak.

---

## 14. Exit priority

On every tick with an active basket, evaluate in this order:

```text
1. Escape
2. Fixed basket take-profit
3. Basket trailing
4. If no exit closes the basket, evaluate the next grid entry
```

If any exit closes the basket successfully, stop processing that basket for the current tick. Do not initialize a replacement basket on the same tick.

### Plain English

The strategy always asks whether it should close the basket before it considers adding another position.

---

## 15. Basket lifecycle

When an exit closes the basket:

- close all basket positions;
- reset basket state;
- reset trailing state;
- reset trade-sequence state.

A later tick may initialize a new basket from a fresh anchor.

At the end of historical data, an open basket is marked to market rather than force-closed.

### Plain English

All trades belong to one basket. The basket is managed and closed as one unit. A finished basket does not immediately restart on the same market tick.

---

## 16. Strategy state machine

```text
NO ACTIVE BASKET
        |
        v
Create fixed anchor
        |
        +-- Upper = anchor + step
        +-- Lower = anchor - step
        |
        v
Wait for a usable first boundary
        |
        +-- exactly one boundary satisfied
        |      open the first BUY or SELL
        |
        +-- both boundaries satisfied on the same quote
               open nothing, stay empty, wait for a later quote
        |
        v
Strictly alternate sides
        |
        +-- only the opposite side of the previous trade is eligible
        |
        +-- Trades 1-4
        |      arithmetic sizing
        |      base lot * trade number
        |
        +-- Trade 5+
               HARD-BE MODE
               calculate required lot
               keep BE within fixed ceiling
               NO BE DRIFT
        |
        v
On every tick
        |
        +-- Escape?
        +-- Fixed TP?
        +-- Trailing close?
        |
        +-- otherwise evaluate next alternating entry
        |
        v
Close whole basket
        |
        v
Reset basket state
```

---

## 17. Principal research parameters

Expose at least these strategy parameters:

```text
StepPercent
    grid-step percentage of anchor

BaseLot
    base lot used to construct trades 1-4

Nnormal
    number of arithmetic-sized trades
    current value: 4

HardBECeilingPercent
    maximum permitted BE distance from original anchor
    T_up is the maximum upper BE Bid level, T_down the maximum lower BE Ask level
    current research starting value: approximately 4.478%

EscapeProfitUnits
    current default: 0.05

EscapeMinimumOpenPositions
    at least 2; the default is 2

FixedTPUnits
    current default: 0.0 (disabled)

TrailingActivationUnits
    current default: 0.50

TrailingDropUnits
    current default: 0.25
```

Execution-cost, commission-buffer, volume-step, and instrument money-value settings must also remain explicit inputs rather than hidden assumptions. The hard-BE projection uses a configured target spread to reconstruct the opposite quote side of the projected simultaneous basket closure (section 6); the target level itself is `Bid = T_up` or `Ask = T_down`.

Financing settings must be explicit inputs and must be zero for a strategy-qualified run. A non-zero financing configuration is rejected until continuous financing behaviour is specified: financing accrued after a tail entry can move the projected P/L at the hard target without any re-verification, which would violate the hard ceiling.

---

## 18. Core design rule

The strategy has two sizing regimes:

```text
NORMAL BASKET
Trades 1-4
-> arithmetic sizing

TAIL BASKET
Trade 5 onward
-> hard fixed-BE sizing
-> no BE drift beyond the configured ceiling
```

The grid geometry and basket exit logic do not change when tail mode activates. Only the lot-sizing rule changes.
