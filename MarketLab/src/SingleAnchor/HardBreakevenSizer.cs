using System;
using System.Globalization;

namespace MarketLab.SingleAnchor
{
    /// <summary>
    /// Why a hard-BE sizing did or did not produce a placeable lot.
    /// </summary>
    public enum HardBreakevenOutcome
    {
        /// <summary>A valid lot satisfies PL_after(T, Q) >= 0.</summary>
        Feasible,

        /// <summary>
        /// An executable price of the projection is not positive: the projected close of a BUY
        /// (target Bid less slippage) or of a SELL (target Ask plus slippage), or the candidate
        /// entry price. No projection is possible.
        /// </summary>
        InvalidTargetPrices,

        /// <summary>
        /// PL_1lot(T) &lt;= 0 and the basket is not already at or inside the ceiling: adding the
        /// required side cannot make the basket break even at the target (specification section 7).
        /// </summary>
        NonPositiveMarginalProfit,

        /// <summary>
        /// The smallest lot that satisfies the requirement exceeds the broker's maximum volume
        /// (specification section 8: surfaced, never converted into BE drift).
        /// </summary>
        ExceedsMaximumVolume
    }

    /// <summary>
    /// Full record of one hard-BE sizing, feasible or not, so the decision can be logged and tested.
    /// <see cref="RequiredLot"/> is the exact Q_BE, or 0 when the ratio is not applicable (the
    /// basket already projects at or inside the ceiling, or PL_1lot(T) is not positive);
    /// <see cref="NormalizedRequiredLot"/> is the broker-valid lot the requirement needs (kept even
    /// when it exceeds the maximum volume, so infeasibility never hides the needed lot);
    /// <see cref="NormalizedLot"/> is the lot to place, 0 when infeasible.
    /// </summary>
    public sealed record HardBreakevenSizing(
        TradeSide Side,
        int TradeNumber,
        TargetPrices Target,
        decimal CandidateEntryPrice,
        decimal ExistingProfitAtTarget,
        decimal MarginalProfitPerLot,
        decimal RequiredLot,
        decimal NormalizedRequiredLot,
        decimal NormalizedLot,
        decimal ProjectedProfitAfter,
        decimal MaximumVolume,
        HardBreakevenOutcome Outcome)
    {
        /// <summary>True when <see cref="NormalizedLot"/> can be placed.</summary>
        public bool IsFeasible => Outcome == HardBreakevenOutcome.Feasible;

        /// <summary>Human-readable account of the sizing, built on demand (never per tick; see the engine's rejection handling).</summary>
        public string Message
        {
            get
            {
                var target = F(Target.Target);
                switch (Outcome)
                {
                    case HardBreakevenOutcome.Feasible:
                        return $"Hard-BE {Side} trade {TradeNumber}: PL_existing(T)={F(ExistingProfitAtTarget)}, PL_1lot(T)={F(MarginalProfitPerLot)}, Q_BE={F(RequiredLot)}, normalized requirement={F(NormalizedRequiredLot)}, lot={F(NormalizedLot)}, PL_after={F(ProjectedProfitAfter)} at target {target}.";
                    case HardBreakevenOutcome.InvalidTargetPrices:
                        return $"Executable prices of the {Side} projection are not positive (target {target}, spread {F(Target.Spread)}, projected Bid {F(Target.Bid)} / Ask {F(Target.Ask)} before slippage, candidate entry {F(CandidateEntryPrice)}).";
                    case HardBreakevenOutcome.NonPositiveMarginalProfit:
                        return $"One lot of {Side} at {F(CandidateEntryPrice)} contributes {F(MarginalProfitPerLot)} at the hard target {target} (projected close {F(Side == TradeSide.Buy ? Target.Bid : Target.Ask)}) while the basket projects {F(ExistingProfitAtTarget)} there; the target cannot be reached by adding {Side} volume.";
                    default:
                        return $"Hard-BE requires exactly {F(RequiredLot)} lots of {Side} (normalized requirement {F(NormalizedRequiredLot)}) and the smallest valid lot above the maximum volume {F(MaximumVolume)}; the order is not placed and breakeven is not allowed to drift.";
                }
            }
        }

        private static string F(decimal value)
        {
            return value.ToString(CultureInfo.InvariantCulture);
        }
    }

