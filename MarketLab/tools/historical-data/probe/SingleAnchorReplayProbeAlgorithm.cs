using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Security.Cryptography;
using NodaTime;
using Newtonsoft.Json;
using QuantConnect;
using QuantConnect.Algorithm;
using QuantConnect.Data;
using QuantConnect.Parameters;
using QuantConnect.Securities;
using MarketLab.SingleAnchor;

namespace MarketLab.HistoricalDataProbe
{
    /// <summary>
    /// MarketLab-owned qualification probe that exercises the actual unchanged LEAN
    /// backtest/data path for the qualified quote-tick subscriptions (the
    /// XAUUSD/oanda/Cfd engine fixture and the XAUUSD/dukascopy/Cfd source identity).
    ///
    /// The probe subscribes exactly like the SingleAnchor host
    /// (<see cref="SingleAnchorVNextAlgorithm"/>: <c>AddCfd(..., Resolution.Tick, ...,
    /// fillForward: false)</c>), feeds every delivered quote tick through the strategy's own
    /// <see cref="QuoteTickFeed"/> and <see cref="SingleAnchorEngine"/> (so the data-quality and
    /// ordering gate of the real strategy path also applies), and accumulates the same canonical
    /// semantic digest the offline converter produced for the qualified source. At the end of the
    /// data it compares delivered count, digest, first/last canonical UTC and per-partition
    /// summaries against <c>replay-expectation.json</c> and writes
    /// <c>single-anchor-replay-probe/replay-result.json</c> to the run's object store.
    ///
    /// The probe is a separate assembly: nothing in the normal strategy path changes and no
    /// per-tick reporting exists unless this probe is explicitly selected as the algorithm.
    ///
    /// Parameters (all optional; the expectation file supplies the window and identity):
    /// <c>probe-symbol</c> (XAUUSD), <c>probe-market</c> (oanda or dukascopy),
    /// <c>probe-security-type</c> (Cfd), <c>probe-expectation-file</c> (config route only; the
    /// default is <c>&lt;data-folder&gt;/marketlab-qualification/replay-expectation.json</c>),
    /// <c>probe-step-percent</c> (0.2), <c>probe-base-lot</c> (0.01) and
    /// <c>probe-projected-spread</c> (0): the probe only needs a valid engine for the feed path.
    /// </summary>
    public class SingleAnchorReplayProbeAlgorithm : QCAlgorithm
    {
        /// <summary>Object-store key of the probe's machine-readable result.</summary>
        public const string ResultKey = "single-anchor-replay-probe/replay-result.json";

        /// <summary>Expected expectation contract identifier.</summary>
        public const string ExpectationContract = "marketlab-single-anchor-replay-expectation-v1";

        [Parameter("probe-symbol")] private string _ticker = "XAUUSD";
        [Parameter("probe-market")] private string _market = Market.Oanda;
        [Parameter("probe-security-type")] private string _securityType = "Cfd";
        [Parameter("probe-expectation-file")] private string _expectationFile = "";
        [Parameter("probe-step-percent")] private decimal _stepPercent = 0.2m;
        [Parameter("probe-base-lot")] private decimal _baseLot = 0.01m;
        [Parameter("probe-projected-spread")] private decimal _projectedSpread = 0m;

        private Symbol _symbol = null!;
        private SingleAnchorEngine _engine = null!;
        private ReplayExpectation _expectation = null!;
        private DeliveredStream _delivered = null!;
        private readonly ProbeRuntime _runtime = new ProbeRuntime();
        private readonly QuoteTickFeed _feed = new QuoteTickFeed();
        private EngineFault? _fault;
        private ReplayProbeResult? _result;
        private bool _resultWritten;

