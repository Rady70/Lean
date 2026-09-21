using System;
using System.Collections.Generic;
using QuantConnect;
using QuantConnect.Data.Market;

namespace MarketLab.SingleAnchor
{
    /// <summary>
    /// Hands every LEAN quote tick, in order, to the engine. Nothing is collapsed: each valid
    /// quote tick of a slice is one engine quote, so a boundary or an exit threshold crossed by
    /// an earlier tick of the same timestamp is seen. Non-quote ticks (trades, open interest)
    /// are not used by the strategy and are counted; quote ticks with non-positive or crossed
    /// prices are counted separately and skipped.
    /// </summary>
    public sealed class QuoteTickFeed
    {
        /// <summary>Quote ticks handed to the engine.</summary>
        public long QuoteTicks { get; private set; }

        /// <summary>Ticks of a type the strategy does not use (trade, open interest).</summary>
        public long NonQuoteTicks { get; private set; }

        /// <summary>Quote ticks skipped because the bid or ask was not positive or the quote was crossed.</summary>
        public long InvalidQuoteTicks { get; private set; }

        /// <summary>The last quote handed to the engine, if any.</summary>
        public Quote? LastQuote { get; private set; }

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
                if (tick.BidPrice <= 0m || tick.AskPrice <= 0m || tick.AskPrice < tick.BidPrice)
                {
                    InvalidQuoteTicks++;
                    continue;
                }
                var quote = new Quote(tick.Time, tick.BidPrice, tick.AskPrice);
                QuoteTicks++;
                LastQuote = quote;
                engine.OnQuote(quote);
            }
        }
    }
}
