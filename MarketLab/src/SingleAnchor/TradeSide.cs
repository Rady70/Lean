namespace MarketLab.SingleAnchor
{
    /// <summary>
    /// Side of one basket leg. The strategy keeps BUY and SELL legs apart even when the host
    /// nets them into one holding (specification sections 3 and 10).
    /// </summary>
    public enum TradeSide
    {
        /// <summary>A long leg, opened from the Ask at the upper level.</summary>
        Buy,

        /// <summary>A short leg, opened from the Bid at the lower level.</summary>
        Sell
    }

    /// <summary>
    /// Helpers for <see cref="TradeSide"/>.
    /// </summary>
    public static class TradeSideExtensions
    {
        /// <summary>
        /// The side that must follow this one under strict alternation (specification section 3).
        /// </summary>
        public static TradeSide Opposite(this TradeSide side)
        {
            return side == TradeSide.Buy ? TradeSide.Sell : TradeSide.Buy;
        }
    }
}
