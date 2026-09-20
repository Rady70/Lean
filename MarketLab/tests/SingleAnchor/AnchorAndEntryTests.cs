using System;
using NUnit.Framework;

namespace MarketLab.SingleAnchor.Tests
{
    [TestFixture]
    public class AnchorAndLevelTests
    {
        [Test]
        public void AnchorIsMidpointAndLevelsDeriveFromIt()
        {
            var h = new Harness();
            var quote = h.Anchor();

            var basket = h.Engine.Basket;
            Assert.That(basket, Is.Not.Null);
            Assert.That(basket!.Anchor, Is.EqualTo(2000m));
            Assert.That(basket.Anchor, Is.EqualTo(quote.Mid));
            Assert.That(basket.Step, Is.EqualTo(20m));
            Assert.That(basket.Upper, Is.EqualTo(2020m));
            Assert.That(basket.Lower, Is.EqualTo(1980m));
            Assert.That(basket.UpperTarget, Is.EqualTo(2089.56m));
            Assert.That(basket.LowerTarget, Is.EqualTo(1910.44m));
            Assert.That(basket.CreatedTime, Is.EqualTo(quote.Time));
            Assert.That(basket.OpenPositions, Is.EqualTo(0));
            Assert.That(h.AnchorsCreated, Has.Count.EqualTo(1));
        }

        [Test]
        public void AnchorAndLevelsStayFixedWhilePriceMoves()
        {
            var h = new Harness();
            h.Anchor();
            var basket = h.Engine.Basket!;

            h.Feed(2010m, 2010.2m);
            h.Feed(1990m, 1990.2m);
            h.Feed(2019.7m, 2019.99m); // ask below Upper: no entry

            Assert.That(h.Engine.Basket, Is.SameAs(basket));
            Assert.That(basket.Anchor, Is.EqualTo(2000m));
            Assert.That(basket.Upper, Is.EqualTo(2020m));
            Assert.That(basket.Lower, Is.EqualTo(1980m));
            Assert.That(basket.OpenPositions, Is.EqualTo(0));
            Assert.That(h.AnchorsCreated, Has.Count.EqualTo(1));
        }

        [Test]
        public void StepPercentAndCeilingScaleWithTheAnchor()
        {
            var p = Harness.Defaults();
            var h = new Harness(new SingleAnchorParameters
            {
                StepPercent = 0.5m,
                BaseLot = p.BaseLot,
                HardBreakevenCeilingPercent = 2m,
                PointValuePerLot = p.PointValuePerLot
            });
            h.Feed(999m, 1001m);

            var basket = h.Engine.Basket!;
            Assert.That(basket.Anchor, Is.EqualTo(1000m));
            Assert.That(basket.Step, Is.EqualTo(5m));
            Assert.That(basket.Upper, Is.EqualTo(1005m));
            Assert.That(basket.Lower, Is.EqualTo(995m));
            Assert.That(basket.UpperTarget, Is.EqualTo(1020m));
            Assert.That(basket.LowerTarget, Is.EqualTo(980m));
        }
    }

    [TestFixture]
    public class QuoteValidationTests
    {
        [TestCase(0, 2000.1)]
        [TestCase(1999.9, 0)]
        [TestCase(-1, 1)]
        [TestCase(2000.2, 2000.1)]
        public void InvalidQuoteIsIgnoredExplicitly(decimal bid, decimal ask)
        {
            var h = new Harness();
            h.Feed(bid, ask);

            Assert.That(h.InvalidQuotes, Has.Count.EqualTo(1));
            Assert.That(h.Engine.Basket, Is.Null);
            Assert.That(h.Engine.QuotesProcessed, Is.EqualTo(0));
        }

        [Test]
        public void ZeroSpreadQuoteIsValid()
        {
            var h = new Harness();
            h.Feed(2000m, 2000m);
            Assert.That(h.InvalidQuotes, Is.Empty);
            Assert.That(h.Engine.Basket!.Anchor, Is.EqualTo(2000m));
        }

        [Test]
        public void OutOfOrderQuoteIsIgnored()
        {
            var h = new Harness();
            h.FeedAt(Harness.T0.AddSeconds(5), 1999.9m, 2000.1m);
            h.FeedAt(Harness.T0.AddSeconds(4), 2019.8m, 2020m);

            Assert.That(h.InvalidQuotes, Has.Count.EqualTo(1));
            Assert.That(h.Engine.QuotesProcessed, Is.EqualTo(1));
            Assert.That(h.Engine.Basket!.OpenPositions, Is.EqualTo(0));

            // the same timestamp again is allowed
            h.FeedAt(Harness.T0.AddSeconds(5), 2019.8m, 2020m);
            Assert.That(h.Engine.Basket!.OpenPositions, Is.EqualTo(1));
        }
    }

