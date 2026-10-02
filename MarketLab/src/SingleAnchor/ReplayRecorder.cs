using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text;
using Newtonsoft.Json;
using Newtonsoft.Json.Linq;

namespace MarketLab.SingleAnchor
{
    /// <summary>
    /// Phase E recorder: observes the engine's authoritative events and the research account's
    /// authoritative observations and emits the deterministic MarketLab replay package (see
    /// <see cref="ReplayPackage"/>). It owns no strategy state and makes no decision: every method
    /// delegates to the wrapped <see cref="SingleAnchorResearchAccount"/> first, so the account's
    /// values and the engine's decision path are exactly what they are without the recorder. The
    /// recorder only reads them and writes text.
    /// </summary>
    /// <remarks>
    /// The engine is constructed with this instance as its <see cref="IResearchObserver"/> when a
    /// research account exists; the account itself remains the engine's risk guard. All engine
    /// events the host already handles are forwarded to the matching <c>On*</c> method. The
    /// recorder keeps O(1) per-quote work: a pending-snapshot flush, one margin-call boolean
    /// comparison and one simulated-time comparison; strings are built only at events and at the
    /// bounded periodic sampling points.
    /// </remarks>
    public sealed class ReplayRecorder : IResearchObserver
    {
        private readonly SingleAnchorResearchAccount _account;
        private readonly bool _marginEnabled;
        private readonly Func<long> _quoteSequence;
        private readonly StringBuilder _events = new StringBuilder(64 * 1024);
        private readonly SortedDictionary<int, StringBuilder> _telemetry = new SortedDictionary<int, StringBuilder>();
        private readonly SortedDictionary<string, int> _eventCounts = new SortedDictionary<string, int>(StringComparer.Ordinal);

        private bool _faulted;
        private string? _faultMessage;
        private ReplayPackageMetadata? _metadata;
        private ReplayPackageResult? _result;
        private long _eventId;
        private long _pendingEventId;
        private bool _marginCallActive;
        private Quote? _pendingCloseQuote;
        private DateTime? _nextPeriodicSample;
        private int _eventSnapshots;
        private int _periodicSamples;

        /// <summary>
        /// Creates a recorder for the account the engine will observe. <paramref name="quoteSequence"/>
        /// returns the engine's current 1-based processed-quote number; it is called on the observer
        /// path only, after the engine has already counted the quote.
        /// </summary>
        public ReplayRecorder(SingleAnchorResearchAccount account, bool marginEnabled, Func<long> quoteSequence)
        {
            _account = account ?? throw new ArgumentNullException(nameof(account));
            _marginEnabled = marginEnabled;
            _quoteSequence = quoteSequence ?? throw new ArgumentNullException(nameof(quoteSequence));
        }

        /// <summary>True once <see cref="Start"/> emitted the run-start identity.</summary>
        public bool Started => _metadata != null;

        /// <summary>
        /// Emits the run-start identity and its exact initial account snapshot. Called once by the
        /// host after the engine and its events are wired; the values are the frozen run inputs, not
        /// a clock reading.
        /// </summary>
        public void Start(ReplayPackageMetadata metadata)
        {
            if (_metadata != null)
            {
                throw new InvalidOperationException("The replay recorder was already started.");
            }
            _metadata = metadata ?? throw new ArgumentNullException(nameof(metadata));
            var line = new JsonLine();
            line.Text("type", "run_started");
            line.Time("time", metadata.StartUtc);
            line.Text("modelRevision", metadata.ModelRevision);
            line.Text("stopOutModel", metadata.StopOutModel);
            line.Text("symbol", metadata.Symbol);
            line.Text("market", metadata.Market);
            line.Text("startDate", metadata.StartDate);
            line.Text("endDate", metadata.EndDate);
            line.Text("quoteTimeZone", metadata.QuoteTimeZone);
            var id = AddEvent("run_started", line.ToLine());
            AddSnapshot("event", id, metadata.StartUtc, 0);
        }

        // ---- IResearchObserver: delegate to the account first, then record ----

        /// <inheritdoc />
        public void ObserveQuote(in Quote quote, Basket? basket, decimal realizedProfit, decimal? rawProfit)
        {
            // The authoritative account observation is never inside the recorder's fault guard:
            // an account fault must keep propagating exactly as it did before Phase E.
            _account.ObserveQuote(quote, basket, realizedProfit, rawProfit);
            if (_faulted)
            {
                return;
            }
            try
            {
                RecordQuoteObservation(quote);
            }
            catch (Exception error)
            {
                Fault(error);
            }
        }

        /// <inheritdoc />
        public void ObserveClose(BasketCloseRecord record, decimal realizedProfit)
        {
            _account.ObserveClose(record, realizedProfit);
            if (_faulted || !_marginEnabled)
            {
                return;
            }
            // The close observations can move the account out of Margin Call. That transition is
            // published after the basket-close event (the event is the causal actor), not between
            // the account update and the event; the pending quote is flushed by the close event
            // handler, by the next observation, or by the package build.
            _pendingCloseQuote = new Quote(record.ClosedTime, record.CloseBid, record.CloseAsk);
        }

        /// <inheritdoc />
        public void ObserveForcedLiquidation(in Quote quote, LiquidatedLegRecord leg, decimal realizedProfit, Basket? basket)
        {
            var before = TryCaptureAccount();
            _account.ObserveForcedLiquidation(quote, leg, realizedProfit, basket);
            var after = TryCaptureAccount();
            if (before == null || after == null || _faulted)
            {
                return;
            }
            try
            {
                var id = AddForcedLiquidationEvent(leg, quote, before.Value, after.Value);
                AddSnapshot("event", id, quote.Time, _quoteSequence());
                // The forced close can restore the account outside Margin Call; publish that
                // transition on the liquidation quote.
                ReconcileMarginCall(quote);
            }
            catch (Exception error)
            {
                Fault(error);
            }
        }

        private ReplayAccountSnapshot? TryCaptureAccount()
        {
            try
            {
                return CaptureAccount();
            }
            catch (Exception error)
            {
                Fault(error);
                return null;
            }
        }

        private void FlushPendingCloseMarginCall()
        {
            if (!_pendingCloseQuote.HasValue)
            {
                return;
            }
            var quote = _pendingCloseQuote.Value;
            _pendingCloseQuote = null;
            ReconcileMarginCall(quote);
        }

