using System;
using System.Collections.Generic;
using System.Globalization;

namespace MarketLab.SingleAnchor
{
    /// <summary>
    /// The SingleAnchor vNext state machine (specification section 16), independent of any host.
    /// Feed it one <see cref="Quote"/> at a time through <see cref="OnQuote"/>; it decides, has the
    /// <see cref="IBasketExecutor"/> fill, and keeps its own basket ledger: the strategy's truth,
    /// never a host's netted holding. A quote that neither triggers an entry nor fires an exit
    /// costs a constant amount of work (the basket is valued from its aggregates) and no
    /// allocation; a trigger quote whose entry stays infeasible re-runs the sizing and records the
    /// attempt without raising a second event for the same situation.
    /// </summary>
    /// <remarks>
    /// Order of work on every quote (sections 14 and 15):
    /// <list type="number">
    /// <item>reject an invalid or out-of-order quote explicitly;</item>
    /// <item>with no basket, anchor a new one on this quote's midpoint;</item>
    /// <item>accrue configured swap for the legs that crossed a rollover;</item>
    /// <item>with open legs: escape, then fixed take-profit, then trailing; a close ends the quote
    /// (no replacement basket on the same quote); a failed close also ends the quote;</item>
    /// <item>otherwise evaluate the next alternating entry; a tail fill is verified against the
    /// hard-BE requirement with its actual price.</item>
    /// </list>
    /// </remarks>
    public sealed class SingleAnchorEngine
    {
        private readonly SingleAnchorParameters _p;
        private readonly IBasketExecutor _executor;
        private readonly List<BasketCloseRecord> _closedBaskets = new List<BasketCloseRecord>();
        private Basket? _basket;
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

        /// <summary>Creates an engine with the deterministic <see cref="ResearchExecutor"/>.</summary>
        public SingleAnchorEngine(SingleAnchorParameters parameters)
            : this(parameters, new ResearchExecutor(parameters ?? throw new ArgumentNullException(nameof(parameters))))
        {
        }

        /// <summary>The validated parameters.</summary>
        public SingleAnchorParameters Parameters => _p;

        /// <summary>The current basket (anchored, with or without legs), or null between baskets.</summary>
        public Basket? Basket => _basket;

        /// <summary>The strategy's own record of every closed basket, in closing order.</summary>
        public IReadOnlyList<BasketCloseRecord> ClosedBaskets => _closedBaskets;

        /// <summary>Sum of the realized executable profit of every closed basket.</summary>
        public decimal RealizedProfit { get; private set; }

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

        /// <summary>Tail fills that left the hard-BE requirement unmet (see <see cref="HardBreakevenViolated"/>).</summary>
        public long HardBreakevenViolations { get; private set; }

        /// <summary>Raised when a basket is anchored.</summary>
        public event Action<AnchorCreatedEvent>? AnchorCreated;

        /// <summary>Raised when a leg is filled and added to the basket.</summary>
        public event Action<EntryOpenedEvent>? EntryOpened;

        /// <summary>Raised once per distinct rejected-entry situation, including hard-BE infeasibility.</summary>
        public event Action<EntryRejectedEvent>? EntryRejected;

        /// <summary>Raised when a tail fill fails the hard-BE verification with its actual price.</summary>
        public event Action<HardBreakevenViolatedEvent>? HardBreakevenViolated;

        /// <summary>Raised when trailing activates.</summary>
        public event Action<TrailingActivatedEvent>? TrailingActivated;

        /// <summary>Raised when a basket is closed.</summary>
        public event Action<BasketClosedEvent>? BasketClosed;

        /// <summary>Raised when the executor could not close the basket.</summary>
        public event Action<BasketCloseFailedEvent>? BasketCloseFailed;

        /// <summary>Raised when a quote is ignored.</summary>
        public event Action<InvalidQuoteEvent>? InvalidQuote;

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

                var rawProfit = BasketEconomics.RawProfit(basket, quote, _p);
                var exitProfit = rawProfit - BasketEconomics.CommissionBufferAmount(basket, _p);
                var stepMoney = BasketEconomics.StepMoney(basket, _p);
                var (reason, threshold) = EvaluateExits(basket, exitProfit, stepMoney, quote);
                if (reason != ExitReason.None)
                {
                    var close = new CloseOrder(basket, reason, quote);
                    var execution = _executor.CloseBasket(close);
                    if (execution.Succeeded && execution.BuyClosePrice > 0m && execution.SellClosePrice > 0m)
                    {
                        FinalizeClose(close, rawProfit, exitProfit, threshold, execution);
                    }
                    else
                    {
                        var message = execution.Succeeded
                            ? $"The executor reported non-positive close prices ({F(execution.BuyClosePrice)} / {F(execution.SellClosePrice)})."
                            : execution.Message ?? "The executor rejected the close.";
                        BasketCloseFailed.Raise(new BasketCloseFailedEvent(basket, reason, quote, message));
                    }
                    // A close that fired ends the quote whether it succeeded or failed: no
                    // replacement basket and no new leg on the same quote.
                    return;
                }
            }

