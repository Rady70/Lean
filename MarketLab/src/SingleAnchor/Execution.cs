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
    /// The strategy invariants whose violation stops a run instead of being turned into a
    /// trading decision.
    /// </summary>
    public enum StrategyInvariant
    {
        /// <summary>
        /// One quote satisfied both entry rules of an empty basket (Ask >= Upper and
        /// Bid &lt;= Lower, a spread of at least two grid steps). The specification defines the
        /// grid for quotes narrower than the grid and no rule for this case; the configuration is
        /// not valid for the data.
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
    /// Thrown by the engine when a strategy invariant fails; the engine is faulted afterwards and
    /// refuses further quotes. A host must stop the run, not continue trading.
    /// </summary>
    public sealed class StrategyInvariantException : InvalidOperationException
    {
        /// <summary>Creates the exception.</summary>
        public StrategyInvariantException(StrategyInvariant invariant, Quote quote, string message)
            : base(message)
        {
            Invariant = invariant;
            Quote = quote;
        }

        /// <summary>Which invariant failed.</summary>
        public StrategyInvariant Invariant { get; }

        /// <summary>The quote being processed when it failed.</summary>
        public Quote Quote { get; }
    }

    /// <summary>
    /// The market-data conditions a research run cannot silently survive: a quote tick with
    /// non-positive or crossed prices, or one earlier than an already processed quote. Ignoring
    /// such a tick would change a path-dependent tick strategy's entries, exits and peaks, so the
    /// result would no longer be a faithful replay.
    /// </summary>
    public enum DataQualityIssue
    {
        /// <summary>A quote tick whose bid or ask is not positive or whose ask is below its bid.</summary>
        InvalidQuoteTick,

        /// <summary>A quote tick stamped earlier than a quote the engine already processed.</summary>
        OutOfOrderQuoteTick
    }

    /// <summary>
    /// Thrown by the tick feed when the market data fails a quality condition; the run is not a
    /// valid research result and a host must stop it.
    /// </summary>
    public sealed class DataQualityException : InvalidOperationException
    {
        /// <summary>Creates the exception.</summary>
        public DataQualityException(DataQualityIssue issue, Quote quote, string message)
            : base(message)
        {
            Issue = issue;
            Quote = quote;
        }

        /// <summary>Which condition failed.</summary>
        public DataQualityIssue Issue { get; }

        /// <summary>The offending tick as a quote (its prices may be invalid).</summary>
        public Quote Quote { get; }
    }

    /// <summary>
    /// The complete state of the current basket, with its valuation at a quote when it has legs
    /// (specification section 15: an open basket is marked to market, not closed). Geometry and
    /// state are always present; the profit figures are null without legs, and
    /// <paramref name="ExecutableProfit"/> is also null when the configured slippage makes a
    /// needed executable close price non-positive at the quote.
    /// </summary>
    public sealed record BasketSnapshot(
        int Sequence,
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
        decimal? StepMoney);

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
    /// The strategy's own record of one closed basket: the closing quote (sequence, Bid, Ask),
    /// the decision quantities at that quote, the realized executable result of closing every
    /// leg under the configured model, and the leg trace.
    /// </summary>
    public sealed record BasketCloseRecord(
        int Sequence,
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
        IReadOnlyList<LegRecord> LegTrace);

    // ---- Events raised by the engine ----

    /// <summary>A new basket was anchored on this quote.</summary>
    public sealed record AnchorCreatedEvent(Basket Basket, Quote Quote);

    /// <summary>A leg was filled and added to the basket.</summary>
    public sealed record EntryOpenedEvent(Basket Basket, BasketLeg Leg, Quote Quote, HardBreakevenSizing? Sizing);

    /// <summary>A leg the grid required was not opened. Raised once per distinct situation.</summary>
    public sealed record EntryRejectedEvent(Basket Basket, EntryRejection Rejection, Quote Quote);

    /// <summary>
    /// Diagnostic raised just before the engine faults with
    /// <see cref="StrategyInvariant.HardBreakevenViolatedByFill"/>: the tail leg was filled and is
    /// in the ledger, but the projected executable basket P/L at its hard target is negative.
    /// </summary>
    public sealed record HardBreakevenViolatedEvent(Basket Basket, BasketLeg Leg, HardBreakevenSizing Sizing, decimal ProjectedProfitAfterFill, Quote Quote);

    /// <summary>Trailing activated on this quote (specification section 13).</summary>
    public sealed record TrailingActivatedEvent(Basket Basket, decimal Profit, decimal ActivationThreshold, Quote Quote);

    /// <summary>The basket was closed; <paramref name="Record"/> carries the decision and realized figures.</summary>
    public sealed record BasketClosedEvent(Basket Basket, BasketCloseRecord Record, Quote Quote);

    /// <summary>The executor could not close the basket; it stays open and the exit is re-evaluated on the next quote.</summary>
    public sealed record BasketCloseFailedEvent(Basket Basket, ExitReason Reason, Quote Quote, string Message);

    /// <summary>A quote was ignored: invalid prices or out of time order.</summary>
    public sealed record InvalidQuoteEvent(Quote Quote, string Message);

    /// <summary>Null-safe event invocation.</summary>
    internal static class EventExtensions
    {
        public static void Raise<T>(this Action<T>? handler, T args)
        {
            handler?.Invoke(args);
        }
    }
}