        /// <summary>
        /// Reconciles the recorder's tracked Margin Call state with the account after the host's
        /// explicit end-of-run observation (which the algorithm applies to the account directly).
        /// </summary>
        public void OnEndOfRunObserved(in Quote quote)
        {
            if (_faulted || !_marginEnabled)
            {
                return;
            }
            try
            {
                ReconcileMarginCall(quote);
            }
            catch (Exception error)
            {
                Fault(error);
            }
        }

        private void RecordQuoteObservation(in Quote quote)
        {
            // A close event always follows ObserveClose on the same quote; this is only a
            // defensive flush if a host ever observes a close without publishing it.
            FlushPendingCloseMarginCall();
            if (_pendingEventId != 0)
            {
                AddSnapshot("event", _pendingEventId, quote.Time, _quoteSequence());
                _pendingEventId = 0;
            }

            if (_marginEnabled)
            {
                ReconcileMarginCall(quote);
            }

            var open = _account.CurrentOpenPositions > 0;
            if (!open)
            {
                _nextPeriodicSample = null;
                return;
            }
            if (!_nextPeriodicSample.HasValue || quote.Time >= _nextPeriodicSample.Value)
            {
                AddSnapshot("periodic", null, quote.Time, _quoteSequence());
                _nextPeriodicSample = quote.Time.AddSeconds(ReplayPackage.TelemetryIntervalSeconds);
            }
        }

        private void ReconcileMarginCall(in Quote quote)
        {
            var active = _account.MarginCallActive;
            if (active == _marginCallActive)
            {
                return;
            }
            _marginCallActive = active;
            var id = AddMarginCallEvent(active, quote);
            AddSnapshot("event", id, quote.Time, _quoteSequence());
        }

        /// <summary>
        /// Records that the recorder itself failed. The engine and the account keep running; the
        /// package build then refuses to emit an incomplete package, so the failure cannot be
        /// mistaken for a successful export. Never called for an account fault.
        /// </summary>
        private void Fault(Exception error)
        {
            if (!_faulted)
            {
                _faulted = true;
                _faultMessage = error.GetType().Name + ": " + error.Message;
            }
        }

        // ---- Engine events, in the engine's exact occurrence order ----
        //
        // Every handler is fault-guarded: a recorder defect must never abort the authoritative
        // run or change its outcome. A fault refuses the package build instead (see Fault/BuildPackage).

        /// <summary>A new basket was anchored; its account snapshot is taken on the observation that immediately follows.</summary>
        public void OnAnchorCreated(AnchorCreatedEvent e)
        {
            if (_faulted) return;
            try
            {
                _pendingEventId = AddAnchorEvent(e);
            }
            catch (Exception error)
            {
                Fault(error);
            }
        }

        /// <summary>A still-empty basket could not start on this ambiguous quote.</summary>
        public void OnFirstEntrySkipped(FirstEntrySkippedEvent e)
        {
            if (_faulted) return;
            try
            {
                var id = AddFirstEntrySkippedEvent(e);
                AddSnapshot("event", id, e.Quote.Time, _quoteSequence());
            }
            catch (Exception error)
            {
                Fault(error);
            }
        }

        /// <summary>A leg was filled. A hard-BE mode change is published before the entry it enabled.</summary>
        public void OnEntryOpened(EntryOpenedEvent e)
        {
            if (_faulted) return;
            try
            {
                var id = AddEntryEvent(e);
                AddSnapshot("event", id, e.Quote.Time, _quoteSequence());
            }
            catch (Exception error)
            {
                Fault(error);
            }
        }

        /// <summary>A distinct rejected-entry episode started. Hard-BE activation is published first when this attempt activated it.</summary>
        public void OnEntryRejected(EntryRejectedEvent e)
        {
            if (_faulted) return;
            try
            {
                var id = AddEntryRejectedEvent(e);
                AddSnapshot("event", id, e.Quote.Time, _quoteSequence());
            }
            catch (Exception error)
            {
                Fault(error);
            }
        }

        /// <summary>The post-fill hard-BE verification failed; the engine publishes this immediately before it stops.</summary>
        public void OnHardBreakevenViolated(HardBreakevenViolatedEvent e)
        {
            if (_faulted) return;
            try
            {
                var id = AddHardBreakevenViolatedEvent(e);
                AddSnapshot("event", id, e.Quote.Time, _quoteSequence());
            }
            catch (Exception error)
            {
                Fault(error);
            }
        }

        /// <summary>
        /// The basket entered hard-BE mode at the first tail attempt. The engine publishes this
        /// before sizing/placing that attempt, so the snapshot is the exact pre-attempt state.
        /// </summary>
        public void OnHardBreakevenActivated(HardBreakevenActivatedEvent e)
        {
            if (_faulted) return;
            try
            {
                var line = new JsonLine();
                line.Text("type", "hard_breakeven_activated");
                line.Number("basket", e.Basket.Sequence);
                line.Number("tradeNumber", e.TradeNumber);
                line.Time("time", e.Quote.Time);
                line.Number("quoteSequence", _quoteSequence());
                line.Text("lowerTarget", ReplayPackage.FormatDecimal(e.Basket.LowerTarget));
                line.Text("upperTarget", ReplayPackage.FormatDecimal(e.Basket.UpperTarget));
                var id = AddEvent("hard_breakeven_activated", line.ToLine());
                AddSnapshot("event", id, e.Quote.Time, _quoteSequence());
            }
            catch (Exception error)
            {
                Fault(error);
            }
        }

        /// <summary>Trailing activated for the basket.</summary>
        public void OnTrailingActivated(TrailingActivatedEvent e)
        {
            if (_faulted) return;
            try
            {
                var id = AddTrailingActivatedEvent(e);
                AddSnapshot("event", id, e.Quote.Time, _quoteSequence());
            }
            catch (Exception error)
            {
                Fault(error);
            }
        }

        /// <summary>The basket closed through a strategy exit.</summary>
        public void OnBasketClosed(BasketClosedEvent e)
        {
            if (_faulted) return;
            try
            {
                var id = AddCloseEvent("strategy_exit", e.Record, e.Quote);
                AddSnapshot("event", id, e.Quote.Time, _quoteSequence());
                FlushPendingCloseMarginCall();
            }
            catch (Exception error)
            {
                Fault(error);
            }
        }

