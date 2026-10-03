using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using Newtonsoft.Json;
using Newtonsoft.Json.Linq;
using NUnit.Framework;

namespace MarketLab.SingleAnchor.Tests
{
    /// <summary>
    /// Phase E focused tests for the authoritative replay package: event coverage and order,
    /// exact account snapshots, bounded periodic telemetry, Margin Call transitions, forced
    /// liquidation representation, byte determinism and — most importantly — that wrapping the
    /// account in the recorder does not change a single engine or account outcome.
    /// </summary>
    [TestFixture]
    public class ReplayRecorderTests
    {
        private sealed class RecorderHarness
        {
            public RecorderHarness(SingleAnchorParameters parameters, decimal initialBalance, MarginParameters? margin = null)
            {
                Parameters = parameters;
                Executor = new SyntheticExecutor(parameters);
                Account = new SingleAnchorResearchAccount(parameters, initialBalance, margin);
                SingleAnchorEngine? engine = null;
                Recorder = new ReplayRecorder(Account, margin != null, () => engine!.QuotesProcessed);
                engine = new SingleAnchorEngine(parameters, Executor, null, Recorder, margin != null ? Account : null);
                Engine = engine;
                Engine.AnchorCreated += Recorder.OnAnchorCreated;
                Engine.FirstEntrySkipped += Recorder.OnFirstEntrySkipped;
                Engine.EntryOpened += Recorder.OnEntryOpened;
                Engine.EntryRejected += Recorder.OnEntryRejected;
                Engine.HardBreakevenViolated += Recorder.OnHardBreakevenViolated;
                Engine.HardBreakevenActivated += Recorder.OnHardBreakevenActivated;
                Engine.TrailingActivated += Recorder.OnTrailingActivated;
                Engine.BasketClosed += Recorder.OnBasketClosed;
                Engine.BasketCloseFailed += Recorder.OnBasketCloseFailed;
                Engine.StopOutTriggered += Recorder.OnStopOutTriggered;
                Engine.BasketLiquidated += Recorder.OnBasketLiquidated;
                Recorder.Start(new ReplayPackageMetadata(
                    SingleAnchorVNextAlgorithm.ModelRevision,
                    SingleAnchorVNextAlgorithm.StopOutModel,
                    "XAUUSD",
                    "dukascopy",
                    "Cfd",
                    "UTC",
                    "UTC",
                    "2024-01-02",
                    "2024-01-03",
                    Harness.T0,
                    Harness.T0.AddDays(1),
                    parameters,
                    margin,
                    null,
                    true,
                    margin != null));
            }

            public SingleAnchorParameters Parameters { get; }
            public SyntheticExecutor Executor { get; }
            public SingleAnchorResearchAccount Account { get; }
            public ReplayRecorder Recorder { get; }
            public SingleAnchorEngine Engine { get; }

            private int _tick;

            public Quote Feed(decimal bid, decimal ask)
            {
                return FeedAt(Harness.T0.AddSeconds(_tick++), bid, ask);
            }

            public Quote FeedAt(DateTime time, decimal bid, decimal ask)
            {
                var quote = new Quote(time, bid, ask);
                Engine.OnQuote(quote);
                return quote;
            }

            public ReplayPackageResult Build(bool completed = true, string? failureKind = null, string? failureCondition = null, string? failureMessage = null, Quote? failureQuote = null)
            {
                var rejections = new List<EntryRejectionRecord>();
                foreach (var closed in Engine.ClosedBaskets)
                {
                    rejections.AddRange(closed.RejectionTrace);
                }
                if (Engine.Basket != null)
                {
                    rejections.AddRange(Engine.Basket.Rejections);
                }
                return Recorder.BuildPackage(new ReplayRunEnd(
                    completed,
                    failureKind,
                    failureCondition,
                    failureMessage,
                    failureQuote,
                    Engine.LastProcessedQuote?.Time,
                    Engine.QuotesProcessed,
                    Engine.QuoteOnlyQuotes,
                    Engine.StrategyEligibleQuotes,
                    Engine.EntriesOpened,
                    Engine.BasketsClosed,
                    Engine.BasketsLiquidated,
                    Engine.ForcedLiquidations,
                    Engine.EntriesRejected,
                    Engine.RejectedEntryAttempts,
                    Engine.SkippedFirstEntryQuotes,
                    Engine.RealizedProfit,
                    null,
                    rejections));
            }
        }

        /// <summary>Parses JSON without Newtonsoft's automatic ISO-date conversion, so the package text is compared verbatim.</summary>
        private static JObject Parse(string json)
        {
            using var reader = new JsonTextReader(new StringReader(json)) { DateParseHandling = DateParseHandling.None };
            return JObject.Load(reader);
        }

        private static List<JObject> Lines(ReplayPackageResult package, string fileName)
        {
            var file = package.Files.Single(f => f.Name == fileName);
            return file.Content
                .Split('\n', StringSplitOptions.RemoveEmptyEntries)
                .Select(Parse)
                .ToList();
        }

