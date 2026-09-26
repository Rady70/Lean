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
    /// allocation; a trigger quote whose entry stays infeasible re-runs the sizing and folds the
    /// attempt into the existing rejection row without formatting a message or raising a second
    /// event for the same episode.
    /// </summary>
    /// <remarks>
    /// Order of work on every quote (sections 14 and 15):
    /// <list type="number">
    /// <item>reject an invalid or out-of-order quote explicitly;</item>
    /// <item>when a source-session trading availability is configured, observe but do not act on
    /// a quote inside a session's five-minute opening or closing buffer; such a quote is counted
    /// in <see cref="QuoteOnlyQuotes"/> and is not strategy-eligible;</item>
    /// <item>with no basket, anchor a new one on this quote's midpoint;</item>
    /// <item>with open legs: escape, then fixed take-profit, then trailing; a close ends the quote
    /// (no replacement basket on the same quote); a failed close also ends the quote;</item>
    /// <item>otherwise evaluate the next entry: a still-empty basket starts only on a quote that
    /// satisfies exactly one boundary (a quote satisfying both is skipped, never a run-ending
    /// error); after the first leg only the opposite side of the previous trade is eligible; a tail
    /// fill is verified against the hard-BE requirement with its actual price before the entry is
    /// published.</item>
    /// </list>
    /// One situation is a strategy invariant, not a trading decision: a tail fill that leaves the
    /// hard-BE requirement unmet. It faults the engine with a
    /// <see cref="StrategyInvariantException"/>. A quote with invalid prices or one earlier than an
    /// already processed quote faults it with a <see cref="DataQualityException"/> at this lowest
    /// layer, so no host can continue a deterministic replay after a market quote was lost. A
    /// quote outside the configured session-map coverage faults it with a
    /// <see cref="SessionMapException"/> the same way: the map describes a different source
    /// revision, and continuing would silently misclassify trading availability. With a PR 3
    /// risk guard, terminal account stop-out faults it with an
    /// <see cref="AccountStopOutException"/> after the quote's account observation and before any
    /// exit or entry on that quote, so no strategy action can rescue an account that already
    /// failed survival. A faulted engine refuses every further quote; a host must stop the run.
    /// </remarks>
    public sealed class SingleAnchorEngine
    {
        private readonly SingleAnchorParameters _p;
        private readonly IBasketExecutor _executor;
        private readonly HistoricalTradingAvailability? _availability;
        private readonly IResearchObserver? _research;
        private readonly IResearchRiskGuard? _risk;
        private readonly List<BasketCloseRecord> _closedBaskets = new List<BasketCloseRecord>();
        private Basket? _basket;
        private int _basketSequence;
        private Quote? _lastProcessedQuote;
        private SingleAnchorRunException? _fault;
        private bool _hardBreakevenVerificationFailed;

        /// <summary>
        /// Creates an engine. Throws <see cref="ArgumentException"/> when the parameters are invalid.
        /// </summary>
        public SingleAnchorEngine(SingleAnchorParameters parameters, IBasketExecutor executor)
            : this(parameters, executor, null)
        {
        }

        /// <summary>
        /// Creates an engine with an optional source-session trading availability. When it is
        /// given, a quote in the first or last five minutes of its source session is observed,
        /// validated and counted (<see cref="QuoteOnlyQuotes"/>) but changes no strategy state;
        /// every other quote behaves exactly as without it.
        /// </summary>
        /// <param name="researchObserver">
        /// Optional read-only research instrumentation (approved roadmap PR 2). It observes the
        /// engine's own basket and realized profit at the fixed points documented on
        /// <see cref="IResearchObserver"/>; it never decides, never mutates the ledger and
        /// changes no strategy outcome. A run without it is the pre-PR-2 strategy path.
        /// </param>
        /// <param name="riskGuard">
        /// Optional PR 3 target-account risk guard. When it is given, the frozen survival order
        /// applies on every processed quote: after the account observation, the guard's
        /// <see cref="IResearchRiskGuard.EvaluateSurvival"/> is asked whether the account is
        /// terminally stopped out (the run then stops before any exit could rescue it), and a
        /// candidate entry is first assessed for the Margin Call block and then for projected
        /// post-fill financing. A run without a guard is the pre-PR-3 strategy path in every
        /// dimension. In the approved host the guard is the same research account passed as
        /// <paramref name="researchObserver"/>, so the state it reports is the state this engine
        /// observed; attaching a guard that has not observed the account is a host error.
        /// </param>
        public SingleAnchorEngine(
            SingleAnchorParameters parameters,
            IBasketExecutor executor,
            HistoricalTradingAvailability? tradingAvailability,
            IResearchObserver? researchObserver = null,
            IResearchRiskGuard? riskGuard = null)
        {
            _p = parameters ?? throw new ArgumentNullException(nameof(parameters));
            _executor = executor ?? throw new ArgumentNullException(nameof(executor));
            _availability = tradingAvailability;
            _research = researchObserver;
            _risk = riskGuard;
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

        /// <summary>
        /// The last quote whose processing began (valid, in order and inside the configured
        /// session-map coverage), or null before the first. A quote refused for data quality
        /// (invalid or out of order) or for a session-map coverage mismatch is never assigned
        /// here: on a <see cref="DataQualityException"/> or <see cref="SessionMapException"/> this
        /// stays the last valid processed quote while <see cref="Fault"/>'s quote is the refused
        /// one and <see cref="QuotesProcessed"/> does not include it. A strategy-invariant fault
        /// happens on a quote that was processed, so there this is the faulting quote.
        /// </summary>
        public Quote? LastProcessedQuote => _lastProcessedQuote;

        /// <summary>True after a strategy invariant or a data-quality condition failed; every later quote is refused.</summary>
        public bool Faulted => _fault != null;

        /// <summary>The failure that faulted the engine, if any.</summary>
        public SingleAnchorRunException? Fault => _fault;

        /// <summary>
        /// What the hard-BE requirement covers under these parameters and this run
        /// (see <see cref="HardBreakevenVerification"/>). <c>HardBEVerifiedUnderConfiguredExecutionModel</c>
        /// is runtime state: it becomes false if a tail fill ever fails the post-fill verification,
        /// even though the run then stops.
        /// </summary>
        public HardBreakevenVerification HardBreakevenStatus => HardBreakevenVerification.For(_p, !_hardBreakevenVerificationFailed);

        /// <summary>Sum of the realized executable profit of every closed basket.</summary>
        public decimal RealizedProfit { get; private set; }

        /// <summary>
        /// Quotes whose processing began (valid, in order and inside the configured session-map
        /// coverage), including a faulting strategy quote and a quote-only quote inside a
        /// source-session buffer. The count after a quote is that quote's sequence number, as
        /// recorded in the traces. A quote refused for data quality or for a session-map coverage
        /// mismatch is not counted (see <see cref="LastProcessedQuote"/>). This is the count of
        /// quotes the host delivered into the strategy's coverage, never a count of quotes the
        /// strategy acted on.
        /// </summary>
        public long QuotesProcessed { get; private set; }

        /// <summary>
        /// Delivered quotes inside the five-minute opening or closing buffer of their
        /// source-derived session (see <see cref="HistoricalTradingAvailability"/>): observed,
        /// validated, ordered and counted, but excluded from every strategy decision and mutation.
        /// Zero when the engine has no trading availability, so quote delivery accounting is never
        /// reduced by this restriction.
        /// </summary>
        public long QuoteOnlyQuotes { get; private set; }

        /// <summary>
        /// Quotes permitted to evaluate strategy logic: every processed quote outside a quote-only
        /// buffer, plus the faulting quote of a strategy invariant. Most of them cause no trade or
        /// state change.
        /// </summary>
        public long StrategyEligibleQuotes => QuotesProcessed - QuoteOnlyQuotes;

        /// <summary>
        /// Legs opened and published over the engine's lifetime. A filled leg is not published and
        /// does not count when the fill cannot become a normal successful entry: a tail leg that
        /// fails the post-fill hard-BE invariant, or a fill whose immediate post-fill account
        /// state causes terminal stop-out (<see cref="AccountStopOutException"/>) or an
        /// unavailable executable account mark (<see cref="AccountSurvivalException"/>). In those
        /// cases the filled leg stays in the basket ledger for the post-mortem or the recorded
        /// terminal state.
        /// </summary>
        public long EntriesOpened { get; private set; }

        /// <summary>Distinct rejected-entry episodes (each raised as one <see cref="EntryRejected"/>); an episode covers every attempt with the same trade, side, reason and hard-BE outcome.</summary>
        public long EntriesRejected { get; private set; }

        /// <summary>Every rejected entry attempt, including repeats of the same episode.</summary>
        public long RejectedEntryAttempts { get; private set; }

        /// <summary>Quotes skipped because a still-empty basket satisfied both first-entry boundaries (specification section 3).</summary>
        public long SkippedFirstEntryQuotes { get; private set; }

        /// <summary>Baskets closed by an exit rule.</summary>
        public long BasketsClosed { get; private set; }

        /// <summary>Raised when a basket is anchored.</summary>
        public event Action<AnchorCreatedEvent>? AnchorCreated;

        /// <summary>Raised once per basket on the first quote that satisfies both first-entry boundaries of a still-empty basket.</summary>
        public event Action<FirstEntrySkippedEvent>? FirstEntrySkipped;

        /// <summary>
        /// Raised when a leg is filled, is in the ledger, has passed the post-fill hard-BE
        /// verification (for a tail leg) and the post-fill account state did not terminate the run
        /// (<see cref="AccountStopOutException"/> or <see cref="AccountSurvivalException"/>). A
        /// faulting fill is not raised as a normal entry; it stays in the ledger.
        /// </summary>
        public event Action<EntryOpenedEvent>? EntryOpened;

        /// <summary>Raised once per distinct rejected-entry episode, including hard-BE infeasibility.</summary>
        public event Action<EntryRejectedEvent>? EntryRejected;

        /// <summary>Raised, as a diagnostic, just before the engine faults on a tail fill that fails the hard-BE verification; the leg is not raised as a normal entry.</summary>
        public event Action<HardBreakevenViolatedEvent>? HardBreakevenViolated;

        /// <summary>Raised when trailing activates.</summary>
        public event Action<TrailingActivatedEvent>? TrailingActivated;

        /// <summary>Raised when a basket is closed.</summary>
        public event Action<BasketClosedEvent>? BasketClosed;

        /// <summary>Raised when the executor could not close the basket.</summary>
        public event Action<BasketCloseFailedEvent>? BasketCloseFailed;

        /// <summary>
        /// Processes one quote. Throws <see cref="DataQualityException"/> for a quote with invalid
        /// prices or one earlier than an already processed quote, <see cref="SessionMapException"/>
        /// for a quote outside the configured session-map coverage, <see cref="StrategyInvariantException"/>
        /// when a strategy invariant fails and (with a PR 3 risk guard)
        /// <see cref="AccountStopOutException"/> when the account is terminally stopped out or
        /// <see cref="AccountSurvivalException"/> when the account cannot be revalued on the quote;
        /// each faults the engine, which then throws again on every call. A quote that satisfies
        /// both first-entry boundaries of a still-empty basket is skipped, not an error.
        /// </summary>
        public void OnQuote(in Quote quote)
        {
            if (_fault != null)
            {
                throw _fault.AsRefusal();
            }
            if (!quote.IsValid)
            {
                throw RecordFault(new DataQualityException(DataQualityIssue.InvalidQuote, quote,
                    $"Quote {quote} has a non-positive or crossed bid/ask; the data is not a valid tick history for this strategy and the run is stopped."));
            }
            if (_lastProcessedQuote.HasValue && quote.Time < _lastProcessedQuote.Value.Time)
            {
                throw RecordFault(new DataQualityException(DataQualityIssue.OutOfOrderQuote, quote,
                    $"Quote {quote} is earlier than the previously processed quote {_lastProcessedQuote.Value}; the tick chronology is broken and the run is stopped."));
            }
            var tradability = QuoteTradability.Tradable;
            if (_availability != null)
            {
                try
                {
                    tradability = _availability.Classify(quote.Time);
                }
                catch (InvalidOperationException error)
                {
                    // A map-coverage mismatch is a run-ending configuration condition at the same
                    // layer as a data-quality fault: the quote is not counted, not assigned as the
                    // last processed quote, and the host writes structured failure evidence.
                    throw RecordFault(new SessionMapException(SessionMapIssue.QuoteOutsideMapCoverage, quote, error.Message));
                }
            }

            _lastProcessedQuote = quote;
            QuotesProcessed++;

            if (tradability != QuoteTradability.Tradable)
            {
                // The quote is in a source-session buffer: it exists, it was validated and it is
                // counted, but the strategy may not anchor, exit, enter, trail, reject, close or
                // change any ledger on it. The next tradable quote is evaluated from its own
                // values; nothing crossed during the buffer is queued. The research observer still
                // sees the market mark of the unchanged basket on the delivered quote.
                QuoteOnlyQuotes++;
                _research?.ObserveQuote(quote, _basket, RealizedProfit, null);
                // The account is revalued on the delivered quote even inside a buffer; survival
                // is a broker-account condition, not a strategy action, so a terminal stop-out
                // stops the run here too (there is no strategy action to rescue on this quote).
                EvaluateSurvival(quote);
                return;
            }

            if (_basket == null)
            {
                _basket = new Basket(++_basketSequence, QuotesProcessed, quote, _p);
                AnchorCreated.Raise(new AnchorCreatedEvent(_basket, quote));
            }
            var basket = _basket;

            if (basket.OpenPositions > 0)
            {
                var rawProfit = BasketEconomics.RawProfit(basket, quote, _p);

                // Research observation before any exit can remove the basket (roadmap section
                // 3.14): the incoming quote's executable valuation of the still-open basket is
                // not lost, including on the tick that is about to close it. The raw profit the
                // exit evaluation needs anyway is passed on, so the observer does not recompute
                // it.
                _research?.ObserveQuote(quote, basket, RealizedProfit, rawProfit);

                // Approved PR 3 survival order step 3: terminal stop-out is evaluated before any
                // exit on this quote could rescue an account that should already have failed
                // survival.
                EvaluateSurvival(quote);

                var exitProfit = rawProfit - _p.CommissionBuffer;
                var stepMoney = BasketEconomics.StepMoney(basket, _p);
                var (reason, threshold) = EvaluateExits(basket, exitProfit, stepMoney, quote);
                if (reason != ExitReason.None)
                {
                    var close = new CloseOrder(basket, reason, quote);
                    var execution = _executor.CloseBasket(close);
                    if (execution.Succeeded && BasketEconomics.ArePricesUsable(basket, execution.BuyClosePrice, execution.SellClosePrice, null))
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
            else
            {
                // No open leg: the incoming quote is observed before the entry evaluation, but
                // there is no raw basket profit to pass. A flat account cannot stop out (there is
                // no position to liquidate); the call keeps the frozen order uniform.
                _research?.ObserveQuote(quote, basket, RealizedProfit, null);
                EvaluateSurvival(quote);
            }

            EvaluateEntry(basket, quote);
        }

        /// <summary>
        /// Approved PR 3 survival order step 3: asks the account risk guard whether the state
        /// observed for this quote is terminal stop-out. The guard records the terminal account
        /// state; the engine faults here, before exits or entries, so no later action can rescue an
        /// account that already failed survival, and no post-stop-out liquidation is simulated.
        /// When the guard cannot establish a current executable account state (a needed close
        /// price is not positive under the configured slippage), the run stops explicitly rather
        /// than being certified from a stale state. No-op without a risk guard (the pre-PR-3
        /// path).
        /// </summary>
        private void EvaluateSurvival(in Quote quote)
        {
            if (_risk == null)
            {
                return;
            }
            if (!_risk.SurvivalObservable)
            {
                throw RecordFault(new AccountSurvivalException(AccountSurvivalIssue.ExecutableMarkUnavailable, quote,
                    $"The PR 3 research account cannot be revalued at {quote}: a needed executable close price is not positive under the configured slippage, so the current equity, used margin, free margin and margin level are not defined on this quote. Survival is not certified from a stale account state; the run is stopped."));
            }
            var stopOut = _risk.EvaluateSurvival(quote);
            if (stopOut == null)
            {
                return;
            }
            throw RecordFault(new AccountStopOutException(stopOut.Reason, quote,
                $"The research account stopped out ({stopOut.Reason}) at {quote}: equity {F(stopOut.Equity)}, balance {F(stopOut.Balance)}, floating {F(stopOut.FloatingProfit)}, used margin {F(stopOut.UsedMargin)}, free margin {F(stopOut.FreeMargin)}" +
                (stopOut.MarginLevelPercent.HasValue ? $", margin level {F(stopOut.MarginLevelPercent.Value)}%" : ", margin level n/a (zero used margin)") +
                $", {stopOut.OpenPositions} open position(s); the intact SingleAnchor path did not survive and the run is stopped."));
        }

        /// <summary>
        /// The complete state of the current basket, valued at a quote without changing anything
        /// (end-of-data mark to market, specification section 15). Null only when there is no
        /// basket or the quote is invalid; a basket without legs is returned with null profits.
        /// </summary>
        public BasketSnapshot? MarkToMarket(in Quote quote)
        {
            var basket = _basket;
            if (basket == null || !quote.IsValid)
            {
                return null;
            }
            decimal? raw = null, exit = null, executable = null, stepMoney = null;
            if (basket.OpenPositions > 0)
            {
                raw = BasketEconomics.RawProfit(basket, quote, _p);
                exit = raw - _p.CommissionBuffer;
                var (buyClose, sellClose) = BasketEconomics.ExecutableClosePrices(quote, _p);
                if (BasketEconomics.ArePricesUsable(basket, buyClose, sellClose, null))
                {
                    executable = BasketEconomics.ExecutableProfit(basket, buyClose, sellClose, _p);
                }
                stepMoney = BasketEconomics.StepMoney(basket, _p);
            }
            return new BasketSnapshot(basket.Sequence, basket.AnchorEvent, basket.CreatedTime, basket.Anchor, basket.Step, basket.Upper, basket.Lower,
                basket.LowerTarget, basket.UpperTarget, basket.OpenPositions, basket.LastSide, basket.NextTradeNumber,
                basket.BuyLots, basket.SellLots, basket.GrossLots, basket.NetLots,
                basket.HardBreakevenModeActive, basket.TrailingActive, basket.PeakProfit,
                quote, raw, exit, executable, stepMoney, LegTrace(basket), basket.Rejections, basket.SkippedFirstEntry);
        }

        /// <summary>The trace rows of the open basket's legs (empty without a basket).</summary>
        public IReadOnlyList<LegRecord> OpenBasketLegTrace()
        {
            var basket = _basket;
            if (basket == null) return Array.Empty<LegRecord>();
            return LegTrace(basket);
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
                    // Specification section 3: a still-empty basket must not start on a quote that
                    // satisfies both boundaries (no priority, no skip-as-trade, no double entry).
                    // The quote is skipped; the basket stays empty and the run continues.
                    SkippedFirstEntryQuotes++;
                    var isNew = basket.SkippedFirstEntry == null;
                    var record = basket.RecordSkippedFirstEntry(QuotesProcessed, quote);
                    if (isNew)
                    {
                        FirstEntrySkipped.Raise(new FirstEntrySkippedEvent(basket, record, quote));
                    }
                    return;
                }
                if (buyTriggered) side = TradeSide.Buy;
                else if (sellTriggered) side = TradeSide.Sell;
                else return;
            }
            else
            {
                // Strict alternation has absolute priority: only the opposite side of the previous
                // trade is evaluated, even if the quote also satisfies the other boundary.
                side = basket.NextRequiredSide!.Value;
                var triggered = side == TradeSide.Buy ? quote.Ask >= basket.Upper : quote.Bid <= basket.Lower;
                if (!triggered) return;
            }

            var tradeNumber = basket.NextTradeNumber;
            decimal lots;
            SizingRegime regime;
            HardBreakevenSizing? sizing = null;
            decimal? rawRequested = null;
            var maximum = _p.MaximumVolume;
            if (tradeNumber <= _p.NormalTradeCount)
            {
                regime = SizingRegime.Arithmetic;
                var requested = _p.BaseLot * tradeNumber;
                rawRequested = requested;
                // Broker normalization never reduces the requested progression: round upward.
                lots = Math.Max(VolumeMath.CeilToStep(requested, _p.VolumeStep), _p.MinimumVolume);
                if (lots > maximum)
                {
                    Reject(basket, quote, new EntryRejection(tradeNumber, side, EntryRejectionReason.VolumeExceedsMaximum, requested, null, lots, null, maximum, null));
                    return;
                }
            }
            else
            {
                regime = SizingRegime.HardBreakeven;
                basket.ActivateHardBreakevenMode();
                var tail = HardBreakevenSizer.Size(basket, side, quote, _p);
                if (!tail.IsFeasible)
                {
                    Reject(basket, quote, new EntryRejection(tradeNumber, side, EntryRejectionReason.HardBreakevenInfeasible,
                        null, tail.ExactRequired, tail.NormalizedRequiredLot, tail, maximum, null));
                    return;
                }
                sizing = tail;
                lots = tail.NormalizedLot;
            }

            var order = new EntryOrder(tradeNumber, side, lots, quote, regime, sizing);

            // Approved PR 3 entry feasibility (roadmap section 3.18): the strategy has produced
            // the actual candidate lot including its hard-BE sizing; only now does account
            // financing decide. The Margin Call block is enforced first, then the projected
            // post-fill margin. Both are explicit rejections: no leg is added, the trade number
            // does not advance, the required side is unchanged and hard-BE mode stays active if
            // it had already activated, so a later eligible quote may retry.
            if (_risk != null)
            {
                var assessment = _risk.AssessEntry(order, basket);
                if (assessment.Decision != MarginEntryDecision.Allowed)
                {
                    var reason = assessment.Decision == MarginEntryDecision.MarginCall
                        ? EntryRejectionReason.MarginCall
                        : EntryRejectionReason.InsufficientMargin;
                    Reject(basket, quote, new EntryRejection(tradeNumber, side, reason,
                        rawRequested, sizing?.ExactRequired, sizing?.NormalizedRequiredLot ?? lots, sizing, maximum, null,
                        assessment.CurrentUsedMargin, assessment.CurrentFreeMargin, assessment.CurrentMarginLevelPercent,
                        assessment.ProjectedUsedMargin, assessment.ProjectedFreeMargin));
                    return;
                }
            }

            var execution = _executor.OpenPosition(order);
            if (!execution.Succeeded)
            {
                Reject(basket, quote, new EntryRejection(tradeNumber, side, EntryRejectionReason.ExecutionFailed,
                    rawRequested, sizing?.ExactRequired, sizing?.NormalizedRequiredLot ?? lots, sizing, maximum, execution.Message));
                return;
            }
            if (execution.FillPrice <= 0m)
            {
                Reject(basket, quote, new EntryRejection(tradeNumber, side, EntryRejectionReason.ExecutionFailed,
                    rawRequested, sizing?.ExactRequired, sizing?.NormalizedRequiredLot ?? lots, sizing, maximum,
                    $"The executor reported a non-positive fill price ({F(execution.FillPrice)}) for trade {tradeNumber}."));
                return;
            }

            var leg = new BasketLeg(tradeNumber, side, lots, execution.FillPrice, quote.Time, regime, QuotesProcessed, quote) { Sizing = sizing, RawRequestedLots = rawRequested };
            basket.AddLeg(leg);

            // Research observation immediately after the new leg is in the ledger (roadmap
            // section 3.14): the post-entry valuation includes the new leg's immediate execution
            // costs. It is taken before the post-fill verification and before any event, so a
            // hard-BE invariant fault or a throwing event handler cannot lose it, and the
            // post-mortem ledger state (which keeps the faulting leg) is observed. The raw profit
            // of the updated basket is computed for the observer here (entry ticks only).
            _research?.ObserveQuote(quote, basket, RealizedProfit, BasketEconomics.RawProfit(basket, quote, _p));

            // The fill changed the account state, so the frozen order's stop-out step applies to
            // the post-fill state as well: a fill whose immediate execution costs (spread,
            // slippage, commission) put the account at terminal stop-out ends the run on this
            // quote instead of waiting for the next one (which may never arrive). The filled leg
            // stays in the ledger and in the terminal state, but it is not published as a normal
            // successful entry, mirroring the hard-BE invariant path.
            EvaluateSurvival(quote);

            if (sizing.HasValue)
            {
                // The hard-BE requirement is re-verified with the actual fill before the entry is
                // published: the projected executable basket P/L at the fixed boundary must be
                // non-negative after the leg. With the research executor the fill is the sizing
                // model and this always holds; a negative value means the executor departed from
                // the model, and continuing would be breakeven drift after hard-BE activation.
                var tail = sizing.Value;
                var afterFill = BasketEconomics.ProjectedExistingProfit(basket, tail.Target, _p);
                if (afterFill < 0m)
                {
                    // The fault is recorded before observers are told, so the engine is faulted
                    // even if an observer throws. The leg stays in the ledger for the post-mortem,
                    // but no normal EntryOpened is raised for it.
                    _hardBreakevenVerificationFailed = true;
                    var fault = RecordFault(new StrategyInvariantException(StrategyInvariant.HardBreakevenViolatedByFill, quote,
                        $"Tail leg {leg} of basket #{basket.Sequence} was filled at {F(execution.FillPrice)} instead of the modelled {F(tail.CandidateEntryPrice)}; the projected executable basket P/L at the hard boundary {F(tail.Target.Target)} is {F(afterFill)} after the fill (sizing expected {F(tail.ProjectedProfitAfter)}). Breakeven would drift beyond the ceiling; the run is stopped."));
                    HardBreakevenViolated.Raise(new HardBreakevenViolatedEvent(basket, leg, tail, afterFill, quote));
                    throw fault;
                }
            }

            EntriesOpened++;
            EntryOpened.Raise(new EntryOpenedEvent(basket, leg, quote, sizing));
        }

        private T RecordFault<T>(T exception) where T : SingleAnchorRunException
        {
            _fault = exception;
            return exception;
        }

        private void Reject(Basket basket, in Quote quote, EntryRejection rejection)
        {
            RejectedEntryAttempts++;
            basket.LastRejection = rejection;
            // The episode key (trade number, side, reason, hard-BE outcome) contains no raw quote
            // values and no normalized requirement, so an episode that reappears after another one
            // appends to its existing row rather than starting a new one. The number of rows is
            // bounded by the finite set of trade/reason/outcome combinations, not by the number of
            // ticks; every attempt is folded into the row (count, last quote, parity digest and
            // min/max values). Matching before formatting keeps a persisting requirement free of
            // per-tick message construction.
            var row = FindEpisode(basket, rejection);
            if (row == null)
            {
                basket.AddRejection(new EntryRejectionRecord(basket.Sequence, QuotesProcessed, quote.Time, quote.Bid, quote.Ask, rejection));
                EntriesRejected++;
                EntryRejected.Raise(new EntryRejectedEvent(basket, rejection, quote));
            }
            else
            {
                row.AppendAttempt(QuotesProcessed, quote.Time, quote.Bid, quote.Ask, rejection);
            }

            // The account folds the episode structure into its run-level margin counters (a
            // repeated margin block stays one episode and one growing attempt count).
            _risk?.ObserveEntryRejection(rejection, row == null);
        }

        private static EntryRejectionRecord? FindEpisode(Basket basket, EntryRejection rejection)
        {
            var rows = basket.Rejections;
            // Newest first: the common case is the episode that is already active.
            for (var i = rows.Count - 1; i >= 0; i--)
            {
                if (rows[i].IsSameEpisode(rejection))
                {
                    return rows[i];
                }
            }
            return null;
        }

        private void FinalizeClose(CloseOrder order, decimal rawProfit, decimal exitProfit, decimal threshold, in CloseExecution execution)
        {
            var basket = order.Basket;
            var commission = _p.CommissionPerLot * basket.GrossLots;
            var realized = BasketEconomics.ExecutableProfit(basket, execution.BuyClosePrice, execution.SellClosePrice, _p);
            var record = new BasketCloseRecord(basket.Sequence, basket.AnchorEvent, basket.CreatedTime, order.Quote.Time, QuotesProcessed, order.Quote.Bid, order.Quote.Ask,
                basket.Anchor, order.Reason, basket.OpenPositions,
                basket.BuyLots, basket.SellLots, basket.GrossLots, basket.NetLots, basket.HardBreakevenModeActive,
                rawProfit, exitProfit, threshold, execution.BuyClosePrice, execution.SellClosePrice, commission, realized,
                LegTrace(basket), basket.Rejections, basket.SkippedFirstEntry);

            _basket = null;
            _closedBaskets.Add(record);
            RealizedProfit += realized;
            BasketsClosed++;

            // The research account records the realized change and seals the basket's research
            // record after the close is final and before observers are notified, so a throwing
            // event handler cannot lose the realized account update.
            _research?.ObserveClose(record, RealizedProfit);

            BasketClosed.Raise(new BasketClosedEvent(basket, record, order.Quote));
        }

        private static IReadOnlyList<LegRecord> LegTrace(Basket basket)
        {
            var legs = basket.Legs;
            var rows = new LegRecord[legs.Count];
            for (var i = 0; i < legs.Count; i++)
            {
                rows[i] = LegRecord.From(basket.Sequence, legs[i]);
            }
            return rows;
        }

        private static string F(decimal value)
        {
            return value.ToString(CultureInfo.InvariantCulture);
        }
    }
}
