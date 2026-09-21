using System;
using System.Globalization;

namespace MarketLab.SingleAnchor
{
    /// <summary>
    /// The SingleAnchor vNext state machine (specification section 16), independent of any host.
    /// Feed it one <see cref="Quote"/> at a time through <see cref="OnQuote"/>; it decides, asks the
    /// <see cref="IBasketExecutor"/> to execute, and keeps its own basket ledger. A quote that
    /// neither triggers an entry nor fires an exit costs one pass over the open legs and no
    /// allocation; a trigger quote whose entry stays infeasible re-runs the sizing and records the
    /// attempt without raising a second event for the same situation.
    /// </summary>
    /// <remarks>
    /// Order of work on every quote (sections 14 and 15):
    /// <list type="number">
    /// <item>reject an invalid or out-of-order quote explicitly;</item>
    /// <item>with no basket, anchor a new one on this quote's midpoint;</item>
    /// <item>accrue configured swap for the legs that crossed a rollover;</item>
    /// <item>while an execution is pending with the host, observe only;</item>
    /// <item>with open legs: escape, then fixed take-profit, then trailing; a close ends the quote
    /// (no replacement basket on the same quote); a failed close also ends the quote;</item>
    /// <item>otherwise evaluate the next alternating entry.</item>
    /// </list>
    /// </remarks>
    public sealed class SingleAnchorEngine
    {
        private sealed class PendingEntry
        {
            public PendingEntry(EntryOrder order) { Order = order; }
            public EntryOrder Order { get; }
            public bool SkipReported { get; set; }
        }

        private sealed class PendingClose
        {
            public PendingClose(CloseOrder order, decimal rawProfit, decimal exitProfit, decimal threshold)
            {
                Order = order;
                RawProfit = rawProfit;
                ExitProfit = exitProfit;
                Threshold = threshold;
            }
            public CloseOrder Order { get; }
            public decimal RawProfit { get; }
            public decimal ExitProfit { get; }
            public decimal Threshold { get; }
            public bool SkipReported { get; set; }
        }

        private readonly SingleAnchorParameters _p;
        private readonly IBasketExecutor _executor;
        private Basket? _basket;
        private PendingEntry? _pendingEntry;
        private PendingClose? _pendingClose;
        private DateTime _lastQuoteTime;
        private bool _hasQuote;

        /// <summary>
        /// Creates an engine. Throws <see cref="ArgumentException"/> when the parameters are invalid.
        /// </summary>
        public SingleAnchorEngine(SingleAnchorParameters parameters, IBasketExecutor executor)
        {
            _p = parameters ?? throw new ArgumentNullException(nameof(parameters));
            _executor = executor ?? throw new ArgumentNullException(nameof(executor));
            _p.Validate();
        }

        /// <summary>The validated parameters.</summary>
        public SingleAnchorParameters Parameters => _p;

        /// <summary>The current basket (anchored, with or without legs), or null between baskets.</summary>
        public Basket? Basket => _basket;

        /// <summary>The entry order awaiting the host's fill, if any.</summary>
        public EntryOrder? PendingEntryOrder => _pendingEntry?.Order;

        /// <summary>The close order awaiting the host's fill, if any.</summary>
        public CloseOrder? PendingCloseOrder => _pendingClose?.Order;

        /// <summary>True while an entry or a close is pending with the host.</summary>
        public bool HasPendingExecution => _pendingEntry != null || _pendingClose != null;

        /// <summary>Quotes accepted by <see cref="OnQuote"/>.</summary>
        public long QuotesProcessed { get; private set; }

        /// <summary>Legs opened over the engine's lifetime.</summary>
        public long EntriesOpened { get; private set; }

        /// <summary>Distinct rejected-entry situations (each raised as one <see cref="EntryRejected"/>).</summary>
        public long EntriesRejected { get; private set; }

        /// <summary>Every rejected entry attempt, including repeats of the same situation.</summary>
        public long RejectedEntryAttempts { get; private set; }

        /// <summary>Baskets closed by an exit rule.</summary>
        public long BasketsClosed { get; private set; }

        /// <summary>Raised when a basket is anchored.</summary>
        public event Action<AnchorCreatedEvent>? AnchorCreated;

        /// <summary>Raised when a leg is filled and added to the basket.</summary>
        public event Action<EntryOpenedEvent>? EntryOpened;

        /// <summary>Raised when the host accepts an entry order it will fill later.</summary>
        public event Action<EntryPendingEvent>? EntryPending;

        /// <summary>Raised once per distinct rejected-entry situation, including hard-BE infeasibility.</summary>
        public event Action<EntryRejectedEvent>? EntryRejected;

        /// <summary>Raised when trailing activates.</summary>
        public event Action<TrailingActivatedEvent>? TrailingActivated;

