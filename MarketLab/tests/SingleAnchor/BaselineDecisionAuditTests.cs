using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using NUnit.Framework;
using QuantConnect;
using QuantConnect.Configuration;
using QuantConnect.Parameters;

namespace MarketLab.SingleAnchor.Tests
{
    /// <summary>
    /// Windows-local consistency check for the resolved baseline configuration freeze audit
    /// (MarketLab\BASELINE_CONFIGURATION_FREEZE_AUDIT.md and MarketLab\config\baseline-decision-audit.json).
    ///
    /// The eight class-D decisions exposed by PR #14 were explicitly approved and the immutable
    /// baseline contract (MarketLab\config\baseline-contract.json) is the canonical run configuration;
    /// the register is the resolved decision record and must agree with the contract. These tests
    /// detect drift between the audit, the contract, the live implementation defaults, the frozen
    /// margin contract and the tracked PR 13 continuous-history evidence. They do not run a strategy
    /// backtest, do not re-verify the machine-local data tree and do not judge whether a cited source
    /// authorizes a value; that remains human review. Re-opening a decision or adding a required field
    /// is always a deliberate edit of the audit, this required-field list and the register together.
    /// </summary>
    [TestFixture]
    [NonParallelizable]
    public class BaselineDecisionAuditTests
    {
        private static readonly string[] RequiredFields =
        {
            "symbol",
            "market",
            "securityType",
            "dataFolder",
            "startDate",
            "endDate",
            "dataResolution",
            "fillForward",
            "dataTimeZone",
            "exchangeTimeZone",
            "sessionMapPath",
            "sessionMapSha256",
            "marketHoursDatabaseSha256",
            "symbolPropertiesDatabaseSha256",
            "continuousHistorySemanticDigest",
            "continuousHistoryMonthCount",
            "continuousHistoryPartitionCount",
            "continuousHistoryQuoteCount",
            "continuousHistoryFirstQuoteUtc",
            "continuousHistoryLastQuoteUtc",
            "sourceFileSetSha256",
            "orderedMonthDigestChainSha256",
            "leanBacktestingConfig",
            "leanBacktestingConfigSha256",
            "algorithmTypeName",
            "algorithmLanguage",
            "buildConfiguration",
            "algorithmLocation",
            "allowEngineErrors",
            "tradingAvailabilityBufferMinutes",
            "normalTradeCount",
            "hardBreakevenCeilingPercent",
            "minimumVolume",
            "volumeStep",
            "maximumVolume",
            "escapeEnabled",
            "escapeProfitUnits",
            "escapeMinimumOpenPositions",
            "fixedTakeProfitUnits",
            "trailingEnabled",
            "trailingActivationUnits",
            "trailingDropUnits",
            "commissionPerLot",
            "pointValuePerLot",
            "buySwapPerLotPerDay",
            "sellSwapPerLotPerDay",
            "researchAccountEnabled",
            "researchAccountCurrency",
            "contractSize",
            "leverage",
            "initialMarginRate",
            "maintenanceMarginRate",
            "matchedHedgeMarginRule",
            "uncoveredVolumeMarginRule",
            "marginCallThresholdPercent",
            "stopOutThresholdPercent",
            "negativeEquityHandling",
            "stepPercent",
            "baseLot",
            "projectedSpread",
            "slippage",
            "commissionBuffer",
            "initialBalance",
            "marginEnabled",
            "helperFailedDataRequestPolicy"
        };

        /// <summary>
        /// The eight decisions PR #14 recorded as class D and the freeze resolved: they must still be
        /// identifiable as the former blockers, now class A with the approved decision recorded.
        /// </summary>
        private static readonly string[] FormerUnresolvedFields =
        {
            "stepPercent",
            "baseLot",
            "projectedSpread",
            "slippage",
            "commissionBuffer",
            "initialBalance",
            "marginEnabled",
            "helperFailedDataRequestPolicy"
        };

        /// <summary>
        /// The approved values of the eight former class-D decisions, keyed by register field. These
        /// are the frozen baseline decisions; the contract check re-verifies them from the canonical
        /// contract and this pin keeps either file from drifting silently.
        /// </summary>
        private static readonly Dictionary<string, object> ResolvedBaselineValues = new Dictionary<string, object>(StringComparer.Ordinal)
        {
            ["stepPercent"] = 0.25m,
            ["baseLot"] = 0.10m,
            ["projectedSpread"] = 0.50m,
            ["slippage"] = 0m,
            ["commissionBuffer"] = 0m,
            ["initialBalance"] = 20000m,
            ["marginEnabled"] = true,
            ["helperFailedDataRequestPolicy"] = true
        };

        /// <summary>
        /// Register values whose authority is an approved baseline decision rather than the
        /// fixture/default that happens to use the same number; the register must say so explicitly.
        /// </summary>
        private static readonly string[] DecisionAuthorisedFields =
        {
            "stepPercent",
            "baseLot",
            "projectedSpread",
            "slippage",
            "commissionBuffer",
            "initialBalance",
            "marginEnabled",
            "helperFailedDataRequestPolicy"
        };

