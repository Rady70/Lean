using System;
using NUnit.Framework;

namespace MarketLab.SingleAnchor.Tests
{
    [TestFixture]
    public class BasketAccountingTests
    {
        [Test]
        public void BuySellGrossAndNetLotsAreKeptApart()
        {
            var h = new Harness();
            var basket = h.PingPongFourLegs();

            Assert.That(basket.BuyLots, Is.EqualTo(0.04m));
            Assert.That(basket.SellLots, Is.EqualTo(0.06m));
            Assert.That(basket.GrossLots, Is.EqualTo(0.10m));
            Assert.That(basket.NetLots, Is.EqualTo(-0.02m));
            Assert.That(basket.IsNetFlat, Is.False);
            Assert.That(basket.SmallestOpenLots, Is.EqualTo(0.01m));
            Assert.That(basket.OpenPositions, Is.EqualTo(4));
            Assert.That(BasketEconomics.ExitSensitivityLots(basket), Is.EqualTo(0.02m));
            Assert.That(BasketEconomics.StepMoney(basket, h.Parameters), Is.EqualTo(40m));
        }

        [Test]
        public void EntryPricesAndSequenceAreRetainedPerLeg()
        {
            var h = new Harness();
            var basket = h.PingPongFourLegs();

            for (var i = 0; i < 4; i++)
            {
                Assert.That(basket.Legs[i].TradeNumber, Is.EqualTo(i + 1));
            }
            Assert.That(basket.Legs[0].EntryPrice, Is.EqualTo(2020m));
            Assert.That(basket.Legs[1].EntryPrice, Is.EqualTo(1980m));
            Assert.That(basket.Legs[2].EntryPrice, Is.EqualTo(2020m));
            Assert.That(basket.Legs[3].EntryPrice, Is.EqualTo(1980m));
            Assert.That(basket.Legs[1].EntryTime, Is.GreaterThan(basket.Legs[0].EntryTime));
        }

        [Test]
        public void NetFlatBasketUsesTheSmallestOpenLotAsExitSensitivity()
        {
            var h = new Harness();
            // the host fills trade 2 with 0.01 instead of the requested 0.02: the ledger records the fill
            h.Executor.EntryOverride = o => ExecutionResult.Fill(o.Side == TradeSide.Buy ? o.Quote.Ask : o.Quote.Bid, 0.01m);
            h.Anchor();
            h.AtUpper();
            h.AtLower();

            var basket = h.Engine.Basket!;
            Assert.That(basket.BuyLots, Is.EqualTo(0.01m));
            Assert.That(basket.SellLots, Is.EqualTo(0.01m));
            Assert.That(basket.NetLots, Is.EqualTo(0m));
            Assert.That(basket.IsNetFlat, Is.True);
            Assert.That(BasketEconomics.ExitSensitivityLots(basket), Is.EqualTo(0.01m));
            Assert.That(BasketEconomics.StepMoney(basket, h.Parameters), Is.EqualTo(20m));
        }

        [Test]
        public void RawProfitMarksBuysAtBidAndSellsAtAsk()
        {
            var h = new Harness();
            h.Anchor();
            h.AtUpper();  // BUY 0.01 @ 2020
            h.AtLower();  // SELL 0.02 @ 1980
            var basket = h.Engine.Basket!;

            var quote = new Quote(Harness.T0.AddMinutes(1), 2000m, 2000.3m);
            var raw = BasketEconomics.RawProfit(basket, quote, h.Parameters);

            // (2000 - 2020) * 0.01 * 100 + (1980 - 2000.3) * 0.02 * 100
            Assert.That(raw, Is.EqualTo(-20m + -40.6m));
            Assert.That(BasketEconomics.CurrentLegProfit(basket.Legs[0], quote, 100m), Is.EqualTo(-20m));
            Assert.That(BasketEconomics.CurrentLegProfit(basket.Legs[1], quote, 100m), Is.EqualTo(-40.6m));
        }

        [Test]
        public void CommissionBufferIsAFlatAmountPlusAnAmountPerGrossLot()
        {
            var h = new Harness(new SingleAnchorParameters
            {
                StepPercent = 1m,
                BaseLot = 0.01m,
                PointValuePerLot = 100m,
                CommissionBuffer = 3m,
                CommissionBufferPerLot = 7m
            });
            h.Anchor();
            h.AtUpper();
            h.AtLower();
            var basket = h.Engine.Basket!;

            var quote = new Quote(Harness.T0.AddMinutes(1), 2000m, 2000.3m);
            Assert.That(BasketEconomics.CommissionBufferAmount(basket, h.Parameters), Is.EqualTo(3m + 7m * 0.03m));
            Assert.That(BasketEconomics.RawProfit(basket, quote, h.Parameters), Is.EqualTo(-60.6m));
            Assert.That(BasketEconomics.ExitProfit(basket, quote, h.Parameters), Is.EqualTo(-60.6m - 3.21m));

            var valuation = h.Engine.MarkToMarket(quote)!;
            Assert.That(valuation.RawProfit, Is.EqualTo(-60.6m));
            Assert.That(valuation.ExitProfit, Is.EqualTo(-63.81m));
        }

