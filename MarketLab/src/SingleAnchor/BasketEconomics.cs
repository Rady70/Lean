using System;

namespace MarketLab.SingleAnchor
{
    /// <summary>
    /// Basket-level money arithmetic (specification sections 7, 9 and 10). Pure functions over the
    /// basket ledger; nothing here reads host holdings. Every valuation uses the basket's
    /// aggregates (BUY/SELL lots, entry notionals), so it costs the same whether the
    /// basket holds one leg or fifty; the per-leg helpers exist for audit and tests.
    /// </summary>
    public static class BasketEconomics
    {
        /// <summary>
        /// Current profit of one leg marked at the side it would close on: a BUY at the Bid, a
        /// SELL at the Ask. No commission (see the commission buffer).
        /// </summary>
        public static decimal CurrentLegProfit(BasketLeg leg, in Quote quote, decimal pointValuePerLot)
        {
            if (leg == null) throw new ArgumentNullException(nameof(leg));
            var priceMove = leg.Side == TradeSide.Buy ? quote.Bid - leg.EntryPrice : leg.EntryPrice - quote.Ask;
            return priceMove * leg.Lots * pointValuePerLot;
        }

        /// <summary>
        /// RawProfit: the combined current profit of every leg, BUY legs marked at the Bid and
        /// SELL legs at the Ask (section 9). Constant time.
        /// </summary>
        public static decimal RawProfit(Basket basket, in Quote quote, SingleAnchorParameters parameters)
        {
            if (basket == null) throw new ArgumentNullException(nameof(basket));
            if (parameters == null) throw new ArgumentNullException(nameof(parameters));
            return PriceProfit(basket, quote.Bid, quote.Ask, parameters.PointValuePerLot);
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
        /// Executable close prices at a hard boundary: the projected Bid less slippage for BUY legs,
        /// the projected Ask plus slippage for SELL legs.
        /// </summary>
        public static (decimal BuyClose, decimal SellClose) ExecutableClosePrices(in TargetPrices target, SingleAnchorParameters parameters)
        {
            if (parameters == null) throw new ArgumentNullException(nameof(parameters));
            return (target.Bid - parameters.Slippage, target.Ask + parameters.Slippage);
        }

        /// <summary>
        /// True when the executable prices that matter are positive: the BUY close when the basket
        /// holds BUY legs or the candidate is a BUY, the SELL close when it holds SELL legs or the
        /// candidate is a SELL. A side that is absent needs no price.
        /// </summary>
        public static bool ArePricesUsable(Basket basket, decimal buyClose, decimal sellClose, TradeSide? candidate)
        {
            if (basket == null) throw new ArgumentNullException(nameof(basket));
            var needsBuy = basket.BuyLots > 0m || candidate == TradeSide.Buy;
            var needsSell = basket.SellLots > 0m || candidate == TradeSide.Sell;
            return (!needsBuy || buyClose > 0m) && (!needsSell || sellClose > 0m);
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
        /// Executable profit of the whole basket closed at the given per-side prices: price P/L
        /// less the round-trip commission on the gross volume. Used for the projection at a hard
        /// target (section 7), for the realized result of a close and for the executable
        /// mark-to-market of an open basket. Constant time.
        /// </summary>
        public static decimal ExecutableProfit(Basket basket, decimal buyClosePrice, decimal sellClosePrice, SingleAnchorParameters parameters)
        {
            if (basket == null) throw new ArgumentNullException(nameof(basket));
            if (parameters == null) throw new ArgumentNullException(nameof(parameters));
            return PriceProfit(basket, buyClosePrice, sellClosePrice, parameters.PointValuePerLot)
                - parameters.CommissionPerLot * basket.GrossLots;
        }

        /// <summary>
        /// Projected executable profit of one leg valued at the hard boundary: a BUY closes at the
        /// projected Bid less slippage, a SELL at the projected Ask plus slippage; the round-trip
        /// commission for the leg's volume is deducted (section 7).
        /// </summary>
        public static decimal ProjectedLegProfit(TradeSide side, decimal lots, decimal entryPrice, in TargetPrices target, SingleAnchorParameters parameters)
        {
            if (parameters == null) throw new ArgumentNullException(nameof(parameters));
            var closePrice = side == TradeSide.Buy ? target.Bid - parameters.Slippage : target.Ask + parameters.Slippage;
            var priceMove = side == TradeSide.Buy ? closePrice - entryPrice : entryPrice - closePrice;
            return priceMove * lots * parameters.PointValuePerLot - parameters.CommissionPerLot * lots;
        }

        /// <summary>
        /// PL_existing(T): projected executable profit of every open leg at the boundary (section 7).
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
    /// Executable prices of the simultaneous basket valuation at a hard boundary (specification
    /// section 6). The upper boundary is the Bid (<c>Bid = T_up</c>) and the lower boundary the Ask
    /// (<c>Ask = T_down</c>); the configured target spread is used only to reconstruct the opposite
    /// quote side of that same instant. The boundary is a ceiling used for sizing: it is not
    /// necessarily the actual zero-loss BE and it is not an exit price.
    /// </summary>
    public readonly record struct TargetPrices
    {
        private TargetPrices(decimal target, decimal spread, bool upperRecovery)
        {
            Target = target;
            Spread = spread;
            if (upperRecovery)
            {
                Bid = target;
                Ask = target + spread;
            }
            else
            {
                Ask = target;
                Bid = target - spread;
            }
        }

        /// <summary>Upper recovery projection: the boundary is Bid = T_up; the SELL side is reconstructed as Ask = T_up + spread.</summary>
        public static TargetPrices ForUpperRecovery(decimal target, decimal spread)
        {
            return new TargetPrices(target, spread, upperRecovery: true);
        }

        /// <summary>Lower recovery projection: the boundary is Ask = T_down; the BUY side is reconstructed as Bid = T_down - spread.</summary>
        public static TargetPrices ForLowerRecovery(decimal target, decimal spread)
        {
            return new TargetPrices(target, spread, upperRecovery: false);
        }

        /// <summary>T_up (upper recovery) or T_down (lower recovery), the hard basket-BE boundary.</summary>
        public decimal Target { get; }

        /// <summary>Spread assumed at the boundary for the opposite quote side.</summary>
        public decimal Spread { get; }

        /// <summary>Projected Bid of the simultaneous closing quote, the close price of BUY legs before slippage.</summary>
        public decimal Bid { get; }

        /// <summary>Projected Ask of the simultaneous closing quote, the close price of SELL legs before slippage.</summary>
        public decimal Ask { get; }

        /// <summary>True when both projected prices are positive.</summary>
        public bool IsValid => Bid > 0m && Ask > 0m;
    }
}