        /// <summary>
        /// The host [Parameter] field defaults at the audit base revision: the raw field initializers
        /// of SingleAnchorVNextAlgorithm. They are fixture/implementation values, not baseline
        /// decisions. Pinning them here means a silent host-default change can no longer leave the
        /// audit's and the register's class B/D records stale.
        /// </summary>
        private static readonly Dictionary<string, object> HostParameterDefaults = new Dictionary<string, object>(StringComparer.Ordinal)
        {
            ["single-anchor-symbol"] = "XAUUSD",
            ["single-anchor-market"] = "oanda",
            ["single-anchor-security-type"] = "Cfd",
            ["single-anchor-start-date"] = "2014-05-02",
            ["single-anchor-end-date"] = "2014-05-14",
            ["single-anchor-cash"] = 100000m,
            ["single-anchor-session-map"] = "",
            ["single-anchor-step-percent"] = 0m,
            ["single-anchor-base-lot"] = 0m,
            ["single-anchor-normal-trade-count"] = 4,
            ["single-anchor-hard-be-ceiling-percent"] = 4.478m,
            ["single-anchor-escape-enabled"] = true,
            ["single-anchor-escape-profit-units"] = 0.05m,
            ["single-anchor-escape-minimum-open-positions"] = 2,
            ["single-anchor-fixed-tp-units"] = 0m,
            ["single-anchor-trailing-enabled"] = true,
            ["single-anchor-trailing-activation-units"] = 0.50m,
            ["single-anchor-trailing-drop-units"] = 0.25m,
            ["single-anchor-commission-buffer"] = 0m,
            ["single-anchor-point-value-per-lot"] = "",
            ["single-anchor-volume-step"] = 0.01m,
            ["single-anchor-minimum-volume"] = 0.01m,
            ["single-anchor-maximum-volume"] = 100m,
            ["single-anchor-commission-per-lot"] = 0m,
            ["single-anchor-slippage"] = 0m,
            ["single-anchor-projected-spread"] = "",
            ["single-anchor-buy-swap-per-lot-per-day"] = 0m,
            ["single-anchor-sell-swap-per-lot-per-day"] = 0m,
            ["single-anchor-research-account"] = true,
            ["single-anchor-margin-enabled"] = false
        };

        /// <summary>
        /// The approved baseline deliberately overrides these host defaults (qualified identity and
        /// period, the required session map, the approved step/base lot, the research-account balance,
        /// the approved broker volume maximum, the host-supplied point value, the target spread that
        /// has no host default, and margin enablement); every other class A/B value must equal its
        /// host default, and the baseline still passes it explicitly rather than relying on it.
        /// </summary>
        private static readonly HashSet<string> OverridesHostDefault = new HashSet<string>(StringComparer.Ordinal)
        {
            "single-anchor-market",
            "single-anchor-start-date",
            "single-anchor-end-date",
            "single-anchor-session-map",
            "single-anchor-step-percent",
            "single-anchor-base-lot",
            "single-anchor-cash",
            "single-anchor-maximum-volume",
            "single-anchor-point-value-per-lot",
            "single-anchor-projected-spread",
            "single-anchor-margin-enabled"
        };

        /// <summary>
        /// The run-backtest.ps1 parameters that can affect the authoritative baseline, mapped to the
        /// register field that inventories them. The Parameters channel carries the inventoried
        /// single-anchor-* fields and is checked separately.
        /// </summary>
        private static readonly Dictionary<string, string> BaselineHelperInputs = new Dictionary<string, string>(StringComparer.Ordinal)
        {
            ["Configuration"] = "buildConfiguration",
            ["Config"] = "leanBacktestingConfig",
            ["AlgorithmTypeName"] = "algorithmTypeName",
            ["AlgorithmLanguage"] = "algorithmLanguage",
            ["AlgorithmLocation"] = "algorithmLocation",
            ["DataFolder"] = "dataFolder",
            ["AllowMissingData"] = "helperFailedDataRequestPolicy",
            ["AllowEngineErrors"] = "allowEngineErrors"
        };

        /// <summary>
        /// Helper parameters that are run mechanics or unrelated to the C# authoritative baseline.
        /// A new helper parameter fails the classification test until it is deliberately handled.
        /// </summary>
        private static readonly string[] MechanicalHelperParameters =
        {
            "LeanRoot",
            "PythonDll",
            "OutputRoot",
            "DryRun"
        };

