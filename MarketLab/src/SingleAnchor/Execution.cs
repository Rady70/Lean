using System;
using System.Collections.Generic;
using System.Globalization;

namespace MarketLab.SingleAnchor
{
    /// <summary>
    /// Which exit rule closed, or tried to close, the basket (specification section 14).
    /// </summary>
    public enum ExitReason
    {
        /// <summary>No exit rule fired.</summary>
        None,

        /// <summary>Escape (section 11).</summary>
        Escape,

        /// <summary>Fixed basket take-profit (section 12).</summary>
        FixedTakeProfit,

        /// <summary>Basket trailing profit (section 13).</summary>
        Trailing
    }

    /// <summary>
    /// A new basket leg the engine wants opened.
    /// </summary>
    public sealed record EntryOrder(int TradeNumber, TradeSide Side, decimal Lots, Quote Quote, SizingRegime Regime, HardBreakevenSizing? Sizing);

    /// <summary>
    /// A request to close every leg of the basket.
    /// </summary>
    public sealed record CloseOrder(Basket Basket, ExitReason Reason, Quote Quote);

    /// <summary>
    /// Result of an entry request: the whole requested volume filled at one price, or nothing.
    /// </summary>
    public readonly record struct EntryExecution(bool Succeeded, decimal FillPrice, string? Message)
    {
        /// <summary>The whole order filled at <paramref name="fillPrice"/>.</summary>
        public static EntryExecution Filled(decimal fillPrice)
        {
            return new EntryExecution(true, fillPrice, null);
        }

        /// <summary>Nothing was executed.</summary>
        public static EntryExecution Failure(string message)
        {
            return new EntryExecution(false, 0m, message);
        }
    }

    /// <summary>
    /// Result of a close request: every BUY leg closed at one price and every SELL leg at
    /// another, or nothing.
    /// </summary>
    public readonly record struct CloseExecution(bool Succeeded, decimal BuyClosePrice, decimal SellClosePrice, string? Message)
    {
        /// <summary>Every leg closed.</summary>
        public static CloseExecution Closed(decimal buyClosePrice, decimal sellClosePrice)
        {
            return new CloseExecution(true, buyClosePrice, sellClosePrice, null);
        }

        /// <summary>Nothing was executed; the basket stays as it was.</summary>
        public static CloseExecution Failure(string message)
        {
            return new CloseExecution(false, 0m, 0m, message);
        }
    }

    /// <summary>
    /// The host's side of execution. The engine decides; the executor fills. The contract is
    /// all-or-nothing and immediate: an entry fills its whole volume at one price or fails, a
    /// close closes every leg or fails. Partial or deferred fills are not part of this contract;
    /// a broker-style executor that needs them is a separate, later qualification. Implementations
    /// do not throw for ordinary rejections; they return a failure the engine surfaces.
    /// </summary>
    public interface IBasketExecutor
    {
        /// <summary>Opens one leg of the given side and volume.</summary>
        EntryExecution OpenPosition(EntryOrder order);

        /// <summary>Closes every leg of the basket.</summary>
        CloseExecution CloseBasket(CloseOrder order);
    }

    /// <summary>
    /// The deterministic research executor: fills exactly the configured execution model that
    /// the hard-BE projection uses, on the quote the engine decided on. A BUY enters at the Ask
    /// plus slippage and closes at the Bid less slippage; a SELL enters at the Bid less slippage
    /// and closes at the Ask plus slippage. Commission is applied by the engine from the same
    /// parameters. It never fails and never fills partially.
    /// </summary>
    public sealed class ResearchExecutor : IBasketExecutor
    {
        private readonly SingleAnchorParameters _parameters;

        /// <summary>Creates the executor for a parameter set.</summary>
        public ResearchExecutor(SingleAnchorParameters parameters)
        {
            _parameters = parameters ?? throw new ArgumentNullException(nameof(parameters));
        }

        /// <inheritdoc />
        public EntryExecution OpenPosition(EntryOrder order)
        {
            if (order == null) throw new ArgumentNullException(nameof(order));
            return EntryExecution.Filled(BasketEconomics.ExecutableEntryPrice(order.Side, order.Quote, _parameters));
        }

        /// <inheritdoc />
        public CloseExecution CloseBasket(CloseOrder order)
        {
            if (order == null) throw new ArgumentNullException(nameof(order));
            var (buyClose, sellClose) = BasketEconomics.ExecutableClosePrices(order.Quote, _parameters);
            return CloseExecution.Closed(buyClose, sellClose);
        }
    }

    /// <summary>
    /// Why an entry the grid required was not opened.
    /// </summary>
    public enum EntryRejectionReason
    {
        /// <summary>Hard-BE sizing found no placeable lot (see the attached sizing record).</summary>
        HardBreakevenInfeasible,

        /// <summary>The arithmetic lot, after normalization, exceeds the broker's maximum volume.</summary>
        VolumeExceedsMaximum,

        /// <summary>The executor did not fill the order.</summary>
        ExecutionFailed
    }

