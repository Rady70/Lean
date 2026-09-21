using System;
using System.Globalization;
using QuantConnect.Orders;

namespace MarketLab.SingleAnchor
{
    /// <summary>
    /// What LEAN reports when a market order is submitted, reduced to the fields the executor uses.
    /// <paramref name="AverageFillPrice"/> and <paramref name="QuantityFilled"/> are the ticket's
    /// cumulative values at the time the submission call returns.
    /// </summary>
    public readonly record struct OrderSubmission(int OrderId, OrderStatus Status, decimal AverageFillPrice, decimal QuantityFilled, string? Error);

    /// <summary>
    /// The thin surface of the LEAN algorithm that <see cref="LeanBasketExecutor"/> needs, so the
    /// executor's order bookkeeping can be tested without an engine run.
    /// </summary>
    public interface ILeanOrderGateway
    {
        /// <summary>Submits a market order for the strategy symbol; positive units buy, negative sell.</summary>
        OrderSubmission SubmitMarketOrder(decimal signedUnits, string tag);

        /// <summary>LEAN's current signed net holding of the strategy symbol, in units.</summary>
        decimal HoldingQuantity { get; }

        /// <summary>Converts a UTC order-event time to the clock the engine's quotes use.</summary>
        DateTime ToQuoteClock(DateTime utcTime);
    }

    /// <summary>
    /// Executes the engine's decisions as LEAN market orders and feeds LEAN's order events back to
    /// the engine. Lots are converted to LEAN units with the configured units per lot. LEAN nets
    /// the symbol into one holding; the engine's basket ledger stays the strategy's view, and a
    /// basket close is one order that flattens whatever LEAN holds.
    /// </summary>
    /// <remarks>
    /// In a LEAN backtest at this revision a market order is filled inside the <c>MarketOrder</c>
    /// call itself: the backtesting transaction handler drains the request queue on the algorithm
    /// thread and scans the backtesting brokerage, and the Submitted and Filled order events are
    /// delivered to the algorithm's OnOrderEvent during that call, before the ticket is returned.
    /// The returned ticket is therefore already <see cref="OrderStatus.Filled"/> and the executor
    /// reports a completed fill at the ticket's average price. A ticket that comes back open (for
    /// example when LEAN converts the order to market-on-open because it considers the exchange
    /// closed, a partial fill under a non-default fill model, or another host) is reported as
    /// <see cref="ExecutionStatus.Pending"/> and resolved from the later order events, with the
    /// quantity already filled at submission time carried over into the volume-weighted total.
    /// </remarks>
    public sealed class LeanBasketExecutor : IBasketExecutor
    {
        private readonly ILeanOrderGateway _gateway;
        private readonly decimal _unitsPerLot;
        private SingleAnchorEngine? _engine;
        private int _pendingEntryOrderId;
        private int _pendingCloseOrderId;
        private decimal _filledUnits;
        private decimal _filledNotional;

        /// <summary>
        /// Creates the executor for one symbol.
        /// </summary>
        public LeanBasketExecutor(ILeanOrderGateway gateway, decimal unitsPerLot)
        {
            _gateway = gateway ?? throw new ArgumentNullException(nameof(gateway));
            if (unitsPerLot <= 0m) throw new ArgumentOutOfRangeException(nameof(unitsPerLot), unitsPerLot, "Units per lot must be positive.");
            _unitsPerLot = unitsPerLot;
        }

        /// <summary>Order id of the entry awaiting a fill, or 0.</summary>
        public int PendingEntryOrderId => _pendingEntryOrderId;

        /// <summary>Order id of the close awaiting a fill, or 0.</summary>
        public int PendingCloseOrderId => _pendingCloseOrderId;

        /// <summary>
        /// Connects the engine whose pending operations this executor resolves.
        /// </summary>
        public void Attach(SingleAnchorEngine engine)
        {
            _engine = engine ?? throw new ArgumentNullException(nameof(engine));
        }

        /// <summary>Lots to LEAN units, signed by side.</summary>
        public decimal ToSignedUnits(TradeSide side, decimal lots)
        {
            var units = lots * _unitsPerLot;
            return side == TradeSide.Buy ? units : -units;
        }

        /// <summary>LEAN units to lots (absolute).</summary>
        public decimal ToLots(decimal units)
        {
            return Math.Abs(units) / _unitsPerLot;
        }

        /// <inheritdoc />
        public ExecutionResult OpenPosition(EntryOrder order)
        {
            if (order == null) throw new ArgumentNullException(nameof(order));
            if (_pendingEntryOrderId != 0 || _pendingCloseOrderId != 0)
            {
                return ExecutionResult.Failure("An order is already pending; the entry was not submitted.");
            }

            var submission = _gateway.SubmitMarketOrder(ToSignedUnits(order.Side, order.Lots),
                $"SingleAnchor trade {order.TradeNumber} {order.Side} {F(order.Lots)} lots ({order.Regime})");
            return Track(submission, isEntry: true);
        }

