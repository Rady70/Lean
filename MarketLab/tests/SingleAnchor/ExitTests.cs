using System;
using NUnit.Framework;

namespace MarketLab.SingleAnchor.Tests
{
    /// <summary>
    /// Two-leg reference basket: BUY 0.01 @ 2020, SELL 0.02 @ 1980, net -0.01, so E = 0.01 and
    /// M_step = 20 * 0.01 * 100 = 20. With ask = bid + 0.2 the basket profit is
    /// (bid - 2020) * 0.01 * 100 + (1980 - bid - 0.2) * 0.02 * 100 = 1939.6 - bid.
    /// </summary>
    internal static class TwoLegs
    {
        public static Harness Build(SingleAnchorParameters? parameters = null, decimal? researchInitialBalance = null)
        {
            var h = new Harness(parameters, null, researchInitialBalance);
            h.Anchor();
            h.AtUpper();
            h.AtLower();
            Assert.That(h.Engine.Basket!.OpenPositions, Is.EqualTo(2));
            return h;
        }

        /// <summary>Bid that gives the two-leg basket the wanted profit in account currency.</summary>
        public static decimal BidForProfit(decimal profit)
        {
            return 1939.6m - profit;
        }
    }

    [TestFixture]
    public class EscapeExitTests
    {
        [Test]
        public void EscapeClosesAtExactlyTheThresholdAndNotBelowIt()
        {
            var h = TwoLegs.Build();
            var basket = h.Engine.Basket!;

            var below = h.Feed(TwoLegs.BidForProfit(0.99m), TwoLegs.BidForProfit(0.99m) + 0.2m);
            Assert.That(h.Engine.Basket, Is.SameAs(basket));
            Assert.That(h.BasketsClosed, Is.Empty);
            Assert.That(BasketEconomics.ExitProfit(basket, below, h.Parameters), Is.EqualTo(0.99m));

            var at = h.Feed(TwoLegs.BidForProfit(1m), TwoLegs.BidForProfit(1m) + 0.2m);
            Assert.That(h.BasketsClosed, Has.Count.EqualTo(1));
            var closed = h.BasketsClosed[0];
            Assert.That(closed.Record.Reason, Is.EqualTo(ExitReason.Escape));
            Assert.That(closed.Record.Threshold, Is.EqualTo(1m), "0.05 units * 20 step money");
            Assert.That(closed.Record.ExitProfit, Is.EqualTo(1m));
            Assert.That(closed.Quote, Is.EqualTo(at));
            Assert.That(closed.Basket, Is.SameAs(basket));
            Assert.That(h.Executor.Closes, Has.Count.EqualTo(1));
            Assert.That(h.Executor.Closes[0].Reason, Is.EqualTo(ExitReason.Escape));
            Assert.That(h.Engine.Basket, Is.Null);
        }

        [Test]
        public void EscapeNeedsAtLeastTwoOpenPositions()
        {
            var h = new Harness(Harness.NoExits() with { EscapeEnabled = true });
            h.Anchor();
            h.AtUpper();                         // one leg, BUY 0.01 @ 2020
            h.Feed(2100m, 2100.2m);              // profit 80, far above 1
            Assert.That(h.BasketsClosed, Is.Empty);
            Assert.That(h.Engine.Basket!.OpenPositions, Is.EqualTo(1));

            // a minimum of one open position violates the specification and is refused
            Assert.Throws<ArgumentException>(() => new Harness(Harness.NoExits() with { EscapeEnabled = true, EscapeMinimumOpenPositions = 1 }));

            // the same two-leg basket escapes at the specified minimum of two
            var two = TwoLegs.Build(Harness.NoExits() with { EscapeEnabled = true });
            two.Feed(1900m, 1900.2m);            // profit 39.6 >= escape 1
            Assert.That(two.BasketsClosed, Has.Count.EqualTo(1));
            Assert.That(two.BasketsClosed[0].Record.Reason, Is.EqualTo(ExitReason.Escape));
        }

        [Test]
        public void EscapeDisabledDoesNotClose()
        {
            var h = TwoLegs.Build(Harness.NoExits());
            h.Feed(1900m, 1900.2m);              // profit 39.6
            Assert.That(h.BasketsClosed, Is.Empty);
            Assert.That(h.Engine.Basket!.OpenPositions, Is.EqualTo(2));
        }

