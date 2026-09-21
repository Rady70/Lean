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
            var p = Harness.Defaults();
            var basket = new Basket(1, new Quote(Harness.T0, 1999.9m, 2000.1m), p);
            basket.AddLeg(new BasketLeg(1, TradeSide.Buy, 0.03m, 2020m, Harness.T0, SizingRegime.Arithmetic));
            basket.AddLeg(new BasketLeg(2, TradeSide.Sell, 0.01m, 1980m, Harness.T0, SizingRegime.Arithmetic));
            basket.AddLeg(new BasketLeg(3, TradeSide.Sell, 0.02m, 1980m, Harness.T0, SizingRegime.Arithmetic));

            Assert.That(basket.BuyLots, Is.EqualTo(0.03m));
            Assert.That(basket.SellLots, Is.EqualTo(0.03m));
            Assert.That(basket.NetLots, Is.EqualTo(0m));
            Assert.That(basket.IsNetFlat, Is.True);
            Assert.That(basket.SmallestOpenLots, Is.EqualTo(0.01m));
            Assert.That(BasketEconomics.ExitSensitivityLots(basket), Is.EqualTo(0.01m));
            Assert.That(BasketEconomics.StepMoney(basket, p), Is.EqualTo(20m));
        }

        [Test]
        public void LegVolumesMustBeWholeVolumeSteps()
        {
            var basket = new Basket(1, new Quote(Harness.T0, 1999.9m, 2000.1m), Harness.Defaults());
            Assert.Throws<InvalidOperationException>(() => basket.AddLeg(new BasketLeg(1, TradeSide.Buy, 0.015m, 2020m, Harness.T0, SizingRegime.Arithmetic)));
            Assert.That(basket.OpenPositions, Is.EqualTo(0));
        }

        [Test]
        public void AggregateValuationEqualsThePerLegSums()
        {
            var h = new Harness();
            var basket = h.PingPongFourLegs();
            h.AtUpper();                                   // BUY 0.06 @ 2020, hard-BE
            Assert.That(basket.OpenPositions, Is.EqualTo(5));
            Assert.That(basket.BuyNotional, Is.EqualTo(0.01m * 2020m + 0.03m * 2020m + 0.06m * 2020m));
            Assert.That(basket.SellNotional, Is.EqualTo(0.02m * 1980m + 0.04m * 1980m));

            var quote = new Quote(Harness.T0.AddMinutes(5), 2003.1m, 2003.37m);
            var perLeg = 0m;
            foreach (var leg in basket.Legs) perLeg += BasketEconomics.CurrentLegProfit(leg, quote, 100m);
            Assert.That(BasketEconomics.RawProfit(basket, quote, h.Parameters), Is.EqualTo(perLeg));

            var costly = h.Parameters with { CommissionPerLot = 7m, Slippage = 0.13m };
            var target = TargetPrices.ForLowerRecovery(basket.LowerTarget, 0.27m);
            var perLegProjected = 0m;
            foreach (var leg in basket.Legs) perLegProjected += BasketEconomics.ProjectedLegProfit(leg.Side, leg.Lots, leg.EntryPrice, target, costly);
            Assert.That(BasketEconomics.ProjectedExistingProfit(basket, target, costly), Is.EqualTo(perLegProjected));
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
        public void CommissionBufferIsAFlatAmountDeductedFromRawProfit()
        {
            var h = new Harness(new SingleAnchorParameters
            {
                StepPercent = 1m,
                BaseLot = 0.01m,
                PointValuePerLot = 100m,
                ProjectedSpread = 0.2m,
                CommissionBuffer = 3m
            });
            h.Anchor();
            h.AtUpper();
            h.AtLower();
            var basket = h.Engine.Basket!;

            var quote = new Quote(Harness.T0.AddMinutes(1), 2000m, 2000.3m);
            Assert.That(BasketEconomics.RawProfit(basket, quote, h.Parameters), Is.EqualTo(-60.6m));
            Assert.That(BasketEconomics.ExitProfit(basket, quote, h.Parameters), Is.EqualTo(-63.6m));

            var valuation = h.Engine.MarkToMarket(quote)!;
            Assert.That(valuation.RawProfit, Is.EqualTo(-60.6m));
            Assert.That(valuation.ExitProfit, Is.EqualTo(-63.6m));
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
            Assert.That(h.BasketsClosed[0].Record.RawProfit, Is.EqualTo(1.5m));
            Assert.That(h.BasketsClosed[0].Record.ExitProfit, Is.EqualTo(1m));
        }

        [Test]
        public void StepMoneyIsUndefinedWithoutLegs()
        {
            var h = new Harness();
            h.Anchor();
            Assert.Throws<InvalidOperationException>(() => BasketEconomics.StepMoney(h.Engine.Basket!, h.Parameters));
        }
    }
}
