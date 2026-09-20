# SingleAnchor vNext Strategy Specification

## 1. Strategy summary

SingleAnchor trades one basket around one fixed anchor price.

For each basket:

- one anchor is created;
- one fixed upper level and one fixed lower level are calculated from that anchor;
- the first trade opens when price reaches either level;
- after the first trade, entries must alternate strictly between BUY and SELL;
- trades 1 through 4 use the original arithmetic lot progression;
- from trade 5 onward, arithmetic sizing stops and a hard fixed breakeven ceiling controls every new lot;
- once hard-BE mode starts, breakeven is not allowed to drift beyond the configured ceiling;
- the whole basket is managed and closed as one unit using escape, fixed take-profit, or basket trailing.

The strategy is intended to let ordinary short baskets behave normally, while forcing long-lived baskets to keep their recovery breakeven within a fixed distance from the original anchor.

---

## 2. Basket anchor and fixed grid levels

When no basket is active, create the basket anchor from the current midpoint:

[
A = rac{Bid + Ask}{2}
]

where:

- (A) = basket anchor price;
- `Bid` = current bid price;
- `Ask` = current ask price.

Calculate the grid step distance:

[
S = A 	imes rac{P}{100}
]

where:

- (S) = grid step distance in price units;
- (A) = basket anchor price;
- (P) = configured grid-step percentage of the anchor.

Then calculate the two fixed entry levels:

[
Upper = A + S
]

[
Lower = A - S
]

where:

- `Upper` = fixed upper entry level;
- `Lower` = fixed lower entry level;
- (A) = basket anchor price;
- (S) = grid step distance.

### Plain English

Each basket gets one anchor and two fixed boundaries. Those three prices do not move while the basket remains open.

---

## 3. Entry rules

A BUY entry is triggered when:

[
Ask ge Upper
]

where:

- `Ask` = current ask price;
- `Upper` = fixed upper basket level.

A SELL entry is triggered when:

[
Bid le Lower
]

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

A BUY cannot directly follow a BUY, and a SELL cannot directly follow a SELL.

### Plain English

The basket grows only when price moves back and forth between the same two fixed boundaries.

---

## 4. Trades 1-4: normal arithmetic sizing

For the first four trades:

[
Q_n = B 	imes n
]

where:

- (Q_n) = requested lot size for trade number (n);
- (B) = configured base lot size;
- (n) = trade number in the basket, starting from 1.

Example with (B = 0.01) lots:

```text
Trade 1 = 0.01
Trade 2 = 0.02
Trade 3 = 0.03
Trade 4 = 0.04
```

The requested lot is normalized upward as needed to a valid broker volume step.

### Plain English

Normal baskets keep the simple increasing lot sequence for the first four trades.

---

## 5. Hard-BE mode starts at trade 5

Define:

```text
Nnormal = 4
```

where:

- `Nnormal` = number of trades that use arithmetic sizing.

If trade 5 is required, hard-BE mode becomes active for the remainder of that basket.

From trade 5 onward:

- arithmetic sizing is no longer used;
- every new lot is calculated from the hard breakeven target;
- the hard-BE rule remains active until the basket closes;
- no intentional BE drift beyond the ceiling is permitted.

### Plain English

Reaching trade 5 means the basket has entered the tail. From that point, lot size is determined by where basket breakeven must be, not by trade number.

---

## 6. Hard fixed breakeven ceiling

Let (C) be the configured maximum breakeven distance from the original anchor, expressed as a percentage.

For an upward recovery target:

[
T_{up} = A 	imes left(1 + rac{C}{100}ight)
]

where:

- (T_{up}) = maximum permitted upper-side basket breakeven price;
- (A) = original basket anchor price;
- (C) = configured hard-BE ceiling percentage.

For a downward recovery target:

[
T_{down} = A 	imes left(1 - rac{C}{100}ight)
]

where:

- (T_{down}) = maximum permitted lower-side basket breakeven price;
- (A) = original basket anchor price;
- (C) = configured hard-BE ceiling percentage.

Current research starting value:

```text
C ~= 4.478%
```

This value is a test/calibration parameter, not a permanently proven optimum.

### Which target applies

- if the next required tail trade is BUY, use (T_{up});
- if the next required tail trade is SELL, use (T_{down}).

### Plain English

