using System;
using System.Collections.Generic;
using QuantConnect;
using QuantConnect.Data.Market;

namespace MarketLab.SingleAnchor
{
    /// <summary>
    /// Hands every LEAN quote tick, in order, to the engine. Nothing is collapsed: each quote
    /// tick of a slice is one engine quote, so a boundary or an exit threshold crossed by an
    /// earlier tick of the same timestamp is seen. Non-quote ticks (trades, open interest) are
    /// not used by the strategy and are only counted. Data quality is not the feed's concern: the
    /// engine itself faults on a quote with non-positive or crossed prices or one earlier than a
    /// quote it already processed (<see cref="DataQualityException"/>), and the feed lets that,
    /// like a <see cref="StrategyInvariantException"/>, propagate to the host, which must stop.
    /// Quote counts and the last processed quote are the engine's
    /// (<see cref="SingleAnchorEngine.QuotesProcessed"/>, <see cref="SingleAnchorEngine.LastProcessedQuote"/>).
    /// </summary>
    public sealed class QuoteTickFeed
    {
        /// <summary>Ticks of a type the strategy does not use (trade, open interest).</summary>
        public long NonQuoteTicks { get; private set; }

        /// <summary>Feeds the ticks of one slice, in the order LEAN delivered them.</summary>
        public void Feed(IReadOnlyList<Tick> ticks, SingleAnchorEngine engine)
        {
            if (ticks == null) throw new ArgumentNullException(nameof(ticks));
            if (engine == null) throw new ArgumentNullException(nameof(engine));

            for (var i = 0; i < ticks.Count; i++)
            {
                var tick = ticks[i];
                if (tick.TickType != TickType.Quote)
                {
                    NonQuoteTicks++;
                    continue;
                }
                engine.OnQuote(new Quote(tick.Time, tick.BidPrice, tick.AskPrice));
            }
        }
    }
}
