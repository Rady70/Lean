using System;
using System.Collections.Generic;
using System.Text.Json;
using NUnit.Framework;

namespace MarketLab.SingleAnchor.Tests
{
    /// <summary>
    /// A risk guard with scripted answers, used to test the engine's frozen PR 3 ordering without
    /// depending on a reachable account arithmetic path.
    /// </summary>
    internal sealed class StubRiskGuard : IResearchRiskGuard
    {
        public MarginStopOut? NextStopOut { get; set; }
        public MarginEntryDecision NextEntryDecision { get; set; } = MarginEntryDecision.Allowed;
        public int SurvivalChecks { get; private set; }

        /// <summary>Scripted observability; false makes the engine stop with AccountSurvival.</summary>
        public bool SurvivalObservable { get; set; } = true;

        public MarginStopOut? EvaluateSurvival(in Quote quote)
        {
            SurvivalChecks++;
            return NextStopOut;
        }

        public MarginEntryAssessment AssessEntry(EntryOrder order, Basket basket)
        {
            return new MarginEntryAssessment(NextEntryDecision, 0m, 0m, null, null, null);
        }

        public void ObserveEntryRejection(EntryRejection rejection, bool isNewEpisode)
        {
        }
    }

    /// <summary>
    /// The approved PR 3 MT5/XM-style margin arithmetic (roadmap sections 3.16-3.18): uncovered
    /// volume only, at the larger side's weighted-average open price, evaluated against the
    /// complete projected post-fill inventory.
    /// </summary>
    [TestFixture]
    public class MarginModelTests
    {
        private static readonly MarginParameters Margin = new MarginParameters();

        [Test]
        public void UncoveredBuyVolumeUsesItsWeightedAverageOpenPrice()
        {
            var basket = new Basket(1, new Quote(Harness.T0, 1999.9m, 2000.1m), Harness.Defaults());
            basket.AddLeg(new BasketLeg(1, TradeSide.Buy, 0.01m, 2020m, Harness.T0, SizingRegime.Arithmetic));

            Assert.That(MarginModel.UsedMargin(basket, Margin), Is.EqualTo(4.04m), "0.01 * 100 * 2020 / 500");
            Assert.That(MarginModel.UsedMargin(0.01m, 20.20m, 0m, 0m, Margin), Is.EqualTo(4.04m));
        }

        [Test]
        public void UncoveredSellVolumeUsesItsWeightedAverageOpenPrice()
        {
            var basket = new Basket(1, new Quote(Harness.T0, 1999.9m, 2000.1m), Harness.Defaults());
            basket.AddLeg(new BasketLeg(1, TradeSide.Sell, 0.02m, 1980m, Harness.T0, SizingRegime.Arithmetic));

            Assert.That(MarginModel.UsedMargin(basket, Margin), Is.EqualTo(7.92m), "0.02 * 100 * 1980 / 500");
        }

        [Test]
        public void FullyMatchedHedgeHasZeroMargin()
        {
            var basket = new Basket(1, new Quote(Harness.T0, 1999.9m, 2000.1m), Harness.Defaults());
            basket.AddLeg(new BasketLeg(1, TradeSide.Buy, 0.02m, 2020m, Harness.T0, SizingRegime.Arithmetic));
            basket.AddLeg(new BasketLeg(2, TradeSide.Sell, 0.02m, 1980m, Harness.T0, SizingRegime.Arithmetic));

            Assert.That(MarginModel.UsedMargin(basket, Margin), Is.EqualTo(0m));
            Assert.That(MarginModel.MarginLevelPercent(100m, 0m), Is.Null, "no infinite margin level for a matched hedge");
        }

        [Test]
        public void PartiallyHedgedInventoryChargesOnlyTheUncoveredSide()
        {
            var basket = new Basket(1, new Quote(Harness.T0, 1999.9m, 2000.1m), Harness.Defaults());
            basket.AddLeg(new BasketLeg(1, TradeSide.Buy, 0.01m, 2020m, Harness.T0, SizingRegime.Arithmetic));
            basket.AddLeg(new BasketLeg(2, TradeSide.Sell, 0.02m, 1980m, Harness.T0, SizingRegime.Arithmetic));
            basket.AddLeg(new BasketLeg(3, TradeSide.Buy, 0.03m, 2020m, Harness.T0, SizingRegime.Arithmetic));

            // BUY 0.04 at 2020 (notional 80.80) against SELL 0.02 at 1980: uncovered 0.02 of BUY.
            Assert.That(basket.BuyNotional, Is.EqualTo(80.80m));
            Assert.That(MarginModel.UsedMargin(basket, Margin), Is.EqualTo(8.08m), "0.02 * 100 * 2020 / 500");
        }

        [Test]
        public void ProjectedSameSideFillUpdatesTheWeightedAverage()
        {
            var basket = new Basket(1, new Quote(Harness.T0, 1999.9m, 2000.1m), Harness.Defaults());
            basket.AddLeg(new BasketLeg(1, TradeSide.Buy, 0.01m, 2020m, Harness.T0, SizingRegime.Arithmetic));

            // 0.01 @ 2020 + 0.01 @ 2040 = 0.02 lots at average 2030.
            var projected = MarginModel.ProjectedUsedMargin(basket, TradeSide.Buy, 0.01m, 2040m, Margin);
            Assert.That(projected, Is.EqualTo(8.12m), "0.02 * 100 * 2030 / 500");
            Assert.That(projected, Is.Not.EqualTo(4.08m), "not an isolated candidate-lot charge at the candidate price");
            Assert.That(projected, Is.Not.EqualTo(8.16m), "not the uncovered volume charged at the candidate price");
        }

        [Test]
        public void ProjectedOppositeSideFillChargesTheNewLargerSide()
        {
            var basket = new Basket(1, new Quote(Harness.T0, 1999.9m, 2000.1m), Harness.Defaults());
            basket.AddLeg(new BasketLeg(1, TradeSide.Buy, 0.01m, 2020m, Harness.T0, SizingRegime.Arithmetic));

            // The SELL candidate becomes the larger side: uncovered 0.02 at the SELL average 1990.
            var projected = MarginModel.ProjectedUsedMargin(basket, TradeSide.Sell, 0.03m, 1990m, Margin);
            Assert.That(projected, Is.EqualTo(7.96m), "0.02 * 100 * 1990 / 500");
        }

        [Test]
        public void ProjectedOppositeSideFillCanReduceTheUsedMargin()
        {
            var basket = new Basket(1, new Quote(Harness.T0, 1999.9m, 2000.1m), Harness.Defaults());
            basket.AddLeg(new BasketLeg(1, TradeSide.Buy, 0.01m, 2020m, Harness.T0, SizingRegime.Arithmetic));
            basket.AddLeg(new BasketLeg(2, TradeSide.Sell, 0.02m, 1980m, Harness.T0, SizingRegime.Arithmetic));
            basket.AddLeg(new BasketLeg(3, TradeSide.Buy, 0.03m, 2020m, Harness.T0, SizingRegime.Arithmetic));
            var current = MarginModel.UsedMargin(basket, Margin);
            Assert.That(current, Is.EqualTo(8.08m));

            // The SELL fill makes the SELL side the larger one: uncovered 0.01 at the SELL
            // weighted average (39.6 + 59.7) / 0.05 = 1986.
            var projected = MarginModel.ProjectedUsedMargin(basket, TradeSide.Sell, 0.03m, 1990m, Margin);
            Assert.That(projected, Is.EqualTo(3.972m), "0.01 * 100 * 1986 / 500");
            Assert.That(projected, Is.LessThan(current), "the hedge-increasing fill reduces the projected used margin");
        }

        [Test]
        public void ProjectedFillCanMakeTheInventoryNetFlat()
        {
            var basket = new Basket(1, new Quote(Harness.T0, 1999.9m, 2000.1m), Harness.Defaults());
            basket.AddLeg(new BasketLeg(1, TradeSide.Buy, 0.01m, 2020m, Harness.T0, SizingRegime.Arithmetic));

            var projected = MarginModel.ProjectedUsedMargin(basket, TradeSide.Sell, 0.01m, 2000m, Margin);
            Assert.That(projected, Is.EqualTo(0m));
        }

        [Test]
        public void MarginLevelIsTheEquityToUsedMarginRatio()
        {
            Assert.That(MarginModel.MarginLevelPercent(50m, 100m), Is.EqualTo(50m));
            Assert.That(MarginModel.MarginLevelPercent(120m, 100m), Is.EqualTo(120m));
            Assert.That(MarginModel.MarginLevelPercent(0.792m, 3.96m), Is.EqualTo(20m));
            Assert.That(MarginModel.MarginLevelPercent(-5m, 100m), Is.EqualTo(-5m));
            Assert.That(MarginModel.MarginLevelPercent(5m, 0m), Is.Null);
        }
    }