        [Test]
        public void EscapeThresholdScalesWithNetExposure()
        {
            var h = new Harness();
            var basket = h.PingPongFourLegs();   // net -0.02 -> M_step 40 -> escape 2
            // profit = 100 * (0.04 * (bid - 2020) + 0.06 * (1980 - bid - 0.2)) = 100 * (37.988 - 0.02 * bid)
            var bid = (37.988m - 0.02m) / 0.02m; // profit 2
            h.Feed(bid, bid + 0.2m);
            Assert.That(h.BasketsClosed, Has.Count.EqualTo(1));
            Assert.That(h.BasketsClosed[0].Record.Threshold, Is.EqualTo(2m));
            Assert.That(h.BasketsClosed[0].Record.ExitProfit, Is.EqualTo(2m));
            Assert.That(h.BasketsClosed[0].Basket, Is.SameAs(basket));
        }
    }

    [TestFixture]
    public class FixedTakeProfitTests
    {
        [Test]
        public void ZeroUnitsDisablesFixedTakeProfit()
        {
            var h = TwoLegs.Build(Harness.NoExits());
            h.Feed(1800m, 1800.2m);              // profit 139.6
            Assert.That(h.BasketsClosed, Is.Empty);
        }

        [Test]
        public void FixedTakeProfitClosesAtItsThreshold()
        {
            var h = TwoLegs.Build(Harness.NoExits() with { FixedTakeProfitUnits = 2m }); // 2 * 20 = 40
            h.Feed(TwoLegs.BidForProfit(39m), TwoLegs.BidForProfit(39m) + 0.2m);
            Assert.That(h.BasketsClosed, Is.Empty);

            h.Feed(TwoLegs.BidForProfit(40m), TwoLegs.BidForProfit(40m) + 0.2m);
            Assert.That(h.BasketsClosed, Has.Count.EqualTo(1));
            Assert.That(h.BasketsClosed[0].Record.Reason, Is.EqualTo(ExitReason.FixedTakeProfit));
            Assert.That(h.BasketsClosed[0].Record.Threshold, Is.EqualTo(40m));
            Assert.That(h.Engine.Basket, Is.Null);
        }
    }

    [TestFixture]
    public class TrailingTests
    {
        /// <summary>One BUY 0.01 @ 2020: M_step 20, activation 10, drop 5; profit = (bid - 2020).</summary>
        private static Harness OneLong(SingleAnchorParameters? parameters = null)
        {
            var h = new Harness(parameters);
            h.Anchor();
            h.AtUpper();
            return h;
        }

        [Test]
        public void TrailingActivatesAtTheActivationThreshold()
        {
            var h = OneLong();
            var basket = h.Engine.Basket!;

            h.Feed(2029.99m, 2030.19m);          // profit 9.99
            Assert.That(basket.TrailingActive, Is.False);
            Assert.That(h.TrailingActivations, Is.Empty);

            var quote = h.Feed(2030m, 2030.2m); // profit 10
            Assert.That(basket.TrailingActive, Is.True);
            Assert.That(basket.PeakProfit, Is.EqualTo(10m));
            Assert.That(h.TrailingActivations, Has.Count.EqualTo(1));
            Assert.That(h.TrailingActivations[0].ActivationThreshold, Is.EqualTo(10m));
            Assert.That(h.TrailingActivations[0].Quote, Is.EqualTo(quote));
            Assert.That(h.BasketsClosed, Is.Empty, "activation alone does not close");
        }

        [Test]
        public void PeakFollowsNewHighsOnly()
        {
            var h = OneLong();
            var basket = h.Engine.Basket!;
            h.Feed(2030m, 2030.2m);              // activate, peak 10
            h.Feed(2050m, 2050.2m);              // 30
            Assert.That(basket.PeakProfit, Is.EqualTo(30m));
            h.Feed(2048m, 2048.2m);              // 28: no new high, no close (floor 25)
            Assert.That(basket.PeakProfit, Is.EqualTo(30m));
            Assert.That(h.BasketsClosed, Is.Empty);
            h.Feed(2055m, 2055.2m);              // 35
            Assert.That(basket.PeakProfit, Is.EqualTo(35m));
        }