    [TestFixture]
    public class EntryTriggerTests
    {
        [Test]
        public void FirstBuyTriggersFromAskAtUpper()
        {
            var h = new Harness();
            h.Anchor();
            h.Feed(2019.99m, 2019.999m); // ask still below Upper
            Assert.That(h.Engine.Basket!.OpenPositions, Is.EqualTo(0));

            var quote = h.AtUpper();

            var basket = h.Engine.Basket!;
            Assert.That(basket.OpenPositions, Is.EqualTo(1));
            var leg = basket.Legs[0];
            Assert.That(leg.TradeNumber, Is.EqualTo(1));
            Assert.That(leg.Side, Is.EqualTo(TradeSide.Buy));
            Assert.That(leg.Lots, Is.EqualTo(0.01m));
            Assert.That(leg.EntryPrice, Is.EqualTo(quote.Ask));
            Assert.That(leg.EntryTime, Is.EqualTo(quote.Time));
            Assert.That(leg.Regime, Is.EqualTo(SizingRegime.Arithmetic));
            Assert.That(h.EntriesOpened, Has.Count.EqualTo(1));
            Assert.That(h.Executor.Entries[0].Quote, Is.EqualTo(quote));
        }

        [Test]
        public void BuyTriggersWhenAskGapsAboveUpper()
        {
            var h = new Harness();
            h.Anchor();
            h.Feed(2024.8m, 2025m);

            var leg = h.Engine.Basket!.Legs[0];
            Assert.That(leg.Side, Is.EqualTo(TradeSide.Buy));
            Assert.That(leg.EntryPrice, Is.EqualTo(2025m), "the leg records the executable Ask, not the level");
        }

        [Test]
        public void FirstSellTriggersFromBidAtLower()
        {
            var h = new Harness();
            h.Anchor();
            h.Feed(1980.001m, 1980.2m); // bid still above Lower
            Assert.That(h.Engine.Basket!.OpenPositions, Is.EqualTo(0));

            var quote = h.AtLower();

            var leg = h.Engine.Basket!.Legs[0];
            Assert.That(leg.TradeNumber, Is.EqualTo(1));
            Assert.That(leg.Side, Is.EqualTo(TradeSide.Sell));
            Assert.That(leg.Lots, Is.EqualTo(0.01m));
            Assert.That(leg.EntryPrice, Is.EqualTo(quote.Bid));
        }

        [Test]
        public void MidpointCrossingWithoutTheExecutableSideDoesNotTrigger()
        {
            var h = new Harness();
            h.Anchor();
            h.Feed(2019.9m, 2019.99m);  // mid 2019.945 < Upper, ask < Upper
            h.Feed(1980.01m, 1980.4m);  // bid > Lower

            Assert.That(h.Engine.Basket!.OpenPositions, Is.EqualTo(0));
        }

        [Test]
        public void WhenBothBoundariesAreSatisfiedTheBuyConditionIsCheckedFirst()
        {
            var h = new Harness();
            h.Anchor();
            h.Feed(1979m, 2021m);

            var basket = h.Engine.Basket!;
            Assert.That(basket.OpenPositions, Is.EqualTo(1));
            Assert.That(basket.Legs[0].Side, Is.EqualTo(TradeSide.Buy));
        }

        [Test]
        public void SidesAlternateStrictlyAfterTheFirstEntry()
        {
            var h = new Harness();
            h.Anchor();
            h.AtUpper();                       // BUY 1
            Assert.That(h.Engine.Basket!.NextRequiredSide, Is.EqualTo(TradeSide.Sell));

            h.AtUpper();                       // another Ask >= Upper: no second BUY
            h.Feed(2024m, 2024.2m);
            Assert.That(h.Engine.Basket!.OpenPositions, Is.EqualTo(1));

            h.AtLower();                       // SELL 2
            Assert.That(h.Engine.Basket!.NextRequiredSide, Is.EqualTo(TradeSide.Buy));
            h.AtLower();                       // another Bid <= Lower: no second SELL
            h.Feed(1975m, 1975.2m);
            Assert.That(h.Engine.Basket!.OpenPositions, Is.EqualTo(2));

            h.AtUpper();                       // BUY 3
            var basket = h.Engine.Basket!;
            Assert.That(basket.OpenPositions, Is.EqualTo(3));
            Assert.That(basket.Legs[0].Side, Is.EqualTo(TradeSide.Buy));
            Assert.That(basket.Legs[1].Side, Is.EqualTo(TradeSide.Sell));
            Assert.That(basket.Legs[2].Side, Is.EqualTo(TradeSide.Buy));
            Assert.That(basket.Legs[2].TradeNumber, Is.EqualTo(3));
            Assert.That(basket.LastSide, Is.EqualTo(TradeSide.Buy));
        }

