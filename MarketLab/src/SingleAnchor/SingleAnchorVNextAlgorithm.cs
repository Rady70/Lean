using System;
using System.Globalization;
using QuantConnect;
using QuantConnect.Algorithm;
using QuantConnect.Data;
using QuantConnect.Data.Market;
using QuantConnect.Orders;
using QuantConnect.Parameters;
using QuantConnect.Securities;

namespace MarketLab.SingleAnchor
{
    /// <summary>
    /// LEAN host for the SingleAnchor vNext strategy on bid/ask quote ticks of one symbol
    /// (XAUUSD by default). The algorithm only adapts: it subscribes, hands each quote to
    /// <see cref="SingleAnchorEngine"/>, executes through <see cref="LeanBasketExecutor"/> and logs
    /// the engine's events. Every strategy input is a LEAN parameter (config `parameters` object or
    /// the MarketLab helper's -Parameters), named below; <c>single-anchor-step-percent</c> and
    /// <c>single-anchor-base-lot</c> have no specified default and must be given.
    /// </summary>
    /// <remarks>
    /// The default dates cover the 13-day Oanda XAUUSD tick sample that upstream ships under
    /// <c>Data\cfd\oanda\tick\xauusd</c> (May 2014, an engine fixture); set them to the coverage
    /// of whatever data folder is used. At the end of the data an open basket is reported marked
    /// to market, not liquidated.
    /// </remarks>
    public class SingleAnchorVNextAlgorithm : QCAlgorithm
    {
        // ---- Host / instrument ----
        [Parameter("single-anchor-symbol")] private string _ticker = "XAUUSD";
        [Parameter("single-anchor-market")] private string _market = Market.Oanda;
        [Parameter("single-anchor-security-type")] private string _securityType = "Cfd";
        [Parameter("single-anchor-start-date")] private string _startDate = "2014-05-02";
        [Parameter("single-anchor-end-date")] private string _endDate = "2014-05-14";
        [Parameter("single-anchor-cash")] private decimal _cash = 100000m;
        [Parameter("single-anchor-leverage")] private decimal _leverage = 50m;
        [Parameter("single-anchor-units-per-lot")] private decimal _unitsPerLot = 100m;

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
        [Parameter("single-anchor-commission-buffer-per-lot")] private decimal _commissionBufferPerLot = 0m;
        [Parameter("single-anchor-point-value-per-lot")] private decimal _pointValuePerLot = 100m;
        [Parameter("single-anchor-volume-step")] private decimal _volumeStep = 0.01m;
        [Parameter("single-anchor-minimum-volume")] private decimal _minimumVolume = 0.01m;
        [Parameter("single-anchor-maximum-volume")] private decimal _maximumVolume = 100m;
        [Parameter("single-anchor-commission-per-lot")] private decimal _commissionPerLot = 0m;
        [Parameter("single-anchor-slippage")] private decimal _slippage = 0m;
        [Parameter("single-anchor-use-observed-spread")] private bool _useObservedSpreadForProjection = true;
        [Parameter("single-anchor-projected-spread")] private decimal _projectedSpread = 0m;
        [Parameter("single-anchor-buy-swap-per-lot-per-day")] private decimal _buySwapPerLotPerDay = 0m;
        [Parameter("single-anchor-sell-swap-per-lot-per-day")] private decimal _sellSwapPerLotPerDay = 0m;
        [Parameter("single-anchor-swap-rollover-time")] private string _swapRolloverTime = "1700";
        [Parameter("single-anchor-triple-swap-day")] private string _tripleSwapDay = "Wednesday";

        private Symbol _symbol = null!;
        private SingleAnchorEngine _engine = null!;
        private LeanBasketExecutor _executor = null!;
        private Quote? _lastQuote;
        private long _quoteSlices;
        private long _supersededTicks;
        private long _invalidTicks;

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
                security = AddForex(_ticker, Resolution.Tick, _market, fillForward: false, leverage: _leverage);
            }
            else if (string.Equals(_securityType, "Cfd", StringComparison.OrdinalIgnoreCase))
            {
                security = AddCfd(_ticker, Resolution.Tick, _market, fillForward: false, leverage: _leverage);
            }
            else
            {
                throw new ArgumentException($"single-anchor-security-type must be Cfd or Forex (got '{_securityType}').");
            }
            _symbol = security.Symbol;
            // Benchmark the traded symbol itself so the run needs no unrelated (SPY) data.
            SetBenchmark(_symbol);

