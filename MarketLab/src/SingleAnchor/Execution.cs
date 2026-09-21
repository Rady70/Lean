using System;
using System.Collections.Generic;

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
    /// and closes at the Ask plus slippage. Commission and swap are applied by the engine from
    /// the same parameters. It never fails and never fills partially.
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
    /// Record of a rejected entry attempt.
    /// </summary>
    public sealed record EntryRejection(int TradeNumber, TradeSide Side, EntryRejectionReason Reason, decimal RequestedLots, string Message, HardBreakevenSizing? Sizing)
    {
        /// <summary>
        /// True when this rejection is the same situation as <paramref name="other"/>: same trade,
        /// side and reason, and for a hard-BE rejection the same outcome and the same required lot
        /// after normalization. A persisting situation is reported once; a materially changed
        /// requirement is reported again.
        /// </summary>
        public bool SameSituationAs(EntryRejection? other, decimal volumeStep)
        {
            if (other == null || other.TradeNumber != TradeNumber || other.Side != Side || other.Reason != Reason)
            {
                return false;
            }
            if (Sizing == null || other.Sizing == null)
            {
                return Sizing == null && other.Sizing == null;
            }
            return Sizing.Outcome == other.Sizing.Outcome
                && VolumeMath.CeilToStep(Sizing.RequiredLot, volumeStep) == VolumeMath.CeilToStep(other.Sizing.RequiredLot, volumeStep);
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
        /// One quote satisfied both entry rules of an empty basket (Ask >= Upper and
        /// Bid &lt;= Lower, a spread of at least two grid steps). The specification defines no rule
        /// for this case and its treatment is an unresolved owner decision (no priority, no skip,
        /// no double entry is added); until it is decided the engine stops rather than choose.
        /// </summary>
        BothBoundariesSatisfied,

        /// <summary>
        /// A tail leg was filled at a price that leaves the projected executable basket P/L at
        /// its hard target negative: the executor departed from the sizing model, and continuing
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
    /// continue a supposedly valid deterministic replay after a market quote was lost.
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
    /// What the hard-BE requirement does and does not cover under a run's configuration, for the
    /// structured results. The requirement is verified at each tail entry under the listed
    /// assumptions; it is never re-verified afterwards. A run is <see cref="Qualified"/> only when
    /// nothing in its configuration can move the projected result after the entry, which today
    /// means zero swap; a configured swap adds financing after the entry that is not re-verified,
    /// so such a run is reported as not qualified rather than looking like a zero-swap run.
    /// </summary>
    public sealed record HardBreakevenGuarantee(
        bool Qualified,
        string Scope,
        IReadOnlyList<string> Assumptions,
        IReadOnlyList<string> NotCovered,
        IReadOnlyList<string> UnqualifiedReasons)
    {
        /// <summary>Evaluates the guarantee metadata for a parameter set.</summary>
        public static HardBreakevenGuarantee For(SingleAnchorParameters parameters)
        {
            if (parameters == null) throw new ArgumentNullException(nameof(parameters));
            var unqualified = new List<string>();
            if (parameters.SwapConfigured)
            {
                unqualified.Add($"Swap is configured (buy {parameters.BuySwapPerLotPerDay} / sell {parameters.SellSwapPerLotPerDay} per lot per day): financing accrued at rollovers after a tail entry enters the basket's projected P/L at the target and is not re-verified against the requirement; the specification defines no response and none is added.");
            }
            return new HardBreakevenGuarantee(
                unqualified.Count == 0,
                "PL_after(T, Q) >= 0 is verified once, immediately after each tail entry, with the actual fill; it is not re-verified afterwards.",
                new[]
                {
                    $"target spread {parameters.ProjectedSpread ?? 0m} (configured; the projected Bid/Ask at the target are T -/+ half of it, an interpretation of T pending owner approval)",
                    $"slippage {parameters.Slippage} per execution",
                    $"round-trip commission {parameters.CommissionPerLot} per lot",
                    "swap accrued up to the entry"
                },
                new[]
                {
                    "a spread wider than the configured target spread when the market reaches the target",
                    "financing accrued after the entry",
                    "any change of the execution model between the entry and the target"
                },
                unqualified);
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
    /// One rejected-entry situation as a trace row: the quote of its first attempt, what was
    /// required, why it was not opened and, for a hard-BE rejection, the full sizing figures of
    /// that first attempt. A situation is the same as long as trade number, side, reason,
    /// hard-BE outcome and normalized required lot do not change; every later attempt of the
    /// same situation is counted in <see cref="Attempts"/> and identified by the last attempt's
    /// quote (sequence, time, Bid, Ask) rather than stored as its own row, so a requirement that
    /// stays infeasible for hours does not produce a row per tick. A materially changed
    /// requirement is a new row.
    /// </summary>
    public sealed class EntryRejectionRecord
    {
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
            RequestedLots = rejection.RequestedLots;
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

        /// <summary>The requested lot (arithmetic) or the exact required lot Q_BE (hard-BE).</summary>
        public decimal RequestedLots { get; }

        /// <summary>The normalized lot of a hard-BE sizing (0 when infeasible); null otherwise.</summary>
        public decimal? NormalizedLot { get; }

        /// <summary>The hard-BE sizing outcome; null for a non-hard-BE rejection.</summary>
        public HardBreakevenOutcome? Outcome { get; }

        /// <summary>T of the hard-BE sizing; null otherwise.</summary>
        public decimal? HardBreakevenTarget { get; }

        /// <summary>Target spread of the hard-BE sizing; null otherwise.</summary>
        public decimal? TargetSpread { get; }

        /// <summary>Projected Bid at the target; null otherwise.</summary>
        public decimal? TargetBid { get; }

        /// <summary>Projected Ask at the target; null otherwise.</summary>
        public decimal? TargetAsk { get; }

        /// <summary>PL_existing(T) of the hard-BE sizing; null otherwise.</summary>
        public decimal? ExistingProfitAtTarget { get; }

        /// <summary>PL_1lot(T) of the hard-BE sizing; null otherwise.</summary>
        public decimal? MarginalProfitPerLot { get; }

        /// <summary>Projected PL_after of the hard-BE sizing; null otherwise.</summary>
        public decimal? ProjectedProfitAfter { get; }

        /// <summary>The engine's message for the first attempt.</summary>
        public string Message { get; }

        /// <summary>Number of attempts of this situation, the first included.</summary>
        public int Attempts { get; private set; }

        /// <summary>Sequence number of the quote of the last attempt (the first when there is one).</summary>
        public long LastQuoteSequence { get; private set; }

        /// <summary>Time of the last attempt's quote.</summary>
        public DateTime LastTime { get; private set; }

        /// <summary>Bid of the last attempt's quote.</summary>
        public decimal LastBid { get; private set; }

        /// <summary>Ask of the last attempt's quote.</summary>
        public decimal LastAsk { get; private set; }

        internal void Repeat(long quoteSequence, DateTime time, decimal bid, decimal ask)
        {
            Attempts++;
            LastQuoteSequence = quoteSequence;
            LastTime = time;
            LastBid = bid;
            LastAsk = ask;
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
        decimal AccruedSwap,
        bool HardBreakevenModeActive,
        bool TrailingActive,
        decimal PeakProfit,
        Quote Quote,
        decimal? RawProfit,
        decimal? ExitProfit,
        decimal? ExecutableProfit,
        decimal? StepMoney,
        IReadOnlyList<LegRecord> LegTrace,
        IReadOnlyList<EntryRejectionRecord> RejectionTrace);

    /// <summary>
    /// One leg as a machine-comparable trace row: the quote it was decided on (sequence number
    /// and decision Bid/Ask), what was filled, when, under which regime and, for a tail leg, the
    /// sizing that produced it including the target spread assumed.
    /// </summary>
    public sealed record LegRecord(
        int Basket,
        int TradeNumber,
        long QuoteSequence,
        DateTime Time,
        decimal DecisionBid,
        decimal DecisionAsk,
        TradeSide Side,
        decimal Lots,
        decimal FillPrice,
        SizingRegime Regime,
        decimal AccruedSwap,
        decimal? HardBreakevenTarget,
        decimal? TargetSpread,
        decimal? TargetBid,
        decimal? TargetAsk,
        decimal? ExistingProfitAtTarget,
        decimal? MarginalProfitPerLot,
        decimal? RequiredLot,
        decimal? ProjectedProfitAfter)
    {
        /// <summary>Builds the row for a leg of the given basket.</summary>
        public static LegRecord From(int basket, BasketLeg leg)
        {
            if (leg == null) throw new ArgumentNullException(nameof(leg));
            var s = leg.Sizing;
            return new LegRecord(basket, leg.TradeNumber, leg.QuoteSequence, leg.EntryTime, leg.TriggerQuote.Bid, leg.TriggerQuote.Ask,
                leg.Side, leg.Lots, leg.EntryPrice, leg.Regime, leg.AccruedSwap,
                s?.Target.Target, s?.Target.Spread, s?.Target.Bid, s?.Target.Ask,
                s?.ExistingProfitAtTarget, s?.MarginalProfitPerLot, s?.RequiredLot, s?.ProjectedProfitAfter);
        }
    }

    /// <summary>
    /// The strategy's own record of one closed basket: its anchor event, the closing quote
    /// (sequence, Bid, Ask), the decision quantities at that quote, the realized executable result
    /// of closing every leg under the configured model, and the leg and rejection traces.
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
        decimal Swap,
        decimal Commission,
        decimal RealizedProfit,
        IReadOnlyList<LegRecord> LegTrace,
        IReadOnlyList<EntryRejectionRecord> RejectionTrace);

    // ---- Events raised by the engine ----

    /// <summary>A new basket was anchored on this quote.</summary>
    public sealed record AnchorCreatedEvent(Basket Basket, Quote Quote);

    /// <summary>A leg was filled and added to the basket.</summary>
    public sealed record EntryOpenedEvent(Basket Basket, BasketLeg Leg, Quote Quote, HardBreakevenSizing? Sizing);

    /// <summary>A leg the grid required was not opened. Raised once per distinct situation; every attempt is in the basket's rejection trace.</summary>
    public sealed record EntryRejectedEvent(Basket Basket, EntryRejection Rejection, Quote Quote);

    /// <summary>
    /// Diagnostic raised just before the engine throws
    /// <see cref="StrategyInvariant.HardBreakevenViolatedByFill"/> (the fault is already recorded):
    /// the tail leg was filled and is in the ledger, but the projected executable basket P/L at
    /// its hard target is negative.
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