Once tail mode starts, the strategy fixes the farthest acceptable recovery point relative to the original anchor. Every later order must be large enough to keep basket breakeven within that limit.

---

## 7. Tail lot calculation

For every trade from trade 5 onward, calculate the minimum lot required to make the full basket reach breakeven at or before the applicable hard target.

Conceptually:

[
Q_{BE} = rac{-PL_{existing}(T)}{PL_{1lot}(T)}
]

where:

- (Q_{BE}) = lot size required for the next tail order;
- (PL_{existing}(T)) = projected profit/loss of all already-open basket positions if price reaches target (T);
- (PL_{1lot}(T)) = projected profit/loss at target (T) contributed by one lot of the new required side;
- (T) = applicable hard target, either (T_{up}) or (T_{down});
- `PL` = profit/loss in account currency.

The formula is valid when (PL_{1lot}(T) > 0).

The requested next tail lot is:

[
Q_{next} = Q_{BE}
]

where:

- (Q_{next}) = requested lot size of the next tail order;
- (Q_{BE}) = lot size required to satisfy the hard-BE target.

The calculation should use executable basket economics, including the configured bid/ask side, spread, commission, slippage, swap/financing, and any other enabled execution costs.

### Plain English

There is no fixed tail sequence such as 0.05, 0.06, 0.07. The strategy calculates exactly how much volume is needed to pull basket breakeven back to the hard limit.

---

## 8. Volume normalization under a hard ceiling

Tail volume must never be rounded downward if that would violate the BE ceiling.

Let:

- (Q_{BE}) = mathematically required lot size;
- (V_{step}) = broker volume step;
- (Q_{normalized}) = actual broker-valid lot size.

Use upward normalization:

[
Q_{normalized}
=
leftlceil
rac{Q_{BE}}{V_{step}}
ightceil
	imes V_{step}
]

where:

- (lceil x ceil) = round (x) upward to the next integer;
- (Q_{BE}) = exact required lot size;
- (V_{step}) = minimum broker lot increment;
- (Q_{normalized}) = final broker-valid lot size.

After normalization, recalculate projected basket P/L at the target and verify that the hard-BE condition still holds.

### Hard-BE acceptance condition

At the applicable target (T):

[
PL_{basket}(T) ge 0
]

where:

- (PL_{basket}(T)) = projected executable profit/loss of the full basket after the new order at target (T);
- (T) = applicable upper or lower hard-BE target.

If this condition is not satisfied, the lot must be increased to the next valid broker volume step and checked again.

### Plain English

Because the BE limit is hard, lot rounding is always conservative. If 0.1234 lots are required and the broker trades in 0.01 steps, 0.13 is used, not 0.12.

---

## 9. Basket profit used for exits

Raw basket profit is the combined profit of all positions in the basket, including swap/financing where applicable.

If an optional commission buffer is enabled:

[
Profit = RawProfit - CommissionBuffer
]

where:

- `Profit` = basket profit used for exit decisions;
- `RawProfit` = current combined basket profit before the optional buffer;
- `CommissionBuffer` = configured estimated commission deduction.

### Plain English

Escape, take-profit, and trailing decisions are based on the basket as a whole, not on individual positions.

---

## 10. Net exposure and step-money calculation

Calculate signed net exposure:

[
N = BuyLots - SellLots
]

where:

- (N) = signed net basket exposure in lots;
- `BuyLots` = total open BUY volume;
- `SellLots` = total open SELL volume.

When net exposure is meaningfully non-zero:

[
E = |N|
]

where:

- (E) = exit-sensitivity lot size;
- (N) = signed net exposure;
- (|N|) = absolute value of net exposure.

If the basket is effectively net-flat, use:

[
E = MinLot
]

where:

- (E) = exit-sensitivity lot size;
- `MinLot` = smallest currently open position size.

Then calculate one strategy step in account currency:

[
M_{step} = S 	imes E 	imes V
]

where:

- (M_{step}) = money value of one strategy step;
- (S) = fixed grid-step distance in price units;
- (E) = exit-sensitivity lot size;
- (V) = money value of a one-price-unit move for one lot.

### Plain English

All basket exit thresholds scale with the basket's current directional exposure.

---

## 11. Escape exit

Default configuration:

```text
Escape enabled = true
Escape profit units = 0.05
Minimum open positions = 2
```

