using System;

namespace MarketLab.SingleAnchor
{
    /// <summary>
    /// One bid/ask observation. The engine acts on the Ask for BUY decisions and on the Bid for
    /// SELL decisions (specification section 3) and never on a single "last" price.
    /// </summary>
    public readonly record struct Quote
    {
        /// <summary>
        /// Creates a quote. Validity is not enforced here; see <see cref="IsValid"/> and
        /// <see cref="SingleAnchorEngine.OnQuote"/>, which rejects invalid quotes explicitly.
        /// </summary>
        public Quote(DateTime time, decimal bid, decimal ask)
        {
            Time = time;
            Bid = bid;
            Ask = ask;
        }

        /// <summary>Timestamp of the quote, in whatever clock the host uses consistently.</summary>
        public DateTime Time { get; }

        /// <summary>Best bid.</summary>
        public decimal Bid { get; }

        /// <summary>Best ask.</summary>
        public decimal Ask { get; }

        /// <summary>Midpoint, the anchor source (specification section 2).</summary>
        public decimal Mid => (Bid + Ask) / 2m;

        /// <summary>Ask minus Bid.</summary>
        public decimal Spread => Ask - Bid;

        /// <summary>
        /// True when both prices are positive and the Ask is not below the Bid. A zero spread is
        /// valid; a crossed or non-positive quote is not.
        /// </summary>
        public bool IsValid => Bid > 0m && Ask > 0m && Ask >= Bid;

        /// <inheritdoc />
        public override string ToString()
        {
            return $"{Time:yyyy-MM-dd HH:mm:ss.fff} bid={Bid} ask={Ask}";
        }
    }
}