        /// <summary>Raised when the host accepts a close order it will fill later.</summary>
        public event Action<BasketClosePendingEvent>? BasketClosePending;

        /// <summary>Raised when a basket is closed.</summary>
        public event Action<BasketClosedEvent>? BasketClosed;

        /// <summary>Raised when the host could not close the basket.</summary>
        public event Action<BasketCloseFailedEvent>? BasketCloseFailed;

        /// <summary>Raised when a quote is ignored.</summary>
        public event Action<InvalidQuoteEvent>? InvalidQuote;

        /// <summary>Raised once per pending execution when quotes arrive while it is outstanding.</summary>
        public event Action<QuoteSkippedWhilePendingEvent>? QuoteSkippedWhilePending;

        /// <summary>
        /// Processes one quote. Returns without side effects for an invalid or out-of-order quote.
        /// </summary>
        public void OnQuote(in Quote quote)
        {
            if (!quote.IsValid)
            {
                InvalidQuote.Raise(new InvalidQuoteEvent(quote, "Quote ignored: bid and ask must be positive and the ask must not be below the bid."));
                return;
            }
            if (_hasQuote && quote.Time < _lastQuoteTime)
            {
                InvalidQuote.Raise(new InvalidQuoteEvent(quote, $"Quote ignored: time {quote.Time:O} is earlier than the previous quote {_lastQuoteTime:O}."));
                return;
            }
            _lastQuoteTime = quote.Time;
            _hasQuote = true;
            QuotesProcessed++;

            if (_basket == null)
            {
                _basket = new Basket(quote, _p);
                AnchorCreated.Raise(new AnchorCreatedEvent(_basket, quote));
            }
            var basket = _basket;

            if (basket.OpenPositions > 0)
            {
                AccrueSwap(basket, quote);
            }

            if (_pendingEntry != null)
            {
                if (!_pendingEntry.SkipReported)
                {
                    _pendingEntry.SkipReported = true;
                    QuoteSkippedWhilePending.Raise(new QuoteSkippedWhilePendingEvent(basket, quote, $"Entry order for trade {_pendingEntry.Order.TradeNumber} ({_pendingEntry.Order.Side} {F(_pendingEntry.Order.Lots)}) is still pending; observing only."));
                }
                return;
            }
            if (_pendingClose != null)
            {
                if (!_pendingClose.SkipReported)
                {
                    _pendingClose.SkipReported = true;
                    QuoteSkippedWhilePending.Raise(new QuoteSkippedWhilePendingEvent(basket, quote, $"Close order ({_pendingClose.Order.Reason}) is still pending; observing only."));
                }
                return;
            }

            if (basket.OpenPositions > 0)
            {
                var rawProfit = BasketEconomics.RawProfit(basket, quote, _p);
                var exitProfit = rawProfit - BasketEconomics.CommissionBufferAmount(basket, _p);
                var stepMoney = BasketEconomics.StepMoney(basket, _p);
                var (reason, threshold) = EvaluateExits(basket, exitProfit, stepMoney, quote);
                if (reason != ExitReason.None)
                {
                    var close = new CloseOrder(basket, reason, quote);
                    var result = _executor.CloseBasket(close);
                    switch (result.Status)
                    {
                        case ExecutionStatus.Filled:
                            FinalizeClose(close, rawProfit, exitProfit, threshold, result.FillPrice > 0m ? result.FillPrice : null);
                            break;
                        case ExecutionStatus.Pending:
                            _pendingClose = new PendingClose(close, rawProfit, exitProfit, threshold);
                            BasketClosePending.Raise(new BasketClosePendingEvent(basket, reason, quote));
                            break;
                        default:
                            BasketCloseFailed.Raise(new BasketCloseFailedEvent(basket, reason, quote, result.Message ?? "The host rejected the close order."));
                            break;
                    }
                    // A close that fired ends the quote whether it filled, is pending or failed:
                    // no replacement basket and no new leg on the same quote.
                    return;
                }
            }

            EvaluateEntry(basket, quote);
        }

        /// <summary>
        /// Reports the fill of the pending entry order. The leg is recorded with the actual fill.
        /// </summary>
        public void ConfirmPendingEntry(decimal fillPrice, decimal filledLots, DateTime fillTime)
        {
            var pending = _pendingEntry ?? throw new InvalidOperationException("No entry order is pending.");
            _pendingEntry = null;
            var basket = _basket ?? throw new InvalidOperationException("An entry was pending without a basket.");
            RecordFill(basket, pending.Order, fillPrice, filledLots, fillTime);
        }

        /// <summary>
        /// Reports that the pending entry order was rejected or cancelled; the grid stays where it was.
        /// </summary>
        public void RejectPendingEntry(string message)
        {
            var pending = _pendingEntry ?? throw new InvalidOperationException("No entry order is pending.");
            _pendingEntry = null;
            var basket = _basket ?? throw new InvalidOperationException("An entry was pending without a basket.");
            var order = pending.Order;
            Reject(basket, order.Quote, new EntryRejection(order.TradeNumber, order.Side, EntryRejectionReason.ExecutionFailed, order.Lots, message ?? "The pending entry order was rejected.", order.Sizing));
        }

