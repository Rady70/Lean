using System;
using System.Collections.Generic;
using System.Text.Json;
using System.Text.Json.Serialization;
using NUnit.Framework;

namespace MarketLab.SingleAnchor.Tests
{
    /// <summary>
    /// Phase B deterministic broker-forced liquidation for SingleAnchor: reaching the Stop Out
    /// condition force-closes open positions least-profitable first at the executable market side
    /// of the triggering quote, realizes their P/L, revalues the surviving inventory and continues
    /// processing historical data. Every forced close, Stop Out episode and terminal basket
    /// outcome is recorded so the behavior is independently auditable.
    /// </summary>
    [TestFixture]
    public class LiquidationTests
    {
        private static readonly JsonSerializerOptions HostLike = new JsonSerializerOptions
        {
            Converters = { new JsonStringEnumConverter() }
        };

        /// <summary>
        /// The three-leg reference basket: BUY 0.10 @ 2020, SELL 0.20 @ 1980, BUY 0.30 @ 2020.
        /// At the 1900/1900.2 crash quote it is in Stop Out: uncovered BUY 0.20 uses 80.8 margin
        /// while equity is 11. The least-profitable BUY 0.30 is force-closed, leaving the uncovered
        /// SELL 0.10 (39.6 margin) and a restored 27.78% level.
        /// </summary>
        private static Harness NewPartialLiquidationHarness(decimal balance, bool exits)
        {
            var parameters = (exits ? Harness.Defaults() : Harness.NoExits()) with { BaseLot = 0.10m };
            var h = new Harness(parameters, null, balance, Harness.MarginDefaults());
            h.Anchor();
            h.AtUpper();
            h.AtLower();
            h.AtUpper();
            return h;
        }

