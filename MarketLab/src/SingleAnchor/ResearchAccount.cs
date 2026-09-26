using System;
using System.Collections.Generic;

namespace MarketLab.SingleAnchor
{
    /// <summary>
    /// The engine's optional research instrumentation contract (approved roadmap PR 2,
    /// section 3.10). The engine remains the only owner of the basket ledger and the only
    /// authority for realized strategy P/L; an observer receives read-only observations of the
    /// engine's own state at fixed points of the quote sequence and derives research values from
    /// them. An observer must not mutate the engine, raise strategy events or change any
    /// strategy decision; the engine's calls are read-only.
    /// </summary>
    /// <remarks>
    /// Observation points (roadmap sections 3.10 and 3.14):
    /// <list type="bullet">
    /// <item><see cref="ObserveQuote"/> is called for every processed quote, including a
    /// quote-only quote inside a source-session buffer, and once more after a newly opened leg
    /// has been added so the post-entry valuation with its immediate execution costs is
    /// observed. On a quote that fires an exit it is called before the close can remove the
    /// basket, so the exit tick's valuation is not lost.</item>
    /// <item><see cref="ObserveClose"/> is called once per closed basket, after the realized
    /// result and the close record are final, so the account can record the realized change and
    /// seal the per-basket research record.</item>
    /// </list>
    /// Every processed quote is already observed, so the host's explicit
    /// <see cref="SingleAnchorResearchAccount.ObserveEndOfRun"/> call with the last processed
    /// quote before writing the results is an idempotent final observation that marks the
    /// account snapshot explicitly at the end-of-data quote. A basket still open at that point
    /// is not pretended to be closed; its compact path state is exposed separately through
    /// <see cref="SingleAnchorResearchAccount.SnapshotActiveBasket"/>.
    /// </remarks>
    public interface IResearchObserver
    {
        /// <summary>
        /// Observes one processed quote with the engine's current basket (null between baskets)
        /// and its current realized profit. Called before an exit can close the basket and once
        /// more after a newly filled leg; an implementation must be O(1) and allocate nothing on
        /// the per-quote path.
        /// </summary>
        /// <param name="rawProfit">
        /// The engine's raw basket profit at this observation state
        /// (<see cref="BasketEconomics.RawProfit"/>), when the engine has already computed it for
        /// this quote and basket state, so the observer does not have to duplicate that work.
        /// Null when the engine has no such value (no open leg, a quote-only quote, or the
        /// explicit end-of-run observation); the observer derives what it needs in that case.
        /// </param>
        void ObserveQuote(in Quote quote, Basket? basket, decimal realizedProfit, decimal? rawProfit);

        /// <summary>
        /// Observes a basket that has just closed, with the engine's realized profit after the
        /// close. The record is final; its leg, rejection and skipped-entry traces are available
        /// for the per-basket research record.
        /// </summary>
        void ObserveClose(BasketCloseRecord record, decimal realizedProfit);
    }

    /// <summary>
    /// The engine's optional PR 3 target-account survival and entry-financing contract. It is a
    /// derived account view, not a second ledger: the implementation reads the engine's basket and
    /// realized profit and answers two questions under the frozen USD XM-style margin contract
    /// (approved roadmap sections 3.16-3.21): is the account already terminally stopped out, and
    /// can the projected post-fill account finance a candidate order?
    /// </summary>
    /// <remarks>
    /// The engine calls <see cref="EvaluateSurvival"/> on every processed quote after the
    /// account's own observation and before any strategy action that could rescue an account that
    /// should already have failed survival, and <see cref="AssessEntry"/> only after a valid
    /// candidate order exists. A non-null <see cref="EvaluateSurvival"/> result is terminal and
    /// the engine stops; a non-<see cref="MarginEntryDecision.Allowed"/> entry assessment becomes
    /// an explicit rejection. The implementation owns no positions and never mutates the engine.
    /// A run without a risk guard is the pre-PR-3 strategy path.
    /// </remarks>
    public interface IResearchRiskGuard
    {
        /// <summary>
        /// True when the account state the survival and entry assessments use is current for the
        /// quote just observed. False when the configured execution economics made a needed
        /// executable close price non-positive, so the current executable equity and margin state
        /// cannot be established on this quote. The engine must not evaluate or certify survival
        /// from a stale state; it stops the run explicitly when this is false.
        /// </summary>
        bool SurvivalObservable { get; }

        /// <summary>
        /// Evaluates terminal stop-out from the account state already observed for this quote
        /// (Step 3 of the frozen survival order). Returns the recorded terminal state the first
        /// time the account stops out; null while the run may continue. The call is idempotent and
        /// the engine stops the run when it is non-null, so no later quote is delivered. Only
        /// called while <see cref="SurvivalObservable"/> is true.
        /// </summary>
        MarginStopOut? EvaluateSurvival(in Quote quote);

        /// <summary>
        /// Assesses one strategy-validated candidate order against the account: the Margin Call
        /// entry block first, then the projected post-fill margin feasibility under the frozen
        /// hedging rule. Must be O(1) and allocate nothing on the path. The account state used is
        /// the one observed for the quote the candidate was decided on; when that observation
        /// skipped an unavailable executable mark, the last observable state is used (the skip is
        /// explicit in <c>researchAccount.floatingObservationsSkipped</c>).
        /// </summary>
        MarginEntryAssessment AssessEntry(EntryOrder order, Basket basket);

        /// <summary>
        /// Folds the engine's rejection-episode accounting into the account's run-level margin
        /// counters. Called once per recorded attempt; <paramref name="isNewEpisode"/> is true
        /// when the engine started a new episode row rather than appending to an existing one.
        /// </summary>
        void ObserveEntryRejection(EntryRejection rejection, bool isNewEpisode);
    }

