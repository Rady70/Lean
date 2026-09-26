using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Security.Cryptography;
using Newtonsoft.Json;
using Newtonsoft.Json.Converters;
using QuantConnect;
using QuantConnect.Algorithm;
using QuantConnect.Data;
using QuantConnect.Parameters;
using QuantConnect.Securities;

namespace MarketLab.SingleAnchor
{
    /// <summary>
    /// LEAN host for the SingleAnchor vNext strategy on bid/ask quote ticks of one symbol
    /// (XAUUSD by default). LEAN is the data and time host only: it reads the tick files and
    /// drives the clock; the strategy engine keeps the independent hedged basket ledger and the
    /// deterministic <see cref="ResearchExecutor"/> fills every leg from the quote itself under
    /// the configured execution model. No LEAN order is placed, so LEAN's portfolio, orders and
    /// statistics stay empty and are not the strategy's results; the strategy writes its own
    /// results to the object store (`single-anchor/results.json` under the run's `storage\`
    /// folder) and to the algorithm log. Every strategy input is a LEAN parameter (config
    /// `parameters` object or the MarketLab helper's -Parameters), named below;
    /// <c>single-anchor-step-percent</c>, <c>single-anchor-base-lot</c> and
    /// <c>single-anchor-projected-spread</c> have no specified default and must be given;
    /// <c>single-anchor-point-value-per-lot</c> defaults to 100 for XAUUSD only (100 oz per lot,
    /// USD account) and must be given for any other ticker: the host is XAUUSD-focused and does
    /// not carry instrument economics for anything else. <c>single-anchor-session-map</c> names an
    /// optional source-derived session map (absolute, or relative to the data folder). With it,
    /// the engine observes every quote LEAN delivers but a quote in the first or last five minutes
    /// of its source session cannot drive strategy state: it is counted as <c>quoteOnlyQuotes</c>
    /// next to the delivered <c>quoteTicksProcessed</c> and the <c>strategyEligibleQuotes</c>.
    /// This gate removes no delivered quote; quotes LEAN itself filtered out before the strategy
    /// (session identity/hours) are a separate data-path concern. Without the parameter, every
    /// delivered quote is strategy-eligible, the pre-existing behaviour. The optional research
    /// account (<c>single-anchor-research-account</c>, default true) is a derived, read-only view
    /// of the engine's own basket and realized profit (balance, executable floating P/L, equity,
    /// run-level extrema, one compact record per closed basket and a compact snapshot of a
    /// basket still open at end of data or at a fault); it owns no positions and changes
    /// no strategy decision, and the results carry it as <c>researchAccount</c>,
    /// <c>researchBaskets</c> and <c>researchOpenBasket</c> (implementation note section 9).
    /// The optional PR 3 target-account margin layer (<c>single-anchor-margin-enabled</c>,
    /// default false) extends that same account with the frozen USD XM-style contract
    /// (<c>single-anchor-margin-contract-size</c> 100, <c>single-anchor-margin-leverage</c> 500,
    /// <c>single-anchor-margin-call-percent</c> 50, <c>single-anchor-margin-stop-out-percent</c>
    /// 20): used/free margin and margin level derived from the same balance/equity, the 50%
    /// Margin Call entry block, explicit <c>InsufficientMargin</c> rejections against the
    /// projected post-fill inventory, and terminal 20% (or open-position negative-equity)
    /// stop-out that stops the run as an <c>AccountStopOut</c> failure. The extra evidence is
    /// written to <c>researchMargin</c>; disabling margin leaves the pre-PR-3 strategy path
    /// exactly unchanged. The account currency is USD as a research simplification (the user's
    /// live account is EUR-denominated; historical EURUSD conversion is out of scope), and no
    /// LEAN portfolio, order or margin state is used.
    /// A strategy invariant
    /// failure (<see cref="StrategyInvariantException"/>), a data-quality failure
    /// (<see cref="DataQualityException"/>), a session-map coverage mismatch
    /// (<see cref="SessionMapException"/>) or — with the PR 3 margin layer enabled — terminal
    /// account stop-out (<see cref="AccountStopOutException"/>) writes the results with the
    /// failure recorded and then stops the run as a LEAN runtime error. The results also carry the hard-BE verification
    /// metadata (strategy definition resolved, requirement verified at each tail entry under the
    /// configured execution model).
    /// </summary>
    /// <remarks>
    /// The default dates cover the 13-day Oanda XAUUSD tick sample that upstream ships under
    /// <c>Data\cfd\oanda\tick\xauusd</c> (May 2014, an engine fixture); set them to the coverage
    /// of whatever data folder is used. At the end of the data an open basket is reported marked
    /// to market, not closed.
    /// </remarks>
    public class SingleAnchorVNextAlgorithm : QCAlgorithm
    {
        /// <summary>Object-store key of the strategy's results file.</summary>
        public const string ResultsKey = "single-anchor/results.json";