        /// <summary>The executor could not close the basket; it stays open.</summary>
        public void OnBasketCloseFailed(BasketCloseFailedEvent e)
        {
            if (_faulted) return;
            try
            {
                var id = AddBasketCloseFailedEvent(e);
                AddSnapshot("event", id, e.Quote.Time, _quoteSequence());
            }
            catch (Exception error)
            {
                Fault(error);
            }
        }

        /// <summary>The account entered Stop Out; deterministic broker liquidation begins.</summary>
        public void OnStopOutTriggered(StopOutTriggeredEvent e)
        {
            if (_faulted) return;
            try
            {
                var id = AddStopOutEvent(e);
                AddSnapshot("event", id, e.Quote.Time, _quoteSequence());
            }
            catch (Exception error)
            {
                Fault(error);
            }
        }

        /// <summary>Every remaining position was removed by broker liquidation.</summary>
        public void OnBasketLiquidated(BasketLiquidatedEvent e)
        {
            if (_faulted) return;
            try
            {
                var id = AddCloseEvent("basket_liquidated", e.Record, e.Quote);
                AddSnapshot("event", id, e.Quote.Time, _quoteSequence());
                FlushPendingCloseMarginCall();
            }
            catch (Exception error)
            {
                Fault(error);
            }
        }

        // ---- Package build ----

        /// <summary>
        /// Finalizes the run: emits the rejection recaps and the <c>run_ended</c> identity with its
        /// exact final account snapshot, then hashes the payload files and builds the manifest.
        /// Idempotent: a second call returns the first result.
        /// </summary>
        public ReplayPackageResult BuildPackage(ReplayRunEnd runEnd)
        {
            if (runEnd == null) throw new ArgumentNullException(nameof(runEnd));
            if (_result != null)
            {
                return _result;
            }
            var metadata = _metadata ?? throw new InvalidOperationException("The replay recorder was not started.");
            if (_faulted)
            {
                // An incomplete package is worse than no package: the evidence chain must be able
                // to tell a recorder failure apart from a successful export.
                throw new InvalidOperationException($"The replay recorder faulted during the run and no package was emitted: {_faultMessage}");
            }
            FlushPendingCloseMarginCall();

            foreach (var rejection in runEnd.Rejections)
            {
                AddRejectionSummary(rejection);
            }

            // The run-end event time must never go backwards: a rejected quote can precede the last
            // accepted one (out-of-order/session-map faults), so it only moves the time forward.
            var endTime = runEnd.LastProcessedQuoteTime ?? metadata.EndUtc;
            if (runEnd.FailureQuote.HasValue && runEnd.FailureQuote.Value.Time > endTime)
            {
                endTime = runEnd.FailureQuote.Value.Time;
            }
            var endId = AddRunEndedEvent(runEnd, endTime);
            AddSnapshot("event", endId, endTime, runEnd.QuoteTicksProcessed);

            var payload = new List<ReplayPackageFile>();
            var eventsContent = _events.ToString();
            payload.Add(File(ReplayPackage.EventsFile, null, eventsContent));
            foreach (var pair in _telemetry)
            {
                var content = pair.Value.ToString();
                payload.Add(File(ReplayPackage.TelemetryFile(pair.Key), pair.Key, content));
            }

            var fingerprints = new StringBuilder();
            foreach (var file in payload)
            {
                fingerprints.Append(file.Name).Append('\n').Append(file.Sha256).Append('\n').Append(file.Bytes).Append('\n');
            }
            var packageSha256 = ReplayPackage.Sha256Hex(fingerprints.ToString());

            var manifest = BuildManifest(metadata, runEnd, packageSha256, payload);
            // Normalize the indented body to LF so the manifest bytes are deterministic across
            // platforms, exactly like the payload files (which are always '\n'-terminated).
            var manifestContent = manifest.ToString(Formatting.Indented).Replace("\r\n", "\n") + "\n";
            var manifestFile = new ReplayPackageFile(
                ReplayPackage.Directory + "/" + ReplayPackage.ManifestFile,
                ReplayPackage.ManifestFile,
                null,
                manifestContent,
                ReplayPackage.Sha256Hex(manifestContent),
                Encoding.UTF8.GetByteCount(manifestContent),
                ReplayPackage.CountLines(manifestContent));

            var files = new List<ReplayPackageFile>(payload.Count + 1);
            files.AddRange(payload);
            files.Add(manifestFile);

            return _result = new ReplayPackageResult(
                files,
                manifestContent,
                packageSha256,
                TotalEventCount(),
                _eventSnapshots,
                _periodicSamples);
        }

        // ---- Event payloads ----

        private long AddAnchorEvent(AnchorCreatedEvent e)
        {
            var anchor = e.Basket.AnchorEvent;
            var line = new JsonLine();
            line.Text("type", "basket_anchored");
            line.Number("basket", anchor.Basket);
            line.Number("quoteSequence", anchor.QuoteSequence);
            line.Time("time", anchor.Time);
            line.Text("bid", ReplayPackage.FormatDecimal(anchor.Bid));
            line.Text("ask", ReplayPackage.FormatDecimal(anchor.Ask));
            line.Text("anchor", ReplayPackage.FormatDecimal(anchor.Anchor));
            line.Text("step", ReplayPackage.FormatDecimal(anchor.Step));
            line.Text("upper", ReplayPackage.FormatDecimal(anchor.Upper));
            line.Text("lower", ReplayPackage.FormatDecimal(anchor.Lower));
            line.Text("lowerTarget", ReplayPackage.FormatDecimal(anchor.LowerTarget));
            line.Text("upperTarget", ReplayPackage.FormatDecimal(anchor.UpperTarget));
            return AddEvent("basket_anchored", line.ToLine());
        }