    /// <summary>
    /// Derived research account and bounded analytics for a SingleAnchor run (approved roadmap
    /// PR 2, sections 3.10-3.15). This is not a second trading ledger: it owns no positions and
    /// makes no decisions. It observes the engine's basket and realized profit and keeps
    /// <c>Balance = InitialBalance + SingleAnchorEngine.RealizedProfit</c>,
    /// <c>FloatingPL</c> as the executable mark-to-market of the basket under the configured
    /// execution economics (close-side slippage and round-trip commission included) and
    /// <c>Equity = Balance + FloatingPL</c>. The optional <c>CommissionBuffer</c> is an
    /// exit-decision threshold only and is never subtracted here.
    /// </summary>
    /// <remarks>
    /// With <see cref="MarginParameters"/> configured, the same account also implements the
    /// approved PR 3 target-account capability (<see cref="IResearchRiskGuard"/>): it derives
    /// used margin, free margin and margin level from the same balance/equity state under the
    /// frozen USD XM-style contract, records their run extrema, counts Margin Call and
    /// insufficient-margin events and records a terminal stop-out. Margin state is derived from
    /// the engine's basket aggregates; it is never a second position registry or Balance/Equity
    /// authority. The observation half of this class remains read-only; only the explicitly
    /// requested risk-guard role can influence the engine, and only by reporting account state
    /// (the engine still decides to reject or stop).
    /// </remarks>
    /// <remarks>
    /// Run-level values are constant-time accumulators; the only retained records are one
    /// compact record per closed basket (its path extrema plus the values derived from the
    /// engine's existing leg and rejection traces) and, on demand, a compact snapshot of a
    /// basket still open. Nothing is retained per quote, and no per-quote object, string or file
    /// is created. When a needed executable close price is not positive the executable mark is
    /// not defined at that quote: the observation is skipped, the run and the active basket
    /// count it (<see cref="FloatingObservationsSkipped"/>), and the floating/equity extrema are
    /// explicitly not complete for a run or basket with a non-zero count, so a skipped worst
    /// point can never make the remaining extrema look complete.
    /// </remarks>
    public sealed class SingleAnchorResearchAccount : IResearchObserver, IResearchRiskGuard
    {
        private readonly SingleAnchorParameters _parameters;
        private readonly MarginParameters? _margin;
        private readonly decimal _slippage;
        private readonly decimal _costPerLot;
        private readonly List<BasketResearchRecord> _basketRecords = new List<BasketResearchRecord>();
        private ActiveBasket? _active;
        private decimal _observedRealizedProfit;
        private decimal _balance;
        private decimal _floatingProfit;
        private decimal _equity;
        private decimal _peakBalance;
        private decimal _maxBalanceDrawdown;
        private decimal _peakEquity;
        private decimal _maxEquityDrawdown;
        private int _openPositions;
        private int _maxOpenPositions;
        private decimal _grossLots;
        private decimal _maxGrossLots;
        private decimal _absoluteNetLots;
        private decimal _maxAbsoluteNetLots;
        private decimal? _maxExecutableFloatingProfit;
        private decimal? _maxExecutableFloatingLoss;
        private bool _floatingObservable = true;
        private long _floatingObservationsSkipped;
        private bool _hasObservation;
        private DateTime _lastQuoteTime;
        private decimal _lastQuoteBid;
        private decimal _lastQuoteAsk;
        private int _lastBasketSequence = -1;
        private int _lastOpenPositions = -1;
        private decimal _lastRealizedProfit;

        // ---- PR 3 target-account margin state (active only when _margin is configured) ----
        private decimal _currentUsedMargin;
        private decimal? _currentFreeMargin;
        private decimal? _currentMarginLevelPercent;
        private decimal _maxUsedMargin;
        private decimal? _minFreeMargin;
        private decimal? _minMarginLevelPercent;
        private bool _marginCallActive;
        private long _marginCallObservations;
        private long _marginCallEpisodes;
        private long _marginCallBlockedAttempts;
        private long _marginCallBlockedEpisodes;
        private long _insufficientMarginAttempts;
        private long _insufficientMarginEpisodes;
        private MarginStopOut? _stopOut;

        /// <summary>
        /// Creates an account for a validated parameter set and the run's initial balance
        /// (<c>single-anchor-cash</c> in the LEAN host). <paramref name="margin"/> is the optional
        /// approved PR 3 target-account margin configuration; null creates the PR 2 read-only
        /// account only, and the host does not hand such an account to the engine as a risk guard.
        /// </summary>
        public SingleAnchorResearchAccount(SingleAnchorParameters parameters, decimal initialBalance, MarginParameters? margin = null)
        {
            _parameters = parameters ?? throw new ArgumentNullException(nameof(parameters));
            if (margin != null)
            {
                margin.Validate();
            }
            _margin = margin;
            _slippage = parameters.Slippage;
            // The executable mark of a raw profit is raw - (slippage * point value + round-trip
            // commission) * gross lots; the coefficient is constant for the run.
            _costPerLot = parameters.Slippage * parameters.PointValuePerLot + parameters.CommissionPerLot;
            InitialBalance = initialBalance;
            _balance = initialBalance;
            _peakBalance = initialBalance;
            _peakEquity = initialBalance;
            _equity = initialBalance;
            _currentFreeMargin = margin == null ? null : initialBalance;
        }

        /// <summary>The run's starting balance; the account never changes it.</summary>
        public decimal InitialBalance { get; }

        /// <summary>The last observed engine realized profit; the account does not accumulate its own.</summary>
        public decimal RealizedProfit => _observedRealizedProfit;

        /// <summary>InitialBalance + RealizedProfit, the current (at end of run, final) balance.</summary>
        public decimal Balance => _balance;

        /// <summary>
        /// The current executable floating P/L of the basket; 0 when no leg is open. It is not
        /// observable when a needed executable close price is not positive, in which case the
        /// last observable value stays, this observation is skipped and
        /// <see cref="FloatingObservable"/> becomes false.
        /// </summary>
        public decimal FloatingProfit => _floatingProfit;

        /// <summary>
        /// True when the last observation produced an executable mark (or was flat); false when
        /// the last observation was skipped because a needed executable close price was not
        /// positive, so the reported floating P/L and equity are not current.
        /// </summary>
        public bool FloatingObservable => _floatingObservable;