        // ---- Host / instrument ----
        [Parameter("single-anchor-symbol")] private string _ticker = "XAUUSD";
        [Parameter("single-anchor-market")] private string _market = Market.Oanda;
        [Parameter("single-anchor-security-type")] private string _securityType = "Cfd";
        [Parameter("single-anchor-start-date")] private string _startDate = "2014-05-02";
        [Parameter("single-anchor-end-date")] private string _endDate = "2014-05-14";
        [Parameter("single-anchor-cash")] private decimal _cash = 100000m;
        [Parameter("single-anchor-session-map")] private string _sessionMap = "";

        // ---- Specification section 17: principal research parameters ----
        [Parameter("single-anchor-step-percent")] private decimal _stepPercent = 0m;
        [Parameter("single-anchor-base-lot")] private decimal _baseLot = 0m;
        [Parameter("single-anchor-normal-trade-count")] private int _normalTradeCount = 4;
        [Parameter("single-anchor-hard-be-ceiling-percent")] private decimal _hardBreakevenCeilingPercent = 4.478m;
        [Parameter("single-anchor-escape-enabled")] private bool _escapeEnabled = true;
        [Parameter("single-anchor-escape-profit-units")] private decimal _escapeProfitUnits = 0.05m;
        [Parameter("single-anchor-escape-minimum-open-positions")] private int _escapeMinimumOpenPositions = 2;
        [Parameter("single-anchor-fixed-tp-units")] private decimal _fixedTakeProfitUnits = 0m;
        [Parameter("single-anchor-trailing-enabled")] private bool _trailingEnabled = true;
        [Parameter("single-anchor-trailing-activation-units")] private decimal _trailingActivationUnits = 0.50m;
        [Parameter("single-anchor-trailing-drop-units")] private decimal _trailingDropUnits = 0.25m;

        // ---- Execution economics, commission buffer, volume steps, money value ----
        [Parameter("single-anchor-commission-buffer")] private decimal _commissionBuffer = 0m;
        [Parameter("single-anchor-point-value-per-lot")] private string _pointValuePerLot = "";
        [Parameter("single-anchor-volume-step")] private decimal _volumeStep = 0.01m;
        [Parameter("single-anchor-minimum-volume")] private decimal _minimumVolume = 0.01m;
        [Parameter("single-anchor-maximum-volume")] private decimal _maximumVolume = 100m;
        [Parameter("single-anchor-commission-per-lot")] private decimal _commissionPerLot = 0m;
        [Parameter("single-anchor-slippage")] private decimal _slippage = 0m;
        [Parameter("single-anchor-projected-spread")] private string _projectedSpread = "";
        [Parameter("single-anchor-buy-swap-per-lot-per-day")] private decimal _buySwapPerLotPerDay = 0m;
        [Parameter("single-anchor-sell-swap-per-lot-per-day")] private decimal _sellSwapPerLotPerDay = 0m;

        // ---- Research account / bounded analytics (approved roadmap PR 2) ----
        [Parameter("single-anchor-research-account")] private bool _researchAccountEnabled = true;