        [Test]
        public void TheAuditRecordsTheResolvedFreezeAndBindsTheContract()
        {
            using var audit = ReadAudit();
            var root = audit.RootElement;

            Assert.That(root.GetProperty("contract").GetString(), Is.EqualTo("marketlab-baseline-decision-audit-v1"));
            Assert.That(root.GetProperty("status").GetString(), Is.EqualTo("resolved"));
            Assert.That(root.GetProperty("baselineConfigurationFrozen").GetBoolean(), Is.True);

            var unresolved = Fields(root).Values.Count(field => ClassOf(field) == "D");
            Assert.That(root.GetProperty("unresolvedDecisionCount").GetInt32(), Is.EqualTo(unresolved));
            Assert.That(
                root.GetProperty("baselineConfigurationFrozen").GetBoolean(),
                Is.EqualTo(unresolved == 0),
                "the frozen flag must be the exact complement of the unresolved decisions");
            Assert.That(unresolved, Is.Zero, "every former class-D decision must be resolved");

            Assert.That(root.GetProperty("frozenBaselineContract").GetString(), Is.EqualTo("config/baseline-contract.json"));
            var recordedContractSha = root.GetProperty("frozenBaselineContractSha256").GetString();
            Assert.That(
                recordedContractSha,
                Is.EqualTo(Sha256LfNormalized(Path.Combine(FindMarketLabRoot(), "config", "baseline-contract.json"))),
                "the register must pin the LF-normalized hash of the canonical baseline contract");
        }

        [Test]
        public void EveryRequiredBaselineFieldIsInventoriedExactlyOnce()
        {
            using var audit = ReadAudit();
            var fields = Fields(audit.RootElement);

            Assert.That(
                fields.Keys,
                Is.EquivalentTo(RequiredFields),
                "the audit must inventory every baseline-relevant field and nothing else (new fields must be added deliberately)");
            Assert.That(fields.Count, Is.EqualTo(RequiredFields.Length));
        }

        [Test]
        public void ApprovedAndDefaultEntriesAreValuedAndSourced()
        {
            using var audit = ReadAudit();
            foreach (var field in Fields(audit.RootElement).Values)
            {
                var id = field.GetProperty("field").GetString();
                var classification = ClassOf(field);
                Assert.That(classification, Is.AnyOf("A", "B"), $"field '{id}' has an unknown or re-opened class");
                Assert.That(
                    field.GetProperty("value").ValueKind,
                    Is.Not.EqualTo(JsonValueKind.Null),
                    $"approved/default field '{id}' must carry its value");
                RequiredText(field, "source");
            }
        }

        [Test]
        public void ResolvedFormerDecisionsCarryTheApprovedDecisionAndPreservedHistory()
        {
            using var audit = ReadAudit();
            var fields = Fields(audit.RootElement);
            var former = fields.Values.Where(field => field.TryGetProperty("wasClassD", out var flag) && flag.GetBoolean()).ToList();
            Assert.That(former, Is.Not.Empty, "the resolved decisions must remain identifiable as the former blockers");

            foreach (var field in former)
            {
                var id = field.GetProperty("field").GetString();
                Assert.That(ClassOf(field), Is.EqualTo("A"), $"former blocker '{id}' must be explicitly approved (class A)");
                RequiredText(field, "approvedDecision");
                RequiredText(field, "authority");
                RequiredText(field, "whyRequired");
                RequiredText(field, "currentCodeDefault");
                RequiredText(field, "notAuthoritativeBecause");
                Assert.That(
                    field.GetProperty("fixtureExampleValues").ValueKind,
                    Is.EqualTo(JsonValueKind.Array),
                    $"field '{id}' must preserve the audit-time fixture/example context");
                Assert.That(field.GetProperty("fixtureExampleValues").GetArrayLength(), Is.GreaterThan(0), $"field '{id}'");
                foreach (var example in field.GetProperty("fixtureExampleValues").EnumerateArray())
                {
                    Assert.That(example.ValueKind, Is.EqualTo(JsonValueKind.String));
                    Assert.That(string.IsNullOrWhiteSpace(example.GetString()), Is.False, $"field '{id}' has an empty example value");
                }

                Assert.That(ResolvedBaselineValues.TryGetValue(id!, out var expected), Is.True, $"field '{id}' is not pinned in this check");
                var value = field.GetProperty("value");
                object? actual = value.ValueKind switch
                {
                    JsonValueKind.True => true,
                    JsonValueKind.False => false,
                    JsonValueKind.Number => value.GetDecimal(),
                    _ => throw new AssertionException($"field '{id}' has unexpected value kind {value.ValueKind}")
                };
                Assert.That(actual, Is.EqualTo(expected), $"the approved value of '{id}' changed unexpectedly");
            }
        }

        [Test]
        public void TheFormerBlockersAreExactlyTheOnesResolved()
        {
            using var audit = ReadAudit();
            var reported = Fields(audit.RootElement).Values
                .Where(field => field.TryGetProperty("wasClassD", out var flag) && flag.GetBoolean())
                .Select(field => field.GetProperty("field").GetString())
                .OrderBy(id => id, StringComparer.Ordinal)
                .ToArray();

            Assert.That(
                reported,
                Is.EqualTo(FormerUnresolvedFields.OrderBy(id => id, StringComparer.Ordinal).ToArray()),
                "re-opening or adding a baseline decision must be a deliberate change of this audit and its check");
        }