        private long AddEntryEvent(EntryOpenedEvent e)
        {
            var leg = e.Leg;
            var line = new JsonLine();
            line.Text("type", "entry_executed");
            line.Number("basket", e.Basket.Sequence);
            line.Number("tradeNumber", leg.TradeNumber);
            line.Number("quoteSequence", leg.QuoteSequence);
            line.Time("time", leg.EntryTime);
            line.Text("decisionBid", ReplayPackage.FormatDecimal(leg.TriggerQuote.Bid));
            line.Text("decisionAsk", ReplayPackage.FormatDecimal(leg.TriggerQuote.Ask));
            line.Text("side", leg.Side.ToString());
            line.Text("placedLot", ReplayPackage.FormatDecimal(leg.Lots));
            line.Text("fillPrice", ReplayPackage.FormatDecimal(leg.EntryPrice));
            line.Text("regime", leg.Regime.ToString());
            line.NullableDecimal("rawRequestedLot", leg.RawRequestedLots);
            if (e.Sizing.HasValue)
            {
                var sizing = e.Sizing.Value;
                line.NullableDecimal("exactRequiredLot", sizing.ExactRequired);
                line.Text("normalizedRequiredLot", ReplayPackage.FormatDecimal(sizing.NormalizedRequiredLot));
                line.Text("hardBreakevenTarget", ReplayPackage.FormatDecimal(sizing.Target.Target));
                line.Text("targetSpread", ReplayPackage.FormatDecimal(sizing.Target.Spread));
                line.Text("targetBid", ReplayPackage.FormatDecimal(sizing.Target.Bid));
                line.Text("targetAsk", ReplayPackage.FormatDecimal(sizing.Target.Ask));
                line.Text("existingProfitAtTarget", ReplayPackage.FormatDecimal(sizing.ExistingProfitAtTarget));
                line.Text("marginalProfitPerLot", ReplayPackage.FormatDecimal(sizing.MarginalProfitPerLot));
                line.Text("projectedProfitAfter", ReplayPackage.FormatDecimal(sizing.ProjectedProfitAfter));
                line.Text("sizingOutcome", sizing.Outcome.ToString());
            }
            else
            {
                line.Null("exactRequiredLot");
                line.Text("normalizedRequiredLot", ReplayPackage.FormatDecimal(leg.Lots));
                line.Null("hardBreakevenTarget");
                line.Null("targetSpread");
                line.Null("targetBid");
                line.Null("targetAsk");
                line.Null("existingProfitAtTarget");
                line.Null("marginalProfitPerLot");
                line.Null("projectedProfitAfter");
                line.Null("sizingOutcome");
            }
            return AddEvent("entry_executed", line.ToLine());
        }

        private long AddEntryRejectedEvent(EntryRejectedEvent e)
        {
            var rejection = e.Rejection;
            var line = new JsonLine();
            line.Text("type", "entry_rejected");
            line.Number("basket", e.Basket.Sequence);
            line.Number("tradeNumber", rejection.TradeNumber);
            line.Text("side", rejection.Side.ToString());
            line.Text("reason", rejection.Reason.ToString());
            line.Number("quoteSequence", _quoteSequence());
            line.Time("time", e.Quote.Time);
            line.Text("bid", ReplayPackage.FormatDecimal(e.Quote.Bid));
            line.Text("ask", ReplayPackage.FormatDecimal(e.Quote.Ask));
            line.NullableDecimal("rawRequestedLots", rejection.RawRequestedLots);
            line.NullableDecimal("exactRequiredLots", rejection.ExactRequiredLots);
            line.Text("normalizedRequiredLots", ReplayPackage.FormatDecimal(rejection.NormalizedRequiredLots));
            line.NullableDecimal("maximumVolume", rejection.MaximumVolume);
            if (rejection.Sizing.HasValue)
            {
                var sizing = rejection.Sizing.Value;
                line.Text("hardBreakevenTarget", ReplayPackage.FormatDecimal(sizing.Target.Target));
                line.Text("targetSpread", ReplayPackage.FormatDecimal(sizing.Target.Spread));
                line.Text("targetBid", ReplayPackage.FormatDecimal(sizing.Target.Bid));
                line.Text("targetAsk", ReplayPackage.FormatDecimal(sizing.Target.Ask));
                line.Text("existingProfitAtTarget", ReplayPackage.FormatDecimal(sizing.ExistingProfitAtTarget));
                line.Text("marginalProfitPerLot", ReplayPackage.FormatDecimal(sizing.MarginalProfitPerLot));
                line.Text("projectedProfitAfter", ReplayPackage.FormatDecimal(sizing.ProjectedProfitAfter));
                line.Text("sizingOutcome", sizing.Outcome.ToString());
            }
            else
            {
                line.Null("hardBreakevenTarget");
                line.Null("targetSpread");
                line.Null("targetBid");
                line.Null("targetAsk");
                line.Null("existingProfitAtTarget");
                line.Null("marginalProfitPerLot");
                line.Null("projectedProfitAfter");
                line.Null("sizingOutcome");
            }
            line.NullableDecimal("accountUsedMargin", rejection.AccountUsedMargin);
            line.NullableDecimal("accountFreeMargin", rejection.AccountFreeMargin);
            line.NullableDecimal("accountMarginLevelPercent", rejection.AccountMarginLevelPercent);
            line.NullableDecimal("projectedUsedMargin", rejection.ProjectedUsedMargin);
            line.NullableDecimal("projectedFreeMargin", rejection.ProjectedFreeMargin);
            line.Text("message", rejection.Message);
            return AddEvent("entry_rejected", line.ToLine());
        }

        /// <summary>
        /// A run-end recap of a compressed rejection episode. It deliberately carries no
        /// eventId-correlated telemetry snapshot: its account state is historical, not current at
        /// build time; the live <c>entry_rejected</c> event of the episode carries the snapshot.
        /// </summary>
        private void AddRejectionSummary(EntryRejectionRecord record)
        {
            var line = new JsonLine();
            line.Text("type", "entry_rejection_summary");
            line.Number("basket", record.Basket);
            line.Number("tradeNumber", record.TradeNumber);
            line.Text("side", record.Side.ToString());
            line.Text("reason", record.Reason.ToString());
            line.NullableEnum("outcome", record.Outcome);
            line.Number("attempts", record.Attempts);
            line.Number("firstQuoteSequence", record.FirstQuoteSequence);
            line.Time("firstTime", record.FirstTime);
            line.Text("firstBid", ReplayPackage.FormatDecimal(record.FirstBid));
            line.Text("firstAsk", ReplayPackage.FormatDecimal(record.FirstAsk));
            line.Number("lastQuoteSequence", record.LastQuoteSequence);
            line.Time("lastTime", record.LastTime);
            line.Text("lastBid", ReplayPackage.FormatDecimal(record.LastBid));
            line.Text("lastAsk", ReplayPackage.FormatDecimal(record.LastAsk));
            line.Text("parityAlgorithm", record.ParityAlgorithm);
            line.Text("parityHash", record.ParityHash);
            line.NullableDecimal("minNormalizedRequiredLots", record.MinNormalizedRequiredLots);
            line.NullableDecimal("maxNormalizedRequiredLots", record.MaxNormalizedRequiredLots);
            line.NullableDecimal("minProjectedFreeMargin", record.MinProjectedFreeMargin);
            line.NullableDecimal("maxProjectedFreeMargin", record.MaxProjectedFreeMargin);
            line.Text("message", record.Message);
            AddEvent("entry_rejection_summary", line.ToLine());
        }

