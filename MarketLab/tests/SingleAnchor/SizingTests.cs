using System;
using NUnit.Framework;

namespace MarketLab.SingleAnchor.Tests
{
    [TestFixture]
    public class ArithmeticSizingTests
    {
        [Test]
        public void TradesOneToFourUseBaseLotTimesTradeNumber()
        {
            var h = new Harness();
            var basket = h.PingPongFourLegs();

            Assert.That(basket.OpenPositions, Is.EqualTo(4));
            Assert.That(basket.Legs[0].Lots, Is.EqualTo(0.01m));
            Assert.That(basket.Legs[1].Lots, Is.EqualTo(0.02m));
            Assert.That(basket.Legs[2].Lots, Is.EqualTo(0.03m));
            Assert.That(basket.Legs[3].Lots, Is.EqualTo(0.04m));
            foreach (var leg in basket.Legs)
            {
                Assert.That(leg.Regime, Is.EqualTo(SizingRegime.Arithmetic));
            }
            Assert.That(basket.HardBreakevenModeActive, Is.False);
        }

        [TestCase(0.015, 0.02, 0.03, 0.05, 0.06)]
        [TestCase(0.014, 0.02, 0.03, 0.05, 0.06)] // 0.014, 0.028, 0.042, 0.056: never rounded down
        [TestCase(0.011, 0.02, 0.03, 0.04, 0.05)] // 0.011, 0.022, 0.033, 0.044
        public void ArithmeticLotsAreNormalizedUpwardToTheStep(decimal baseLot, decimal q1, decimal q2, decimal q3, decimal q4)
        {
            var h = new Harness(Harness.NoExits() with { BaseLot = baseLot });
            var basket = h.PingPongFourLegs();

            Assert.That(basket.Legs[0].Lots, Is.EqualTo(q1));
            Assert.That(basket.Legs[1].Lots, Is.EqualTo(q2));
            Assert.That(basket.Legs[2].Lots, Is.EqualTo(q3));
            Assert.That(basket.Legs[3].Lots, Is.EqualTo(q4));
        }

        [Test]
        public void ArithmeticLotBelowTheMinimumUsesTheMinimum()
        {
            var h = new Harness(new SingleAnchorParameters
            {
                StepPercent = 1m,
                BaseLot = 0.001m,
                PointValuePerLot = 100m,
                ProjectedSpread = 0.2m
            });
            h.Anchor();
            h.AtUpper();

            Assert.That(h.Engine.Basket!.Legs[0].Lots, Is.EqualTo(0.01m));
        }

        [Test]
        public void ArithmeticLotAboveTheMaximumIsRejectedExplicitly()
        {
            var h = new Harness(new SingleAnchorParameters
            {
                StepPercent = 1m,
                BaseLot = 60m,
                PointValuePerLot = 100m,
                ProjectedSpread = 0.2m,
                MaximumVolume = 100m,
                EscapeEnabled = false,
                TrailingEnabled = false
            });
            h.Anchor();
            h.AtUpper();
            Assert.That(h.Engine.Basket!.Legs[0].Lots, Is.EqualTo(60m));

            h.AtLower();   // trade 2 would be 120 lots
            h.AtLower();   // the same episode again

            var basket = h.Engine.Basket!;
            Assert.That(basket.OpenPositions, Is.EqualTo(1));
            Assert.That(h.EntriesRejected, Has.Count.EqualTo(1), "one event per distinct episode");
            Assert.That(h.Engine.RejectedEntryAttempts, Is.EqualTo(2));
            var rejection = h.EntriesRejected[0].Rejection;
            Assert.That(rejection.Reason, Is.EqualTo(EntryRejectionReason.VolumeExceedsMaximum));
            Assert.That(rejection.TradeNumber, Is.EqualTo(2));
            Assert.That(rejection.Side, Is.EqualTo(TradeSide.Sell));
            Assert.That(rejection.RawRequestedLots, Is.EqualTo(120m), "B * n");
            Assert.That(rejection.NormalizedRequiredLots, Is.EqualTo(120m));
            Assert.That(basket.LastRejection, Is.Not.Null);
            Assert.That(h.Executor.Entries, Has.Count.EqualTo(1), "nothing was sent to the host");
        }
    }

    [TestFixture]
    public class HardBreakevenModeTests
    {
        [Test]
        public void TradeFiveActivatesHardBreakevenModeForTheRestOfTheBasket()
        {
            var h = new Harness();
            var basket = h.PingPongFourLegs();
            Assert.That(basket.HardBreakevenModeActive, Is.False);

            h.AtUpper(); // trade 5: BUY, hard-BE sized
            Assert.That(basket.HardBreakevenModeActive, Is.True);
            Assert.That(basket.OpenPositions, Is.EqualTo(5));
            var fifth = basket.Legs[4];
            Assert.That(fifth.Regime, Is.EqualTo(SizingRegime.HardBreakeven));
            Assert.That(fifth.Side, Is.EqualTo(TradeSide.Buy));
            Assert.That(fifth.Lots, Is.EqualTo(0.06m));
            var sizing = h.EntriesOpened[4].Sizing;
            Assert.That(sizing.HasValue, Is.True);
            Assert.That(sizing!.Value.Outcome, Is.EqualTo(HardBreakevenOutcome.Feasible));

            h.AtLower(); // trade 6: SELL, still hard-BE
            Assert.That(basket.HardBreakevenModeActive, Is.True);
            var sixth = basket.Legs[5];
            Assert.That(sixth.Regime, Is.EqualTo(SizingRegime.HardBreakeven));
            Assert.That(sixth.Side, Is.EqualTo(TradeSide.Sell));
            Assert.That(sixth.Lots, Is.EqualTo(0.10m));
            Assert.That(h.EntriesOpened[5].Sizing!.Value.ExistingProfitAtTarget, Is.EqualTo(-680.24m));
            Assert.That(h.EntriesOpened[5].Sizing!.Value.MarginalProfitPerLot, Is.EqualTo(6956m));
            Assert.That(h.EntriesOpened[5].Sizing!.Value.ProjectedProfitAfter, Is.EqualTo(15.36m));
        }