        private static List<JObject> Events(ReplayPackageResult package)
        {
            return Lines(package, ReplayPackage.EventsFile);
        }

        private static List<JObject> Telemetry(ReplayPackageResult package, params string[] fileNames)
        {
            var result = new List<JObject>();
            foreach (var file in package.Files.Where(f => fileNames.Length == 0 ? f.Year.HasValue : fileNames.Contains(f.Name)))
            {
                result.AddRange(file.Content.Split('\n', StringSplitOptions.RemoveEmptyEntries).Select(Parse));
            }
            return result;
        }

        /// <summary>Anchor 2000, BUY 0.01 @ 2020, trailing activate at 2030, close at 2045.</summary>
        private static void FeedTrailingScenario(RecorderHarness h)
        {
            h.Feed(1999.9m, 2000.1m);   // anchor
            h.Feed(2019.8m, 2020m);     // BUY 0.01 @ 2020
            h.Feed(2030m, 2030.2m);     // trailing activation (profit 10)
            h.Feed(2050m, 2050.2m);     // peak 30
            h.Feed(2045m, 2045.2m);     // trailing close at threshold 25
        }

        [Test]
        public void EventStreamCoversTheScenarioInExactEngineOrder()
        {
            var h = new RecorderHarness(Harness.Defaults(), 10000m);
            FeedTrailingScenario(h);
            var package = h.Build();

            var types = Events(package).Select(e => (string)e["type"]!).ToList();
            Assert.That(types, Is.EqualTo(new[]
            {
                "run_started",
                "basket_anchored",
                "entry_executed",
                "trailing_activated",
                "strategy_exit",
                "run_ended"
            }));

            var anchor = Events(package).Single(e => (string)e["type"]! == "basket_anchored");
            Assert.That((int)anchor["basket"]!, Is.EqualTo(1));
            Assert.That(Convert.ToDecimal((string)anchor["anchor"]!), Is.EqualTo(2000m));
            Assert.That(Convert.ToDecimal((string)anchor["upper"]!), Is.EqualTo(2020m));
            Assert.That(Convert.ToDecimal((string)anchor["lower"]!), Is.EqualTo(1980m));
            Assert.That(Convert.ToDecimal((string)anchor["lowerTarget"]!), Is.EqualTo(1910.44m));
            Assert.That(Convert.ToDecimal((string)anchor["upperTarget"]!), Is.EqualTo(2089.56m));

            var exit = Events(package).Single(e => (string)e["type"]! == "strategy_exit");
            Assert.That((string)exit["reason"]!, Is.EqualTo("Trailing"));
            Assert.That(Convert.ToDecimal((string)exit["threshold"]!), Is.EqualTo(25m));
            Assert.That(Convert.ToDecimal((string)exit["realizedProfit"]!), Is.EqualTo(25m));

            Assert.That(package.EventCount, Is.EqualTo(6));
            Assert.That(package.EventSnapshotCount, Is.EqualTo(6), "every event carries one exact account snapshot");
        }

        [Test]
        public void EveryEventSnapshotMatchesTheAccountStateAtThatEvent()
        {
            var h = new RecorderHarness(Harness.Defaults(), 10000m);
            FeedTrailingScenario(h);
            var package = h.Build();

            var events = Events(package);
            var telemetry = Telemetry(package).Where(t => (string)t["kind"]! == "event").ToList();
            Assert.That(telemetry, Has.Count.EqualTo(events.Count));
            for (var i = 0; i < events.Count; i++)
            {
                Assert.That((long)telemetry[i]["eventId"]!, Is.EqualTo((long)events[i]["id"]!), "event snapshots are in event order");
                Assert.That((string)telemetry[i]["time"]!, Is.EqualTo((string)events[i]["time"]!), "the snapshot is taken at the event's own timestamp");
            }

            var exitEvent = events.Single(e => (string)e["type"]! == "strategy_exit");
            var exitSnapshot = telemetry.Single(t => (long?)t["eventId"] == (long)exitEvent["id"]!);
            Assert.That(Convert.ToDecimal((string)exitSnapshot["balance"]!), Is.EqualTo(h.Account.Balance));
            Assert.That(Convert.ToDecimal((string)exitSnapshot["equity"]!), Is.EqualTo(h.Account.Equity));
            Assert.That((int)exitSnapshot["openPositions"]!, Is.EqualTo(0));
        }

        [Test]
        public void PeriodicTelemetryIsBoundedToOpenPositionsAndTheInterval()
        {
            // BUY 0.01 @ 2020 is open from t+1s; quotes every 100s up to t+1000s.
            var h = new RecorderHarness(Harness.Defaults() with { TrailingEnabled = false, EscapeEnabled = false }, 10000m);
            h.Feed(1999.9m, 2000.1m);   // t0 anchor (flat)
            var entry = h.Feed(2019.8m, 2020m); // t1 entry -> first periodic sample
            for (var i = 1; i <= 10; i++)
            {
                h.FeedAt(entry.Time.AddSeconds(i * 100), 2019.8m, 2020m);
            }
            var package = h.Build();

            var periodic = Telemetry(package).Where(t => (string)t["kind"]! == "periodic").ToList();
            Assert.That(periodic.All(t => (int)t["openPositions"]! > 0), Is.True, "periodic samples exist only while positions are open");
            Assert.That(periodic, Has.Count.EqualTo(4), "samples at t+1, t+301, t+601 and t+901 seconds");
            Assert.That((string)periodic[0]["time"]!, Is.EqualTo(ReplayPackage.FormatUtc(entry.Time)));
            var times = periodic.Select(t => (string)t["time"]!).ToList();
            Assert.That(times, Is.Ordered);
            Assert.That(package.PeriodicSampleCount, Is.EqualTo(4));
        }