        private long AddFirstEntrySkippedEvent(FirstEntrySkippedEvent e)
        {
            var record = e.Record;
            var line = new JsonLine();
            line.Text("type", "first_entry_skipped");
            line.Number("basket", record.Basket);
            line.Number("quoteSequence", record.FirstQuoteSequence);
            line.Time("time", record.FirstTime);
            line.Text("bid", ReplayPackage.FormatDecimal(record.FirstBid));
            line.Text("ask", ReplayPackage.FormatDecimal(record.FirstAsk));
            line.Text("spread", ReplayPackage.FormatDecimal(e.Quote.Spread));
            line.Number("attempts", record.Attempts);
            return AddEvent("first_entry_skipped", line.ToLine());
        }

        private long AddTrailingActivatedEvent(TrailingActivatedEvent e)
        {
            var line = new JsonLine();
            line.Text("type", "trailing_activated");
            line.Number("basket", e.Basket.Sequence);
            line.Number("quoteSequence", _quoteSequence());
            line.Time("time", e.Quote.Time);
            line.Text("bid", ReplayPackage.FormatDecimal(e.Quote.Bid));
            line.Text("ask", ReplayPackage.FormatDecimal(e.Quote.Ask));
            line.Text("profit", ReplayPackage.FormatDecimal(e.Profit));
            line.Text("activationThreshold", ReplayPackage.FormatDecimal(e.ActivationThreshold));
            return AddEvent("trailing_activated", line.ToLine());
        }

        private long AddStopOutEvent(StopOutTriggeredEvent e)
        {
            var stopOut = e.StopOut;
            var line = new JsonLine();
            line.Text("type", "stop_out_triggered");
            line.Number("basket", e.Basket.Sequence);
            line.Text("reason", stopOut.Reason.ToString());
            line.Number("quoteSequence", _quoteSequence());
            line.Time("time", stopOut.Time);
            line.Text("bid", ReplayPackage.FormatDecimal(e.Quote.Bid));
            line.Text("ask", ReplayPackage.FormatDecimal(e.Quote.Ask));
            line.Text("balance", ReplayPackage.FormatDecimal(stopOut.Balance));
            line.Text("floatingProfit", ReplayPackage.FormatDecimal(stopOut.FloatingProfit));
            line.Text("equity", ReplayPackage.FormatDecimal(stopOut.Equity));
            line.Text("usedMargin", ReplayPackage.FormatDecimal(stopOut.UsedMargin));
            line.Text("freeMargin", ReplayPackage.FormatDecimal(stopOut.FreeMargin));
            line.NullableDecimal("marginLevelPercent", stopOut.MarginLevelPercent);
            line.Number("openPositions", stopOut.OpenPositions);
            return AddEvent("stop_out_triggered", line.ToLine());
        }

        private long AddForcedLiquidationEvent(LiquidatedLegRecord leg, in Quote quote, ReplayAccountSnapshot before, ReplayAccountSnapshot after)
        {
            var line = new JsonLine();
            line.Text("type", "forced_liquidation");
            line.Time("time", leg.LiquidationTime);
            line.Number("basket", leg.Basket);
            line.Number("ordinal", leg.Ordinal);
            line.Number("tradeNumber", leg.TradeNumber);
            line.Text("side", leg.Side.ToString());
            line.Text("placedLot", ReplayPackage.FormatDecimal(leg.PlacedLot));
            line.Text("entryPrice", ReplayPackage.FormatDecimal(leg.EntryPrice));
            line.Time("entryTime", leg.EntryTime);
            line.Text("regime", leg.Regime.ToString());
            line.NullableDecimal("rawRequestedLot", leg.RawRequestedLot);
            line.NullableDecimal("exactRequiredLot", leg.ExactRequiredLot);
            line.Text("normalizedRequiredLot", ReplayPackage.FormatDecimal(leg.NormalizedRequiredLot));
            line.Time("liquidationTime", leg.LiquidationTime);
            line.Time("triggerTime", leg.TriggerTime);
            line.Number("triggerQuoteSequence", leg.TriggerQuoteSequence);
            line.Text("triggerBid", ReplayPackage.FormatDecimal(leg.TriggerBid));
            line.Text("triggerAsk", ReplayPackage.FormatDecimal(leg.TriggerAsk));
            line.Text("closePrice", ReplayPackage.FormatDecimal(leg.ClosePrice));
            line.Text("commission", ReplayPackage.FormatDecimal(leg.Commission));
            line.Text("realizedProfit", ReplayPackage.FormatDecimal(leg.RealizedProfit));
            line.Text("reason", leg.Reason.ToString());
            line.Snapshot("before", before);
            line.Snapshot("after", after);
            return AddEvent("forced_liquidation", line.ToLine());
        }

