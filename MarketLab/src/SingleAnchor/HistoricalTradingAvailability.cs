using System;
using System.Collections.Generic;

namespace MarketLab.SingleAnchor
{
    /// <summary>
    /// How a delivered quote relates to the source-derived session it falls in, under the
    /// five-minute research assumption: the first and last five minutes of every session are
    /// quote-only windows in which the strategy may observe the quote but must not act on it.
    /// </summary>
    public enum QuoteTradability
    {
        /// <summary>The quote is in the tradable body of its session; the strategy behaves normally.</summary>
        Tradable = 0,

        /// <summary>The quote is in the first five minutes of its session (quote-only, strategy frozen).</summary>
        QuoteOnlyOpeningBuffer = 1,

        /// <summary>The quote is in the last five minutes of its session (quote-only, strategy frozen).</summary>
        QuoteOnlyClosingBuffer = 2
    }

    /// <summary>
    /// The strategy-side trading-availability rule over source-derived sessions:
    /// <c>T0 &lt;= t &lt; T0 + 5min</c> is quote-only (opening buffer),
    /// <c>T0 + 5min &lt;= t &lt;= T1 - 5min</c> is tradable and
    /// <c>T1 - 5min &lt; t &lt;= T1</c> is quote-only (closing buffer), with exact millisecond
    /// semantics. <c>T0</c> and <c>T1</c> are the exact timestamps of the first and last observed
    /// quotes of the source session (<see cref="HistoricalSession"/>). A session with no
    /// observable end has no closing buffer: the dataset cannot prove a close, so none is
    /// fabricated.
    /// </summary>
    /// <remarks>
    /// The sessions are in the same clock as the quotes they classify. The map is derived in UTC
    /// and converted once, by the host, into the subscription's exchange time zone, which is the
    /// clock of LEAN's delivered <c>Tick.Time</c>. The instance is stateful and expects quotes in
    /// non-decreasing time order, exactly like the engine that owns it; a quote outside every
    /// session is refused loudly because it means the map and the replay data window do not match.
    /// </remarks>
    public sealed class HistoricalTradingAvailability
    {
        /// <summary>The fixed research assumption: five minutes at each end of a session.</summary>
        public static readonly TimeSpan QuoteOnlyBuffer = TimeSpan.FromMinutes(5);

        private readonly IReadOnlyList<HistoricalSession> _sessions;
        private int _next;

        /// <summary>Creates the classifier over validated sessions (sorted, non-overlapping).</summary>
        public HistoricalTradingAvailability(IReadOnlyList<HistoricalSession> sessions)
        {
            if (sessions == null || sessions.Count == 0)
            {
                throw new ArgumentException("trading availability needs at least one session", nameof(sessions));
            }

            for (var i = 0; i < sessions.Count; i++)
            {
                var session = sessions[i] ?? throw new ArgumentException("a session cannot be null", nameof(sessions));
                if (session.End.HasValue && session.End.Value <= session.Start)
                {
                    throw new ArgumentException($"session {i} ends at or before it starts", nameof(sessions));
                }
                if (!session.End.HasValue && i != sessions.Count - 1)
                {
                    throw new ArgumentException("only the final session may have no observable end", nameof(sessions));
                }
                if (i > 0)
                {
                    var previous = sessions[i - 1]!;
                    if (previous.End.HasValue && session.Start <= previous.End.Value)
                    {
                        throw new ArgumentException($"session {i} overlaps or precedes session {i - 1}", nameof(sessions));
                    }
                }
            }

            _sessions = sessions;
        }

        /// <summary>The sessions this classifier was built from, in order.</summary>
        public IReadOnlyList<HistoricalSession> Sessions => _sessions;

        /// <summary>
        /// Classifies one quote. Quotes must arrive in non-decreasing time order.
        /// </summary>
        public QuoteTradability Classify(DateTime quoteTime)
        {
            return Classify(quoteTime, out _);
        }

        /// <summary>
        /// Classifies one quote and reports the index of the session it fell in, so a full-history
        /// scan can attribute quote-only counts to individual sessions without re-deriving the
        /// rule.
        /// </summary>
        public QuoteTradability Classify(DateTime quoteTime, out int sessionIndex)
        {
            while (_next < _sessions.Count)
            {
                var candidate = _sessions[_next]!;
                if (candidate.End.HasValue && quoteTime > candidate.End.Value)
                {
                    _next++;
                    continue;
                }
                break;
            }

            if (_next >= _sessions.Count)
            {
                throw new InvalidOperationException(
                    $"quote at {quoteTime:yyyy-MM-dd HH:mm:ss.fff} is after the last session of the availability map; " +
                    "the map and the replay data window do not match.");
            }

            var session = _sessions[_next]!;
            if (quoteTime < session.Start)
            {
                throw new InvalidOperationException(
                    $"quote at {quoteTime:yyyy-MM-dd HH:mm:ss.fff} is before session {_next} " +
                    $"(starts {session.Start:yyyy-MM-dd HH:mm:ss.fff}); the map and the replay data window do not match.");
            }

            sessionIndex = _next;
            if (quoteTime < session.Start + QuoteOnlyBuffer)
            {
                return QuoteTradability.QuoteOnlyOpeningBuffer;
            }
            if (!session.End.HasValue)
            {
                return QuoteTradability.Tradable;
            }
            if (quoteTime <= session.End.Value - QuoteOnlyBuffer)
            {
                return QuoteTradability.Tradable;
            }
            return QuoteTradability.QuoteOnlyClosingBuffer;
        }
    }
}