        [Test]
        public void TelemetryIsShardedByUtcCalendarYear()
        {
            var h = new RecorderHarness(Harness.Defaults() with { TrailingEnabled = false, EscapeEnabled = false }, 10000m);
            h.FeedAt(new DateTime(2019, 12, 31, 23, 59, 0), 1999.9m, 2000.1m); // 2019 anchor
            h.FeedAt(new DateTime(2019, 12, 31, 23, 59, 30), 2019.8m, 2020m);  // 2019 entry
            h.FeedAt(new DateTime(2020, 1, 1, 0, 4, 30), 2019.8m, 2020m);      // 2020 quote (sample due)
            var package = h.Build();

            Assert.That(package.Files.Any(f => f.Name == "telemetry-2019.jsonl"), Is.True);
            Assert.That(package.Files.Any(f => f.Name == "telemetry-2020.jsonl"), Is.True);
            var manifest = Parse(package.Manifest);
            var years = ((JArray)manifest["files"]!).Select(f => f["year"]!.Type == JTokenType.Null ? (int?)null : (int?)f["year"]!).Where(y => y.HasValue).Select(y => y!.Value).ToList();
            Assert.That(years, Does.Contain(2019));
            Assert.That(years, Does.Contain(2020));
            Assert.That(years, Is.Ordered, "telemetry shards are listed by ascending year");
        }

        [Test]
        public void MarginCallEnterAndLeaveAreCapturedAsEvents()
        {
            var h = new RecorderHarness(Harness.Defaults(), 1000m, Harness.MarginDefaults());
            h.Feed(1999.9m, 2000.1m);   // anchor
            h.Feed(2019.8m, 2020m);     // BUY 0.01 @ 2020; balance 1000, used 4.04
            h.Feed(1022.02m, 1022.22m); // equity 2.02 -> margin level exactly 50%
            h.Feed(1022.03m, 1022.23m); // just above -> leave
            h.Feed(1022.02m, 1022.22m); // exactly 50% again -> second enter
            var package = h.Build();

            var types = Events(package).Select(e => (string)e["type"]!).ToList();
            Assert.That(types.Count(t => t == "margin_call_entered"), Is.EqualTo(2));
            Assert.That(types.Count(t => t == "margin_call_left"), Is.EqualTo(1), "the run ends inside the second Margin Call episode");
            Assert.That(h.Account.MarginCallActive, Is.True);

            var firstEnter = Events(package).First(e => (string)e["type"]! == "margin_call_entered");
            Assert.That(Convert.ToDecimal((string)firstEnter["marginLevelPercent"]!), Is.EqualTo(50m));
            Assert.That((int)firstEnter["openPositions"]!, Is.EqualTo(1));
            var firstLeave = Events(package).First(e => (string)e["type"]! == "margin_call_left");
            Assert.That((long)firstLeave["quoteSequence"]!, Is.GreaterThan((long)firstEnter["quoteSequence"]!));
        }