        [Test]
        public void OneForcedCloseRestoresTheMarginAndTheSurvivingBasketContinues()
        {
            var h = NewPartialLiquidationHarness(3215m, exits: false);
            Assert.That(h.Engine.Basket!.OpenPositions, Is.EqualTo(3));
            var agreements = new List<bool>();
            h.Engine.ForcedLiquidation += e => agreements.Add(
                h.ResearchAccount!.CurrentOpenPositions == e.Basket.OpenPositions
                && h.ResearchAccount.CurrentGrossLots == e.Basket.GrossLots
                && h.ResearchAccount.CurrentAbsoluteNetLots == Math.Abs(e.Basket.NetLots));

            h.Feed(1900m, 1900.2m);

            Assert.That(h.Engine.Fault, Is.Null);
            Assert.That(h.Engine.BasketsLiquidated, Is.EqualTo(0), "the basket was only partially liquidated");
            Assert.That(h.Engine.BasketsClosed, Is.EqualTo(0), "no strategy exit fired");
            Assert.That(h.Engine.ForcedLiquidations, Is.EqualTo(1));
            Assert.That(h.Engine.RealizedProfit, Is.EqualTo(-3600m));

            var basket = h.Engine.Basket!;
            Assert.That(basket.OpenPositions, Is.EqualTo(2), "the two better positions survive");
            Assert.That(basket.HistoricalEntries, Is.EqualTo(3));
            Assert.That(basket.LiquidatedPositions, Is.EqualTo(1));
            Assert.That(basket.LiquidatedRealizedProfit, Is.EqualTo(-3600m));
            Assert.That(basket.NextTradeNumber, Is.EqualTo(4), "the removed leg does not release its trade number");
            Assert.That(basket.NextRequiredSide, Is.EqualTo(TradeSide.Sell), "the historical sequence says the next leg is SELL");
            Assert.That(basket.LastSide, Is.EqualTo(TradeSide.Buy));
            Assert.That(basket.SmallestOpenLots, Is.EqualTo(0.10m), "recomputed from the surviving inventory");
            Assert.That(basket.BuyLots, Is.EqualTo(0.10m));
            Assert.That(basket.SellLots, Is.EqualTo(0.20m));
            Assert.That(agreements, Has.All.True, "the account and the basket describe the same inventory after the forced close");

            var account = h.ResearchAccount!;
            Assert.That(account.Balance, Is.EqualTo(-385m), "3215 plus the realized -3600");
            Assert.That(account.FloatingProfit, Is.EqualTo(396m), "-1200 on the surviving BUY and +1596 on the surviving SELL");
            Assert.That(account.Equity, Is.EqualTo(11m));
            Assert.That(account.CurrentOpenPositions, Is.EqualTo(basket.OpenPositions));
            Assert.That(account.CurrentGrossLots, Is.EqualTo(basket.GrossLots));
            Assert.That(account.CurrentAbsoluteNetLots, Is.EqualTo(Math.Abs(basket.NetLots)));
            Assert.That(account.BasketRecords, Is.Empty, "the open basket has not closed");

            var margin = account.MarginSummary!;
            Assert.That(margin.CurrentUsedMargin, Is.EqualTo(39.6m), "after the close the uncovered SELL 0.10 at 1980 needs 39.6");
            Assert.That(margin.CurrentUsedMargin, Is.EqualTo(MarginModel.UsedMargin(basket, new MarginParameters())));
            Assert.That(margin.CurrentFreeMargin, Is.EqualTo(11m - 39.6m));
            Assert.That(margin.CurrentMarginLevelPercent, Is.EqualTo(11m / 39.6m * 100m));
            Assert.That(margin.MarginCallActive, Is.True, "27.78% is above Stop Out but inside the Margin Call band");
            Assert.That(margin.ForcedLiquidations, Is.EqualTo(1));

            var episode = margin.StopOutEpisodes[0];
            Assert.That(episode.Basket, Is.EqualTo(1));
            Assert.That(episode.Reason, Is.EqualTo(StopOutReason.MarginLevel));
            Assert.That(episode.Outcome, Is.EqualTo(StopOutEpisodeOutcome.MarginRestored));
            Assert.That(episode.TriggerQuoteSequence, Is.EqualTo(5));
            Assert.That(episode.AtTrigger.UsedMargin, Is.EqualTo(80.8m), "the uncovered BUY 0.20 at 2020");
            Assert.That(episode.AtTrigger.MarginLevelPercent, Is.EqualTo(11m / 80.8m * 100m));
            Assert.That(episode.AtTrigger.OpenPositions, Is.EqualTo(3));

            var liquidation = episode.Liquidations[0];
            Assert.That(liquidation.Leg.TradeNumber, Is.EqualTo(3), "the deepest and least-profitable BUY is liquidated first");
            Assert.That(liquidation.Leg.Side, Is.EqualTo(TradeSide.Buy));
            Assert.That(liquidation.Leg.PlacedLot, Is.EqualTo(0.30m));
            Assert.That(liquidation.Leg.EntryPrice, Is.EqualTo(2020m));
            Assert.That(liquidation.Leg.ClosePrice, Is.EqualTo(1900m), "a BUY closes at the Bid");
            Assert.That(liquidation.Leg.RealizedProfit, Is.EqualTo(-3600m));
            Assert.That(liquidation.Leg.Ordinal, Is.EqualTo(1));
            Assert.That(liquidation.Leg.TriggerQuoteSequence, Is.EqualTo(5));
            Assert.That(liquidation.Leg.LiquidationTime, Is.EqualTo(h.Engine.LastProcessedQuote!.Value.Time));
            Assert.That(liquidation.Before.FloatingProfit, Is.EqualTo(-3204m));
            Assert.That(liquidation.Before.MarginLevelPercent, Is.EqualTo(11m / 80.8m * 100m));
            Assert.That(liquidation.After.Balance, Is.EqualTo(-385m));
            Assert.That(liquidation.After.FloatingProfit, Is.EqualTo(396m), "the floating mark is recomputed from the survivors");
            Assert.That(liquidation.After.Equity, Is.EqualTo(11m));
            Assert.That(liquidation.After.MarginLevelPercent, Is.EqualTo(11m / 39.6m * 100m));

            // Same-quote strategy continuation: the next arithmetic SELL is evaluated, but the
            // account is inside the Margin Call band, so it is blocked. Margin Call is an entry
            // restriction, not a liquidation event.
            Assert.That(h.EntriesRejected, Has.Count.EqualTo(1));
            Assert.That(h.EntriesRejected[0].Rejection.Reason, Is.EqualTo(EntryRejectionReason.MarginCall));
            Assert.That(h.EntriesRejected[0].Rejection.TradeNumber, Is.EqualTo(4));
            Assert.That(margin.MarginCallBlockedAttempts, Is.EqualTo(1));
            Assert.That(basket.OpenPositions, Is.EqualTo(2), "the blocked entry added nothing");

            var snapshot = h.Engine.MarkToMarket(h.Engine.LastProcessedQuote!.Value)!;
            Assert.That(snapshot.LiquidatedPositions, Is.EqualTo(1));
            Assert.That(snapshot.LiquidatedRealizedProfit, Is.EqualTo(-3600m));
            Assert.That(snapshot.LiquidationTrace, Has.Count.EqualTo(1));
            Assert.That(snapshot.NextTradeNumber, Is.EqualTo(4));

            var active = account.SnapshotActiveBasket(basket)!;
            Assert.That(active.EntryCount, Is.EqualTo(3), "the liquidated leg stays in the historical entry count");
            Assert.That(active.DeepestTradeNumber, Is.EqualTo(3));
            Assert.That(active.LiquidatedPositions, Is.EqualTo(1));
            Assert.That(active.LiquidatedRealizedProfit, Is.EqualTo(-3600m));
        }