        /// <summary>
        /// Reports the fill of the pending close order; the basket is closed and reset.
        /// </summary>
        public void ConfirmPendingClose(decimal? hostFillPrice)
        {
            var pending = _pendingClose ?? throw new InvalidOperationException("No close order is pending.");
            _pendingClose = null;
            FinalizeClose(pending.Order, pending.RawProfit, pending.ExitProfit, pending.Threshold, hostFillPrice);
        }

        /// <summary>
        /// Reports that the pending close order was rejected or cancelled; the basket stays open and
        /// the exit rules are evaluated again on the next quote.
        /// </summary>
        public void RejectPendingClose(string message)
        {
            var pending = _pendingClose ?? throw new InvalidOperationException("No close order is pending.");
            _pendingClose = null;
            var order = pending.Order;
            BasketCloseFailed.Raise(new BasketCloseFailedEvent(order.Basket, order.Reason, order.Quote, message ?? "The pending close order was rejected."));
        }

        /// <summary>
        /// Values the open basket at a quote without changing anything (end-of-data mark to market,
        /// specification section 15). Null when there is no basket with legs.
        /// </summary>
        public BasketValuation? MarkToMarket(in Quote quote)
        {
            var basket = _basket;
            if (basket == null || basket.OpenPositions == 0 || !quote.IsValid)
            {
                return null;
            }
            var raw = BasketEconomics.RawProfit(basket, quote, _p);
            return new BasketValuation(quote, basket.OpenPositions, basket.BuyLots, basket.SellLots, basket.GrossLots, basket.NetLots,
                raw, raw - BasketEconomics.CommissionBufferAmount(basket, _p), BasketEconomics.StepMoney(basket, _p),
                basket.HardBreakevenModeActive, basket.TrailingActive, basket.PeakProfit);
        }

        private (ExitReason Reason, decimal Threshold) EvaluateExits(Basket basket, decimal exitProfit, decimal stepMoney, in Quote quote)
        {
            if (_p.EscapeEnabled && basket.OpenPositions >= _p.EscapeMinimumOpenPositions)
            {
                var escape = _p.EscapeProfitUnits * stepMoney;
                if (exitProfit >= escape) return (ExitReason.Escape, escape);
            }

            if (_p.FixedTakeProfitUnits > 0m)
            {
                var takeProfit = _p.FixedTakeProfitUnits * stepMoney;
                if (exitProfit >= takeProfit) return (ExitReason.FixedTakeProfit, takeProfit);
            }

            if (_p.TrailingEnabled)
            {
                if (!basket.TrailingActive)
                {
                    var activation = _p.TrailingActivationUnits * stepMoney;
                    if (exitProfit >= activation)
                    {
                        basket.ActivateTrailing(exitProfit);
                        TrailingActivated.Raise(new TrailingActivatedEvent(basket, exitProfit, activation, quote));
                    }
                }
                else
                {
                    basket.UpdatePeak(exitProfit);
                }

                if (basket.TrailingActive)
                {
                    var floor = basket.PeakProfit - _p.TrailingDropUnits * stepMoney;
                    if (exitProfit <= floor) return (ExitReason.Trailing, floor);
                }
            }

            return (ExitReason.None, 0m);
        }