    /// <summary>
    /// The approved margin contract values and their validation (roadmap section 3.16).
    /// </summary>
    [TestFixture]
    public class MarginParametersTests
    {
        [Test]
        public void DefaultsAreTheFrozenPr3Contract()
        {
            var margin = new MarginParameters();
            Assert.That(margin.ContractSize, Is.EqualTo(100m));
            Assert.That(margin.Leverage, Is.EqualTo(500m));
            Assert.That(margin.MarginCallLevelPercent, Is.EqualTo(50m));
            Assert.That(margin.StopOutLevelPercent, Is.EqualTo(20m));
            Assert.That(margin.GetValidationErrors(), Is.Empty);
        }

        [Test]
        public void InvalidMarginConfigurationsAreRefused()
        {
            Assert.That(new MarginParameters { ContractSize = 0m }.GetValidationErrors(), Has.Count.EqualTo(1));
            Assert.That(new MarginParameters { ContractSize = -1m }.GetValidationErrors(), Has.Count.EqualTo(1));
            Assert.That(new MarginParameters { Leverage = 0m }.GetValidationErrors(), Has.Count.EqualTo(1));
            Assert.That(new MarginParameters { StopOutLevelPercent = 0m }.GetValidationErrors(), Has.Count.EqualTo(1));
            Assert.That(new MarginParameters { StopOutLevelPercent = 100m }.GetValidationErrors(), Is.Not.Empty);
            Assert.That(new MarginParameters { MarginCallLevelPercent = 20m }.GetValidationErrors(), Is.Not.Empty, "margin call must sit above stop-out");
            Assert.That(new MarginParameters { MarginCallLevelPercent = 10m, StopOutLevelPercent = 20m }.GetValidationErrors(), Is.Not.Empty);
            Assert.That(new MarginParameters { MarginCallLevelPercent = 100m }.GetValidationErrors(), Is.Not.Empty);
            Assert.Throws<ArgumentException>(() => new MarginParameters { Leverage = 0m }.Validate());
            Assert.Throws<ArgumentException>(() => new SingleAnchorResearchAccount(Harness.Defaults(), 1000m, new MarginParameters { Leverage = 0m }));
        }
    }

    /// <summary>
    /// The frozen PR 3 host contract: margin mode models exactly the approved USD XM-style
    /// XAUUSD CFD research account, so the instrument, its CFD Leverage calculation and the
    /// 100-per-lot USD point value may not vary. The fixed contract values themselves
    /// (100 oz/lot, 1:500, 50%/20%) come from <see cref="MarginParameters"/>' approved defaults.
    /// </summary>
    [TestFixture]
    public class MarginHostContractTests
    {
        [Test]
        public void TheApprovedHostConfigurationPasses()
        {
            Assert.That(SingleAnchorVNextAlgorithm.MarginHostContractError("XAUUSD", "Cfd", 100m), Is.Null);
            Assert.That(SingleAnchorVNextAlgorithm.MarginHostContractError("xauusd", "cfd", 100m), Is.Null, "the comparison is case-insensitive");
        }

        [Test]
        public void MarginModeRefusesAnotherInstrumentSecurityTypeOrPointValue()
        {
            Assert.That(SingleAnchorVNextAlgorithm.MarginHostContractError("EURUSD", "Cfd", 100m), Does.Contain("XAUUSD"));
            Assert.That(SingleAnchorVNextAlgorithm.MarginHostContractError("XAUUSD", "Forex", 100m), Does.Contain("Cfd"));
            Assert.That(SingleAnchorVNextAlgorithm.MarginHostContractError("XAUUSD", "Cfd", 50m), Does.Contain("100"));
            Assert.That(SingleAnchorVNextAlgorithm.MarginHostContractError("XAUUSD", "Cfd", 0m), Does.Contain("100"));
        }
    }

    /// <summary>
    /// The approved XM research volume profile (minimum 0.01, step 0.01, maximum 50 lots): PR 3
    /// must support and test it without changing the unrelated global engine default (100).
    /// </summary>
    [TestFixture]
    public class MarginApprovedVolumeProfileTests
    {
        private static SingleAnchorParameters ApprovedProfile()
        {
            return Harness.Defaults() with { MinimumVolume = 0.01m, VolumeStep = 0.01m, MaximumVolume = 50m };
        }

        [Test]
        public void TheApprovedProfilePlacesAnOrdinaryAndAHardBreakevenTail()
        {
            var h = new Harness(ApprovedProfile(), null, 1_000_000m, Harness.MarginDefaults());
            h.PingPongFourLegs();
            h.AtUpper(); // trade 5 hard-BE 0.06 <= 50

            Assert.That(h.Engine.EntriesOpened, Is.EqualTo(5));
            Assert.That(h.Engine.EntriesRejected, Is.EqualTo(0));
            Assert.That(h.Engine.Basket!.Legs[4].Lots, Is.EqualTo(0.06m));
        }

        [Test]
        public void TheApprovedMaximumRejectsAnArithmeticLotAboveFifty()
        {
            var p = ApprovedProfile() with { BaseLot = 20m };
            var h = new Harness(p, null, 1_000_000m, Harness.MarginDefaults());
            h.Anchor();
            h.AtUpper(); // trade 1 BUY 20 <= 50
            h.AtLower(); // trade 2 SELL 40 <= 50
            h.AtUpper(); // trade 3 BUY 60 > 50

            Assert.That(h.Engine.EntriesOpened, Is.EqualTo(2));
            Assert.That(h.EntriesRejected, Has.Count.EqualTo(1));
            Assert.That(h.EntriesRejected[0].Rejection.Reason, Is.EqualTo(EntryRejectionReason.VolumeExceedsMaximum));
            Assert.That(h.EntriesRejected[0].Rejection.NormalizedRequiredLots, Is.EqualTo(60m));
            Assert.That(h.Engine.Basket!.OpenPositions, Is.EqualTo(2), "the over-maximum lot is not financed or placed");
        }

        [Test]
        public void TheGlobalEngineDefaultVolumeCeilingIsStillOneHundred()
        {
            Assert.That(Harness.Defaults().MinimumVolume, Is.EqualTo(0.01m));
            Assert.That(Harness.Defaults().VolumeStep, Is.EqualTo(0.01m));
            Assert.That(Harness.Defaults().MaximumVolume, Is.EqualTo(100m), "PR 3 must not encode the broker profile in the global default");
        }
    }

    /// <summary>
    /// Account-level margin state: used/free margin and margin level derived from the same
    /// balance/equity state, their extrema, the exact Margin Call and stop-out boundaries, the
    /// flat and matched-hedge edge cases and the terminal negative-equity rule.
    /// </summary>
    [TestFixture]
    public class MarginAccountStateTests
    {
        private static SingleAnchorResearchAccount NewAccount(decimal balance)
        {
            return new SingleAnchorResearchAccount(Harness.Defaults(), balance, new MarginParameters());
        }

        private static Basket BuyOnlyBasket()
        {
            var basket = new Basket(1, new Quote(Harness.T0, 1999.9m, 2000.1m), Harness.Defaults());
            basket.AddLeg(new BasketLeg(1, TradeSide.Buy, 0.01m, 2020m, Harness.T0, SizingRegime.Arithmetic));
            return basket;
        }

        [Test]
        public void UsedFreeMarginAndLevelFollowTheBasketAndEquity()
        {
            var account = NewAccount(1000m);
            var basket = BuyOnlyBasket();
            var quote = new Quote(Harness.T0.AddSeconds(1), 2019.8m, 2020m);
            account.ObserveQuote(quote, basket, 0m, null);

            Assert.That(account.MarginSummary, Is.Not.Null);
            var m = account.MarginSummary!;
            Assert.That(m.CurrentUsedMargin, Is.EqualTo(4.04m));
            Assert.That(m.CurrentFreeMargin, Is.EqualTo(995.76m), "equity 999.8 less used 4.04");
            Assert.That(m.CurrentMarginLevelPercent, Is.EqualTo(MarginModel.MarginLevelPercent(999.8m, 4.04m)));
            Assert.That(m.MaxUsedMargin, Is.EqualTo(4.04m));
            Assert.That(m.MinFreeMargin, Is.EqualTo(995.76m));
            Assert.That(m.MinMarginLevelPercent, Is.EqualTo(m.CurrentMarginLevelPercent));
            Assert.That(m.MarginCallActive, Is.False);
            Assert.That(m.StopOut, Is.Null);
        }