        /// <summary>
        /// Number of observations whose executable mark was skipped over the whole run. A
        /// non-zero value means the equity and floating extrema may be incomplete: a skipped
        /// point can be an unseen extreme (the last-observation flag alone cannot show this).
        /// </summary>
        public long FloatingObservationsSkipped => _floatingObservationsSkipped;

        /// <summary>Balance + FloatingProfit, the current (at end of run, final) equity.</summary>
        public decimal Equity => _equity;

        /// <summary>Highest balance observed since the initial balance.</summary>
        public decimal PeakBalance => _peakBalance;

        /// <summary>Largest decline of the balance from its running peak, in account currency.</summary>
        public decimal MaxBalanceDrawdown => _maxBalanceDrawdown;

        /// <summary>Highest equity observed since the initial balance.</summary>
        public decimal PeakEquity => _peakEquity;

        /// <summary>Largest decline of the equity from its running peak, in account currency.</summary>
        public decimal MaxEquityDrawdown => _maxEquityDrawdown;

        /// <summary>Open positions of the last observation.</summary>
        public int CurrentOpenPositions => _openPositions;

        /// <summary>Highest number of open positions observed over the run.</summary>
        public int MaxOpenPositions => _maxOpenPositions;

        /// <summary>Gross lots of the last observation.</summary>
        public decimal CurrentGrossLots => _grossLots;

        /// <summary>Highest gross lots observed over the run.</summary>
        public decimal MaxGrossLots => _maxGrossLots;

        /// <summary>Absolute net lots of the last observation.</summary>
        public decimal CurrentAbsoluteNetLots => _absoluteNetLots;

        /// <summary>Highest absolute net lots observed over the run.</summary>
        public decimal MaxAbsoluteNetLots => _maxAbsoluteNetLots;

        /// <summary>Most positive executable floating P/L observed while a leg was open; null when no leg was ever observed.</summary>
        public decimal? MaxExecutableFloatingProfit => _maxExecutableFloatingProfit;

        /// <summary>Most adverse (most negative) executable floating P/L observed while a leg was open; null when no leg was ever observed.</summary>
        public decimal? MaxExecutableFloatingLoss => _maxExecutableFloatingLoss;

        /// <summary>One compact research record per closed basket, in closing order.</summary>
        public IReadOnlyList<BasketResearchRecord> BasketRecords => _basketRecords;

        /// <summary>The run's research account snapshot, taken after the end-of-run observation.</summary>
        public ResearchAccountSummary Summary => new ResearchAccountSummary(
            InitialBalance,
            Balance,
            Equity,
            FloatingProfit,
            FloatingObservable,
            FloatingObservationsSkipped,
            RealizedProfit,
            PeakBalance,
            MaxBalanceDrawdown,
            PeakEquity,
            MaxEquityDrawdown,
            _openPositions,
            _maxOpenPositions,
            _grossLots,
            _maxGrossLots,
            _absoluteNetLots,
            _maxAbsoluteNetLots,
            _maxExecutableFloatingProfit,
            _maxExecutableFloatingLoss,
            _basketRecords.Count);

        /// <summary>
        /// The run's target-account margin/survival evidence, or null when the account was created
        /// without <see cref="MarginParameters"/> (PR 3 margin disabled). The current values are
        /// the last observed account state; <see cref="MarginStopOut"/> is non-null exactly when
        /// the run stopped out.
        /// </summary>
        public ResearchMarginSummary? MarginSummary => _margin == null
            ? null
            : new ResearchMarginSummary(
                _margin,
                _currentUsedMargin,
                _currentFreeMargin,
                _currentMarginLevelPercent,
                _maxUsedMargin,
                _minFreeMargin,
                _minMarginLevelPercent,
                _marginCallActive,
                _marginCallObservations,
                _marginCallEpisodes,
                _marginCallBlockedAttempts,
                _marginCallBlockedEpisodes,
                _insufficientMarginAttempts,
                _insufficientMarginEpisodes,
                _stopOut);

        /// <summary>
        /// The compact research state of a basket that is still open (ordinary end of data or a
        /// run-ending strategy fault), or null when no basket is open. It never pretends the
        /// basket closed: there is no close reason or realized profit, only the basket's path
        /// and sizing/rejection facts, including its own floating extrema and the number of
        /// skipped executable marks. It is computed from the engine's live basket and the
        /// account's observations; calling it more than once changes nothing.
        /// </summary>
        public ActiveBasketResearch? SnapshotActiveBasket(Basket? basket)
        {
            if (basket == null) return null;
            var legs = new LegRecord[basket.Legs.Count];
            for (var i = 0; i < legs.Length; i++)
            {
                legs[i] = LegRecord.From(basket.Sequence, basket.Legs[i]);
            }
            var active = _active != null && _active.Sequence == basket.Sequence ? _active : null;
            var facts = ComputeFacts(
                legs,
                basket.Rejections,
                active,
                basket.OpenPositions,
                basket.GrossLots,
                Math.Abs(basket.NetLots));
            return new ActiveBasketResearch(
                basket.Sequence,
                basket.CreatedTime,
                facts.FirstEntryTime,
                facts.FirstSide,
                facts.EntryCount,
                facts.DeepestTradeNumber,
                facts.DeepestAttemptedTradeNumber,
                facts.MaxOpenPositions,
                facts.MaxGrossLots,
                facts.MaxAbsoluteNetLots,
                facts.MaxIndividualPlacedLot,
                facts.MaxFloatingProfit,
                facts.MaxFloatingLoss,
                facts.FloatingObservationsSkipped,
                basket.HardBreakevenModeActive,
                basket.HardBreakevenModeActive ? _parameters.NormalTradeCount + 1 : (int?)null,
                facts.LargestExactRequiredTailLot,
                facts.LargestNormalizedRequiredTailLot,
                facts.LargestPlacedTailLot,
                facts.HardBreakevenInfeasibleAttempts,
                facts.HardBreakevenInfeasibleEpisodes,
                facts.Rejections);
        }

        /// <inheritdoc />
        public void ObserveQuote(in Quote quote, Basket? basket, decimal realizedProfit, decimal? rawProfit)
        {
            Observe(quote, basket, realizedProfit, rawProfit);
        }