        [Test]
        public void DecisionAuthorisedValuesStateThatTheApprovedDecisionIsTheAuthority()
        {
            using var audit = ReadAudit();
            var fields = Fields(audit.RootElement);
            foreach (var id in DecisionAuthorisedFields)
            {
                var authority = RequiredText(fields[id], "authority");
                Assert.That(
                    authority,
                    Does.Contain("approved").IgnoreCase,
                    $"field '{id}' must state that its authority is the approved decision, not a fixture/default");
            }
        }

        [Test]
        public void DataIdentityMatchesTheTrackedContinuousHistoryEvidence()
        {
            using var audit = ReadAudit();
            using var evidence = ReadEvidence();
            var fields = Fields(audit.RootElement);
            var composition = evidence.RootElement.GetProperty("composition");
            var totals = composition.GetProperty("totals");
            var replay = evidence.RootElement.GetProperty("replay");
            var retirement = evidence.RootElement.GetProperty("retirement");

            Assert.That(RequiredText(fields["dataFolder"], "value"), Is.EqualTo(composition.GetProperty("data_folder").GetString()));
            Assert.That(RequiredText(fields["startDate"], "value"), Is.EqualTo(composition.GetProperty("lean_run_window").GetProperty("start_date").GetString()));
            Assert.That(RequiredText(fields["endDate"], "value"), Is.EqualTo(composition.GetProperty("lean_run_window").GetProperty("end_date").GetString()));
            Assert.That(RequiredText(fields["sessionMapPath"], "value"), Is.EqualTo(composition.GetProperty("session_map_relative_path").GetString()));
            Assert.That(RequiredText(fields["sessionMapSha256"], "value"), Is.EqualTo(composition.GetProperty("session_map_sha256").GetString()));
            Assert.That(RequiredText(fields["marketHoursDatabaseSha256"], "value"), Is.EqualTo(composition.GetProperty("market_hours_database_sha256").GetString()));
            Assert.That(RequiredText(fields["symbolPropertiesDatabaseSha256"], "value"), Is.EqualTo(composition.GetProperty("symbol_properties_database_sha256").GetString()));
            Assert.That(RequiredText(fields["continuousHistorySemanticDigest"], "value"), Is.EqualTo(composition.GetProperty("ordered_source_semantic_digest").GetString()));
            Assert.That(RequiredDecimal(fields["continuousHistoryMonthCount"], "value"), Is.EqualTo((decimal)composition.GetProperty("month_count").GetInt32()));
            Assert.That(RequiredDecimal(fields["continuousHistoryPartitionCount"], "value"), Is.EqualTo((decimal)composition.GetProperty("partition_count").GetInt32()));
            Assert.That(RequiredDecimal(fields["continuousHistoryQuoteCount"], "value"), Is.EqualTo((decimal)totals.GetProperty("accepted_row_count").GetInt64()));
            Assert.That(RequiredText(fields["continuousHistoryFirstQuoteUtc"], "value"), Is.EqualTo(composition.GetProperty("first_canonical_utc").GetString()));
            Assert.That(RequiredText(fields["continuousHistoryLastQuoteUtc"], "value"), Is.EqualTo(composition.GetProperty("last_canonical_utc").GetString()));
            Assert.That(RequiredText(fields["sourceFileSetSha256"], "value"), Is.EqualTo(composition.GetProperty("source_file_set_sha256").GetString()));
            Assert.That(RequiredText(fields["orderedMonthDigestChainSha256"], "value"), Is.EqualTo(composition.GetProperty("ordered_month_digest_chain_sha256").GetString()));

            Assert.That(RequiredText(fields["dataResolution"], "value"), Is.EqualTo("Tick"));
            Assert.That(RequiredBool(fields["fillForward"], "value"), Is.False);
            Assert.That(RequiredText(fields["dataTimeZone"], "value"), Is.EqualTo("UTC"));
            Assert.That(RequiredText(fields["exchangeTimeZone"], "value"), Is.EqualTo("UTC"));
            Assert.That(RequiredDecimal(fields["tradingAvailabilityBufferMinutes"], "value"), Is.EqualTo(5m));
            Assert.That(RequiredText(fields["leanBacktestingConfig"], "value"), Is.EqualTo("MarketLab/config/backtesting.json"));
            Assert.That(
                RequiredText(fields["leanBacktestingConfigSha256"], "value"),
                Is.EqualTo(Sha256LfNormalized(Path.Combine(FindMarketLabRoot(), "config", "backtesting.json"))),
                "the qualified backtesting configuration content must still match the audit hash");
            Assert.That(RequiredText(fields["algorithmTypeName"], "value"), Is.EqualTo("SingleAnchorVNextAlgorithm"));
            Assert.That(RequiredText(fields["algorithmLanguage"], "value"), Is.EqualTo("CSharp"));
            Assert.That(RequiredText(fields["buildConfiguration"], "value"), Is.EqualTo("Release"));
            Assert.That(
                RequiredText(fields["algorithmLocation"], "value"),
                Is.EqualTo(@"MarketLab\src\SingleAnchor\bin\Release\MarketLab.SingleAnchor.dll"),
                "the authoritative run must name the SingleAnchor assembly, not the helper's upstream default");
            Assert.That(RequiredBool(fields["allowEngineErrors"], "value"), Is.False, "the authoritative run must not suppress engine errors");

            Assert.That(replay.GetProperty("overall_qualification").GetString(), Is.EqualTo("PASS"));
            Assert.That(replay.GetProperty("probe_qualification").GetString(), Is.EqualTo("PASS"));
            Assert.That(replay.GetProperty("helper_exit_code").GetInt32(), Is.EqualTo(0));
            Assert.That(replay.GetProperty("missing_native_partitions").GetInt32(), Is.EqualTo(0));
            Assert.That(replay.GetProperty("source_coverage_gap_days").GetInt32(), Is.EqualTo(0));
            // The factual basis of the approved helper failed-data-request policy (audit section 10.8):
            // every failed request is a calendar day the always-open identity requests that carries no
            // source rows, plus the unrelated missing benchmark hour file.
            Assert.That(replay.GetProperty("native_partition_failed_data_requests").GetInt32(), Is.EqualTo(406));
            Assert.That(replay.GetProperty("source_absent_days").GetInt32(), Is.EqualTo(406));
            Assert.That(replay.GetProperty("unrelated_failed_data_requests").GetInt32(), Is.EqualTo(1));
            Assert.That(replay.GetProperty("out_of_window_failed_data_requests").GetInt32(), Is.EqualTo(0));
            Assert.That(totals.GetProperty("rejected_row_count").GetInt64(), Is.EqualTo(0L));
            Assert.That(totals.GetProperty("first_canonical_utc").GetString(), Is.EqualTo(composition.GetProperty("first_canonical_utc").GetString()));
            Assert.That(totals.GetProperty("last_canonical_utc").GetString(), Is.EqualTo(composition.GetProperty("last_canonical_utc").GetString()));
            Assert.That(totals.GetProperty("raw_row_count").GetInt64(), Is.EqualTo(totals.GetProperty("accepted_row_count").GetInt64()));
            Assert.That(totals.GetProperty("converted_row_count").GetInt64(), Is.EqualTo(totals.GetProperty("accepted_row_count").GetInt64()));
            Assert.That(replay.GetProperty("lean_delivered_row_count").GetInt64(), Is.EqualTo(totals.GetProperty("accepted_row_count").GetInt64()));
            Assert.That(replay.GetProperty("probe_processed_row_count").GetInt64(), Is.EqualTo(totals.GetProperty("accepted_row_count").GetInt64()));
            Assert.That(retirement.GetProperty("continuous_is_single_complete_native_representation").GetBoolean(), Is.True);

            var identity = evidence.RootElement.GetProperty("identity").GetString();
            Assert.That(identity, Does.Contain("XAUUSD/dukascopy/Cfd"));
            Assert.That(identity, Does.Contain("UTC/UTC"));
        }