        [Test]
        public void RunExtremaTrackTheWorstObservedState()
        {
            var account = NewAccount(1000m);
            var basket = BuyOnlyBasket();
            account.ObserveQuote(new Quote(Harness.T0.AddSeconds(1), 2019.8m, 2020m), basket, 0m, null);   // equity 999.8
            basket.AddLeg(new BasketLeg(2, TradeSide.Sell, 0.02m, 1980m, Harness.T0.AddSeconds(2), SizingRegime.Arithmetic));
            account.ObserveQuote(new Quote(Harness.T0.AddSeconds(2), 1980m, 1980.2m), basket, 0m, null);   // equity 959.6, used 3.96
            account.ObserveQuote(new Quote(Harness.T0.AddSeconds(3), 2100m, 2100.2m), basket, 0m, null);   // equity 839.6, used 3.96

            var m = account.MarginSummary!;
            Assert.That(m.MaxUsedMargin, Is.EqualTo(4.04m), "the one-leg BUY state used the most margin");
            Assert.That(m.MinFreeMargin, Is.EqualTo(835.64m), "equity 839.6 less used 3.96");
            Assert.That(m.MinMarginLevelPercent, Is.EqualTo(MarginModel.MarginLevelPercent(839.6m, 3.96m)));
            Assert.That(m.CurrentUsedMargin, Is.EqualTo(3.96m));
        }

        [Test]
        public void MarginCallStartsAtExactlyFiftyPercentAndClearsAboveIt()
        {
            var account = NewAccount(1000m);
            var basket = BuyOnlyBasket();
            var levelQuote = new Quote(Harness.T0.AddSeconds(1), 1022.02m, 1022.22m);
            account.ObserveQuote(levelQuote, basket, 0m, null);
            Assert.That(account.MarginSummary!.CurrentMarginLevelPercent, Is.EqualTo(50m), "equity 2.02 over used 4.04");
            Assert.That(account.MarginSummary.MarginCallActive, Is.True, "at or below 50% is a Margin Call");
            Assert.That(account.MarginSummary.MarginCallEpisodes, Is.EqualTo(1));
            Assert.That(account.MarginSummary.MarginCallObservations, Is.EqualTo(1));

            var blocked = account.AssessEntry(new EntryOrder(2, TradeSide.Sell, 0.01m, levelQuote, SizingRegime.Arithmetic, null), basket);
            Assert.That(blocked.Decision, Is.EqualTo(MarginEntryDecision.MarginCall));
            Assert.That(blocked.ProjectedUsedMargin, Is.Null, "the block is enforced before any projection");

            var above = new Quote(Harness.T0.AddSeconds(2), 1022.03m, 1022.23m);
            account.ObserveQuote(above, basket, 0m, null);
            Assert.That(account.MarginSummary!.MarginCallActive, Is.False, "above 50% the state clears");
            Assert.That(account.MarginSummary.MarginCallObservations, Is.EqualTo(1));
            var allowed = account.AssessEntry(new EntryOrder(2, TradeSide.Sell, 0.01m, above, SizingRegime.Arithmetic, null), basket);
            Assert.That(allowed.Decision, Is.EqualTo(MarginEntryDecision.Allowed), "a matching hedge needs no margin");

            account.ObserveQuote(levelQuote, basket, 0m, null);
            Assert.That(account.MarginSummary!.MarginCallActive, Is.True);
            Assert.That(account.MarginSummary.MarginCallEpisodes, Is.EqualTo(2), "a second crossing is a second episode");
            Assert.That(account.MarginSummary.MarginCallObservations, Is.EqualTo(2), "only the observations in Margin Call are counted");
        }

        [Test]
        public void StopOutStartsAtExactlyTwentyPercent()
        {
            var account = NewAccount(1000m);
            var basket = BuyOnlyBasket();
            var boundary = new Quote(Harness.T0.AddSeconds(1), 1020.808m, 1021.008m);
            account.ObserveQuote(boundary, basket, 0m, null);
            Assert.That(account.MarginSummary!.CurrentMarginLevelPercent, Is.EqualTo(20m), "equity 0.808 over used 4.04");

            var stopOut = account.EvaluateSurvival(boundary);
            Assert.That(stopOut, Is.Not.Null, "at or below 20% is terminal");
            Assert.That(stopOut!.Reason, Is.EqualTo(StopOutReason.MarginLevel));
            Assert.That(stopOut.Equity, Is.EqualTo(0.808m));
            Assert.That(stopOut.UsedMargin, Is.EqualTo(4.04m));
            Assert.That(stopOut.FreeMargin, Is.EqualTo(-3.232m));
            Assert.That(stopOut.MarginLevelPercent, Is.EqualTo(20m));
            Assert.That(stopOut.OpenPositions, Is.EqualTo(1));
            Assert.That(account.EvaluateSurvival(boundary), Is.SameAs(stopOut), "the terminal record is idempotent");
        }

        [Test]
        public void JustAboveTwentyPercentSurvives()
        {
            var account = NewAccount(1000m);
            var basket = BuyOnlyBasket();
            var quote = new Quote(Harness.T0.AddSeconds(1), 1020.809m, 1021.009m);
            account.ObserveQuote(quote, basket, 0m, null);

            Assert.That(account.MarginSummary!.CurrentMarginLevelPercent, Is.GreaterThan(20m));
            Assert.That(account.EvaluateSurvival(quote), Is.Null);
            Assert.That(account.MarginSummary.MarginCallActive, Is.True, "still inside the Margin Call band");
        }

        [Test]
        public void OpenPositionsWithNegativeEquityStopOutDespiteZeroUsedMargin()
        {
            var account = NewAccount(-50m);
            var matched = new Basket(1, new Quote(Harness.T0, 1999.9m, 2000.1m), Harness.Defaults());
            matched.AddLeg(new BasketLeg(1, TradeSide.Buy, 0.02m, 2020m, Harness.T0, SizingRegime.Arithmetic));
            matched.AddLeg(new BasketLeg(2, TradeSide.Sell, 0.02m, 1980m, Harness.T0, SizingRegime.Arithmetic));
            var quote = new Quote(Harness.T0.AddSeconds(1), 2000m, 2000.2m);
            account.ObserveQuote(quote, matched, 0m, null);

            Assert.That(account.MarginSummary!.CurrentUsedMargin, Is.EqualTo(0m));
            Assert.That(account.MarginSummary.CurrentMarginLevelPercent, Is.Null, "a matched hedge has no margin level");
            Assert.That(account.MarginSummary.CurrentFreeMargin, Is.EqualTo(-130.4m));

            var stopOut = account.EvaluateSurvival(quote);
            Assert.That(stopOut, Is.Not.Null);
            Assert.That(stopOut!.Reason, Is.EqualTo(StopOutReason.NegativeEquity), "zero used margin must not look infinitely safe");
            Assert.That(stopOut.UsedMargin, Is.EqualTo(0m));
            Assert.That(stopOut.MarginLevelPercent, Is.Null);
            Assert.That(stopOut.Equity, Is.EqualTo(-130.4m));
        }

        [Test]
        public void FlatAccountHasNoMarginStateAndNeverStopsOut()
        {
            var account = NewAccount(-50m);
            var quote = new Quote(Harness.T0, 2000m, 2000.2m);
            account.ObserveQuote(quote, null, 0m, null);

            var m = account.MarginSummary!;
            Assert.That(m.CurrentUsedMargin, Is.EqualTo(0m));
            Assert.That(m.CurrentFreeMargin, Is.EqualTo(-50m), "free margin is the balance when nothing is required");
            Assert.That(m.CurrentMarginLevelPercent, Is.Null);
            Assert.That(m.MarginCallActive, Is.False);
            Assert.That(account.EvaluateSurvival(quote), Is.Null, "a flat account has nothing to liquidate");

            var empty = new Basket(1, quote, Harness.Defaults());
            var assessment = account.AssessEntry(new EntryOrder(1, TradeSide.Buy, 0.01m, quote, SizingRegime.Arithmetic, null), empty);
            Assert.That(assessment.Decision, Is.EqualTo(MarginEntryDecision.InsufficientMargin), "the negative balance cannot finance any positive requirement");
        }