        // ---- Target-account margin survival (approved roadmap PR 3) ----
        [Parameter("single-anchor-margin-enabled")] private bool _marginEnabled = false;
        [Parameter("single-anchor-margin-contract-size")] private decimal _marginContractSize = 100m;
        [Parameter("single-anchor-margin-leverage")] private decimal _marginLeverage = 500m;
        [Parameter("single-anchor-margin-call-percent")] private decimal _marginCallPercent = 50m;
        [Parameter("single-anchor-margin-stop-out-percent")] private decimal _marginStopOutPercent = 20m;

        private Symbol _symbol = null!;
        private SingleAnchorEngine _engine = null!;
        private SingleAnchorParameters _parameters = null!;
        private SingleAnchorResearchAccount? _researchAccount;
        private SessionMapRunInfo? _sessionMapInfo;
        private readonly QuoteTickFeed _feed = new QuoteTickFeed();

        /// <summary>The strategy engine (exposed for inspection after a run).</summary>
        public SingleAnchorEngine Engine => _engine;

        /// <inheritdoc />
        public override void Initialize()
        {
            SetStartDate(ParameterParsing.ParseDate(_startDate, "single-anchor-start-date"));
            SetEndDate(ParameterParsing.ParseDate(_endDate, "single-anchor-end-date"));
            SetCash(_cash);

            Security security;
            if (string.Equals(_securityType, "Forex", StringComparison.OrdinalIgnoreCase))
            {
                security = AddForex(_ticker, Resolution.Tick, _market, fillForward: false);
            }
            else if (string.Equals(_securityType, "Cfd", StringComparison.OrdinalIgnoreCase))
            {
                security = AddCfd(_ticker, Resolution.Tick, _market, fillForward: false);
            }
            else
            {
                throw new ArgumentException($"single-anchor-security-type must be Cfd or Forex (got '{_securityType}').");
            }
            _symbol = security.Symbol;
            // Benchmark the traded symbol itself so the run needs no unrelated (SPY) data.
            SetBenchmark(_symbol);

            var pointValue = ParameterParsing.ParseOptionalDecimal(_pointValuePerLot, "single-anchor-point-value-per-lot");
            if (!pointValue.HasValue)
            {
                if (string.Equals(_ticker, "XAUUSD", StringComparison.OrdinalIgnoreCase))
                {
                    pointValue = 100m; // the documented XAUUSD assumption: 100 oz per lot in a USD account
                }
                else
                {
                    throw new ArgumentException($"single-anchor-point-value-per-lot must be given for {_ticker}: the host carries instrument economics for XAUUSD only (100 per lot); any other instrument needs its own explicit money value.");
                }
            }

            _parameters = new SingleAnchorParameters
            {
                StepPercent = _stepPercent,
                BaseLot = _baseLot,
                NormalTradeCount = _normalTradeCount,
                HardBreakevenCeilingPercent = _hardBreakevenCeilingPercent,
                EscapeEnabled = _escapeEnabled,
                EscapeProfitUnits = _escapeProfitUnits,
                EscapeMinimumOpenPositions = _escapeMinimumOpenPositions,
                FixedTakeProfitUnits = _fixedTakeProfitUnits,
                TrailingEnabled = _trailingEnabled,
                TrailingActivationUnits = _trailingActivationUnits,
                TrailingDropUnits = _trailingDropUnits,
                CommissionBuffer = _commissionBuffer,
                PointValuePerLot = pointValue.Value,
                VolumeStep = _volumeStep,
                MinimumVolume = _minimumVolume,
                MaximumVolume = _maximumVolume,
                CommissionPerLot = _commissionPerLot,
                Slippage = _slippage,
                ProjectedSpread = ParameterParsing.ParseOptionalDecimal(_projectedSpread, "single-anchor-projected-spread"),
                BuySwapPerLotPerDay = _buySwapPerLotPerDay,
                SellSwapPerLotPerDay = _sellSwapPerLotPerDay
            };
            var errors = _parameters.GetValidationErrors();
            if (errors.Count > 0)
            {
                throw new ArgumentException("SingleAnchor parameters are invalid (see the single-anchor-* parameters): " + string.Join(" ", errors));
            }

            var availability = ResolveTradingAvailability(security);
            MarginParameters? margin = null;
            if (_marginEnabled)
            {
                if (!_researchAccountEnabled)
                {
                    throw new ArgumentException(
                        "single-anchor-margin-enabled=true requires single-anchor-research-account=true: the PR 3 margin/survival model extends the one research account and must not create a second Balance/Equity authority.");
                }
                margin = new MarginParameters
                {
                    ContractSize = _marginContractSize,
                    Leverage = _marginLeverage,
                    MarginCallLevelPercent = _marginCallPercent,
                    StopOutLevelPercent = _marginStopOutPercent
                };
                var marginErrors = margin.GetValidationErrors();
                if (marginErrors.Count > 0)
                {
                    throw new ArgumentException("SingleAnchor margin parameters are invalid (see the single-anchor-margin-* parameters): " + string.Join(" ", marginErrors));
                }
            }
            _researchAccount = _researchAccountEnabled ? new SingleAnchorResearchAccount(_parameters, _cash, margin) : null;
            _engine = new SingleAnchorEngine(_parameters, new ResearchExecutor(_parameters), availability, _researchAccount, margin != null ? _researchAccount : null);
            WireEvents();

            Log(_researchAccount != null
                ? $"SingleAnchor research account enabled: initial balance {F(_cash)}; derived Balance/FloatingPL/Equity and the run/basket analytics are written in the results (the strategy path is unchanged)."
                : "SingleAnchor research account disabled (single-anchor-research-account=false): the run is the pre-PR-2 strategy path with no derived account state.");
            if (margin != null)
            {
                Log($"SingleAnchor target-account margin enabled: USD XM-style research account (not the EUR live account), contract {F(margin.ContractSize)} oz/lot, fixed leverage 1:{F(margin.Leverage)}, initial/maintenance margin rate 1.0, matched BUY/SELL volume has zero margin and only the uncovered side is charged {F(margin.ContractSize)} oz/lot * weighted-average open price / {F(margin.Leverage)}; Margin Call {F(margin.MarginCallLevelPercent)}% blocks new entries while exits stay possible, terminal Stop Out {F(margin.StopOutLevelPercent)}% (or open positions with negative equity) stops the run, no broker liquidation is simulated; BUY/SELL swap 0 and commission per lot {F(_parameters.CommissionPerLot)}.");
            }

            var verification = _engine.HardBreakevenStatus;
            Log($"SingleAnchor hard-BE verification: strategyDefinitionResolved={verification.StrategyDefinitionResolved}; hardBEVerifiedUnderConfiguredExecutionModel={verification.HardBEVerifiedUnderConfiguredExecutionModel}; scope: {verification.Scope} Assumptions: {string.Join("; ", verification.Assumptions)}. Not covered: {string.Join("; ", verification.NotCovered)}.");

            Log($"SingleAnchor vNext on {_symbol} ({_securityType}, {_market}) tick quotes; LEAN is the data host, fills are the research executor's, no LEAN order is placed.");
            var p = _parameters;
            Log($"SingleAnchor parameters: step {F(p.StepPercent)}%, base lot {F(p.BaseLot)}, Nnormal {p.NormalTradeCount}, hard-BE ceiling {F(p.HardBreakevenCeilingPercent)}%, " +
                $"escape {(p.EscapeEnabled ? F(p.EscapeProfitUnits) + " units, min " + p.EscapeMinimumOpenPositions + " positions" : "off")}, " +
                $"fixed TP {(p.FixedTakeProfitUnits > 0m ? F(p.FixedTakeProfitUnits) + " units" : "off")}, " +
                $"trailing {(p.TrailingEnabled ? F(p.TrailingActivationUnits) + "/" + F(p.TrailingDropUnits) + " units" : "off")}, " +
                $"commission buffer {F(p.CommissionBuffer)}, point value {F(p.PointValuePerLot)}/lot, volume step {F(p.VolumeStep)} [{F(p.MinimumVolume)}, {F(p.MaximumVolume)}], " +
                $"commission {F(p.CommissionPerLot)}/lot round trip, slippage {F(p.Slippage)}, target spread {F(p.ProjectedSpread!.Value)}, " +
                $"swap buy {F(p.BuySwapPerLotPerDay)} / sell {F(p.SellSwapPerLotPerDay)} per lot per day (financing not supported; both must be 0).");
        }

