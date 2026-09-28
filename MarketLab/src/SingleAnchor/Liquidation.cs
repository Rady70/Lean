using System;
using System.Collections.Generic;

namespace MarketLab.SingleAnchor
{
    /// <summary>
    /// How a Stop Out episode ended under the Phase B broker-liquidation model. A null outcome in
    /// <see cref="StopOutEpisodeRecord"/> means the run stopped before the episode could resolve
    /// (a forced-close execution failure or an unavailable executable mark), so nothing is
    /// fabricated about how it would have resolved.
    /// </summary>
    public enum StopOutEpisodeOutcome
    {
        /// <summary>
        /// Forced liquidation restored the account outside the Stop Out condition; the surviving
        /// basket continued to be processed from its remaining positions.
        /// </summary>
        MarginRestored,

        /// <summary>
        /// Forced liquidation removed every open position. The basket ended through the
        /// broker-liquidation terminal reason, not through a strategy exit.
        /// </summary>
        AllPositionsLiquidated
    }

    /// <summary>
    /// The account state observed before or after one broker action, in the same executable
    /// valuation the survival rule uses. <see cref="FreeMargin"/> and
    /// <see cref="MarginLevelPercent"/> are null when the used margin is zero and the ratio is
    /// undefined, exactly as in the margin model.
    /// </summary>
    public sealed record LiquidationAccountState(
        decimal Balance,
        decimal FloatingProfit,
        decimal Equity,
        decimal UsedMargin,
        decimal? FreeMargin,
        decimal? MarginLevelPercent,
        int OpenPositions);

    /// <summary>
    /// One deterministic broker-forced close of an individual open position with the account state
    /// observed before and after it. The leg identity is the immutable
    /// <see cref="LiquidatedLegRecord"/>; the account values are this account's own executable
    /// observations, so the event is independently auditable without re-deriving the account.
    /// </summary>
    public sealed record ForcedLiquidationRecord(
        LiquidatedLegRecord Leg,
        LiquidationAccountState Before,
        LiquidationAccountState After);

    /// <summary>
    /// One Stop Out episode: the account state that triggered deterministic broker liquidation, the
    /// ordered forced closes (least-profitable open position first; equal-profit ties by the
    /// higher immutable trade number), and how the episode ended. A null
    /// <see cref="Outcome"/> is an unresolved episode at the end of the run. The account never
    /// invents a strategy exit here: a basket whose positions were all removed ends through
    /// <see cref="ExitReason.BrokerLiquidation"/>.
    /// </summary>
    public sealed record StopOutEpisodeRecord(
        int Basket,
        StopOutReason Reason,
        long TriggerQuoteSequence,
        DateTime TriggerTime,
        decimal TriggerBid,
        decimal TriggerAsk,
        LiquidationAccountState AtTrigger,
        IReadOnlyList<ForcedLiquidationRecord> Liquidations,
        StopOutEpisodeOutcome? Outcome,
        DateTime? ResolvedTime,
        LiquidationAccountState AfterLiquidation);
}