        /// <inheritdoc />
        public ExecutionResult CloseBasket(CloseOrder order)
        {
            if (order == null) throw new ArgumentNullException(nameof(order));
            if (_pendingEntryOrderId != 0 || _pendingCloseOrderId != 0)
            {
                return ExecutionResult.Failure("An order is already pending; the close was not submitted.");
            }

            var held = _gateway.HoldingQuantity;
            if (held == 0m)
            {
                // A net-flat basket has nothing to flatten in LEAN's netted holding; the
                // strategy-level close is complete as soon as the ledger resets.
                return ExecutionResult.Fill(0m, 0m, "Net-flat in LEAN; no flattening order needed.");
            }

            var submission = _gateway.SubmitMarketOrder(-held, $"SingleAnchor close ({order.Reason}) flatten {F(held)} units");
            return Track(submission, isEntry: false);
        }

        /// <summary>
        /// Routes LEAN order events for the pending orders to the engine. Call from the
        /// algorithm's OnOrderEvent; events for other orders, including the synchronous events
        /// LEAN raises before a submission call returns, are ignored.
        /// </summary>
        public void OnOrderEvent(OrderEvent orderEvent)
        {
            if (orderEvent == null) throw new ArgumentNullException(nameof(orderEvent));
            var engine = _engine ?? throw new InvalidOperationException("Attach the engine before order events arrive.");

            var isEntry = orderEvent.OrderId == _pendingEntryOrderId && _pendingEntryOrderId != 0;
            var isClose = orderEvent.OrderId == _pendingCloseOrderId && _pendingCloseOrderId != 0;
            if (!isEntry && !isClose)
            {
                return;
            }

            switch (orderEvent.Status)
            {
                case OrderStatus.PartiallyFilled:
                    Accumulate(orderEvent.AbsoluteFillQuantity, orderEvent.FillPrice);
                    break;

                case OrderStatus.Filled:
                    Accumulate(orderEvent.AbsoluteFillQuantity, orderEvent.FillPrice);
                    CompletePending(engine, isEntry, orderEvent);
                    break;

                case OrderStatus.Invalid:
                case OrderStatus.Canceled:
                    var message = $"LEAN order {orderEvent.OrderId} ended {orderEvent.Status}: {orderEvent.Message}";
                    if (isEntry && _filledUnits > 0m)
                    {
                        // Part of the entry is held by LEAN: the ledger records what was filled.
                        CompletePending(engine, true, orderEvent);
                    }
                    else
                    {
                        ClearPending();
                        if (isEntry)
                        {
                            engine.RejectPendingEntry(message);
                        }
                        else
                        {
                            // Any partial flatten stays in LEAN's holding; the exit is re-evaluated
                            // on the next quote and a retry flattens whatever is left.
                            engine.RejectPendingClose(message);
                        }
                    }
                    break;
            }
        }

        private void CompletePending(SingleAnchorEngine engine, bool isEntry, OrderEvent orderEvent)
        {
            var averagePrice = _filledUnits > 0m ? _filledNotional / _filledUnits : orderEvent.FillPrice;
            var lots = ToLots(_filledUnits);
            ClearPending();
            if (isEntry)
            {
                engine.ConfirmPendingEntry(averagePrice, lots, _gateway.ToQuoteClock(orderEvent.UtcTime));
            }
            else
            {
                engine.ConfirmPendingClose(averagePrice);
            }
        }

        private void Accumulate(decimal absoluteUnits, decimal fillPrice)
        {
            _filledUnits += absoluteUnits;
            _filledNotional += absoluteUnits * fillPrice;
        }

        private void ClearPending()
        {
            _pendingEntryOrderId = 0;
            _pendingCloseOrderId = 0;
            _filledUnits = 0m;
            _filledNotional = 0m;
        }

        private ExecutionResult Track(OrderSubmission submission, bool isEntry)
        {
            if (submission.Status == OrderStatus.Invalid)
            {
                return ExecutionResult.Failure($"LEAN rejected order {submission.OrderId}: {submission.Error ?? "marked invalid on submission."}");
            }

            if (submission.Status == OrderStatus.Filled)
            {
                // The backtesting path: LEAN filled the market order inside the submission call.
                return ExecutionResult.Fill(submission.AverageFillPrice, ToLots(submission.QuantityFilled));
            }

            if (isEntry) _pendingEntryOrderId = submission.OrderId; else _pendingCloseOrderId = submission.OrderId;
            // Fills LEAN already reported synchronously (a partially filled ticket) are carried
            // over; the events for them were raised before this order was being tracked.
            _filledUnits = Math.Abs(submission.QuantityFilled);
            _filledNotional = _filledUnits * submission.AverageFillPrice;
            return ExecutionResult.Pending($"LEAN order {submission.OrderId} submitted ({submission.Status}); the fill is applied from its order events.");
        }

        private static string F(decimal value)
        {
            return value.ToString(CultureInfo.InvariantCulture);
        }
    }
}