        [Test]
        public void NormalTradeCountIsConfigurable()
        {
            var h = new Harness(new SingleAnchorParameters
            {
                StepPercent = 1m,
                BaseLot = 0.01m,
                NormalTradeCount = 2,
                PointValuePerLot = 100m,
                ProjectedSpread = 0.2m
            });
            h.Anchor();
            h.AtUpper();
            h.AtLower();
            Assert.That(h.Engine.Basket!.HardBreakevenModeActive, Is.False);
            h.AtUpper(); // trade 3 is the first tail trade

            var basket = h.Engine.Basket!;
            Assert.That(basket.HardBreakevenModeActive, Is.True);
            Assert.That(basket.Legs[2].Regime, Is.EqualTo(SizingRegime.HardBreakeven));
            Assert.That(basket.Legs[1].Regime, Is.EqualTo(SizingRegime.Arithmetic));
        }

        [Test]
        public void ZeroNormalTradesSizesTheFirstTradeAtTheMinimumBecauseNothingNeedsRecovering()
        {
            var h = new Harness(new SingleAnchorParameters
            {
                StepPercent = 1m,
                BaseLot = 0.5m,
                NormalTradeCount = 0,
                PointValuePerLot = 100m,
                ProjectedSpread = 0.2m
            });
            h.Anchor();
            h.AtUpper();

            var basket = h.Engine.Basket!;
            Assert.That(basket.HardBreakevenModeActive, Is.True);
            Assert.That(basket.Legs[0].Regime, Is.EqualTo(SizingRegime.HardBreakeven));
            Assert.That(basket.Legs[0].Lots, Is.EqualTo(0.01m));
            Assert.That(h.EntriesOpened[0].Sizing!.Value.RequiredLot, Is.EqualTo(0m));
        }

        [Test]
        public void InfeasibleHardBreakevenIsSurfacedAndNoOrderIsPlaced()
        {
            // Ceiling below the step: the target is below the BUY entry, so no BUY volume can
            // break even there (PL_1lot <= 0).
            var p = Harness.NoExits();
            var h = new Harness(new SingleAnchorParameters
            {
                StepPercent = p.StepPercent,
                BaseLot = p.BaseLot,
                HardBreakevenCeilingPercent = 0.5m,
                PointValuePerLot = p.PointValuePerLot,
                ProjectedSpread = 0.2m,
                EscapeEnabled = false,
                TrailingEnabled = false
            });
            var basket = h.PingPongFourLegs();

            h.AtUpper();
            h.AtUpper();
            h.Feed(2030m, 2030.2m);

            Assert.That(basket.OpenPositions, Is.EqualTo(4));
            Assert.That(basket.HardBreakevenModeActive, Is.True, "trade 5 was required, so tail mode is active even though it is infeasible");
            Assert.That(h.Executor.Entries, Has.Count.EqualTo(4), "no order reached the host");
            Assert.That(h.EntriesRejected, Has.Count.EqualTo(1));
            Assert.That(h.Engine.RejectedEntryAttempts, Is.EqualTo(3));
            var rejection = h.EntriesRejected[0].Rejection;
            Assert.That(rejection.Reason, Is.EqualTo(EntryRejectionReason.HardBreakevenInfeasible));
            Assert.That(rejection.Sizing!.Value.Outcome, Is.EqualTo(HardBreakevenOutcome.NonPositiveMarginalProfit));
            Assert.That(rejection.Sizing!.Value.NormalizedLot, Is.EqualTo(0m));
            Assert.That(rejection.NormalizedRequiredLots, Is.EqualTo(0m), "no positive lot can satisfy the requirement");
            Assert.That(rejection.ExactRequiredLots, Is.Null, "the ratio did not apply");
            Assert.That(rejection.TradeNumber, Is.EqualTo(5));
            Assert.That(basket.LastRejection!.Value.Sizing!.Value.CandidateEntryPrice, Is.EqualTo(2030.2m), "the latest attempt is kept");
        }

        [Test]
        public void EveryTailFillIsVerifiedAgainstTheHardBreakevenRequirement()
        {
            var h = new Harness();
            var basket = h.PingPongFourLegs();
            h.AtUpper(); // trade 5 through the research executor: fill = sizing model

            var sizing = h.EntriesOpened[4].Sizing!.Value;
            Assert.That(BasketEconomics.ProjectedExistingProfit(basket, sizing.Target, h.Parameters), Is.EqualTo(sizing.ProjectedProfitAfter));
            Assert.That(BasketEconomics.ProjectedExistingProfit(basket, sizing.Target, h.Parameters), Is.EqualTo(37.04m));
            Assert.That(basket.Legs[4].Sizing!.Value, Is.EqualTo(sizing));
            Assert.That(h.Violations, Is.Empty);
            Assert.That(h.Engine.Faulted, Is.False);
            Assert.That(h.Engine.HardBreakevenStatus.HardBEVerifiedUnderConfiguredExecutionModel, Is.True);
        }

        [Test]
        public void ATailFillWorseThanTheModelFaultsTheRun()
        {
            // With the research executor this cannot happen (fills are the sizing model); an
            // executor that departs from the model would put breakeven outside the ceiling, which
            // the strategy forbids after hard-BE activation, so the engine stops instead of trading on.
            var h = new Harness(Harness.NoExits());
            var basket = h.PingPongFourLegs();
            h.Executor.EntryOverride = o => EntryExecution.Filled(2030m); // 10 above the modelled Ask

            var fault = Assert.Throws<StrategyInvariantException>(() => h.AtUpper())!;

            // -380.32 + (2089.56 - 2030) * 0.06 * 100 = -22.96 < 0: the requirement is not met
            Assert.That(fault.Invariant, Is.EqualTo(StrategyInvariant.HardBreakevenViolatedByFill));
            Assert.That(fault.Message, Does.Contain("-22.96"));
            Assert.That(basket.OpenPositions, Is.EqualTo(5), "the fill happened; the ledger stays truthful for the post-mortem");
            Assert.That(basket.Legs[4].EntryPrice, Is.EqualTo(2030m));
            Assert.That(h.Violations, Has.Count.EqualTo(1), "the diagnostic is raised before the fault");
            Assert.That(h.Violations[0].ProjectedProfitAfterFill, Is.EqualTo(-22.96m));
            Assert.That(h.Violations[0].Leg, Is.SameAs(basket.Legs[4]));
            Assert.That(h.Engine.Faulted, Is.True);
            Assert.That(h.Engine.EntriesOpened, Is.EqualTo(4), "the failing tail leg is not published as a successful entry");
            Assert.That(h.EntriesOpened, Has.Count.EqualTo(4), "and no EntryOpened event was raised for it");
            Assert.That(h.Engine.HardBreakevenStatus.HardBEVerifiedUnderConfiguredExecutionModel, Is.False, "the verification state follows the failed fill");

            h.Executor.EntryOverride = null;
            Assert.Throws<StrategyInvariantException>(() => h.AtLower());
            Assert.That(basket.OpenPositions, Is.EqualTo(5), "no further trading after the fault");
        }

