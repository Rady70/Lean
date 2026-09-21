using System;
using System.Collections.Generic;

namespace MarketLab.SingleAnchor
{
    /// <summary>
    /// The one basket the strategy manages at a time: a fixed anchor, the two fixed grid levels
    /// derived from it, the two hard-breakeven targets, the ordered legs, and the trailing state.
    /// Everything here stays fixed or accumulates until the basket closes; nothing is recomputed
    /// from later prices (specification sections 2, 6, 13, 15).
    /// </summary>
    /// <remarks>
    /// Besides the leg list (kept for audit and reporting) the basket maintains the aggregates
    /// that make every per-quote valuation constant-time: BUY and SELL lots and the entry-price
    /// notionals (sum of entry price times lots per side). Every leg is a whole number of volume
    /// steps, so the signed net exposure is exact and "net-flat" is exactly zero.
    /// </remarks>
    public sealed class Basket
    {
        private readonly List<BasketLeg> _legs = new List<BasketLeg>();
        private readonly List<EntryRejectionRecord> _rejections = new List<EntryRejectionRecord>();
        private readonly decimal _volumeStep;

        internal Basket(int sequence, in Quote anchorQuote, SingleAnchorParameters parameters)
            : this(sequence, 0, anchorQuote, parameters)
        {
        }

        internal Basket(int sequence, long anchorQuoteSequence, in Quote anchorQuote, SingleAnchorParameters parameters)
        {
            Sequence = sequence;
            AnchorQuoteSequence = anchorQuoteSequence;
            AnchorQuote = anchorQuote;
            CreatedTime = anchorQuote.Time;
            Anchor = anchorQuote.Mid;
            Step = Anchor * parameters.StepPercent / 100m;
            Upper = Anchor + Step;
            Lower = Anchor - Step;
            UpperTarget = Anchor * (1m + parameters.HardBreakevenCeilingPercent / 100m);
            LowerTarget = Anchor * (1m - parameters.HardBreakevenCeilingPercent / 100m);
            _volumeStep = parameters.VolumeStep;
        }

        /// <summary>1-based number of this basket in the engine's lifetime.</summary>
        public int Sequence { get; }

        /// <summary>Sequence number of the engine quote whose midpoint became the anchor (0 when built outside the engine).</summary>
        public long AnchorQuoteSequence { get; }

        /// <summary>The quote whose midpoint became the anchor (its Bid and Ask are the source prices).</summary>
        public Quote AnchorQuote { get; }

        /// <summary>Time of the quote whose midpoint became the anchor.</summary>
        public DateTime CreatedTime { get; }

        /// <summary>A = (Bid + Ask) / 2 at creation.</summary>
        public decimal Anchor { get; }

        /// <summary>S = A * P / 100.</summary>
        public decimal Step { get; }

        /// <summary>Upper = A + S; a BUY triggers when Ask >= Upper.</summary>
        public decimal Upper { get; }

        /// <summary>Lower = A - S; a SELL triggers when Bid <= Lower.</summary>
        public decimal Lower { get; }

        /// <summary>T_up = A * (1 + C / 100), the hard target for a required BUY.</summary>
        public decimal UpperTarget { get; }

        /// <summary>T_down = A * (1 - C / 100), the hard target for a required SELL.</summary>
        public decimal LowerTarget { get; }

        /// <summary>Legs in entry order (audit; valuations use the aggregates below).</summary>
        public IReadOnlyList<BasketLeg> Legs => _legs;

        /// <summary>Every rejected-entry situation of this basket, in order; repeats are counted on their row.</summary>
        public IReadOnlyList<EntryRejectionRecord> Rejections => _rejections;

        /// <summary>The anchoring event of this basket as a trace row.</summary>
        public AnchorRecord AnchorEvent => new AnchorRecord(Sequence, AnchorQuoteSequence, CreatedTime, AnchorQuote.Bid, AnchorQuote.Ask, Anchor, Step, Upper, Lower, LowerTarget, UpperTarget);

        /// <summary>Number of open positions.</summary>
        public int OpenPositions => _legs.Count;

        /// <summary>Total open BUY volume in lots.</summary>
        public decimal BuyLots { get; private set; }

        /// <summary>Total open SELL volume in lots.</summary>
        public decimal SellLots { get; private set; }

        /// <summary>Sum of entry price times lots over the BUY legs.</summary>
        public decimal BuyNotional { get; private set; }