    /// <summary>
    /// Record of a rejected entry attempt. The three lot concepts stay separate: the raw requested
    /// lot of an arithmetic trade (B * n), the exact mathematically required hard-BE lot (Q_BE) and
    /// the upward broker-normalized lot the requirement needs. Nothing was placed, so there is no
    /// placed lot on a rejection. <see cref="Message"/> is built on demand only; the engine does not
    /// format a human-readable string for every repeated attempt. A value type: a repeated
    /// rejection creates no heap object on the hot path.
    /// </summary>
    public readonly record struct EntryRejection(
        int TradeNumber,
        TradeSide Side,
        EntryRejectionReason Reason,
        decimal? RawRequestedLots,
        decimal? ExactRequiredLots,
        decimal NormalizedRequiredLots,
        HardBreakevenSizing? Sizing,
        decimal MaximumVolume,
        string? ExecutionMessage)
    {
        /// <summary>Human-readable account of the rejection, built on demand.</summary>
        public string Message
        {
            get
            {
                switch (Reason)
                {
                    case EntryRejectionReason.HardBreakevenInfeasible:
                        return Sizing.HasValue ? Sizing.Value.Message : "Hard-BE sizing is not available.";
                    case EntryRejectionReason.VolumeExceedsMaximum:
                        return $"Arithmetic lot for trade {TradeNumber} ({F(RawRequestedLots ?? 0m)} raw -> {F(NormalizedRequiredLots)} normalized) exceeds the maximum volume {F(MaximumVolume)}; the order is not placed.";
                    default:
                        return ExecutionMessage ?? "The executor rejected the entry.";
                }
            }
        }

        private static string F(decimal value)
        {
            return value.ToString(CultureInfo.InvariantCulture);
        }
    }

    /// <summary>
    /// Base of the two conditions that end a research run: the engine is faulted afterwards and
    /// refuses every further quote, and a host must stop rather than continue.
    /// </summary>
    public abstract class SingleAnchorRunException : InvalidOperationException
    {
        /// <summary>Creates the exception.</summary>
        protected SingleAnchorRunException(Quote quote, string message)
            : base(message)
        {
            Quote = quote;
        }

        /// <summary>The quote being processed when the run ended.</summary>
        public Quote Quote { get; }

        /// <summary>Short name of the condition, for structured results.</summary>
        public abstract string Kind { get; }

        /// <summary>Name of the specific condition, for structured results.</summary>
        public abstract string Condition { get; }

        /// <summary>The exception thrown for every quote offered after the fault.</summary>
        public abstract SingleAnchorRunException AsRefusal();
    }

    /// <summary>
    /// The strategy conditions that stop a run instead of being turned into a trading decision.
    /// </summary>
    public enum StrategyInvariant
    {
        /// <summary>
        /// A tail leg was filled at a price that leaves the projected executable basket P/L at
        /// its hard boundary negative: the executor departed from the sizing model, and continuing
        /// would mean breakeven drift after hard-BE activation.
        /// </summary>
        HardBreakevenViolatedByFill
    }

    /// <summary>
    /// Thrown by the engine when a strategy invariant fails.
    /// </summary>
    public sealed class StrategyInvariantException : SingleAnchorRunException
    {
        /// <summary>Creates the exception.</summary>
        public StrategyInvariantException(StrategyInvariant invariant, Quote quote, string message)
            : base(quote, message)
        {
            Invariant = invariant;
        }

        /// <summary>Which invariant failed.</summary>
        public StrategyInvariant Invariant { get; }

        /// <inheritdoc />
        public override string Kind => "StrategyInvariant";

        /// <inheritdoc />
        public override string Condition => Invariant.ToString();

        /// <inheritdoc />
        public override SingleAnchorRunException AsRefusal()
        {
            return new StrategyInvariantException(Invariant, Quote, "The engine is faulted and accepts no further quotes: " + Message);
        }
    }

    /// <summary>
    /// The market-data conditions a research run cannot silently survive: a quote with
    /// non-positive or crossed prices, or one earlier than an already processed quote. Ignoring
    /// such a quote would change a path-dependent tick strategy's entries, exits and peaks, so the
    /// result would no longer be a faithful replay.
    /// </summary>
    public enum DataQualityIssue
    {
        /// <summary>A quote whose bid or ask is not positive or whose ask is below its bid.</summary>
        InvalidQuote,

        /// <summary>A quote stamped earlier than a quote the engine already processed.</summary>
        OutOfOrderQuote
    }

    /// <summary>
    /// Thrown by the engine itself when a quote fails a data-quality condition, so that no host can
    /// continue a supposedly valid deterministic replay after a market quote was lost. The faulting
    /// quote is <see cref="SingleAnchorRunException.Quote"/>; it is not processed and does not become
    /// the engine's <see cref="SingleAnchorEngine.LastProcessedQuote"/>.
    /// </summary>
    public sealed class DataQualityException : SingleAnchorRunException
    {
        /// <summary>Creates the exception.</summary>
        public DataQualityException(DataQualityIssue issue, Quote quote, string message)
            : base(quote, message)
        {
            Issue = issue;
        }

        /// <summary>Which condition failed.</summary>
        public DataQualityIssue Issue { get; }

        /// <inheritdoc />
        public override string Kind => "DataQuality";

        /// <inheritdoc />
        public override string Condition => Issue.ToString();

        /// <inheritdoc />
        public override SingleAnchorRunException AsRefusal()
        {
            return new DataQualityException(Issue, Quote, "The engine is faulted and accepts no further quotes: " + Message);
        }
    }