        [Test]
        public void ArithmeticFillsAreNotSubjectToTheHardBreakevenCheck()
        {
            var h = new Harness(Harness.NoExits());
            h.Executor.EntryOverride = o => EntryExecution.Filled(o.Side == TradeSide.Buy ? o.Quote.Ask + 10m : o.Quote.Bid - 10m);
            h.PingPongFourLegs();
            Assert.That(h.Violations, Is.Empty);
        }

        [Test]
        public void AChangedNormalizedRequirementStaysInTheSameRejectionEpisode()
        {
            // The broker-normalized requirement moves with every quote and is deliberately not part
            // of the episode identity; the row keeps the first requirement for context, the min/max
            // over the episode and the digest of every attempt.
            var h = new Harness(Harness.NoExits() with { MaximumVolume = 0.05m });
            var basket = h.PingPongFourLegs();
            h.AtUpper();                       // Q_BE 0.0547 -> 0.06 > 0.05
            h.AtUpper();                       // same episode
            Assert.That(h.EntriesRejected, Has.Count.EqualTo(1));

            h.Feed(2060m, 2060.2m);            // marginal 2936 -> Q_BE 0.1295 -> 0.13
            Assert.That(h.EntriesRejected, Has.Count.EqualTo(1), "a changed normalized requirement stays in the episode");
            Assert.That(h.Engine.RejectedEntryAttempts, Is.EqualTo(3));
            var row = basket.Rejections[0];
            Assert.That(row.Attempts, Is.EqualTo(3));
            Assert.That(row.NormalizedRequiredLots, Is.EqualTo(0.06m), "the first attempt's requirement stays for context");
            Assert.That(row.MinNormalizedRequiredLots, Is.EqualTo(0.06m));
            Assert.That(row.MaxNormalizedRequiredLots, Is.EqualTo(0.13m));
            Assert.That(basket.LastRejection!.Value.Sizing!.Value.RequiredLot, Is.GreaterThan(0.12m).And.LessThan(0.13m), "the latest attempt is kept");
        }

        [Test]
        public void OscillatingNormalizedRequirementsStayOneBoundedRow()
        {
            // Requirements alternate between adjacent normalized buckets (0.06 / 0.08) on every
            // tick. Before the episode identity dropped the normalized requirement, each attempt
            // differed from the previous one and produced a new row per tick.
            var h = new Harness(Harness.NoExits() with { MaximumVolume = 0.05m });
            var basket = h.PingPongFourLegs();
            for (var i = 0; i < 1000; i++)
            {
                h.Feed(2019.8m, i % 2 == 0 ? 2020m : 2040m);
            }

            Assert.That(h.Engine.RejectedEntryAttempts, Is.EqualTo(1000));
            Assert.That(basket.Rejections, Has.Count.EqualTo(1), "an oscillating requirement stays one episode");
            var row = basket.Rejections[0];
            Assert.That(row.Attempts, Is.EqualTo(1000));
            Assert.That(row.NormalizedRequiredLots, Is.EqualTo(0.06m), "the first attempt's requirement remains for context");
            Assert.That(row.MinNormalizedRequiredLots, Is.EqualTo(0.06m));
            Assert.That(row.MaxNormalizedRequiredLots, Is.EqualTo(0.08m));
            Assert.That(row.ParityHash, Has.Length.EqualTo(16));
            Assert.That(row.LastAsk, Is.EqualTo(2040m));
        }

        [Test]
        public void OscillatingHardBreakevenOutcomeStaysBoundedToItsEpisodes()
        {
            // The hard-BE outcome is itself quote-dependent: PL_1lot crosses zero at
            // Ask = T_up - CommissionPerLot / V. Quotes alternating on either side of that level
            // must stay two bounded episodes (one per outcome), not one row per tick, and an
            // episode that reappears appends to its existing row.
            var p = Harness.NoExits() with { CommissionPerLot = 7m, MaximumVolume = 100m };
            var h = new Harness(p);
            var basket = h.PingPongFourLegs();
            for (var i = 0; i < 1000; i++)
            {
                var ask = i % 2 == 0 ? 2089.48m : 2089.50m; // marginal +1 / -1 at T_up = 2089.56
                h.Feed(ask - 0.02m, ask);
            }

            Assert.That(h.Engine.RejectedEntryAttempts, Is.EqualTo(1000));
            Assert.That(h.Engine.EntriesRejected, Is.EqualTo(2), "one distinct episode per hard-BE outcome");
            Assert.That(basket.Rejections, Has.Count.EqualTo(2), "bounded rows, not one per tick");
            Assert.That(basket.Rejections[0].Outcome, Is.Not.EqualTo(basket.Rejections[1].Outcome));
            Assert.That(basket.Rejections[0].Attempts + basket.Rejections[1].Attempts, Is.EqualTo(1000));
            Assert.That(basket.Rejections[0].Attempts, Is.GreaterThan(1));
            Assert.That(basket.Rejections[1].Attempts, Is.GreaterThan(1));
        }

        [Test]
        public void AnInfeasibleTailCanBecomeFeasibleAndThenOpens()
        {
            var p = Harness.NoExits() with { MaximumVolume = 0.1m };
            var h = new Harness(p);
            var basket = h.PingPongFourLegs();
            h.Feed(2059.8m, 2060m);            // required 0.1286... -> 0.13 > 0.1: rejected
            Assert.That(basket.OpenPositions, Is.EqualTo(4));
            Assert.That(basket.Rejections, Has.Count.EqualTo(1));
            Assert.That(basket.Rejections[0].Outcome, Is.EqualTo(HardBreakevenOutcome.ExceedsMaximumVolume));

            h.AtUpper();                        // ask 2020: required 0.0547 -> 0.06 <= 0.1: opens
            Assert.That(basket.OpenPositions, Is.EqualTo(5));
            Assert.That(basket.Legs[4].Side, Is.EqualTo(TradeSide.Buy));
            Assert.That(basket.Legs[4].Regime, Is.EqualTo(SizingRegime.HardBreakeven));
            Assert.That(basket.LastRejection, Is.Null, "a filled entry clears the rejection state");
            Assert.That(basket.Rejections, Has.Count.EqualTo(1), "the closed episode stays in the trace");
        }