            EvaluateEntry(basket, quote);
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
            var (buyClose, sellClose) = BasketEconomics.ExecutableClosePrices(quote, _p);
            return new BasketValuation(quote, basket.OpenPositions, basket.BuyLots, basket.SellLots, basket.GrossLots, basket.NetLots,
                raw, raw - BasketEconomics.CommissionBufferAmount(basket, _p),
                BasketEconomics.ExecutableProfit(basket, buyClose, sellClose, _p),
                BasketEconomics.StepMoney(basket, _p),
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
                var buyTriggered = quote.Ask >= basket.Upper;
                var sellTriggered = quote.Bid <= basket.Lower;
                if (buyTriggered && sellTriggered)
                {
                    // Both entry rules of section 3 hold on one quote (spread >= 2 steps). The
                    // specification defines no priority between them, so nothing is opened.
                    Reject(basket, quote, new EntryRejection(basket.NextTradeNumber, null, EntryRejectionReason.AmbiguousBoundaries, 0m,
                        $"Quote {quote} satisfies both Ask >= Upper ({F(basket.Upper)}) and Bid <= Lower ({F(basket.Lower)}); no side is chosen and no leg is opened.", null));
                    return;
                }
                if (buyTriggered) side = TradeSide.Buy;
                else if (sellTriggered) side = TradeSide.Sell;
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
                // Broker normalization never reduces the requested progression: round upward.
                lots = Math.Max(VolumeMath.CeilToStep(requested, _p.VolumeStep), _p.MinimumVolume);
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
            var execution = _executor.OpenPosition(order);
            if (!execution.Succeeded)
            {
                Reject(basket, quote, new EntryRejection(tradeNumber, side, EntryRejectionReason.ExecutionFailed, lots, execution.Message ?? "The executor rejected the entry.", sizing));
                return;
            }
            if (execution.FillPrice <= 0m)
            {
                Reject(basket, quote, new EntryRejection(tradeNumber, side, EntryRejectionReason.ExecutionFailed, lots,
                    $"The executor reported a non-positive fill price ({F(execution.FillPrice)}) for trade {tradeNumber}.", sizing));
                return;
            }

            var leg = new BasketLeg(tradeNumber, side, lots, execution.FillPrice, quote.Time, regime);
            basket.AddLeg(leg);
            if (_p.SwapConfigured && basket.OpenPositions == 1)
            {
                basket.NextRolloverTime = NextRolloverAfter(quote.Time);
            }
            EntriesOpened++;
            EntryOpened.Raise(new EntryOpenedEvent(basket, leg, quote, sizing));

            if (sizing != null)
            {
                // The hard-BE requirement is re-verified with the actual fill: the projected
                // executable basket P/L at the fixed target must be non-negative after the leg.
                var afterFill = BasketEconomics.ProjectedExistingProfit(basket, sizing.Target, _p);
                if (afterFill < 0m)
                {
                    basket.HardBreakevenViolations++;
                    HardBreakevenViolations++;
                    HardBreakevenViolated.Raise(new HardBreakevenViolatedEvent(basket, leg, sizing, afterFill, quote));
                }
            }
        }

        private void Reject(Basket basket, in Quote quote, EntryRejection rejection)
        {
            RejectedEntryAttempts++;
            var isNew = !rejection.SameSituationAs(basket.LastRejection, _p.VolumeStep);
            basket.LastRejection = rejection;
            if (isNew)
            {
                EntriesRejected++;
                EntryRejected.Raise(new EntryRejectedEvent(basket, rejection, quote));
            }
        }

        private void FinalizeClose(CloseOrder order, decimal rawProfit, decimal exitProfit, decimal threshold, in CloseExecution execution)
        {
            var basket = order.Basket;
            var commission = _p.CommissionPerLot * basket.GrossLots;
            var realized = BasketEconomics.ExecutableProfit(basket, execution.BuyClosePrice, execution.SellClosePrice, _p);
            var record = new BasketCloseRecord(basket.CreatedTime, order.Quote.Time, basket.Anchor, order.Reason, basket.OpenPositions,
                basket.BuyLots, basket.SellLots, basket.GrossLots, basket.NetLots, basket.HardBreakevenModeActive, basket.HardBreakevenViolations,
                rawProfit, exitProfit, threshold, execution.BuyClosePrice, execution.SellClosePrice, basket.AccruedSwapTotal, commission, realized);

            _basket = null;
            _closedBaskets.Add(record);
            RealizedProfit += realized;
            BasketsClosed++;
            BasketClosed.Raise(new BasketClosedEvent(basket, record, order.Quote));
        }

        private void AccrueSwap(Basket basket, in Quote quote)
        {
            if (!_p.SwapConfigured || basket.NextRolloverTime == null) return;
            var next = basket.NextRolloverTime.Value;
            if (next > quote.Time) return;

            // Rollovers are rare (at most one per day), so the per-leg pass here is not on the
            // per-quote path; it keeps each leg's own accrued swap for audit.
            var legs = basket.Legs;
            while (next <= quote.Time)
            {
                // The rollover at instant R ends the trading day that contains R - 1 tick. Weekend
                // days are never charged; the configured triple-swap day is charged three times;
                // only legs opened strictly before R are charged.
                var closingDay = next.AddTicks(-1).DayOfWeek;
                if (closingDay != DayOfWeek.Saturday && closingDay != DayOfWeek.Sunday)
                {
                    var multiplier = _p.TripleSwapDay == closingDay ? 3m : 1m;
                    for (var i = 0; i < legs.Count; i++)
                    {
                        var leg = legs[i];
                        if (leg.EntryTime >= next) continue;
                        var rate = leg.Side == TradeSide.Buy ? _p.BuySwapPerLotPerDay : _p.SellSwapPerLotPerDay;
                        basket.AddSwap(leg, leg.Lots * rate * multiplier);
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