        [Test]
        public void StopOutForcedLiquidationAndFullLiquidationAreRepresentedExactly()
        {
            var h = new RecorderHarness(Harness.Defaults(), 10m, Harness.MarginDefaults());
            h.Feed(1999.9m, 2000.1m);       // anchor
            h.Feed(2019.8m, 2020m);         // BUY 0.01 @ 2020; used 4.04, free 5.96
            h.Feed(2010.808m, 2011.008m);   // equity 0.808 -> margin level 20% -> Stop Out
            var package = h.Build();

            var types = Events(package).Select(e => (string)e["type"]!).ToList();
            Assert.That(types, Does.Contain("stop_out_triggered"));
            Assert.That(types, Does.Contain("forced_liquidation"));
            Assert.That(types, Does.Contain("basket_liquidated"));
            Assert.That(types.IndexOf("stop_out_triggered"), Is.LessThan(types.IndexOf("forced_liquidation")));
            Assert.That(types.IndexOf("forced_liquidation"), Is.LessThan(types.IndexOf("basket_liquidated")));
            // The drop put the account into Margin Call (20% <= 50%); the forced close that empties
            // the basket leaves it, and that leave is published on the liquidation quote.
            Assert.That(types, Does.Contain("margin_call_entered"));
            Assert.That(types, Does.Contain("margin_call_left"));
            Assert.That(types.IndexOf("margin_call_entered"), Is.LessThan(types.IndexOf("stop_out_triggered")));
            Assert.That(types.IndexOf("forced_liquidation"), Is.LessThan(types.IndexOf("margin_call_left")));
            Assert.That(types.IndexOf("margin_call_left"), Is.LessThan(types.IndexOf("basket_liquidated")));

            var forced = Events(package).Single(e => (string)e["type"]! == "forced_liquidation");
            Assert.That((int)forced["basket"]!, Is.EqualTo(1));
            Assert.That((int)forced["ordinal"]!, Is.EqualTo(1));
            Assert.That((int)forced["tradeNumber"]!, Is.EqualTo(1));
            Assert.That((string)forced["side"]!, Is.EqualTo("Buy"));
            Assert.That(Convert.ToDecimal((string)forced["closePrice"]!), Is.EqualTo(2010.808m));
            Assert.That(Convert.ToDecimal((string)forced["realizedProfit"]!), Is.EqualTo(-9.192m));
            Assert.That((string)forced["reason"]!, Is.EqualTo("MarginLevel"));
            Assert.That(Convert.ToDecimal((string)forced["beforeBalance"]!), Is.EqualTo(10m));
            Assert.That(Convert.ToDecimal((string)forced["afterBalance"]!), Is.EqualTo(0.808m));
            Assert.That((int)forced["beforeOpenPositions"]!, Is.EqualTo(1));
            Assert.That((int)forced["afterOpenPositions"]!, Is.EqualTo(0));
            Assert.That(forced["beforeBalance"]!.Type, Is.EqualTo(JTokenType.String), "account decimals are exact JSON strings, never JSON numbers");
            Assert.That(forced["afterBalance"]!.Type, Is.EqualTo(JTokenType.String));
            Assert.That(forced["beforeUsedMargin"]!.Type, Is.EqualTo(JTokenType.String));
            Assert.That(forced["beforeFloatingProfit"]!.Type, Is.EqualTo(JTokenType.String));
            Assert.That(forced["beforeEquity"]!.Type, Is.EqualTo(JTokenType.String));
            Assert.That(forced["afterFreeMargin"]!.Type, Is.EqualTo(JTokenType.String).Or.EqualTo(JTokenType.Null));
            Assert.That(forced["afterMarginLevelPercent"]!.Type, Is.EqualTo(JTokenType.String).Or.EqualTo(JTokenType.Null));

            var liquidated = Events(package).Single(e => (string)e["type"]! == "basket_liquidated");
            Assert.That((string)liquidated["reason"]!, Is.EqualTo("BrokerLiquidation"));
            Assert.That(Convert.ToDecimal((string)liquidated["realizedProfit"]!), Is.EqualTo(-9.192m));
            Assert.That((int)liquidated["liquidatedPositions"]!, Is.EqualTo(1));

            var forcedSnapshot = Telemetry(package).Single(t => (long?)t["eventId"] == (long)forced["id"]!);
            Assert.That(Convert.ToDecimal((string)forcedSnapshot["balance"]!), Is.EqualTo(0.808m), "the forced-liquidation snapshot is the account state after the close");
            Assert.That((int)forcedSnapshot["openPositions"]!, Is.EqualTo(0));
        }

        /// <summary>Anchors and places the four arithmetic legs; the next required side is BUY (trade 5).</summary>
        private static void FeedFourArithmeticLegs(RecorderHarness h)
        {
            h.Feed(1999.9m, 2000.1m);   // anchor
            h.Feed(2019.8m, 2020m);     // trade 1 BUY
            h.Feed(1980m, 1980.2m);     // trade 2 SELL
            h.Feed(2019.8m, 2020m);     // trade 3 BUY
            h.Feed(1980m, 1980.2m);     // trade 4 SELL
        }

        [Test]
        public void HardBreakevenActivationSnapshotIsThePreAttemptStateAndTheEntrySnapshotIsPostEntry()
        {
            var h = new RecorderHarness(Harness.Defaults(), 10000m);
            FeedFourArithmeticLegs(h);
            h.Feed(2019.8m, 2020m);     // trade 5 BUY tail: hard-BE mode activates, then the leg enters
            var package = h.Build();

            var events = Events(package);
            var types = events.Select(e => (string)e["type"]!).ToList();
            var activationIndex = types.IndexOf("hard_breakeven_activated");
            Assert.That(activationIndex, Is.GreaterThanOrEqualTo(0), "the tail attempt activates the hard-BE mode");
            Assert.That(types[activationIndex + 1], Is.EqualTo("entry_executed"), "activation precedes the entry it enabled");
            var activation = events[activationIndex];
            var entry = events[activationIndex + 1];
            Assert.That((int)activation["tradeNumber"]!, Is.EqualTo(5));
            Assert.That((int)entry["tradeNumber"]!, Is.EqualTo(5));
            Assert.That((string)entry["regime"]!, Is.EqualTo("HardBreakeven"));
            Assert.That(entry["hardBreakevenTarget"], Is.Not.Null.And.Not.EqualTo(JValue.CreateNull()));

            // The activation snapshot is taken at the transition, before the tail leg exists;
            // the entry snapshot is taken after the leg entered the account.
            var snapshots = Telemetry(package).Where(t => (string)t["kind"]! == "event").ToList();
            var activationSnapshot = snapshots.Single(t => (long?)t["eventId"] == (long)activation["id"]!);
            var entrySnapshot = snapshots.Single(t => (long?)t["eventId"] == (long)entry["id"]!);
            Assert.That((int)activationSnapshot["openPositions"]!, Is.EqualTo(4), "activation is pre-attempt");
            Assert.That((int)entrySnapshot["openPositions"]!, Is.EqualTo(5), "the entry is post-fill");
            Assert.That(Convert.ToDecimal((string)activationSnapshot["grossLots"]!), Is.LessThan(Convert.ToDecimal((string)entrySnapshot["grossLots"]!)));
            Assert.That((string)activationSnapshot["balance"]!, Is.EqualTo((string)entrySnapshot["balance"]!), "a fill does not realize P/L");
        }

