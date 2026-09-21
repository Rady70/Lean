using System;
using System.Collections.Generic;
using NUnit.Framework;
using QuantConnect;
using QuantConnect.Orders;
using QuantConnect.Orders.Fees;

namespace MarketLab.SingleAnchor.Tests
{
    /// <summary>
    /// Stands in for the LEAN algorithm: records submissions, answers with a scripted status and
    /// exposes a settable holding.
    /// </summary>
    internal sealed class FakeGateway : ILeanOrderGateway
    {
        private int _nextOrderId = 1;

        public List<(decimal Units, string Tag)> Submissions { get; } = new List<(decimal, string)>();
        public OrderStatus NextStatus { get; set; } = OrderStatus.Submitted;
        public string? NextError { get; set; }
        public decimal NextQuantityFilled { get; set; }
        public decimal NextAverageFillPrice { get; set; }
        public decimal HoldingQuantity { get; set; }
        public int LastOrderId { get; private set; }

        public OrderSubmission SubmitMarketOrder(decimal signedUnits, string tag)
        {
            Submissions.Add((signedUnits, tag));
            LastOrderId = _nextOrderId++;
            if (NextStatus == OrderStatus.Filled)
            {
                return new OrderSubmission(LastOrderId, NextStatus, 2020.5m, signedUnits, NextError);
            }
            return new OrderSubmission(LastOrderId, NextStatus, NextAverageFillPrice, NextQuantityFilled, NextError);
        }

        public DateTime ToQuoteClock(DateTime utcTime)
        {
            return utcTime.AddHours(-5);
        }
    }

    [TestFixture]
    public class LeanBasketExecutorTests
    {
        private static readonly Symbol Xauusd = Symbol.Create("XAUUSD", SecurityType.Cfd, Market.Oanda);

        private sealed class Setup
        {
            public FakeGateway Gateway { get; } = new FakeGateway();
            public LeanBasketExecutor Executor { get; }
            public SingleAnchorEngine Engine { get; }
            public List<EntryOpenedEvent> Opened { get; } = new List<EntryOpenedEvent>();
            public List<EntryRejectedEvent> Rejected { get; } = new List<EntryRejectedEvent>();
            public List<BasketClosedEvent> Closed { get; } = new List<BasketClosedEvent>();
            public List<BasketCloseFailedEvent> CloseFailed { get; } = new List<BasketCloseFailedEvent>();
            private int _tick;

            public Setup()
            {
                Executor = new LeanBasketExecutor(Gateway, 100m);
                Engine = new SingleAnchorEngine(Harness.Defaults(), Executor);
                Executor.Attach(Engine);
                Engine.EntryOpened += e => Opened.Add(e);
                Engine.EntryRejected += e => Rejected.Add(e);
                Engine.BasketClosed += e => Closed.Add(e);
                Engine.BasketCloseFailed += e => CloseFailed.Add(e);
            }

            public void Feed(decimal bid, decimal ask)
            {
                Engine.OnQuote(new Quote(Harness.T0.AddSeconds(_tick++), bid, ask));
            }

            public OrderEvent Event(int orderId, OrderStatus status, decimal fillPrice, decimal fillQuantity, string message = "")
            {
                var direction = fillQuantity >= 0m ? OrderDirection.Buy : OrderDirection.Sell;
                return new OrderEvent(orderId, Xauusd, new DateTime(2024, 1, 2, 15, 0, 0, DateTimeKind.Utc), status, direction, fillPrice, fillQuantity, OrderFee.Zero, message);
            }
        }

        [Test]
        public void UnitConversionUsesUnitsPerLotAndSide()
        {
            var executor = new LeanBasketExecutor(new FakeGateway(), 100m);
            Assert.That(executor.ToSignedUnits(TradeSide.Buy, 0.01m), Is.EqualTo(1m));
            Assert.That(executor.ToSignedUnits(TradeSide.Sell, 0.13m), Is.EqualTo(-13m));
            Assert.That(executor.ToLots(-13m), Is.EqualTo(0.13m));
            Assert.That(executor.ToLots(1m), Is.EqualTo(0.01m));
            Assert.Throws<ArgumentOutOfRangeException>(() => new LeanBasketExecutor(new FakeGateway(), 0m));
        }

