using System;
using System.Collections.Generic;
using System.Globalization;

namespace MarketLab.SingleAnchor
{
    /// <summary>
    /// Every input of the SingleAnchor vNext strategy (specification section 17: the principal
    /// research parameters plus the execution-cost, commission-buffer, volume-step and
    /// instrument money-value settings, which "must remain explicit inputs rather than hidden
    /// assumptions"). Defaults are the specification's defaults where it states one. Four inputs
    /// have no specified value and must be set: <see cref="StepPercent"/>, <see cref="BaseLot"/>,
    /// <see cref="PointValuePerLot"/> and <see cref="ProjectedSpread"/> (the last may be zero but
    /// must be supplied). <see cref="Validate"/> rejects an incomplete or inconsistent set before
    /// the engine is constructed.
    /// </summary>
    public sealed record SingleAnchorParameters
    {
        // ---- Grid geometry and sizing regimes (sections 2, 4, 5, 6) ----

        /// <summary>P: grid-step distance as a percentage of the anchor (section 2). Required.</summary>
        public decimal StepPercent { get; init; }

        /// <summary>B: base lot for trades 1..Nnormal, Q_n = B * n (section 4). Required.</summary>
        public decimal BaseLot { get; init; }

        /// <summary>Nnormal: number of arithmetic-sized trades before hard-BE mode (section 5). Default 4.</summary>
        public int NormalTradeCount { get; init; } = 4;

        /// <summary>
        /// C: maximum permitted breakeven distance from the original anchor, in percent (section 6).
        /// The research starting value is approximately 4.478; it is a calibration input, not a proven optimum.
        /// </summary>
        public decimal HardBreakevenCeilingPercent { get; init; } = 4.478m;

        // ---- Escape exit (section 11) ----

        /// <summary>Escape enabled. Default true.</summary>
        public bool EscapeEnabled { get; init; } = true;

        /// <summary>U_escape: escape threshold in strategy-step units. Default 0.05.</summary>
        public decimal EscapeProfitUnits { get; init; } = 0.05m;

        /// <summary>Minimum open positions for the escape exit to apply. Default 2.</summary>
        public int EscapeMinimumOpenPositions { get; init; } = 2;

        // ---- Fixed basket take-profit (section 12) ----

        /// <summary>U_TP: fixed take-profit in strategy-step units; 0 disables it. Default 0.</summary>
        public decimal FixedTakeProfitUnits { get; init; }

        // ---- Basket trailing profit (section 13) ----

        /// <summary>Trailing enabled. Default true.</summary>
        public bool TrailingEnabled { get; init; } = true;

        /// <summary>U_activate: trailing activation threshold in strategy-step units. Default 0.50.</summary>
        public decimal TrailingActivationUnits { get; init; } = 0.50m;

        /// <summary>U_drop: permitted decline from the peak in strategy-step units. Default 0.25.</summary>
        public decimal TrailingDropUnits { get; init; } = 0.25m;

        // ---- Basket profit used for exits (section 9) ----

        /// <summary>
        /// Optional commission buffer in account currency deducted from raw basket profit before
        /// every exit decision, as written in section 9: Profit = RawProfit - CommissionBuffer.
        /// 0 disables it (default).
        /// </summary>
        public decimal CommissionBuffer { get; init; }

        // ---- Instrument money value and broker volume constraints (sections 8, 10, 17) ----

        /// <summary>V: account-currency value of a one-price-unit move for one lot (section 10). Required.</summary>
        public decimal PointValuePerLot { get; init; }

        /// <summary>V_step: broker volume step in lots (section 8). Default 0.01.</summary>
        public decimal VolumeStep { get; init; } = 0.01m;

        /// <summary>Smallest volume the broker accepts, in lots; must be a multiple of the step. Default 0.01.</summary>
        public decimal MinimumVolume { get; init; } = 0.01m;

        /// <summary>Largest volume the broker accepts for one order, in lots. Default 100.</summary>
        public decimal MaximumVolume { get; init; } = 100m;

        // ---- Executable economics used by the hard-BE projection (section 7) ----

        /// <summary>
        /// Round-trip commission per lot in account currency (open plus close). Applied to every leg,
        /// existing and candidate, in the projected executable basket P/L. Default 0.
        /// </summary>
        public decimal CommissionPerLot { get; init; }

        /// <summary>
        /// Adverse slippage assumed per execution, in price units: the candidate leg's projected
        /// entry and every leg's projected close at the target are moved against the basket by
        /// this amount. Default 0.
        /// </summary>
        public decimal Slippage { get; init; }

        /// <summary>
        /// The configured spread assumed at the hard target (section 7: "configured bid/ask
        /// execution side, spread"). The implementation splits it around T to obtain the
        /// projected executable Bid/Ask (T -/+ half; whether T is such a midpoint is an
        /// interpretation pending owner approval). The hard-BE requirement is verified at each
        /// tail entry under this assumption only; a wider spread at the target is not covered.
        /// Must be supplied; zero is a valid sensitivity case (no arithmetic depends on a
        /// positive spread), negative is not.
        /// </summary>
        public decimal? ProjectedSpread { get; init; }

        // ---- Swap / financing (sections 7 and 9, "where configured") ----

        /// <summary>Swap per lot per charged rollover for BUY legs, account currency (negative = cost). Default 0.</summary>
        public decimal BuySwapPerLotPerDay { get; init; }

        /// <summary>Swap per lot per charged rollover for SELL legs, account currency (negative = cost). Default 0.</summary>
        public decimal SellSwapPerLotPerDay { get; init; }