        [Test]
        public void HardBreakevenActivationWithAnInfeasibleTailKeepsThePreAttemptSnapshot()
        {
            // The first four lots fit; the trade-5 requirement (about 0.06) exceeds the maximum,
            // so the activation is followed by a rejection, never by a fill.
            var h = new RecorderHarness(Harness.Defaults() with { MaximumVolume = 0.05m }, 10000m);
            FeedFourArithmeticLegs(h);
            h.Feed(2019.8m, 2020m);
            var package = h.Build();

            var events = Events(package);
            var types = events.Select(e => (string)e["type"]!).ToList();
            var activationIndex = types.IndexOf("hard_breakeven_activated");
            Assert.That(activationIndex, Is.GreaterThanOrEqualTo(0));
            Assert.That(types[activationIndex + 1], Is.EqualTo("entry_rejected"));
            var activation = events[activationIndex];
            var rejection = events[activationIndex + 1];
            Assert.That((string)rejection["reason"]!, Is.EqualTo("HardBreakevenInfeasible"));
            var snapshots = Telemetry(package).Where(t => (string)t["kind"]! == "event").ToList();
            var activationSnapshot = snapshots.Single(t => (long?)t["eventId"] == (long)activation["id"]!);
            var rejectionSnapshot = snapshots.Single(t => (long?)t["eventId"] == (long)rejection["id"]!);
            Assert.That((int)activationSnapshot["openPositions"]!, Is.EqualTo(4));
            Assert.That((int)rejectionSnapshot["openPositions"]!, Is.EqualTo(4), "a rejected attempt adds no leg");
        }

        [Test]
        public void TheSameScenarioProducesByteIdenticalPackages()
        {
            var first = new RecorderHarness(Harness.Defaults(), 10000m);
            FeedTrailingScenario(first);
            var firstPackage = first.Build();

            var second = new RecorderHarness(Harness.Defaults(), 10000m);
            FeedTrailingScenario(second);
            var secondPackage = second.Build();

            Assert.That(secondPackage.PackageSha256, Is.EqualTo(firstPackage.PackageSha256));
            Assert.That(secondPackage.Manifest, Is.EqualTo(firstPackage.Manifest), "the manifest bytes are deterministic too");
            foreach (var file in firstPackage.PayloadFiles)
            {
                var match = secondPackage.PayloadFiles.Single(f => f.Name == file.Name);
                Assert.That(match.Content, Is.EqualTo(file.Content), file.Name);
                Assert.That(match.Sha256, Is.EqualTo(file.Sha256), file.Name);
                Assert.That(match.Lines, Is.EqualTo(file.Lines), file.Name);
            }
        }

        [Test]
        public void AStoppedRunCarriesTheFailureAndTheFaultingQuote()
        {
            var h = new RecorderHarness(Harness.Defaults(), 10000m);
            h.Feed(1999.9m, 2000.1m);
            var fault = new Quote(Harness.T0.AddSeconds(5), 2001m, 2000.9m);
            var package = h.Build(false, "DataQuality", "InvalidQuote", "the quote is not a valid tick", fault);

            var ended = Events(package).Single(e => (string)e["type"]! == "run_ended");
            Assert.That((bool)ended["completed"]!, Is.False);
            Assert.That((string)ended["failureKind"]!, Is.EqualTo("DataQuality"));
            Assert.That((string)ended["failureCondition"]!, Is.EqualTo("InvalidQuote"));
            Assert.That((string)ended["failureQuoteTime"]!, Is.EqualTo(ReplayPackage.FormatUtc(fault.Time)));
            Assert.That(Convert.ToDecimal((string)ended["failureBid"]!), Is.EqualTo(fault.Bid));
            Assert.That(Convert.ToDecimal((string)ended["failureAsk"]!), Is.EqualTo(fault.Ask));

            var manifest = Parse(package.Manifest);
            Assert.That((bool)manifest["outcome"]!["completed"]!, Is.False);
            Assert.That((string)manifest["outcome"]!["failureCondition"]!, Is.EqualTo("InvalidQuote"));
        }

