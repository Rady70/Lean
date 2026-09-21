using System;
using System.Collections.Generic;
using System.Globalization;
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
    /// not carry instrument economics for anything else. A strategy invariant failure
    /// (<see cref="StrategyInvariantException"/>) or a data-quality failure
    /// (<see cref="DataQualityException"/>) writes the results with the failure recorded and then
    /// stops the run as a LEAN runtime error. The results also carry the hard-BE guarantee
    /// metadata and the strategy-definition decisions still open with the owner.
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
        [Parameter("single-anchor-swap-rollover-time")] private string _swapRolloverTime = "1700";
        [Parameter("single-anchor-triple-swap-day")] private string _tripleSwapDay = "Wednesday";

        private Symbol _symbol = null!;
        private SingleAnchorEngine _engine = null!;
        private SingleAnchorParameters _parameters = null!;
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
                SellSwapPerLotPerDay = _sellSwapPerLotPerDay,
                SwapRolloverTimeOfDay = ParameterParsing.ParseTimeOfDay(_swapRolloverTime, "single-anchor-swap-rollover-time"),
                TripleSwapDay = ParameterParsing.ParseOptionalDayOfWeek(_tripleSwapDay, "single-anchor-triple-swap-day")
            };
            var errors = _parameters.GetValidationErrors();
            if (errors.Count > 0)
            {
                throw new ArgumentException("SingleAnchor parameters are invalid (see the single-anchor-* parameters): " + string.Join(" ", errors));
            }

            _engine = new SingleAnchorEngine(_parameters, new ResearchExecutor(_parameters));
            WireEvents();

            var guarantee = _engine.HardBreakevenGuarantee;
            Log($"SingleAnchor hard-BE guarantee: qualified={guarantee.Qualified}; scope: {guarantee.Scope} Assumptions: {string.Join("; ", guarantee.Assumptions)}. Not covered: {string.Join("; ", guarantee.NotCovered)}." +
                (guarantee.UnqualifiedReasons.Count > 0 ? " Not qualified because: " + string.Join(" ", guarantee.UnqualifiedReasons) : string.Empty));
            foreach (var decision in OpenDecisions)
            {
                Log($"SingleAnchor open owner decision ({decision["id"]}): {decision["question"]} Current behaviour: {decision["currentBehaviour"]}");
            }

            Log($"SingleAnchor vNext on {_symbol} ({_securityType}, {_market}) tick quotes; LEAN is the data host, fills are the research executor's, no LEAN order is placed.");
            var p = _parameters;
            Log($"SingleAnchor parameters: step {F(p.StepPercent)}%, base lot {F(p.BaseLot)}, Nnormal {p.NormalTradeCount}, hard-BE ceiling {F(p.HardBreakevenCeilingPercent)}%, " +
                $"escape {(p.EscapeEnabled ? F(p.EscapeProfitUnits) + " units, min " + p.EscapeMinimumOpenPositions + " positions" : "off")}, " +
                $"fixed TP {(p.FixedTakeProfitUnits > 0m ? F(p.FixedTakeProfitUnits) + " units" : "off")}, " +
                $"trailing {(p.TrailingEnabled ? F(p.TrailingActivationUnits) + "/" + F(p.TrailingDropUnits) + " units" : "off")}, " +
                $"commission buffer {F(p.CommissionBuffer)}, point value {F(p.PointValuePerLot)}/lot, volume step {F(p.VolumeStep)} [{F(p.MinimumVolume)}, {F(p.MaximumVolume)}], " +
                $"commission {F(p.CommissionPerLot)}/lot round trip, slippage {F(p.Slippage)}, target spread {F(p.ProjectedSpread!.Value)}, " +
                $"swap buy {F(p.BuySwapPerLotPerDay)} / sell {F(p.SellSwapPerLotPerDay)} per lot per day at {p.SwapRolloverTimeOfDay} (triple: {(p.TripleSwapDay.HasValue ? p.TripleSwapDay.Value.ToString() : "none")}).");
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
                _feed.Feed(ticks, _engine);
            }
            catch (SingleAnchorRunException failure)
            {
                // LEAN ends the run on the rethrow without calling OnEndOfAlgorithm, so the
                // results are written here, with the failure recorded. Both kinds (a strategy
                // invariant, a data-quality condition) end the run the same way.
                Error($"SingleAnchor {failure.Kind} failure ({failure.Condition}): {failure.Message}");
                Log($"SingleAnchor run stopped by the {failure.Condition} condition at {failure.Quote}.");
                WriteResults(new RunFailure(failure.Kind, failure.Condition, failure.Quote, failure.Message));
                throw;
            }
        }

        /// <inheritdoc />
        public override void OnEndOfAlgorithm()
        {
            Log($"SingleAnchor end of data: {_engine.QuotesProcessed} quote ticks processed ({_feed.NonQuoteTicks} non-quote ticks unused), {_engine.EntriesOpened} legs opened, {_engine.EntriesRejected} distinct rejected entries ({_engine.RejectedEntryAttempts} attempts), {_engine.BasketsClosed} baskets closed, realized profit {F(_engine.RealizedProfit)}.");

            var snapshot = CurrentBasketSnapshot();
            var basket = _engine.Basket;
            if (basket == null || snapshot == null)
            {
                Log("SingleAnchor end of data: no basket open.");
            }
            else if (basket.OpenPositions == 0)
            {
                Log($"SingleAnchor end of data: basket #{snapshot.Sequence} anchored at {F(snapshot.Anchor)} (upper {F(snapshot.Upper)}, lower {F(snapshot.Lower)}) with no open leg.");
            }
            else
            {
                Log($"SingleAnchor end of data: open basket #{snapshot.Sequence} marked to market at {snapshot.Quote} (not closed): {snapshot.OpenPositions} legs, buy {F(snapshot.BuyLots)} / sell {F(snapshot.SellLots)} / gross {F(snapshot.GrossLots)} / net {F(snapshot.NetLots)} lots, raw profit {F(snapshot.RawProfit!.Value)}, exit profit {F(snapshot.ExitProfit!.Value)}, executable profit {(snapshot.ExecutableProfit.HasValue ? F(snapshot.ExecutableProfit.Value) : "n/a (a needed executable close price is not positive)")}, step money {F(snapshot.StepMoney!.Value)}, hard-BE mode {snapshot.HardBreakevenModeActive}, trailing {snapshot.TrailingActive} (peak {F(snapshot.PeakProfit)}).");
                foreach (var leg in basket.Legs)
                {
                    Log($"SingleAnchor open leg: {leg}");
                }
            }

            WriteResults(null);
        }

        private sealed record RunFailure(string Kind, string Condition, Quote Quote, string Message);

        /// <summary>
        /// Strategy-definition questions the specification leaves open and the owner has not yet
        /// decided. They are written into every results file so no run is read as if they were
        /// settled. The current behaviour is not the strategy; it is what the code does meanwhile.
        /// </summary>
        public static readonly IReadOnlyList<IReadOnlyDictionary<string, string>> OpenDecisions = new[]
        {
            new Dictionary<string, string>
            {
                ["id"] = "BothBoundariesOnOneQuote",
                ["question"] = "How is a first-entry quote that satisfies both entry rules (Ask >= Upper and Bid <= Lower) to be treated? The specification defines no rule; no priority, no skip and no double entry has been approved.",
                ["currentBehaviour"] = "the engine stops the run (StrategyInvariant BothBoundariesSatisfied) rather than choose; this stop is not an approved strategy rule."
            },
            new Dictionary<string, string>
            {
                ["id"] = "HardTargetPriceMeaning",
                ["question"] = "Is T_up / T_down a midpoint target, with the configured target spread split around it (Bid = T - spread/2, Ask = T + spread/2) to obtain the executable prices of the projection? The specification defines T only as the maximum permitted breakeven price.",
                ["currentBehaviour"] = "T is treated as a midpoint and the configured spread is split symmetrically around it; this reading is not yet approved."
            }
        };

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
                ["hardBreakevenGuarantee"] = _engine.HardBreakevenGuarantee,
                ["openOwnerDecisions"] = OpenDecisions,
                ["symbol"] = _symbol.Value,
                ["market"] = _market,
                ["quoteTimeZone"] = Securities[_symbol].Exchange.TimeZone.Id,
                ["startDate"] = _startDate,
                ["endDate"] = _endDate,
                ["parameters"] = _parameters,
                ["quoteTicksProcessed"] = _engine.QuotesProcessed,
                ["nonQuoteTicksUnused"] = _feed.NonQuoteTicks,
                ["lastProcessedQuote"] = _engine.LastProcessedQuote,
                ["legsOpened"] = _engine.EntriesOpened,
                ["distinctRejectedEntries"] = _engine.EntriesRejected,
                ["rejectedEntryAttempts"] = _engine.RejectedEntryAttempts,
                ["basketsClosed"] = _engine.BasketsClosed,
                ["realizedProfit"] = _engine.RealizedProfit,
                ["closedBaskets"] = _engine.ClosedBaskets,
                ["openBasket"] = CurrentBasketSnapshot(),
                ["openBasketLegs"] = _engine.OpenBasketLegTrace()
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
            _engine.AnchorCreated += e => Log($"SingleAnchor basket #{e.Basket.Sequence} anchor {F(e.Basket.Anchor)} at {e.Quote}: upper {F(e.Basket.Upper)}, lower {F(e.Basket.Lower)}, hard-BE targets {F(e.Basket.LowerTarget)} / {F(e.Basket.UpperTarget)}.");
            _engine.EntryOpened += e => Log($"SingleAnchor leg opened: {e.Leg}; basket buy {F(e.Basket.BuyLots)} / sell {F(e.Basket.SellLots)} / net {F(e.Basket.NetLots)} lots" + (e.Sizing != null ? "; " + e.Sizing.Message : string.Empty));
            _engine.EntryRejected += e => Error($"SingleAnchor entry rejected ({e.Rejection.Reason}) for trade {e.Rejection.TradeNumber} {e.Rejection.Side} of basket #{e.Basket.Sequence} at {e.Quote}: {e.Rejection.Message}");
            _engine.HardBreakevenViolated += e => Error($"SingleAnchor hard-BE violated by the fill of {e.Leg} in basket #{e.Basket.Sequence}: projected executable P/L at target {F(e.Sizing.Target.Target)} is {F(e.ProjectedProfitAfterFill)} after the fill (sizing expected {F(e.Sizing.ProjectedProfitAfter)}); the run stops.");
            _engine.TrailingActivated += e => Log($"SingleAnchor trailing activated at profit {F(e.Profit)} (threshold {F(e.ActivationThreshold)}) at {e.Quote}.");
            _engine.BasketClosed += e => Log($"SingleAnchor basket #{e.Record.Sequence} closed by {e.Record.Reason} at {e.Quote}: {e.Record.Legs} legs, raw profit {F(e.Record.RawProfit)}, exit profit {F(e.Record.ExitProfit)} vs threshold {F(e.Record.Threshold)}, realized {F(e.Record.RealizedProfit)} (buys closed {F(e.Record.BuyClosePrice)}, sells closed {F(e.Record.SellClosePrice)}, swap {F(e.Record.Swap)}, commission {F(e.Record.Commission)}); realized total {F(_engine.RealizedProfit)}.");
            _engine.BasketCloseFailed += e => Error($"SingleAnchor close ({e.Reason}) failed at {e.Quote}: {e.Message}");
        }

        private static string F(decimal value)
        {
            return value.ToString(CultureInfo.InvariantCulture);
        }
    }
}