        [Test]
        public void SellFirstBasketSizesItsTailAtTheLowerBoundaryThroughTheEngine()
        {
            var h = new Harness(Harness.NoExits());
            h.Anchor();
            h.AtLower();                        // SELL 1
            h.AtUpper();                        // BUY 2
            h.AtLower();                        // SELL 3
            h.AtUpper();                        // BUY 4
            h.AtLower();                        // SELL 5 tail at the lower boundary

            var basket = h.Engine.Basket!;
            Assert.That(basket.OpenPositions, Is.EqualTo(5));
            var sizing = basket.Legs[4].Sizing!.Value;
            Assert.That(basket.Legs[4].Side, Is.EqualTo(TradeSide.Sell));
            Assert.That(sizing.Target.Ask, Is.EqualTo(1910.44m), "lower recovery values the Ask at T_down");
            Assert.That(sizing.Target.Bid, Is.EqualTo(1910.24m));
            Assert.That(sizing.ExistingProfitAtTarget, Is.EqualTo(-380.32m));
            Assert.That(sizing.MarginalProfitPerLot, Is.EqualTo(6956m));
            Assert.That(sizing.ExactRequired, Is.EqualTo(380.32m / 6956m));
            Assert.That(sizing.NormalizedRequiredLot, Is.EqualTo(0.06m));
            Assert.That(sizing.NormalizedLot, Is.EqualTo(0.06m));
            Assert.That(sizing.ProjectedProfitAfter, Is.EqualTo(37.04m));
        }

        [Test]
        public void HardBreakevenLotAboveTheMaximumIsInfeasibleNotDrifted()
        {
            var p = Harness.NoExits();
            var h = new Harness(new SingleAnchorParameters
            {
                StepPercent = p.StepPercent,
                BaseLot = p.BaseLot,
                PointValuePerLot = p.PointValuePerLot,
                ProjectedSpread = 0.2m,
                MaximumVolume = 0.05m,
                EscapeEnabled = false,
                TrailingEnabled = false
            });
            var basket = h.PingPongFourLegs();

            h.AtUpper();

            Assert.That(basket.OpenPositions, Is.EqualTo(4));
            Assert.That(h.Executor.Entries, Has.Count.EqualTo(4));
            var rejection = h.EntriesRejected[0].Rejection;
            Assert.That(rejection.Reason, Is.EqualTo(EntryRejectionReason.HardBreakevenInfeasible));
            Assert.That(rejection.Sizing!.Value.Outcome, Is.EqualTo(HardBreakevenOutcome.ExceedsMaximumVolume));
            Assert.That(rejection.Sizing!.Value.RequiredLot, Is.EqualTo(-(-380.32m) / 6956m));
            Assert.That(rejection.Sizing!.Value.NormalizedRequiredLot, Is.EqualTo(0.06m), "the needed broker lot is retained");
            Assert.That(rejection.Sizing!.Value.NormalizedLot, Is.EqualTo(0m), "no smaller lot is substituted");
            Assert.That(rejection.ExactRequiredLots, Is.EqualTo(-(-380.32m) / 6956m));
            Assert.That(rejection.NormalizedRequiredLots, Is.EqualTo(0.06m));
        }
    }

    [TestFixture]
    public class HardBreakevenSizerTests
    {
        private static readonly DateTime Time = Harness.T0;

        /// <summary>The four-leg reference basket built directly on the ledger.</summary>
        private static Basket ReferenceBasket(SingleAnchorParameters parameters)
        {
            var basket = new Basket(1, new Quote(Time, 1999.9m, 2000.1m), parameters);
            basket.AddLeg(new BasketLeg(1, TradeSide.Buy, 0.01m, 2020m, Time, SizingRegime.Arithmetic));
            basket.AddLeg(new BasketLeg(2, TradeSide.Sell, 0.02m, 1980m, Time, SizingRegime.Arithmetic));
            basket.AddLeg(new BasketLeg(3, TradeSide.Buy, 0.03m, 2020m, Time, SizingRegime.Arithmetic));
            basket.AddLeg(new BasketLeg(4, TradeSide.Sell, 0.04m, 1980m, Time, SizingRegime.Arithmetic));
            return basket;
        }

        private static readonly Quote Upper = new Quote(Time, 2019.8m, 2020m);
        private static readonly Quote Lower = new Quote(Time, 1980m, 1980.2m);

        [Test]
        public void RequiredLotIsMinusExistingOverMarginalAndIsRoundedUpward()
        {
            var p = Harness.Defaults();
            var sizing = HardBreakevenSizer.Size(ReferenceBasket(p), TradeSide.Buy, Upper, p);

            Assert.That(sizing.IsFeasible, Is.True);
            Assert.That(sizing.TradeNumber, Is.EqualTo(5));
            Assert.That(sizing.Target.Target, Is.EqualTo(2089.56m));
            // Owner decision resolved: the upper hard-BE level is the Bid, T_up itself; the
            // configured spread only reconstructs the opposite (Ask) side of the simultaneous close.
            Assert.That(sizing.Target.Bid, Is.EqualTo(2089.56m), "the hard-BE level is the Bid");
            Assert.That(sizing.Target.Ask, Is.EqualTo(2089.76m), "the spread reconstructs the opposite side only");
            Assert.That(sizing.CandidateEntryPrice, Is.EqualTo(2020m));
            Assert.That(sizing.ExistingProfitAtTarget, Is.EqualTo(-380.32m));
            Assert.That(sizing.MarginalProfitPerLot, Is.EqualTo(6956m));
            Assert.That(sizing.RequiredLot, Is.EqualTo(380.32m / 6956m));
            Assert.That(sizing.RequiredLot, Is.GreaterThan(0.05m).And.LessThan(0.06m));
            Assert.That(sizing.NormalizedRequiredLot, Is.EqualTo(0.06m));
            Assert.That(sizing.NormalizedLot, Is.EqualTo(0.06m), "0.0547 rounds up to 0.06, never down to 0.05");
            Assert.That(sizing.ProjectedProfitAfter, Is.EqualTo(37.04m));
        }

