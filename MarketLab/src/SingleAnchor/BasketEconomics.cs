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
        /// RawProfit: the combined current profit of the surviving legs, BUY legs marked at the Bid
        /// and SELL legs at the Ask (section 9). Constant time. For the basket's lifetime economic
        /// basis (forced-liquidation P/L plus survivors) use <see cref="LifetimeRawProfit"/>.
        /// </summary>
        public static decimal RawProfit(Basket basket, in Quote quote, SingleAnchorParameters parameters)
        {
            if (basket == null) throw new ArgumentNullException(nameof(basket));
            if (parameters == null) throw new ArgumentNullException(nameof(parameters));
            return PriceProfit(basket, quote.Bid, quote.Ask, parameters.PointValuePerLot);
        }

        /// <summary>
        /// The basket's lifetime raw profit at a quote: the executable P/L already realized by
        /// broker-forced liquidation plus the raw profit of the surviving legs. This is the basis
        /// the strategy's exit rules use, so a partial liquidation never silently improves the
        /// surviving basket's decision economics: the forced P/L stays in the series. For a basket
        /// that never liquidated it equals <see cref="RawProfit"/> exactly. The survivor-only
        /// floating mark stays available as <see cref="RawProfit"/> and, on the account, as
        /// <c>FloatingProfit</c>.
        /// </summary>
        public static decimal LifetimeRawProfit(Basket basket, in Quote quote, SingleAnchorParameters parameters)
        {
            if (basket == null) throw new ArgumentNullException(nameof(basket));
            return basket.LiquidatedRealizedProfit + RawProfit(basket, quote, parameters);
        }

        /// <summary>
        /// Profit used for exit decisions: the basket's lifetime raw profit minus the optional
        /// commission buffer (section 9: Profit = RawProfit - CommissionBuffer, with the forced
        /// liquidation P/L included after a partial liquidation).
        /// </summary>
        public static decimal ExitProfit(Basket basket, in Quote quote, SingleAnchorParameters parameters)
        {
            return LifetimeRawProfit(basket, quote, parameters) - parameters!.CommissionBuffer;
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
        /// Executable close price of one position at the triggering quote under the configured
        /// execution model: a BUY closes at the Bid less slippage, a SELL at the Ask plus slippage.
        /// This is the correct market side the deterministic broker liquidation must use.
        /// </summary>
        public static decimal ExecutableLegClosePrice(TradeSide side, in Quote quote, SingleAnchorParameters parameters)
        {
            if (parameters == null) throw new ArgumentNullException(nameof(parameters));
            return side == TradeSide.Buy ? quote.Bid - parameters.Slippage : quote.Ask + parameters.Slippage;
        }

        /// <summary>
        /// Executable P/L of one position closed at <paramref name="closePrice"/>: the price move
        /// from its actual entry, valued at the configured point value, less the round-trip
        /// commission on its own volume. This is the position's value used by the broker's
        /// least-profitable-first liquidation ordering and by each forced close's realized P/L;
        /// summing it over every open leg reproduces the account's executable floating mark
        /// (raw profit less the per-lot cost on the gross volume).
        /// </summary>
        public static decimal ExecutableLegProfit(BasketLeg leg, decimal closePrice, SingleAnchorParameters parameters)
        {
            if (leg == null) throw new ArgumentNullException(nameof(leg));
            if (parameters == null) throw new ArgumentNullException(nameof(parameters));
            var priceMove = leg.Side == TradeSide.Buy ? closePrice - leg.EntryPrice : leg.EntryPrice - closePrice;
            return priceMove * leg.Lots * parameters.PointValuePerLot - parameters.CommissionPerLot * leg.Lots;
        }

        /// <summary>
        /// Executable P/L of one position at a quote: a BUY valued at the Bid less slippage, a
        /// SELL at the Ask plus slippage, each less its own round-trip commission. Used by the
        /// deterministic liquidation ordering.
        /// </summary>
        public static decimal ExecutableLegProfit(BasketLeg leg, in Quote quote, SingleAnchorParameters parameters)
        {
            return ExecutableLegProfit(leg, ExecutableLegClosePrice(leg.Side, quote, parameters), parameters);
        }

        /// <summary>
        /// Executable profit of the whole basket closed at the given per-side prices: price P/L
        /// less the round-trip commission on the gross volume. Used for the projection at a hard
        /// target (section 7), for the realized result of a close and for the executable
        /// mark-to-market of an open basket's surviving inventory. Constant time. For the basket's
        /// lifetime executable result (forced P/L plus survivors) use
        /// <see cref="LifetimeExecutableProfit"/>.
        /// </summary>
        public static decimal ExecutableProfit(Basket basket, decimal buyClosePrice, decimal sellClosePrice, SingleAnchorParameters parameters)
        {
            if (basket == null) throw new ArgumentNullException(nameof(basket));
            if (parameters == null) throw new ArgumentNullException(nameof(parameters));
            return PriceProfit(basket, buyClosePrice, sellClosePrice, parameters.PointValuePerLot)
                - parameters.CommissionPerLot * basket.GrossLots;
        }

        /// <summary>
        /// The basket's lifetime executable result at the given per-side prices: the P/L already
        /// realized by broker-forced liquidation plus the executable value of the surviving
        /// inventory (close-side slippage and round-trip commission included on the survivors).
        /// For a basket that never liquidated it equals <see cref="ExecutableProfit"/> exactly.
        /// </summary>
        public static decimal LifetimeExecutableProfit(Basket basket, decimal buyClosePrice, decimal sellClosePrice, SingleAnchorParameters parameters)
        {
            if (basket == null) throw new ArgumentNullException(nameof(basket));
            return basket.LiquidatedRealizedProfit + ExecutableProfit(basket, buyClosePrice, sellClosePrice, parameters);
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
        /// PL_existing(T): projected executable profit of every surviving leg at the boundary
        /// (section 7). Constant time; equal to the sum of <see cref="ProjectedLegProfit"/> over
        /// the legs. For the hard-BE sizing basis after a partial liquidation use
        /// <see cref="LifetimeProjectedExistingProfit"/>, which also carries the already realized
        /// broker-liquidation P/L.
        /// </summary>
        public static decimal ProjectedExistingProfit(Basket basket, in TargetPrices target, SingleAnchorParameters parameters)
        {
            var (buyClose, sellClose) = ExecutableClosePrices(target, parameters);
            return ExecutableProfit(basket, buyClose, sellClose, parameters);
        }

        /// <summary>
        /// The basket's lifetime projected executable P/L at the boundary: the P/L already realized
        /// by broker-forced liquidation plus the surviving legs' projected value. This is the basis
        /// the hard-BE sizing and its post-fill verification use, so a forced loss is not silently
        /// dropped from the next tail's requirement (and a forced profit is not silently ignored).
        /// For a basket that never liquidated it equals <see cref="ProjectedExistingProfit"/> exactly.
        /// </summary>
        public static decimal LifetimeProjectedExistingProfit(Basket basket, in TargetPrices target, SingleAnchorParameters parameters)
        {
            if (basket == null) throw new ArgumentNullException(nameof(basket));
            return basket.LiquidatedRealizedProfit + ProjectedExistingProfit(basket, target, parameters);
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