        /// <summary>
        /// Loads the optional source-derived session map and turns it into the engine's
        /// trading-availability classifier. Without the parameter the run keeps the unrestricted
        /// behaviour: every delivered quote is strategy-eligible. With it, the map must exist and
        /// be for this symbol; its UTC sessions are converted into this subscription's exchange
        /// time zone, which is the clock of LEAN's tick times, while the junction-rule zone stays
        /// the map's own.
        /// </summary>
        private HistoricalTradingAvailability? ResolveTradingAvailability(Security security)
        {
            if (string.IsNullOrWhiteSpace(_sessionMap))
            {
                Log("SingleAnchor session map: none configured; every delivered quote is strategy-eligible (no five-minute trading-availability restriction).");
                return null;
            }

            var path = Path.IsPathRooted(_sessionMap)
                ? _sessionMap
                : Path.Combine(Globals.DataFolder, _sessionMap);
            if (!File.Exists(path))
            {
                throw new ArgumentException(
                    $"single-anchor-session-map is '{_sessionMap}' but '{path}' does not exist. " +
                    "Generate it with MarketLab\\tools\\session-map from the immutable source and place it outside Git.");
            }

            var map = HistoricalSessionMap.Load(path);
            if (!string.Equals(map.Symbol, _ticker, StringComparison.OrdinalIgnoreCase))
            {
                throw new ArgumentException(
                    $"session map {path} is for '{map.Symbol}' but the run is configured for '{_ticker}'.");
            }

            // The junction rule is evaluated in the junction time zone, but the replay may deliver
            // quotes in any clock (LEAN's subscription time zone); the UTC boundaries are
            // converted to whatever clock this run actually delivers.
            var availability = map.ToAvailability(security.Exchange.TimeZone);
            var source = map.Source!;
            var final = map.Sessions[map.Sessions.Count - 1]!;
            _sessionMapInfo = new SessionMapRunInfo(
                _sessionMap, Sha256File(path), map.Symbol, map.JunctionTimeZone, map.Sessions.Count,
                map.Sessions[0]!.Start, final.End.HasValue,
                source.FileCount, source.RowCount, source.Sha256Aggregate, source.FirstQuoteUtc, source.LastQuoteUtc);
            Log(
                $"SingleAnchor session map: {map.Sessions.Count} source-derived sessions from {path} (sha256 {_sessionMapInfo.Sha256}); " +
                $"junction rule zone {map.JunctionTimeZone}, quote clock {security.Exchange.TimeZone.Id}; " +
                $"source {source.FileCount} files / {source.RowCount} rows (aggregate sha256 {source.Sha256Aggregate}); " +
                $"five-minute quote-only buffers at both session ends; first session starts {FormatUtc(map.Sessions[0]!.Start)}; " +
                (final.End.HasValue
                    ? $"final session ends {FormatUtc(final.End.Value)} (coverage end {FormatUtc(source.LastQuoteUtc)})."
                    : $"final session end not observable (no closing buffer; coverage ends {FormatUtc(source.LastQuoteUtc)})."));
            return availability;
        }