        [Test]
        public void EntryIsSubmittedAsSignedUnitsAndPendingUntilTheFillEventArrives()
        {
            var s = new Setup();
            s.Feed(1999.9m, 2000.1m);
            s.Feed(2019.8m, 2020m);                       // BUY 0.01 -> +1 unit

            Assert.That(s.Gateway.Submissions, Has.Count.EqualTo(1));
            Assert.That(s.Gateway.Submissions[0].Units, Is.EqualTo(1m));
            Assert.That(s.Gateway.Submissions[0].Tag, Does.Contain("trade 1 Buy 0.01"));
            Assert.That(s.Executor.PendingEntryOrderId, Is.EqualTo(s.Gateway.LastOrderId));
            Assert.That(s.Engine.HasPendingExecution, Is.True);
            Assert.That(s.Engine.Basket!.OpenPositions, Is.EqualTo(0));

            s.Executor.OnOrderEvent(s.Event(s.Gateway.LastOrderId, OrderStatus.Submitted, 0m, 0m));
            Assert.That(s.Engine.HasPendingExecution, Is.True, "a Submitted event changes nothing");

            s.Executor.OnOrderEvent(s.Event(s.Gateway.LastOrderId, OrderStatus.Filled, 2020.05m, 1m));

            Assert.That(s.Executor.PendingEntryOrderId, Is.EqualTo(0));
            Assert.That(s.Engine.HasPendingExecution, Is.False);
            var leg = s.Engine.Basket!.Legs[0];
            Assert.That(leg.Lots, Is.EqualTo(0.01m));
            Assert.That(leg.EntryPrice, Is.EqualTo(2020.05m));
            Assert.That(leg.EntryTime, Is.EqualTo(new DateTime(2024, 1, 2, 10, 0, 0)), "fill time converted to the quote clock");
            Assert.That(s.Opened, Has.Count.EqualTo(1));
        }

        [Test]
        public void PartialFillsAreAccumulatedIntoOneVolumeWeightedFill()
        {
            var s = new Setup();
            s.Feed(1999.9m, 2000.1m);
            s.Feed(2019.8m, 2020m);
            var id = s.Gateway.LastOrderId;

            s.Executor.OnOrderEvent(s.Event(id, OrderStatus.PartiallyFilled, 2020m, 0.4m));
            Assert.That(s.Engine.HasPendingExecution, Is.True);
            s.Executor.OnOrderEvent(s.Event(id, OrderStatus.Filled, 2021m, 0.6m));

            var leg = s.Engine.Basket!.Legs[0];
            Assert.That(leg.Lots, Is.EqualTo(0.01m));
            Assert.That(leg.EntryPrice, Is.EqualTo(2020.6m));
        }

        [Test]
        public void FillsAlreadyOnTheTicketAtSubmissionAreCarriedIntoThePendingTotal()
        {
            var s = new Setup();
            s.Gateway.NextStatus = OrderStatus.PartiallyFilled;
            s.Gateway.NextQuantityFilled = 0.4m;
            s.Gateway.NextAverageFillPrice = 2020m;
            s.Feed(1999.9m, 2000.1m);
            s.Feed(2019.8m, 2020m);
            Assert.That(s.Engine.HasPendingExecution, Is.True, "a partially filled ticket is pending");

            // the event for the 0.4 units was raised before tracking started; only the rest arrives now
            s.Executor.OnOrderEvent(s.Event(s.Gateway.LastOrderId, OrderStatus.Filled, 2021m, 0.6m));

            var leg = s.Engine.Basket!.Legs[0];
            Assert.That(leg.Lots, Is.EqualTo(0.01m));
            Assert.That(leg.EntryPrice, Is.EqualTo(2020.6m));
        }

        [Test]
        public void CancelAfterAPartialFillRecordsWhatLeanHolds()
        {
            var s = new Setup();
            s.Feed(1999.9m, 2000.1m);
            s.Feed(2019.8m, 2020m);
            var id = s.Gateway.LastOrderId;
            s.Executor.OnOrderEvent(s.Event(id, OrderStatus.PartiallyFilled, 2020m, 0.4m));

            s.Executor.OnOrderEvent(s.Event(id, OrderStatus.Canceled, 0m, 0m, "cancelled"));

            Assert.That(s.Engine.HasPendingExecution, Is.False);
            Assert.That(s.Rejected, Is.Empty);
            var leg = s.Engine.Basket!.Legs[0];
            Assert.That(leg.Lots, Is.EqualTo(0.004m), "the ledger holds the 0.4 units LEAN actually filled");
            Assert.That(leg.EntryPrice, Is.EqualTo(2020m));
        }

