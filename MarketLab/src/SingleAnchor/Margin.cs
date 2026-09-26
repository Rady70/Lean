using System;
using System.Collections.Generic;
using System.Globalization;

namespace MarketLab.SingleAnchor
{
    /// <summary>
    /// The frozen PR 3 target-account margin configuration (approved roadmap contract, sections
    /// 3.16-3.21): a USD-denominated XM Global Ultra Low Standard-style research account with
    /// hedging position accounting, a fixed selected leverage and the MT5/XM hedging margin rule.
    /// The approved PR 3 values are the defaults - 100 oz per lot, fixed 1:500, Margin Call 50%,
    /// Stop-out 20% - and the production host instantiates exactly those values (it also enforces
    /// the XAUUSD CFD instrument and the 100-per-lot USD point value). The record stays
    /// internally parameterizable so the arithmetic can be tested independently, but PR 3 must
    /// not expose dynamic or equity-based leverage tiers, a multi-currency account or a generic
    /// multi-broker framework. It is deliberately not part of
    /// <see cref="SingleAnchorParameters"/>: the strategy parameter block that the parity
    /// projection hashes stays unchanged, and margin is a research-account capability, not a
    /// strategy formula.
    /// </summary>
    public sealed record MarginParameters
    {
        /// <summary>XAUUSD contract size in ounces per lot. PR 3 approves 100 (the same 100-oz lot the 100/lot point value assumes).</summary>
        public decimal ContractSize { get; init; } = 100m;

        /// <summary>Fixed selected leverage. PR 3 approves 1:500; no dynamic or equity-based tiers exist in this phase.</summary>
        public decimal Leverage { get; init; } = 500m;

        /// <summary>
        /// Margin Call Level in percent. At or below it (while above stop-out) the account stays
        /// alive, exits are still allowed, and no new position may be opened. PR 3 approves 50.
        /// </summary>
        public decimal MarginCallLevelPercent { get; init; } = 50m;

        /// <summary>
        /// Stop-out Level in percent. At or below it the survival path is terminal. PR 3 approves
        /// 20. The negative-equity rule for an account with open positions is additional and does
        /// not depend on this value.
        /// </summary>
        public decimal StopOutLevelPercent { get; init; } = 20m;

        /// <summary>Returns every problem with this margin configuration, in a fixed order; empty when valid.</summary>
        public IReadOnlyList<string> GetValidationErrors()
        {
            var errors = new List<string>();

            if (ContractSize <= 0m) errors.Add($"{nameof(ContractSize)} must be > 0 oz per lot (got {F(ContractSize)}).");
            if (Leverage <= 0m) errors.Add($"{nameof(Leverage)} must be > 0 (got {F(Leverage)}); PR 3 approves a fixed 1:500 and no leverage tiers.");
            if (StopOutLevelPercent <= 0m || StopOutLevelPercent >= 100m) errors.Add($"{nameof(StopOutLevelPercent)} must be > 0 and < 100 (got {F(StopOutLevelPercent)}).");
            if (MarginCallLevelPercent <= StopOutLevelPercent) errors.Add($"{nameof(MarginCallLevelPercent)} ({F(MarginCallLevelPercent)}) must be > {nameof(StopOutLevelPercent)} ({F(StopOutLevelPercent)}): the entry block sits above the terminal stop-out.");
            if (MarginCallLevelPercent >= 100m) errors.Add($"{nameof(MarginCallLevelPercent)} must be < 100 (got {F(MarginCallLevelPercent)}).");

            return errors;
        }

        /// <summary>Throws <see cref="ArgumentException"/> listing every problem when the margin configuration is invalid.</summary>
        public void Validate()
        {
            var errors = GetValidationErrors();
            if (errors.Count > 0)
            {
                throw new ArgumentException("Invalid SingleAnchor margin parameters: " + string.Join(" ", errors));
            }
        }

        private static string F(decimal value)
        {
            return value.ToString(CultureInfo.InvariantCulture);
        }
    }

    /// <summary>
    /// The approved PR 3 MT5/XM-style hedging margin arithmetic. Pure functions: nothing here owns
    /// positions or account state; <see cref="Basket"/>/<see cref="BasketLeg"/> remain the position
    /// truth. The covered (matched) BUY/SELL volume has zero margin; only the uncovered side is
    /// charged, at the frozen contract-leverage formula
    /// <c>uncovered lots * contract size * weighted-average open price / leverage</c>. A projected
    /// candidate fill is always evaluated against the complete projected post-fill BUY/SELL
    /// inventory, so an opposite-side entry that increases the matched hedge correctly reduces the
    /// projected used margin instead of being treated as an isolated incremental charge.
    /// </summary>
    public static class MarginModel
    {
        /// <summary>
        /// Used margin of the basket's current inventory. Zero when the inventory is net-flat or
        /// empty; otherwise the uncovered volume at the weighted-average open price of the larger
        /// side. Constant time from the basket's existing aggregates.
        /// </summary>
        public static decimal UsedMargin(Basket basket, MarginParameters margin)
        {
            if (basket == null) throw new ArgumentNullException(nameof(basket));
            if (margin == null) throw new ArgumentNullException(nameof(margin));
            return UsedMargin(basket.BuyLots, basket.BuyNotional, basket.SellLots, basket.SellNotional, margin);
        }