        private long AddCloseEvent(string type, BasketCloseRecord record, in Quote quote)
        {
            var line = new JsonLine();
            line.Text("type", type);
            line.Number("basket", record.Sequence);
            line.Text("reason", record.Reason.ToString());
            line.Number("quoteSequence", record.CloseQuoteSequence);
            line.Time("time", record.ClosedTime);
            line.Text("bid", ReplayPackage.FormatDecimal(record.CloseBid));
            line.Text("ask", ReplayPackage.FormatDecimal(record.CloseAsk));
            line.Text("anchor", ReplayPackage.FormatDecimal(record.Anchor));
            line.Number("legs", record.Legs);
            line.Text("buyLots", ReplayPackage.FormatDecimal(record.BuyLots));
            line.Text("sellLots", ReplayPackage.FormatDecimal(record.SellLots));
            line.Text("grossLots", ReplayPackage.FormatDecimal(record.GrossLots));
            line.Text("netLots", ReplayPackage.FormatDecimal(record.NetLots));
            line.Bool("hardBreakevenModeActive", record.HardBreakevenModeActive);
            line.Text("rawProfit", ReplayPackage.FormatDecimal(record.RawProfit));
            line.Text("exitProfit", ReplayPackage.FormatDecimal(record.ExitProfit));
            line.Text("threshold", ReplayPackage.FormatDecimal(record.Threshold));
            line.Text("buyClosePrice", ReplayPackage.FormatDecimal(record.BuyClosePrice));
            line.Text("sellClosePrice", ReplayPackage.FormatDecimal(record.SellClosePrice));
            line.Text("commission", ReplayPackage.FormatDecimal(record.Commission));
            line.Text("realizedProfit", ReplayPackage.FormatDecimal(record.RealizedProfit));
            line.Text("liquidatedRealizedProfit", ReplayPackage.FormatDecimal(record.LiquidatedRealizedProfit));
            line.Number("liquidatedPositions", record.LiquidatedPositions);
            line.Number("historicalEntries", record.HistoricalEntries);
            return AddEvent(type, line.ToLine());
        }

        private long AddBasketCloseFailedEvent(BasketCloseFailedEvent e)
        {
            var line = new JsonLine();
            line.Text("type", "basket_close_failed");
            line.Number("basket", e.Basket.Sequence);
            line.Text("reason", e.Reason.ToString());
            line.Number("quoteSequence", _quoteSequence());
            line.Time("time", e.Quote.Time);
            line.Text("bid", ReplayPackage.FormatDecimal(e.Quote.Bid));
            line.Text("ask", ReplayPackage.FormatDecimal(e.Quote.Ask));
            line.Text("message", e.Message);
            return AddEvent("basket_close_failed", line.ToLine());
        }

        private long AddHardBreakevenViolatedEvent(HardBreakevenViolatedEvent e)
        {
            var line = new JsonLine();
            line.Text("type", "hard_breakeven_violated");
            line.Number("basket", e.Basket.Sequence);
            line.Number("tradeNumber", e.Leg.TradeNumber);
            line.Text("side", e.Leg.Side.ToString());
            line.Number("quoteSequence", _quoteSequence());
            line.Time("time", e.Quote.Time);
            line.Text("bid", ReplayPackage.FormatDecimal(e.Quote.Bid));
            line.Text("ask", ReplayPackage.FormatDecimal(e.Quote.Ask));
            line.Text("placedLot", ReplayPackage.FormatDecimal(e.Leg.Lots));
            line.Text("fillPrice", ReplayPackage.FormatDecimal(e.Leg.EntryPrice));
            line.Text("hardBreakevenTarget", ReplayPackage.FormatDecimal(e.Sizing.Target.Target));
            line.Text("projectedProfitAfterFill", ReplayPackage.FormatDecimal(e.ProjectedProfitAfterFill));
            line.Text("sizingProjectedProfitAfter", ReplayPackage.FormatDecimal(e.Sizing.ProjectedProfitAfter));
            line.Text("message", e.Sizing.Message);
            return AddEvent("hard_breakeven_violated", line.ToLine());
        }

        private long AddMarginCallEvent(bool active, in Quote quote)
        {
            var snapshot = CaptureAccount();
            var line = new JsonLine();
            line.Text("type", active ? "margin_call_entered" : "margin_call_left");
            line.Number("quoteSequence", _quoteSequence());
            line.Time("time", quote.Time);
            line.Text("bid", ReplayPackage.FormatDecimal(quote.Bid));
            line.Text("ask", ReplayPackage.FormatDecimal(quote.Ask));
            line.Text("balance", ReplayPackage.FormatDecimal(snapshot.Balance));
            line.Text("equity", ReplayPackage.FormatDecimal(snapshot.Equity));
            line.Text("usedMargin", ReplayPackage.FormatDecimal(snapshot.UsedMargin));
            line.NullableDecimal("freeMargin", snapshot.FreeMargin);
            line.NullableDecimal("marginLevelPercent", snapshot.MarginLevelPercent);
            line.Number("openPositions", snapshot.OpenPositions);
            return AddEvent(active ? "margin_call_entered" : "margin_call_left", line.ToLine());
        }

        private long AddRunEndedEvent(ReplayRunEnd runEnd, DateTime time)
        {
            var line = new JsonLine();
            line.Text("type", "run_ended");
            line.Time("time", time);
            line.Bool("completed", runEnd.Completed);
            line.NullableText("failureKind", runEnd.FailureKind);
            line.NullableText("failureCondition", runEnd.FailureCondition);
            line.NullableText("failureMessage", runEnd.FailureMessage);
            if (runEnd.FailureQuote.HasValue)
            {
                line.Time("failureQuoteTime", runEnd.FailureQuote.Value.Time);
                line.Text("failureBid", ReplayPackage.FormatDecimal(runEnd.FailureQuote.Value.Bid));
                line.Text("failureAsk", ReplayPackage.FormatDecimal(runEnd.FailureQuote.Value.Ask));
            }
            else
            {
                line.Null("failureQuoteTime");
                line.Null("failureBid");
                line.Null("failureAsk");
            }
            line.Number("quoteTicksProcessed", runEnd.QuoteTicksProcessed);
            line.Number("quoteOnlyQuotes", runEnd.QuoteOnlyQuotes);
            line.Number("strategyEligibleQuotes", runEnd.StrategyEligibleQuotes);
            line.Number("legsOpened", runEnd.LegsOpened);
            line.Number("basketsClosed", runEnd.BasketsClosed);
            line.Number("basketsLiquidated", runEnd.BasketsLiquidated);
            line.Number("forcedLiquidations", runEnd.ForcedLiquidations);
            line.Number("distinctRejectedEntries", runEnd.DistinctRejectedEntries);
            line.Number("rejectedEntryAttempts", runEnd.RejectedEntryAttempts);
            line.Number("skippedFirstEntryQuotes", runEnd.SkippedFirstEntryQuotes);
            line.Text("engineRealizedProfit", ReplayPackage.FormatDecimal(runEnd.EngineRealizedProfit));
            if (runEnd.Delivery != null)
            {
                line.Number("deliveryQuoteCount", runEnd.Delivery.QuoteCount);
                line.Text("deliverySemanticDigest", runEnd.Delivery.SemanticDigest);
                line.NullableText("deliveryFirstUtc", runEnd.Delivery.FirstCanonicalUtc);
                line.NullableText("deliveryLastUtc", runEnd.Delivery.LastCanonicalUtc);
            }
            else
            {
                line.Null("deliveryQuoteCount");
                line.Null("deliverySemanticDigest");
                line.Null("deliveryFirstUtc");
                line.Null("deliveryLastUtc");
            }
            return AddEvent("run_ended", line.ToLine());
        }