        /// <inheritdoc />
        public override void Initialize()
        {
            var expectationPath = ResolveExpectationPath();
            if (!File.Exists(expectationPath))
            {
                throw new InvalidOperationException(
                    $"replay expectation not found: {expectationPath}. Qualify and convert the source " +
                    "against this data folder first (python -m marketlab_historical_data qualify ...).");
            }

            _expectation = ReplayExpectation.Load(expectationPath);
            RequireContract(_expectation);
            SetTimeZone(ResolveZone(_expectation.DataTimeZone));
            SetStartDate(_expectation.ParseStartDate());
            SetEndDate(_expectation.ParseEndDate());
            SetCash(100000m);

            Security security;
            if (string.Equals(_securityType, "Forex", StringComparison.OrdinalIgnoreCase))
            {
                security = AddForex(_ticker, Resolution.Tick, _market, fillForward: false);
            }
            else
            {
                security = AddCfd(_ticker, Resolution.Tick, _market, fillForward: false);
            }

            _symbol = security.Symbol;
            SetBenchmark(_symbol);

            var config = security.Subscriptions.First();
            _runtime.DataTimeZone = config.DataTimeZone.Id;
            _runtime.ExchangeTimeZone = config.ExchangeTimeZone.Id;
            _runtime.AlgorithmTimeZone = TimeZone.Id;
            _runtime.LeanDataFolder = Globals.DataFolder;
            _runtime.StartDate = _expectation.RunWindow.StartDate;
            _runtime.EndDate = _expectation.RunWindow.EndDate;
            var marketHoursPath = Path.Combine(
                Globals.GetDataFolderPath("market-hours"), "market-hours-database.json");
            _runtime.MarketHoursDatabasePath = marketHoursPath;
            _runtime.MarketHoursDatabaseSha256 = File.Exists(marketHoursPath)
                ? Sha256File(marketHoursPath)
                : string.Empty;
            _runtime.Assemblies = CollectRuntimeAssemblies();
            _delivered = new DeliveredStream(config.ExchangeTimeZone, config.DataTimeZone);

            var parameters = new SingleAnchorParameters
            {
                StepPercent = _stepPercent,
                BaseLot = _baseLot,
                PointValuePerLot = 100m,
                ProjectedSpread = _projectedSpread
            };
            var errors = parameters.GetValidationErrors();
            if (errors.Count > 0)
            {
                throw new ArgumentException(
                    "probe execution parameters are invalid: " + string.Join(" ", errors));
            }

            _engine = new SingleAnchorEngine(parameters, new ResearchExecutor(parameters));

            Log(
                $"SingleAnchor replay probe: {_expectation.Symbol} {_expectation.SecurityType} " +
                $"({_expectation.Market}) tick quotes; data time zone {_runtime.DataTimeZone}, " +
                $"exchange time zone {_runtime.ExchangeTimeZone}, algorithm time zone " +
                $"{_runtime.AlgorithmTimeZone}; window {_runtime.StartDate}..{_runtime.EndDate}; " +
                $"expecting {_expectation.AcceptedRowCount} quotes.");
        }

        /// <inheritdoc />
        public override void OnData(Slice slice)
        {
            if (slice == null || !slice.Ticks.TryGetValue(_symbol, out var ticks))
            {
                return;
            }

            try
            {
                foreach (var tick in ticks)
                {
                    if (tick.TickType != TickType.Quote)
                    {
                        continue;
                    }

                    _delivered.Add(tick.Time, tick.BidPrice, tick.AskPrice);
                }

                _feed.Feed(ticks, _engine);
            }
            catch (SingleAnchorRunException failure)
            {
                _fault = new EngineFault
                {
                    Kind = failure.Kind,
                    Condition = failure.Condition,
                    Message = failure.Message,
                    Quote = failure.Quote.ToString()
                };
                Error($"SingleAnchor replay probe stopped by the {failure.Kind} ({failure.Condition}) " +
                      $"condition at {failure.Quote}: {failure.Message}");
                WriteResult();
                throw;
            }
        }

        /// <inheritdoc />
        public override void OnEndOfAlgorithm()
        {
            WriteResult();
            var result = _result;
            if (result != null && result.FailureReasons.Count > 0)
            {
                Error("SingleAnchor replay qualification FAIL: " + string.Join(", ", result.FailureReasons));
                throw new InvalidOperationException(
                    "SingleAnchor replay qualification failed: " +
                    string.Join(", ", result.FailureReasons));
            }

            Log($"SingleAnchor replay probe PASS: {result?.Delivered.QuoteCount ?? 0} quotes delivered, " +
                $"digest {result?.Delivered.SemanticDigest ?? "n/a"}.");
        }