        private static string FormatUtc(DateTime value)
        {
            return value.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", CultureInfo.InvariantCulture);
        }

        private static string Sha256File(string path)
        {
            using var stream = File.OpenRead(path);
            using var sha = SHA256.Create();
            return Convert.ToHexString(sha.ComputeHash(stream)).ToLowerInvariant();
        }

        private sealed record SessionMapRunInfo(
            string Map,
            string Sha256,
            string Symbol,
            string JunctionTimeZone,
            int Sessions,
            DateTime FirstSessionStartUtc,
            bool FinalSessionEndObservable,
            int SourceFileCount,
            long SourceRowCount,
            string SourceSha256Aggregate,
            DateTime SourceFirstQuoteUtc,
            DateTime SourceCoverageEndUtc);

        /// <inheritdoc />
        public override void OnData(Slice slice)
        {
            if (slice == null || !slice.Ticks.TryGetValue(_symbol, out var ticks))
            {
                return;
            }
            try
            {
                _feed.Feed(ticks, _engine);
            }
            catch (SingleAnchorRunException failure)
            {
                // LEAN ends the run on the rethrow without calling OnEndOfAlgorithm, so the
                // results are written here, with the failure recorded. Every engine fault kind
                // (strategy invariant, data quality, session-map coverage) ends the run the same
                // way.
                Error($"SingleAnchor {failure.Kind} failure ({failure.Condition}): {failure.Message}");
                Log($"SingleAnchor run stopped by the {failure.Condition} condition at {failure.Quote}.");
                WriteResults(new RunFailure(failure.Kind, failure.Condition, failure.Quote, failure.Message));
                throw;
            }
        }