        [Test]
        public void NormalizedLotSatisfiesTheRequirementAndOneStepLessDoesNot()
        {
            var p = Harness.Defaults();
            var basket = ReferenceBasket(p);
            var sizing = HardBreakevenSizer.Size(basket, TradeSide.Buy, Upper, p);

            var target = sizing.Target;
            var existing = BasketEconomics.ProjectedExistingProfit(basket, target, p);
            var withLot = existing + BasketEconomics.ProjectedLegProfit(TradeSide.Buy, sizing.NormalizedLot, sizing.CandidateEntryPrice, target, p);
            var withOneStepLess = existing + BasketEconomics.ProjectedLegProfit(TradeSide.Buy, sizing.NormalizedLot - p.VolumeStep, sizing.CandidateEntryPrice, target, p);

            Assert.That(withLot, Is.EqualTo(sizing.ProjectedProfitAfter));
            Assert.That(withLot, Is.GreaterThanOrEqualTo(0m));
            Assert.That(withOneStepLess, Is.EqualTo(-32.52m));
            Assert.That(withOneStepLess, Is.LessThan(0m));
        }

        [Test]
        public void SellSideUsesTheLowerTargetAsTheAsk()
        {
            var p = Harness.Defaults();
            var basket = ReferenceBasket(p);
            basket.AddLeg(new BasketLeg(5, TradeSide.Buy, 0.06m, 2020m, Time, SizingRegime.HardBreakeven));

            var sizing = HardBreakevenSizer.Size(basket, TradeSide.Sell, Lower, p);

            Assert.That(sizing.Target.Target, Is.EqualTo(1910.44m));
            Assert.That(sizing.Target.Ask, Is.EqualTo(1910.44m), "the lower hard-BE level is the Ask");
            Assert.That(sizing.Target.Bid, Is.EqualTo(1910.24m), "the spread reconstructs the opposite side only");
            Assert.That(sizing.CandidateEntryPrice, Is.EqualTo(1980m));
            Assert.That(sizing.ExistingProfitAtTarget, Is.EqualTo(-680.24m));
            Assert.That(sizing.MarginalProfitPerLot, Is.EqualTo(6956m));
            Assert.That(sizing.NormalizedRequiredLot, Is.EqualTo(0.10m));
            Assert.That(sizing.NormalizedLot, Is.EqualTo(0.10m));
            Assert.That(sizing.ProjectedProfitAfter, Is.EqualTo(15.36m));
        }

        [Test]
        public void BasketAlreadyInsideTheCeilingNeedsOnlyTheMinimumLot()
        {
            var p = Harness.Defaults();
            var basket = new Basket(1, new Quote(Time, 1999.9m, 2000.1m), p);
            basket.AddLeg(new BasketLeg(1, TradeSide.Sell, 0.01m, 1980m, Time, SizingRegime.Arithmetic));
            basket.AddLeg(new BasketLeg(2, TradeSide.Buy, 0.50m, 2020m, Time, SizingRegime.Arithmetic));

            var sizing = HardBreakevenSizer.Size(basket, TradeSide.Sell, Lower, p);

            Assert.That(sizing.IsFeasible, Is.True);
            Assert.That(sizing.ExistingProfitAtTarget, Is.LessThan(0m));

            var sizingUp = HardBreakevenSizer.Size(basket, TradeSide.Buy, Upper, p);
            Assert.That(sizingUp.ExistingProfitAtTarget, Is.GreaterThan(0m), "net long basket is already profitable at the upper target");
            Assert.That(sizingUp.RequiredLot, Is.EqualTo(0m));
            Assert.That(sizingUp.NormalizedLot, Is.EqualTo(p.MinimumVolume));
            Assert.That(sizingUp.ProjectedProfitAfter, Is.GreaterThanOrEqualTo(0m));
        }

        [Test]
        public void CommissionAndSlippageEnterBothTheExistingAndTheMarginalProjection()
        {
            var d = Harness.Defaults();
            var p = new SingleAnchorParameters
            {
                StepPercent = d.StepPercent,
                BaseLot = d.BaseLot,
                PointValuePerLot = d.PointValuePerLot,
                ProjectedSpread = 0.2m,
                CommissionPerLot = 7m,
                Slippage = 0.1m
            };
            var sizing = HardBreakevenSizer.Size(ReferenceBasket(p), TradeSide.Buy, Upper, p);

            Assert.That(sizing.CandidateEntryPrice, Is.EqualTo(2020.1m));
            Assert.That(sizing.ExistingProfitAtTarget, Is.EqualTo(-382.02m));
            Assert.That(sizing.MarginalProfitPerLot, Is.EqualTo(6929m));
            Assert.That(sizing.NormalizedRequiredLot, Is.EqualTo(0.06m));
            Assert.That(sizing.NormalizedLot, Is.EqualTo(0.06m));
            Assert.That(sizing.ProjectedProfitAfter, Is.EqualTo(-382.02m + 0.06m * 6929m));
        }

        [Test]
        public void TargetSpreadIsTheConfiguredOneNotTheQuotes()
        {
            // The sizing quote's spread is 0.2; the projection uses the configured 0.5.
            var p = Harness.Defaults() with { ProjectedSpread = 0.5m };
            var sizing = HardBreakevenSizer.Size(ReferenceBasket(p), TradeSide.Buy, Upper, p);

            Assert.That(sizing.Target.Spread, Is.EqualTo(0.5m));
            Assert.That(sizing.Target.Bid, Is.EqualTo(2089.56m), "the configured spread never moves the BE level");
            Assert.That(sizing.Target.Ask, Is.EqualTo(2090.06m));
            Assert.That(sizing.ExistingProfitAtTarget, Is.EqualTo(-382.12m));
            Assert.That(sizing.MarginalProfitPerLot, Is.EqualTo(6956m));
        }