        [Test]
        public void CancelAfterAPartialCloseKeepsTheBasketForARetry()
        {
            var s = new Setup();
            s.Feed(1999.9m, 2000.1m);
            s.Feed(2019.8m, 2020m);
            s.Executor.OnOrderEvent(s.Event(s.Gateway.LastOrderId, OrderStatus.Filled, 2020m, 1m));
            s.Feed(2035m, 2035.2m);
            s.Gateway.HoldingQuantity = 1m;
            s.Feed(2025m, 2025.2m);                       // trailing close submitted
            var id = s.Gateway.LastOrderId;
            s.Executor.OnOrderEvent(s.Event(id, OrderStatus.PartiallyFilled, 2025m, -0.4m));

            s.Executor.OnOrderEvent(s.Event(id, OrderStatus.Canceled, 0m, 0m, "cancelled"));

            Assert.That(s.CloseFailed, Has.Count.EqualTo(1));
            Assert.That(s.Engine.Basket, Is.Not.Null);
            Assert.That(s.Engine.HasPendingExecution, Is.False);
            s.Gateway.HoldingQuantity = 0.6m;             // LEAN kept the unflattened remainder
            s.Feed(2025m, 2025.2m);                       // the exit fires again and flattens the rest
            Assert.That(s.Gateway.Submissions[^1].Units, Is.EqualTo(-0.6m));
        }

        [Test]
        public void EventsForOtherOrdersAreIgnored()
        {
            var s = new Setup();
            s.Feed(1999.9m, 2000.1m);
            s.Feed(2019.8m, 2020m);

            s.Executor.OnOrderEvent(s.Event(s.Gateway.LastOrderId + 100, OrderStatus.Filled, 1m, 1m));

            Assert.That(s.Engine.HasPendingExecution, Is.True);
            Assert.That(s.Engine.Basket!.OpenPositions, Is.EqualTo(0));
        }

        [Test]
        public void InvalidOrCanceledEventRejectsThePendingEntry()
        {
            var s = new Setup();
            s.Feed(1999.9m, 2000.1m);
            s.Feed(2019.8m, 2020m);

            s.Executor.OnOrderEvent(s.Event(s.Gateway.LastOrderId, OrderStatus.Invalid, 0m, 0m, "Insufficient buying power"));

            Assert.That(s.Engine.HasPendingExecution, Is.False);
            Assert.That(s.Rejected, Has.Count.EqualTo(1));
            Assert.That(s.Rejected[0].Rejection.Reason, Is.EqualTo(EntryRejectionReason.ExecutionFailed));
            Assert.That(s.Rejected[0].Rejection.Message, Does.Contain("Insufficient buying power"));
            Assert.That(s.Engine.Basket!.OpenPositions, Is.EqualTo(0));
        }

        [Test]
        public void SubmissionMarkedInvalidIsAFailureNotAPendingOrder()
        {
            var s = new Setup();
            s.Gateway.NextStatus = OrderStatus.Invalid;
            s.Gateway.NextError = "OrderQuantityZero: zero";
            s.Feed(1999.9m, 2000.1m);
            s.Feed(2019.8m, 2020m);

            Assert.That(s.Engine.HasPendingExecution, Is.False);
            Assert.That(s.Executor.PendingEntryOrderId, Is.EqualTo(0));
            Assert.That(s.Rejected, Has.Count.EqualTo(1));
            Assert.That(s.Rejected[0].Rejection.Message, Does.Contain("OrderQuantityZero"));
        }

        [Test]
        public void SynchronousFillIsReportedAsAFill()
        {
            var s = new Setup();
            s.Gateway.NextStatus = OrderStatus.Filled;
            s.Feed(1999.9m, 2000.1m);
            s.Feed(2019.8m, 2020m);

            Assert.That(s.Engine.HasPendingExecution, Is.False);
            Assert.That(s.Engine.Basket!.Legs[0].EntryPrice, Is.EqualTo(2020.5m));
            Assert.That(s.Engine.Basket!.Legs[0].Lots, Is.EqualTo(0.01m));
        }