        [Test]
        public void TrailingClosesWhenProfitFallsByTheConfiguredDropFromThePeak()
        {
            var h = OneLong();
            h.Feed(2030m, 2030.2m);              // activate
            h.Feed(2050m, 2050.2m);              // peak 30, floor 25
            h.Feed(2045.01m, 2045.21m);          // 25.01: not yet
            Assert.That(h.BasketsClosed, Is.Empty);

            var quote = h.Feed(2045m, 2045.2m); // 25 <= 25
            Assert.That(h.BasketsClosed, Has.Count.EqualTo(1));
            var closed = h.BasketsClosed[0];
            Assert.That(closed.Record.Reason, Is.EqualTo(ExitReason.Trailing));
            Assert.That(closed.Record.Threshold, Is.EqualTo(25m), "peak 30 minus 0.25 units * 20");
            Assert.That(closed.Record.ExitProfit, Is.EqualTo(25m));
            Assert.That(closed.Quote, Is.EqualTo(quote));
        }

        [Test]
        public void TrailingDisabledNeverActivates()
        {
            var h = OneLong(Harness.NoExits());
            h.Feed(2100m, 2100.2m);
            h.Feed(2000m, 2000.2m);
            Assert.That(h.Engine.Basket!.TrailingActive, Is.False);
            Assert.That(h.BasketsClosed, Is.Empty);
        }

        [Test]
        public void ANewGridTradeDoesNotResetTrailingState()
        {
            var h = OneLong(Harness.Defaults() with { TrailingDropUnits = 10m }); // drop 200: a return to Lower does not close
            var basket = h.Engine.Basket!;
            h.Feed(2035m, 2035.2m);              // activate, peak 15
            Assert.That(basket.TrailingActive, Is.True);

            h.AtLower();                         // SELL 0.02 @ 1980 added, profit -40 > 15 - 200
            Assert.That(basket.OpenPositions, Is.EqualTo(2));
            Assert.That(basket.TrailingActive, Is.True);
            Assert.That(basket.PeakProfit, Is.EqualTo(15m));
            Assert.That(h.BasketsClosed, Is.Empty);
        }

        [Test]
        public void ZeroDropClosesOnTheActivationQuote()
        {
            var h = OneLong(Harness.Defaults() with { TrailingDropUnits = 0m });
            h.Feed(2030m, 2030.2m);
            Assert.That(h.BasketsClosed, Has.Count.EqualTo(1));
            Assert.That(h.BasketsClosed[0].Record.Reason, Is.EqualTo(ExitReason.Trailing));
        }
    }

    [TestFixture]
    public class ExitPriorityTests
    {
        [Test]
        public void AnExitOnAQuoteThatAlsoTriggersAnEntryClosesWithoutOpeningTheLeg()
        {
            var h = new Harness();
            h.Anchor();
            h.AtUpper();                         // BUY 0.01 @ 2020
            h.Feed(2035m, 2035.2m);              // trailing active, peak 15, floor 10
            var basket = h.Engine.Basket!;

            var quote = h.AtLower();             // profit -40 <= 10 AND bid <= Lower

            Assert.That(h.BasketsClosed, Has.Count.EqualTo(1));
            Assert.That(h.BasketsClosed[0].Record.Reason, Is.EqualTo(ExitReason.Trailing));
            Assert.That(h.BasketsClosed[0].Quote, Is.EqualTo(quote));
            Assert.That(basket.OpenPositions, Is.EqualTo(1), "no SELL was added to the closing basket");
            Assert.That(h.Executor.Entries, Has.Count.EqualTo(1));
            Assert.That(h.Engine.Basket, Is.Null, "no replacement basket on the closing quote");
            Assert.That(h.AnchorsCreated, Has.Count.EqualTo(1));
        }

        [Test]
        public void EscapeIsEvaluatedBeforeFixedTakeProfit()
        {
            var h = TwoLegs.Build(Harness.Defaults() with { FixedTakeProfitUnits = 1m }); // TP 20, escape 1
            h.Feed(1900m, 1900.2m);              // profit 39.6 satisfies both
            Assert.That(h.BasketsClosed[0].Record.Reason, Is.EqualTo(ExitReason.Escape));

            var noEscape = TwoLegs.Build(Harness.Defaults() with { EscapeEnabled = false, FixedTakeProfitUnits = 1m });
            noEscape.Feed(1900m, 1900.2m);
            Assert.That(noEscape.BasketsClosed[0].Record.Reason, Is.EqualTo(ExitReason.FixedTakeProfit));
        }