        [Test]
        public void PartialLiquidationKeepsItsRealizedLossAndTheStrategyClosesTheSurvivors()
        {
            var h = NewPartialLiquidationHarness(3215m, exits: true);

            h.Feed(1900m, 1900.2m);

            Assert.That(h.Engine.ForcedLiquidations, Is.EqualTo(1));
            Assert.That(h.Engine.BasketsLiquidated, Is.EqualTo(0));
            Assert.That(h.Engine.BasketsClosed, Is.EqualTo(1), "after restoration the escape rule closes the surviving basket on the same quote");
            Assert.That(h.Engine.RealizedProfit, Is.EqualTo(-3204m), "the forced -3600 is not discarded; the survivors realize +396");

            var record = h.Engine.ClosedBaskets[0];
            Assert.That(record.Reason, Is.EqualTo(ExitReason.Escape));
            Assert.That(record.Legs, Is.EqualTo(2), "the close record describes the survivors that the strategy closed");
            Assert.That(record.HistoricalEntries, Is.EqualTo(3));
            Assert.That(record.LiquidatedPositions, Is.EqualTo(1));
            Assert.That(record.LiquidatedRealizedProfit, Is.EqualTo(-3600m));
            Assert.That(record.RealizedProfit, Is.EqualTo(-3204m), "the basket's whole realized result includes the forced closes");
            Assert.That(record.LiquidationTrace[0].TradeNumber, Is.EqualTo(3));
            Assert.That(h.ResearchAccount!.Balance, Is.EqualTo(3215m - 3204m));

            var research = h.ResearchAccount.BasketRecords[0];
            Assert.That(research.CloseReason, Is.EqualTo(ExitReason.Escape));
            Assert.That(research.EntryCount, Is.EqualTo(3));
            Assert.That(research.DeepestTradeNumber, Is.EqualTo(3));
            Assert.That(research.LiquidatedPositions, Is.EqualTo(1));
            Assert.That(research.LiquidatedRealizedProfit, Is.EqualTo(-3600m));
            Assert.That(research.RealizedProfit, Is.EqualTo(-3204m));
        }

        [Test]
        public void NonZeroCommissionIsChargedOncePerForcedClose()
        {
            // Same three-leg partial liquidation with a 5-per-lot round-trip commission. The forced
            // close of trade 3 realizes (1900 - 2020) * 0.30 * 100 - 5 * 0.30 = -3601.5, the forced
            // record's commission is 1.5, the surviving escape close realizes 396 - 1.5 = 394.5,
            // and the basket's lifetime realized result is -3207 (no double charge, no loss).
            var parameters = Harness.Defaults() with { BaseLot = 0.10m, CommissionPerLot = 5m };
            var h = new Harness(parameters, null, 3215m, Harness.MarginDefaults());
            h.Anchor();
            h.AtUpper();
            h.AtLower();
            h.AtUpper();

            h.Feed(1900m, 1900.2m);

            var episode = h.ResearchAccount!.MarginSummary!.StopOutEpisodes[0];
            Assert.That(episode.Outcome, Is.EqualTo(StopOutEpisodeOutcome.MarginRestored));
            Assert.That(episode.Liquidations[0].Leg.TradeNumber, Is.EqualTo(3));
            Assert.That(episode.Liquidations[0].Leg.Commission, Is.EqualTo(1.5m));
            Assert.That(episode.Liquidations[0].Leg.RealizedProfit, Is.EqualTo(-3601.5m));
            Assert.That(episode.Liquidations[0].After.Balance, Is.EqualTo(3215m - 3601.5m));
            Assert.That(episode.Liquidations[0].After.Equity, Is.EqualTo(8m), "3215 - 3207: the surviving floating mark carries its own commission");
            Assert.That(episode.Liquidations[0].After.FloatingProfit, Is.EqualTo(394.5m));

            var record = h.Engine.ClosedBaskets[0];
            Assert.That(record.Reason, Is.EqualTo(ExitReason.Escape));
            Assert.That(record.Commission, Is.EqualTo(3m), "the surviving 0.30 lots plus the forced 0.30 lots, each charged once");
            Assert.That(record.LiquidatedRealizedProfit, Is.EqualTo(-3601.5m));
            Assert.That(record.RealizedProfit, Is.EqualTo(-3207m));
            Assert.That(h.Engine.RealizedProfit, Is.EqualTo(-3207m));
            Assert.That(h.ResearchAccount.Balance, Is.EqualTo(8m));
        }