    /// <summary>
    /// What the hard-BE requirement covers under a run's configuration, for the structured results.
    /// <see cref="StrategyDefinitionResolved"/> states that the two formerly open strategy-definition
    /// points (first-entry handling and the meaning of T_up / T_down) are resolved by the
    /// specification; <see cref="HardBEVerifiedUnderConfiguredExecutionModel"/> is runtime state:
    /// true while every applicable tail entry so far passed the post-fill verification with the
    /// actual fill under the configured execution model, false once one failed (the run then stops).
    /// It is not a guarantee against arbitrary future spread or other execution conditions that
    /// were not part of the projection.
    /// </summary>
    public sealed record HardBreakevenVerification(
        bool StrategyDefinitionResolved,
        bool HardBEVerifiedUnderConfiguredExecutionModel,
        string Scope,
        IReadOnlyList<string> Assumptions,
        IReadOnlyList<string> NotCovered)
    {
        /// <summary>
        /// Evaluates the verification metadata for a parameter set and a run's post-fill
        /// verification state.
        /// </summary>
        /// <param name="parameters">The validated parameters.</param>
        /// <param name="hardBeVerifiedUnderConfiguredExecutionModel">
        /// True when every applicable tail fill so far passed the post-fill verification; the engine
        /// passes false once a fill failed it (the run then stops).
        /// </param>
        public static HardBreakevenVerification For(SingleAnchorParameters parameters, bool hardBeVerifiedUnderConfiguredExecutionModel = true)
        {
            if (parameters == null) throw new ArgumentNullException(nameof(parameters));
            var w = parameters.ProjectedSpread!.Value;
            return new HardBreakevenVerification(
                true,
                hardBeVerifiedUnderConfiguredExecutionModel,
                "PL_after(T, Q) >= 0 is verified at each applicable tail entry, with the actual fill, under the configured execution model; it is not re-verified afterwards.",
                new[]
                {
                    $"upper recovery projection: Bid = T_up, Ask = T_up + {F(w)} (the boundary itself is Bid = T_up; the actual zero-loss BE must stay at or below it)",
                    $"lower recovery projection: Ask = T_down, Bid = T_down - {F(w)} (the boundary itself is Ask = T_down; the actual zero-loss BE must stay at or above it)",
                    $"slippage {F(parameters.Slippage)} per execution",
                    $"round-trip commission {F(parameters.CommissionPerLot)} per lot",
                    "financing is not supported (both swap rates are 0)"
                },
                new[]
                {
                    "a spread at the boundary wider than the configured target spread",
                    "a change of the execution model between the entry and the target"
                });
        }

        private static string F(decimal value)
        {
            return value.ToString(CultureInfo.InvariantCulture);
        }
    }

    /// <summary>
    /// The anchoring event of a basket: the exact source quote (sequence number, time, Bid, Ask)
    /// and the geometry derived from it.
    /// </summary>
    public sealed record AnchorRecord(
        int Basket,
        long QuoteSequence,
        DateTime Time,
        decimal Bid,
        decimal Ask,
        decimal Anchor,
        decimal Step,
        decimal Upper,
        decimal Lower,
        decimal LowerTarget,
        decimal UpperTarget);

    /// <summary>
    /// A deterministic FNV-1a 64-bit accumulator for the compact parity checksums. The algorithm
    /// and the canonical serialization are fixed so another implementation can reproduce a digest
    /// byte for byte. A 64-bit digest is a compact high-confidence mismatch detector, not a
    /// mathematical proof that every compressed attempt matched.
    /// </summary>
    /// <remarks>
    /// FNV-1a 64-bit: offset basis 14695981039346656037, prime 1099511628211, multiplication modulo
    /// 2^64. Decimal canonicalization: invariant-culture general format (no exponent), then the
    /// insignificant trailing zeros of the fractional part are removed and zero has one
    /// representation, so numerically equal values such as <c>1.2</c>, <c>1.20</c> and <c>1.200</c>
    /// hash identically and the checksum compares strategy values, not decimal representations.
    /// Fields are written directly into the accumulator, without an intermediate string.
    /// </remarks>
    internal struct ParityHasher
    {
        private const ulong OffsetBasis = 14695981039346656037UL;
        private const ulong Prime = 1099511628211UL;
        private ulong _hash;

        /// <summary>A fresh accumulator.</summary>
        public static ParityHasher Start()
        {
            return new ParityHasher { _hash = OffsetBasis };
        }

        /// <summary>The 16-character lower-case hexadecimal digest.</summary>
        public string Hex => _hash.ToString("x16", CultureInfo.InvariantCulture);

        /// <summary>Adds the '\n' field terminator.</summary>
        public void Separator()
        {
            AddByte((byte)'\n');
        }

        /// <summary>Adds an ASCII literal (field values and enum names built from ASCII constants).</summary>
        public void AddAscii(string text)
        {
            for (var i = 0; i < text.Length; i++)
            {
                AddByte((byte)text[i]);
            }
        }

        /// <summary>Adds an integer in invariant culture.</summary>
        public void AddLong(long value)
        {
            System.Span<char> buffer = stackalloc char[32];
            if (value.TryFormat(buffer, out var written, default, CultureInfo.InvariantCulture))
            {
                AddCanonicalNumber(buffer.Slice(0, written));
            }
        }

        /// <summary>Adds a decimal in its canonical numeric form (see the type remarks).</summary>
        public void AddDecimal(decimal value)
        {
            System.Span<char> buffer = stackalloc char[64];
            if (value.TryFormat(buffer, out var written, default, CultureInfo.InvariantCulture))
            {
                AddCanonicalNumber(buffer.Slice(0, written));
            }
        }