        [Test]
        public void FlatCommissionBufferAloneMatchesTheSpecificationFormula()
        {
            var h = TwoLegs.Build(Harness.Defaults() with { CommissionBuffer = 0.5m }); // escape threshold 1
            // profit 1.4 raw - 0.5 buffer = 0.9: no escape; raw 1.5 - 0.5 = 1.0: escape
            h.Feed(TwoLegs.BidForProfit(1.4m), TwoLegs.BidForProfit(1.4m) + 0.2m);
            Assert.That(h.BasketsClosed, Is.Empty);
            h.Feed(TwoLegs.BidForProfit(1.5m), TwoLegs.BidForProfit(1.5m) + 0.2m);
            Assert.That(h.BasketsClosed, Has.Count.EqualTo(1));
            Assert.That(h.BasketsClosed[0].RawProfit, Is.EqualTo(1.5m));
            Assert.That(h.BasketsClosed[0].ExitProfit, Is.EqualTo(1m));
        }

        [Test]
        public void StepMoneyIsUndefinedWithoutLegs()
        {
            var h = new Harness();
            h.Anchor();
            Assert.Throws<InvalidOperationException>(() => BasketEconomics.StepMoney(h.Engine.Basket!, h.Parameters));
        }
    }

    [TestFixture]
    public class SwapAccrualTests
    {
        private static SingleAnchorParameters WithBuySwap(decimal buySwap, DayOfWeek? triple = DayOfWeek.Wednesday)
        {
            return new SingleAnchorParameters
            {
                StepPercent = 1m,
                BaseLot = 0.01m,
                PointValuePerLot = 100m,
                BuySwapPerLotPerDay = buySwap,
                SwapRolloverTimeOfDay = new TimeSpan(17, 0, 0),
                TripleSwapDay = triple
            };
        }

        private static readonly DateTime Tuesday = new DateTime(2024, 1, 2, 10, 0, 0);

        [Test]
        public void SwapAccruesAtWeekdayRolloversWithTripleOnTheConfiguredDay()
        {
            var h = new Harness(WithBuySwap(-2m));
            h.FeedAt(Tuesday, 1999.9m, 2000.1m);
            h.FeedAt(Tuesday.AddSeconds(1), 2019.8m, 2020m);       // BUY 0.01 @ 2020
            var leg = h.Engine.Basket!.Legs[0];
            Assert.That(h.Engine.Basket!.NextRolloverTime, Is.EqualTo(new DateTime(2024, 1, 2, 17, 0, 0)));

            h.FeedAt(new DateTime(2024, 1, 2, 16, 59, 59), 2000m, 2000.2m);
            Assert.That(leg.AccruedSwap, Is.EqualTo(0m));

            h.FeedAt(new DateTime(2024, 1, 2, 17, 0, 0), 2000m, 2000.2m);   // Tuesday closes: 1x
            Assert.That(leg.AccruedSwap, Is.EqualTo(-0.02m));

            h.FeedAt(new DateTime(2024, 1, 3, 17, 0, 0), 2000m, 2000.2m);   // Wednesday closes: 3x
            Assert.That(leg.AccruedSwap, Is.EqualTo(-0.08m));

            h.FeedAt(new DateTime(2024, 1, 4, 17, 0, 0), 2000m, 2000.2m);   // Thursday
            Assert.That(leg.AccruedSwap, Is.EqualTo(-0.10m));
            h.FeedAt(new DateTime(2024, 1, 5, 17, 0, 0), 2000m, 2000.2m);   // Friday
            Assert.That(leg.AccruedSwap, Is.EqualTo(-0.12m));
            h.FeedAt(new DateTime(2024, 1, 6, 17, 0, 0), 2000m, 2000.2m);   // Saturday: not charged
            h.FeedAt(new DateTime(2024, 1, 7, 17, 0, 0), 2000m, 2000.2m);   // Sunday: not charged
            Assert.That(leg.AccruedSwap, Is.EqualTo(-0.12m));
            h.FeedAt(new DateTime(2024, 1, 8, 17, 0, 0), 2000m, 2000.2m);   // Monday
            Assert.That(leg.AccruedSwap, Is.EqualTo(-0.14m));

            var quote = new Quote(new DateTime(2024, 1, 8, 18, 0, 0), 2020m, 2020.2m);
            Assert.That(BasketEconomics.RawProfit(h.Engine.Basket!, quote, h.Parameters), Is.EqualTo(-0.14m), "raw profit includes accrued swap");
        }