        /// <inheritdoc />
        public override void OnEndOfAlgorithm()
        {
            Log($"SingleAnchor end of data: {_engine.QuotesProcessed} quote ticks delivered and processed ({_feed.NonQuoteTicks} non-quote ticks unused), {_engine.QuoteOnlyQuotes} quote-only in five-minute session buffers, {_engine.StrategyEligibleQuotes} strategy-eligible; {_engine.EntriesOpened} legs opened, {_engine.EntriesRejected} distinct rejected entries ({_engine.RejectedEntryAttempts} attempts), {_engine.BasketsClosed} baskets closed, realized profit {F(_engine.RealizedProfit)}.");

            var snapshot = CurrentBasketSnapshot();
            var basket = _engine.Basket;
            if (basket == null || snapshot == null)
            {
                Log("SingleAnchor end of data: no basket open.");
            }
            else if (basket.OpenPositions == 0)
            {
                Log($"SingleAnchor end of data: basket #{snapshot.Sequence} anchored at {F(snapshot.Anchor)} (upper {F(snapshot.Upper)}, lower {F(snapshot.Lower)}) with no open leg" +
                    (snapshot.SkippedFirstEntryTrace != null ? $"; {snapshot.SkippedFirstEntryTrace.Attempts} first-entry quote(s) skipped as ambiguous" : string.Empty) + ".");
            }
            else
            {
                Log($"SingleAnchor end of data: open basket #{snapshot.Sequence} marked to market at {snapshot.Quote} (not closed): {snapshot.OpenPositions} legs, buy {F(snapshot.BuyLots)} / sell {F(snapshot.SellLots)} / gross {F(snapshot.GrossLots)} / net {F(snapshot.NetLots)} lots, raw profit {F(snapshot.RawProfit!.Value)}, exit profit {F(snapshot.ExitProfit!.Value)}, executable profit {(snapshot.ExecutableProfit.HasValue ? F(snapshot.ExecutableProfit.Value) : "n/a (a needed executable close price is not positive)")}, step money {F(snapshot.StepMoney!.Value)}, hard-BE mode {snapshot.HardBreakevenModeActive}, trailing {snapshot.TrailingActive} (peak {F(snapshot.PeakProfit)}).");
                foreach (var leg in basket.Legs)
                {
                    Log($"SingleAnchor open leg: {leg}");
                }
            }

            if (_researchAccount != null)
            {
                if (_engine.LastProcessedQuote.HasValue)
                {
                    // The end-of-data mark is observed with the same engine state the openBasket
                    // snapshot reports, so the final equity and the run extrema include it.
                    _researchAccount.ObserveEndOfRun(_engine.LastProcessedQuote.Value, _engine.Basket, _engine.RealizedProfit);
                }
                var a = _researchAccount.Summary;
                var mark = a.FloatingObservable
                    ? $"floating {F(a.FloatingProfit)}, equity {F(a.Equity)}"
                    : $"floating/equity not current (the last executable mark was unavailable; {a.FloatingObservationsSkipped} observation(s) skipped overall); last observable floating {F(a.FloatingProfit)}, equity {F(a.Equity)}";
                Log($"SingleAnchor research account: balance {F(a.Balance)} ({mark}), realized {F(a.RealizedProfit)}, peak balance {F(a.PeakBalance)}, max balance drawdown {F(a.MaxBalanceDrawdown)}, peak equity {F(a.PeakEquity)}, max equity drawdown {F(a.MaxEquityDrawdown)}; exposure max {a.MaxOpenPositions} positions / {F(a.MaxGrossLots)} gross / {F(a.MaxAbsoluteNetLots)} |net| lots (final {a.CurrentOpenPositions} / {F(a.CurrentGrossLots)} / {F(a.CurrentAbsoluteNetLots)}); max executable floating loss {FNullable(a.MaxExecutableFloatingLoss)}, max executable floating profit {FNullable(a.MaxExecutableFloatingProfit)}; skipped executable marks {a.FloatingObservationsSkipped}; {a.ClosedBasketsObserved} closed-basket research record(s).");
                if (_researchAccount.MarginSummary is { } m)
                {
                    Log($"SingleAnchor target-account margin: used {F(m.CurrentUsedMargin)}, free {FNullable(m.CurrentFreeMargin)}, margin level {FPercent(m.CurrentMarginLevelPercent)} (max used {F(m.MaxUsedMargin)}, min free {FNullable(m.MinFreeMargin)}, min level {FPercent(m.MinMarginLevelPercent)}); Margin Call {m.MarginCallActive} ({m.MarginCallEpisodes} episode(s), {m.MarginCallObservations} observation(s), {m.MarginCallBlockedEpisodes} blocked episode(s)/{m.MarginCallBlockedAttempts} attempt(s)); insufficient-margin {m.InsufficientMarginEpisodes} episode(s)/{m.InsufficientMarginAttempts} attempt(s); stop-out {(m.StopOut == null ? "none" : m.StopOut.Reason + " at " + m.StopOut.Time.ToString("yyyy-MM-dd HH:mm:ss.fff", CultureInfo.InvariantCulture))}.");
                }
            }

            WriteResults(null);
        }