        /// <summary>Adds a decimal when present; a not-applicable value adds nothing.</summary>
        public void AddOptionalDecimal(decimal? value)
        {
            if (value.HasValue)
            {
                AddDecimal(value.Value);
            }
        }

        private void AddCanonicalNumber(System.ReadOnlySpan<char> chars)
        {
            var end = chars.Length;
            var dot = -1;
            for (var i = 0; i < end; i++)
            {
                if (chars[i] == '.')
                {
                    dot = i;
                    break;
                }
            }
            if (dot >= 0)
            {
                while (end > dot + 1 && chars[end - 1] == '0')
                {
                    end--;
                }
                if (end == dot + 1)
                {
                    end = dot;
                }
            }
            var allZero = true;
            for (var i = 0; i < end; i++)
            {
                var c = chars[i];
                if (c != '0' && c != '.' && c != '-')
                {
                    allZero = false;
                    break;
                }
            }
            if (allZero)
            {
                AddByte((byte)'0');
                return;
            }
            for (var i = 0; i < end; i++)
            {
                AddByte((byte)chars[i]);
            }
        }

        private void AddByte(byte value)
        {
            unchecked
            {
                _hash ^= value;
                _hash *= Prime;
            }
        }
    }

    /// <summary>
    /// The canonical per-attempt parity representation of a rejected entry, folded into the digest
    /// kept by each <see cref="EntryRejectionRecord"/>. The canonical field order is:
    /// quoteSequence, Bid, Ask, tradeNumber, side, reason, hardBreakevenOutcome, candidateEntryPrice,
    /// PL_existing, PL_1lot, exactRequiredLot, normalizedRequiredLot, rawRequestedLot, PL_after; each
    /// field is '\n'-terminated, decimals use the canonical numeric form of
    /// <see cref="ParityHasher"/>, enums their exact names and a not-applicable value is empty.
    /// </summary>
    internal static class RejectionParity
    {
        /// <summary>Human-readable description of the digest, stored with each row.</summary>
        public const string Algorithm =
            "FNV-1a 64-bit over UTF-8 canonical attempt fields, each '\\n'-terminated, in order: quoteSequence, Bid, Ask, tradeNumber, side, reason, hardBreakevenOutcome, candidateEntryPrice, PL_existing, PL_1lot, exactRequiredLot, normalizedRequiredLot, rawRequestedLot, PL_after; decimals in canonical numeric form (invariant culture general format, insignificant trailing zeros removed, zero as '0'); enums as their exact names; not-applicable values empty.";

        /// <summary>Folds one rejection attempt into the digest.</summary>
        public static void Add(
            ref ParityHasher hasher,
            long quoteSequence,
            decimal bid,
            decimal ask,
            int tradeNumber,
            TradeSide side,
            EntryRejectionReason reason,
            HardBreakevenOutcome? outcome,
            decimal? candidateEntryPrice,
            decimal? existingProfitAtTarget,
            decimal? marginalProfitPerLot,
            decimal? exactRequiredLots,
            decimal normalizedRequiredLots,
            decimal? rawRequestedLots,
            decimal? projectedProfitAfter)
        {
            hasher.AddLong(quoteSequence);
            hasher.Separator();
            hasher.AddDecimal(bid);
            hasher.Separator();
            hasher.AddDecimal(ask);
            hasher.Separator();
            hasher.AddLong(tradeNumber);
            hasher.Separator();
            hasher.AddAscii(side == TradeSide.Buy ? "Buy" : "Sell");
            hasher.Separator();
            AddReason(ref hasher, reason);
            hasher.Separator();
            AddOutcome(ref hasher, outcome);
            hasher.Separator();
            hasher.AddOptionalDecimal(candidateEntryPrice);
            hasher.Separator();
            hasher.AddOptionalDecimal(existingProfitAtTarget);
            hasher.Separator();
            hasher.AddOptionalDecimal(marginalProfitPerLot);
            hasher.Separator();
            hasher.AddOptionalDecimal(exactRequiredLots);
            hasher.Separator();
            hasher.AddDecimal(normalizedRequiredLots);
            hasher.Separator();
            hasher.AddOptionalDecimal(rawRequestedLots);
            hasher.Separator();
            hasher.AddOptionalDecimal(projectedProfitAfter);
            hasher.Separator();
        }

        private static void AddReason(ref ParityHasher hasher, EntryRejectionReason reason)
        {
            switch (reason)
            {
                case EntryRejectionReason.HardBreakevenInfeasible:
                    hasher.AddAscii("HardBreakevenInfeasible");
                    break;
                case EntryRejectionReason.VolumeExceedsMaximum:
                    hasher.AddAscii("VolumeExceedsMaximum");
                    break;
                default:
                    hasher.AddAscii("ExecutionFailed");
                    break;
            }
        }

        private static void AddOutcome(ref ParityHasher hasher, HardBreakevenOutcome? outcome)
        {
            if (!outcome.HasValue)
            {
                return;
            }
            switch (outcome.Value)
            {
                case HardBreakevenOutcome.Feasible:
                    hasher.AddAscii("Feasible");
                    break;
                case HardBreakevenOutcome.InvalidTargetPrices:
                    hasher.AddAscii("InvalidTargetPrices");
                    break;
                case HardBreakevenOutcome.NonPositiveMarginalProfit:
                    hasher.AddAscii("NonPositiveMarginalProfit");
                    break;
                default:
                    hasher.AddAscii("ExceedsMaximumVolume");
                    break;
            }
        }
    }