        [Test]
        public void ApprovedValuesMatchTheImplementationContract()
        {
            using var audit = ReadAudit();
            var fields = Fields(audit.RootElement);
            var parameters = new SingleAnchorParameters();
            var margin = new MarginParameters();

            Assert.That(RequiredDecimal(fields["normalTradeCount"], "value"), Is.EqualTo((decimal)parameters.NormalTradeCount));
            Assert.That(RequiredDecimal(fields["hardBreakevenCeilingPercent"], "value"), Is.EqualTo(parameters.HardBreakevenCeilingPercent));
            Assert.That(RequiredBool(fields["escapeEnabled"], "value"), Is.EqualTo(parameters.EscapeEnabled));
            Assert.That(RequiredDecimal(fields["escapeProfitUnits"], "value"), Is.EqualTo(parameters.EscapeProfitUnits));
            Assert.That(RequiredDecimal(fields["escapeMinimumOpenPositions"], "value"), Is.EqualTo((decimal)parameters.EscapeMinimumOpenPositions));
            Assert.That(RequiredDecimal(fields["fixedTakeProfitUnits"], "value"), Is.EqualTo(parameters.FixedTakeProfitUnits));
            Assert.That(RequiredBool(fields["trailingEnabled"], "value"), Is.EqualTo(parameters.TrailingEnabled));
            Assert.That(RequiredDecimal(fields["trailingActivationUnits"], "value"), Is.EqualTo(parameters.TrailingActivationUnits));
            Assert.That(RequiredDecimal(fields["trailingDropUnits"], "value"), Is.EqualTo(parameters.TrailingDropUnits));
            Assert.That(RequiredDecimal(fields["minimumVolume"], "value"), Is.EqualTo(parameters.MinimumVolume));
            Assert.That(RequiredDecimal(fields["volumeStep"], "value"), Is.EqualTo(parameters.VolumeStep));
            Assert.That(RequiredDecimal(fields["commissionPerLot"], "value"), Is.EqualTo(parameters.CommissionPerLot));
            Assert.That(RequiredDecimal(fields["buySwapPerLotPerDay"], "value"), Is.EqualTo(parameters.BuySwapPerLotPerDay));
            Assert.That(RequiredDecimal(fields["sellSwapPerLotPerDay"], "value"), Is.EqualTo(parameters.SellSwapPerLotPerDay));

            Assert.That(RequiredDecimal(fields["maximumVolume"], "value"), Is.EqualTo(50m));
            Assert.That(
                parameters.MaximumVolume,
                Is.EqualTo(100m),
                "the engine's unrelated global default stays 100; the approved broker profile 50 must be passed explicitly");
            Assert.That(RequiredDecimal(fields["pointValuePerLot"], "value"), Is.EqualTo(100m));
            Assert.That(SingleAnchorVNextAlgorithm.MarginHostContractError("XAUUSD", "Cfd", 100m), Is.Null);
            Assert.That(SingleAnchorVNextAlgorithm.MarginHostContractError("XAUUSD", "Cfd", 50m), Is.Not.Null);

            Assert.That(RequiredDecimal(fields["contractSize"], "value"), Is.EqualTo(margin.ContractSize));
            Assert.That(RequiredDecimal(fields["leverage"], "value"), Is.EqualTo(margin.Leverage));
            Assert.That(RequiredDecimal(fields["marginCallThresholdPercent"], "value"), Is.EqualTo(margin.MarginCallLevelPercent));
            Assert.That(RequiredDecimal(fields["stopOutThresholdPercent"], "value"), Is.EqualTo(margin.StopOutLevelPercent));
            Assert.That(RequiredDecimal(fields["initialMarginRate"], "value"), Is.EqualTo(1.0m));
            Assert.That(RequiredDecimal(fields["maintenanceMarginRate"], "value"), Is.EqualTo(1.0m));
            Assert.That(RequiredText(fields["researchAccountCurrency"], "value"), Is.EqualTo("USD"));
            Assert.That(RequiredBool(fields["researchAccountEnabled"], "value"), Is.True);

            // The approved decisions that have no host default, or whose value deliberately overrides
            // a host default: the register must carry the approved value, not the host/fixture one.
            Assert.That(new SingleAnchorParameters().StepPercent, Is.EqualTo(0m), "the host has no approved step default; the contract must supply it");
            Assert.That(new SingleAnchorParameters().BaseLot, Is.EqualTo(0m), "the host has no approved base-lot default; the contract must supply it");
            Assert.That(new SingleAnchorParameters().ProjectedSpread, Is.Null, "the target spread has no host default; the contract must supply it");
            Assert.That(new SingleAnchorParameters().Slippage, Is.EqualTo(0m));
            Assert.That(new SingleAnchorParameters().CommissionBuffer, Is.EqualTo(0m));
            Assert.That(RequiredDecimal(fields["stepPercent"], "value"), Is.EqualTo(0.25m));
            Assert.That(RequiredDecimal(fields["baseLot"], "value"), Is.EqualTo(0.10m));
            Assert.That(RequiredDecimal(fields["projectedSpread"], "value"), Is.EqualTo(0.50m));
            Assert.That(RequiredDecimal(fields["slippage"], "value"), Is.EqualTo(0m));
            Assert.That(RequiredDecimal(fields["commissionBuffer"], "value"), Is.EqualTo(0m));
            Assert.That(RequiredDecimal(fields["initialBalance"], "value"), Is.EqualTo(20000m));
            Assert.That(RequiredBool(fields["marginEnabled"], "value"), Is.True);
            Assert.That(RequiredBool(fields["helperFailedDataRequestPolicy"], "value"), Is.True);
        }