        private sealed record RunFailure(string Kind, string Condition, Quote Quote, string Message);

        private BasketSnapshot? CurrentBasketSnapshot()
        {
            return _engine.Basket != null && _engine.LastProcessedQuote.HasValue ? _engine.MarkToMarket(_engine.LastProcessedQuote.Value) : null;
        }

        private void WriteResults(RunFailure? failure)
        {
            var results = new Dictionary<string, object?>
            {
                ["completed"] = failure == null,
                ["failure"] = failure,
                ["hardBreakevenVerification"] = _engine.HardBreakevenStatus,
                ["symbol"] = _symbol.Value,
                ["market"] = _market,
                ["quoteTimeZone"] = Securities[_symbol].Exchange.TimeZone.Id,
                ["startDate"] = _startDate,
                ["endDate"] = _endDate,
                ["parameters"] = _parameters,
                ["quoteTicksProcessed"] = _engine.QuotesProcessed,
                ["quoteOnlyQuotes"] = _engine.QuoteOnlyQuotes,
                ["strategyEligibleQuotes"] = _engine.StrategyEligibleQuotes,
                ["sessionMap"] = _sessionMapInfo,
                ["nonQuoteTicksUnused"] = _feed.NonQuoteTicks,
                ["lastProcessedQuote"] = _engine.LastProcessedQuote,
                ["legsOpened"] = _engine.EntriesOpened,
                ["skippedFirstEntryQuotes"] = _engine.SkippedFirstEntryQuotes,
                ["distinctRejectedEntries"] = _engine.EntriesRejected,
                ["rejectedEntryAttempts"] = _engine.RejectedEntryAttempts,
                ["basketsClosed"] = _engine.BasketsClosed,
                ["realizedProfit"] = _engine.RealizedProfit,
                ["researchAccount"] = _researchAccount?.Summary,
                ["researchBaskets"] = _researchAccount?.BasketRecords,
                ["researchOpenBasket"] = _researchAccount?.SnapshotActiveBasket(_engine.Basket),
                ["researchMargin"] = _researchAccount?.MarginSummary,
                ["closedBaskets"] = _engine.ClosedBaskets,
                ["openBasket"] = CurrentBasketSnapshot()
            };
            var settings = new JsonSerializerSettings { Formatting = Formatting.Indented, Converters = { new StringEnumConverter() } };
            if (ObjectStore.SaveJson(ResultsKey, results, settings: settings))
            {
                Log($"SingleAnchor results written to the object store as {ResultsKey}.");
            }
            else
            {
                Error($"SingleAnchor results could not be written to the object store as {ResultsKey}.");
            }
        }