    /// <summary>
    /// The canonical compact parity representation of the skipped first-entry attempts of one
    /// basket. The canonical field order is: quoteSequence, Bid, Ask, each '\n'-terminated, with
    /// decimals in the canonical numeric form of <see cref="ParityHasher"/>. One digest per basket
    /// over every skipped quote, so a one-tick decision mismatch between two engines is detectable
    /// without one JSON row per skipped tick.
    /// </summary>
    internal static class SkippedFirstEntryParity
    {
        /// <summary>Human-readable description of the digest, stored with each trace.</summary>
        public const string Algorithm =
            "FNV-1a 64-bit over UTF-8 canonical skipped first-entry attempt fields, each '\\n'-terminated, in order: quoteSequence, Bid, Ask; decimals in canonical numeric form (invariant culture general format, insignificant trailing zeros removed, zero as '0').";

        /// <summary>Folds one skipped first-entry quote into the digest.</summary>
        public static void Add(ref ParityHasher hasher, long quoteSequence, decimal bid, decimal ask)
        {
            hasher.AddLong(quoteSequence);
            hasher.Separator();
            hasher.AddDecimal(bid);
            hasher.Separator();
            hasher.AddDecimal(ask);
            hasher.Separator();
        }
    }

    /// <summary>
    /// One rejected-entry episode as a trace row: the quote of its first attempt, what was
    /// required, why it was not opened and the full lot distinction. An episode is keyed by trade
    /// number, side, reason and hard-BE outcome; every attempt with that key is folded into the row
    /// (attempt count, last quote, parity digest and min/max values, including the min/max
    /// broker-normalized requirement) rather than stored as its own row, so a requirement that
    /// stays infeasible for hours, or oscillates between adjacent volume steps, does not produce a
    /// row per tick. The key is quote-independent, so an episode that reappears after another
    /// episode appends to its existing row instead of starting a new one. The digest makes every
    /// compressed attempt comparable with a port.
    /// </summary>
    public sealed class EntryRejectionRecord
    {
        private ParityHasher _parity;

        /// <summary>
        /// True when <paramref name="rejection"/> belongs to this episode: same trade number, side,
        /// reason and hard-BE outcome. The broker-normalized requirement is deliberately not part of
        /// the identity (it moves with every quote); the parity digest and the min/max normalized
        /// requirement preserve its variation.
        /// </summary>
        public bool IsSameEpisode(EntryRejection rejection)
        {
            return rejection.TradeNumber == TradeNumber
                && rejection.Side == Side
                && rejection.Reason == Reason
                && rejection.Sizing?.Outcome == Outcome;
        }

        internal EntryRejectionRecord(int basket, long quoteSequence, DateTime time, decimal bid, decimal ask, EntryRejection rejection)
        {
            Basket = basket;
            FirstQuoteSequence = quoteSequence;
            FirstTime = time;
            FirstBid = bid;
            FirstAsk = ask;
            TradeNumber = rejection.TradeNumber;
            Side = rejection.Side;
            Reason = rejection.Reason;
            RawRequestedLots = rejection.RawRequestedLots;
            ExactRequiredLots = rejection.ExactRequiredLots;
            NormalizedRequiredLots = rejection.NormalizedRequiredLots;
            PlacedLots = null;
            var s = rejection.Sizing;
            NormalizedLot = s?.NormalizedLot;
            Outcome = s?.Outcome;
            HardBreakevenTarget = s?.Target.Target;
            TargetSpread = s?.Target.Spread;
            TargetBid = s?.Target.Bid;
            TargetAsk = s?.Target.Ask;
            ExistingProfitAtTarget = s?.ExistingProfitAtTarget;
            MarginalProfitPerLot = s?.MarginalProfitPerLot;
            ProjectedProfitAfter = s?.ProjectedProfitAfter;
            Message = rejection.Message;
            Attempts = 1;
            LastQuoteSequence = quoteSequence;
            LastTime = time;
            LastBid = bid;
            LastAsk = ask;
            _parity = ParityHasher.Start();
            Include(rejection);
        }

        /// <summary>Basket sequence number.</summary>
        public int Basket { get; }

        /// <summary>Sequence number of the quote of the first attempt.</summary>
        public long FirstQuoteSequence { get; }

        /// <summary>Time of the first attempt's quote.</summary>
        public DateTime FirstTime { get; }

        /// <summary>Bid of the first attempt's quote.</summary>
        public decimal FirstBid { get; }

        /// <summary>Ask of the first attempt's quote.</summary>
        public decimal FirstAsk { get; }

        /// <summary>Trade number that was required.</summary>
        public int TradeNumber { get; }

        /// <summary>Side that was required.</summary>
        public TradeSide Side { get; }

        /// <summary>Why the entry was not opened.</summary>
        public EntryRejectionReason Reason { get; }

        /// <summary>The raw requested lot B * n of an arithmetic rejection; null otherwise.</summary>
        public decimal? RawRequestedLots { get; }

        /// <summary>The exact mathematically required lot Q_BE of a hard-BE rejection when the ratio applied; null otherwise.</summary>
        public decimal? ExactRequiredLots { get; }

        /// <summary>The upward broker-normalized lot of the first attempt (kept even above the maximum volume); 0 when no positive lot satisfies the requirement.</summary>
        public decimal NormalizedRequiredLots { get; }

