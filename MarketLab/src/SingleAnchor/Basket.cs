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
    public sealed class Basket
    {
        private readonly List<BasketLeg> _legs = new List<BasketLeg>();
        private readonly decimal _volumeStep;

        internal Basket(in Quote anchorQuote, SingleAnchorParameters parameters)
        {
            CreatedTime = anchorQuote.Time;
            Anchor = anchorQuote.Mid;
            Step = Anchor * parameters.StepPercent / 100m;
            Upper = Anchor + Step;
            Lower = Anchor - Step;
            UpperTarget = Anchor * (1m + parameters.HardBreakevenCeilingPercent / 100m);
            LowerTarget = Anchor * (1m - parameters.HardBreakevenCeilingPercent / 100m);
            _volumeStep = parameters.VolumeStep;
        }

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

        /// <summary>Legs in entry order.</summary>
        public IReadOnlyList<BasketLeg> Legs => _legs;

        /// <summary>Number of open positions.</summary>
        public int OpenPositions => _legs.Count;

        /// <summary>Total open BUY volume in lots.</summary>
        public decimal BuyLots { get; private set; }

        /// <summary>Total open SELL volume in lots.</summary>
        public decimal SellLots { get; private set; }

        /// <summary>BuyLots + SellLots.</summary>
        public decimal GrossLots => BuyLots + SellLots;

        /// <summary>N = BuyLots - SellLots (specification section 10).</summary>
        public decimal NetLots => BuyLots - SellLots;

        /// <summary>
        /// True when the signed net exposure is not meaningfully non-zero. Every leg is a whole
        /// number of volume steps, so a real exposure is at least one step; anything smaller than
        /// half a step is treated as flat.
        /// </summary>
        public bool IsNetFlat => Math.Abs(NetLots) < _volumeStep / 2m;

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
        /// Next rollover instant at which swap is evaluated, or null while swap is not configured
        /// or the basket has no legs.
        /// </summary>
        public DateTime? NextRolloverTime { get; internal set; }

        /// <summary>
        /// The most recent rejected entry attempt for this basket, kept so an unchanged
        /// infeasibility is reported once rather than on every tick; cleared by a filled entry.
        /// </summary>
        public EntryRejection? LastRejection { get; internal set; }

        internal void AddLeg(BasketLeg leg)
        {
            _legs.Add(leg);
            if (leg.Side == TradeSide.Buy) BuyLots += leg.Lots; else SellLots += leg.Lots;
            SmallestOpenLots = _legs.Count == 1 ? leg.Lots : Math.Min(SmallestOpenLots, leg.Lots);
            LastSide = leg.Side;
            LastRejection = null;
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
            return $"anchor={Anchor} step={Step} upper={Upper} lower={Lower} targets=[{LowerTarget}, {UpperTarget}] legs={OpenPositions} buy={BuyLots} sell={SellLots} net={NetLots} hardBE={HardBreakevenModeActive} trailing={TrailingActive}";
        }
    }
}