        private void WireEvents()
        {
            _engine.AnchorCreated += e => Log($"SingleAnchor basket #{e.Basket.Sequence} anchor {F(e.Basket.Anchor)} at {e.Quote}: upper {F(e.Basket.Upper)}, lower {F(e.Basket.Lower)}, hard-BE boundaries {F(e.Basket.LowerTarget)} / {F(e.Basket.UpperTarget)}.");
            _engine.FirstEntrySkipped += e => Log($"SingleAnchor basket #{e.Basket.Sequence} first entry skipped at {e.Quote} (spread {F(e.Quote.Spread)} satisfies both boundaries); the basket stays empty and waits for an unambiguous quote.");
            _engine.EntryOpened += e => Log($"SingleAnchor leg opened: {e.Leg}; basket buy {F(e.Basket.BuyLots)} / sell {F(e.Basket.SellLots)} / net {F(e.Basket.NetLots)} lots" + (e.Sizing.HasValue ? "; " + e.Sizing.Value.Message : string.Empty));
            _engine.EntryRejected += e => Error($"SingleAnchor entry rejected ({e.Rejection.Reason}) for trade {e.Rejection.TradeNumber} {e.Rejection.Side} of basket #{e.Basket.Sequence} at {e.Quote}: {e.Rejection.Message}");
            _engine.HardBreakevenViolated += e => Error($"SingleAnchor hard-BE violated by the fill of {e.Leg} in basket #{e.Basket.Sequence}: projected executable P/L at target {F(e.Sizing.Target.Target)} is {F(e.ProjectedProfitAfterFill)} after the fill (sizing expected {F(e.Sizing.ProjectedProfitAfter)}); the run stops.");
            _engine.TrailingActivated += e => Log($"SingleAnchor trailing activated at profit {F(e.Profit)} (threshold {F(e.ActivationThreshold)}) at {e.Quote}.");
            _engine.BasketClosed += e => Log($"SingleAnchor basket #{e.Record.Sequence} closed by {e.Record.Reason} at {e.Quote}: {e.Record.Legs} legs, raw profit {F(e.Record.RawProfit)}, exit profit {F(e.Record.ExitProfit)} vs threshold {F(e.Record.Threshold)}, realized {F(e.Record.RealizedProfit)} (buys closed {F(e.Record.BuyClosePrice)}, sells closed {F(e.Record.SellClosePrice)}, commission {F(e.Record.Commission)}); realized total {F(_engine.RealizedProfit)}.");
            _engine.BasketCloseFailed += e => Error($"SingleAnchor close ({e.Reason}) failed at {e.Quote}: {e.Message}");
        }

        private static string F(decimal value)
        {
            return value.ToString(CultureInfo.InvariantCulture);
        }

        private static string FNullable(decimal? value)
        {
            return value.HasValue ? F(value.Value) : "n/a";
        }

        private static string FPercent(decimal? value)
        {
            return value.HasValue ? F(value.Value) + "%" : "n/a (zero used margin)";
        }
    }
}
