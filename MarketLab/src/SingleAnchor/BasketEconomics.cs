using System;

namespace MarketLab.SingleAnchor
{
    /// <summary>
    /// Basket-level money arithmetic (specification sections 7, 9 and 10). Pure functions over the
    /// basket ledger; nothing here reads host holdings. Every valuation uses the basket's
    /// aggregates (BUY/SELL lots, entry notionals, swap total), so it costs the same whether the
    /// basket holds one leg or fifty; the per-leg helpers exist for audit and tests.
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
        /// RawProfit: the combined current profit of every leg, BUY legs marked at the Bid and
        /// SELL legs at the Ask, plus accrued swap (section 9). Constant time.
        /// </summary>
        public static decimal RawProfit(Basket basket, in Quote quote, SingleAnchorParameters parameters)
        {
            if (basket == null) throw new ArgumentNullException(nameof(basket));
            if (parameters == null) throw new ArgumentNullException(nameof(parameters));
            return PriceProfit(basket, quote.Bid, quote.Ask, parameters.PointValuePerLot) + basket.AccruedSwapTotal;
        }

        /// <summary>
        /// Profit used for exit decisions: RawProfit minus the optional commission buffer
        /// (section 9: Profit = RawProfit - CommissionBuffer).
        /// </summary>
        public static decimal ExitProfit(Basket basket, in Quote quote, SingleAnchorParameters parameters)
        {
            return RawProfit(basket, quote, parameters) - parameters!.CommissionBuffer;
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
        /// Executable close prices at a quote under the configured execution model: BUY legs close
        /// at the Bid less slippage, SELL legs at the Ask plus slippage. They are usable only when
        /// both are positive (<see cref="ArePricesUsable"/>).
        /// </summary>
        public static (decimal BuyClose, decimal SellClose) ExecutableClosePrices(in Quote quote, SingleAnchorParameters parameters)
        {
            if (parameters == null) throw new ArgumentNullException(nameof(parameters));
            return (quote.Bid - parameters.Slippage, quote.Ask + parameters.Slippage);
        }

        /// <summary>
        /// Executable close prices at a hard target: the projected Bid less slippage for BUY legs,
        /// the projected Ask plus slippage for SELL legs.
        /// </summary>
        public static (decimal BuyClose, decimal SellClose) ExecutableClosePrices(in TargetPrices target, SingleAnchorParameters parameters)
        {
            if (parameters == null) throw new ArgumentNullException(nameof(parameters));
            return (target.Bid - parameters.Slippage, target.Ask + parameters.Slippage);
        }

        /// <summary>True when every executable price handed in is positive.</summary>
        public static bool ArePricesUsable(decimal buyClose, decimal sellClose)
        {
            return buyClose > 0m && sellClose > 0m;
        }

        /// <summary>
        /// Executable entry price of a new leg at a quote under the configured execution model:
        /// a BUY at the Ask plus slippage, a SELL at the Bid less slippage.
        /// </summary>
        public static decimal ExecutableEntryPrice(TradeSide side, in Quote quote, SingleAnchorParameters parameters)
        {
            if (parameters == null) throw new ArgumentNullException(nameof(parameters));
            return side == TradeSide.Buy ? quote.Ask + parameters.Slippage : quote.Bid - parameters.Slippage;
        }

        /// <summary>
        /// Executable profit of the whole basket closed at the given per-side prices: price P/L,
        /// plus accrued swap, less the round-trip commission on the gross volume. Used for the
        /// projection at a hard target (section 7), for the realized result of a close and for
        /// the executable mark-to-market of an open basket. Constant time.
        /// </summary>
        public static decimal ExecutableProfit(Basket basket, decimal buyClosePrice, decimal sellClosePrice, SingleAnchorParameters parameters)
        {
            if (basket == null) throw new ArgumentNullException(nameof(basket));
            if (parameters == null) throw new ArgumentNullException(nameof(parameters));
            return PriceProfit(basket, buyClosePrice, sellClosePrice, parameters.PointValuePerLot)
                + basket.AccruedSwapTotal
                - parameters.CommissionPerLot * basket.GrossLots;
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
        /// Constant time; equal to the sum of <see cref="ProjectedLegProfit"/> over the legs.
        /// </summary>
        public static decimal ProjectedExistingProfit(Basket basket, in TargetPrices target, SingleAnchorParameters parameters)
        {
            var (buyClose, sellClose) = ExecutableClosePrices(target, parameters);
            return ExecutableProfit(basket, buyClose, sellClose, parameters);
        }

        private static decimal PriceProfit(Basket basket, decimal buyClosePrice, decimal sellClosePrice, decimal pointValuePerLot)
        {
            return ((buyClosePrice * basket.BuyLots - basket.BuyNotional) + (basket.SellNotional - sellClosePrice * basket.SellLots)) * pointValuePerLot;
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