        /// <summary>Always null on a rejection: nothing was placed.</summary>
        public decimal? PlacedLots { get; }

        /// <summary>The lot a feasible sizing would have placed (0 when none was placeable); null for a non-hard-BE rejection.</summary>
        public decimal? NormalizedLot { get; }

        /// <summary>The hard-BE sizing outcome; null for a non-hard-BE rejection.</summary>
        public HardBreakevenOutcome? Outcome { get; }

        /// <summary>T of the hard-BE sizing; null otherwise.</summary>
        public decimal? HardBreakevenTarget { get; }

        /// <summary>Target spread of the hard-BE sizing; null otherwise.</summary>
        public decimal? TargetSpread { get; }

        /// <summary>Projected Bid at the boundary; null otherwise.</summary>
        public decimal? TargetBid { get; }

        /// <summary>Projected Ask at the boundary; null otherwise.</summary>
        public decimal? TargetAsk { get; }

        /// <summary>PL_existing(T) of the first attempt; null otherwise.</summary>
        public decimal? ExistingProfitAtTarget { get; }

        /// <summary>PL_1lot(T) of the first attempt; null otherwise.</summary>
        public decimal? MarginalProfitPerLot { get; }

        /// <summary>Projected PL_after of the first attempt; null otherwise.</summary>
        public decimal? ProjectedProfitAfter { get; }

        /// <summary>The engine's message for the first attempt.</summary>
        public string Message { get; }

        /// <summary>Number of attempts of this episode, the first included.</summary>
        public long Attempts { get; private set; }

        /// <summary>Sequence number of the quote of the last attempt (the first when there is one).</summary>
        public long LastQuoteSequence { get; private set; }

        /// <summary>Time of the last attempt's quote.</summary>
        public DateTime LastTime { get; private set; }

        /// <summary>Bid of the last attempt's quote.</summary>
        public decimal LastBid { get; private set; }

        /// <summary>Ask of the last attempt's quote.</summary>
        public decimal LastAsk { get; private set; }

        /// <summary>Name of the parity algorithm used by <see cref="ParityHash"/>.</summary>
        public string ParityAlgorithm => RejectionParity.Algorithm;

        /// <summary>FNV-1a 64-bit digest over the canonical tuple of every attempt of this row.</summary>
        public string ParityHash => _parity.Hex;

        /// <summary>Smallest exact required lot over the attempts (null when the ratio never applied).</summary>
        public decimal? MinExactRequiredLots { get; private set; }

        /// <summary>Largest exact required lot over the attempts (null when the ratio never applied).</summary>
        public decimal? MaxExactRequiredLots { get; private set; }

        /// <summary>Smallest PL_existing(T) over the attempts (null when not applicable).</summary>
        public decimal? MinExistingProfitAtTarget { get; private set; }

        /// <summary>Largest PL_existing(T) over the attempts (null when not applicable).</summary>
        public decimal? MaxExistingProfitAtTarget { get; private set; }

        /// <summary>Smallest PL_1lot(T) over the attempts (null when not applicable).</summary>
        public decimal? MinMarginalProfitPerLot { get; private set; }

        /// <summary>Largest PL_1lot(T) over the attempts (null when not applicable).</summary>
        public decimal? MaxMarginalProfitPerLot { get; private set; }

        /// <summary>Smallest PL_after over the attempts (null when not applicable).</summary>
        public decimal? MinProjectedProfitAfter { get; private set; }

        /// <summary>Largest PL_after over the attempts (null when not applicable).</summary>
        public decimal? MaxProjectedProfitAfter { get; private set; }

        /// <summary>Smallest broker-normalized required lot over the attempts (the row aggregates across normalized-requirement changes).</summary>
        public decimal MinNormalizedRequiredLots { get; private set; }

        /// <summary>Largest broker-normalized required lot over the attempts (the row aggregates across normalized-requirement changes).</summary>
        public decimal MaxNormalizedRequiredLots { get; private set; }

        internal void AppendAttempt(long quoteSequence, DateTime time, decimal bid, decimal ask, EntryRejection rejection)
        {
            Attempts++;
            LastQuoteSequence = quoteSequence;
            LastTime = time;
            LastBid = bid;
            LastAsk = ask;
            Include(rejection);
        }

        private void Include(EntryRejection rejection)
        {
            var s = rejection.Sizing;
            RejectionParity.Add(
                ref _parity,
                LastQuoteSequence,
                LastBid,
                LastAsk,
                rejection.TradeNumber,
                rejection.Side,
                rejection.Reason,
                s?.Outcome,
                s?.CandidateEntryPrice,
                s?.ExistingProfitAtTarget,
                s?.MarginalProfitPerLot,
                rejection.ExactRequiredLots,
                rejection.NormalizedRequiredLots,
                rejection.RawRequestedLots,
                s?.ProjectedProfitAfter);
            IfSet(s?.ExistingProfitAtTarget, ref minExisting, ref maxExisting);
            IfSet(s?.MarginalProfitPerLot, ref minMarginal, ref maxMarginal);
            IfSet(s?.ProjectedProfitAfter, ref minAfter, ref maxAfter);
            IfSet(rejection.ExactRequiredLots, ref minExact, ref maxExact);
            if (Attempts <= 1 || rejection.NormalizedRequiredLots < MinNormalizedRequiredLots)
            {
                MinNormalizedRequiredLots = rejection.NormalizedRequiredLots;
            }
            if (Attempts <= 1 || rejection.NormalizedRequiredLots > MaxNormalizedRequiredLots)
            {
                MaxNormalizedRequiredLots = rejection.NormalizedRequiredLots;
            }

            MinExistingProfitAtTarget = minExisting;
            MaxExistingProfitAtTarget = maxExisting;
            MinMarginalProfitPerLot = minMarginal;
            MaxMarginalProfitPerLot = maxMarginal;
            MinProjectedProfitAfter = minAfter;
            MaxProjectedProfitAfter = maxAfter;
            MinExactRequiredLots = minExact;
            MaxExactRequiredLots = maxExact;
        }