        /// <summary>
        /// The uncovered-volume margin of a BUY/SELL inventory given as lots and entry-price
        /// notionals (sum of entry price times lots per side), the same aggregates the basket
        /// maintains. Exposed for the projected post-fill calculation and for tests.
        /// </summary>
        public static decimal UsedMargin(decimal buyLots, decimal buyNotional, decimal sellLots, decimal sellNotional, MarginParameters margin)
        {
            if (margin == null) throw new ArgumentNullException(nameof(margin));
            var uncovered = Math.Abs(buyLots - sellLots);
            if (uncovered == 0m)
            {
                return 0m;
            }
            var weightedAverageOpenPrice = buyLots > sellLots ? buyNotional / buyLots : sellNotional / sellLots;
            return uncovered * margin.ContractSize * weightedAverageOpenPrice / margin.Leverage;
        }

        /// <summary>
        /// Used margin of the complete projected post-fill inventory: the basket's current BUY/SELL
        /// lots and notionals plus the candidate leg at its projected execution price. This is the
        /// approved PR 3 projection; it must not be replaced by an isolated candidate-lot margin.
        /// </summary>
        public static decimal ProjectedUsedMargin(Basket basket, TradeSide side, decimal lots, decimal entryPrice, MarginParameters margin)
        {
            if (basket == null) throw new ArgumentNullException(nameof(basket));
            if (margin == null) throw new ArgumentNullException(nameof(margin));
            var buyLots = basket.BuyLots;
            var buyNotional = basket.BuyNotional;
            var sellLots = basket.SellLots;
            var sellNotional = basket.SellNotional;
            if (side == TradeSide.Buy)
            {
                buyLots += lots;
                buyNotional += lots * entryPrice;
            }
            else
            {
                sellLots += lots;
                sellNotional += lots * entryPrice;
            }
            return UsedMargin(buyLots, buyNotional, sellLots, sellNotional, margin);
        }

        /// <summary>
        /// Margin Level in percent: equity / used margin * 100. Null when the used margin is zero,
        /// because the ratio is then undefined; PR 3 must not manufacture an infinite or
        /// arbitrarily safe level for a fully hedged or flat account (the explicit negative-equity
        /// stop-out rule covers that edge case instead).
        /// </summary>
        public static decimal? MarginLevelPercent(decimal equity, decimal usedMargin)
        {
            return usedMargin > 0m ? equity / usedMargin * 100m : (decimal?)null;
        }
    }

    /// <summary>How the research account judged a candidate entry against the PR 3 margin rules.</summary>
    public enum MarginEntryDecision
    {
        /// <summary>The account can finance the projected post-fill account; the order may be placed.</summary>
        Allowed,

        /// <summary>The account is at or below the Margin Call Level; no new position may be opened.</summary>
        MarginCall,

        /// <summary>The projected post-fill used margin exceeds the account equity, so the candidate cannot be financed.</summary>
        InsufficientMargin
    }

    /// <summary>
    /// One candidate-entry margin assessment. The current values describe the account state of the
    /// quote the candidate was decided on; the projected values describe the complete post-fill
    /// inventory and are null when the Margin Call block stopped the assessment before any
    /// projection (the approved order evaluates the block first).
    /// </summary>
    public readonly record struct MarginEntryAssessment(
        MarginEntryDecision Decision,
        decimal CurrentUsedMargin,
        decimal? CurrentFreeMargin,
        decimal? CurrentMarginLevelPercent,
        decimal? ProjectedUsedMargin,
        decimal? ProjectedFreeMargin);

    /// <summary>Why terminal stop-out was reached.</summary>
    public enum StopOutReason
    {
        /// <summary>The margin level reached the stop-out threshold (at or below it).</summary>
        MarginLevel,

        /// <summary>
        /// The account has open positions and entered negative equity with no defined margin level
        /// (fully matched hedge, zero used margin). A zero-margin state must not look infinitely
        /// safe.
        /// </summary>
        NegativeEquity
    }

    /// <summary>
    /// The terminal survival failure state: the intact SingleAnchor path did not survive and the
    /// research run stops. This is not a simulated broker liquidation: no ticket was closed and no
    /// post-stop-out behaviour is invented. The values are the account state observed on the quote
    /// that tripped the stop-out.
    /// </summary>
    public sealed record MarginStopOut(
        StopOutReason Reason,
        DateTime Time,
        decimal Balance,
        decimal FloatingProfit,
        decimal Equity,
        decimal UsedMargin,
        decimal FreeMargin,
        decimal? MarginLevelPercent,
        int OpenPositions);

    /// <summary>
    /// The run-level PR 3 account-survival evidence written next to the PR 2 research account
    /// block. The current values are the last observed account state; the extrema are run maxima
    /// and minima. <see cref="MaxUsedMargin"/> needs no price and is exact; the free-margin and
    /// margin-level extrema come from the same executable observations as the floating mark, so
    /// when <c>researchAccount.floatingObservationsSkipped</c> is non-zero a skipped mark can have
    /// been an unseen extreme and the true run minimum may be more extreme than reported.
    /// <see cref="StopOut"/> is null when the account survived the run.
    /// </summary>
    public sealed record ResearchMarginSummary(
        MarginParameters Parameters,
        decimal CurrentUsedMargin,
        decimal? CurrentFreeMargin,
        decimal? CurrentMarginLevelPercent,
        decimal MaxUsedMargin,
        decimal? MinFreeMargin,
        decimal? MinMarginLevelPercent,
        bool MarginCallActive,
        long MarginCallObservations,
        long MarginCallEpisodes,
        long MarginCallBlockedAttempts,
        long MarginCallBlockedEpisodes,
        long InsufficientMarginAttempts,
        long InsufficientMarginEpisodes,
        MarginStopOut? StopOut);
}