        [Test]
        public void CandidateIncreasingMarginIsRejectedWhileHedgeIncreasingCandidateIsAllowed()
        {
            var account = NewAccount(100m);
            var basket = new Basket(1, new Quote(Harness.T0, 1999.9m, 2000.1m), Harness.Defaults());
            basket.AddLeg(new BasketLeg(1, TradeSide.Buy, 0.04m, 2020m, Harness.T0, SizingRegime.Arithmetic));
            basket.AddLeg(new BasketLeg(2, TradeSide.Sell, 0.02m, 1980m, Harness.T0, SizingRegime.Arithmetic));
            var quote = new Quote(Harness.T0.AddSeconds(1), 2020m, 2020.2m);
            account.ObserveQuote(quote, basket, 0m, null);

            var m = account.MarginSummary!;
            Assert.That(m.CurrentUsedMargin, Is.EqualTo(8.08m));
            Assert.That(m.CurrentFreeMargin, Is.EqualTo(11.52m), "equity 19.6 less used 8.08");

            var sameSide = account.AssessEntry(new EntryOrder(3, TradeSide.Buy, 0.04m, quote, SizingRegime.Arithmetic, null), basket);
            Assert.That(sameSide.Decision, Is.EqualTo(MarginEntryDecision.InsufficientMargin));
            Assert.That(sameSide.ProjectedUsedMargin, Is.EqualTo(24.2412m));
            Assert.That(sameSide.ProjectedFreeMargin, Is.EqualTo(-4.6412m));

            var hedge = account.AssessEntry(new EntryOrder(3, TradeSide.Sell, 0.02m, quote, SizingRegime.Arithmetic, null), basket);
            Assert.That(hedge.Decision, Is.EqualTo(MarginEntryDecision.Allowed));
            Assert.That(hedge.ProjectedUsedMargin, Is.EqualTo(0m), "the fill matches the remaining uncovered BUY volume");
            Assert.That(hedge.ProjectedFreeMargin, Is.EqualTo(19.6m));
            Assert.That(hedge.ProjectedUsedMargin, Is.LessThan(m.CurrentUsedMargin));
        }

        [Test]
        public void ZeroProjectedFreeMarginIsStillFeasible()
        {
            var quote = new Quote(Harness.T0.AddSeconds(1), 2019.8m, 2020m);
            var empty = new Basket(1, new Quote(Harness.T0, 1999.9m, 2000.1m), Harness.Defaults());

            // 0.5 lot at 2020 needs exactly 202: non-negative projected free margin is feasible.
            var exact = NewAccount(202m);
            exact.ObserveQuote(quote, empty, 0m, null);
            var boundary = exact.AssessEntry(new EntryOrder(1, TradeSide.Buy, 0.5m, quote, SizingRegime.Arithmetic, null), empty);
            Assert.That(boundary.ProjectedUsedMargin, Is.EqualTo(202m));
            Assert.That(boundary.ProjectedFreeMargin, Is.EqualTo(0m));
            Assert.That(boundary.Decision, Is.EqualTo(MarginEntryDecision.Allowed));

            var thin = NewAccount(201.99m);
            thin.ObserveQuote(quote, empty, 0m, null);
            var rejected = thin.AssessEntry(new EntryOrder(1, TradeSide.Buy, 0.5m, quote, SizingRegime.Arithmetic, null), empty);
            Assert.That(rejected.ProjectedFreeMargin, Is.EqualTo(-0.01m));
            Assert.That(rejected.Decision, Is.EqualTo(MarginEntryDecision.InsufficientMargin));
        }

        [Test]
        public void ASkippedExecutableMarkStillObservesTheUsedMargin()
        {
            // The account keeps its PR 2 skip semantics: used margin (pure inventory) is still
            // observed, while the equity-dependent margin state stays as of the last observable
            // mark and SurvivalObservable is false. The engine does not evaluate survival from
            // that state; it stops the run explicitly (MarginEngineSurvivalTests).
            var p = Harness.Defaults() with { Slippage = 2500m };
            var account = new SingleAnchorResearchAccount(p, 1000m, Harness.MarginDefaults());
            var basket = BuyOnlyBasket();

            var skipped = new Quote(Harness.T0.AddSeconds(1), 2019.8m, 2020m);
            account.ObserveQuote(skipped, basket, 0m, null);

            Assert.That(account.FloatingObservable, Is.False, "bid - 2500 is not a usable close price");
            Assert.That(account.SurvivalObservable, Is.False, "the engine must not use this state for survival");
            Assert.That(account.FloatingObservationsSkipped, Is.EqualTo(1));
            Assert.That(account.MarginSummary!.MaxUsedMargin, Is.EqualTo(4.04m), "used margin needs no price and is still observed");
            Assert.That(account.MarginSummary.CurrentUsedMargin, Is.EqualTo(0m), "the margin state stays as of the last observable mark");
            Assert.That(account.MarginSummary.CurrentFreeMargin, Is.EqualTo(1000m));
            Assert.That(account.MarginSummary.CurrentMarginLevelPercent, Is.Null);

            var valid = new Quote(Harness.T0.AddSeconds(2), 5000m, 5000.2m);
            account.ObserveQuote(valid, basket, 0m, null);

            Assert.That(account.FloatingObservable, Is.True);
            Assert.That(account.SurvivalObservable, Is.True, "an observable mark makes the survival state current again");
            Assert.That(account.FloatingProfit, Is.EqualTo(480m), "raw 2980 less 2500 slippage cost");
            Assert.That(account.MarginSummary.CurrentUsedMargin, Is.EqualTo(4.04m));
            Assert.That(account.MarginSummary.CurrentFreeMargin, Is.EqualTo(1475.96m));
            Assert.That(account.MarginSummary.CurrentMarginLevelPercent, Is.EqualTo(MarginModel.MarginLevelPercent(1480m, 4.04m)));
        }

        [Test]
        public void ClosedBasketReturnsTheAccountToZeroMargin()
        {
            var h = new Harness(Harness.Defaults(), null, 1000m, new MarginParameters());
            h.Anchor();
            h.AtUpper();
            h.AtLower();
            var account = h.ResearchAccount!;
            Assert.That(account.MarginSummary!.CurrentUsedMargin, Is.EqualTo(3.96m));

            h.Feed(1900m, 1900.2m); // escape closes the two-leg basket at 39.6

            Assert.That(h.BasketsClosed, Has.Count.EqualTo(1));
            var m = account.MarginSummary!;
            Assert.That(m.CurrentUsedMargin, Is.EqualTo(0m));
            Assert.That(m.CurrentFreeMargin, Is.EqualTo(1039.6m));
            Assert.That(m.CurrentMarginLevelPercent, Is.Null);
            Assert.That(m.MarginCallActive, Is.False);
            Assert.That(m.StopOut, Is.Null);
            Assert.That(m.MaxUsedMargin, Is.EqualTo(4.04m), "the one-leg BUY state used the most margin before the hedge existed");
        }

        [Test]
        public void InitialBalanceChangesSurvivalOnTheSamePath()
        {
            // Same basket and quote: a 44-balance account is stopped out, a 1000-balance account
            // survives. (44 is the smallest balance that lets the two-leg basket open: the SELL
            // entry at 1980 needs equity 4.0 over used 4.04, just above the 50% entry block.)
            var poor = new Harness(Harness.Defaults(), null, 44m, new MarginParameters());
            poor.Anchor();
            poor.AtUpper();
            poor.AtLower();
            Assert.That(poor.Engine.Basket!.OpenPositions, Is.EqualTo(2));
            var crash = new Quote(Harness.T0.AddSeconds(3), 2100m, 2100.2m);
            poor.ResearchAccount!.ObserveQuote(crash, poor.Engine.Basket, 0m, null);
            var stopOut = poor.ResearchAccount.EvaluateSurvival(crash);
            Assert.That(stopOut, Is.Not.Null);
            Assert.That(stopOut!.Equity, Is.EqualTo(-116.4m), "44 - 160.4 floating");

            var rich = new Harness(Harness.Defaults(), null, 1000m, new MarginParameters());
            rich.Anchor();
            rich.AtUpper();
            rich.AtLower();
            rich.Feed(2100m, 2100.2m);
            Assert.That(rich.Engine.Fault, Is.Null);
            Assert.That(rich.ResearchAccount!.MarginSummary!.StopOut, Is.Null);
        }
    }

    /// <summary>
    /// Engine-level PR 3 entry feasibility and the frozen survival order (roadmap sections 3.18
    /// to 3.20): the Margin Call block, InsufficientMargin as a distinct rejection that does not
    /// advance the strategy state, retry after a later eligible quote, and stop-out before a
    /// same-quote strategy rescue.
    /// </summary>
    [TestFixture]
    public class MarginEngineSurvivalTests
    {
        private static Harness NewMarginHarness(SingleAnchorParameters? parameters, decimal balance)
        {
            return new Harness(parameters ?? Harness.Defaults(), null, balance, new MarginParameters());
        }

