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
            : this(tradeNumber, side, lots, entryPrice, entryTime, regime, 0, new Quote(entryTime, entryPrice, entryPrice))
        {
        }

        internal BasketLeg(int tradeNumber, TradeSide side, decimal lots, decimal entryPrice, DateTime entryTime, SizingRegime regime, long quoteSequence, in Quote triggerQuote)
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
            QuoteSequence = quoteSequence;
            TriggerQuote = triggerQuote;
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

        /// <summary>1-based number of the engine quote that triggered the leg (0 when built outside the engine).</summary>
        public long QuoteSequence { get; }

        /// <summary>The quote the entry decision was taken on (its Bid and Ask are the decision prices).</summary>
        public Quote TriggerQuote { get; }

        /// <summary>
        /// The raw requested lot of an arithmetic leg (B * trade number), before broker
        /// normalization; null for a hard-BE leg. Kept so the traces can distinguish the raw
        /// request from the normalized required lot and the placed lot.
        /// </summary>
        public decimal? RawRequestedLots { get; internal set; }

        /// <summary>The hard-BE sizing that produced this leg; null for an arithmetic leg.</summary>
        public HardBreakevenSizing? Sizing { get; internal set; }

        /// <inheritdoc />
        public override string ToString()
        {
            return $"#{TradeNumber} {Side} {Lots} @ {EntryPrice} ({Regime})";
        }
    }
}