        [Test]
        public void CloseFlattensTheNettedHoldingAndCompletesOnItsFill()
        {
            var s = new Setup();
            s.Feed(1999.9m, 2000.1m);
            s.Feed(2019.8m, 2020m);                       // BUY 0.01
            s.Executor.OnOrderEvent(s.Event(s.Gateway.LastOrderId, OrderStatus.Filled, 2020m, 1m));
            s.Feed(1980m, 1980.2m);                       // SELL 0.02
            s.Executor.OnOrderEvent(s.Event(s.Gateway.LastOrderId, OrderStatus.Filled, 1980m, -2m));
            s.Gateway.HoldingQuantity = -1m;              // LEAN nets +1 -2 into -1
            var basket = s.Engine.Basket!;

            s.Feed(1900m, 1900.2m);                       // escape

            Assert.That(s.Gateway.Submissions, Has.Count.EqualTo(3));
            Assert.That(s.Gateway.Submissions[2].Units, Is.EqualTo(1m), "buy back the net short");
            Assert.That(s.Gateway.Submissions[2].Tag, Does.Contain("close (Escape)"));
            Assert.That(s.Executor.PendingCloseOrderId, Is.EqualTo(s.Gateway.LastOrderId));
            Assert.That(s.Engine.Basket, Is.SameAs(basket));

            s.Executor.OnOrderEvent(s.Event(s.Gateway.LastOrderId, OrderStatus.Filled, 1900.2m, 1m));

            Assert.That(s.Engine.Basket, Is.Null);
            Assert.That(s.Closed, Has.Count.EqualTo(1));
            Assert.That(s.Closed[0].HostFillPrice, Is.EqualTo(1900.2m));
            Assert.That(s.Closed[0].ExitProfit, Is.EqualTo(39.6m), "strategy accounting at the closing quote");
            Assert.That(s.Executor.PendingCloseOrderId, Is.EqualTo(0));
        }

        [Test]
        public void NetFlatHoldingClosesWithoutAnOrder()
        {
            var s = new Setup();
            s.Feed(1999.9m, 2000.1m);
            s.Feed(2019.8m, 2020m);
            s.Executor.OnOrderEvent(s.Event(s.Gateway.LastOrderId, OrderStatus.Filled, 2020m, 1m));
            s.Feed(2035m, 2035.2m);                       // trailing active, peak 15
            s.Gateway.HoldingQuantity = 0m;               // pretend LEAN already shows flat

            s.Feed(2025m, 2025.2m);                       // profit 5 <= 10: trailing close

            Assert.That(s.Gateway.Submissions, Has.Count.EqualTo(1), "no flattening order");
            Assert.That(s.Engine.Basket, Is.Null);
            Assert.That(s.Closed, Has.Count.EqualTo(1));
            Assert.That(s.Closed[0].HostFillPrice, Is.Null);
        }

        [Test]
        public void RejectedCloseEventKeepsTheBasketOpen()
        {
            var s = new Setup();
            s.Feed(1999.9m, 2000.1m);
            s.Feed(2019.8m, 2020m);
            s.Executor.OnOrderEvent(s.Event(s.Gateway.LastOrderId, OrderStatus.Filled, 2020m, 1m));
            s.Feed(2035m, 2035.2m);
            s.Gateway.HoldingQuantity = 1m;
            s.Feed(2025m, 2025.2m);

            s.Executor.OnOrderEvent(s.Event(s.Gateway.LastOrderId, OrderStatus.Canceled, 0m, 0m, "cancelled"));

            Assert.That(s.CloseFailed, Has.Count.EqualTo(1));
            Assert.That(s.Engine.Basket, Is.Not.Null);
            Assert.That(s.Engine.HasPendingExecution, Is.False);
            Assert.That(s.Executor.PendingCloseOrderId, Is.EqualTo(0));
        }

        [Test]
        public void ASecondOrderWhileOneIsPendingIsRefusedWithoutSubmitting()
        {
            var gateway = new FakeGateway();
            var executor = new LeanBasketExecutor(gateway, 100m);
            var quote = new Quote(Harness.T0, 2019.8m, 2020m);
            var first = executor.OpenPosition(new EntryOrder(1, TradeSide.Buy, 0.01m, quote, SizingRegime.Arithmetic, null));
            Assert.That(first.Status, Is.EqualTo(ExecutionStatus.Pending));

            var second = executor.OpenPosition(new EntryOrder(2, TradeSide.Sell, 0.02m, quote, SizingRegime.Arithmetic, null));

            Assert.That(second.Status, Is.EqualTo(ExecutionStatus.Failed));
            Assert.That(gateway.Submissions, Has.Count.EqualTo(1));
        }

        [Test]
        public void OrderEventsBeforeAttachAreAProgrammingError()
        {
            var executor = new LeanBasketExecutor(new FakeGateway(), 100m);
            Assert.Throws<InvalidOperationException>(() => executor.OnOrderEvent(new OrderEvent()));
        }
    }
}
