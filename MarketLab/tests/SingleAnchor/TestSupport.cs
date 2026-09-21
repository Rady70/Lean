using System;
using System.Collections.Generic;

namespace MarketLab.SingleAnchor.Tests
{
    /// <summary>
    /// The deterministic research executor, with hooks to override one call at a time (to inject
    /// a failure or a fill that departs from the model). Records every request.
    /// </summary>
    internal sealed class SyntheticExecutor : IBasketExecutor
    {
        private readonly ResearchExecutor _research;

        public SyntheticExecutor(SingleAnchorParameters parameters)
        {
            _research = new ResearchExecutor(parameters);
        }

        public List<EntryOrder> Entries { get; } = new List<EntryOrder>();
        public List<CloseOrder> Closes { get; } = new List<CloseOrder>();
        public Func<EntryOrder, EntryExecution>? EntryOverride { get; set; }
        public Func<CloseOrder, CloseExecution>? CloseOverride { get; set; }

        public EntryExecution OpenPosition(EntryOrder order)
        {
            Entries.Add(order);
            return EntryOverride != null ? EntryOverride(order) : _research.OpenPosition(order);
        }

        public CloseExecution CloseBasket(CloseOrder order)
        {
            Closes.Add(order);
            return CloseOverride != null ? CloseOverride(order) : _research.CloseBasket(order);
        }
    }

    /// <summary>
    /// An engine, its executor and every event it raised, plus quote helpers.
    /// The reference scenario: anchor 2000 (bid 1999.9 / ask 2000.1), step 1% = 20, so
    /// Upper = 2020, Lower = 1980, T_up = 2089.56, T_down = 1910.44, V = 100 per lot.
    /// </summary>
    internal sealed class Harness
    {
        public static readonly DateTime T0 = new DateTime(2024, 1, 2, 10, 0, 0);

        public Harness(SingleAnchorParameters? parameters = null)
        {
            Parameters = parameters ?? Defaults();
            Executor = new SyntheticExecutor(Parameters);
            Engine = new SingleAnchorEngine(Parameters, Executor);
            Engine.AnchorCreated += e => AnchorsCreated.Add(e);
            Engine.EntryOpened += e => EntriesOpened.Add(e);
            Engine.EntryRejected += e => EntriesRejected.Add(e);
            Engine.HardBreakevenViolated += e => Violations.Add(e);
            Engine.TrailingActivated += e => TrailingActivations.Add(e);
            Engine.BasketClosed += e => BasketsClosed.Add(e);
            Engine.BasketCloseFailed += e => CloseFailures.Add(e);
            Engine.InvalidQuote += e => InvalidQuotes.Add(e);
        }

        public SingleAnchorParameters Parameters { get; }
        public SyntheticExecutor Executor { get; }
        public SingleAnchorEngine Engine { get; }
        public List<AnchorCreatedEvent> AnchorsCreated { get; } = new List<AnchorCreatedEvent>();
        public List<EntryOpenedEvent> EntriesOpened { get; } = new List<EntryOpenedEvent>();
        public List<EntryRejectedEvent> EntriesRejected { get; } = new List<EntryRejectedEvent>();
        public List<HardBreakevenViolatedEvent> Violations { get; } = new List<HardBreakevenViolatedEvent>();
        public List<TrailingActivatedEvent> TrailingActivations { get; } = new List<TrailingActivatedEvent>();
        public List<BasketClosedEvent> BasketsClosed { get; } = new List<BasketClosedEvent>();
        public List<BasketCloseFailedEvent> CloseFailures { get; } = new List<BasketCloseFailedEvent>();
        public List<InvalidQuoteEvent> InvalidQuotes { get; } = new List<InvalidQuoteEvent>();

        private int _tick;

        /// <summary>The reference parameter set; exits as specified, no execution costs.</summary>
        public static SingleAnchorParameters Defaults()
        {
            return new SingleAnchorParameters
            {
                StepPercent = 1m,
                BaseLot = 0.01m,
                NormalTradeCount = 4,
                HardBreakevenCeilingPercent = 4.478m,
                PointValuePerLot = 100m,
                VolumeStep = 0.01m,
                MinimumVolume = 0.01m,
                MaximumVolume = 100m
            };
        }

        /// <summary>The reference set with every exit rule switched off, for entry-only scenarios.</summary>
        public static SingleAnchorParameters NoExits()
        {
            return Defaults() with { EscapeEnabled = false, FixedTakeProfitUnits = 0m, TrailingEnabled = false };
        }

        /// <summary>Next quote, one second after the previous one.</summary>
        public Quote Next(decimal bid, decimal ask)
        {
            return new Quote(T0.AddSeconds(_tick++), bid, ask);
        }

        /// <summary>Feeds one quote and returns it.</summary>
        public Quote Feed(decimal bid, decimal ask)
        {
            var quote = Next(bid, ask);
            Engine.OnQuote(quote);
            return quote;
        }

        /// <summary>Feeds a quote with an explicit time.</summary>
        public Quote FeedAt(DateTime time, decimal bid, decimal ask)
        {
            var quote = new Quote(time, bid, ask);
            Engine.OnQuote(quote);
            return quote;
        }

        /// <summary>Anchors the reference basket at 2000 (no entry can trigger on this quote).</summary>
        public Quote Anchor()
        {
            return Feed(1999.9m, 2000.1m);
        }

        /// <summary>A quote at the upper level: ask exactly 2020.</summary>
        public Quote AtUpper()
        {
            return Feed(2019.8m, 2020m);
        }

        /// <summary>A quote at the lower level: bid exactly 1980.</summary>
        public Quote AtLower()
        {
            return Feed(1980m, 1980.2m);
        }

        /// <summary>
        /// Anchors and runs the four-leg reference sequence BUY 0.01 @ 2020, SELL 0.02 @ 1980,
        /// BUY 0.03 @ 2020, SELL 0.04 @ 1980 (no exit fires on the way).
        /// </summary>
        public Basket PingPongFourLegs()
        {
            Anchor();
            AtUpper();
            AtLower();
            AtUpper();
            AtLower();
            return Engine.Basket!;
        }
    }
}