        [Test]
        public void HardBreakevenTailCanBeForceClosedWithoutLosingItsIdentity()
        {
            // The five-leg ladder's tail (trade 5, a hard-BE BUY) is the least-profitable position at
            // a crash and is force-closed first. Its immutable sizing identity stays in the forced
            // record and hard-BE mode and the historical depth are untouched.
            var parameters = Harness.NoExits();
            var executor = new SyntheticExecutor(parameters);
            var guard = new StubRiskGuard();
            var engine = new SingleAnchorEngine(parameters, executor, null, null, guard);
            engine.OnQuote(new Quote(Harness.T0, 1999.9m, 2000.1m));
            engine.OnQuote(new Quote(Harness.T0.AddSeconds(1), 2019.8m, 2020m));
            engine.OnQuote(new Quote(Harness.T0.AddSeconds(2), 1980m, 1980.2m));
            engine.OnQuote(new Quote(Harness.T0.AddSeconds(3), 2019.8m, 2020m));
            engine.OnQuote(new Quote(Harness.T0.AddSeconds(4), 1980m, 1980.2m));
            engine.OnQuote(new Quote(Harness.T0.AddSeconds(5), 2019.8m, 2020m));
            Assert.That(engine.Basket!.HardBreakevenModeActive, Is.True);

            var captured = (LiquidatedLegRecord?)null;
            var capturedOpen = -1;
            var capturedNext = -1;
            engine.ForcedLiquidation += e =>
            {
                captured = e.Record;
                capturedOpen = e.Basket.OpenPositions;
                capturedNext = e.Basket.NextTradeNumber;
            };
            guard.NextStopOut = new MarginStopOut(StopOutReason.MarginLevel, Harness.T0.AddSeconds(6), 0m, 0m, 0.6m, 3.96m, -3.36m, 15.1515m, 5);
            guard.StopOutLimit = 1;
            engine.OnQuote(new Quote(Harness.T0.AddSeconds(6), 1900m, 1900.2m));

            Assert.That(captured, Is.Not.Null);
            Assert.That(captured!.TradeNumber, Is.EqualTo(5), "the tail is the least-profitable position");
            Assert.That(captured.Regime, Is.EqualTo(SizingRegime.HardBreakeven));
            Assert.That(captured.ExactRequiredLot, Is.Not.Null, "the tail's sizing identity survives the removal");
            Assert.That(captured.ClosePrice, Is.EqualTo(1900m));
            Assert.That(capturedOpen, Is.EqualTo(4));
            Assert.That(capturedNext, Is.EqualTo(6), "the removed tail still owns trade number 5");
            Assert.That(engine.Basket!.HardBreakevenModeActive, Is.True);
        }

        [Test]
        public void AFailureAfterASuccessfulForcedCloseKeepsThePartialEvidence()
        {
            // The 61.192-balance basket needs both positions closed to leave Stop Out; the second
            // forced close fails, so the run stops with the first close's P/L, the surviving
            // position and an unresolved episode recorded truthfully.
            var h = new Harness(Harness.NoExits(), null, 61.192m, Harness.MarginDefaults());
            h.Anchor();
            h.AtUpper();
            h.AtLower();
            h.Executor.LegCloseOverride = order => order.Leg.TradeNumber == 2
                ? LegCloseExecution.Closed(BasketEconomics.ExecutableLegClosePrice(order.Leg.Side, order.Quote, h.Parameters))
                : LegCloseExecution.Failure("injected second forced close failure");

            var failure = Assert.Throws<BrokerLiquidationException>(() => h.Feed(2000m, 2000.2m));

            Assert.That(failure!.Condition, Is.EqualTo("ForcedCloseFailed"));
            Assert.That(h.Engine.ForcedLiquidations, Is.EqualTo(1), "the first forced close happened and its P/L is real");
            Assert.That(h.Engine.RealizedProfit, Is.EqualTo(-40.4m));
            Assert.That(h.Engine.Basket!.OpenPositions, Is.EqualTo(1), "the survivor of the first close stays in the ledger");
            Assert.That(h.Engine.Basket.LiquidatedPositions, Is.EqualTo(1));
            Assert.That(h.ResearchAccount!.Balance, Is.EqualTo(61.192m - 40.4m));
            var episode = h.ResearchAccount.MarginSummary!.StopOutEpisodes[0];
            Assert.That(episode.Outcome, Is.Null, "the episode is unresolved and recorded as such");
            Assert.That(episode.Liquidations, Has.Count.EqualTo(1));
            Assert.That(episode.Liquidations[0].Leg.TradeNumber, Is.EqualTo(2));
            Assert.That(episode.AfterLiquidation.Balance, Is.EqualTo(61.192m - 40.4m));
            Assert.That(episode.AfterLiquidation.OpenPositions, Is.EqualTo(1));
            Assert.Throws<BrokerLiquidationException>(() => h.Feed(2001m, 2001.2m));
        }