        [Test]
        public void MarginCallBlocksTheEntryWithoutAdvancingTheTrade()
        {
            var h = NewMarginHarness(null, 82m);
            h.Anchor();
            h.AtUpper();
            h.AtLower();
            var basket = h.Engine.Basket!;
            Assert.That(basket.NextTradeNumber, Is.EqualTo(3));

            h.AtUpper(); // trade 3 BUY: equity 1.8 over used 3.96 = 45.45% -> Margin Call

            Assert.That(h.EntriesRejected, Has.Count.EqualTo(1));
            Assert.That(h.EntriesRejected[0].Rejection.Reason, Is.EqualTo(EntryRejectionReason.MarginCall));
            Assert.That(h.EntriesRejected[0].Rejection.NormalizedRequiredLots, Is.EqualTo(0.03m), "the strategy's valid candidate is reported");
            Assert.That(h.ResearchAccount!.MarginSummary!.MarginCallBlockedAttempts, Is.EqualTo(1));
            Assert.That(h.ResearchAccount.MarginSummary.MarginCallBlockedEpisodes, Is.EqualTo(1));

            Assert.That(h.EntriesOpened, Has.Count.EqualTo(2), "no leg was added");
            Assert.That(basket.OpenPositions, Is.EqualTo(2));
            Assert.That(basket.NextTradeNumber, Is.EqualTo(3), "the trade number does not advance");
            Assert.That(basket.NextRequiredSide, Is.EqualTo(TradeSide.Buy), "the required side is unchanged");
            Assert.That(basket.HardBreakevenModeActive, Is.False);

            h.AtUpper(); // a later trigger: the same episode, one bounded row
            Assert.That(h.EntriesRejected, Has.Count.EqualTo(1));
            Assert.That(basket.Rejections, Has.Count.EqualTo(1));
            Assert.That(basket.Rejections[0].Attempts, Is.EqualTo(2));
            Assert.That(h.ResearchAccount.MarginSummary.MarginCallBlockedAttempts, Is.EqualTo(2));
            Assert.That(h.ResearchAccount.MarginSummary.MarginCallBlockedEpisodes, Is.EqualTo(1));
        }

        [Test]
        public void ARecoveredAccountRetriesTheSameBlockedTrade()
        {
            // Exits are off, so the basket persists across the recovery quote: the blocked trade
            // 3 is retried on the next trigger (and folds into the same bounded episode).
            var h = new Harness(Harness.NoExits(), null, 82m, Harness.MarginDefaults());
            h.Anchor();
            h.AtUpper();
            h.AtLower();
            var basket = h.Engine.Basket!;

            h.AtUpper(); // Margin Call block: equity 1.8 over used 3.96 = 45.45%
            Assert.That(h.ResearchAccount!.MarginSummary!.MarginCallBlockedAttempts, Is.EqualTo(1));
            Assert.That(basket.NextTradeNumber, Is.EqualTo(3));

            h.Feed(1900m, 1900.2m); // recovery above 50%, no trigger and (with exits off) no close
            Assert.That(basket.OpenPositions, Is.EqualTo(2));
            Assert.That(h.ResearchAccount.MarginSummary.MarginCallActive, Is.False, "the account recovered above the Margin Call level");
            Assert.That(h.ResearchAccount.MarginSummary.MarginCallBlockedAttempts, Is.EqualTo(1));

            h.AtUpper(); // the same trade is attempted again

            Assert.That(h.ResearchAccount.MarginSummary.MarginCallBlockedAttempts, Is.EqualTo(2), "the later quote retried the entry");
            Assert.That(h.ResearchAccount.MarginSummary.MarginCallBlockedEpisodes, Is.EqualTo(1), "the retry folds into the same episode");
            Assert.That(basket.Rejections, Has.Count.EqualTo(1));
            Assert.That(basket.Rejections[0].Attempts, Is.EqualTo(2));
            Assert.That(basket.NextTradeNumber, Is.EqualTo(3), "the state still did not advance");
        }

        [Test]
        public void RecoveryAndABasketCloseAreFollowedByALaterSuccessfulEntry()
        {
            var h = NewMarginHarness(null, 82m);
            h.Anchor();
            h.AtUpper();
            h.AtLower();
            h.AtUpper(); // Margin Call block for trade 3

            h.Feed(1900m, 1900.2m); // escape (allowed above stop-out) closes the two-leg basket at 39.6

            Assert.That(h.BasketsClosed, Has.Count.EqualTo(1));
            Assert.That(h.Engine.Basket, Is.Null);
            var margin = h.ResearchAccount!.MarginSummary!;
            Assert.That(margin.MarginCallActive, Is.False);
            Assert.That(margin.CurrentUsedMargin, Is.EqualTo(0m));
            Assert.That(margin.CurrentMarginLevelPercent, Is.Null);

            var closed = h.ResearchAccount.BasketRecords[0];
            Assert.That(closed.Rejections, Has.Count.EqualTo(1));
            Assert.That(closed.Rejections[0].Reason, Is.EqualTo(EntryRejectionReason.MarginCall));
            Assert.That(closed.Rejections[0].Attempts, Is.EqualTo(1));

            // A later basket's otherwise valid entry is admitted.
            h.Feed(1899.9m, 1900.1m); // anchor 1900
            h.Feed(1918.8m, 1919m);   // upper 1919: BUY 0.01

            Assert.That(h.AnchorsCreated, Has.Count.EqualTo(2));
            Assert.That(h.Engine.Basket!.Sequence, Is.EqualTo(2));
            Assert.That(h.EntriesOpened, Has.Count.EqualTo(3));
            Assert.That(h.EntriesOpened[2].Leg.TradeNumber, Is.EqualTo(1));
            Assert.That(h.EntriesOpened[2].Leg.Side, Is.EqualTo(TradeSide.Buy));
        }

        [Test]
        public void InsufficientMarginRejectsWithoutAdvancingAndASharperQuoteCanRetry()
        {
            var h = NewMarginHarness(null, 88.5m);
            h.Anchor();
            h.AtUpper();
            h.AtLower();
            var basket = h.Engine.Basket!;

            var wide = h.Feed(2020.2m, 2020.4m); // trade 3 BUY 0.03 entry at 2020.4: projected 8.0812 > equity 7.9

            Assert.That(h.EntriesRejected, Has.Count.EqualTo(1));
            var rejection = h.EntriesRejected[0].Rejection;
            Assert.That(rejection.Reason, Is.EqualTo(EntryRejectionReason.InsufficientMargin));
            Assert.That(rejection.TradeNumber, Is.EqualTo(3));
            Assert.That(rejection.ProjectedUsedMargin, Is.EqualTo(8.0812m));
            Assert.That(rejection.ProjectedFreeMargin, Is.EqualTo(-0.1812m));
            Assert.That(basket.OpenPositions, Is.EqualTo(2), "no leg was added");
            Assert.That(basket.NextTradeNumber, Is.EqualTo(3), "the trade number does not advance");
            Assert.That(h.ResearchAccount!.MarginSummary!.InsufficientMarginAttempts, Is.EqualTo(1));
            Assert.That(h.ResearchAccount.MarginSummary.InsufficientMarginEpisodes, Is.EqualTo(1));

            var record = basket.Rejections[0];
            Assert.That(record.ProjectedUsedMargin, Is.EqualTo(8.0812m));
            Assert.That(record.MinProjectedFreeMargin, Is.EqualTo(-0.1812m));
            Assert.That(record.MaxProjectedFreeMargin, Is.EqualTo(-0.1812m));

            h.Feed(2020m, 2020m); // zero-spread quote at the boundary: projected 8.08 <= equity 8.5

            Assert.That(h.EntriesOpened, Has.Count.EqualTo(3));
            Assert.That(basket.OpenPositions, Is.EqualTo(3), "the later eligible quote retried successfully");
            Assert.That(basket.NextTradeNumber, Is.EqualTo(4));
            Assert.That(basket.Legs[2].Lots, Is.EqualTo(0.03m));
            Assert.That(basket.Legs[2].EntryPrice, Is.EqualTo(2020m));
            Assert.That(h.EntriesRejected, Has.Count.EqualTo(1), "the successful retry is not another rejection episode");
        }