        private decimal? minExisting;
        private decimal? maxExisting;
        private decimal? minMarginal;
        private decimal? maxMarginal;
        private decimal? minAfter;
        private decimal? maxAfter;
        private decimal? minExact;
        private decimal? maxExact;

        private static void IfSet(decimal? value, ref decimal? min, ref decimal? max)
        {
            if (!value.HasValue)
            {
                return;
            }
            if (!min.HasValue || value.Value < min.Value) min = value;
            if (!max.HasValue || value.Value > max.Value) max = value;
        }
    }

    /// <summary>
    /// The quotes on which a basket, still empty, satisfied both first-entry boundaries and
    /// therefore could not start (specification section 3). One compact row per basket: the first
    /// and last such quote and the number of occurrences, so the event is auditable without one
    /// record per tick.
    /// </summary>
    public sealed class SkippedFirstEntryRecord
    {
        private ParityHasher _parity;

        internal SkippedFirstEntryRecord(int basket, long quoteSequence, in Quote quote)
        {
            Basket = basket;
            FirstQuoteSequence = quoteSequence;
            FirstTime = quote.Time;
            FirstBid = quote.Bid;
            FirstAsk = quote.Ask;
            Attempts = 1;
            LastQuoteSequence = quoteSequence;
            LastTime = quote.Time;
            LastBid = quote.Bid;
            LastAsk = quote.Ask;
            _parity = ParityHasher.Start();
            SkippedFirstEntryParity.Add(ref _parity, quoteSequence, quote.Bid, quote.Ask);
        }

        /// <summary>Basket sequence number.</summary>
        public int Basket { get; }

        /// <summary>Sequence number of the first skipped quote.</summary>
        public long FirstQuoteSequence { get; }

        /// <summary>Time of the first skipped quote.</summary>
        public DateTime FirstTime { get; }

        /// <summary>Bid of the first skipped quote.</summary>
        public decimal FirstBid { get; }

        /// <summary>Ask of the first skipped quote.</summary>
        public decimal FirstAsk { get; }

        /// <summary>Number of quotes skipped for this basket, the first included.</summary>
        public long Attempts { get; private set; }

        /// <summary>Sequence number of the last skipped quote.</summary>
        public long LastQuoteSequence { get; private set; }

        /// <summary>Time of the last skipped quote.</summary>
        public DateTime LastTime { get; private set; }

        /// <summary>Bid of the last skipped quote.</summary>
        public decimal LastBid { get; private set; }

        /// <summary>Ask of the last skipped quote.</summary>
        public decimal LastAsk { get; private set; }

        /// <summary>Name of the parity algorithm used by <see cref="ParityHash"/>.</summary>
        public string ParityAlgorithm => SkippedFirstEntryParity.Algorithm;

        /// <summary>FNV-1a 64-bit digest over the canonical tuple of every skipped quote of this basket.</summary>
        public string ParityHash => _parity.Hex;

        internal void Repeat(long quoteSequence, in Quote quote)
        {
            Attempts++;
            LastQuoteSequence = quoteSequence;
            LastTime = quote.Time;
            LastBid = quote.Bid;
            LastAsk = quote.Ask;
            SkippedFirstEntryParity.Add(ref _parity, quoteSequence, quote.Bid, quote.Ask);
        }
    }

    /// <summary>
    /// The complete state of the current basket, with its valuation at a quote when it has legs
    /// (specification section 15: an open basket is marked to market, not closed). Anchor source,
    /// geometry, state, legs and rejections are always present; the profit figures are null
    /// without legs, and <paramref name="ExecutableProfit"/> is also null when the configured
    /// slippage makes a needed executable close price non-positive at the quote.
    /// </summary>
    public sealed record BasketSnapshot(
        int Sequence,
        AnchorRecord AnchorEvent,
        DateTime CreatedTime,
        decimal Anchor,
        decimal Step,
        decimal Upper,
        decimal Lower,
        decimal LowerTarget,
        decimal UpperTarget,
        int OpenPositions,
        TradeSide? LastSide,
        int NextTradeNumber,
        decimal BuyLots,
        decimal SellLots,
        decimal GrossLots,
        decimal NetLots,
        bool HardBreakevenModeActive,
        bool TrailingActive,
        decimal PeakProfit,
        Quote Quote,
        decimal? RawProfit,
        decimal? ExitProfit,
        decimal? ExecutableProfit,
        decimal? StepMoney,
        IReadOnlyList<LegRecord> LegTrace,
        IReadOnlyList<EntryRejectionRecord> RejectionTrace,
        SkippedFirstEntryRecord? SkippedFirstEntryTrace);