        /// <summary>
        /// Observes one processed quote when the caller has no precomputed raw profit; the
        /// account derives it. Equivalent to passing a null <c>rawProfit</c>.
        /// </summary>
        public void ObserveQuote(in Quote quote, Basket? basket, decimal realizedProfit)
        {
            Observe(quote, basket, realizedProfit, null);
        }

        /// <summary>
        /// Observes the end-of-data mark with the last processed quote. It is genuinely
        /// idempotent: when the quote, the basket state and the realized profit are exactly the
        /// last observed ones, nothing happens, so the host's final call cannot double-count a
        /// skipped executable mark (the engine has already observed every processed quote). Any
        /// other state (a later quote, a new leg or a realized change) is observed normally.
        /// </summary>
        public void ObserveEndOfRun(in Quote quote, Basket? basket, decimal realizedProfit)
        {
            if (_hasObservation
                && quote.Time == _lastQuoteTime
                && quote.Bid == _lastQuoteBid
                && quote.Ask == _lastQuoteAsk
                && (basket?.Sequence ?? -1) == _lastBasketSequence
                && (basket?.OpenPositions ?? -1) == _lastOpenPositions
                && realizedProfit == _lastRealizedProfit)
            {
                return;
            }
            Observe(quote, basket, realizedProfit, null);
        }

        /// <inheritdoc />
        public void ObserveClose(BasketCloseRecord record, decimal realizedProfit)
        {
            if (record == null) throw new ArgumentNullException(nameof(record));
            var active = _active != null && _active.Sequence == record.Sequence ? _active : null;
            _active = null;
            _basketRecords.Add(BuildRecord(record, active));

            // The basket is closed: floating P/L returns to zero and the realized result reaches
            // the balance on this observation, so a realized loss/gain is not lost when no later
            // quote is delivered.
            Observe(default, null, realizedProfit, null);
        }

        /// <inheritdoc />
        public bool SurvivalObservable => _margin != null && _floatingObservable;

        /// <inheritdoc />
        public MarginStopOut? EvaluateSurvival(in Quote quote)
        {
            var margin = RequireMargin();
            if (_stopOut != null)
            {
                return _stopOut;
            }
            if (_openPositions <= 0)
            {
                // No open leg can be stopped out. A flat account with a negative balance is not a
                // broker stop-out: there is nothing to liquidate, and the negative free margin
                // already blocks every candidate under the financing test.
                return null;
            }

            var marginLevel = _currentMarginLevelPercent;
            StopOutReason reason;
            if (marginLevel.HasValue && marginLevel.Value <= margin.StopOutLevelPercent)
            {
                reason = StopOutReason.MarginLevel;
            }
            else if (_equity < 0m)
            {
                // The approved hedged-account rule: open positions and negative equity are
                // terminal even when the matched hedge leaves zero used margin and the margin
                // level is therefore undefined.
                reason = StopOutReason.NegativeEquity;
            }
            else
            {
                return null;
            }

            // The engine calls this immediately after the observation of the same quote and only
            // while SurvivalObservable is true, so the equity and margin values below are current
            // for that quote; a skipped executable mark stops the run instead (the account keeps
            // its last observable values only for presentation and the skipped-mark count).
            _stopOut = new MarginStopOut(
                reason,
                quote.Time,
                _balance,
                _floatingProfit,
                _equity,
                _currentUsedMargin,
                _currentFreeMargin ?? _equity - _currentUsedMargin,
                marginLevel,
                _openPositions);
            return _stopOut;
        }

        /// <inheritdoc />
        public MarginEntryAssessment AssessEntry(EntryOrder order, Basket basket)
        {
            var margin = RequireMargin();
            if (basket == null) throw new ArgumentNullException(nameof(basket));

            // Approved order: the Margin Call entry block comes first, so an account at or below
            // the Margin Call Level rejects every candidate before any projection is made.
            var marginLevel = _currentMarginLevelPercent;
            if (marginLevel.HasValue && marginLevel.Value <= margin.MarginCallLevelPercent)
            {
                return new MarginEntryAssessment(MarginEntryDecision.MarginCall, _currentUsedMargin, _currentFreeMargin, marginLevel, null, null);
            }

            // Financing: the candidate fills into the complete projected post-fill inventory at
            // the configured execution model's executable entry price, and the projected account
            // must have non-negative free margin (equity at the current quote at least the
            // projected used margin). This is deliberately not an isolated candidate-lot charge:
            // an opposite-side entry can reduce the projected used margin by increasing the
            // matched volume.
            var candidateEntryPrice = BasketEconomics.ExecutableEntryPrice(order.Side, order.Quote, _parameters);
            var projectedUsedMargin = MarginModel.ProjectedUsedMargin(basket, order.Side, order.Lots, candidateEntryPrice, margin);
            var projectedFreeMargin = _equity - projectedUsedMargin;
            var decision = projectedFreeMargin < 0m ? MarginEntryDecision.InsufficientMargin : MarginEntryDecision.Allowed;
            return new MarginEntryAssessment(decision, _currentUsedMargin, _currentFreeMargin, marginLevel, projectedUsedMargin, projectedFreeMargin);
        }

        /// <inheritdoc />
        public void ObserveEntryRejection(EntryRejection rejection, bool isNewEpisode)
        {
            switch (rejection.Reason)
            {
                case EntryRejectionReason.MarginCall:
                    _marginCallBlockedAttempts++;
                    if (isNewEpisode) _marginCallBlockedEpisodes++;
                    break;
                case EntryRejectionReason.InsufficientMargin:
                    _insufficientMarginAttempts++;
                    if (isNewEpisode) _insufficientMarginEpisodes++;
                    break;
            }
        }

        private MarginParameters RequireMargin()
        {
            if (_margin == null)
            {
                throw new InvalidOperationException("This research account was created without margin parameters; it is not a PR 3 risk guard.");
            }
            return _margin;
        }