        [Test]
        public void InsufficientMarginIsDistinctFromHardBreakevenInfeasibility()
        {
            var p = Harness.Defaults() with { MaximumVolume = 0.05m };
            var h = NewMarginHarness(p, 1_000_000m);
            h.PingPongFourLegs();
            h.AtUpper(); // trade 5 requires 0.06 > maximum 0.05

            Assert.That(h.EntriesRejected, Has.Count.EqualTo(1));
            Assert.That(h.EntriesRejected[0].Rejection.Reason, Is.EqualTo(EntryRejectionReason.HardBreakevenInfeasible));
            Assert.That(h.ResearchAccount!.MarginSummary!.InsufficientMarginAttempts, Is.EqualTo(0));
            Assert.That(h.ResearchAccount.MarginSummary.MarginCallBlockedAttempts, Is.EqualTo(0));
            Assert.That(h.Engine.Basket!.Rejections[0].Reason, Is.EqualTo(EntryRejectionReason.HardBreakevenInfeasible));
        }

        [Test]
        public void AnUnfinancedHardBreakevenTailKeepsHardBreakevenModeActive()
        {
            var h = new Harness(Harness.Defaults(), null, 250m, Harness.MarginDefaults());
            h.PingPongFourLegs();
            var basket = h.Engine.Basket!;

            h.AtUpper(); // trade 5 BUY 0.06: the sizing is feasible, the projected margin is not

            Assert.That(h.EntriesRejected, Has.Count.EqualTo(1), "the candidate is a valid hard-BE sizing, so the rejection is the margin, not hard-BE infeasibility");
            var rejection = h.EntriesRejected[0].Rejection;
            Assert.That(rejection.Reason, Is.EqualTo(EntryRejectionReason.InsufficientMargin));
            Assert.That(rejection.TradeNumber, Is.EqualTo(5));
            Assert.That(rejection.Sizing.HasValue, Is.True);
            Assert.That(rejection.Sizing!.Value.Outcome, Is.EqualTo(HardBreakevenOutcome.Feasible));
            Assert.That(rejection.ProjectedUsedMargin, Is.EqualTo(16.16m), "BUY 0.10 against SELL 0.06: uncovered 0.04 at 2020");
            Assert.That(rejection.ProjectedFreeMargin, Is.EqualTo(-6.96m), "equity 9.2 less projected 16.16");

            Assert.That(basket.OpenPositions, Is.EqualTo(4), "no leg was added");
            Assert.That(basket.NextTradeNumber, Is.EqualTo(5), "the trade number does not advance");
            Assert.That(basket.NextRequiredSide, Is.EqualTo(TradeSide.Buy));
            Assert.That(basket.HardBreakevenModeActive, Is.True, "hard-BE mode remains active after the financing rejection");
            var active = h.ResearchAccount!.SnapshotActiveBasket(basket)!;
            Assert.That(active.HardBreakevenModeActivated, Is.True);
            Assert.That(active.FirstHardBreakevenTradeNumber, Is.EqualTo(5));
        }

        [Test]
        public void InsufficientMarginIsDistinctFromExecutionFailure()
        {
            var h = NewMarginHarness(null, 1_000_000m);
            h.PingPongFourLegs();
            h.Executor.EntryOverride = order => order.TradeNumber == 5
                ? EntryExecution.Failure("injected execution failure")
                : EntryExecution.Filled(BasketEconomics.ExecutableEntryPrice(order.Side, order.Quote, h.Parameters));
            h.AtUpper();

            Assert.That(h.EntriesRejected, Has.Count.EqualTo(1));
            Assert.That(h.EntriesRejected[0].Rejection.Reason, Is.EqualTo(EntryRejectionReason.ExecutionFailed));
            Assert.That(h.ResearchAccount!.MarginSummary!.InsufficientMarginAttempts, Is.EqualTo(0));
            Assert.That(h.Engine.Basket!.Rejections[0].Reason, Is.EqualTo(EntryRejectionReason.ExecutionFailed));
        }

        [Test]
        public void AFillThatImmediatelyStopsOutIsTerminalOnTheSameQuote()
        {
            // Equity 4.05 finances the 4.04 projected margin of a 0.01 BUY at 2020, but the fill's
            // immediate mark at the same quote's bid 2010 is -10: the post-fill account is
            // terminal and must not be allowed to wait for a next quote that may never come.
            var h = new Harness(Harness.Defaults(), null, 4.05m, Harness.MarginDefaults());
            h.Anchor();

            var failure = Assert.Throws<AccountStopOutException>(() => h.Feed(2010m, 2020m));

            Assert.That(failure!.Kind, Is.EqualTo("AccountStopOut"));
            Assert.That(h.BasketsClosed, Is.Empty);
            Assert.That(h.Engine.Basket!.OpenPositions, Is.EqualTo(1), "the filled leg stays in the ledger and in the terminal state");
            Assert.That(h.Engine.EntriesOpened, Is.EqualTo(0), "the fill is not published as a normal successful entry");
            Assert.That(h.Executor.Entries, Has.Count.EqualTo(1), "the executor did fill the order");

            var stopOut = h.ResearchAccount!.MarginSummary!.StopOut;
            Assert.That(stopOut, Is.Not.Null);
            Assert.That(stopOut!.Time, Is.EqualTo(h.Engine.LastProcessedQuote!.Value.Time));
            Assert.That(stopOut.Equity, Is.EqualTo(-5.95m), "balance 4.05 plus the immediate -10 mark");
            Assert.That(stopOut.FloatingProfit, Is.EqualTo(-10m));
            Assert.That(stopOut.UsedMargin, Is.EqualTo(4.04m));
            Assert.That(stopOut.OpenPositions, Is.EqualTo(1));
            Assert.Throws<AccountStopOutException>(() => h.Feed(2000m, 2000.2m), "a faulted engine refuses every further quote");
        }

        [Test]
        public void AnUnobservableExecutableMarkStopsTheRunExplicitly()
        {
            // With pathological slippage the post-fill executable close price is not positive, so
            // the current account state is undefined: survival cannot be certified from the stale
            // pre-fill state, and the run stops instead of continuing.
            var p = Harness.Defaults() with { Slippage = 2500m };
            var h = new Harness(p, null, 1000m, Harness.MarginDefaults());
            h.Anchor();

            var failure = Assert.Throws<AccountSurvivalException>(() => h.Feed(2019.8m, 2020m));

            Assert.That(failure!.Kind, Is.EqualTo("AccountSurvival"));
            Assert.That(failure.Condition, Is.EqualTo("ExecutableMarkUnavailable"));
            Assert.That(h.Engine.Basket!.OpenPositions, Is.EqualTo(1), "the fill happened and stays in the ledger");
            Assert.That(h.Engine.EntriesOpened, Is.EqualTo(0));
            Assert.That(h.Engine.Fault, Is.SameAs(failure));
            Assert.That(h.ResearchAccount!.MarginSummary!.StopOut, Is.Null, "this is not a stop-out: survival could not be established");
            Assert.That(h.ResearchAccount.FloatingObservable, Is.False);
            Assert.That(h.ResearchAccount.FloatingObservationsSkipped, Is.EqualTo(1));
            Assert.Throws<AccountSurvivalException>(() => h.Feed(3000m, 3000.2m), "a faulted engine refuses every further quote");
        }

        [Test]
        public void MarginCallDoesNotBlockNormalBasketExits()
        {
            // The account is alive (survival returns null) but every entry is Margin Call blocked;
            // an escape exit must still execute. The engine consults the guard for survival and
            // entries only, never for exits.
            var p = Harness.Defaults();
            var executor = new SyntheticExecutor(p);
            var guard = new StubRiskGuard();
            var engine = new SingleAnchorEngine(p, executor, null, null, guard);
            engine.OnQuote(new Quote(Harness.T0, 1999.9m, 2000.1m));
            engine.OnQuote(new Quote(Harness.T0.AddSeconds(1), 2019.8m, 2020m));
            engine.OnQuote(new Quote(Harness.T0.AddSeconds(2), 1980m, 1980.2m));
            Assert.That(engine.Basket!.OpenPositions, Is.EqualTo(2));
            // Three processed quotes plus the two post-fill survival checks of the two entries.
            Assert.That(guard.SurvivalChecks, Is.EqualTo(5), "survival is asked on every processed quote and after every fill");

            // The account stays alive but every further entry would be Margin Call blocked.
            guard.NextEntryDecision = MarginEntryDecision.MarginCall;
            engine.OnQuote(new Quote(Harness.T0.AddSeconds(3), 1900m, 1900.2m)); // escape at profit 39.6

            Assert.That(engine.BasketsClosed, Is.EqualTo(1));
            Assert.That(executor.Closes, Has.Count.EqualTo(1));
            Assert.That(engine.RealizedProfit, Is.EqualTo(39.6m));
        }

