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
    /// not used by the strategy and are only counted. A quote tick with non-positive or crossed
    /// prices, or one the engine refuses as earlier than a quote it already processed, is a
    /// data-quality failure (<see cref="DataQualityException"/>): a path-dependent tick replay
    /// that skipped it would no longer be faithful, so the run must stop. A
    /// <see cref="StrategyInvariantException"/> from the engine propagates likewise. Quote counts
    /// and the last processed quote are the engine's (<see cref="SingleAnchorEngine.QuotesProcessed"/>,
    /// <see cref="SingleAnchorEngine.LastProcessedQuote"/>); the feed keeps no second copy.
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
                var quote = new Quote(tick.Time, tick.BidPrice, tick.AskPrice);
                if (!quote.IsValid)
                {
                    throw new DataQualityException(DataQualityIssue.InvalidQuoteTick, quote,
                        $"Quote tick {quote} has a non-positive or crossed bid/ask; the data is not a valid tick history for this strategy and the run is stopped.");
                }
                if (!engine.OnQuote(quote))
                {
                    var previous = engine.LastProcessedQuote;
                    throw new DataQualityException(DataQualityIssue.OutOfOrderQuoteTick, quote,
                        $"Quote tick {quote} is earlier than the previously processed quote {(previous.HasValue ? previous.Value.ToString() : "(none)")}; the tick chronology is broken and the run is stopped.");
                }
            }
        }
    }
}