        private void Observe(in Quote quote, Basket? basket, decimal realizedProfit, decimal? rawProfit)
        {
            // Remember the exact observation state so ObserveEndOfRun can recognise a repeat
            // (the engine already observes every processed quote).
            _hasObservation = true;
            _lastQuoteTime = quote.Time;
            _lastQuoteBid = quote.Bid;
            _lastQuoteAsk = quote.Ask;
            _lastBasketSequence = basket?.Sequence ?? -1;
            _lastOpenPositions = basket?.OpenPositions ?? -1;
            _lastRealizedProfit = realizedProfit;

            // Realized profit changes only when a basket closes, so the balance and its drawdown
            // are recomputed only then; every other quote reuses the cached balance.
            if (realizedProfit != _observedRealizedProfit)
            {
                _observedRealizedProfit = realizedProfit;
                _balance = InitialBalance + realizedProfit;
                if (_balance > _peakBalance) _peakBalance = _balance;
                var balanceDrawdown = _peakBalance - _balance;
                if (balanceDrawdown > _maxBalanceDrawdown) _maxBalanceDrawdown = balanceDrawdown;
            }

            // Within one basket the ledger is append-only, so the exposure values can change only
            // when the basket changes or its open-position count changes. Everything else reuses
            // the last observed values.
            var openPositions = basket?.OpenPositions ?? 0;
            if (basket == null)
            {
                _openPositions = 0;
                _grossLots = 0m;
                _absoluteNetLots = 0m;
            }
            else
            {
                var active = _active;
                if (active == null || active.Sequence != basket.Sequence || openPositions != _openPositions)
                {
                    var grossLots = basket.GrossLots;
                    var absoluteNetLots = Math.Abs(basket.NetLots);
                    if (active == null || active.Sequence != basket.Sequence)
                    {
                        active = new ActiveBasket(basket.Sequence);
                        _active = active;
                    }
                    _openPositions = openPositions;
                    _grossLots = grossLots;
                    _absoluteNetLots = absoluteNetLots;
                    if (openPositions > _maxOpenPositions) _maxOpenPositions = openPositions;
                    if (grossLots > _maxGrossLots) _maxGrossLots = grossLots;
                    if (absoluteNetLots > _maxAbsoluteNetLots) _maxAbsoluteNetLots = absoluteNetLots;
                    active.ObserveExposure(openPositions, grossLots, absoluteNetLots);
                }
            }

            // PR 3: used margin is pure inventory state, so its maximum is observed on every
            // observation, including one whose executable mark below is skipped.
            var usedMargin = 0m;
            if (_margin != null)
            {
                usedMargin = openPositions > 0 ? MarginModel.UsedMargin(basket!, _margin) : 0m;
                if (usedMargin > _maxUsedMargin) _maxUsedMargin = usedMargin;
            }

            var floating = 0m;
            var observable = true;
            if (openPositions > 0)
            {
                // The executable mark is the raw price P/L of the basket at this quote (the engine
                // already computed it on this quote's path when available) less the configured
                // per-lot cost of the simultaneous close: slippage converted to account currency
                // plus the round-trip commission, applied to the gross volume. This is the exact
                // rearrangement of BasketEconomics.ExecutableProfit at the executable close
                // prices, and the equivalence is pinned by tests.
                var raw = rawProfit ?? BasketEconomics.RawProfit(basket!, quote, _parameters);
                if ((basket!.BuyLots == 0m || quote.Bid - _slippage > 0m)
                    && (basket.SellLots == 0m || quote.Ask + _slippage > 0m))
                {
                    floating = raw - _costPerLot * _grossLots;
                }
                else
                {
                    // The executable mark is not defined at this quote (a needed close price is
                    // not positive). The observation is skipped rather than fabricated, and the
                    // skip is counted permanently so the extrema can never look complete.
                    observable = false;
                }
            }

            if (!observable)
            {
                _floatingObservable = false;
                _floatingObservationsSkipped++;
                _active?.ObserveSkippedFloating();
                return;
            }

            _floatingObservable = true;
            _floatingProfit = floating;
            _equity = _balance + floating;
            if (_equity > _peakEquity) _peakEquity = _equity;
            var equityDrawdown = _peakEquity - _equity;
            if (equityDrawdown > _maxEquityDrawdown) _maxEquityDrawdown = equityDrawdown;

            if (_margin != null)
            {
                ObserveMarginState(usedMargin);
            }

            if (openPositions > 0)
            {
                if (!_maxExecutableFloatingProfit.HasValue || floating > _maxExecutableFloatingProfit.Value)
                {
                    _maxExecutableFloatingProfit = floating;
                }
                if (!_maxExecutableFloatingLoss.HasValue || floating < _maxExecutableFloatingLoss.Value)
                {
                    _maxExecutableFloatingLoss = floating;
                }
                _active?.ObserveFloating(floating);
            }
        }

        /// <summary>
        /// Updates the PR 3 margin state from the current executable equity and the inventory used
        /// margin. The current values and the free-margin/margin-level extrema are exact decimal
        /// ratios of the observed state; the minimum free margin and minimum margin level may be
        /// incomplete when an executable mark was skipped, which
        /// <see cref="FloatingObservationsSkipped"/> makes explicit for the run.
        /// </summary>
        private void ObserveMarginState(decimal usedMargin)
        {
            _currentUsedMargin = usedMargin;
            _currentFreeMargin = _equity - usedMargin;
            _currentMarginLevelPercent = MarginModel.MarginLevelPercent(_equity, usedMargin);

            if (!_minFreeMargin.HasValue || _currentFreeMargin.Value < _minFreeMargin.Value)
            {
                _minFreeMargin = _currentFreeMargin;
            }
            if (_currentMarginLevelPercent.HasValue
                && (!_minMarginLevelPercent.HasValue || _currentMarginLevelPercent.Value < _minMarginLevelPercent.Value))
            {
                _minMarginLevelPercent = _currentMarginLevelPercent;
            }

            // Margin Call is not diagnostic-only: the engine consults the recorded state through
            // the risk guard before any candidate is financed. At or below the level no new
            // position may be opened; a later quote above it may clear the state.
            var marginCall = _currentMarginLevelPercent.HasValue
                && _currentMarginLevelPercent.Value <= _margin!.MarginCallLevelPercent;
            if (marginCall)
            {
                _marginCallObservations++;
                if (!_marginCallActive)
                {
                    _marginCallEpisodes++;
                }
            }
            _marginCallActive = marginCall;
        }