        [Test]
        public void TheHardTargetLevelDoesNotShiftWithTheSpread()
        {
            var d = Harness.Defaults();
            foreach (var spread in new[] { 0m, 0.2m, 5m })
            {
                var p = d with { ProjectedSpread = spread };
                var buy = HardBreakevenSizer.Size(ReferenceBasket(p), TradeSide.Buy, Upper, p);
                Assert.That(buy.Target.Target, Is.EqualTo(2089.56m));
                Assert.That(buy.Target.Bid, Is.EqualTo(2089.56m), "upper hard-BE level is Bid = T_up");
                Assert.That(buy.Target.Ask, Is.EqualTo(2089.56m + spread));

                var sell = HardBreakevenSizer.Size(ReferenceBasket(p), TradeSide.Sell, Lower, p);
                Assert.That(sell.Target.Target, Is.EqualTo(1910.44m));
                Assert.That(sell.Target.Ask, Is.EqualTo(1910.44m), "lower hard-BE level is Ask = T_down");
                Assert.That(sell.Target.Bid, Is.EqualTo(1910.44m - spread));
            }
        }

        [Test]
        public void NonPositiveMarginalProfitIsInfeasible()
        {
            var d = Harness.Defaults();
            var p = new SingleAnchorParameters
            {
                StepPercent = d.StepPercent,
                BaseLot = d.BaseLot,
                HardBreakevenCeilingPercent = 0.5m, // T_up = 2010 < entry 2020
                PointValuePerLot = d.PointValuePerLot,
                ProjectedSpread = 0.2m
            };
            var sizing = HardBreakevenSizer.Size(ReferenceBasket(p), TradeSide.Buy, Upper, p);

            Assert.That(sizing.IsFeasible, Is.False);
            Assert.That(sizing.Outcome, Is.EqualTo(HardBreakevenOutcome.NonPositiveMarginalProfit));
            Assert.That(sizing.MarginalProfitPerLot, Is.LessThanOrEqualTo(0m));
            Assert.That(sizing.NormalizedLot, Is.EqualTo(0m));
            Assert.That(sizing.Message, Does.Contain("cannot be reached"));
        }

        [Test]
        public void ExactlyZeroMarginalProfitIsInfeasible()
        {
            // The upper hard-BE level is the Bid, so T_up = 2020 (C = 1%) makes PL_1lot exactly 0.
            var d = Harness.Defaults();
            var p = new SingleAnchorParameters
            {
                StepPercent = d.StepPercent,
                BaseLot = d.BaseLot,
                HardBreakevenCeilingPercent = 1m,
                PointValuePerLot = d.PointValuePerLot,
                ProjectedSpread = 0.2m
            };
            var sizing = HardBreakevenSizer.Size(ReferenceBasket(p), TradeSide.Buy, Upper, p);

            Assert.That(sizing.Target.Bid, Is.EqualTo(2020m));
            Assert.That(sizing.MarginalProfitPerLot, Is.EqualTo(0m));
            Assert.That(sizing.Outcome, Is.EqualTo(HardBreakevenOutcome.NonPositiveMarginalProfit));
        }

        [Test]
        public void NonPositiveMarginalProfitWithTheBasketInsideTheCeilingPlacesTheMinimumLot()
        {
            // T_up = 2010 (C = 0.5%), Bid 2010 < BUY entry 2020: PL_1lot = -1000. The basket
            // already projects +469.8 at T_up, so the smallest valid lot, the minimum, still
            // satisfies PL_after >= 0 (469.8 - 10) and is placed; more volume never helps.
            var d = Harness.Defaults();
            var p = new SingleAnchorParameters
            {
                StepPercent = d.StepPercent,
                BaseLot = d.BaseLot,
                HardBreakevenCeilingPercent = 0.5m,
                PointValuePerLot = d.PointValuePerLot,
                ProjectedSpread = 0.2m
            };
            var basket = new Basket(1, new Quote(Time, 1999.9m, 2000.1m), p);
            basket.AddLeg(new BasketLeg(1, TradeSide.Sell, 0.01m, 1980m, Time, SizingRegime.Arithmetic));
            basket.AddLeg(new BasketLeg(2, TradeSide.Buy, 0.50m, 2000m, Time, SizingRegime.Arithmetic));

            var sizing = HardBreakevenSizer.Size(basket, TradeSide.Buy, Upper, p);

            Assert.That(sizing.MarginalProfitPerLot, Is.EqualTo(-1000m));
            Assert.That(sizing.ExistingProfitAtTarget, Is.EqualTo(469.8m));
            Assert.That(sizing.IsFeasible, Is.True);
            Assert.That(sizing.RequiredLot, Is.EqualTo(0m));
            Assert.That(sizing.ExactRequired, Is.Null, "PL_1lot <= 0: there is no finite exact Q_BE");
            Assert.That(sizing.NormalizedLot, Is.EqualTo(0.01m));
            Assert.That(sizing.ProjectedProfitAfter, Is.EqualTo(459.8m));
        }

        [Test]
        public void ALegWithNoFiniteExactRequirementTracesNullExactRequiredLot()
        {
            // Same scenario through the leg trace mapping: the minimum lot is a valid placement
            // because the basket is already inside the ceiling, but there is no exact Q_BE at all,
            // so ExactRequiredLot must be null rather than 0.
            var d = Harness.Defaults();
            var p = new SingleAnchorParameters
            {
                StepPercent = d.StepPercent,
                BaseLot = d.BaseLot,
                HardBreakevenCeilingPercent = 0.5m,
                PointValuePerLot = d.PointValuePerLot,
                ProjectedSpread = 0.2m
            };
            var basket = new Basket(1, new Quote(Time, 1999.9m, 2000.1m), p);
            basket.AddLeg(new BasketLeg(1, TradeSide.Sell, 0.01m, 1980m, Time, SizingRegime.Arithmetic));
            basket.AddLeg(new BasketLeg(2, TradeSide.Buy, 0.50m, 2000m, Time, SizingRegime.Arithmetic));

            var sizing = HardBreakevenSizer.Size(basket, TradeSide.Buy, Upper, p);
            Assert.That(sizing.IsFeasible, Is.True);
            Assert.That(sizing.ExactRequired, Is.Null);

            var leg = new BasketLeg(3, TradeSide.Buy, sizing.NormalizedLot, 2020m, Time, SizingRegime.HardBreakeven) { Sizing = sizing };
            basket.AddLeg(leg);
            var row = LegRecord.From(basket.Sequence, leg);

            Assert.That(row.ExactRequiredLot, Is.Null, "no exact Q_BE exists");
            Assert.That(row.NormalizedRequiredLot, Is.EqualTo(0.01m));
            Assert.That(row.PlacedLot, Is.EqualTo(0.01m));
            Assert.That(row.Regime, Is.EqualTo(SizingRegime.HardBreakeven));
        }

