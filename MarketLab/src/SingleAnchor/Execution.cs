using System;

namespace MarketLab.SingleAnchor
{
    /// <summary>
    /// Which exit rule closed, or is closing, the basket (specification section 14).
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
    /// Outcome of an execution request handed to the host.
    /// </summary>
    public enum ExecutionStatus
    {
        /// <summary>Filled immediately; the fill price and volume are known.</summary>
        Filled,

        /// <summary>
        /// Accepted but not yet filled. The host must later call the engine's confirm or reject
        /// method for the pending operation (LEAN fills backtest market orders after OnData).
        /// </summary>
        Pending,

        /// <summary>Not accepted; nothing was placed.</summary>
        Failed
    }

    /// <summary>
    /// What the host reports back for an execution request.
    /// </summary>
    public readonly record struct ExecutionResult(ExecutionStatus Status, decimal FillPrice, decimal FilledLots, string? Message)
    {
        /// <summary>A completed fill.</summary>
        public static ExecutionResult Fill(decimal fillPrice, decimal filledLots, string? message = null)
        {
            return new ExecutionResult(ExecutionStatus.Filled, fillPrice, filledLots, message);
        }

        /// <summary>An accepted request whose fill will be reported later.</summary>
        public static ExecutionResult Pending(string? message = null)
        {
            return new ExecutionResult(ExecutionStatus.Pending, 0m, 0m, message);
        }

        /// <summary>A rejected request.</summary>
        public static ExecutionResult Failure(string message)
        {
            return new ExecutionResult(ExecutionStatus.Failed, 0m, 0m, message);
        }
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
    /// The host's side of execution. The engine decides; the host places orders and reports fills.
    /// Implementations must not throw for ordinary rejections; they return
    /// <see cref="ExecutionResult.Failure"/> so the engine can surface them explicitly.
    /// </summary>
    public interface IBasketExecutor
    {
        /// <summary>Opens one leg of the given side and volume.</summary>
        ExecutionResult OpenPosition(EntryOrder order);

        /// <summary>Closes every leg of the basket.</summary>
        ExecutionResult CloseBasket(CloseOrder order);
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

        /// <summary>The host did not accept the order, or a pending order was later rejected.</summary>
        ExecutionFailed
    }

    /// <summary>
    /// Record of a rejected entry attempt.
    /// </summary>
    public sealed record EntryRejection(int TradeNumber, TradeSide Side, EntryRejectionReason Reason, decimal RequestedLots, string Message, HardBreakevenSizing? Sizing)
    {
        /// <summary>
        /// True when this rejection is the same situation as <paramref name="other"/>: same trade,
        /// side and reason. Used to report a persisting infeasibility once.
        /// </summary>
        public bool SameSituationAs(EntryRejection? other)
        {
            return other != null && other.TradeNumber == TradeNumber && other.Side == Side && other.Reason == Reason;
        }
    }

    /// <summary>
    /// Values of an open basket at a quote, without any side effect (used for end-of-data
    /// mark-to-market reporting, specification section 15).
    /// </summary>
    public sealed record BasketValuation(
        Quote Quote,
        int OpenPositions,
        decimal BuyLots,
        decimal SellLots,
        decimal GrossLots,
        decimal NetLots,
        decimal RawProfit,
        decimal ExitProfit,
        decimal StepMoney,
        bool HardBreakevenModeActive,
        bool TrailingActive,
        decimal PeakProfit);

    // ---- Events raised by the engine ----

    /// <summary>A new basket was anchored on this quote.</summary>
    public sealed record AnchorCreatedEvent(Basket Basket, Quote Quote);

    /// <summary>A leg was filled and added to the basket.</summary>
    public sealed record EntryOpenedEvent(Basket Basket, BasketLeg Leg, Quote Quote, HardBreakevenSizing? Sizing);

    /// <summary>A leg the grid required was not opened. Raised once per distinct situation.</summary>
    public sealed record EntryRejectedEvent(Basket Basket, EntryRejection Rejection, Quote Quote);

    /// <summary>An entry order was accepted by the host and awaits its fill.</summary>
    public sealed record EntryPendingEvent(Basket Basket, EntryOrder Order);

    /// <summary>Trailing activated on this quote (specification section 13).</summary>
    public sealed record TrailingActivatedEvent(Basket Basket, decimal Profit, decimal ActivationThreshold, Quote Quote);

    /// <summary>A close order was accepted by the host and awaits its fill.</summary>
    public sealed record BasketClosePendingEvent(Basket Basket, ExitReason Reason, Quote Quote);

    /// <summary>
    /// The basket was closed. <paramref name="ExitProfit"/> and <paramref name="RawProfit"/> are the
    /// strategy's own accounting at the closing quote; <paramref name="HostFillPrice"/> is whatever
    /// the host reported for its flattening execution, if anything.
    /// </summary>
    public sealed record BasketClosedEvent(Basket Basket, ExitReason Reason, Quote Quote, decimal RawProfit, decimal ExitProfit, decimal Threshold, decimal? HostFillPrice);

    /// <summary>The host could not close the basket; it stays open and the exit is re-evaluated on the next quote.</summary>
    public sealed record BasketCloseFailedEvent(Basket Basket, ExitReason Reason, Quote Quote, string Message);

    /// <summary>A quote was ignored: invalid prices or out of time order.</summary>
    public sealed record InvalidQuoteEvent(Quote Quote, string Message);

    /// <summary>
    /// A quote arrived while an entry or close was still pending with the host; the engine only
    /// observed it. Raised once per pending operation.
    /// </summary>
    public sealed record QuoteSkippedWhilePendingEvent(Basket Basket, Quote Quote, string Message);

    /// <summary>Marker for a null-safe event invocation helper.</summary>
    internal static class EventExtensions
    {
        public static void Raise<T>(this Action<T>? handler, T args)
        {
            handler?.Invoke(args);
        }
    }
}