        [Test]
        public void ForcedLiquidationPreservesTrailingState()
        {
            // Trailing activates on the 1889/1889.2 quote (profit 20.8 over a 20 activation over a
            // 40 step money). The forced close of the losing BUY 0.03 on a later quote must not
            // reset the trailing state or the recorded peak.
            var parameters = Harness.Defaults() with { EscapeEnabled = false, FixedTakeProfitUnits = 0m };
            var executor = new SyntheticExecutor(parameters);
            var guard = new StubRiskGuard();
            var engine = new SingleAnchorEngine(parameters, executor, null, null, guard);
            engine.OnQuote(new Quote(Harness.T0, 1999.9m, 2000.1m));
            engine.OnQuote(new Quote(Harness.T0.AddSeconds(1), 2019.8m, 2020m));
            engine.OnQuote(new Quote(Harness.T0.AddSeconds(2), 1980m, 1980.2m));
            engine.OnQuote(new Quote(Harness.T0.AddSeconds(3), 2019.8m, 2020m));
            engine.OnQuote(new Quote(Harness.T0.AddSeconds(4), 1980m, 1980.2m));
            engine.OnQuote(new Quote(Harness.T0.AddSeconds(5), 1889m, 1889.2m));
            var basket = engine.Basket!;
            Assert.That(basket.TrailingActive, Is.True, "profit 20.8 reaches the 20 activation threshold");
            Assert.That(basket.PeakProfit, Is.EqualTo(20.8m));

            var trailingAtClose = false;
            var peakAtClose = 0m;
            engine.ForcedLiquidation += e =>
            {
                trailingAtClose = e.Basket.TrailingActive;
                peakAtClose = e.Basket.PeakProfit;
            };
            guard.NextStopOut = new MarginStopOut(StopOutReason.MarginLevel, Harness.T0.AddSeconds(6), 0m, 0m, 0.6m, 3.96m, -3.36m, 15.1515m, 4);
            guard.StopOutLimit = 1;
            engine.OnQuote(new Quote(Harness.T0.AddSeconds(6), 1880m, 1880.2m));

            Assert.That(engine.ForcedLiquidations, Is.EqualTo(1));
            Assert.That(trailingAtClose, Is.True, "removing a leg does not reset trailing");
            Assert.That(peakAtClose, Is.EqualTo(20.8m), "the recorded peak is untouched by the forced close");
            Assert.That(engine.Basket!.TrailingActive, Is.True);
            Assert.That(engine.Basket.PeakProfit, Is.EqualTo(458.8m), "the surviving basket keeps trailing from the recorded peak");
            Assert.That(engine.Basket.NextTradeNumber, Is.EqualTo(5));
        }

        [Test]
        public void EqualProfitTiesCloseTheHigherImmutableTradeNumberFirst()
        {
            // At 1993.2/1993.4 the BUY 0.01 @ 2020 and the SELL 0.02 @ 1980 have exactly equal
            // executable P/L: (1993.2 - 2020) * 1 = (1980 - 1993.4) * 2 = -26.8. The documented tie
            // rule closes the higher trade number first, so the ordering never depends on
            // collection iteration or an unstable sort.
            var h = new Harness(Harness.NoExits(), null, 50m, Harness.MarginDefaults());
            h.Anchor();
            h.AtUpper();
            h.AtLower();

            h.Feed(1993.2m, 1993.4m);

            var episode = h.ResearchAccount!.MarginSummary!.StopOutEpisodes[0];
            Assert.That(episode.Liquidations, Has.Count.EqualTo(2));
            Assert.That(episode.Liquidations[0].Leg.RealizedProfit, Is.EqualTo(-26.8m));
            Assert.That(episode.Liquidations[1].Leg.RealizedProfit, Is.EqualTo(-26.8m));
            Assert.That(episode.Liquidations[0].Leg.TradeNumber, Is.EqualTo(2), "the tie is broken by the higher trade number");
            Assert.That(episode.Liquidations[1].Leg.TradeNumber, Is.EqualTo(1));
            Assert.That(episode.Outcome, Is.EqualTo(StopOutEpisodeOutcome.AllPositionsLiquidated));
            Assert.That(h.Engine.RealizedProfit, Is.EqualTo(-53.6m));

            // The same stream twice produces the same ordering and evidence.
            static string Run()
            {
                var replay = new Harness(Harness.NoExits(), null, 50m, Harness.MarginDefaults());
                replay.Anchor();
                replay.AtUpper();
                replay.AtLower();
                replay.Feed(1993.2m, 1993.4m);
                return JsonSerializer.Serialize(
                    new
                    {
                        Episode = replay.ResearchAccount!.MarginSummary!.StopOutEpisodes,
                        Realized = replay.Engine.RealizedProfit,
                        Next = replay.Engine.Basket?.NextTradeNumber
                    },
                    HostLike);
            }
            Assert.That(Run(), Is.EqualTo(Run()));
        }

        [Test]
        public void BuyForcedCloseUsesTheBidLessSlippage()
        {
            var parameters = Harness.NoExits() with { Slippage = 0.5m };
            var h = new Harness(parameters, null, 20m, Harness.MarginDefaults());
            h.Anchor();
            h.AtUpper();
            Assert.That(h.Engine.Basket!.Legs[0].EntryPrice, Is.EqualTo(2020.5m), "a BUY enters at the Ask plus slippage");

            h.Feed(2000m, 2000.2m);

            var liquidation = h.ResearchAccount!.MarginSummary!.StopOutEpisodes[0].Liquidations[0];
            Assert.That(liquidation.Leg.Side, Is.EqualTo(TradeSide.Buy));
            Assert.That(liquidation.Leg.ClosePrice, Is.EqualTo(1999.5m), "a BUY is force-closed at the Bid less slippage");
            Assert.That(liquidation.Leg.RealizedProfit, Is.EqualTo((1999.5m - 2020.5m) * 0.01m * 100m));
            Assert.That(h.Engine.RealizedProfit, Is.EqualTo(-21m));
            Assert.That(h.Engine.BasketsLiquidated, Is.EqualTo(1));
        }