        [Test]
        public void NonPositiveMarginalProfitWhenTheMinimumLotBreaksTheCeilingIsInfeasible()
        {
            var d = Harness.Defaults();
            var p = new SingleAnchorParameters
            {
                StepPercent = d.StepPercent,
                BaseLot = d.BaseLot,
                HardBreakevenCeilingPercent = 0.5m,
                PointValuePerLot = d.PointValuePerLot,
                ProjectedSpread = 0.2m
            };
            var basket = new Basket(1, new Quote(Time, 1999.9m, 2000.1m), p);
            basket.AddLeg(new BasketLeg(1, TradeSide.Sell, 0.01m, 1980m, Time, SizingRegime.Arithmetic));
            basket.AddLeg(new BasketLeg(2, TradeSide.Buy, 0.04m, 2000m, Time, SizingRegime.Arithmetic)); // +40 - 30.2 = 9.8 at T_up

            var sizing = HardBreakevenSizer.Size(basket, TradeSide.Buy, Upper, p);

            Assert.That(sizing.ExistingProfitAtTarget, Is.EqualTo(9.8m));
            Assert.That(sizing.ProjectedProfitAfter, Is.EqualTo(9.8m - 10m), "the minimum lot would push the basket below breakeven at the target");
            Assert.That(sizing.IsFeasible, Is.False);
            Assert.That(sizing.Outcome, Is.EqualTo(HardBreakevenOutcome.NonPositiveMarginalProfit));
            Assert.That(sizing.NormalizedLot, Is.EqualTo(0m));
        }

        [Test]
        public void RequirementAboveTheMaximumVolumeIsInfeasible()
        {
            var d = Harness.Defaults();
            var p = new SingleAnchorParameters
            {
                StepPercent = d.StepPercent,
                BaseLot = d.BaseLot,
                PointValuePerLot = d.PointValuePerLot,
                ProjectedSpread = 0.2m,
                MaximumVolume = 0.05m
            };
            var sizing = HardBreakevenSizer.Size(ReferenceBasket(p), TradeSide.Buy, Upper, p);

            Assert.That(sizing.IsFeasible, Is.False);
            Assert.That(sizing.Outcome, Is.EqualTo(HardBreakevenOutcome.ExceedsMaximumVolume));
            Assert.That(sizing.RequiredLot, Is.EqualTo(380.32m / 6956m));
            Assert.That(sizing.NormalizedRequiredLot, Is.EqualTo(0.06m), "the normalized requirement is retained exactly as the example in the plan");
            Assert.That(sizing.NormalizedLot, Is.EqualTo(0m));
            Assert.That(sizing.Message, Does.Contain("not allowed to drift"));
        }

        [Test]
        public void TheVerificationFallbackStepsAShortStartUpToTheVerifiedRequiredLot()
        {
            // Unit test of the rounding-fallback seam with a deliberately short start: the production
            // ceil estimate is within one decimal ulp of the true requirement, so it is not
            // practically reachable by a crafted parameter set; the loop itself must still move the
            // verified lot and its recomputed P/L together.
            var p = Harness.Defaults();
            var target = TargetPrices.ForUpperRecovery(2089.56m, p.ProjectedSpread!.Value);
            var verified = HardBreakevenSizer.SmallestVerifiedLot(-380.32m, TradeSide.Buy, 2020m, target, p, 0.05m, out var after);

            Assert.That(verified, Is.EqualTo(0.06m));
            Assert.That(after, Is.EqualTo(37.04m));

            // On the sizer's own path a feasible sizing reports the verified lot as its required lot.
            var sizing = HardBreakevenSizer.Size(ReferenceBasket(p), TradeSide.Buy, Upper, p);
            Assert.That(sizing.IsFeasible, Is.True);
            Assert.That(sizing.NormalizedRequiredLot, Is.EqualTo(sizing.NormalizedLot));
            Assert.That(sizing.ProjectedProfitAfter, Is.GreaterThanOrEqualTo(0m));
        }

        [TestCase(0.06, true)]
        [TestCase(0.059, false)]
        public void TheRequirementIsComparedStrictlyAgainstTheMaximumVolume(decimal maximum, bool feasible)
        {
            var p = Harness.Defaults() with { MaximumVolume = maximum };
            var sizing = HardBreakevenSizer.Size(ReferenceBasket(p), TradeSide.Buy, Upper, p);

            Assert.That(sizing.NormalizedRequiredLot, Is.EqualTo(0.06m));
            Assert.That(sizing.IsFeasible, Is.EqualTo(feasible));
            if (feasible)
            {
                Assert.That(sizing.NormalizedLot, Is.EqualTo(0.06m));
            }
            else
            {
                Assert.That(sizing.NormalizedLot, Is.EqualTo(0m));
                Assert.That(sizing.Outcome, Is.EqualTo(HardBreakevenOutcome.ExceedsMaximumVolume));
            }
        }

        [Test]
        public void TheVerificationFallbackFailsExplicitlyWhenItCannotMakeProgress()
        {
            // A start so far outside the sizer's range that lot + step is a decimal no-op must never
            // be returned as a negative-P/L "verified" lot: it fails explicitly.
            var p = Harness.Defaults() with { ProjectedSpread = 0m, VolumeStep = 0.001m, MinimumVolume = 0.001m, MaximumVolume = 1e28m };
            var target = TargetPrices.ForUpperRecovery(1.0000001m, 0m);

            var error = Assert.Throws<InvalidOperationException>(() =>
                HardBreakevenSizer.SmallestVerifiedLot(-1e26m, TradeSide.Buy, 1m, target, p, 1e27m, out _));

            Assert.That(error!.Message, Does.Contain("cannot make progress"));
        }