        [Test]
        public void HostParametersAndTheirDefaultsArePinnedAndInventoried()
        {
            using var audit = ReadAudit();
            var fields = Fields(audit.RootElement);

            // LEAN's own discovery: fields and properties, public/non-public/static/instance, with the
            // member name used when the attribute carries no name (ParameterAttribute.ApplyAttributes).
            var hostMembers = typeof(SingleAnchorVNextAlgorithm)
                .GetFields(ParameterAttribute.BindingFlags)
                .Cast<MemberInfo>()
                .Concat(typeof(SingleAnchorVNextAlgorithm).GetProperties(ParameterAttribute.BindingFlags))
                .Select(member => (Member: member, Attribute: member.GetCustomAttribute<ParameterAttribute>()))
                .Where(entry => entry.Attribute != null)
                .ToDictionary(
                    entry => entry.Attribute!.Name ?? entry.Member.Name,
                    entry => entry.Member,
                    StringComparer.Ordinal);

            var inventoried = fields.Values
                .Select(RunParameterOf)
                .Where(name => name != null && name!.StartsWith("single-anchor-", StringComparison.Ordinal))
                .ToHashSet(StringComparer.Ordinal);

            Assert.That(
                inventoried,
                Is.EquivalentTo(hostMembers.Keys),
                "every host [Parameter] must be inventoried in the audit register, and every inventoried single-anchor parameter must exist on the host");
            Assert.That(hostMembers.Count, Is.EqualTo(HostParameterDefaults.Count));

            // Constructing the LEAN algorithm loads the market-hours and symbol-properties databases
            // through Globals.DataFolder (the upstream Data fixture), and the field initializers carry
            // the host parameter defaults. Restore the previous data folder afterwards.
            var previousDataFolder = Config.Get("data-folder", "../../../Data/");
            Config.Set("data-folder", Path.GetFullPath(Path.Combine(FindMarketLabRoot(), "..", "Data")));
            Globals.Reset();
            SingleAnchorVNextAlgorithm host;
            try
            {
                host = new SingleAnchorVNextAlgorithm();
            }
            finally
            {
                Config.Set("data-folder", previousDataFolder);
                Globals.Reset();
            }

            foreach (var entry in hostMembers)
            {
                var field = fields.Values.SingleOrDefault(candidate => RunParameterOf(candidate) == entry.Key);
                Assert.That(field.ValueKind, Is.Not.EqualTo(JsonValueKind.Undefined), $"host parameter '{entry.Key}' has no register field");
                Assert.That(HostParameterDefaults.TryGetValue(entry.Key, out var expected), Is.True, $"host parameter '{entry.Key}' is not pinned in the audit test");
                var hostDefault = entry.Value is FieldInfo fieldInfo
                    ? fieldInfo.GetValue(host)
                    : ((PropertyInfo)entry.Value).GetValue(host);
                Assert.That(
                    hostDefault,
                    Is.EqualTo(expected),
                    $"host parameter '{entry.Key}' default changed; the audit and the register must be revisited deliberately");
                var approved = ApprovedText(field);
                var defaultText = HostDefaultText(expected!);
                if (OverridesHostDefault.Contains(entry.Key))
                {
                    Assert.That(
                        approved,
                        Is.Not.EqualTo(defaultText),
                        $"field for '{entry.Key}' documents an override and must differ from the host default");
                }
                else
                {
                    Assert.That(
                        approved,
                        Is.EqualTo(defaultText),
                        $"field for '{entry.Key}' must equal its host default (the baseline passes the specified default explicitly)");
                }
            }
        }