        private void RequireContract(ReplayExpectation expectation)
        {
            if (!string.Equals(expectation.Contract, ExpectationContract, StringComparison.Ordinal))
            {
                throw new InvalidOperationException(
                    $"replay expectation contract is '{expectation.Contract}', expected " +
                    $"'{ExpectationContract}'");
            }

            if (!string.Equals(expectation.Symbol, _ticker, StringComparison.OrdinalIgnoreCase) ||
                !string.Equals(expectation.Market, _market, StringComparison.OrdinalIgnoreCase) ||
                !string.Equals(expectation.SecurityType, _securityType, StringComparison.OrdinalIgnoreCase))
            {
                throw new InvalidOperationException(
                    $"replay expectation is for {expectation.Symbol}/{expectation.SecurityType}/" +
                    $"{expectation.Market}, but the probe was configured for {_ticker}/" +
                    $"{_securityType}/{_market}");
            }
        }

        private string ResolveExpectationPath()
        {
            if (!string.IsNullOrWhiteSpace(_expectationFile))
            {
                return Path.GetFullPath(_expectationFile);
            }

            return Path.Combine(
                Globals.DataFolder, "marketlab-qualification", "replay-expectation.json");
        }

        private static DateTimeZone ResolveZone(string id)
        {
            if (string.IsNullOrWhiteSpace(id))
            {
                throw new InvalidOperationException("replay expectation carries no data time zone");
            }

            if (string.Equals(id, "UTC", StringComparison.OrdinalIgnoreCase))
            {
                return TimeZones.Utc;
            }

            var zone = DateTimeZoneProviders.Tzdb.GetZoneOrNull(id);
            if (zone == null)
            {
                throw new InvalidOperationException($"data time zone is unknown to NodaTime: {id}");
            }

            return zone;
        }

        private static string Sha256File(string path)
        {
            using var stream = File.OpenRead(path);
            using var sha = SHA256.Create();
            return Convert.ToHexString(sha.ComputeHash(stream)).ToLowerInvariant();
        }

        private static Dictionary<string, string> CollectRuntimeAssemblies()
        {
            var assemblies = new Dictionary<string, string>(StringComparer.Ordinal);
            void Add(Assembly? assembly)
            {
                var location = assembly?.Location;
                if (!string.IsNullOrEmpty(location) && File.Exists(location))
                {
                    assemblies[Path.GetFileName(location)] = Sha256File(location);
                }
            }

            Add(Assembly.GetEntryAssembly());
            Add(typeof(SingleAnchorReplayProbeAlgorithm).Assembly);
            Add(typeof(QCAlgorithm).Assembly);
            Add(typeof(QuantConnect.Data.Market.Tick).Assembly);
            return assemblies;
        }

        private void WriteResult()
        {
            if (_resultWritten)
            {
                return;
            }

            _resultWritten = true;
            var delivered = _delivered.ToSummary();
            var comparison = ReplayQualification.Compare(
                _expectation, delivered, _engine != null ? _engine.QuotesProcessed : -1);
            var reasons = ReplayQualification.FailureReasons(comparison);
            if (_fault != null)
            {
                reasons.Add("EngineFaulted");
            }

            _runtime.EngineQuotesProcessed = _engine != null ? _engine.QuotesProcessed : 0;
            _runtime.EngineNonQuoteTicks = _feed.NonQuoteTicks;
            _runtime.EngineFault = _fault;
            _result = new ReplayProbeResult
            {
                Completed = _fault == null,
                Qualification = reasons.Count == 0 && _fault == null ? "PASS" : "FAIL",
                FailureReasons = reasons,
                Expected = _expectation,
                Delivered = delivered,
                Comparison = comparison,
                Runtime = _runtime
            };

            var settings = new JsonSerializerSettings { Formatting = Formatting.Indented };
            if (ObjectStore.SaveJson(ResultKey, _result, settings: settings))
            {
                Log($"SingleAnchor replay result written to the object store as {ResultKey}.");
            }
            else
            {
                Error($"SingleAnchor replay result could not be written to the object store as {ResultKey}.");
            }
        }
    }
}