        private BasketResearchRecord BuildRecord(BasketCloseRecord record, ActiveBasket? activeExtrema)
        {
            var facts = ComputeFacts(
                record.LegTrace,
                record.RejectionTrace,
                activeExtrema,
                record.Legs,
                record.GrossLots,
                Math.Abs(record.NetLots));
            var durationSeconds = facts.FirstEntryTime.HasValue
                ? ((decimal)(record.ClosedTime - facts.FirstEntryTime.Value).Ticks) / TimeSpan.TicksPerSecond
                : (decimal?)null;
            return new BasketResearchRecord(
                record.Sequence,
                record.CreatedTime,
                facts.FirstEntryTime,
                record.ClosedTime,
                durationSeconds,
                facts.FirstSide,
                facts.EntryCount,
                facts.DeepestTradeNumber,
                facts.DeepestAttemptedTradeNumber,
                facts.MaxOpenPositions,
                facts.MaxGrossLots,
                facts.MaxAbsoluteNetLots,
                facts.MaxIndividualPlacedLot,
                facts.MaxFloatingProfit,
                facts.MaxFloatingLoss,
                facts.FloatingObservationsSkipped,
                record.Reason,
                record.RealizedProfit,
                record.HardBreakevenModeActive,
                record.HardBreakevenModeActive ? _parameters.NormalTradeCount + 1 : (int?)null,
                facts.LargestExactRequiredTailLot,
                facts.LargestNormalizedRequiredTailLot,
                facts.LargestPlacedTailLot,
                facts.HardBreakevenInfeasibleAttempts,
                facts.HardBreakevenInfeasibleEpisodes,
                facts.Rejections);
        }

        /// <summary>
        /// The shared per-basket facts derived from the engine's leg and rejection traces plus
        /// the account's path observations. The <c>fallback*</c> arguments are the final live
        /// exposure values used as lower bounds for the maxima when no observation recorded the
        /// basket (they cannot exceed the true maxima under the append-only ledger).
        /// </summary>
        private static BasketFacts ComputeFacts(
            IReadOnlyList<LegRecord> legs,
            IReadOnlyList<EntryRejectionRecord> rejectionRows,
            ActiveBasket? activeExtrema,
            int fallbackOpenPositions,
            decimal fallbackGrossLots,
            decimal fallbackAbsoluteNetLots)
        {
            DateTime? firstEntryTime = legs.Count > 0 ? legs[0].Time : (DateTime?)null;
            TradeSide? firstSide = legs.Count > 0 ? legs[0].Side : (TradeSide?)null;
            var deepestTradeNumber = 0;
            decimal? maxPlaced = null;
            decimal? maxPlacedTail = null;
            decimal? maxExactTail = null;
            decimal? maxNormalizedTail = null;
            for (var i = 0; i < legs.Count; i++)
            {
                var leg = legs[i];
                if (leg.TradeNumber > deepestTradeNumber) deepestTradeNumber = leg.TradeNumber;
                if (maxPlaced == null || leg.PlacedLot > maxPlaced.Value) maxPlaced = leg.PlacedLot;
                if (leg.Regime != SizingRegime.HardBreakeven) continue;
                if (maxPlacedTail == null || leg.PlacedLot > maxPlacedTail.Value) maxPlacedTail = leg.PlacedLot;
                if (leg.ExactRequiredLot.HasValue && (maxExactTail == null || leg.ExactRequiredLot.Value > maxExactTail.Value))
                {
                    maxExactTail = leg.ExactRequiredLot;
                }
                if (maxNormalizedTail == null || leg.NormalizedRequiredLot > maxNormalizedTail.Value)
                {
                    maxNormalizedTail = leg.NormalizedRequiredLot;
                }
            }

            var deepestAttemptedTradeNumber = deepestTradeNumber;
            long hardBreakevenInfeasibleAttempts = 0;
            long hardBreakevenInfeasibleEpisodes = 0;
            for (var i = 0; i < rejectionRows.Count; i++)
            {
                var row = rejectionRows[i];
                if (row.TradeNumber > deepestAttemptedTradeNumber) deepestAttemptedTradeNumber = row.TradeNumber;
                if (row.Outcome.HasValue)
                {
                    // A hard-BE sizing was attached, including a feasible sizing whose execution
                    // failed: its requirement is part of the tail evidence even though the
                    // rejection reason is not hard-BE infeasibility.
                    if (row.MaxExactRequiredLots.HasValue && (maxExactTail == null || row.MaxExactRequiredLots.Value > maxExactTail.Value))
                    {
                        maxExactTail = row.MaxExactRequiredLots;
                    }
                    if (maxNormalizedTail == null || row.MaxNormalizedRequiredLots > maxNormalizedTail.Value)
                    {
                        maxNormalizedTail = row.MaxNormalizedRequiredLots;
                    }
                }
                if (row.Reason != EntryRejectionReason.HardBreakevenInfeasible) continue;
                hardBreakevenInfeasibleEpisodes++;
                hardBreakevenInfeasibleAttempts += row.Attempts;
            }

            return new BasketFacts(
                firstEntryTime,
                firstSide,
                legs.Count,
                deepestTradeNumber,
                deepestAttemptedTradeNumber,
                Math.Max(fallbackOpenPositions, activeExtrema?.MaxOpenPositions ?? 0),
                Math.Max(fallbackGrossLots, activeExtrema?.MaxGrossLots ?? 0m),
                Math.Max(fallbackAbsoluteNetLots, activeExtrema?.MaxAbsoluteNetLots ?? 0m),
                maxPlaced,
                activeExtrema?.MaxFloatingProfit,
                activeExtrema?.MaxFloatingLoss,
                activeExtrema?.FloatingObservationsSkipped ?? 0,
                maxExactTail,
                maxNormalizedTail,
                maxPlacedTail,
                hardBreakevenInfeasibleAttempts,
                hardBreakevenInfeasibleEpisodes,
                SummarizeRejections(rejectionRows));
        }