        [Test]
        public void SellForcedCloseUsesTheAskPlusSlippage()
        {
            var parameters = Harness.NoExits() with { Slippage = 0.5m };
            var h = new Harness(parameters, null, 20m, Harness.MarginDefaults());
            h.Anchor();
            h.Feed(1980m, 1980.2m);
            Assert.That(h.Engine.Basket!.Legs[0].EntryPrice, Is.EqualTo(1979.5m), "a SELL enters at the Bid less slippage");

            h.Feed(2000m, 2000.2m);

            var liquidation = h.ResearchAccount!.MarginSummary!.StopOutEpisodes[0].Liquidations[0];
            Assert.That(liquidation.Leg.Side, Is.EqualTo(TradeSide.Sell));
            Assert.That(liquidation.Leg.ClosePrice, Is.EqualTo(2000.7m), "a SELL is force-closed at the Ask plus slippage");
            Assert.That(liquidation.Leg.RealizedProfit, Is.EqualTo((1979.5m - 2000.7m) * 0.01m * 100m));
            Assert.That(h.Engine.RealizedProfit, Is.EqualTo(-21.2m));
            Assert.That(h.Engine.BasketsLiquidated, Is.EqualTo(1));
        }

        [Test]
        public void MultipleForcedClosesContinueUntilTheScriptedGuardClears()
        {
            var parameters = Harness.NoExits();
            var executor = new SyntheticExecutor(parameters);
            var guard = new StubRiskGuard();
            var engine = new SingleAnchorEngine(parameters, executor, null, null, guard);
            engine.OnQuote(new Quote(Harness.T0, 1999.9m, 2000.1m));
            engine.OnQuote(new Quote(Harness.T0.AddSeconds(1), 2019.8m, 2020m));   // BUY 1
            engine.OnQuote(new Quote(Harness.T0.AddSeconds(2), 1980m, 1980.2m));   // SELL 2
            engine.OnQuote(new Quote(Harness.T0.AddSeconds(3), 2019.8m, 2020m));   // BUY 3
            engine.OnQuote(new Quote(Harness.T0.AddSeconds(4), 1980m, 1980.2m));   // SELL 4
            Assert.That(engine.Basket!.OpenPositions, Is.EqualTo(4));

            var triggers = 0;
            engine.StopOutTriggered += _ => triggers++;
            guard.NextStopOut = new MarginStopOut(StopOutReason.MarginLevel, Harness.T0.AddSeconds(5), 0m, 0m, 0.6m, 3.96m, -3.36m, 15.1515m, 4);
            guard.StopOutLimit = 2;
            engine.OnQuote(new Quote(Harness.T0.AddSeconds(5), 1900m, 1900.2m));

            Assert.That(engine.Fault, Is.Null);
            Assert.That(triggers, Is.EqualTo(1), "the trigger event fires once per episode");
            Assert.That(engine.ForcedLiquidations, Is.EqualTo(2), "the guard cleared after the second close");
            Assert.That(engine.BasketsLiquidated, Is.EqualTo(0));
            Assert.That(engine.Basket!.OpenPositions, Is.EqualTo(2), "the partial liquidation leaves survivors");
            Assert.That(executor.LegCloses, Has.Count.EqualTo(2));
            Assert.That(executor.LegCloses[0].Leg.TradeNumber, Is.EqualTo(3), "BUY legs lose at 1900, deepest lot first");
            Assert.That(executor.LegCloses[1].Leg.TradeNumber, Is.EqualTo(1));
            Assert.That(engine.Basket.NextTradeNumber, Is.EqualTo(5));
            Assert.That(engine.Basket.NextRequiredSide, Is.EqualTo(TradeSide.Buy), "trade 4 was SELL; the historical sequence is unchanged");

            // The strategy continues on a later quote without reusing a trade number.
            engine.OnQuote(new Quote(Harness.T0.AddSeconds(6), 2019.8m, 2020m));
            Assert.That(executor.Entries[^1].TradeNumber, Is.EqualTo(5));
            Assert.That(executor.Entries[^1].Side, Is.EqualTo(TradeSide.Buy));
            Assert.That(engine.Basket!.OpenPositions, Is.EqualTo(3));
        }

