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
            h.AtLower();   // the same situation again

            var basket = h.Engine.Basket!;
            Assert.That(basket.OpenPositions, Is.EqualTo(1));
            Assert.That(h.EntriesRejected, Has.Count.EqualTo(1), "one event per distinct situation");
            Assert.That(h.Engine.RejectedEntryAttempts, Is.EqualTo(2));
            var rejection = h.EntriesRejected[0].Rejection;
            Assert.That(rejection.Reason, Is.EqualTo(EntryRejectionReason.VolumeExceedsMaximum));
            Assert.That(rejection.TradeNumber, Is.EqualTo(2));
            Assert.That(rejection.Side, Is.EqualTo(TradeSide.Sell));
            Assert.That(rejection.RequestedLots, Is.EqualTo(120m));
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
            Assert.That(sizing, Is.Not.Null);
            Assert.That(sizing!.Outcome, Is.EqualTo(HardBreakevenOutcome.Feasible));

            h.AtLower(); // trade 6: SELL, still hard-BE
            Assert.That(basket.HardBreakevenModeActive, Is.True);
            var sixth = basket.Legs[5];
            Assert.That(sixth.Regime, Is.EqualTo(SizingRegime.HardBreakeven));
            Assert.That(sixth.Side, Is.EqualTo(TradeSide.Sell));
            Assert.That(sixth.Lots, Is.EqualTo(0.10m));
            Assert.That(h.EntriesOpened[5].Sizing!.ExistingProfitAtTarget, Is.EqualTo(-679.84m));
            Assert.That(h.EntriesOpened[5].Sizing!.MarginalProfitPerLot, Is.EqualTo(6946m));
            Assert.That(h.EntriesOpened[5].Sizing!.ProjectedProfitAfter, Is.EqualTo(14.76m));
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
            Assert.That(h.EntriesOpened[0].Sizing!.RequiredLot, Is.EqualTo(0m));
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
            Assert.That(rejection.Sizing!.Outcome, Is.EqualTo(HardBreakevenOutcome.NonPositiveMarginalProfit));
            Assert.That(rejection.Sizing!.NormalizedLot, Is.EqualTo(0m));
            Assert.That(rejection.TradeNumber, Is.EqualTo(5));
            Assert.That(basket.LastRejection!.Sizing!.CandidateEntryPrice, Is.EqualTo(2030.2m), "the latest attempt is kept");
        }

        [Test]
        public void EveryTailFillIsVerifiedAgainstTheHardBreakevenRequirement()
        {
            var h = new Harness();
            var basket = h.PingPongFourLegs();
            h.AtUpper(); // trade 5 through the research executor: fill = sizing model

            var sizing = h.EntriesOpened[4].Sizing!;
            Assert.That(BasketEconomics.ProjectedExistingProfit(basket, sizing.Target, h.Parameters), Is.EqualTo(sizing.ProjectedProfitAfter));
            Assert.That(BasketEconomics.ProjectedExistingProfit(basket, sizing.Target, h.Parameters), Is.EqualTo(36.64m));
            Assert.That(basket.Legs[4].Sizing, Is.SameAs(sizing));
            Assert.That(h.Violations, Is.Empty);
            Assert.That(h.Engine.Faulted, Is.False);
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

            // -380.12 + (2089.46 - 2030) * 0.06 * 100 = -23.36 < 0: the requirement is not met
            Assert.That(fault.Invariant, Is.EqualTo(StrategyInvariant.HardBreakevenViolatedByFill));
            Assert.That(fault.Message, Does.Contain("-23.36"));
            Assert.That(basket.OpenPositions, Is.EqualTo(5), "the fill happened; the ledger stays truthful for the post-mortem");
            Assert.That(basket.Legs[4].EntryPrice, Is.EqualTo(2030m));
            Assert.That(h.Violations, Has.Count.EqualTo(1), "the diagnostic is raised before the fault");
            Assert.That(h.Violations[0].ProjectedProfitAfterFill, Is.EqualTo(-23.36m));
            Assert.That(h.Violations[0].Leg, Is.SameAs(basket.Legs[4]));
            Assert.That(h.Engine.Faulted, Is.True);

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
        public void RejectionIsReportedAgainWhenTheRequiredLotChangesMaterially()
        {
            var h = new Harness(Harness.NoExits() with { MaximumVolume = 0.05m });
            h.PingPongFourLegs();
            h.AtUpper();                       // Q_BE 0.0547 -> 0.06 > 0.05
            h.AtUpper();                       // same situation
            Assert.That(h.EntriesRejected, Has.Count.EqualTo(1));

            h.Feed(2060m, 2060.2m);            // marginal 2926 -> Q_BE 0.1299 -> 0.13: materially different
            Assert.That(h.EntriesRejected, Has.Count.EqualTo(2));
            Assert.That(h.EntriesRejected[1].Rejection.Sizing!.RequiredLot, Is.GreaterThan(0.12m).And.LessThan(0.13m));
            Assert.That(h.Engine.RejectedEntryAttempts, Is.EqualTo(3));
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
            Assert.That(rejection.Sizing!.Outcome, Is.EqualTo(HardBreakevenOutcome.ExceedsMaximumVolume));
            Assert.That(rejection.Sizing!.RequiredLot, Is.EqualTo(-(-380.12m) / 6946m));
            Assert.That(rejection.Sizing!.NormalizedLot, Is.EqualTo(0m), "no smaller lot is substituted");
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
            // The projected Bid/Ask are the interim reading of T (a midpoint with the configured
            // 0.2 target spread split around it); which price T is remains an owner decision, and
            // these two assertions pin the current arithmetic only, not an approved rule.
            Assert.That(sizing.Target.Bid, Is.EqualTo(2089.46m));
            Assert.That(sizing.Target.Ask, Is.EqualTo(2089.66m));
            Assert.That(sizing.CandidateEntryPrice, Is.EqualTo(2020m));
            Assert.That(sizing.ExistingProfitAtTarget, Is.EqualTo(-380.12m));
            Assert.That(sizing.MarginalProfitPerLot, Is.EqualTo(6946m));
            Assert.That(sizing.RequiredLot, Is.EqualTo(380.12m / 6946m));
            Assert.That(sizing.RequiredLot, Is.GreaterThan(0.05m).And.LessThan(0.06m));
            Assert.That(sizing.NormalizedLot, Is.EqualTo(0.06m), "0.0547 rounds up to 0.06, never down to 0.05");
            Assert.That(sizing.ProjectedProfitAfter, Is.EqualTo(36.64m));
        }

        [Test]
        public void NormalizedLotSatisfiesTheRequirementAndOneStepLessDoesNot()
        {
            var p = Harness.Defaults();
            var basket = ReferenceBasket(p);
            var sizing = HardBreakevenSizer.Size(basket, TradeSide.Buy, Upper, p);

            var target = sizing.Target;
            var existing = BasketEconomics.ProjectedExistingProfit(basket, target, p);
            var withLot = existing + BasketEconomics.ProjectedLegProfit(TradeSide.Buy, sizing.NormalizedLot, sizing.CandidateEntryPrice, 0m, target, p);
            var withOneStepLess = existing + BasketEconomics.ProjectedLegProfit(TradeSide.Buy, sizing.NormalizedLot - p.VolumeStep, sizing.CandidateEntryPrice, 0m, target, p);

            Assert.That(withLot, Is.EqualTo(sizing.ProjectedProfitAfter));
            Assert.That(withLot, Is.GreaterThanOrEqualTo(0m));
            Assert.That(withOneStepLess, Is.EqualTo(-32.82m));
            Assert.That(withOneStepLess, Is.LessThan(0m));
        }

        [Test]
        public void SellSideUsesTheLowerTargetAndTheBid()
        {
            var p = Harness.Defaults();
            var basket = ReferenceBasket(p);
            basket.AddLeg(new BasketLeg(5, TradeSide.Buy, 0.06m, 2020m, Time, SizingRegime.HardBreakeven));

            var sizing = HardBreakevenSizer.Size(basket, TradeSide.Sell, Lower, p);

            Assert.That(sizing.Target.Target, Is.EqualTo(1910.44m));
            Assert.That(sizing.Target.Bid, Is.EqualTo(1910.34m));
            Assert.That(sizing.Target.Ask, Is.EqualTo(1910.54m));
            Assert.That(sizing.CandidateEntryPrice, Is.EqualTo(1980m));
            Assert.That(sizing.ExistingProfitAtTarget, Is.EqualTo(-679.84m));
            Assert.That(sizing.MarginalProfitPerLot, Is.EqualTo(6946m));
            Assert.That(sizing.NormalizedLot, Is.EqualTo(0.10m));
            Assert.That(sizing.ProjectedProfitAfter, Is.EqualTo(14.76m));
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
            Assert.That(sizing.ExistingProfitAtTarget, Is.EqualTo(-381.82m));
            Assert.That(sizing.MarginalProfitPerLot, Is.EqualTo(6919m));
            Assert.That(sizing.NormalizedLot, Is.EqualTo(0.06m));
            Assert.That(sizing.ProjectedProfitAfter, Is.EqualTo(-381.82m + 0.06m * 6919m));
        }

        [Test]
        public void TargetSpreadIsTheConfiguredOneNotTheQuotes()
        {
            // The sizing quote's spread is 0.2; the projection uses the configured 0.5.
            var p = Harness.Defaults() with { ProjectedSpread = 0.5m };
            var sizing = HardBreakevenSizer.Size(ReferenceBasket(p), TradeSide.Buy, Upper, p);

            Assert.That(sizing.Target.Spread, Is.EqualTo(0.5m));
            Assert.That(sizing.Target.Bid, Is.EqualTo(2089.31m));
            Assert.That(sizing.Target.Ask, Is.EqualTo(2089.81m));
            Assert.That(sizing.ExistingProfitAtTarget, Is.EqualTo(-381.62m));
            Assert.That(sizing.MarginalProfitPerLot, Is.EqualTo(6931m));
        }

        [Test]
        public void AccruedSwapIsPartOfTheExistingProjection()
        {
            var p = Harness.Defaults();
            var basket = ReferenceBasket(p);
            basket.AddSwap(basket.Legs[0], -5m);

            var sizing = HardBreakevenSizer.Size(basket, TradeSide.Buy, Upper, p);

            Assert.That(sizing.ExistingProfitAtTarget, Is.EqualTo(-385.12m));
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
            // Ceiling such that the projected Bid at T_up equals the candidate entry: 2020 + 0.1 = 2020.1 -> T_up = 2020.1 -> C = 1.005%
            var d = Harness.Defaults();
            var p = new SingleAnchorParameters
            {
                StepPercent = d.StepPercent,
                BaseLot = d.BaseLot,
                HardBreakevenCeilingPercent = 1.005m,
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
            // T_up = 2010 (C = 0.5%), projected Bid 2009.9 < BUY entry 2020: PL_1lot = -1010. The
            // basket already projects +464.9 at T_up, so the smallest valid lot, the minimum,
            // still satisfies PL_after >= 0 (464.9 - 10.1) and is placed; more volume never helps.
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

            Assert.That(sizing.MarginalProfitPerLot, Is.EqualTo(-1010m));
            Assert.That(sizing.ExistingProfitAtTarget, Is.EqualTo(464.9m));
            Assert.That(sizing.IsFeasible, Is.True);
            Assert.That(sizing.RequiredLot, Is.EqualTo(0m));
            Assert.That(sizing.NormalizedLot, Is.EqualTo(0.01m));
            Assert.That(sizing.ProjectedProfitAfter, Is.EqualTo(454.8m));
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
            basket.AddLeg(new BasketLeg(2, TradeSide.Buy, 0.04m, 2000m, Time, SizingRegime.Arithmetic)); // +39.6 - 30.1 = 9.5 at T_up

            var sizing = HardBreakevenSizer.Size(basket, TradeSide.Buy, Upper, p);

            Assert.That(sizing.ExistingProfitAtTarget, Is.EqualTo(9.5m));
            Assert.That(sizing.ProjectedProfitAfter, Is.EqualTo(9.5m - 10.1m), "the minimum lot would push the basket below breakeven at the target");
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
            Assert.That(sizing.RequiredLot, Is.EqualTo(380.12m / 6946m));
            Assert.That(sizing.NormalizedLot, Is.EqualTo(0m));
            Assert.That(sizing.Message, Does.Contain("not allowed to drift"));
        }

        [Test]
        public void ProjectedClosePricesBelowZeroAfterSlippageAreInvalid()
        {
            // The target itself is valid (Bid 2089.46) but the executable BUY close, Bid less
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
            Assert.That(sizing.NormalizedLot, Is.EqualTo(0m));
        }

        [Test]
        public void ProjectedPricesThatAreNotPositiveAreInfeasible()
        {
            var d = Harness.Defaults();
            var p = Harness.Defaults() with { ProjectedSpread = 5000m };
            var sizing = HardBreakevenSizer.Size(ReferenceBasket(p), TradeSide.Buy, Upper, p);

            Assert.That(sizing.Outcome, Is.EqualTo(HardBreakevenOutcome.InvalidTargetPrices));
            Assert.That(sizing.NormalizedLot, Is.EqualTo(0m));
        }

        [Test]
        public void OnlyTheSidesPresentOrRequiredNeedAPositiveExecutablePrice()
        {
            // SELL-only basket, SELL candidate: the projected BUY close (1910.34 - 1950 < 0) is
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
