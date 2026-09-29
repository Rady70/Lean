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
        private readonly List<LiquidatedLegRecord> _liquidations = new List<LiquidatedLegRecord>();
        private readonly decimal _volumeStep;
        private int _nextTradeNumber = 1;
        private TradeSide? _lastEntrySide;
        private int _historicalEntries;

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

        /// <summary>T_up = A * (1 + C / 100), the upper hard-BE boundary for a required BUY (the actual BE must stay at or below it).</summary>
        public decimal UpperTarget { get; }

        /// <summary>T_down = A * (1 - C / 100), the lower hard-BE boundary for a required SELL (the actual BE must stay at or above it).</summary>
        public decimal LowerTarget { get; }

        /// <summary>Legs still open in entry order (audit; valuations use the aggregates below).</summary>
        public IReadOnlyList<BasketLeg> Legs => _legs;

        /// <summary>
        /// Positions removed from this basket by deterministic broker-forced liquidation, in
        /// liquidation order, with their immutable identities and forced-close prices. A leg the
        /// broker removed is never a strategy exit and never disappears from the basket's history.
        /// The trace is a read-only view; it grows only by a forced close.
        /// </summary>
        public IReadOnlyList<LiquidatedLegRecord> LiquidationTrace => _liquidations.AsReadOnly();

        /// <summary>Number of positions this basket opened over its lifetime, including liquidated ones.</summary>
        public int HistoricalEntries => _historicalEntries;

        /// <summary>Number of positions removed by broker-forced liquidation so far.</summary>
        public int LiquidatedPositions => _liquidations.Count;

        /// <summary>Realized executable P/L of the positions removed by broker-forced liquidation (commission included).</summary>
        public decimal LiquidatedRealizedProfit { get; private set; }

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

        /// <summary>Side of the most recent leg ever opened in this basket, or null before the first entry.</summary>
        /// <remarks>
        /// This is the basket's historical entry sequence, not its surviving inventory: a leg
        /// removed by broker liquidation does not change the side the next entry must take.
        /// </remarks>
        public TradeSide? LastSide => _lastEntrySide;

        /// <summary>
        /// Side the next leg must take: the opposite of the most recent historical leg, or null
        /// before the first entry (either boundary may open the basket). Broker liquidation of a
        /// leg does not reorder the historical entry sequence.
        /// </summary>
        public TradeSide? NextRequiredSide => _lastEntrySide?.Opposite();

        /// <summary>
        /// Trade number the next entry would carry. It is the basket's monotonic historical
        /// sequence and never falls back when positions are removed by broker liquidation.
        /// </summary>
        public int NextTradeNumber => _nextTradeNumber;

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
        /// The most recent rejected entry attempt for this basket (audit); cleared by a filled entry.
        /// The engine's episode scan, not this property, folds repeats into one trace row.
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
            _lastEntrySide = leg.Side;
            _historicalEntries++;
            if (leg.TradeNumber >= _nextTradeNumber)
            {
                _nextTradeNumber = leg.TradeNumber + 1;
            }
            LastRejection = null;
        }

        /// <summary>
        /// Removes one open position because the broker force-closed it during deterministic Stop Out
        /// liquidation, and records the forced close in the basket's liquidation trace. The leg's
        /// immutable identity is copied; the surviving aggregates and the smallest open lot are
        /// recomputed from the surviving inventory. The historical entry sequence, the trade
        /// numbering and hard-BE state are deliberately untouched.
        /// </summary>
        internal LiquidatedLegRecord RemoveLeg(
            BasketLeg leg,
            in Quote triggerQuote,
            long triggerQuoteSequence,
            decimal closePrice,
            decimal commission,
            decimal realizedProfit,
            StopOutReason reason,
            int ordinal)
        {
            if (leg == null) throw new ArgumentNullException(nameof(leg));
            var index = _legs.IndexOf(leg);
            if (index < 0)
            {
                throw new InvalidOperationException($"Leg {leg} is not an open position of basket #{Sequence}.");
            }
            _legs.RemoveAt(index);
            if (leg.Side == TradeSide.Buy)
            {
                BuyLots -= leg.Lots;
                BuyNotional -= leg.EntryPrice * leg.Lots;
            }
            else
            {
                SellLots -= leg.Lots;
                SellNotional -= leg.EntryPrice * leg.Lots;
            }
            SmallestOpenLots = SmallestLot();
            var record = new LiquidatedLegRecord(
                Sequence,
                leg.TradeNumber,
                leg.Side,
                leg.Lots,
                leg.EntryPrice,
                leg.EntryTime,
                leg.Regime,
                leg.RawRequestedLots,
                leg.Sizing?.ExactRequired,
                leg.Sizing?.NormalizedRequiredLot ?? leg.Lots,
                triggerQuote.Time,
                triggerQuote.Time,
                triggerQuoteSequence,
                triggerQuote.Bid,
                triggerQuote.Ask,
                closePrice,
                commission,
                realizedProfit,
                reason,
                ordinal);
            _liquidations.Add(record);
            LiquidatedRealizedProfit += realizedProfit;
            return record;
        }

        private decimal SmallestLot()
        {
            if (_legs.Count == 0)
            {
                return 0m;
            }
            var smallest = _legs[0].Lots;
            for (var i = 1; i < _legs.Count; i++)
            {
                if (_legs[i].Lots < smallest)
                {
                    smallest = _legs[i].Lots;
                }
            }
            return smallest;
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