        [Test]
        public void AnOutOfOrderFailureQuoteDoesNotMoveTheRunEndEventBackwards()
        {
            var h = new RecorderHarness(Harness.Defaults(), 10000m);
            h.Feed(1999.9m, 2000.1m);
            h.Feed(2019.8m, 2020m);
            var last = h.Engine.LastProcessedQuote!.Value;
            var early = new Quote(Harness.T0, 1999.5m, 1999.7m);
            var package = h.Build(false, "DataQuality", "OutOfOrderQuote", "the quote is earlier than the last processed one", early);

            var ended = Events(package).Single(e => (string)e["type"]! == "run_ended");
            Assert.That((string)ended["time"]!, Is.EqualTo(ReplayPackage.FormatUtc(last.Time)), "the run-end clock never goes backwards");
            Assert.That((string)ended["failureQuoteTime"]!, Is.EqualTo(ReplayPackage.FormatUtc(early.Time)), "the rejected quote identity is preserved");
        }

        [Test]
        public void RejectionSummariesAreRecapsWithoutASnapshotAndLiveRejectionsHaveOne()
        {
            // Account 4.03 cannot finance the projected 4.04 used margin of the first 0.01 BUY, so
            // the first entry attempt opens an InsufficientMargin episode and later attempts append.
            var h = new RecorderHarness(Harness.Defaults(), 4.03m, Harness.MarginDefaults());
            h.Feed(1999.9m, 2000.1m);       // anchor
            h.Feed(2019.8m, 2020m);         // first rejected attempt (new episode)
            h.Feed(2019.8m, 2020m);         // repeated attempt (folds into the episode)
            var package = h.Build();

            var events = Events(package);
            Assert.That(events.Count(e => (string)e["type"]! == "entry_rejected"), Is.EqualTo(1), "only a new episode raises the live event");
            Assert.That(events.Count(e => (string)e["type"]! == "entry_rejection_summary"), Is.EqualTo(1));
            var live = events.Single(e => (string)e["type"]! == "entry_rejected");
            var summary = events.Single(e => (string)e["type"]! == "entry_rejection_summary");
            var snapshots = Telemetry(package).Where(t => (string)t["kind"]! == "event").ToList();
            Assert.That(snapshots.Any(t => (long?)t["eventId"] == (long)live["id"]!), Is.True, "the live rejection has an exact snapshot");
            Assert.That(snapshots.Any(t => (long?)t["eventId"] == (long)summary["id"]!), Is.False, "the run-end recap has no snapshot");
            Assert.That((long)summary["attempts"]!, Is.EqualTo(2));
        }

        [Test]
        public void TheManifestIdentifiesTheRunAndVerifiesEveryFile()
        {
            var h = new RecorderHarness(Harness.Defaults(), 10000m);
            FeedTrailingScenario(h);
            var package = h.Build();
            var manifest = Parse(package.Manifest);

            Assert.That((string)manifest["contract"]!, Is.EqualTo(ReplayPackage.Contract));
            Assert.That((string)manifest["modelRevision"]!, Is.EqualTo(SingleAnchorVNextAlgorithm.ModelRevision));
            Assert.That((string)manifest["stopOutModel"]!, Is.EqualTo(SingleAnchorVNextAlgorithm.StopOutModel));
            Assert.That((int)manifest["telemetryIntervalSeconds"]!, Is.EqualTo(ReplayPackage.TelemetryIntervalSeconds));
            Assert.That((string)manifest["startUtc"]!, Is.EqualTo(ReplayPackage.FormatUtc(Harness.T0)));
            Assert.That((bool)manifest["outcome"]!["completed"]!, Is.True);
            Assert.That((int)manifest["counters"]!["legsOpened"]!, Is.EqualTo(1));
            Assert.That((int)manifest["eventCounts"]!["strategy_exit"]!, Is.EqualTo(1));
            Assert.That(manifest["parameters"]!["StepPercent"]!.Type, Is.EqualTo(JTokenType.String), "manifest parameters are exact strings");
            Assert.That((string)manifest["parameters"]!["StepPercent"]!, Is.EqualTo("1"));

            var files = (JArray)manifest["files"]!;
            Assert.That(files, Has.Count.EqualTo(package.PayloadFiles.Count));
            foreach (var row in files)
            {
                var name = (string)row["name"]!;
                var file = package.PayloadFiles.Single(f => f.Name == name);
                Assert.That((string)row["sha256"]!, Is.EqualTo(file.Sha256));
                Assert.That((int)row["bytes"]!, Is.EqualTo(file.Bytes));
                Assert.That((int)row["lines"]!, Is.EqualTo(file.Lines));
                Assert.That(ReplayPackage.Sha256Hex(file.Content), Is.EqualTo(file.Sha256));
            }
        }