        private static IReadOnlyList<ResearchRejectionCount> SummarizeRejections(IReadOnlyList<EntryRejectionRecord> rows)
        {
            if (rows.Count == 0) return Array.Empty<ResearchRejectionCount>();
            var groups = new List<ResearchRejectionCount>();
            for (var i = 0; i < rows.Count; i++)
            {
                var row = rows[i];
                var index = IndexOf(groups, row.Reason, row.Outcome);
                if (index >= 0)
                {
                    var existing = groups[index];
                    groups[index] = existing with { Episodes = existing.Episodes + 1, Attempts = existing.Attempts + row.Attempts };
                }
                else
                {
                    groups.Add(new ResearchRejectionCount(row.Reason, row.Outcome, 1, row.Attempts));
                }
            }
            groups.Sort(static (left, right) =>
            {
                var reason = left.Reason.CompareTo(right.Reason);
                if (reason != 0) return reason;
                if (!left.Outcome.HasValue) return right.Outcome.HasValue ? -1 : 0;
                if (!right.Outcome.HasValue) return 1;
                return left.Outcome.Value.CompareTo(right.Outcome.Value);
            });
            return groups;
        }

        private static int IndexOf(List<ResearchRejectionCount> groups, EntryRejectionReason reason, HardBreakevenOutcome? outcome)
        {
            for (var i = 0; i < groups.Count; i++)
            {
                if (groups[i].Reason == reason && groups[i].Outcome == outcome) return i;
            }
            return -1;
        }

        /// <summary>The running path extrema and completeness state of the one basket currently open.</summary>
        private sealed class ActiveBasket
        {
            public ActiveBasket(int sequence)
            {
                Sequence = sequence;
            }

            public int Sequence { get; }
            public int MaxOpenPositions { get; private set; }
            public decimal MaxGrossLots { get; private set; }
            public decimal MaxAbsoluteNetLots { get; private set; }
            public decimal? MaxFloatingProfit { get; private set; }
            public decimal? MaxFloatingLoss { get; private set; }
            public long FloatingObservationsSkipped { get; private set; }

            public void ObserveExposure(int openPositions, decimal grossLots, decimal absoluteNetLots)
            {
                if (openPositions > MaxOpenPositions) MaxOpenPositions = openPositions;
                if (grossLots > MaxGrossLots) MaxGrossLots = grossLots;
                if (absoluteNetLots > MaxAbsoluteNetLots) MaxAbsoluteNetLots = absoluteNetLots;
            }

            public void ObserveFloating(decimal floating)
            {
                if (!MaxFloatingProfit.HasValue || floating > MaxFloatingProfit.Value) MaxFloatingProfit = floating;
                if (!MaxFloatingLoss.HasValue || floating < MaxFloatingLoss.Value) MaxFloatingLoss = floating;
            }

            public void ObserveSkippedFloating()
            {
                FloatingObservationsSkipped++;
            }
        }

        /// <summary>The compact facts shared by the closed-basket and active-basket records.</summary>
        private readonly struct BasketFacts
        {
            public BasketFacts(
                DateTime? firstEntryTime,
                TradeSide? firstSide,
                int entryCount,
                int deepestTradeNumber,
                int deepestAttemptedTradeNumber,
                int maxOpenPositions,
                decimal maxGrossLots,
                decimal maxAbsoluteNetLots,
                decimal? maxIndividualPlacedLot,
                decimal? maxFloatingProfit,
                decimal? maxFloatingLoss,
                long floatingObservationsSkipped,
                decimal? largestExactRequiredTailLot,
                decimal? largestNormalizedRequiredTailLot,
                decimal? largestPlacedTailLot,
                long hardBreakevenInfeasibleAttempts,
                long hardBreakevenInfeasibleEpisodes,
                IReadOnlyList<ResearchRejectionCount> rejections)
            {
                FirstEntryTime = firstEntryTime;
                FirstSide = firstSide;
                EntryCount = entryCount;
                DeepestTradeNumber = deepestTradeNumber;
                DeepestAttemptedTradeNumber = deepestAttemptedTradeNumber;
                MaxOpenPositions = maxOpenPositions;
                MaxGrossLots = maxGrossLots;
                MaxAbsoluteNetLots = maxAbsoluteNetLots;
                MaxIndividualPlacedLot = maxIndividualPlacedLot;
                MaxFloatingProfit = maxFloatingProfit;
                MaxFloatingLoss = maxFloatingLoss;
                FloatingObservationsSkipped = floatingObservationsSkipped;
                LargestExactRequiredTailLot = largestExactRequiredTailLot;
                LargestNormalizedRequiredTailLot = largestNormalizedRequiredTailLot;
                LargestPlacedTailLot = largestPlacedTailLot;
                HardBreakevenInfeasibleAttempts = hardBreakevenInfeasibleAttempts;
                HardBreakevenInfeasibleEpisodes = hardBreakevenInfeasibleEpisodes;
                Rejections = rejections;
            }

            public DateTime? FirstEntryTime { get; }
            public TradeSide? FirstSide { get; }
            public int EntryCount { get; }
            public int DeepestTradeNumber { get; }
            public int DeepestAttemptedTradeNumber { get; }
            public int MaxOpenPositions { get; }
            public decimal MaxGrossLots { get; }
            public decimal MaxAbsoluteNetLots { get; }
            public decimal? MaxIndividualPlacedLot { get; }
            public decimal? MaxFloatingProfit { get; }
            public decimal? MaxFloatingLoss { get; }
            public long FloatingObservationsSkipped { get; }
            public decimal? LargestExactRequiredTailLot { get; }
            public decimal? LargestNormalizedRequiredTailLot { get; }
            public decimal? LargestPlacedTailLot { get; }
            public long HardBreakevenInfeasibleAttempts { get; }
            public long HardBreakevenInfeasibleEpisodes { get; }
            public IReadOnlyList<ResearchRejectionCount> Rejections { get; }
        }
    }