        [Test]
        public void StopOutPrecedesASameQuoteStrategyRescue()
        {
            // A stop-out state on the very quote whose escape would close the basket: the guard
            // is asked before the exit evaluation, so the run stops and the basket is not closed.
            var p = Harness.Defaults();
            var executor = new SyntheticExecutor(p);
            var guard = new StubRiskGuard();
            var engine = new SingleAnchorEngine(p, executor, null, null, guard);
            engine.OnQuote(new Quote(Harness.T0, 1999.9m, 2000.1m));
            engine.OnQuote(new Quote(Harness.T0.AddSeconds(1), 2019.8m, 2020m));
            engine.OnQuote(new Quote(Harness.T0.AddSeconds(2), 1980m, 1980.2m));
            var basket = engine.Basket!;
            Assert.That(basket.OpenPositions, Is.EqualTo(2));

            guard.NextStopOut = new MarginStopOut(StopOutReason.MarginLevel, Harness.T0.AddSeconds(3), 0m, 0m, 0.6m, 3.96m, -3.36m, 15.1515m, 2);
            var failure = Assert.Throws<AccountStopOutException>(() => engine.OnQuote(new Quote(Harness.T0.AddSeconds(3), 1900m, 1900.2m)));

            Assert.That(failure!.Kind, Is.EqualTo("AccountStopOut"));
            Assert.That(failure.Condition, Is.EqualTo("MarginLevel"));
            Assert.That(engine.ClosedBaskets, Is.Empty, "the escape exit that would have fired is not allowed to rescue the account");
            Assert.That(executor.Closes, Is.Empty, "the executor was never asked to close");
            Assert.That(basket.OpenPositions, Is.EqualTo(2), "no broker liquidation is simulated");
            Assert.That(engine.Fault, Is.SameAs(failure));
            Assert.Throws<AccountStopOutException>(() => engine.OnQuote(new Quote(Harness.T0.AddSeconds(4), 1900m, 1900.2m)), "a faulted engine refuses every further quote");

            // The same path without a risk guard closes the basket at that quote.
            var plain = new Harness(Harness.Defaults(), null, 1000m);
            plain.Anchor();
            plain.AtUpper();
            plain.AtLower();
            plain.Feed(1900m, 1900.2m);
            Assert.That(plain.BasketsClosed, Has.Count.EqualTo(1), "without PR 3 the escape would have rescued the basket");
        }

        [Test]
        public void StopOutAtExactlyTwentyPercentStopsTheRun()
        {
            var h = NewMarginHarness(null, 61.192m);
            h.Anchor();
            h.AtUpper();
            h.AtLower();

            var failure = Assert.Throws<AccountStopOutException>(() => h.Feed(2000m, 2000.2m));

            Assert.That(failure!.Condition, Is.EqualTo("MarginLevel"));
            var stopOut = h.ResearchAccount!.MarginSummary!.StopOut!;
            Assert.That(stopOut.MarginLevelPercent, Is.EqualTo(20m));
            Assert.That(stopOut.Equity, Is.EqualTo(0.792m));
        }

        [Test]
        public void JustAboveTheStopOutBoundaryContinuesInMarginCall()
        {
            var h = NewMarginHarness(null, 61.193m);
            h.Anchor();
            h.AtUpper();
            h.AtLower();
            h.Feed(2000m, 2000.2m);

            Assert.That(h.Engine.Fault, Is.Null);
            Assert.That(h.ResearchAccount!.MarginSummary!.StopOut, Is.Null);
            Assert.That(h.ResearchAccount.MarginSummary.MarginCallActive, Is.True);
        }

        [Test]
        public void StopOutIsEvaluatedOnAQuoteOnlyBufferQuote()
        {
            var sessions = new[] { new HistoricalSession(new DateTime(2024, 1, 2, 9, 0, 0), new DateTime(2024, 1, 2, 9, 30, 0)) };
            var h = new Harness(Harness.Defaults(), new HistoricalTradingAvailability(sessions), 20.808m, new MarginParameters());
            h.FeedAt(new DateTime(2024, 1, 2, 9, 6, 0), 1999.9m, 2000.1m);
            h.FeedAt(new DateTime(2024, 1, 2, 9, 6, 1), 2019.8m, 2020m); // BUY 0.01 at 2020
            Assert.That(h.ResearchAccount!.MarginSummary!.CurrentUsedMargin, Is.EqualTo(4.04m));

            // 09:26 is in the closing buffer: no strategy action, but the account still revalues
            // and stop-out is terminal (equity 0.808 over used 4.04 = 20%).
            var failure = Assert.Throws<AccountStopOutException>(() => h.FeedAt(new DateTime(2024, 1, 2, 9, 26, 0), 2000m, 2000.2m));

            Assert.That(failure!.Condition, Is.EqualTo("MarginLevel"));
            Assert.That(h.Engine.QuoteOnlyQuotes, Is.EqualTo(1));
            Assert.That(h.BasketsClosed, Is.Empty);
        }

        [Test]
        public void NegativeEquityWithOpenPositionsStopsTheEnginePath()
        {
            var h = NewMarginHarness(null, 44m);
            h.Anchor();
            h.AtUpper();
            h.AtLower();
            Assert.That(h.Engine.Basket!.OpenPositions, Is.EqualTo(2));

            var failure = Assert.Throws<AccountStopOutException>(() => h.Feed(2000m, 2000.2m));

            Assert.That(failure!.Condition, Is.EqualTo("MarginLevel"), "negative equity with a charged uncovered side reports the level rule");
            Assert.That(h.ResearchAccount!.MarginSummary!.StopOut!.Equity, Is.EqualTo(-16.4m), "44 - 60.4 floating");
            Assert.That(h.ResearchAccount.MarginSummary.StopOut.OpenPositions, Is.EqualTo(2));
        }
    }

    /// <summary>
    /// Roadmap section 3.21: risk-disabled runs must reproduce the pre-PR-3 strategy path exactly,
    /// and enabling margin on an account that never binds must not change it either.
    /// </summary>
    [TestFixture]
    public class MarginRiskDisabledParityTests
    {
        [Test]
        public void DisablingMarginAndEvenEnablingItWithoutBindingChangesNoStrategyOutcome()
        {
            var p = Harness.Defaults() with
            {
                StepPercent = 0.5m,
                HardBreakevenCeilingPercent = 0.3m,
                MaximumVolume = 0.05m
            };
            var marginEnabled = new Harness(p, null, 1_000_000m, new MarginParameters());
            var accountOnly = new Harness(p, null, 1_000_000m);
            var noAccount = new Harness(p);

            foreach (var quote in DeterministicStream())
            {
                marginEnabled.Engine.OnQuote(quote);
                accountOnly.Engine.OnQuote(quote);
                noAccount.Engine.OnQuote(quote);
            }

            Assert.That(marginEnabled.Engine.EntriesOpened, Is.GreaterThan(0), "the stream must exercise entries");
            Assert.That(marginEnabled.Engine.BasketsClosed, Is.GreaterThan(0), "the stream must exercise closes");
            Assert.That(marginEnabled.Engine.RejectedEntryAttempts, Is.GreaterThan(0), "the stream must exercise rejected attempts");
            Assert.That(marginEnabled.ResearchAccount!.MarginSummary!.MaxUsedMargin, Is.GreaterThan(0m), "the margin layer observed real inventory");
            Assert.That(marginEnabled.ResearchAccount.MarginSummary.StopOut, Is.Null);
            Assert.That(marginEnabled.ResearchAccount.MarginSummary.InsufficientMarginAttempts, Is.EqualTo(0));
            Assert.That(marginEnabled.ResearchAccount.MarginSummary.MarginCallBlockedAttempts, Is.EqualTo(0));
            Assert.That(accountOnly.ResearchAccount!.MarginSummary, Is.Null, "no margin parameters: no margin block");
            Assert.That(noAccount.ResearchAccount, Is.Null);

            var projection = StrategyProjection(marginEnabled.Engine);
            Assert.That(StrategyProjection(accountOnly.Engine), Is.EqualTo(projection));
            Assert.That(StrategyProjection(noAccount.Engine), Is.EqualTo(projection));
            Assert.That(marginEnabled.Engine.QuotesProcessed, Is.EqualTo(accountOnly.Engine.QuotesProcessed));
            Assert.That(marginEnabled.Engine.RealizedProfit, Is.EqualTo(accountOnly.Engine.RealizedProfit));
        }