    /// <summary>
    /// One leg as a machine-comparable trace row: the quote it was decided on (sequence number
    /// and decision Bid/Ask), what was filled, when, under which regime and, for a tail leg, the
    /// sizing that produced it including the target spread assumed. The raw requested lot, the
    /// exact hard-BE requirement and the broker-normalized requirement stay separate from the
    /// placed lot.
    /// </summary>
    public sealed record LegRecord(
        int Basket,
        int TradeNumber,
        long QuoteSequence,
        DateTime Time,
        decimal DecisionBid,
        decimal DecisionAsk,
        TradeSide Side,
        decimal PlacedLot,
        decimal FillPrice,
        SizingRegime Regime,
        decimal? RawRequestedLot,
        decimal? ExactRequiredLot,
        decimal NormalizedRequiredLot,
        decimal? HardBreakevenTarget,
        decimal? TargetSpread,
        decimal? TargetBid,
        decimal? TargetAsk,
        decimal? ExistingProfitAtTarget,
        decimal? MarginalProfitPerLot,
        decimal? ProjectedProfitAfter)
    {
        /// <summary>Builds the row for a leg of the given basket.</summary>
        public static LegRecord From(int basket, BasketLeg leg)
        {
            if (leg == null) throw new ArgumentNullException(nameof(leg));
            var s = leg.Sizing;
            return new LegRecord(basket, leg.TradeNumber, leg.QuoteSequence, leg.EntryTime, leg.TriggerQuote.Bid, leg.TriggerQuote.Ask,
                leg.Side, leg.Lots, leg.EntryPrice, leg.Regime,
                leg.RawRequestedLots,
                s?.ExactRequired,
                s?.NormalizedRequiredLot ?? leg.Lots,
                s?.Target.Target, s?.Target.Spread, s?.Target.Bid, s?.Target.Ask,
                s?.ExistingProfitAtTarget, s?.MarginalProfitPerLot, s?.ProjectedProfitAfter);
        }
    }

    /// <summary>
    /// The strategy's own record of one closed basket: its anchor event, the closing quote
    /// (sequence, Bid, Ask), the decision quantities at that quote, the realized executable result
    /// of closing every leg under the configured model, and the leg, rejection and skipped
    /// first-entry traces.
    /// </summary>
    public sealed record BasketCloseRecord(
        int Sequence,
        AnchorRecord AnchorEvent,
        DateTime CreatedTime,
        DateTime ClosedTime,
        long CloseQuoteSequence,
        decimal CloseBid,
        decimal CloseAsk,
        decimal Anchor,
        ExitReason Reason,
        int Legs,
        decimal BuyLots,
        decimal SellLots,
        decimal GrossLots,
        decimal NetLots,
        bool HardBreakevenModeActive,
        decimal RawProfit,
        decimal ExitProfit,
        decimal Threshold,
        decimal BuyClosePrice,
        decimal SellClosePrice,
        decimal Commission,
        decimal RealizedProfit,
        IReadOnlyList<LegRecord> LegTrace,
        IReadOnlyList<EntryRejectionRecord> RejectionTrace,
        SkippedFirstEntryRecord? SkippedFirstEntryTrace);

    // ---- Events raised by the engine ----

    /// <summary>A new basket was anchored on this quote.</summary>
    public sealed record AnchorCreatedEvent(Basket Basket, Quote Quote);

    /// <summary>
    /// A still-empty basket saw a quote that satisfied both first-entry boundaries and therefore
    /// did not start (specification section 3). Raised once per basket, on the first such quote;
    /// later occurrences are counted on the basket's skipped-first-entry trace.
    /// </summary>
    public sealed record FirstEntrySkippedEvent(Basket Basket, SkippedFirstEntryRecord Record, Quote Quote);

    /// <summary>A leg was filled and added to the basket, after the post-fill hard-BE verification for a tail leg.</summary>
    public sealed record EntryOpenedEvent(Basket Basket, BasketLeg Leg, Quote Quote, HardBreakevenSizing? Sizing);

    /// <summary>A leg the grid required was not opened. Raised once per distinct rejected-entry episode; every attempt is in the basket's rejection trace.</summary>
    public sealed record EntryRejectedEvent(Basket Basket, EntryRejection Rejection, Quote Quote);

    /// <summary>
    /// Diagnostic raised just before the engine throws
    /// <see cref="StrategyInvariant.HardBreakevenViolatedByFill"/> (the fault is already recorded):
    /// the tail leg was filled and is in the ledger, but the projected executable basket P/L at
    /// its hard boundary is negative. The leg is not published as a normal successful entry.
    /// </summary>
    public sealed record HardBreakevenViolatedEvent(Basket Basket, BasketLeg Leg, HardBreakevenSizing Sizing, decimal ProjectedProfitAfterFill, Quote Quote);

    /// <summary>Trailing activated on this quote (specification section 13).</summary>
    public sealed record TrailingActivatedEvent(Basket Basket, decimal Profit, decimal ActivationThreshold, Quote Quote);

    /// <summary>The basket was closed; <paramref name="Record"/> carries the decision and realized figures.</summary>
    public sealed record BasketClosedEvent(Basket Basket, BasketCloseRecord Record, Quote Quote);

    /// <summary>The executor could not close the basket; it stays open and the exit is re-evaluated on the next quote.</summary>
    public sealed record BasketCloseFailedEvent(Basket Basket, ExitReason Reason, Quote Quote, string Message);

    /// <summary>Null-safe event invocation.</summary>
    internal static class EventExtensions
    {
        public static void Raise<T>(this Action<T>? handler, T args)
        {
            handler?.Invoke(args);
        }
    }
}