        [Test]
        public void TheRecorderDoesNotChangeTheEngineOrAccountOutcome()
        {
            // Baseline: the account itself is the engine's observer.
            var parameters = Harness.Defaults();
            var baselineExecutor = new SyntheticExecutor(parameters);
            var baselineAccount = new SingleAnchorResearchAccount(parameters, 10000m);
            var baseline = new SingleAnchorEngine(parameters, baselineExecutor, null, baselineAccount, null);
            FeedTrailingScenario(new HarnessLike(baseline));

            // With the recorder wrapping the account.
            var h = new RecorderHarness(parameters, 10000m);
            FeedTrailingScenario(h);
            var package = h.Build();

            Assert.That(package.EventCount, Is.EqualTo(6));
            Assert.That(h.Engine.RealizedProfit, Is.EqualTo(baseline.RealizedProfit));
            Assert.That(h.Account.Balance, Is.EqualTo(baselineAccount.Balance));
            Assert.That(h.Account.Equity, Is.EqualTo(baselineAccount.Equity));
            Assert.That(h.Account.FloatingProfit, Is.EqualTo(baselineAccount.FloatingProfit));
            Assert.That(JsonConvert.SerializeObject(h.Engine.ClosedBaskets), Is.EqualTo(JsonConvert.SerializeObject(baseline.ClosedBaskets)));
            Assert.That(JsonConvert.SerializeObject(h.Account.BasketRecords), Is.EqualTo(JsonConvert.SerializeObject(baselineAccount.BasketRecords)));
            Assert.That(h.Account.MaxOpenPositions, Is.EqualTo(baselineAccount.MaxOpenPositions));
        }

        /// <summary>
        /// The terminal hard-BE violation producer path: the failable tail order fills and enters
        /// the basket ledger, the engine throws before EntriesOpened/EntryOpened and before any
        /// continuation, and the package records exactly one diagnostic bound to the faulting leg
        /// with no normal entry_executed for it.
        /// </summary>
        [Test]
        public void ATerminalHardBreakevenViolationIsRecordedWithoutAnEntryEvent()
        {
            var h = new RecorderHarness(Harness.NoExits(), 10000m);
            h.Feed(1999.9m, 2000.1m);   // anchor
            h.Feed(2019.8m, 2020m);     // BUY 0.01 @ 2020
            h.Feed(1980m, 1980.2m);     // SELL 0.02 @ 1980
            h.Feed(2019.8m, 2020m);     // BUY 0.03 @ 2020
            h.Feed(1980m, 1980.2m);     // SELL 0.04 @ 1980
            h.Executor.EntryOverride = _ => EntryExecution.Filled(2030m); // departs from the sizing model

            var faultingQuote = new Quote(Harness.T0.AddSeconds(5), 2019.8m, 2020m);
            var fault = Assert.Throws<StrategyInvariantException>(() => h.Engine.OnQuote(faultingQuote))!;
            Assert.That(fault.Invariant, Is.EqualTo(StrategyInvariant.HardBreakevenViolatedByFill));
            Assert.That(h.Engine.EntriesOpened, Is.EqualTo(4), "the faulting fill is not counted as an opened entry");

            var basket = h.Engine.Basket!;
            Assert.That(basket.OpenPositions, Is.EqualTo(5), "the faulting leg stays in the terminal basket ledger");
            var faultingLeg = basket.Legs.Single(leg => leg.TradeNumber == 5);

            var package = h.Build(false, "StrategyInvariant", "HardBreakevenViolatedByFill", "synthetic violation", fault.Quote);
            var events = Events(package);
            var violations = events.Where(e => (string)e["type"]! == "hard_breakeven_violated").ToList();
            Assert.That(violations, Has.Count.EqualTo(1));
            var violation = violations[0];
            Assert.That((int)violation["basket"]!, Is.EqualTo(basket.Sequence));
            Assert.That((int)violation["tradeNumber"]!, Is.EqualTo(5));
            Assert.That((string)violation["side"]!, Is.EqualTo(faultingLeg.Side.ToString()));
            Assert.That(Convert.ToDecimal((string)violation["placedLot"]!), Is.EqualTo(faultingLeg.Lots));
            Assert.That(Convert.ToDecimal((string)violation["fillPrice"]!), Is.EqualTo(faultingLeg.EntryPrice));
            Assert.That((string)violation["time"]!, Is.EqualTo(ReplayPackage.FormatUtc(faultingLeg.EntryTime)));
            Assert.That((long)violation["quoteSequence"]!, Is.EqualTo(faultingLeg.QuoteSequence));

            Assert.That(
                events.Any(e => (string)e["type"]! == "entry_executed" && (int)e["basket"]! == basket.Sequence && (int)e["tradeNumber"]! == 5),
                Is.False,
                "the faulting leg is never published as a normal entry");
            Assert.That(events.Count(e => (string)e["type"]! == "entry_executed"), Is.EqualTo(4));
            Assert.That(
                events.Any(e => (string)e["type"]! is "strategy_exit" or "basket_liquidated" or "trailing_activated"),
                Is.False,
                "no later strategy continuation after the terminal diagnostic");

            // The diagnostic snapshot is the post-fill account state: the engine observed the
            // faulting fill before it re-verified hard-BE and raised the diagnostic.
            var violationSnapshot = Telemetry(package)
                .Where(t => (string)t["kind"]! == "event")
                .Single(t => (long?)t["eventId"] == (long)violation["id"]!);
            Assert.That(Convert.ToDecimal((string)violationSnapshot["balance"]!), Is.EqualTo(h.Account.Balance));
            Assert.That(Convert.ToDecimal((string)violationSnapshot["equity"]!), Is.EqualTo(h.Account.Equity));
            Assert.That(Convert.ToDecimal((string)violationSnapshot["floatingProfit"]!), Is.EqualTo(h.Account.FloatingProfit));
            Assert.That(Convert.ToDecimal((string)violationSnapshot["usedMargin"]!), Is.EqualTo(h.Account.CurrentUsedMargin));
            Assert.That(violationSnapshot["freeMargin"]!.Type, Is.EqualTo(JTokenType.Null), "margin is disabled in this harness");
            Assert.That((int)violationSnapshot["openPositions"]!, Is.EqualTo(h.Account.CurrentOpenPositions));
            Assert.That(Convert.ToDecimal((string)violationSnapshot["grossLots"]!), Is.EqualTo(h.Account.CurrentGrossLots));
            Assert.That(Convert.ToDecimal((string)violationSnapshot["netLots"]!), Is.EqualTo(h.Account.CurrentNetLots));
            Assert.That(Convert.ToDecimal((string)violationSnapshot["absoluteNetLots"]!), Is.EqualTo(h.Account.CurrentAbsoluteNetLots));

            var runEnded = events[events.Count - 1];
            Assert.That((string)runEnded["type"]!, Is.EqualTo("run_ended"));
            Assert.That((bool)runEnded["completed"]!, Is.False);
            Assert.That((string)runEnded["failureCondition"]!, Is.EqualTo("HardBreakevenViolatedByFill"));
            Assert.That(events[events.Count - 2], Is.SameAs(violation), "the diagnostic immediately precedes run_ended");
        }

