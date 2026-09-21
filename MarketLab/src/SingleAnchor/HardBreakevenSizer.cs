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
        /// required side cannot make the basket break even at the boundary (specification section 7).
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
    /// <see cref="ExactRequired"/> is that exact requirement or null when it does not exist;
    /// <see cref="NormalizedRequiredLot"/> is the smallest broker-valid lot whose direct
    /// recomputation verifies the requirement, kept even when it exceeds the maximum volume, so
    /// infeasibility never hides the needed lot;
    /// <see cref="NormalizedLot"/> is the lot to place, 0 when infeasible. A value type: a rejected
    /// attempt creates no heap object on the hot path.
    /// </summary>
    public readonly record struct HardBreakevenSizing(
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

        /// <summary>
        /// The exact mathematically required lot Q_BE, or null when the ratio does not apply
        /// (PL_1lot(T) &lt;= 0 means there is no finite exact requirement). The trace records use
        /// this so a minimum-volume leg in the already-inside-the-ceiling case does not look like
        /// an exact requirement of zero.
        /// </summary>
        public decimal? ExactRequired => MarginalProfitPerLot > 0m ? RequiredLot : (decimal?)null;

        /// <summary>Human-readable account of the sizing, built on demand (never per tick; see the engine's rejection handling).</summary>
        public string Message
        {
            get
            {
                var target = F(Target.Target);
                switch (Outcome)
                {
                    case HardBreakevenOutcome.Feasible:
                        return $"Hard-BE {Side} trade {TradeNumber}: PL_existing(T)={F(ExistingProfitAtTarget)}, PL_1lot(T)={F(MarginalProfitPerLot)}, Q_BE={F(RequiredLot)}, normalized requirement={F(NormalizedRequiredLot)}, lot={F(NormalizedLot)}, PL_after={F(ProjectedProfitAfter)} at boundary {target}.";
                    case HardBreakevenOutcome.InvalidTargetPrices:
                        return $"Executable prices of the {Side} projection are not positive (target {target}, spread {F(Target.Spread)}, projected Bid {F(Target.Bid)} / Ask {F(Target.Ask)} before slippage, candidate entry {F(CandidateEntryPrice)}).";
                    case HardBreakevenOutcome.NonPositiveMarginalProfit:
                        return $"One lot of {Side} at {F(CandidateEntryPrice)} contributes {F(MarginalProfitPerLot)} at the hard boundary {target} (projected close {F(Side == TradeSide.Buy ? Target.Bid : Target.Ask)}) while the basket projects {F(ExistingProfitAtTarget)} there; the boundary cannot be reached by adding {Side} volume.";
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
    /// projected executable basket P/L at the applicable hard boundary is non-negative. The boundary is
    /// Bid = T_up for a required BUY recovery and Ask = T_down for a required
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
        /// broker-normalized requirement is the smallest volume-step multiple whose direct
        /// recomputation of PL_after(T, Q) is non-negative, starting from ceil(max(Q_BE, minimum) /
        /// step) * step and stepping upward while the recomputation is still negative. It is
        /// reported exactly (even above MaximumVolume); above MaximumVolume the sizing is
        /// infeasible.</item>
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
            // The hard boundary itself: Bid = T_up for a required BUY recovery, Ask = T_down for a
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
            // broker-normalized requirement is the smallest broker-valid lot whose direct
            // recomputation verifies PL_after >= 0; it is reported even when it exceeds the maximum
            // volume, so an infeasible sizing never hides the lot the hard-BE condition needs
            // (section 8). The verification step may move the requirement one step above the
            // ceil(Q_BE) estimate when decimal rounding needs it, and the reported requirement
            // moves with the verified lot.
            var required = existing >= 0m ? 0m : -existing / marginal;
            var candidate = VolumeMath.CeilToStep(Math.Max(required, parameters.MinimumVolume), parameters.VolumeStep);
            var normalizedRequired = SmallestVerifiedLot(existing, side, candidateEntry, target, parameters, candidate, out var after);

            if (normalizedRequired > maximum)
            {
                return new HardBreakevenSizing(side, tradeNumber, target, candidateEntry, existing, marginal, required, normalizedRequired, 0m, after, maximum, HardBreakevenOutcome.ExceedsMaximumVolume);
            }

            return new HardBreakevenSizing(side, tradeNumber, target, candidateEntry, existing, marginal, required, normalizedRequired, normalizedRequired, after, maximum, HardBreakevenOutcome.Feasible);
        }

        /// <summary>
        /// Steps <paramref name="startingLot"/> upward, one volume step at a time, until the direct
        /// recomputation of <c>PL_after</c> is non-negative, and returns the smallest verified lot.
        /// The starting lot is normally <c>ceil(max(Q_BE, minimum) / step) * step</c>; the loop only
        /// runs when decimal rounding left that estimate one or more steps short. It is exposed
        /// internally so that fallback branch can be tested with a deliberately short start.
        /// Requires PL_1lot(T) &gt; 0, which makes the sequence strictly increasing and terminating.
        /// </summary>
        internal static decimal SmallestVerifiedLot(
            decimal existing,
            TradeSide side,
            decimal candidateEntry,
            in TargetPrices target,
            SingleAnchorParameters parameters,
            decimal startingLot,
            out decimal after)
        {
            var lot = startingLot;
            after = ProjectedAfter(existing, side, lot, candidateEntry, target, parameters);
            while (after < 0m)
            {
                lot += parameters.VolumeStep;
                after = ProjectedAfter(existing, side, lot, candidateEntry, target, parameters);
            }
            return lot;
        }

        private static decimal ProjectedAfter(decimal existing, TradeSide side, decimal lot, decimal candidateEntry, in TargetPrices target, SingleAnchorParameters parameters)
        {
            return existing + BasketEconomics.ProjectedLegProfit(side, lot, candidateEntry, target, parameters);
        }
    }
}