        [Test]
        public void TotalLiquidationEndsTheBasketAsABrokerOutcomeAndTheRunContinues()
        {
            var h = new Harness(Harness.Defaults(), null, 4.05m, Harness.MarginDefaults());
            h.Anchor();
            h.Feed(2010m, 2020m);

            Assert.That(h.Engine.Fault, Is.Null);
            Assert.That(h.Engine.EntriesOpened, Is.EqualTo(1), "the fill is a published entry even though the broker immediately liquidates it");
            Assert.That(h.Engine.ForcedLiquidations, Is.EqualTo(1));
            Assert.That(h.Engine.BasketsLiquidated, Is.EqualTo(1));
            Assert.That(h.Engine.BasketsClosed, Is.EqualTo(0));
            Assert.That(h.Engine.Basket, Is.Null);

            var record = h.Engine.ClosedBaskets[0];
            Assert.That(record.Reason, Is.EqualTo(ExitReason.BrokerLiquidation));
            Assert.That(record.Legs, Is.EqualTo(0), "no surviving position is pretended to exist");
            Assert.That(record.HistoricalEntries, Is.EqualTo(1));
            Assert.That(record.LiquidatedPositions, Is.EqualTo(1));
            Assert.That(record.RealizedProfit, Is.EqualTo(-10m));
            Assert.That(record.RealizedProfit, Is.EqualTo(record.LiquidatedRealizedProfit));
            Assert.That(record.LiquidationTrace, Has.Count.EqualTo(1));
            Assert.That(record.LiquidationTrace[0].TriggerTime, Is.EqualTo(h.Engine.LastProcessedQuote!.Value.Time));
            Assert.That(record.LiquidationTrace[0].LiquidationTime, Is.EqualTo(record.LiquidationTrace[0].TriggerTime));

            var episode = h.ResearchAccount!.MarginSummary!.StopOutEpisodes[0];
            Assert.That(episode.Outcome, Is.EqualTo(StopOutEpisodeOutcome.AllPositionsLiquidated));
            Assert.That(episode.AtTrigger.Equity, Is.EqualTo(-5.95m));
            Assert.That(episode.AfterLiquidation.Equity, Is.EqualTo(-5.95m));
            Assert.That(episode.AfterLiquidation.OpenPositions, Is.EqualTo(0));

            // After every position is gone the run continues: a new basket anchors and the flat
            // negative account blocks new entries as InsufficientMargin instead of Stop Out.
            h.Feed(2000m, 2000.2m);
            Assert.That(h.Engine.Basket!.Sequence, Is.EqualTo(2), "a new basket is anchored after the total liquidation");
            Assert.That(h.Engine.Basket.OpenPositions, Is.EqualTo(0));
            h.Feed(2020.1m, 2021m);
            Assert.That(h.Engine.Basket.OpenPositions, Is.EqualTo(0));
            Assert.That(h.EntriesRejected, Has.Count.EqualTo(1));
            Assert.That(h.EntriesRejected[0].Rejection.Reason, Is.EqualTo(EntryRejectionReason.InsufficientMargin));
            Assert.That(h.Engine.Fault, Is.Null, "a flat negative account is not a broker Stop Out");
        }

        [Test]
        public void AForcedCloseTheExecutorCannotFillStopsTheRunWithoutInventingState()
        {
            var h = NewPartialLiquidationHarness(3215m, exits: false);
            h.Executor.LegCloseOverride = _ => LegCloseExecution.Failure("injected forced close failure");

            var failure = Assert.Throws<BrokerLiquidationException>(() => h.Feed(1900m, 1900.2m));

            Assert.That(failure!.Kind, Is.EqualTo("BrokerLiquidation"));
            Assert.That(failure.Condition, Is.EqualTo("ForcedCloseFailed"));
            Assert.That(h.Engine.Fault, Is.SameAs(failure));
            Assert.That(h.Engine.Basket!.OpenPositions, Is.EqualTo(3), "the failed forced close leaves the inventory untouched");
            Assert.That(h.Engine.ForcedLiquidations, Is.EqualTo(0));
            Assert.That(h.Engine.RealizedProfit, Is.EqualTo(0m));
            var episode = h.ResearchAccount!.MarginSummary!.StopOutEpisodes[0];
            Assert.That(episode.Outcome, Is.Null, "the unresolved episode is recorded truthfully");
            Assert.That(episode.Liquidations, Is.Empty);
            Assert.Throws<BrokerLiquidationException>(() => h.Feed(1899m, 1899.2m), "a faulted engine refuses every further quote");
        }

        [Test]
        public void TheEventStreamReportsTheTriggerEveryForcedCloseAndTheBasketOutcome()
        {
            var h = NewPartialLiquidationHarness(3215m, exits: false);
            h.Feed(1900m, 1900.2m);

            Assert.That(h.StopOutTriggers, Has.Count.EqualTo(1));
            Assert.That(h.StopOutTriggers[0].StopOut.Reason, Is.EqualTo(StopOutReason.MarginLevel));
            Assert.That(h.ForcedLiquidations, Has.Count.EqualTo(1));
            Assert.That(h.ForcedLiquidations[0].Record.TradeNumber, Is.EqualTo(3));
            Assert.That(h.ForcedLiquidations[0].Quote.Time, Is.EqualTo(h.Engine.LastProcessedQuote!.Value.Time));
            Assert.That(h.BasketsLiquidated, Is.Empty, "the basket was not fully liquidated");
            Assert.That(h.BasketsClosed, Is.Empty, "no strategy exit fired");
        }