        /// <summary>Feeds the trailing scenario into an engine the caller built directly.</summary>
        private sealed class HarnessLike
        {
            private readonly SingleAnchorEngine _engine;
            private int _tick;

            public HarnessLike(SingleAnchorEngine engine)
            {
                _engine = engine;
            }

            public void Feed(decimal bid, decimal ask)
            {
                _engine.OnQuote(new Quote(Harness.T0.AddSeconds(_tick++), bid, ask));
            }
        }

        private static void FeedTrailingScenario(HarnessLike h)
        {
            h.Feed(1999.9m, 2000.1m);
            h.Feed(2019.8m, 2020m);
            h.Feed(2030m, 2030.2m);
            h.Feed(2050m, 2050.2m);
            h.Feed(2045m, 2045.2m);
        }
    }

    /// <summary>
    /// The fail-closed publication contract: payload files first, the manifest only after every
    /// payload persisted, and no manifest at all after a payload failure.
    /// </summary>
    [TestFixture]
    public class ReplayPackagePublisherTests
    {
        private static ReplayPackageFile File(string name, string content)
        {
            return new ReplayPackageFile(
                ReplayPackage.Directory + "/" + name,
                name,
                null,
                content,
                ReplayPackage.Sha256Hex(content),
                Encoding.UTF8.GetByteCount(content),
                ReplayPackage.CountLines(content));
        }

        [Test]
        public void PayloadsAreSavedBeforeTheManifest()
        {
            var files = new[] { File("events.jsonl", "a\n"), File("telemetry-2019.jsonl", "b\n"), File("manifest.json", "{}\n") };
            var saved = new List<string>();
            var published = ReplayPackagePublisher.Publish(files, (key, bytes) =>
            {
                saved.Add(key);
                return true;
            }, out var failedKey);

            Assert.That(published, Is.True);
            Assert.That(failedKey, Is.Null);
            Assert.That(saved, Has.Count.EqualTo(3));
            Assert.That(saved[saved.Count - 1], Does.EndWith("manifest.json"), "the manifest is published last");
        }

        [Test]
        public void AFailedPayloadSuppressesTheManifest()
        {
            var files = new[] { File("events.jsonl", "a\n"), File("telemetry-2019.jsonl", "b\n"), File("manifest.json", "{}\n") };
            var attempted = new List<string>();
            var published = ReplayPackagePublisher.Publish(files, (key, bytes) =>
            {
                attempted.Add(key);
                return !key.EndsWith("telemetry-2019.jsonl");
            }, out var failedKey);

            Assert.That(published, Is.False);
            Assert.That(failedKey, Does.EndWith("telemetry-2019.jsonl"));
            Assert.That(attempted.Any(key => key.EndsWith("manifest.json")), Is.False, "no manifest after a payload failure");
        }

        [Test]
        public void AFailedManifestIsReported()
        {
            var files = new[] { File("events.jsonl", "a\n"), File("manifest.json", "{}\n") };
            var published = ReplayPackagePublisher.Publish(files, (key, bytes) => !key.EndsWith("manifest.json"), out var failedKey);

            Assert.That(published, Is.False);
            Assert.That(failedKey, Does.EndWith("manifest.json"));
        }
    }
}