        [Test]
        public void GapOverSeveralRolloversAccruesThemAllAtOnce()
        {
            var h = new Harness(WithBuySwap(-2m));
            h.FeedAt(Tuesday, 1999.9m, 2000.1m);
            h.FeedAt(Tuesday.AddSeconds(1), 2019.8m, 2020m);
            h.FeedAt(new DateTime(2024, 1, 8, 18, 0, 0), 2000m, 2000.2m);

            Assert.That(h.Engine.Basket!.Legs[0].AccruedSwap, Is.EqualTo(-0.14m));
            Assert.That(h.Engine.Basket!.NextRolloverTime, Is.EqualTo(new DateTime(2024, 1, 9, 17, 0, 0)));
        }

        [Test]
        public void LegOpenedExactlyAtTheRolloverIsChargedFromTheNextOne()
        {
            var h = new Harness(WithBuySwap(-2m));
            h.FeedAt(new DateTime(2024, 1, 2, 16, 59, 59), 1999.9m, 2000.1m);
            h.FeedAt(new DateTime(2024, 1, 2, 17, 0, 0), 2019.8m, 2020m);   // BUY at the rollover instant
            Assert.That(h.Engine.Basket!.NextRolloverTime, Is.EqualTo(new DateTime(2024, 1, 3, 17, 0, 0)));

            h.FeedAt(new DateTime(2024, 1, 2, 17, 0, 1), 2000m, 2000.2m);
            Assert.That(h.Engine.Basket!.Legs[0].AccruedSwap, Is.EqualTo(0m));
            h.FeedAt(new DateTime(2024, 1, 3, 17, 0, 0), 2000m, 2000.2m);
            Assert.That(h.Engine.Basket!.Legs[0].AccruedSwap, Is.EqualTo(-0.06m));
        }

        [Test]
        public void SellLegsUseTheSellRateAndLaterLegsAreChargedFromTheirOwnNextRollover()
        {
            var h = new Harness(new SingleAnchorParameters
            {
                StepPercent = 1m,
                BaseLot = 0.01m,
                PointValuePerLot = 100m,
                BuySwapPerLotPerDay = -2m,
                SellSwapPerLotPerDay = 1m,
                TripleSwapDay = null
            });
            h.FeedAt(Tuesday, 1999.9m, 2000.1m);
            h.FeedAt(Tuesday.AddSeconds(1), 2019.8m, 2020m);               // BUY 0.01
            h.FeedAt(new DateTime(2024, 1, 2, 17, 0, 0), 2000m, 2000.2m);  // Tuesday rollover: buy -0.02
            h.FeedAt(new DateTime(2024, 1, 2, 18, 0, 0), 1980m, 1980.2m);  // SELL 0.02 after the rollover
            h.FeedAt(new DateTime(2024, 1, 3, 17, 0, 0), 2000m, 2000.2m);  // Wednesday rollover, no triple

            var basket = h.Engine.Basket!;
            Assert.That(basket.Legs[0].AccruedSwap, Is.EqualTo(-0.04m));
            Assert.That(basket.Legs[1].AccruedSwap, Is.EqualTo(0.02m));
        }

        [Test]
        public void LegFilledAfterTheRolloverInstantIsNotChargedForIt()
        {
            var h = new Harness(WithBuySwap(-2m, null) with { SellSwapPerLotPerDay = 1m });
            h.FeedAt(Tuesday, 1999.9m, 2000.1m);
            h.FeedAt(Tuesday.AddSeconds(1), 2019.8m, 2020m);                       // BUY 0.01, charged from Tue 17:00
            h.Executor.EntryOverride = _ => ExecutionResult.Pending();
            h.FeedAt(new DateTime(2024, 1, 2, 16, 59, 59), 1980m, 1980.2m);      // SELL 0.02 submitted, pending
            h.Engine.ConfirmPendingEntry(1980m, 0.02m, new DateTime(2024, 1, 2, 17, 0, 30)); // filled after the rollover

            h.FeedAt(new DateTime(2024, 1, 2, 17, 1, 0), 2000m, 2000.2m);        // Tuesday rollover is processed now

            var basket = h.Engine.Basket!;
            Assert.That(basket.Legs[0].AccruedSwap, Is.EqualTo(-0.02m));
            Assert.That(basket.Legs[1].AccruedSwap, Is.EqualTo(0m), "opened after the rollover instant");
            h.FeedAt(new DateTime(2024, 1, 3, 17, 0, 0), 2000m, 2000.2m);
            Assert.That(basket.Legs[1].AccruedSwap, Is.EqualTo(0.02m));
        }

        [Test]
        public void NoSwapConfiguredMeansNoAccrualAndNoRolloverTracking()
        {
            var h = new Harness();
            h.FeedAt(Tuesday, 1999.9m, 2000.1m);
            h.FeedAt(Tuesday.AddSeconds(1), 2019.8m, 2020m);
            h.FeedAt(new DateTime(2024, 1, 9, 18, 0, 0), 2000m, 2000.2m);

            Assert.That(h.Engine.Basket!.NextRolloverTime, Is.Null);
            Assert.That(h.Engine.Basket!.Legs[0].AccruedSwap, Is.EqualTo(0m));
        }
    }
}