        /// <summary>Sum of entry price times lots over the SELL legs.</summary>
        public decimal SellNotional { get; private set; }

        /// <summary>BuyLots + SellLots.</summary>
        public decimal GrossLots => BuyLots + SellLots;

        /// <summary>N = BuyLots - SellLots (specification section 10).</summary>
        public decimal NetLots => BuyLots - SellLots;

        /// <summary>
        /// True when the signed net exposure is exactly zero. Every leg is a whole number of
        /// volume steps and the arithmetic is exact decimal, so no tolerance is needed.
        /// </summary>
        public bool IsNetFlat => NetLots == 0m;

        /// <summary>MinLot: the smallest currently open position size, or 0 with no legs.</summary>
        public decimal SmallestOpenLots { get; private set; }

        /// <summary>Side of the most recent leg, or null before the first entry.</summary>
        public TradeSide? LastSide { get; private set; }

        /// <summary>
        /// Side the next leg must take: the opposite of the last leg, or null before the first
        /// entry (either boundary may open the basket).
        /// </summary>
        public TradeSide? NextRequiredSide => LastSide?.Opposite();

        /// <summary>Trade number the next entry would carry.</summary>
        public int NextTradeNumber => _legs.Count + 1;

        /// <summary>
        /// True once a trade beyond Nnormal has been required; stays true until the basket closes
        /// (specification section 5), including when that trade turned out to be infeasible.
        /// </summary>
        public bool HardBreakevenModeActive { get; private set; }

        /// <summary>True after trailing activated (specification section 13).</summary>
        public bool TrailingActive { get; private set; }

        /// <summary>Highest basket profit seen since trailing activated.</summary>
        public decimal PeakProfit { get; private set; }

        /// <summary>
        /// The most recent rejected entry attempt for this basket, kept so an unchanged
        /// situation is reported once rather than on every quote; cleared by a filled entry.
        /// </summary>
        public EntryRejection? LastRejection { get; internal set; }

        /// <summary>
        /// The quotes on which this basket, still empty, satisfied both first-entry boundaries and
        /// therefore could not start (specification section 3). Null until the first such quote.
        /// One compact row per basket; no per-tick records.
        /// </summary>
        public SkippedFirstEntryRecord? SkippedFirstEntry { get; private set; }

        internal void AddLeg(BasketLeg leg)
        {
            if (decimal.Remainder(leg.Lots, _volumeStep) != 0m)
            {
                throw new InvalidOperationException($"Leg volume {leg.Lots} is not a whole multiple of the volume step {_volumeStep}.");
            }
            _legs.Add(leg);
            if (leg.Side == TradeSide.Buy)
            {
                BuyLots += leg.Lots;
                BuyNotional += leg.EntryPrice * leg.Lots;
            }
            else
            {
                SellLots += leg.Lots;
                SellNotional += leg.EntryPrice * leg.Lots;
            }
            SmallestOpenLots = _legs.Count == 1 ? leg.Lots : Math.Min(SmallestOpenLots, leg.Lots);
            LastSide = leg.Side;
            LastRejection = null;
        }

        internal void AddRejection(EntryRejectionRecord record)
        {
            _rejections.Add(record);
        }

        internal SkippedFirstEntryRecord RecordSkippedFirstEntry(long quoteSequence, in Quote quote)
        {
            if (SkippedFirstEntry == null)
            {
                SkippedFirstEntry = new SkippedFirstEntryRecord(Sequence, quoteSequence, quote);
            }
            else
            {
                SkippedFirstEntry.Repeat(quoteSequence, quote);
            }
            return SkippedFirstEntry;
        }

        internal void ActivateHardBreakevenMode()
        {
            HardBreakevenModeActive = true;
        }

        internal void ActivateTrailing(decimal profit)
        {
            TrailingActive = true;
            PeakProfit = profit;
        }

        internal void UpdatePeak(decimal profit)
        {
            if (profit > PeakProfit) PeakProfit = profit;
        }

        /// <inheritdoc />
        public override string ToString()
        {
            return $"#{Sequence} anchor={Anchor} step={Step} upper={Upper} lower={Lower} targets=[{LowerTarget}, {UpperTarget}] legs={OpenPositions} buy={BuyLots} sell={SellLots} net={NetLots} hardBE={HardBreakevenModeActive} trailing={TrailingActive}";
        }
    }
}