        [Test]
        public void EveryFeasibleSizingHasANonNegativeVerifiedProjection()
        {
            // General invariant over a quote sweep on both sides: whenever the sizer reports
            // Feasible, the reported normalized requirement equals the placed lot and the direct
            // recomputation at the boundary is non-negative.
            var p = Harness.Defaults();
            var basket = ReferenceBasket(p);
            for (var i = 0; i <= 120; i++)
            {
                var ask = 2020m + i * 0.5m; // 2020..2080, the upper-recovery region
                var buy = HardBreakevenSizer.Size(basket, TradeSide.Buy, new Quote(Time, ask - 0.2m, ask), p);
                if (buy.IsFeasible)
                {
                    Assert.That(buy.ProjectedProfitAfter, Is.GreaterThanOrEqualTo(0m), $"buy at {ask}");
                    Assert.That(buy.NormalizedRequiredLot, Is.EqualTo(buy.NormalizedLot), $"buy at {ask}");
                }

                var bid = 1980m - i * 0.5m; // 1980..1920, the lower-recovery region
                var sell = HardBreakevenSizer.Size(basket, TradeSide.Sell, new Quote(Time, bid, bid + 0.2m), p);
                if (sell.IsFeasible)
                {
                    Assert.That(sell.ProjectedProfitAfter, Is.GreaterThanOrEqualTo(0m), $"sell at {bid}");
                    Assert.That(sell.NormalizedRequiredLot, Is.EqualTo(sell.NormalizedLot), $"sell at {bid}");
                }
            }
        }

        [Test]
        public void ProjectedClosePricesBelowZeroAfterSlippageAreInvalid()
        {
            // The target itself is valid (Bid 2089.56) but the executable BUY close, Bid less
            // slippage, is not positive.
            var d = Harness.Defaults();
            var p = new SingleAnchorParameters
            {
                StepPercent = d.StepPercent,
                BaseLot = d.BaseLot,
                PointValuePerLot = d.PointValuePerLot,
                ProjectedSpread = 0.2m,
                Slippage = 2100m
            };
            var sizing = HardBreakevenSizer.Size(ReferenceBasket(p), TradeSide.Buy, Upper, p);

            Assert.That(sizing.Target.IsValid, Is.True);
            Assert.That(sizing.CandidateEntryPrice, Is.EqualTo(4120m));
            Assert.That(sizing.Outcome, Is.EqualTo(HardBreakevenOutcome.InvalidTargetPrices));
            Assert.That(sizing.NormalizedRequiredLot, Is.EqualTo(0m));
            Assert.That(sizing.NormalizedLot, Is.EqualTo(0m));
        }

        [Test]
        public void ProjectedPricesThatAreNotPositiveAreInfeasible()
        {
            // A wide target spread makes the reconstructed opposite side non-positive on the lower
            // recovery: Bid = T_down - 2000 < 0.
            var d = Harness.Defaults();
            var p = Harness.Defaults() with { ProjectedSpread = 2000m };
            var basket = new Basket(1, new Quote(Time, 1999.9m, 2000.1m), p);
            basket.AddLeg(new BasketLeg(1, TradeSide.Buy, 0.01m, 2020m, Time, SizingRegime.Arithmetic));
            var sizing = HardBreakevenSizer.Size(basket, TradeSide.Sell, Lower, p);

            Assert.That(sizing.Target.Bid, Is.EqualTo(1910.44m - 2000m));
            Assert.That(sizing.Outcome, Is.EqualTo(HardBreakevenOutcome.InvalidTargetPrices));
            Assert.That(sizing.NormalizedLot, Is.EqualTo(0m));
        }

        [Test]
        public void OnlyTheSidesPresentOrRequiredNeedAPositiveExecutablePrice()
        {
            // SELL-only basket, SELL candidate: the projected BUY close (1910.24 - 1950 < 0) is
            // irrelevant, so the sizing proceeds and fails for the economic reason, not for validity.
            var p = Harness.Defaults() with { Slippage = 1950m };
            var basket = new Basket(1, new Quote(Time, 1999.9m, 2000.1m), p);
            basket.AddLeg(new BasketLeg(1, TradeSide.Sell, 0.01m, 1980m, Time, SizingRegime.Arithmetic));

            var sizing = HardBreakevenSizer.Size(basket, TradeSide.Sell, Lower, p);

            Assert.That(sizing.CandidateEntryPrice, Is.EqualTo(30m));
            Assert.That(sizing.Outcome, Is.EqualTo(HardBreakevenOutcome.NonPositiveMarginalProfit));
        }

        [Test]
        public void ZeroTargetSpreadIsAValidSensitivityCase()
        {
            // Nothing divides by the spread: with 0 the projected Bid and Ask both equal T.
            var p = Harness.Defaults() with { ProjectedSpread = 0m };
            Assert.That(p.GetValidationErrors(), Is.Empty);

            var sizing = HardBreakevenSizer.Size(ReferenceBasket(p), TradeSide.Buy, Upper, p);

            Assert.That(sizing.Target.Bid, Is.EqualTo(2089.56m));
            Assert.That(sizing.Target.Ask, Is.EqualTo(2089.56m));
            Assert.That(sizing.ExistingProfitAtTarget, Is.EqualTo(69.56m * 4m - 109.56m * 6m));
            Assert.That(sizing.MarginalProfitPerLot, Is.EqualTo(6956m));
            Assert.That(sizing.IsFeasible, Is.True);
            Assert.That(sizing.NormalizedLot, Is.EqualTo(0.06m));
            Assert.That(sizing.ProjectedProfitAfter, Is.EqualTo(-379.12m + 0.06m * 6956m));
        }

        [Test]
        public void InvalidQuoteIsRejectedByTheSizer()
        {
            var p = Harness.Defaults();
            Assert.Throws<ArgumentException>(() => HardBreakevenSizer.Size(ReferenceBasket(p), TradeSide.Buy, new Quote(Time, 2020m, 2019m), p));
        }
    }

    [TestFixture]
    public class VolumeMathTests
    {
        [TestCase(0.1234, 0.01, 0.13)]
        [TestCase(0.12, 0.01, 0.12)]
        [TestCase(0.120000001, 0.01, 0.13)]
        [TestCase(0.05, 0.1, 0.1)]
        [TestCase(0, 0.01, 0)]
        public void CeilToStepRoundsUpward(decimal volume, decimal step, decimal expected)
        {
            Assert.That(VolumeMath.CeilToStep(volume, step), Is.EqualTo(expected));
        }

        [Test]
        public void NonPositiveStepIsRejected()
        {
            Assert.Throws<ArgumentOutOfRangeException>(() => VolumeMath.CeilToStep(1m, 0m));
            Assert.Throws<ArgumentOutOfRangeException>(() => VolumeMath.CeilToStep(1m, -0.01m));
        }
    }
}