    /// <summary>
    /// The run-level research account values written to the results (roadmap section 3.12).
    /// The balance, equity and floating values are the current ones at the moment of the
    /// snapshot; the host takes the snapshot after the end-of-run observation, so they are the
    /// run's final values. <see cref="FloatingObservable"/> describes only the last observation;
    /// <see cref="FloatingObservationsSkipped"/> is the persistent completeness flag for the
    /// whole run: when it is non-zero, the equity and floating extrema may be incomplete.
    /// </summary>
    public sealed record ResearchAccountSummary(
        decimal InitialBalance,
        decimal Balance,
        decimal Equity,
        decimal FloatingProfit,
        bool FloatingObservable,
        long FloatingObservationsSkipped,
        decimal RealizedProfit,
        decimal PeakBalance,
        decimal MaxBalanceDrawdown,
        decimal PeakEquity,
        decimal MaxEquityDrawdown,
        int CurrentOpenPositions,
        int MaxOpenPositions,
        decimal CurrentGrossLots,
        decimal MaxGrossLots,
        decimal CurrentAbsoluteNetLots,
        decimal MaxAbsoluteNetLots,
        decimal? MaxExecutableFloatingProfit,
        decimal? MaxExecutableFloatingLoss,
        int ClosedBasketsObserved);

    /// <summary>
    /// One closed basket's research record (roadmap section 3.13). It adds the observed path
    /// extrema of the basket to the strategy's own close record; the leg, rejection and
    /// skipped-entry traces stay in <see cref="BasketCloseRecord"/>. The three lot concepts stay
    /// separate: <see cref="LargestExactRequiredTailLot"/> (Q_BE),
    /// <see cref="LargestNormalizedRequiredTailLot"/> (the broker-normalized requirement) and
    /// <see cref="LargestPlacedTailLot"/> (what was actually opened).
    /// <see cref="DeepestTradeNumber"/> is the deepest <em>placed</em> trade number (the retired
    /// repository's basket depth); <see cref="DeepestAttemptedTradeNumber"/> additionally covers
    /// rejected attempts, so a required but infeasible tail is visible without overloading the
    /// depth statistic. The tail-lot maxima include the requirements of hard-BE episodes, and
    /// <see cref="HardBreakevenInfeasibleAttempts"/> /
    /// <see cref="HardBreakevenInfeasibleEpisodes"/> count the hard-BE <em>infeasibility</em>
    /// episodes only (an execution failure with a feasible hard-BE sizing is counted by its
    /// reason in <see cref="Rejections"/> and still contributes its requirement to the maxima).
    /// <see cref="FloatingObservationsSkipped"/> is the number of executable marks this basket
    /// could not observe; when it is non-zero the floating extrema may be incomplete.
    /// </summary>
    public sealed record BasketResearchRecord(
        int Basket,
        DateTime AnchorTime,
        DateTime? FirstEntryTime,
        DateTime CloseTime,
        decimal? DurationFromFirstEntrySeconds,
        TradeSide? FirstSide,
        int EntryCount,
        int DeepestTradeNumber,
        int DeepestAttemptedTradeNumber,
        int MaxOpenPositions,
        decimal MaxGrossLots,
        decimal MaxAbsoluteNetLots,
        decimal? MaxIndividualPlacedLot,
        decimal? MaxExecutableFloatingProfit,
        decimal? MaxExecutableFloatingLoss,
        long FloatingObservationsSkipped,
        ExitReason CloseReason,
        decimal RealizedProfit,
        bool HardBreakevenModeActivated,
        int? FirstHardBreakevenTradeNumber,
        decimal? LargestExactRequiredTailLot,
        decimal? LargestNormalizedRequiredTailLot,
        decimal? LargestPlacedTailLot,
        long HardBreakevenInfeasibleAttempts,
        long HardBreakevenInfeasibleEpisodes,
        IReadOnlyList<ResearchRejectionCount> Rejections);

    /// <summary>
    /// The compact research state of a basket that is still open at end of data or at a
    /// run-ending strategy fault. It is deliberately not a <see cref="BasketResearchRecord"/>:
    /// the basket did not close, so there is no close reason, realized profit or duration, and
    /// nothing is fabricated. It carries the same path, lot and rejection facts (including the
    /// basket's own floating extrema and its skipped-mark count) so the final unresolved
    /// basket's history is not lost. <see cref="DeepestTradeNumber"/> is the deepest placed
    /// trade and <see cref="DeepestAttemptedTradeNumber"/> includes rejected attempts.
    /// </summary>
    public sealed record ActiveBasketResearch(
        int Basket,
        DateTime AnchorTime,
        DateTime? FirstEntryTime,
        TradeSide? FirstSide,
        int EntryCount,
        int DeepestTradeNumber,
        int DeepestAttemptedTradeNumber,
        int MaxOpenPositions,
        decimal MaxGrossLots,
        decimal MaxAbsoluteNetLots,
        decimal? MaxIndividualPlacedLot,
        decimal? MaxExecutableFloatingProfit,
        decimal? MaxExecutableFloatingLoss,
        long FloatingObservationsSkipped,
        bool HardBreakevenModeActivated,
        int? FirstHardBreakevenTradeNumber,
        decimal? LargestExactRequiredTailLot,
        decimal? LargestNormalizedRequiredTailLot,
        decimal? LargestPlacedTailLot,
        long HardBreakevenInfeasibleAttempts,
        long HardBreakevenInfeasibleEpisodes,
        IReadOnlyList<ResearchRejectionCount> Rejections);

    /// <summary>
    /// One rejection count of a closed or active basket: the distinct rejection episodes and the
    /// total attempts, keyed by reason and hard-BE outcome. The distinction between an individual
    /// rejected attempt and a compact rejection episode is preserved for both totals.
    /// </summary>
    public sealed record ResearchRejectionCount(
        EntryRejectionReason Reason,
        HardBreakevenOutcome? Outcome,
        long Episodes,
        long Attempts);
}