    /// <summary>
    /// Tail lot sizing (specification sections 6-8): the smallest broker-valid lot Q such that the
    /// projected executable basket P/L at the applicable hard target is non-negative. The target is
    /// the true basket-BE level: Bid = T_up for a required BUY recovery, Ask = T_down for a required
    /// SELL recovery; the configured target spread only reconstructs the opposite quote side of the
    /// simultaneous basket closure (see <see cref="TargetPrices"/>).
    /// </summary>
    public static class HardBreakevenSizer
    {
        /// <summary>
        /// Sizes the required <paramref name="side"/> for the basket at the current quote.
        /// </summary>
        /// <remarks>
        /// Steps, all in exact decimal:
        /// <list type="number">
        /// <item>Upper recovery (BUY): T = T_up, projected Bid = T_up, projected Ask = T_up + W. Lower recovery (SELL): T = T_down, projected Ask = T_down, projected Bid = T_down - W.</item>
        /// <item>Candidate entry: Ask + slippage for a BUY, Bid - slippage for a SELL.</item>
        /// <item>PL_existing(T) over every open leg; PL_1lot(T) for one lot of the candidate.</item>
        /// <item>PL_1lot(T) &gt; 0: Q_BE = -PL_existing / PL_1lot (0 when PL_existing &gt;= 0); the
        /// broker-normalized requirement is ceil(max(Q_BE, minimum) / step) * step; the placed lot
        /// is that requirement, verified by direct recomputation of PL_after(T, Q) and stepped upward
        /// while negative; above MaximumVolume it is infeasible.</item>
        /// <item>PL_1lot(T) &lt;= 0: the ratio is not valid and more volume cannot help, so the only
        /// candidate is the minimum volume; it is placed when PL_after(T, minimum) &gt;= 0
        /// (the basket is already at or inside the ceiling) and otherwise the sizing is infeasible.</item>
        /// </list>
        /// </remarks>
        public static HardBreakevenSizing Size(Basket basket, TradeSide side, in Quote quote, SingleAnchorParameters parameters)
        {
            if (basket == null) throw new ArgumentNullException(nameof(basket));
            if (parameters == null) throw new ArgumentNullException(nameof(parameters));
            if (!quote.IsValid) throw new ArgumentException("Sizing requires a valid quote; got " + quote, nameof(quote));

            var tradeNumber = basket.NextTradeNumber;
            // The hard-BE level itself: Bid = T_up for a required BUY recovery, Ask = T_down for a
            // required SELL recovery. The configured spread reconstructs only the opposite side of
            // the simultaneous close (section 6); it never shifts the target.
            var target = side == TradeSide.Buy
                ? TargetPrices.ForUpperRecovery(basket.UpperTarget, parameters.ProjectedSpread!.Value)
                : TargetPrices.ForLowerRecovery(basket.LowerTarget, parameters.ProjectedSpread!.Value);
            // The same execution model the research executor fills with, so the projection and the
            // actual fill agree (the engine re-verifies the invariant after every tail fill).
            var candidateEntry = BasketEconomics.ExecutableEntryPrice(side, quote, parameters);
            var maximum = parameters.MaximumVolume;

            var (projectedBuyClose, projectedSellClose) = BasketEconomics.ExecutableClosePrices(target, parameters);
            if (!target.IsValid || !BasketEconomics.ArePricesUsable(basket, projectedBuyClose, projectedSellClose, side) || candidateEntry <= 0m)
            {
                return new HardBreakevenSizing(side, tradeNumber, target, candidateEntry, 0m, 0m, 0m, 0m, 0m, 0m, maximum, HardBreakevenOutcome.InvalidTargetPrices);
            }

            var existing = BasketEconomics.ProjectedExistingProfit(basket, target, parameters);
            var marginal = BasketEconomics.ProjectedLegProfit(side, 1m, candidateEntry, target, parameters);

            if (marginal <= 0m)
            {
                var afterMinimum = ProjectedAfter(existing, side, parameters.MinimumVolume, candidateEntry, target, parameters);
                if (afterMinimum >= 0m)
                {
                    return new HardBreakevenSizing(side, tradeNumber, target, candidateEntry, existing, marginal, 0m, parameters.MinimumVolume, parameters.MinimumVolume, afterMinimum, maximum, HardBreakevenOutcome.Feasible);
                }
                return new HardBreakevenSizing(side, tradeNumber, target, candidateEntry, existing, marginal, 0m, 0m, 0m, afterMinimum, maximum, HardBreakevenOutcome.NonPositiveMarginalProfit);
            }

            // Q_BE is the exact requirement; a basket already at or inside the ceiling needs no
            // volume for breakeven, so the smallest valid lot is the broker minimum. The
            // broker-normalized requirement is kept even when it exceeds the maximum volume, so an
            // infeasible sizing never hides the lot the hard-BE condition needs (section 8).
            var required = existing >= 0m ? 0m : -existing / marginal;
            var normalizedRequired = VolumeMath.CeilToStep(Math.Max(required, parameters.MinimumVolume), parameters.VolumeStep);
            var lot = normalizedRequired;

            // Conservative normalization: verify with the normalized lot and, if rounding left the
            // requirement unmet, take the next step. Never a smaller lot (section 8).
            var after = ProjectedAfter(existing, side, lot, candidateEntry, target, parameters);
            while (after < 0m && lot + parameters.VolumeStep <= maximum)
            {
                lot += parameters.VolumeStep;
                after = ProjectedAfter(existing, side, lot, candidateEntry, target, parameters);
            }

            if (after < 0m || lot > maximum)
            {
                return new HardBreakevenSizing(side, tradeNumber, target, candidateEntry, existing, marginal, required, normalizedRequired, 0m, after, maximum, HardBreakevenOutcome.ExceedsMaximumVolume);
            }

            return new HardBreakevenSizing(side, tradeNumber, target, candidateEntry, existing, marginal, required, normalizedRequired, lot, after, maximum, HardBreakevenOutcome.Feasible);
        }

        private static decimal ProjectedAfter(decimal existing, TradeSide side, decimal lot, decimal candidateEntry, in TargetPrices target, SingleAnchorParameters parameters)
        {
            return existing + BasketEconomics.ProjectedLegProfit(side, lot, candidateEntry, target, parameters);
        }
    }
}