Calculate the escape threshold:

[
M_{escape} = U_{escape} 	imes M_{step}
]

where:

- (M_{escape}) = basket profit required for an escape close;
- (U_{escape}) = configured escape-profit units;
- (M_{step}) = current money value of one strategy step.

Close the whole basket when:

[
Profit ge M_{escape}
]

where:

- `Profit` = current basket profit;
- (M_{escape}) = escape threshold.

Escape applies only when the basket has at least two open positions.

### Plain English

After the basket has more than one trade, a small positive recovery is enough to exit the whole basket.

---

## 12. Fixed basket take-profit

Default configuration:

```text
Fixed TP units = 0.0
```

A value of 0 disables fixed TP.

When enabled:

[
M_{TP} = U_{TP} 	imes M_{step}
]

where:

- (M_{TP}) = money profit required for fixed take-profit;
- (U_{TP}) = configured fixed-TP units;
- (M_{step}) = current money value of one strategy step.

Close the whole basket when:

[
Profit ge M_{TP}
]

where:

- `Profit` = current basket profit;
- (M_{TP}) = fixed take-profit threshold.

### Plain English

Fixed TP closes the complete basket when total basket profit reaches the configured target.

---

## 13. Basket trailing profit

Default configuration:

```text
Trailing enabled = true
Trailing activation units = 0.50
Trailing drop units = 0.25
```

Calculate the trailing activation threshold:

[
M_{activate} = U_{activate} 	imes M_{step}
]

where:

- (M_{activate}) = basket profit required to activate trailing;
- (U_{activate}) = configured trailing-activation units;
- (M_{step}) = current money value of one strategy step.

Trailing activates when:

[
Profit ge M_{activate}
]

where:

- `Profit` = current basket profit;
- (M_{activate}) = trailing activation threshold.

At activation:

```text
PeakProfit = current Profit
```

Whenever basket profit reaches a new high:

```text
PeakProfit = new higher Profit
```

Calculate the permitted trailing drop:

[
M_{drop} = U_{drop} 	imes M_{step}
]

where:

- (M_{drop}) = permitted decline from peak basket profit;
- (U_{drop}) = configured trailing-drop units;
- (M_{step}) = current money value of one strategy step.

Close the whole basket when:

[
Profit le PeakProfit - M_{drop}
]

where:

- `Profit` = current basket profit;
- `PeakProfit` = highest basket profit observed since trailing activated;
- (M_{drop}) = allowed decline from the peak.

Opening another grid trade does not by itself reset trailing state. Trailing state is reset when the basket is closed/reset.

### Plain English

After the basket earns enough profit, trailing begins protecting that profit. It remembers the best basket profit reached and closes when profit falls far enough from that peak.

---

## 14. Exit priority

On every tick with an active basket, evaluate in this order:

```text
1. Escape
2. Fixed basket take-profit
3. Basket trailing
4. If no exit closes the basket, evaluate the next grid entry
```

If any exit closes the basket successfully, stop processing that basket for the tick.

### Plain English

The strategy always asks whether it should close the basket before it considers adding another position.

---

## 15. Basket lifecycle

When an exit condition closes the basket:

- close all basket positions;
- reset basket state;
- reset trailing state;
- reset trade sequence state.

A new basket then starts from a fresh anchor when normal basket initialization occurs again.

### Plain English

All open trades belong to one basket. The basket is managed and closed as one unit.

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
Wait for first boundary
        |
        v
Open first BUY or SELL
        |
        v
Strictly alternate sides
        |
        +-- Trades 1-4
        |      arithmetic sizing
        |      base lot x trade number
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

The key parameters to expose for testing are:

```text
StepPercent
    grid-step percentage of anchor

BaseLot
    lot size used to build trades 1-4

Nnormal
    number of arithmetic-sized trades
    current value: 4

HardBECeilingPercent
    maximum permitted BE distance from original anchor
    current research starting value: approximately 4.478%

EscapeProfitUnits
    current default: 0.05

FixedTPUnits
    current default: 0.0 (disabled)

TrailingActivationUnits
    current default: 0.50

TrailingDropUnits
    current default: 0.25
```

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

The grid geometry and basket exit logic remain unchanged when tail mode activates. Only the lot-sizing rule changes.
