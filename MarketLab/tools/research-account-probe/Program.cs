using System;
using System.Diagnostics;
using System.Linq;
using MarketLab.SingleAnchor;

namespace MarketLab.ResearchAccountProbe
{
    /// <summary>
    /// Reproduces the PR 2 performance/allocation evidence for the research account. The quote
    /// stream is deterministic and deliberately trigger-heavy (a fixed pseudo-random walk around
    /// 2000 with the fixture-style parameters), so most quotes have an open basket and the
    /// observer's per-quote executable mark runs. The probe measures, per phase, the engine alone
    /// and the engine with an attached <see cref="SingleAnchorResearchAccount"/>:
    /// <list type="bullet">
    /// <item>nanoseconds per quote (same process, same machine, so the two figures are
    /// comparable; absolute values still move with host load);</item>
    /// <item>managed bytes allocated by the thread over the run;</item>
    /// <item>the strategy counters, which must be identical in both configurations.</item>
    /// </list>
    /// The stable attributable quantities are the allocation difference and the closed-basket
    /// count; the per-quote time is reported as a range, not a precise cost.
    /// </summary>
    internal static class Program
    {
        private const int WarmupQuotes = 300_000;
        private const int MeasuredQuotes = 3_000_000;
        private const int Phases = 5;

        private static int Main()
        {
            var parameters = FixtureParameters();
            Measure(parameters, withAccount: false, WarmupQuotes);
            Measure(parameters, withAccount: true, WarmupQuotes);

            var without = new Measurement[Phases];
            var with = new Measurement[Phases];
            var mismatches = 0;
            for (var phase = 0; phase < Phases; phase++)
            {
                // Alternate the order so a thermal, JIT or load drift cannot bias the
                // with/without comparison in one direction.
                var accountFirst = (phase % 2) == 1;
                var first = Measure(parameters, withAccount: accountFirst, MeasuredQuotes);
                var second = Measure(parameters, withAccount: !accountFirst, MeasuredQuotes);
                without[phase] = accountFirst ? second : first;
                with[phase] = accountFirst ? first : second;
                Console.WriteLine(
                    $"phase {phase} ({(accountFirst ? "with,without" : "without,with")}): without {without[phase].NanosecondsPerQuote:F1} ns/quote / {without[phase].Bytes} B / closed {without[phase].ClosedBaskets} / entries {without[phase].Entries} / attempts {without[phase].RejectedAttempts}");
                Console.WriteLine(
                    $"phase {phase} ({(accountFirst ? "with,without" : "without,with")}): with    {with[phase].NanosecondsPerQuote:F1} ns/quote / {with[phase].Bytes} B / closed {with[phase].ClosedBaskets} / entries {with[phase].Entries} / attempts {with[phase].RejectedAttempts}");
                if (without[phase].ClosedBaskets != with[phase].ClosedBaskets
                    || without[phase].Entries != with[phase].Entries
                    || without[phase].RejectedAttempts != with[phase].RejectedAttempts)
                {
                    mismatches++;
                }
            }

            var bytesDeltaMin = with.Min(m => m.Bytes) - without.Max(m => m.Bytes);
            var bytesDeltaMax = with.Max(m => m.Bytes) - without.Min(m => m.Bytes);
            var baskets = with[0].ClosedBaskets;
            Console.WriteLine($"without: median {Median(without.Select(m => m.NanosecondsPerQuote).ToArray()):F1} ns/quote; bytes {string.Join(",", without.Select(m => m.Bytes))}");
            Console.WriteLine($"with   : median {Median(with.Select(m => m.NanosecondsPerQuote).ToArray()):F1} ns/quote; bytes {string.Join(",", with.Select(m => m.Bytes))}");
            Console.WriteLine($"strategy counter mismatches across phases: {mismatches}");
            Console.WriteLine($"account allocation delta: {bytesDeltaMin}-{bytesDeltaMax} B over {baskets} closed baskets = {(double)bytesDeltaMin / Math.Max(1, baskets):F1}-{(double)bytesDeltaMax / Math.Max(1, baskets):F1} B per closed basket");
            return mismatches == 0 ? 0 : 1;
        }

        private static SingleAnchorParameters FixtureParameters()
        {
            return new SingleAnchorParameters
            {
                StepPercent = 0.2m,
                BaseLot = 0.01m,
                PointValuePerLot = 100m,
                ProjectedSpread = 0.5m
            };
        }

        private static Measurement Measure(SingleAnchorParameters parameters, bool withAccount, int quotes)
        {
            var account = withAccount ? new SingleAnchorResearchAccount(parameters, 100000m) : null;
            var engine = account == null
                ? new SingleAnchorEngine(parameters, new ResearchExecutor(parameters))
                : new SingleAnchorEngine(parameters, new ResearchExecutor(parameters), null, account);
            var time = new DateTime(2024, 1, 2, 0, 0, 0);
            var price = 2000m;
            var seed = 123456789;
            var before = GC.GetAllocatedBytesForCurrentThread();
            var watch = Stopwatch.StartNew();
            for (var i = 0; i < quotes; i++)
            {
                seed = (int)((seed * 1103515245L + 12345L) & 0x7fffffffL);
                price += ((seed % 11) - 5) * 0.9m;
                if (price < 1850m) price = 1850m;
                if (price > 2150m) price = 2150m;
                time = time.AddMilliseconds(100);
                engine.OnQuote(new Quote(time, price, price + 0.2m));
            }
            watch.Stop();
            var bytes = GC.GetAllocatedBytesForCurrentThread() - before;
            return new Measurement(
                watch.ElapsedTicks * (1_000_000_000.0 / Stopwatch.Frequency) / quotes,
                bytes,
                engine.BasketsClosed,
                engine.EntriesOpened,
                engine.RejectedEntryAttempts);
        }

        private static double Median(double[] values)
        {
            var sorted = values.OrderBy(v => v).ToArray();
            return sorted[sorted.Length / 2];
        }

        private readonly record struct Measurement(
            double NanosecondsPerQuote,
            long Bytes,
            long ClosedBaskets,
            long Entries,
            long RejectedAttempts);
    }
}