        // ---- Telemetry ----

        private void AddSnapshot(string kind, long? eventId, DateTime time, long quoteSequence)
        {
            var snapshot = CaptureAccount();
            var year = time.Year;
            if (!_telemetry.TryGetValue(year, out var shard))
            {
                shard = new StringBuilder(Math.Max(1024, _telemetry.Count == 0 ? 256 * 1024 : 32 * 1024));
                _telemetry[year] = shard;
            }
            var line = new JsonLine();
            line.Text("kind", kind);
            line.NullableNumber("eventId", eventId);
            line.Time("time", time);
            line.Number("quoteSequence", quoteSequence);
            line.Text("balance", ReplayPackage.FormatDecimal(snapshot.Balance));
            line.Text("equity", ReplayPackage.FormatDecimal(snapshot.Equity));
            line.Text("floatingProfit", ReplayPackage.FormatDecimal(snapshot.FloatingProfit));
            line.Bool("floatingObservable", snapshot.FloatingObservable);
            line.Text("realizedProfit", ReplayPackage.FormatDecimal(snapshot.RealizedProfit));
            line.Text("usedMargin", ReplayPackage.FormatDecimal(snapshot.UsedMargin));
            line.NullableDecimal("freeMargin", snapshot.FreeMargin);
            line.NullableDecimal("marginLevelPercent", snapshot.MarginLevelPercent);
            line.Bool("marginCallActive", snapshot.MarginCallActive);
            line.Number("openPositions", snapshot.OpenPositions);
            line.Text("grossLots", ReplayPackage.FormatDecimal(snapshot.GrossLots));
            line.Text("absoluteNetLots", ReplayPackage.FormatDecimal(snapshot.AbsoluteNetLots));
            shard.Append(line.ToLine()).Append('\n');
            if (kind == "periodic")
            {
                _periodicSamples++;
            }
            else
            {
                _eventSnapshots++;
            }
        }

        private ReplayAccountSnapshot CaptureAccount()
        {
            return new ReplayAccountSnapshot(
                _account.Balance,
                _account.Equity,
                _account.FloatingProfit,
                _account.FloatingObservable,
                _account.RealizedProfit,
                _account.CurrentUsedMargin,
                _account.CurrentFreeMargin,
                _account.CurrentMarginLevelPercent,
                _marginEnabled && _account.MarginCallActive,
                _account.CurrentOpenPositions,
                _account.CurrentGrossLots,
                _account.CurrentAbsoluteNetLots);
        }

        private readonly record struct ReplayAccountSnapshot(
            decimal Balance,
            decimal Equity,
            decimal FloatingProfit,
            bool FloatingObservable,
            decimal RealizedProfit,
            decimal UsedMargin,
            decimal? FreeMargin,
            decimal? MarginLevelPercent,
            bool MarginCallActive,
            int OpenPositions,
            decimal GrossLots,
            decimal AbsoluteNetLots);

        // ---- Event plumbing and manifest ----

        private long AddEvent(string type, string line)
        {
            // The event id is injected as the final property of the completed object, so every
            // event is addressable and every telemetry event snapshot can reference it.
            var id = ++_eventId;
            _events.Append(line, 0, line.Length - 1).Append(",\"id\":").Append(id.ToString(CultureInfo.InvariantCulture)).Append('}').Append('\n');
            Increment(_eventCounts, type);
            return id;
        }

        private int TotalEventCount()
        {
            var total = 0;
            foreach (var pair in _eventCounts)
            {
                total += pair.Value;
            }
            return total;
        }

        private static void Increment(SortedDictionary<string, int> counts, string key)
        {
            counts.TryGetValue(key, out var value);
            counts[key] = value + 1;
        }

        private static ReplayPackageFile File(string name, int? year, string content)
        {
            return new ReplayPackageFile(
                ReplayPackage.Directory + "/" + name,
                name,
                year,
                content,
                ReplayPackage.Sha256Hex(content),
                Encoding.UTF8.GetByteCount(content),
                ReplayPackage.CountLines(content));
        }