        private void EvaluateEntry(Basket basket, in Quote quote)
        {
            TradeSide side;
            if (basket.OpenPositions == 0)
            {
                // Either boundary opens the basket; the BUY condition is checked first, as written
                // in specification section 3, for the rare quote that satisfies both.
                if (quote.Ask >= basket.Upper) side = TradeSide.Buy;
                else if (quote.Bid <= basket.Lower) side = TradeSide.Sell;
                else return;
            }
            else
            {
                side = basket.NextRequiredSide!.Value;
                var triggered = side == TradeSide.Buy ? quote.Ask >= basket.Upper : quote.Bid <= basket.Lower;
                if (!triggered) return;
            }

            var tradeNumber = basket.NextTradeNumber;
            decimal lots;
            SizingRegime regime;
            HardBreakevenSizing? sizing = null;
            if (tradeNumber <= _p.NormalTradeCount)
            {
                regime = SizingRegime.Arithmetic;
                var requested = _p.BaseLot * tradeNumber;
                lots = Math.Max(VolumeMath.RoundToNearestStep(requested, _p.VolumeStep), _p.MinimumVolume);
                if (lots > _p.MaximumVolume)
                {
                    Reject(basket, quote, new EntryRejection(tradeNumber, side, EntryRejectionReason.VolumeExceedsMaximum, lots,
                        $"Arithmetic lot for trade {tradeNumber} ({F(requested)} -> {F(lots)}) exceeds the maximum volume {F(_p.MaximumVolume)}; the order is not placed.", null));
                    return;
                }
            }
            else
            {
                regime = SizingRegime.HardBreakeven;
                basket.ActivateHardBreakevenMode();
                sizing = HardBreakevenSizer.Size(basket, side, quote, _p);
                if (!sizing.IsFeasible)
                {
                    Reject(basket, quote, new EntryRejection(tradeNumber, side, EntryRejectionReason.HardBreakevenInfeasible, sizing.RequiredLot, sizing.Message, sizing));
                    return;
                }
                lots = sizing.NormalizedLot;
            }

            var order = new EntryOrder(tradeNumber, side, lots, quote, regime, sizing);
            var result = _executor.OpenPosition(order);
            switch (result.Status)
            {
                case ExecutionStatus.Filled:
                    RecordFill(basket, order, result.FillPrice, result.FilledLots, quote.Time);
                    break;
                case ExecutionStatus.Pending:
                    _pendingEntry = new PendingEntry(order);
                    EntryPending.Raise(new EntryPendingEvent(basket, order));
                    break;
                default:
                    Reject(basket, quote, new EntryRejection(tradeNumber, side, EntryRejectionReason.ExecutionFailed, lots, result.Message ?? "The host rejected the entry order.", sizing));
                    break;
            }
        }

        private void RecordFill(Basket basket, EntryOrder order, decimal fillPrice, decimal filledLots, DateTime fillTime)
        {
            if (fillPrice <= 0m || filledLots <= 0m)
            {
                Reject(basket, order.Quote, new EntryRejection(order.TradeNumber, order.Side, EntryRejectionReason.ExecutionFailed, order.Lots,
                    $"The host reported an unusable fill for trade {order.TradeNumber}: price {F(fillPrice)}, lots {F(filledLots)}.", order.Sizing));
                return;
            }

            var leg = new BasketLeg(order.TradeNumber, order.Side, filledLots, fillPrice, fillTime, order.Regime);
            basket.AddLeg(leg);
            if (_p.SwapConfigured && basket.OpenPositions == 1)
            {
                basket.NextRolloverTime = NextRolloverAfter(fillTime);
            }
            EntriesOpened++;
            EntryOpened.Raise(new EntryOpenedEvent(basket, leg, order.Quote, order.Sizing));
        }

        private void Reject(Basket basket, in Quote quote, EntryRejection rejection)
        {
            RejectedEntryAttempts++;
            var isNew = !rejection.SameSituationAs(basket.LastRejection);
            basket.LastRejection = rejection;
            if (isNew)
            {
                EntriesRejected++;
                EntryRejected.Raise(new EntryRejectedEvent(basket, rejection, quote));
            }
        }

        private void FinalizeClose(CloseOrder order, decimal rawProfit, decimal exitProfit, decimal threshold, decimal? hostFillPrice)
        {
            _basket = null;
            BasketsClosed++;
            BasketClosed.Raise(new BasketClosedEvent(order.Basket, order.Reason, order.Quote, rawProfit, exitProfit, threshold, hostFillPrice));
        }

        private void AccrueSwap(Basket basket, in Quote quote)
        {
            if (!_p.SwapConfigured || basket.NextRolloverTime == null) return;
            var next = basket.NextRolloverTime.Value;
            if (next > quote.Time) return;

            var legs = basket.Legs;
            while (next <= quote.Time)
            {
                // The rollover at instant R ends the trading day that contains R - 1 tick. Weekend
                // days are never charged; the configured triple-swap day is charged three times;
                // only legs opened strictly before R are charged (a fill reported after R, from a
                // pending order, is not).
                var closingDay = next.AddTicks(-1).DayOfWeek;
                if (closingDay != DayOfWeek.Saturday && closingDay != DayOfWeek.Sunday)
                {
                    var multiplier = _p.TripleSwapDay == closingDay ? 3m : 1m;
                    for (var i = 0; i < legs.Count; i++)
                    {
                        var leg = legs[i];
                        if (leg.EntryTime >= next) continue;
                        var rate = leg.Side == TradeSide.Buy ? _p.BuySwapPerLotPerDay : _p.SellSwapPerLotPerDay;
                        leg.AccruedSwap += leg.Lots * rate * multiplier;
                    }
                }
                next = next.AddDays(1);
            }
            basket.NextRolloverTime = next;
        }

        private DateTime NextRolloverAfter(DateTime time)
        {
            var candidate = time.Date + _p.SwapRolloverTimeOfDay;
            return candidate > time ? candidate : candidate.AddDays(1);
        }

        private static string F(decimal value)
        {
            return value.ToString(CultureInfo.InvariantCulture);
        }
    }
}
