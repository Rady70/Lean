using System;

namespace MarketLab.SingleAnchor
{
    /// <summary>
    /// Which sizing rule produced a leg (specification section 18).
    /// </summary>
    public enum SizingRegime
    {
        /// <summary>Trades 1..Nnormal: Q_n = B * n (section 4).</summary>
        Arithmetic,

        /// <summary>Trade Nnormal+1 onward: hard fixed-breakeven sizing (sections 5-8).</summary>
        HardBreakeven
    }

    /// <summary>
    /// One open position of the basket, kept individually so BUY lots, SELL lots, entry prices
    /// and the entry sequence stay distinguishable regardless of how the host nets holdings.
    /// </summary>
    public sealed class BasketLeg
    {
        internal BasketLeg(int tradeNumber, TradeSide side, decimal lots, decimal entryPrice, DateTime entryTime, SizingRegime regime)
        {
            if (tradeNumber < 1) throw new ArgumentOutOfRangeException(nameof(tradeNumber), tradeNumber, "Trade numbers start at 1.");
            if (lots <= 0m) throw new ArgumentOutOfRangeException(nameof(lots), lots, "A leg needs a positive volume.");
            if (entryPrice <= 0m) throw new ArgumentOutOfRangeException(nameof(entryPrice), entryPrice, "A leg needs a positive entry price.");

            TradeNumber = tradeNumber;
            Side = side;
            Lots = lots;
            EntryPrice = entryPrice;
            EntryTime = entryTime;
            Regime = regime;
        }

        /// <summary>1-based position of this leg in the basket's entry sequence.</summary>
        public int TradeNumber { get; }

        /// <summary>BUY or SELL.</summary>
        public TradeSide Side { get; }

        /// <summary>Filled volume in lots.</summary>
        public decimal Lots { get; }

        /// <summary>Actual fill price reported by the host.</summary>
        public decimal EntryPrice { get; }

        /// <summary>Fill time in the quote clock.</summary>
        public DateTime EntryTime { get; }

        /// <summary>Sizing rule that produced the leg.</summary>
        public SizingRegime Regime { get; }

        /// <summary>
        /// Swap/financing credited (positive) or charged (negative) to this leg so far, in account
        /// currency. Zero unless swap is configured.
        /// </summary>
        public decimal AccruedSwap { get; internal set; }

        /// <summary>The hard-BE sizing that produced this leg; null for an arithmetic leg.</summary>
        public HardBreakevenSizing? Sizing { get; internal set; }

        /// <inheritdoc />
        public override string ToString()
        {
            return $"#{TradeNumber} {Side} {Lots} @ {EntryPrice} ({Regime}, swap {AccruedSwap})";
        }
    }
}