        [Test]
        public void HelperRunInputsAreClassifiedAndInventoried()
        {
            using var audit = ReadAudit();
            var fields = Fields(audit.RootElement);
            var script = File.ReadAllText(Path.Combine(FindMarketLabRoot(), "scripts", "run-backtest.ps1"));
            var paramBlock = Regex.Match(script, @"param\(([\s\S]*?)\n\)");
            Assert.That(paramBlock.Success, Is.True, "run-backtest.ps1 param block was not found");

            var declared = Regex.Matches(paramBlock.Groups[1].Value, @"\$(\w+)")
                .Select(match => match.Groups[1].Value)
                .ToArray();
            var expected = BaselineHelperInputs.Keys.Concat(MechanicalHelperParameters).Append("Parameters").ToArray();
            Assert.That(
                declared,
                Is.EquivalentTo(expected),
                "every run-backtest.ps1 parameter must be classified as a baseline input, the parameter channel or run mechanics");

            foreach (var entry in BaselineHelperInputs)
            {
                Assert.That(fields.ContainsKey(entry.Value), Is.True, $"-{entry.Key} must be inventoried as field '{entry.Value}'");
            }
            Assert.That(
                fields.Values.Select(RunParameterOf).Any(name => name != null && name.StartsWith("single-anchor-", StringComparison.Ordinal)),
                Is.True,
                "-Parameters must carry the inventoried single-anchor fields");
        }

        [Test]
        public void FixtureAndExampleValuesAreInventoriedAndNotPromoted()
        {
            using var audit = ReadAudit();
            var fields = Fields(audit.RootElement);
            var fixtureValues = audit.RootElement.GetProperty("fixtureValues").EnumerateArray().ToList();
            Assert.That(fixtureValues, Is.Not.Empty);

            var keys = new HashSet<string>(StringComparer.Ordinal);
            foreach (var fixture in fixtureValues)
            {
                var owner = RequiredText(fixture, "field");
                Assert.That(fields.ContainsKey(owner), Is.True, $"fixture value owner '{owner}' is not a baseline field");
                var value = RequiredText(fixture, "value");
                RequiredText(fixture, "where");
                RequiredText(fixture, "whyNotAuthoritative");
                keys.Add(owner + "=" + value);

                var promoted = fixture.TryGetProperty("promotedByExplicitDecision", out var promotion)
                    && promotion.ValueKind == JsonValueKind.True;
                if (value == ApprovedText(fields[owner]))
                {
                    Assert.That(
                        promoted,
                        Is.True,
                        $"fixture value '{owner}={value}' equals the approved value and must be marked promotedByExplicitDecision with an authorityNote");
                }
                if (promoted)
                {
                    Assert.That(
                        RequiredText(fixture, "authorityNote"),
                        Is.Not.Empty,
                        $"fixture value '{owner}={value}' claims promotion and must explain that the approved decision is the authority");
                }
            }

            Assert.That(keys, Does.Contain("stepPercent=0.2"));
            Assert.That(keys, Does.Contain("baseLot=0.01"));
            Assert.That(keys, Does.Contain("projectedSpread=0.5"));
            Assert.That(keys, Does.Contain("initialBalance=100000"));
            Assert.That(keys, Does.Contain("initialBalance=1000000"));
            Assert.That(keys, Does.Contain("initialBalance=7"));
            Assert.That(keys, Does.Contain("initialBalance=12"));
        }