        private JObject BuildManifest(ReplayPackageMetadata metadata, ReplayRunEnd runEnd, string packageSha256, IReadOnlyList<ReplayPackageFile> payload)
        {
            var files = new JArray();
            foreach (var file in payload)
            {
                files.Add(new JObject
                {
                    ["name"] = file.Name,
                    ["year"] = file.Year.HasValue ? new JValue(file.Year.Value) : JValue.CreateNull(),
                    ["sha256"] = file.Sha256,
                    ["bytes"] = file.Bytes,
                    ["lines"] = file.Lines
                });
            }
            var eventCounts = new JObject();
            foreach (var pair in _eventCounts)
            {
                eventCounts[pair.Key] = pair.Value;
            }
            var telemetryCounts = new JObject
            {
                ["event"] = _eventSnapshots,
                ["periodic"] = _periodicSamples
            };
            return new JObject
            {
                ["contract"] = ReplayPackage.Contract,
                ["modelRevision"] = metadata.ModelRevision,
                ["stopOutModel"] = metadata.StopOutModel,
                ["symbol"] = metadata.Symbol,
                ["market"] = metadata.Market,
                ["securityType"] = metadata.SecurityType,
                ["algorithmTimeZone"] = metadata.AlgorithmTimeZone,
                ["quoteTimeZone"] = metadata.QuoteTimeZone,
                ["startDate"] = metadata.StartDate,
                ["endDate"] = metadata.EndDate,
                ["startUtc"] = ReplayPackage.FormatUtc(metadata.StartUtc),
                ["endUtc"] = ReplayPackage.FormatUtc(metadata.EndUtc),
                ["researchAccountEnabled"] = metadata.ResearchAccountEnabled,
                ["marginEnabled"] = metadata.MarginEnabled,
                ["telemetryIntervalSeconds"] = ReplayPackage.TelemetryIntervalSeconds,
                ["parameters"] = ExactNumbers(metadata.Parameters),
                ["marginParameters"] = metadata.MarginParameters == null ? JValue.CreateNull() : ExactNumbers(metadata.MarginParameters),
                ["sessionMap"] = metadata.SessionMap == null ? JValue.CreateNull() : JObject.FromObject(metadata.SessionMap),
                ["delivered"] = runEnd.Delivery == null
                    ? JValue.CreateNull()
                    : new JObject
                    {
                        ["quoteCount"] = runEnd.Delivery.QuoteCount,
                        ["semanticDigest"] = runEnd.Delivery.SemanticDigest,
                        ["firstCanonicalUtc"] = runEnd.Delivery.FirstCanonicalUtc,
                        ["lastCanonicalUtc"] = runEnd.Delivery.LastCanonicalUtc
                    },
                ["outcome"] = new JObject
                {
                    ["completed"] = runEnd.Completed,
                    ["failureKind"] = runEnd.FailureKind,
                    ["failureCondition"] = runEnd.FailureCondition
                },
                ["counters"] = new JObject
                {
                    ["quoteTicksProcessed"] = runEnd.QuoteTicksProcessed,
                    ["quoteOnlyQuotes"] = runEnd.QuoteOnlyQuotes,
                    ["strategyEligibleQuotes"] = runEnd.StrategyEligibleQuotes,
                    ["legsOpened"] = runEnd.LegsOpened,
                    ["basketsClosed"] = runEnd.BasketsClosed,
                    ["basketsLiquidated"] = runEnd.BasketsLiquidated,
                    ["forcedLiquidations"] = runEnd.ForcedLiquidations,
                    ["distinctRejectedEntries"] = runEnd.DistinctRejectedEntries,
                    ["rejectedEntryAttempts"] = runEnd.RejectedEntryAttempts,
                    ["skippedFirstEntryQuotes"] = runEnd.SkippedFirstEntryQuotes,
                    ["engineRealizedProfit"] = runEnd.EngineRealizedProfit.ToString(CultureInfo.InvariantCulture)
                },
                ["eventCounts"] = eventCounts,
                ["telemetryCounts"] = telemetryCounts,
                ["files"] = files,
                ["packageSha256"] = packageSha256
            };
        }

        /// <summary>
        /// Serializes an object's properties with every numeric leaf as an invariant-culture JSON
        /// string, so the manifest carries the exact decimal parameter identity instead of a JSON
        /// number a consumer could re-read as an IEEE double.
        /// </summary>
        private static JObject ExactNumbers(object value)
        {
            var source = JObject.FromObject(value);
            var result = new JObject();
            foreach (var property in source.Properties())
            {
                result[property.Name] = StringifyNumbers(property.Value);
            }
            return result;
        }

        private static JToken StringifyNumbers(JToken token)
        {
            if (token is JValue value)
            {
                if (value.Type == JTokenType.Integer || value.Type == JTokenType.Float)
                {
                    return new JValue(Convert.ToString(value.Value, CultureInfo.InvariantCulture));
                }
                return value.DeepClone();
            }
            var container = token.DeepClone();
            foreach (var child in container.Children().ToList())
            {
                child.Replace(StringifyNumbers(child));
            }
            return container;
        }

        /// <summary>
        /// Minimal ordered JSON-object writer: properties are written in call order, decimals and
        /// timestamps use the package's canonical forms and strings use JSON escaping. A line is
        /// complete after <see cref="ToLine"/>.
        /// </summary>
        private sealed class JsonLine
        {
            private readonly StringBuilder _sb;
            private bool _first = true;

            public JsonLine()
            {
                _sb = new StringBuilder(256);
                _sb.Append('{');
            }

            public void Text(string name, string value) => Property(name, JsonConvert.ToString(value));

            public void NullableText(string name, string? value)
            {
                if (value == null)
                {
                    Null(name);
                }
                else
                {
                    Text(name, value);
                }
            }

            public void Number(string name, long value) => Property(name, value.ToString(CultureInfo.InvariantCulture));

            public void NullableNumber(string name, long? value)
            {
                if (value.HasValue)
                {
                    Number(name, value.Value);
                }
                else
                {
                    Null(name);
                }
            }

            public void NullableDecimal(string name, decimal? value)
            {
                if (value.HasValue)
                {
                    // Always a canonical string: a JSON number would be re-read as a double by a
                    // browser and could lose decimal precision.
                    Text(name, ReplayPackage.FormatDecimal(value.Value));
                }
                else
                {
                    Null(name);
                }
            }

            public void NullableEnum(string name, object? value)
            {
                if (value == null)
                {
                    Null(name);
                }
                else
                {
                    Text(name, value.ToString()!);
                }
            }

            public void Bool(string name, bool value) => Property(name, value ? "true" : "false");

            public void Time(string name, DateTime value) => Property(name, JsonConvert.ToString(ReplayPackage.FormatUtc(value)));

            public void Null(string name) => Property(name, "null");

            public void Snapshot(string prefix, ReplayAccountSnapshot snapshot)
            {
                Text(prefix + "Balance", ReplayPackage.FormatDecimal(snapshot.Balance));
                Text(prefix + "FloatingProfit", ReplayPackage.FormatDecimal(snapshot.FloatingProfit));
                Text(prefix + "Equity", ReplayPackage.FormatDecimal(snapshot.Equity));
                Text(prefix + "UsedMargin", ReplayPackage.FormatDecimal(snapshot.UsedMargin));
                NullableDecimal(prefix + "FreeMargin", snapshot.FreeMargin);
                NullableDecimal(prefix + "MarginLevelPercent", snapshot.MarginLevelPercent);
                Number(prefix + "OpenPositions", snapshot.OpenPositions);
            }

            private void Property(string name, string json)
            {
                if (!_first)
                {
                    _sb.Append(',');
                }
                _first = false;
                _sb.Append(JsonConvert.ToString(name)).Append(':').Append(json);
            }

            public string ToLine()
            {
                return _sb.Append('}').ToString();
            }
        }
    }
}
