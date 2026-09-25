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
    /// account snapshot explicitly at the end-of-data quote.
    /// </remarks>
    public interface IResearchObserver
    {
        /// <summary>
        /// Observes one processed quote with the engine's current basket (null between baskets)
        /// and its current realized profit. Called before an exit can close the basket and once
        /// more after a newly filled leg; an implementation must be O(1) and allocate nothing on
        /// the per-quote path.
        /// </summary>
        void ObserveQuote(in Quote quote, Basket? basket, decimal realizedProfit);

        /// <summary>
        /// Observes a basket that has just closed, with the engine's realized profit after the
        /// close. The record is final; its leg, rejection and skipped-entry traces are available
        /// for the per-basket research record.
        /// </summary>
        void ObserveClose(BasketCloseRecord record, decimal realizedProfit);
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
    /// Run-level values are constant-time accumulators; the only retained records are one
    /// compact record per closed basket (its path extrema plus the values derived from the
    /// engine's existing leg and rejection traces). Nothing is retained per quote, and no
    /// per-quote object, string or file is created.
    /// </remarks>
    public sealed class SingleAnchorResearchAccount : IResearchObserver
    {
        private readonly SingleAnchorParameters _parameters;
        private readonly List<BasketResearchRecord> _basketRecords = new List<BasketResearchRecord>();
        private ActiveBasket? _active;
        private decimal _realizedProfit;
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

        /// <summary>
        /// Creates an account for a validated parameter set and the run's initial balance
        /// (<c>single-anchor-cash</c> in the LEAN host).
        /// </summary>
        public SingleAnchorResearchAccount(SingleAnchorParameters parameters, decimal initialBalance)
        {
            _parameters = parameters ?? throw new ArgumentNullException(nameof(parameters));
            InitialBalance = initialBalance;
            _peakBalance = initialBalance;
            _peakEquity = initialBalance;
            _equity = initialBalance;
        }

        /// <summary>The run's starting balance; the account never changes it.</summary>
        public decimal InitialBalance { get; }

        /// <summary>The last observed engine realized profit; the account does not accumulate its own.</summary>
        public decimal RealizedProfit => _realizedProfit;

        /// <summary>InitialBalance + RealizedProfit, the current (at end of run, final) balance.</summary>
        public decimal Balance => InitialBalance + _realizedProfit;

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

        /// <inheritdoc />
        public void ObserveQuote(in Quote quote, Basket? basket, decimal realizedProfit)
        {
            Observe(quote, basket, realizedProfit);
        }

        /// <summary>
        /// Observes the end-of-data mark with the last processed quote. It is the same
        /// observation as a processed quote; when that quote was already observed with the same
        /// basket and realized profit it changes no aggregate (maximum/minimum updates are
        /// strict), so calling the account once more before writing results is safe.
        /// </summary>
        public void ObserveEndOfRun(in Quote quote, Basket? basket, decimal realizedProfit)
        {
            Observe(quote, basket, realizedProfit);
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
            Observe(default, null, realizedProfit);
        }

        private void Observe(in Quote quote, Basket? basket, decimal realizedProfit)
        {
            _realizedProfit = realizedProfit;
            var balance = InitialBalance + realizedProfit;
            if (balance > _peakBalance) _peakBalance = balance;
            var balanceDrawdown = _peakBalance - balance;
            if (balanceDrawdown > _maxBalanceDrawdown) _maxBalanceDrawdown = balanceDrawdown;

            var openPositions = basket?.OpenPositions ?? 0;
            var grossLots = basket?.GrossLots ?? 0m;
            var absoluteNetLots = basket == null ? 0m : Math.Abs(basket.NetLots);
            _openPositions = openPositions;
            _grossLots = grossLots;
            _absoluteNetLots = absoluteNetLots;
            if (openPositions > _maxOpenPositions) _maxOpenPositions = openPositions;
            if (grossLots > _maxGrossLots) _maxGrossLots = grossLots;
            if (absoluteNetLots > _maxAbsoluteNetLots) _maxAbsoluteNetLots = absoluteNetLots;

            if (basket != null)
            {
                var active = _active;
                if (active == null || active.Sequence != basket.Sequence)
                {
                    active = new ActiveBasket(basket.Sequence);
                    _active = active;
                }
                active.ObserveExposure(openPositions, grossLots, absoluteNetLots);
            }

            var floating = 0m;
            var observable = true;
            if (openPositions > 0)
            {
                var (buyClose, sellClose) = BasketEconomics.ExecutableClosePrices(quote, _parameters);
                if (BasketEconomics.ArePricesUsable(basket!, buyClose, sellClose, null))
                {
                    floating = BasketEconomics.ExecutableProfit(basket!, buyClose, sellClose, _parameters);
                }
                else
                {
                    // The executable mark is not defined at this quote (a needed close price is
                    // not positive); the observation is skipped rather than fabricated.
                    observable = false;
                }
            }

            if (!observable)
            {
                _floatingObservable = false;
                return;
            }

            _floatingObservable = true;
            _floatingProfit = floating;
            _equity = balance + floating;
            if (_equity > _peakEquity) _peakEquity = _equity;
            var equityDrawdown = _peakEquity - _equity;
            if (equityDrawdown > _maxEquityDrawdown) _maxEquityDrawdown = equityDrawdown;

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

        private BasketResearchRecord BuildRecord(BasketCloseRecord record, ActiveBasket? activeExtrema)
        {
            var legs = record.LegTrace;
            DateTime? firstEntryTime = legs.Count > 0 ? legs[0].Time : (DateTime?)null;
            decimal? durationSeconds = firstEntryTime.HasValue
                ? ((decimal)(record.ClosedTime - firstEntryTime.Value).Ticks) / TimeSpan.TicksPerSecond
                : (decimal?)null;
            var maxOpenPositions = Math.Max(record.Legs, activeExtrema?.MaxOpenPositions ?? 0);
            var maxGrossLots = Math.Max(record.GrossLots, activeExtrema?.MaxGrossLots ?? 0m);
            var maxAbsoluteNetLots = Math.Max(Math.Abs(record.NetLots), activeExtrema?.MaxAbsoluteNetLots ?? 0m);

            decimal? maxPlaced = null;
            decimal? maxPlacedTail = null;
            decimal? maxExactTail = null;
            decimal? maxNormalizedTail = null;
            for (var i = 0; i < legs.Count; i++)
            {
                var leg = legs[i];
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

            var deepestTradeNumber = legs.Count > 0 ? legs[legs.Count - 1].TradeNumber : 0;
            long hardBreakevenAttempts = 0;
            long hardBreakevenEpisodes = 0;
            var rejectionRows = record.RejectionTrace;
            for (var i = 0; i < rejectionRows.Count; i++)
            {
                var row = rejectionRows[i];
                if (row.TradeNumber > deepestTradeNumber) deepestTradeNumber = row.TradeNumber;
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
                hardBreakevenEpisodes++;
                hardBreakevenAttempts += row.Attempts;
            }

            return new BasketResearchRecord(
                record.Sequence,
                record.CreatedTime,
                firstEntryTime,
                record.ClosedTime,
                durationSeconds,
                legs.Count > 0 ? legs[0].Side : (TradeSide?)null,
                record.Legs,
                deepestTradeNumber,
                maxOpenPositions,
                maxGrossLots,
                maxAbsoluteNetLots,
                maxPlaced,
                activeExtrema?.MaxFloatingProfit,
                activeExtrema?.MaxFloatingLoss,
                record.Reason,
                record.RealizedProfit,
                record.HardBreakevenModeActive,
                record.HardBreakevenModeActive ? _parameters.NormalTradeCount + 1 : (int?)null,
                maxExactTail,
                maxNormalizedTail,
                maxPlacedTail,
                hardBreakevenAttempts,
                hardBreakevenEpisodes,
                SummarizeRejections(record));
        }

        private static IReadOnlyList<ResearchRejectionCount> SummarizeRejections(BasketCloseRecord record)
        {
            var rows = record.RejectionTrace;
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

        /// <summary>The running path extrema of the one basket currently open.</summary>
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
        }
    }

    /// <summary>
    /// The run-level research account values written to the results (roadmap section 3.12).
    /// The balance, equity and floating values are the current ones at the moment of the
    /// snapshot; the host takes the snapshot after the end-of-run observation, so they are the
    /// run's final values.
    /// </summary>
    public sealed record ResearchAccountSummary(
        decimal InitialBalance,
        decimal Balance,
        decimal Equity,
        decimal FloatingProfit,
        bool FloatingObservable,
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
    /// <see cref="DeepestTradeNumber"/> is the deepest trade number reached by a placed leg or a
    /// rejected attempt, so a required but infeasible tail is visible even when no leg was
    /// opened; the tail-lot maxima include the requirements of hard-BE episodes, and
    /// <see cref="HardBreakevenRejectedAttempts"/> / <see cref="HardBreakevenRejectionEpisodes"/>
    /// count the hard-BE infeasibility episodes only (an execution failure with a feasible
    /// hard-BE sizing is counted by its reason in <see cref="Rejections"/> and still contributes
    /// its requirement to the maxima).
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
        int MaxOpenPositions,
        decimal MaxGrossLots,
        decimal MaxAbsoluteNetLots,
        decimal? MaxIndividualPlacedLot,
        decimal? MaxExecutableFloatingProfit,
        decimal? MaxExecutableFloatingLoss,
        ExitReason CloseReason,
        decimal RealizedProfit,
        bool HardBreakevenModeActivated,
        int? FirstHardBreakevenTradeNumber,
        decimal? LargestExactRequiredTailLot,
        decimal? LargestNormalizedRequiredTailLot,
        decimal? LargestPlacedTailLot,
        long HardBreakevenRejectedAttempts,
        long HardBreakevenRejectionEpisodes,
        IReadOnlyList<ResearchRejectionCount> Rejections);

    /// <summary>
    /// One rejection count of a closed basket: the distinct rejection episodes and the total
    /// attempts, keyed by reason and hard-BE outcome. The distinction between an individual
    /// rejected attempt and a compact rejection episode is preserved for both totals.
    /// </summary>
    public sealed record ResearchRejectionCount(
        EntryRejectionReason Reason,
        HardBreakevenOutcome? Outcome,
        long Episodes,
        long Attempts);
}