            var parameters = new SingleAnchorParameters
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
                CommissionBufferPerLot = _commissionBufferPerLot,
                PointValuePerLot = _pointValuePerLot,
                VolumeStep = _volumeStep,
                MinimumVolume = _minimumVolume,
                MaximumVolume = _maximumVolume,
                CommissionPerLot = _commissionPerLot,
                Slippage = _slippage,
                UseObservedSpreadForProjection = _useObservedSpreadForProjection,
                ProjectedSpread = _projectedSpread,
                BuySwapPerLotPerDay = _buySwapPerLotPerDay,
                SellSwapPerLotPerDay = _sellSwapPerLotPerDay,
                SwapRolloverTimeOfDay = ParameterParsing.ParseTimeOfDay(_swapRolloverTime, "single-anchor-swap-rollover-time"),
                TripleSwapDay = ParameterParsing.ParseOptionalDayOfWeek(_tripleSwapDay, "single-anchor-triple-swap-day")
            };
            var errors = parameters.GetValidationErrors();
            if (errors.Count > 0)
            {
                throw new ArgumentException("SingleAnchor parameters are invalid (see the single-anchor-* parameters): " + string.Join(" ", errors));
            }

            if (_unitsPerLot <= 0m)
            {
                throw new ArgumentException($"single-anchor-units-per-lot must be > 0 (got {F(_unitsPerLot)}).");
            }
            var lotSize = security.SymbolProperties.LotSize;
            var stepUnits = parameters.VolumeStep * _unitsPerLot;
            if (lotSize > 0m && decimal.Remainder(stepUnits, lotSize) != 0m)
            {
                throw new ArgumentException($"One volume step ({F(parameters.VolumeStep)} lots = {F(stepUnits)} units) is not a whole multiple of LEAN's lot size {F(lotSize)} for {_symbol}; adjust single-anchor-volume-step or single-anchor-units-per-lot.");
            }

            _executor = new LeanBasketExecutor(new Gateway(this), _unitsPerLot);
            _engine = new SingleAnchorEngine(parameters, _executor);
            _executor.Attach(_engine);
            WireEvents();

            Log($"SingleAnchor vNext on {_symbol} ({_securityType}, {_market}) tick quotes, {F(_unitsPerLot)} units per lot, LEAN lot size {F(lotSize)}, leverage {F(_leverage)}.");
            Log($"SingleAnchor parameters: step {F(parameters.StepPercent)}%, base lot {F(parameters.BaseLot)}, Nnormal {parameters.NormalTradeCount}, hard-BE ceiling {F(parameters.HardBreakevenCeilingPercent)}%, " +
                $"escape {(parameters.EscapeEnabled ? F(parameters.EscapeProfitUnits) + " units, min " + parameters.EscapeMinimumOpenPositions + " positions" : "off")}, " +
                $"fixed TP {(parameters.FixedTakeProfitUnits > 0m ? F(parameters.FixedTakeProfitUnits) + " units" : "off")}, " +
                $"trailing {(parameters.TrailingEnabled ? F(parameters.TrailingActivationUnits) + "/" + F(parameters.TrailingDropUnits) + " units" : "off")}, " +
                $"commission buffer {F(parameters.CommissionBuffer)} + {F(parameters.CommissionBufferPerLot)}/lot, point value {F(parameters.PointValuePerLot)}/lot, volume step {F(parameters.VolumeStep)} [{F(parameters.MinimumVolume)}, {F(parameters.MaximumVolume)}], " +
                $"commission {F(parameters.CommissionPerLot)}/lot round trip, slippage {F(parameters.Slippage)}, projected spread {(parameters.UseObservedSpreadForProjection ? "observed" : F(parameters.ProjectedSpread))}, " +
                $"swap buy {F(parameters.BuySwapPerLotPerDay)} / sell {F(parameters.SellSwapPerLotPerDay)} per lot per day at {parameters.SwapRolloverTimeOfDay} (triple: {(parameters.TripleSwapDay.HasValue ? parameters.TripleSwapDay.Value.ToString() : "none")}).");
        }

        /// <inheritdoc />
        public override void OnData(Slice slice)
        {
            if (slice == null || !slice.Ticks.TryGetValue(_symbol, out var ticks))
            {
                return;
            }

            // Every tick in the slice shares its timestamp; the last valid quote tick is the market
            // state LEAN will fill against, so it is the one the engine decides on. Earlier ticks
            // of the same timestamp are superseded, invalid ones ignored; both are counted.
            Tick? last = null;
            for (var i = 0; i < ticks.Count; i++)
            {
                var tick = ticks[i];
                if (tick.TickType == TickType.Quote && tick.BidPrice > 0m && tick.AskPrice > 0m && tick.AskPrice >= tick.BidPrice)
                {
                    if (last != null) _supersededTicks++;
                    last = tick;
                }
                else
                {
                    _invalidTicks++;
                }
            }
            if (last == null)
            {
                return;
            }

            _quoteSlices++;
            var quote = new Quote(last.Time, last.BidPrice, last.AskPrice);
            _lastQuote = quote;
            _engine.OnQuote(quote);
        }

        /// <inheritdoc />
        public override void OnOrderEvent(OrderEvent orderEvent)
        {
            if (orderEvent == null) return;
            if (orderEvent.Status == OrderStatus.Filled || orderEvent.Status == OrderStatus.Invalid || orderEvent.Status == OrderStatus.Canceled)
            {
                Log($"LEAN order {orderEvent.OrderId} {orderEvent.Status}: {orderEvent.Direction} {F(orderEvent.AbsoluteFillQuantity)} units @ {F(orderEvent.FillPrice)} fee {orderEvent.OrderFee} {orderEvent.Message}");
            }
            _executor.OnOrderEvent(orderEvent);
        }

        /// <inheritdoc />
        public override void OnEndOfAlgorithm()
        {
            Log($"SingleAnchor end of data: {_quoteSlices} quote slices used, {_supersededTicks} earlier same-timestamp quote ticks superseded, {_invalidTicks} invalid ticks ignored, {_engine.QuotesProcessed} quotes processed, {_engine.EntriesOpened} legs opened, {_engine.EntriesRejected} distinct rejected entries ({_engine.RejectedEntryAttempts} attempts), {_engine.BasketsClosed} baskets closed.");

            var basket = _engine.Basket;
            if (basket == null)
            {
                Log("SingleAnchor end of data: no basket open.");
                return;
            }
            if (basket.OpenPositions == 0)
            {
                Log($"SingleAnchor end of data: basket anchored at {F(basket.Anchor)} (upper {F(basket.Upper)}, lower {F(basket.Lower)}) with no open leg.");
                return;
            }

            var valuation = _lastQuote.HasValue ? _engine.MarkToMarket(_lastQuote.Value) : null;
            if (valuation == null)
            {
                Log($"SingleAnchor end of data: basket left open with {basket.OpenPositions} legs and no quote to mark it; not force-closed.");
                return;
            }
            Log($"SingleAnchor end of data: open basket marked to market at {valuation.Quote} (not force-closed): {valuation.OpenPositions} legs, buy {F(valuation.BuyLots)} / sell {F(valuation.SellLots)} / gross {F(valuation.GrossLots)} / net {F(valuation.NetLots)} lots, raw profit {F(valuation.RawProfit)}, exit profit {F(valuation.ExitProfit)}, step money {F(valuation.StepMoney)}, hard-BE mode {valuation.HardBreakevenModeActive}, trailing {valuation.TrailingActive} (peak {F(valuation.PeakProfit)}); LEAN holding {F(Portfolio[_symbol].Quantity)} units.");
            foreach (var leg in basket.Legs)
            {
                Log($"SingleAnchor open leg: {leg}");
            }
            if (_engine.HasPendingExecution)
            {
                Log("SingleAnchor end of data: an order was still pending with LEAN.");
            }
        }

        private void WireEvents()
        {
            _engine.AnchorCreated += e => Log($"SingleAnchor anchor {F(e.Basket.Anchor)} at {e.Quote}: upper {F(e.Basket.Upper)}, lower {F(e.Basket.Lower)}, hard-BE targets {F(e.Basket.LowerTarget)} / {F(e.Basket.UpperTarget)}.");
            _engine.EntryPending += e => Log($"SingleAnchor trade {e.Order.TradeNumber} {e.Order.Side} {F(e.Order.Lots)} lots submitted at {e.Order.Quote} ({e.Order.Regime}); awaiting the fill.");
            _engine.EntryOpened += e => Log($"SingleAnchor leg opened: {e.Leg}; basket buy {F(e.Basket.BuyLots)} / sell {F(e.Basket.SellLots)} / net {F(e.Basket.NetLots)} lots" + (e.Sizing != null ? "; " + e.Sizing.Message : string.Empty));
            _engine.EntryRejected += e => Error($"SingleAnchor entry rejected ({e.Rejection.Reason}) for trade {e.Rejection.TradeNumber} {e.Rejection.Side} at {e.Quote}: {e.Rejection.Message}");
            _engine.TrailingActivated += e => Log($"SingleAnchor trailing activated at profit {F(e.Profit)} (threshold {F(e.ActivationThreshold)}) at {e.Quote}.");
            _engine.BasketClosePending += e => Log($"SingleAnchor close ({e.Reason}) submitted at {e.Quote}; awaiting the fill.");
            _engine.BasketClosed += e => Log($"SingleAnchor basket closed by {e.Reason} at {e.Quote}: {e.Basket.OpenPositions} legs, raw profit {F(e.RawProfit)}, exit profit {F(e.ExitProfit)} vs threshold {F(e.Threshold)}" + (e.HostFillPrice.HasValue ? $", LEAN flatten fill {F(e.HostFillPrice.Value)}" : ", no LEAN order (net-flat)") + ".");
            _engine.BasketCloseFailed += e => Error($"SingleAnchor close ({e.Reason}) failed at {e.Quote}: {e.Message}");
            _engine.InvalidQuote += e => Error($"SingleAnchor {e.Message} ({e.Quote})");
            _engine.QuoteSkippedWhilePending += e => Log($"SingleAnchor {e.Message} ({e.Quote})");
        }

        /// <summary>
        /// The executor's view of this algorithm: one symbol, market orders, the netted holding
        /// and the exchange clock the quotes are stamped in.
        /// </summary>
        private sealed class Gateway : ILeanOrderGateway
        {
            private readonly SingleAnchorVNextAlgorithm _algorithm;

            public Gateway(SingleAnchorVNextAlgorithm algorithm)
            {
                _algorithm = algorithm;
            }

            public decimal HoldingQuantity => _algorithm.Portfolio[_algorithm._symbol].Quantity;

            public OrderSubmission SubmitMarketOrder(decimal signedUnits, string tag)
            {
                var ticket = _algorithm.MarketOrder(_algorithm._symbol, signedUnits, asynchronous: false, tag: tag);
                var response = ticket.SubmitRequest?.Response;
                var error = response != null && response.IsError ? $"{response.ErrorCode}: {response.ErrorMessage}" : null;
                return new OrderSubmission(ticket.OrderId, ticket.Status, ticket.AverageFillPrice, ticket.QuantityFilled, error);
            }

            public DateTime ToQuoteClock(DateTime utcTime)
            {
                return utcTime.ConvertFromUtc(_algorithm.Securities[_algorithm._symbol].Exchange.TimeZone);
            }
        }

        private static string F(decimal value)
        {
            return value.ToString(CultureInfo.InvariantCulture);
        }
    }
}