        /// <summary>
        /// With a constant M_step the fixed take-profit and the trailing close can never fire on the
        /// same quote (the peak is below the TP threshold whenever trailing is active and TP is not).
        /// A new leg that shrinks the net exposure shrinks M_step, so both thresholds move: the host
        /// fills BUY 0.05 @ 2020 (M_step 100: TP 100, activation 50, drop 300), trailing activates at
        /// profit 95, then SELL 0.04 @ 1980 leaves net +0.01 (M_step 20: TP 20, drop 60, floor 35).
        /// At profit 30 both TP (>= 20) and trailing (<= 35) fire; the order of evaluation decides.
        /// </summary>
        private static Harness TakeProfitAndTrailingBothFiring(decimal fixedTakeProfitUnits)
        {
            var h = new Harness(Harness.Defaults() with { BaseLot = 0.05m, EscapeEnabled = false, FixedTakeProfitUnits = fixedTakeProfitUnits, TrailingDropUnits = 3m });
            h.Anchor();
            h.AtUpper();                          // BUY 0.05 @ 2020
            h.Feed(2039m, 2039.2m);               // profit 95: trailing active, peak 95
            var basket = h.Engine.Basket!;
            Assert.That(basket.TrailingActive, Is.True);
            Assert.That(basket.PeakProfit, Is.EqualTo(95m));
            // a SELL 0.04 leg added straight to the ledger: net +0.01 shrinks M_step from 100 to 20
            basket.AddLeg(new BasketLeg(2, TradeSide.Sell, 0.04m, 1980m, Harness.T0.AddSeconds(3), SizingRegime.Arithmetic));
            Assert.That(basket.OpenPositions, Is.EqualTo(2));
            Assert.That(basket.NetLots, Is.EqualTo(0.01m));
            Assert.That(BasketEconomics.StepMoney(basket, h.Parameters), Is.EqualTo(20m));
            Assert.That(basket.TrailingActive, Is.True, "a new leg does not reset trailing");
            Assert.That(basket.PeakProfit, Is.EqualTo(95m));
            Assert.That(h.BasketsClosed, Is.Empty);
            return h;
        }

        [Test]
        public void FixedTakeProfitIsEvaluatedBeforeTrailing()
        {
            var h = TakeProfitAndTrailingBothFiring(1m);
            var quote = h.Feed(2210.8m, 2211m);   // profit 5 * 190.8 + 4 * (1980 - 2211) = 30
            Assert.That(h.BasketsClosed, Has.Count.EqualTo(1));
            Assert.That(h.BasketsClosed[0].Record.ExitProfit, Is.EqualTo(30m));
            Assert.That(h.BasketsClosed[0].Record.Reason, Is.EqualTo(ExitReason.FixedTakeProfit));
            Assert.That(h.BasketsClosed[0].Record.Threshold, Is.EqualTo(20m));
            Assert.That(h.BasketsClosed[0].Quote, Is.EqualTo(quote));
        }

        [Test]
        public void TrailingClosesTheSameQuoteWhenFixedTakeProfitIsDisabled()
        {
            var h = TakeProfitAndTrailingBothFiring(0m);
            h.Feed(2210.8m, 2211m);
            Assert.That(h.BasketsClosed, Has.Count.EqualTo(1));
            Assert.That(h.BasketsClosed[0].Record.Reason, Is.EqualTo(ExitReason.Trailing));
            Assert.That(h.BasketsClosed[0].Record.Threshold, Is.EqualTo(35m), "peak 95 minus 3 units * 20");
        }

        [Test]
        public void TrailingRunsWhenEscapeAndTakeProfitDoNotClose()
        {
            var h = TwoLegs.Build(Harness.Defaults() with { EscapeEnabled = false }); // TP off
            h.Feed(TwoLegs.BidForProfit(12m), TwoLegs.BidForProfit(12m) + 0.2m); // activate, peak 12, floor 7
            h.Feed(TwoLegs.BidForProfit(7m), TwoLegs.BidForProfit(7m) + 0.2m);
            Assert.That(h.BasketsClosed[0].Record.Reason, Is.EqualTo(ExitReason.Trailing));
        }
    }
}