        [Test]
        public void SellFirstBasketAlternatesTheOtherWay()
        {
            var h = new Harness();
            h.Anchor();
            h.AtLower();                       // SELL 1
            h.AtLower();
            Assert.That(h.Engine.Basket!.OpenPositions, Is.EqualTo(1));
            h.AtUpper();                       // BUY 2
            h.AtUpper();
            Assert.That(h.Engine.Basket!.OpenPositions, Is.EqualTo(2));
            h.AtLower();                       // SELL 3

            var basket = h.Engine.Basket!;
            Assert.That(basket.Legs[0].Side, Is.EqualTo(TradeSide.Sell));
            Assert.That(basket.Legs[1].Side, Is.EqualTo(TradeSide.Buy));
            Assert.That(basket.Legs[2].Side, Is.EqualTo(TradeSide.Sell));
        }

        [Test]
        public void EntryCanTriggerOnTheAnchoringQuoteOnlyWhenTheSpreadCoversTheStep()
        {
            // The anchor is the midpoint, so a step wider than half the spread cannot trigger on
            // the anchoring quote itself; a step inside the spread can (both levels inside the quote).
            var h = new Harness();
            h.Feed(1999.9m, 2000.1m);
            Assert.That(h.Engine.Basket!.OpenPositions, Is.EqualTo(0));

            var wide = new Harness(new SingleAnchorParameters
            {
                StepPercent = 0.001m, // step 0.02 on a 2000 anchor, spread 0.2
                BaseLot = 0.01m,
                PointValuePerLot = 100m
            });
            wide.Feed(1999.9m, 2000.1m);
            Assert.That(wide.Engine.Basket!.OpenPositions, Is.EqualTo(1));
            Assert.That(wide.Engine.Basket!.Legs[0].Side, Is.EqualTo(TradeSide.Buy));
        }
    }

    [TestFixture]
    public class ParameterValidationTests
    {
        [Test]
        public void ReferenceParametersAreValid()
        {
            Assert.That(Harness.Defaults().GetValidationErrors(), Is.Empty);
            Assert.DoesNotThrow(() => Harness.Defaults().Validate());
        }

        [Test]
        public void SpecificationDefaultsAreTheDefaults()
        {
            var p = new SingleAnchorParameters();
            Assert.That(p.NormalTradeCount, Is.EqualTo(4));
            Assert.That(p.HardBreakevenCeilingPercent, Is.EqualTo(4.478m));
            Assert.That(p.EscapeEnabled, Is.True);
            Assert.That(p.EscapeProfitUnits, Is.EqualTo(0.05m));
            Assert.That(p.EscapeMinimumOpenPositions, Is.EqualTo(2));
            Assert.That(p.FixedTakeProfitUnits, Is.EqualTo(0m));
            Assert.That(p.TrailingEnabled, Is.True);
            Assert.That(p.TrailingActivationUnits, Is.EqualTo(0.50m));
            Assert.That(p.TrailingDropUnits, Is.EqualTo(0.25m));
        }

        [Test]
        public void MissingStepPercentAndBaseLotAreReported()
        {
            var errors = new SingleAnchorParameters { PointValuePerLot = 100m }.GetValidationErrors();
            Assert.That(errors, Has.Some.Contains("StepPercent"));
            Assert.That(errors, Has.Some.Contains("BaseLot"));
            Assert.That(errors, Has.Count.EqualTo(2));
        }

