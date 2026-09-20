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

        /// <summary>The projected Bid or Ask at the target is not positive; no projection is possible.</summary>
        InvalidTargetPrices,

        /// <summary>
        /// PL_1lot(T) &lt;= 0: one lot of the required side does not gain at the target, so no
        /// volume can pull breakeven inside the ceiling (specification section 7).
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
    /// </summary>
    public sealed record HardBreakevenSizing(
        TradeSide Side,
        int TradeNumber,
        TargetPrices Target,
        decimal CandidateEntryPrice,
        decimal ExistingProfitAtTarget,
        decimal MarginalProfitPerLot,
        decimal RequiredLot,
        decimal NormalizedLot,
        decimal ProjectedProfitAfter,
        HardBreakevenOutcome Outcome,
        string Message)
    {
        /// <summary>True when <see cref="NormalizedLot"/> can be placed.</summary>
        public bool IsFeasible => Outcome == HardBreakevenOutcome.Feasible;
    }

    /// <summary>
    /// Tail lot sizing (specification sections 6-8): the smallest broker-valid lot Q such that the
    /// projected executable basket P/L at the applicable hard target is non-negative.
    /// </summary>
    public static class HardBreakevenSizer
    {
        /// <summary>
        /// Sizes the required <paramref name="side"/> for the basket at the current quote.
        /// </summary>
        /// <remarks>
        /// Steps, all in exact decimal:
        /// <list type="number">
        /// <item>T = T_up for a BUY, T_down for a SELL; projected Bid/Ask at T from the observed or configured spread.</item>
        /// <item>Candidate entry: Ask + slippage for a BUY, Bid - slippage for a SELL.</item>
        /// <item>PL_existing(T) over every open leg; PL_1lot(T) for one lot of the candidate.</item>
        /// <item>PL_1lot(T) &lt;= 0 is infeasible. Otherwise Q_BE = -PL_existing / PL_1lot, or 0 when PL_existing &gt;= 0.</item>
        /// <item>Q = ceil(max(Q_BE, MinimumVolume) / step) * step; verify PL_after(T, Q) &gt;= 0 by direct
        /// recomputation and step upward until it holds; above MaximumVolume it is infeasible.</item>
        /// </list>
        /// </remarks>
        public static HardBreakevenSizing Size(Basket basket, TradeSide side, in Quote quote, SingleAnchorParameters parameters)
        {
            if (basket == null) throw new ArgumentNullException(nameof(basket));
            if (parameters == null) throw new ArgumentNullException(nameof(parameters));
            if (!quote.IsValid) throw new ArgumentException("Sizing requires a valid quote; got " + quote, nameof(quote));

            var tradeNumber = basket.NextTradeNumber;
            var targetMid = side == TradeSide.Buy ? basket.UpperTarget : basket.LowerTarget;
            var spread = parameters.UseObservedSpreadForProjection ? quote.Spread : parameters.ProjectedSpread;
            var target = new TargetPrices(targetMid, spread);
            var candidateEntry = side == TradeSide.Buy ? quote.Ask + parameters.Slippage : quote.Bid - parameters.Slippage;

            if (!target.IsValid || candidateEntry <= 0m)
            {
                return new HardBreakevenSizing(side, tradeNumber, target, candidateEntry, 0m, 0m, 0m, 0m, 0m,
                    HardBreakevenOutcome.InvalidTargetPrices,
                    $"Projected prices at the {side} target are not positive (target {F(targetMid)}, spread {F(spread)}, candidate entry {F(candidateEntry)}).");
            }

            var existing = BasketEconomics.ProjectedExistingProfit(basket, target, parameters);
            var marginal = BasketEconomics.ProjectedLegProfit(side, 1m, candidateEntry, 0m, target, parameters);

            if (marginal <= 0m)
            {
                return new HardBreakevenSizing(side, tradeNumber, target, candidateEntry, existing, marginal, 0m, 0m, existing,
                    HardBreakevenOutcome.NonPositiveMarginalProfit,
                    $"One lot of {side} at {F(candidateEntry)} contributes {F(marginal)} at the hard target {F(targetMid)} (projected close {F(side == TradeSide.Buy ? target.Bid : target.Ask)}); the target cannot be reached by adding {side} volume.");
            }

            // Q_BE is the exact requirement; a basket already at or inside the ceiling needs no
            // volume for breakeven, so the smallest valid lot is the broker minimum.
            var required = existing >= 0m ? 0m : -existing / marginal;
            var lot = VolumeMath.CeilToStep(Math.Max(required, parameters.MinimumVolume), parameters.VolumeStep);

            // Conservative normalization: verify with the normalized lot and, if rounding left the
            // requirement unmet, take the next step. Never a smaller lot (section 8).
            var after = ProjectedAfter(existing, side, lot, candidateEntry, target, parameters);
            while (after < 0m)
            {
                if (lot + parameters.VolumeStep > parameters.MaximumVolume) break;
                lot += parameters.VolumeStep;
                after = ProjectedAfter(existing, side, lot, candidateEntry, target, parameters);
            }

            if (after < 0m || lot > parameters.MaximumVolume)
            {
                return new HardBreakevenSizing(side, tradeNumber, target, candidateEntry, existing, marginal, required, 0m, after,
                    HardBreakevenOutcome.ExceedsMaximumVolume,
                    $"Hard-BE requires {F(required)} lots of {side} (normalized {F(lot)}), above the maximum volume {F(parameters.MaximumVolume)}; the order is not placed and breakeven is not allowed to drift.");
            }

            return new HardBreakevenSizing(side, tradeNumber, target, candidateEntry, existing, marginal, required, lot, after,
                HardBreakevenOutcome.Feasible,
                $"Hard-BE {side} trade {tradeNumber}: PL_existing(T)={F(existing)}, PL_1lot(T)={F(marginal)}, Q_BE={F(required)}, lot={F(lot)}, PL_after={F(after)} at target {F(targetMid)}.");
        }

        private static decimal ProjectedAfter(decimal existing, TradeSide side, decimal lot, decimal candidateEntry, in TargetPrices target, SingleAnchorParameters parameters)
        {
            return existing + BasketEconomics.ProjectedLegProfit(side, lot, candidateEntry, 0m, target, parameters);
        }

        private static string F(decimal value)
        {
            return value.ToString(CultureInfo.InvariantCulture);
        }
    }
}