        [Test]
        public void AMarginGuardWithoutAnAccountObserverStillFailsExplicitly()
        {
            // The engine itself does not require an observer, but an account created without
            // margin parameters refuses the risk-guard role instead of fabricating account state.
            var account = new SingleAnchorResearchAccount(Harness.Defaults(), 1000m);
            Assert.That(account.MarginSummary, Is.Null);
            Assert.Throws<InvalidOperationException>(() => account.EvaluateSurvival(new Quote(Harness.T0, 2000m, 2000.2m)));
            Assert.Throws<InvalidOperationException>(() => account.AssessEntry(
                new EntryOrder(1, TradeSide.Buy, 0.01m, new Quote(Harness.T0, 2000m, 2000.2m), SizingRegime.Arithmetic, null),
                new Basket(1, new Quote(Harness.T0, 1999.9m, 2000.1m), Harness.Defaults())));
        }

        private static List<Quote> DeterministicStream()
        {
            var quotes = new List<Quote>();
            var time = new DateTime(2024, 3, 1, 0, 0, 0);
            var price = 2000m;
            quotes.Add(new Quote(time, price, price + 0.2m));
            quotes.Add(new Quote(time.AddMilliseconds(1), price - 30m, price + 30m));
            var seed = 987654321;
            for (var i = 1; i < 3000; i++)
            {
                seed = (int)((seed * 1103515245L + 12345L) & 0x7fffffffL);
                var delta = ((seed % 11) - 5) * 0.9m;
                price = Math.Clamp(price + delta, 1850m, 2150m);
                quotes.Add(new Quote(time.AddSeconds(i), price, price + 0.2m));
            }
            return quotes;
        }

        private static string StrategyProjection(SingleAnchorEngine engine)
        {
            var payload = new
            {
                engine.QuotesProcessed,
                engine.QuoteOnlyQuotes,
                engine.StrategyEligibleQuotes,
                engine.EntriesOpened,
                engine.EntriesRejected,
                engine.RejectedEntryAttempts,
                engine.SkippedFirstEntryQuotes,
                engine.BasketsClosed,
                engine.RealizedProfit,
                ClosedBaskets = engine.ClosedBaskets,
                LastProcessedQuote = engine.LastProcessedQuote,
                OpenBasket = engine.LastProcessedQuote.HasValue ? engine.MarkToMarket(engine.LastProcessedQuote.Value) : null
            };
            return JsonSerializer.Serialize(payload);
        }
    }

    /// <summary>
    /// Bounded retention and per-quote work with margin enabled (roadmap section 3.15): a
    /// persisting rejection stays one episode row, and the steady-state observation path allocates
    /// nothing.
    /// </summary>
    [TestFixture]
    public class MarginBoundednessTests
    {
        [Test]
        public void APersistingInsufficientMarginStaysCompact()
        {
            var p = Harness.Defaults() with { BaseLot = 1m };
            var h = new Harness(p, null, 100m, new MarginParameters());
            h.Anchor();
            var basket = h.Engine.Basket!;

            for (var i = 0; i < 100_000; i++)
            {
                h.AtUpper();
            }

            Assert.That(h.Engine.RejectedEntryAttempts, Is.EqualTo(100_000));
            Assert.That(h.Engine.EntriesRejected, Is.EqualTo(1), "one bounded episode row");
            Assert.That(basket.Rejections, Has.Count.EqualTo(1));
            Assert.That(basket.Rejections[0].Reason, Is.EqualTo(EntryRejectionReason.InsufficientMargin));
            Assert.That(basket.Rejections[0].Attempts, Is.EqualTo(100_000));
            Assert.That(h.ResearchAccount!.MarginSummary!.InsufficientMarginAttempts, Is.EqualTo(100_000));
            Assert.That(h.ResearchAccount.MarginSummary.InsufficientMarginEpisodes, Is.EqualTo(1));
            Assert.That(basket.OpenPositions, Is.EqualTo(0), "no leg was ever added");
        }

        [Test]
        public void ObservingQuotesWithMarginAllocatesNothingOnTheSteadyStatePath()
        {
            var account = new SingleAnchorResearchAccount(Harness.Defaults(), 1000m, new MarginParameters());
            var basket = new Basket(1, new Quote(Harness.T0, 1999.9m, 2000.1m), Harness.Defaults());
            basket.AddLeg(new BasketLeg(1, TradeSide.Buy, 0.01m, 2020m, Harness.T0, SizingRegime.Arithmetic));
            var quote = new Quote(Harness.T0.AddSeconds(1), 2019.8m, 2020m);

            var allocated = MeasureSteadyStateAllocation(() => account.ObserveQuote(quote, basket, 0m));
            Assert.That(allocated, Is.EqualTo(0), "the margin state update must not allocate");
            Assert.That(account.MarginSummary, Is.Not.Null);
        }

        private static long MeasureSteadyStateAllocation(Action observe)
        {
            var allocated = 0L;
            Exception? failure = null;
            var thread = new System.Threading.Thread(() =>
            {
                try
                {
                    for (var i = 0; i < 1_000_000; i++)
                    {
                        observe();
                    }
                    var before = GC.GetAllocatedBytesForCurrentThread();
                    for (var i = 0; i < 1_000_000; i++)
                    {
                        observe();
                    }
                    allocated = GC.GetAllocatedBytesForCurrentThread() - before;
                }
                catch (Exception error)
                {
                    failure = error;
                }
            });
            thread.Start();
            thread.Join();

            Assert.That(failure, Is.Null);
            return allocated;
        }
    }

    /// <summary>
    /// The new PR 3 evidence serializes with the run results: the margin summary block and the
    /// per-episode projected-margin fields.
    /// </summary>
    [TestFixture]
    public class MarginSerializationTests
    {
        private static readonly JsonSerializerOptions HostLike = new JsonSerializerOptions
        {
            Converters = { new System.Text.Json.Serialization.JsonStringEnumConverter() }
        };

        [Test]
        public void MarginSummarySerializesTheSurvivalEvidence()
        {
            var h = new Harness(Harness.Defaults(), null, 20.808m, new MarginParameters());
            h.Anchor();
            h.AtUpper();

            var json = JsonSerializer.Serialize(h.ResearchAccount!.MarginSummary, HostLike);
            Assert.That(json, Does.Contain("\"CurrentUsedMargin\":4.04"));
            Assert.That(json, Does.Contain("\"MaxUsedMargin\":4.04"));
            Assert.That(json, Does.Contain("\"CurrentMarginLevelPercent\""));
            Assert.That(json, Does.Contain("\"MinFreeMargin\""));
            Assert.That(json, Does.Contain("\"MarginCallActive\""));
            Assert.That(json, Does.Contain("\"MarginCallBlockedAttempts\""));
            Assert.That(json, Does.Contain("\"InsufficientMarginAttempts\""));
            Assert.That(json, Does.Contain("\"StopOut\":null"));
            Assert.That(json, Does.Contain("\"ContractSize\":100"));
            Assert.That(json, Does.Contain("\"Leverage\":500"));
        }

        [Test]
        public void TerminalStopOutAndRejectionEvidenceSerialize()
        {
            var h = new Harness(Harness.Defaults(), null, 61.192m, new MarginParameters());
            h.Anchor();
            h.AtUpper();
            h.AtLower();
            Assert.Throws<AccountStopOutException>(() => h.Feed(2000m, 2000.2m));

            var stopOutJson = JsonSerializer.Serialize(h.ResearchAccount!.MarginSummary, HostLike);
            Assert.That(stopOutJson, Does.Contain("\"StopOut\":{"));
            Assert.That(stopOutJson, Does.Contain("\"Reason\":\"MarginLevel\""));

            var rejections = new Harness(Harness.Defaults(), null, 88.5m, new MarginParameters());
            rejections.Anchor();
            rejections.AtUpper();
            rejections.AtLower();
            rejections.Feed(2020.2m, 2020.4m);
            var recordJson = JsonSerializer.Serialize(rejections.Engine.Basket!.Rejections[0], HostLike);
            Assert.That(recordJson, Does.Contain("\"ProjectedUsedMargin\":8.0812"));
            Assert.That(recordJson, Does.Contain("\"ProjectedFreeMargin\":-0.1812"));
            Assert.That(recordJson, Does.Contain("\"MinProjectedFreeMargin\":-0.1812"));
            Assert.That(recordJson, Does.Contain("\"Reason\":\"InsufficientMargin\""), "the rejection serializes distinctly from hard-BE and execution failures");
        }
    }
}