        [Test]
        public void EachConstraintIsChecked()
        {
            Assert.That(With(p => p.NormalTradeCount = -1), Has.Some.Contains("NormalTradeCount"));
            Assert.That(With(p => p.HardBreakevenCeilingPercent = 100m), Has.Some.Contains("HardBreakevenCeilingPercent"));
            Assert.That(With(p => p.HardBreakevenCeilingPercent = 0m), Has.Some.Contains("HardBreakevenCeilingPercent"));
            Assert.That(With(p => p.EscapeProfitUnits = -0.1m), Has.Some.Contains("EscapeProfitUnits"));
            Assert.That(With(p => p.EscapeMinimumOpenPositions = 0), Has.Some.Contains("EscapeMinimumOpenPositions"));
            Assert.That(With(p => p.FixedTakeProfitUnits = -1m), Has.Some.Contains("FixedTakeProfitUnits"));
            Assert.That(With(p => p.TrailingActivationUnits = -1m), Has.Some.Contains("TrailingActivationUnits"));
            Assert.That(With(p => p.TrailingDropUnits = -1m), Has.Some.Contains("TrailingDropUnits"));
            Assert.That(With(p => p.CommissionBufferPerLot = -1m), Has.Some.Contains("CommissionBufferPerLot"));
            Assert.That(With(p => p.PointValuePerLot = 0m), Has.Some.Contains("PointValuePerLot"));
            Assert.That(With(p => p.VolumeStep = 0m), Has.Some.Contains("VolumeStep"));
            Assert.That(With(p => p.MinimumVolume = 0m), Has.Some.Contains("MinimumVolume"));
            Assert.That(With(p => p.MinimumVolume = 0.015m), Has.Some.Contains("whole multiple"));
            Assert.That(With(p => p.MaximumVolume = 0.005m), Has.Some.Contains("MaximumVolume"));
            Assert.That(With(p => p.CommissionPerLot = -1m), Has.Some.Contains("CommissionPerLot"));
            Assert.That(With(p => p.Slippage = -1m), Has.Some.Contains("Slippage"));
            Assert.That(With(p => p.ProjectedSpread = -1m), Has.Some.Contains("ProjectedSpread"));
            Assert.That(With(p => p.SwapRolloverTimeOfDay = TimeSpan.FromHours(24)), Has.Some.Contains("SwapRolloverTimeOfDay"));
            Assert.That(With(p => p.TripleSwapDay = DayOfWeek.Sunday), Has.Some.Contains("TripleSwapDay"));
        }

        [Test]
        public void EngineRefusesInvalidParameters()
        {
            var invalid = new SingleAnchorParameters { StepPercent = 1m, BaseLot = 0.01m }; // no point value
            Assert.Throws<ArgumentException>(() => new SingleAnchorEngine(invalid, new SyntheticExecutor()));
        }

        private static System.Collections.Generic.IReadOnlyList<string> With(Action<Mutable> mutate)
        {
            var m = new Mutable();
            mutate(m);
            return m.Build().GetValidationErrors();
        }

        private sealed class Mutable
        {
            public int NormalTradeCount = 4;
            public decimal HardBreakevenCeilingPercent = 4.478m;
            public decimal EscapeProfitUnits = 0.05m;
            public int EscapeMinimumOpenPositions = 2;
            public decimal FixedTakeProfitUnits = 0m;
            public decimal TrailingActivationUnits = 0.5m;
            public decimal TrailingDropUnits = 0.25m;
            public decimal CommissionBufferPerLot = 0m;
            public decimal PointValuePerLot = 100m;
            public decimal VolumeStep = 0.01m;
            public decimal MinimumVolume = 0.01m;
            public decimal MaximumVolume = 100m;
            public decimal CommissionPerLot = 0m;
            public decimal Slippage = 0m;
            public decimal ProjectedSpread = 0m;
            public TimeSpan SwapRolloverTimeOfDay = new TimeSpan(17, 0, 0);
            public DayOfWeek? TripleSwapDay = DayOfWeek.Wednesday;

            public SingleAnchorParameters Build()
            {
                return new SingleAnchorParameters
                {
                    StepPercent = 1m,
                    BaseLot = 0.01m,
                    NormalTradeCount = NormalTradeCount,
                    HardBreakevenCeilingPercent = HardBreakevenCeilingPercent,
                    EscapeProfitUnits = EscapeProfitUnits,
                    EscapeMinimumOpenPositions = EscapeMinimumOpenPositions,
                    FixedTakeProfitUnits = FixedTakeProfitUnits,
                    TrailingActivationUnits = TrailingActivationUnits,
                    TrailingDropUnits = TrailingDropUnits,
                    CommissionBufferPerLot = CommissionBufferPerLot,
                    PointValuePerLot = PointValuePerLot,
                    VolumeStep = VolumeStep,
                    MinimumVolume = MinimumVolume,
                    MaximumVolume = MaximumVolume,
                    CommissionPerLot = CommissionPerLot,
                    Slippage = Slippage,
                    ProjectedSpread = ProjectedSpread,
                    SwapRolloverTimeOfDay = SwapRolloverTimeOfDay,
                    TripleSwapDay = TripleSwapDay
                };
            }
        }
    }
}