        [Test]
        public void HardBreakevenStateAndTradeNumberingSurviveAPartialLiquidation()
        {
            var parameters = Harness.NoExits();
            var executor = new SyntheticExecutor(parameters);
            var guard = new StubRiskGuard();
            var engine = new SingleAnchorEngine(parameters, executor, null, null, guard);
            engine.OnQuote(new Quote(Harness.T0, 1999.9m, 2000.1m));
            engine.OnQuote(new Quote(Harness.T0.AddSeconds(1), 2019.8m, 2020m));   // BUY 1
            engine.OnQuote(new Quote(Harness.T0.AddSeconds(2), 1980m, 1980.2m));   // SELL 2
            engine.OnQuote(new Quote(Harness.T0.AddSeconds(3), 2019.8m, 2020m));   // BUY 3
            engine.OnQuote(new Quote(Harness.T0.AddSeconds(4), 1980m, 1980.2m));   // SELL 4
            engine.OnQuote(new Quote(Harness.T0.AddSeconds(5), 2019.8m, 2020m));   // BUY 5, hard-BE tail
            var basket = engine.Basket!;
            Assert.That(basket.OpenPositions, Is.EqualTo(5));
            Assert.That(basket.HardBreakevenModeActive, Is.True);
            Assert.That(basket.NextTradeNumber, Is.EqualTo(6));

            guard.NextStopOut = new MarginStopOut(StopOutReason.MarginLevel, Harness.T0.AddSeconds(6), 0m, 0m, 0.6m, 3.96m, -3.36m, 15.1515m, 5);
            guard.StopOutLimit = 2;
            // A rally quote: the losing SELL legs are force-closed first, and the next required BUY
            // boundary is not breached, so the survivors are observed after the episode ends.
            engine.OnQuote(new Quote(Harness.T0.AddSeconds(6), 2050m, 2050.2m));

            Assert.That(engine.ForcedLiquidations, Is.EqualTo(2));
            Assert.That(basket.OpenPositions, Is.EqualTo(3));
            Assert.That(basket.HardBreakevenModeActive, Is.True, "removing legs does not reset hard-BE mode");
            Assert.That(basket.NextTradeNumber, Is.EqualTo(6), "the historical depth is not inferred from surviving legs");
            Assert.That(basket.NextRequiredSide, Is.EqualTo(TradeSide.Sell), "trade 5 was BUY; the next leg is still SELL");
            Assert.That(basket.LiquidatedPositions, Is.EqualTo(2));
            Assert.That(basket.HistoricalEntries, Is.EqualTo(5));
            Assert.That(executor.LegCloses[0].Leg.TradeNumber, Is.EqualTo(4), "the deepest losing SELL is closed first");
            Assert.That(executor.LegCloses[1].Leg.TradeNumber, Is.EqualTo(2));
        }

        [Test]
        public void RunsThatNeverReachStopOutAreUnchanged()
        {
            var margin = new Harness(Harness.Defaults(), null, 1_000_000m, Harness.MarginDefaults());
            var plain = new Harness(Harness.Defaults(), null, 1_000_000m);
            foreach (var quote in DeterministicStream())
            {
                margin.Engine.OnQuote(quote);
                plain.Engine.OnQuote(quote);
            }

            Assert.That(margin.Engine.ForcedLiquidations, Is.EqualTo(0));
            Assert.That(margin.Engine.BasketsLiquidated, Is.EqualTo(0));
            Assert.That(margin.ResearchAccount!.MarginSummary!.StopOutEpisodes, Is.Empty);
            Assert.That(margin.Engine.QuotesProcessed, Is.EqualTo(plain.Engine.QuotesProcessed));
            Assert.That(margin.Engine.EntriesOpened, Is.EqualTo(plain.Engine.EntriesOpened));
            Assert.That(margin.Engine.BasketsClosed, Is.EqualTo(plain.Engine.BasketsClosed));
            Assert.That(margin.Engine.RealizedProfit, Is.EqualTo(plain.Engine.RealizedProfit));
            Assert.That(
                JsonSerializer.Serialize(margin.Engine.ClosedBaskets, HostLike),
                Is.EqualTo(JsonSerializer.Serialize(plain.Engine.ClosedBaskets, HostLike)));
        }

        private static List<Quote> DeterministicStream()
        {
            var quotes = new List<Quote>();
            var time = new DateTime(2024, 3, 1, 0, 0, 0);
            var price = 2000m;
            quotes.Add(new Quote(time, price, price + 0.2m));
            var seed = 987654321;
            for (var i = 1; i < 2000; i++)
            {
                seed = unchecked(seed * 1103515245 + 12345);
                var step = ((seed >> 16) % 400 - 200) / 10m;
                price = Math.Max(1500m, Math.Min(2500m, price + step));
                quotes.Add(new Quote(time.AddMilliseconds(i), price, price + 0.2m));
            }
            return quotes;
        }
    }
}
