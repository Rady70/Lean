using System;

namespace MarketLab.SingleAnchor
{
    /// <summary>
    /// Basket-level money arithmetic (specification sections 7, 9 and 10). Pure functions over the
    /// basket ledger; nothing here reads host holdings.
    /// </summary>
    public static class BasketEconomics
    {
        /// <summary>
        /// Current profit of one leg marked at the side it would close on: a BUY at the Bid, a
        /// SELL at the Ask, plus the leg's accrued swap. No commission (see the commission buffer).
        /// </summary>
        public static decimal CurrentLegProfit(BasketLeg leg, in Quote quote, decimal pointValuePerLot)
        {
            if (leg == null) throw new ArgumentNullException(nameof(leg));
            var priceMove = leg.Side == TradeSide.Buy ? quote.Bid - leg.EntryPrice : leg.EntryPrice - quote.Ask;
            return priceMove * leg.Lots * pointValuePerLot + leg.AccruedSwap;
        }

        /// <summary>
        /// RawProfit: the combined current profit of every leg including accrued swap (section 9).
        /// </summary>
        public static decimal RawProfit(Basket basket, in Quote quote, SingleAnchorParameters parameters)
        {
            if (basket == null) throw new ArgumentNullException(nameof(basket));
            if (parameters == null) throw new ArgumentNullException(nameof(parameters));
            var legs = basket.Legs;
            var total = 0m;
            for (var i = 0; i < legs.Count; i++)
            {
                total += CurrentLegProfit(legs[i], quote, parameters.PointValuePerLot);
            }
            return total;
        }

        /// <summary>
        /// Profit used for exit decisions: RawProfit minus the optional commission buffer,
        /// CommissionBufferPerLot * GrossLots (section 9).
        /// </summary>
        public static decimal ExitProfit(Basket basket, in Quote quote, SingleAnchorParameters parameters)
        {
            if (basket == null) throw new ArgumentNullException(nameof(basket));
            if (parameters == null) throw new ArgumentNullException(nameof(parameters));
            return RawProfit(basket, quote, parameters) - parameters.CommissionBufferPerLot * basket.GrossLots;
        }

        /// <summary>
        /// E: the exit-sensitivity lot size, |N| when the basket has a net exposure, otherwise the
        /// smallest open position (section 10). Requires at least one leg.
        /// </summary>
        public static decimal ExitSensitivityLots(Basket basket)
        {
            if (basket == null) throw new ArgumentNullException(nameof(basket));
            if (basket.OpenPositions == 0) throw new InvalidOperationException("Exit sensitivity is undefined for a basket without legs.");
            return basket.IsNetFlat ? basket.SmallestOpenLots : Math.Abs(basket.NetLots);
        }

        /// <summary>
        /// M_step = S * E * V, the money value of one strategy step (section 10). Requires at least one leg.
        /// </summary>
        public static decimal StepMoney(Basket basket, SingleAnchorParameters parameters)
        {
            if (parameters == null) throw new ArgumentNullException(nameof(parameters));
            return basket!.Step * ExitSensitivityLots(basket) * parameters.PointValuePerLot;
        }

        /// <summary>
        /// Projected executable profit of one leg closed at the hard target: a BUY closes at the
        /// projected Bid less slippage, a SELL at the projected Ask plus slippage; accrued swap is
        /// kept and the round-trip commission for the leg's volume is deducted (section 7).
        /// </summary>
        public static decimal ProjectedLegProfit(TradeSide side, decimal lots, decimal entryPrice, decimal accruedSwap, in TargetPrices target, SingleAnchorParameters parameters)
        {
            if (parameters == null) throw new ArgumentNullException(nameof(parameters));
            var closePrice = side == TradeSide.Buy ? target.Bid - parameters.Slippage : target.Ask + parameters.Slippage;
            var priceMove = side == TradeSide.Buy ? closePrice - entryPrice : entryPrice - closePrice;
            return priceMove * lots * parameters.PointValuePerLot + accruedSwap - parameters.CommissionPerLot * lots;
        }

        /// <summary>
        /// PL_existing(T): projected executable profit of every open leg at the target (section 7).
        /// </summary>
        public static decimal ProjectedExistingProfit(Basket basket, in TargetPrices target, SingleAnchorParameters parameters)
        {
            if (basket == null) throw new ArgumentNullException(nameof(basket));
            var legs = basket.Legs;
            var total = 0m;
            for (var i = 0; i < legs.Count; i++)
            {
                var leg = legs[i];
                total += ProjectedLegProfit(leg.Side, leg.Lots, leg.EntryPrice, leg.AccruedSwap, target, parameters);
            }
            return total;
        }
    }

    /// <summary>
    /// Executable prices assumed at a hard target: the target is a midpoint (like the anchor it is
    /// derived from) and the projected spread is split symmetrically around it.
    /// </summary>
    public readonly record struct TargetPrices
    {
        /// <summary>Builds the projected Bid/Ask around a mid target with the given spread.</summary>
        public TargetPrices(decimal target, decimal spread)
        {
            Target = target;
            Spread = spread;
            Bid = target - spread / 2m;
            Ask = target + spread / 2m;
        }

        /// <summary>T, the hard target as a midpoint.</summary>
        public decimal Target { get; }

        /// <summary>Spread assumed at the target.</summary>
        public decimal Spread { get; }

        /// <summary>Projected Bid at the target, the close price of BUY legs before slippage.</summary>
        public decimal Bid { get; }

        /// <summary>Projected Ask at the target, the close price of SELL legs before slippage.</summary>
        public decimal Ask { get; }

        /// <summary>True when both projected prices are positive.</summary>
        public bool IsValid => Bid > 0m && Ask > 0m;
    }
}