        private static string FindMarketLabRoot()
        {
            var candidate = new DirectoryInfo(TestContext.CurrentContext.TestDirectory);
            while (candidate != null)
            {
                if (File.Exists(Path.Combine(candidate.FullName, "SINGLE_ANCHOR_VNEXT_STRATEGY.md"))
                    && File.Exists(Path.Combine(candidate.FullName, "config", "baseline-decision-audit.json"))
                    && File.Exists(Path.Combine(candidate.FullName, "src", "SingleAnchor", "SingleAnchorParameters.cs")))
                {
                    return candidate.FullName;
                }
                candidate = candidate.Parent;
            }
            throw new InvalidOperationException(
                $"Could not locate the MarketLab directory above '{TestContext.CurrentContext.TestDirectory}'. "
                + "Run the tests from a checkout of the repository.");
        }

        private static JsonDocument ReadAudit()
        {
            return JsonDocument.Parse(File.ReadAllText(Path.Combine(FindMarketLabRoot(), "config", "baseline-decision-audit.json")));
        }

        private static JsonDocument ReadEvidence()
        {
            return JsonDocument.Parse(File.ReadAllText(Path.Combine(
                FindMarketLabRoot(), "tools", "historical-data", "fixtures", "continuous-history-evidence.json")));
        }

        private static Dictionary<string, JsonElement> Fields(JsonElement root)
        {
            var fields = new Dictionary<string, JsonElement>(StringComparer.Ordinal);
            foreach (var entry in root.GetProperty("fields").EnumerateArray())
            {
                var id = entry.GetProperty("field").GetString() ?? string.Empty;
                Assert.That(fields.ContainsKey(id), Is.False, $"duplicate baseline field '{id}' in the audit");
                fields[id] = entry;
            }
            return fields;
        }

        private static string Sha256LfNormalized(string path)
        {
            var text = File.ReadAllText(path).Replace("\r\n", "\n");
            using var sha = SHA256.Create();
            return Convert.ToHexString(sha.ComputeHash(Encoding.UTF8.GetBytes(text))).ToLowerInvariant();
        }

        private static string? RunParameterOf(JsonElement field)
        {
            return field.TryGetProperty("runParameter", out var parameter) && parameter.ValueKind == JsonValueKind.String
                ? parameter.GetString()
                : null;
        }

        private static string HostDefaultText(object value)
        {
            switch (value)
            {
                case string text:
                    return text;
                case bool boolean:
                    return boolean ? "true" : "false";
                case decimal number:
                    return number.ToString(CultureInfo.InvariantCulture);
                case int number:
                    return number.ToString(CultureInfo.InvariantCulture);
                default:
                    throw new AssertionException($"unexpected host default type {value.GetType().Name}");
            }
        }

        private static string ClassOf(JsonElement field)
        {
            return RequiredText(field, "class");
        }

        private static string RequiredText(JsonElement field, string name)
        {
            var id = field.GetProperty("field").GetString();
            Assert.That(field.TryGetProperty(name, out var value), Is.True, $"field '{id}' must carry '{name}'");
            Assert.That(value.ValueKind, Is.EqualTo(JsonValueKind.String), $"field '{id}': '{name}' must be a string");
            var text = value.GetString();
            Assert.That(string.IsNullOrWhiteSpace(text), Is.False, $"field '{id}': '{name}' must not be empty");
            return text ?? string.Empty;
        }

        private static decimal RequiredDecimal(JsonElement field, string name)
        {
            var id = field.GetProperty("field").GetString();
            Assert.That(field.TryGetProperty(name, out var value), Is.True, $"field '{id}' must carry '{name}'");
            Assert.That(value.ValueKind, Is.EqualTo(JsonValueKind.Number), $"field '{id}': '{name}' must be a number");
            return value.GetDecimal();
        }

        private static bool RequiredBool(JsonElement field, string name)
        {
            var id = field.GetProperty("field").GetString();
            Assert.That(field.TryGetProperty(name, out var value), Is.True, $"field '{id}' must carry '{name}'");
            Assert.That(value.ValueKind, Is.AnyOf(JsonValueKind.True, JsonValueKind.False), $"field '{id}': '{name}' must be a boolean");
            return value.GetBoolean();
        }

        private static string ApprovedText(JsonElement field)
        {
            var value = field.GetProperty("value");
            switch (value.ValueKind)
            {
                case JsonValueKind.String:
                    return value.GetString() ?? string.Empty;
                case JsonValueKind.Number:
                    return value.GetRawText();
                case JsonValueKind.True:
                    return "true";
                case JsonValueKind.False:
                    return "false";
                default:
                    throw new AssertionException(
                        $"field '{field.GetProperty("field").GetString()}' has a non-scalar approved value {value.ValueKind}");
            }
        }
    }
}