        /// <summary>
        /// Time of day, in the quote clock, at which a trading day rolls over. Rollovers that end a
        /// Monday-to-Friday trading day are charged; those ending a Saturday or Sunday are not.
        /// Default 17:00 (the New York close; LEAN's Oanda XAUUSD quotes are stamped in New York time).
        /// </summary>
        public TimeSpan SwapRolloverTimeOfDay { get; init; } = new TimeSpan(17, 0, 0);

        /// <summary>
        /// Trading day whose rollover charges three days of swap, or null for none. Default Wednesday.
        /// </summary>
        public DayOfWeek? TripleSwapDay { get; init; } = DayOfWeek.Wednesday;

        /// <summary>True when either swap rate is non-zero, i.e. swap accrual is configured.</summary>
        public bool SwapConfigured => BuySwapPerLotPerDay != 0m || SellSwapPerLotPerDay != 0m;

        /// <summary>
        /// Returns every problem with this parameter set, in a fixed order; empty when valid.
        /// </summary>
        public IReadOnlyList<string> GetValidationErrors()
        {
            var errors = new List<string>();

            if (StepPercent <= 0m) errors.Add($"{nameof(StepPercent)} must be > 0 (got {F(StepPercent)}); the specification states no default, set it explicitly.");
            else if (StepPercent >= 100m) errors.Add($"{nameof(StepPercent)} must be < 100 so the lower level stays positive (got {F(StepPercent)}).");
            if (BaseLot <= 0m) errors.Add($"{nameof(BaseLot)} must be > 0 (got {F(BaseLot)}); the specification states no default, set it explicitly.");
            if (NormalTradeCount < 0) errors.Add($"{nameof(NormalTradeCount)} must be >= 0 (got {NormalTradeCount}).");
            if (HardBreakevenCeilingPercent <= 0m || HardBreakevenCeilingPercent >= 100m) errors.Add($"{nameof(HardBreakevenCeilingPercent)} must be > 0 and < 100 (got {F(HardBreakevenCeilingPercent)}).");

            if (EscapeProfitUnits < 0m) errors.Add($"{nameof(EscapeProfitUnits)} must be >= 0 (got {F(EscapeProfitUnits)}).");
            if (EscapeMinimumOpenPositions < 1) errors.Add($"{nameof(EscapeMinimumOpenPositions)} must be >= 1 (got {EscapeMinimumOpenPositions}).");
            if (FixedTakeProfitUnits < 0m) errors.Add($"{nameof(FixedTakeProfitUnits)} must be >= 0, 0 disables fixed TP (got {F(FixedTakeProfitUnits)}).");
            if (TrailingActivationUnits < 0m) errors.Add($"{nameof(TrailingActivationUnits)} must be >= 0 (got {F(TrailingActivationUnits)}).");
            if (TrailingDropUnits < 0m) errors.Add($"{nameof(TrailingDropUnits)} must be >= 0 (got {F(TrailingDropUnits)}).");
            if (CommissionBuffer < 0m) errors.Add($"{nameof(CommissionBuffer)} must be >= 0 (got {F(CommissionBuffer)}).");

            if (PointValuePerLot <= 0m) errors.Add($"{nameof(PointValuePerLot)} must be > 0 (got {F(PointValuePerLot)}).");
            if (VolumeStep <= 0m) errors.Add($"{nameof(VolumeStep)} must be > 0 (got {F(VolumeStep)}).");
            if (MinimumVolume <= 0m) errors.Add($"{nameof(MinimumVolume)} must be > 0 (got {F(MinimumVolume)}).");
            if (VolumeStep > 0m && MinimumVolume > 0m && decimal.Remainder(MinimumVolume, VolumeStep) != 0m) errors.Add($"{nameof(MinimumVolume)} ({F(MinimumVolume)}) must be a whole multiple of {nameof(VolumeStep)} ({F(VolumeStep)}).");
            if (MaximumVolume < MinimumVolume) errors.Add($"{nameof(MaximumVolume)} ({F(MaximumVolume)}) must be >= {nameof(MinimumVolume)} ({F(MinimumVolume)}).");

            if (CommissionPerLot < 0m) errors.Add($"{nameof(CommissionPerLot)} must be >= 0 (got {F(CommissionPerLot)}).");
            if (Slippage < 0m) errors.Add($"{nameof(Slippage)} must be >= 0 (got {F(Slippage)}).");
            if (!ProjectedSpread.HasValue) errors.Add($"{nameof(ProjectedSpread)} must be supplied; the target spread of the hard-BE projection is an explicit input (zero is allowed).");
            else if (ProjectedSpread.Value < 0m) errors.Add($"{nameof(ProjectedSpread)} must be >= 0 (got {F(ProjectedSpread.Value)}).");

            if (SwapRolloverTimeOfDay < TimeSpan.Zero || SwapRolloverTimeOfDay >= TimeSpan.FromDays(1)) errors.Add($"{nameof(SwapRolloverTimeOfDay)} must be a time of day in [00:00, 24:00) (got {SwapRolloverTimeOfDay}).");
            if (TripleSwapDay == DayOfWeek.Saturday || TripleSwapDay == DayOfWeek.Sunday) errors.Add($"{nameof(TripleSwapDay)} must be a weekday or null (got {TripleSwapDay}); weekend rollovers are never charged.");

            return errors;
        }

        /// <summary>
        /// Throws <see cref="ArgumentException"/> listing every problem when the set is invalid.
        /// </summary>
        public void Validate()
        {
            var errors = GetValidationErrors();
            if (errors.Count > 0)
            {
                throw new ArgumentException("Invalid SingleAnchor parameters: " + string.Join(" ", errors));
            }
        }

        private static string F(decimal value)
        {
            return value.ToString(CultureInfo.InvariantCulture);
        }
    }
}
