using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using NUnit.Framework;
using QuantConnect.Parameters;

namespace MarketLab.SingleAnchor.Tests
{
    /// <summary>
    /// Windows-local checks for the frozen SingleAnchor baseline contract
    /// (MarketLab\config\baseline-contract.json, MarketLab\BASELINE_CONTRACT.md).
    ///
    /// The contract is the canonical, immutable reference configuration for the first untouched
    /// continuous full-history baseline. These tests verify that it is complete (every host
    /// [Parameter] is bound exactly once with an explicit value and authority), that its values are
    /// the approved baseline values, that its identity is stable and recorded in the decision register
    /// and the human-auditable contract, that it renders the exact future run invocation, that the
    /// host defaults cannot silently change the run, and that the qualified data identity, the PR 3
    /// margin contract and the approved failed-data policy are unchanged. They do not run a strategy
    /// backtest, re-verify the machine-local data tree, recompute the 413,750,130-row digest or judge
    /// whether a cited source authorizes a value (that remains human review).
    /// </summary>
    [TestFixture]
    [NonParallelizable]
    public class BaselineContractTests
    {
        /// <summary>
        /// The frozen parameter values, keyed by LEAN parameter name. This is the pinned, independent
        /// statement of the approved baseline; the contract must match it exactly.
        /// </summary>
        private static readonly Dictionary<string, string> FrozenParameterValues = new Dictionary<string, string>(StringComparer.Ordinal)
        {
            ["single-anchor-symbol"] = "XAUUSD",
            ["single-anchor-market"] = "dukascopy",
            ["single-anchor-security-type"] = "Cfd",
            ["single-anchor-start-date"] = "2019-01-01",
            ["single-anchor-end-date"] = "2026-06-30",
            ["single-anchor-cash"] = "20000",
            ["single-anchor-session-map"] = "marketlab-sessions/xauusd-sessions.json",
            ["single-anchor-step-percent"] = "0.25",
            ["single-anchor-base-lot"] = "0.10",
            ["single-anchor-normal-trade-count"] = "4",
            ["single-anchor-hard-be-ceiling-percent"] = "4.478",
            ["single-anchor-escape-enabled"] = "true",
            ["single-anchor-escape-profit-units"] = "0.05",
            ["single-anchor-escape-minimum-open-positions"] = "2",
            ["single-anchor-fixed-tp-units"] = "0",
            ["single-anchor-trailing-enabled"] = "true",
            ["single-anchor-trailing-activation-units"] = "0.50",
            ["single-anchor-trailing-drop-units"] = "0.25",
            ["single-anchor-commission-buffer"] = "0",
            ["single-anchor-point-value-per-lot"] = "100",
            ["single-anchor-volume-step"] = "0.01",
            ["single-anchor-minimum-volume"] = "0.01",
            ["single-anchor-maximum-volume"] = "50",
            ["single-anchor-commission-per-lot"] = "0",
            ["single-anchor-slippage"] = "0",
            ["single-anchor-projected-spread"] = "0.50",
            ["single-anchor-buy-swap-per-lot-per-day"] = "0",
            ["single-anchor-sell-swap-per-lot-per-day"] = "0",
            ["single-anchor-research-account"] = "true",
            ["single-anchor-margin-enabled"] = "true"
        };

        /// <summary>
        /// The deterministic host-declaration order the contract must keep, so the rendered
        /// `-Parameters` string and the documented invocation are byte-stable.
        /// </summary>
        private static readonly string[] HostParameterOrder = FrozenParameterValues.Keys.ToArray();

        private static readonly string[] ExpectedAuxiliaryPaths = { "cfd/dukascopy/hour/xauusd.zip" };

        [Test]
        public void TheContractIsTheFrozenImmutableBaselineConfiguration()
        {
            using var contract = ReadContract();
            var root = contract.RootElement;

            Assert.That(root.GetProperty("contract").GetString(), Is.EqualTo("marketlab-single-anchor-baseline-contract-v1"));
            Assert.That(root.GetProperty("status").GetString(), Is.EqualTo("frozen"));
            Assert.That(root.GetProperty("immutable").GetBoolean(), Is.True);
            Assert.That(RequiredText(root, "scope"), Does.Contain("first untouched"), "the contract must identify itself as the reference for the first untouched baseline");
            Assert.That(RequiredText(root, "canonicalization"), Does.Contain("SHA-256"), "the contract identity canonicalization must be documented");
            Assert.That(root.TryGetProperty("runProcedure", out _), Is.True);
            Assert.That(root.TryGetProperty("relationshipToLaterResearch", out _), Is.True);

            var later = root.GetProperty("relationshipToLaterResearch");
            Assert.That(RequiredText(later, "laterConfigurations"), Does.Contain("never rewrite").IgnoreCase);
        }

        [Test]
        public void EveryHostParameterIsBoundExactlyOnceWithAnExplicitValueAndAuthority()
        {
            using var contract = ReadContract();
            var hostMembers = HostParameterNames();
            var parameters = ContractParameters(contract.RootElement);

            Assert.That(
                parameters.Keys,
                Is.EquivalentTo(hostMembers),
                "every host [Parameter] must be bound by the contract and every contract parameter must exist on the host");
            Assert.That(parameters.Count, Is.EqualTo(hostMembers.Length), "the contract must bind each host parameter exactly once");

            foreach (var entry in parameters)
            {
                Assert.That(entry.Key, Does.Match("^single-anchor-[a-z0-9-]+$"), $"'{entry.Key}' is not a single-anchor-* parameter");
                Assert.That(RequiredText(entry.Value, "value"), Is.Not.Empty, $"parameter '{entry.Key}' must carry an explicit value");
                Assert.That(RequiredText(entry.Value, "authority"), Is.Not.Empty, $"parameter '{entry.Key}' must carry its authority");
            }
        }

        [Test]
        public void FrozenValuesAndTheirOrderMatchTheApprovedBaseline()
        {
            using var contract = ReadContract();
            var parameters = ContractParameters(contract.RootElement);

            Assert.That(
                parameters.Keys.ToArray(),
                Is.EqualTo(HostParameterOrder),
                "the contract parameter order is part of the deterministic rendering; reordering is a deliberate change");
            foreach (var name in HostParameterOrder)
            {
                Assert.That(
                    RequiredText(parameters[name], "value"),
                    Is.EqualTo(FrozenParameterValues[name]),
                    $"the frozen baseline value of '{name}' changed unexpectedly");
            }
        }

        [Test]
        public void TheResolvedAuditRegisterAgreesWithTheContract()
        {
            using var contract = ReadContract();
            using var audit = ReadAudit();
            var parameters = ContractParameters(contract.RootElement);
            var fields = Fields(audit.RootElement);

            foreach (var entry in parameters)
            {
                var field = fields.Values.SingleOrDefault(candidate => RunParameterOf(candidate) == entry.Key);
                Assert.That(field.ValueKind, Is.Not.EqualTo(JsonValueKind.Undefined), $"host parameter '{entry.Key}' is not inventoried in the register");
                Assert.That(ClassOf(field), Is.AnyOf("A", "B"), $"resolved host parameter '{entry.Key}' must be approved (A) or a valid specified default (B)");
                var contractValue = RequiredText(entry.Value, "value");
                var registerValue = field.GetProperty("value");
                bool equal = registerValue.ValueKind switch
                {
                    JsonValueKind.True => contractValue == "true",
                    JsonValueKind.False => contractValue == "false",
                    JsonValueKind.Number => registerValue.GetDecimal() == decimal.Parse(contractValue, CultureInfo.InvariantCulture),
                    JsonValueKind.String => registerValue.GetString() == contractValue,
                    _ => false
                };
                Assert.That(equal, Is.True, $"the register value of '{entry.Key}' does not agree with the contract value '{contractValue}'");
            }

            var policyField = fields["helperFailedDataRequestPolicy"];
            Assert.That(ClassOf(policyField), Is.EqualTo("A"));
            Assert.That(RequiredBool(policyField, "value"), Is.EqualTo(contract.RootElement.GetProperty("failedDataRequestPolicy").GetProperty("allowMissingData").GetBoolean()));

            var root = contract.RootElement;
            Assert.That(audit.RootElement.GetProperty("frozenBaselineContract").GetString(), Is.EqualTo("config/baseline-contract.json"));
            Assert.That(
                audit.RootElement.GetProperty("frozenBaselineContractSha256").GetString(),
                Is.EqualTo(Sha256LfNormalized(Path.Combine(FindMarketLabRoot(), "config", "baseline-contract.json"))));
            Assert.That(root.GetProperty("qualifiedDataIdentity").GetProperty("sessionMapPath").GetString(), Is.EqualTo("marketlab-sessions/xauusd-sessions.json"));
        }

        [Test]
        public void ContractIdentityIsStableAndRecordedInTheHumanContract()
        {
            var contractPath = Path.Combine(FindMarketLabRoot(), "config", "baseline-contract.json");
            var identity = Sha256LfNormalized(contractPath);
            var humanContract = File.ReadAllText(Path.Combine(FindMarketLabRoot(), "BASELINE_CONTRACT.md"));

            using var audit = ReadAudit();
            Assert.That(audit.RootElement.GetProperty("frozenBaselineContractSha256").GetString(), Is.EqualTo(identity));
            Assert.That(humanContract, Does.Contain(identity), "the human-auditable contract must record the baseline contract identity");
            Assert.That(humanContract, Does.Contain("LF"), "the human-auditable contract must document the canonicalization");

            using var contract = ReadContract();
            var root = contract.RootElement;
            Assert.That(
                RequiredText(root, "canonicalization"),
                Does.Not.Contain(identity).IgnoreCase,
                "the contract file must not contain its own identity (it would be circular)");
        }

        [Test]
        public void TheContractRendersTheExactFrozenRunInvocation()
        {
            using var contract = ReadContract();
            var root = contract.RootElement;
            var parameters = ContractParameters(root);
            var rendered = string.Join(",", HostParameterOrder.Select(name => name + ":" + RequiredText(parameters[name], "value")));

            var expectedCommand = "pwsh -File MarketLab\\scripts\\run-backtest.ps1"
                + " -Configuration " + RequiredText(root.GetProperty("runHost"), "buildConfiguration")
                + " -Config " + RequiredText(root.GetProperty("runHost"), "leanConfig")
                + " -AlgorithmTypeName " + RequiredText(root.GetProperty("runHost"), "algorithmTypeName")
                + " -AlgorithmLanguage " + RequiredText(root.GetProperty("runHost"), "algorithmLanguage")
                + " -AlgorithmLocation " + RequiredText(root.GetProperty("runHost"), "algorithmLocation")
                + " -DataFolder " + RequiredText(root.GetProperty("qualifiedDataIdentity"), "dataFolder")
                + " -Parameters \"" + rendered + "\""
                + " -AllowMissingData -RunEvidence";

            var runProcedure = root.GetProperty("runProcedure");
            Assert.That(RequiredText(root.GetProperty("runHost"), "buildConfiguration"), Is.EqualTo("Release"));
            Assert.That(RequiredText(root.GetProperty("runHost"), "algorithmTypeName"), Is.EqualTo("SingleAnchorVNextAlgorithm"));
            Assert.That(RequiredText(root.GetProperty("runHost"), "algorithmLanguage"), Is.EqualTo("CSharp"));
            Assert.That(RequiredText(root.GetProperty("runHost"), "algorithmLocation"), Is.EqualTo(@"MarketLab\src\SingleAnchor\bin\Release\MarketLab.SingleAnchor.dll"));
            Assert.That(RequiredText(root.GetProperty("runHost"), "leanConfig"), Is.EqualTo("MarketLab/config/backtesting.json"));
            Assert.That(root.GetProperty("runHost").GetProperty("allowMissingData").GetBoolean(), Is.True);
            Assert.That(root.GetProperty("runHost").GetProperty("allowEngineErrors").GetBoolean(), Is.False);

            var recordedCommand = RequiredText(runProcedure, "exactRunCommand");
            Assert.That(recordedCommand, Is.EqualTo(expectedCommand), "the recorded exactRunCommand must be exactly the invocation rendered from the contract");
            Assert.That(recordedCommand, Does.Not.Contain("-AllowEngineErrors"));
            Assert.That(recordedCommand, Does.Contain("-AllowMissingData").And.Contain("-RunEvidence"));
            Assert.That(recordedCommand, Does.Contain("2019-01-01").And.Contain("2026-06-30"));
            Assert.That(recordedCommand, Does.Contain("E:\\MarketLab\\data\\lean\\xauusd-dukascopy"));

            Assert.That(RequiredText(runProcedure, "postRunAuditCommand"), Does.Contain("Test-SingleAnchorBaselineFailedData.ps1"));
            Assert.That(RequiredText(runProcedure, "runEvidenceRequirements"), Does.Contain("invocation evidence").IgnoreCase);
            Assert.That(RequiredText(runProcedure, "runEvidenceRequirements"), Does.Contain("composition manifest").IgnoreCase);
            Assert.That(RequiredText(root.GetProperty("runHost"), "runEvidence"), Does.Contain("-RunEvidence"));

            var humanContract = File.ReadAllText(Path.Combine(FindMarketLabRoot(), "BASELINE_CONTRACT.md"));
            Assert.That(humanContract, Does.Contain(rendered), "the human-auditable contract must record the exact frozen parameters string");
            Assert.That(humanContract, Does.Contain(recordedCommand), "the human-auditable contract must record the exact frozen run command");
        }

        [Test]
        public void HostDefaultsCannotSilentlyChangeTheBaseline()
        {
            using var contract = ReadContract();
            var parameters = ContractParameters(contract.RootElement);
            var hostDefaults = new SingleAnchorParameters();

            Assert.That(hostDefaults.StepPercent, Is.EqualTo(0m));
            Assert.That(hostDefaults.BaseLot, Is.EqualTo(0m));
            Assert.That(hostDefaults.NormalTradeCount, Is.EqualTo(4));
            Assert.That(hostDefaults.HardBreakevenCeilingPercent, Is.EqualTo(4.478m));
            Assert.That(hostDefaults.EscapeEnabled, Is.True);
            Assert.That(hostDefaults.EscapeProfitUnits, Is.EqualTo(0.05m));
            Assert.That(hostDefaults.EscapeMinimumOpenPositions, Is.EqualTo(2));
            Assert.That(hostDefaults.FixedTakeProfitUnits, Is.EqualTo(0m));
            Assert.That(hostDefaults.TrailingEnabled, Is.True);
            Assert.That(hostDefaults.TrailingActivationUnits, Is.EqualTo(0.50m));
            Assert.That(hostDefaults.TrailingDropUnits, Is.EqualTo(0.25m));
            Assert.That(hostDefaults.CommissionBuffer, Is.EqualTo(0m));
            Assert.That(hostDefaults.VolumeStep, Is.EqualTo(0.01m));
            Assert.That(hostDefaults.MinimumVolume, Is.EqualTo(0.01m));
            Assert.That(hostDefaults.MaximumVolume, Is.EqualTo(100m), "the engine global default stays 100");
            Assert.That(hostDefaults.CommissionPerLot, Is.EqualTo(0m));
            Assert.That(hostDefaults.Slippage, Is.EqualTo(0m));
            Assert.That(hostDefaults.ProjectedSpread, Is.Null, "the target spread has no host default and must be supplied");
            Assert.That(hostDefaults.BuySwapPerLotPerDay, Is.EqualTo(0m));
            Assert.That(hostDefaults.SellSwapPerLotPerDay, Is.EqualTo(0m));

            Assert.That(RequiredText(parameters["single-anchor-maximum-volume"], "value"), Is.EqualTo("50"), "MaximumVolume must not silently return to the engine default 100");
            Assert.That(RequiredText(parameters["single-anchor-projected-spread"], "value"), Is.EqualTo("0.50"));
            Assert.That(RequiredText(parameters["single-anchor-margin-enabled"], "value"), Is.EqualTo("true"));
            Assert.That(RequiredText(parameters["single-anchor-step-percent"], "value"), Is.EqualTo("0.25"));
            Assert.That(RequiredText(parameters["single-anchor-base-lot"], "value"), Is.EqualTo("0.10"));
            Assert.That(RequiredText(parameters["single-anchor-cash"], "value"), Is.EqualTo("20000"));

            // Every parameter, including those whose frozen value equals the host default, is passed
            // explicitly on the command line, so no host default is part of the baseline behaviour.
            foreach (var name in HostParameterOrder)
            {
                Assert.That(RequiredText(parameters[name], "value"), Is.Not.Empty, $"'{name}' must be passed explicitly");
            }
        }

        [Test]
        public void FixedImplementationBehaviourIsBoundAndDriftChecked()
        {
            using var contract = ReadContract();
            var fixedBehaviour = contract.RootElement.GetProperty("fixedImplementationContract");
            Assert.That(RequiredText(fixedBehaviour, "description"), Is.Not.Empty);
            Assert.That(RequiredText(fixedBehaviour, "dataResolution"), Is.EqualTo("Tick"));
            Assert.That(fixedBehaviour.GetProperty("fillForward").GetBoolean(), Is.False);
            Assert.That(fixedBehaviour.GetProperty("quoteOnlyBufferMinutes").GetInt32(), Is.EqualTo(5));
            Assert.That(RequiredText(fixedBehaviour, "sessionJunctionTimeZone"), Is.EqualTo("America/New_York"));
            Assert.That(RequiredText(fixedBehaviour, "sessionJunctionWindow"), Does.Contain("17:00:00"));
            Assert.That(RequiredText(fixedBehaviour, "benchmark"), Does.Contain("traded symbol"));
            Assert.That(RequiredText(fixedBehaviour, "sessionMapSemantics"), Does.Contain("quote-only"));

            // Live implementation values (public constants and the host source lines that cannot be
            // expressed as [Parameter]s): a change here must fail this test deliberately.
            Assert.That(HistoricalTradingAvailability.QuoteOnlyBuffer, Is.EqualTo(TimeSpan.FromMinutes(5)));
            Assert.That(SessionJunctionRule.TimeZoneId, Is.EqualTo("America/New_York"));
            Assert.That(SessionJunctionRule.SettlementStart.Hour, Is.EqualTo(17));
            Assert.That(SessionJunctionRule.SettlementStart.Minute, Is.EqualTo(0));
            Assert.That(SessionJunctionRule.SettlementEnd.Hour, Is.EqualTo(18));
            Assert.That(SessionJunctionRule.SettlementEnd.Minute, Is.EqualTo(0));
            Assert.That(HistoricalSessionMap.JunctionRuleText, Does.Contain("17:00:00").And.Contain("18:00:00").And.Contain("America/New_York"));

            var hostSource = File.ReadAllText(Path.Combine(FindMarketLabRoot(), "src", "SingleAnchor", "SingleAnchorVNextAlgorithm.cs"));
            Assert.That(hostSource, Does.Contain("AddCfd(_ticker, Resolution.Tick, _market, fillForward: false)"));
            Assert.That(hostSource, Does.Contain("AddForex(_ticker, Resolution.Tick, _market, fillForward: false)"));
            Assert.That(hostSource, Does.Contain("SetBenchmark(_symbol)"));
        }

        [Test]
        public void TerminationPolicyDistinguishesApprovedOutcomeFromFailures()
        {
            using var contract = ReadContract();
            var policy = contract.RootElement.GetProperty("failedDataRequestPolicy");
            var rule = RequiredText(policy, "terminationRule");
            Assert.That(rule, Does.Contain("AccountStopOut"));
            Assert.That(rule, Does.Contain("not an approved baseline outcome").IgnoreCase);
            Assert.That(rule, Does.Contain("invalid"));
            Assert.That(rule, Does.Not.Contain("or another recorded strategy/data failure"));
        }

        [Test]
        public void DataIdentityMatchesTheQualifiedContinuousHistoryEvidence()
        {
            using var contract = ReadContract();
            using var evidence = ReadEvidence();
            var identity = contract.RootElement.GetProperty("qualifiedDataIdentity");
            var composition = evidence.RootElement.GetProperty("composition");
            var totals = composition.GetProperty("totals");
            var replay = evidence.RootElement.GetProperty("replay");

            Assert.That(RequiredText(identity, "symbol"), Is.EqualTo("XAUUSD"));
            Assert.That(RequiredText(identity, "market"), Is.EqualTo("dukascopy"));
            Assert.That(RequiredText(identity, "securityType"), Is.EqualTo("Cfd"));
            Assert.That(RequiredText(identity, "resolution"), Is.EqualTo("Tick"));
            Assert.That(identity.GetProperty("fillForward").GetBoolean(), Is.False);
            Assert.That(RequiredText(identity, "dataTimeZone"), Is.EqualTo("UTC"));
            Assert.That(RequiredText(identity, "exchangeTimeZone"), Is.EqualTo("UTC"));

            Assert.That(RequiredText(identity, "dataFolder"), Is.EqualTo(composition.GetProperty("data_folder").GetString()));
            Assert.That(RequiredText(identity, "startDate"), Is.EqualTo(composition.GetProperty("lean_run_window").GetProperty("start_date").GetString()));
            Assert.That(RequiredText(identity, "endDate"), Is.EqualTo(composition.GetProperty("lean_run_window").GetProperty("end_date").GetString()));
            Assert.That(RequiredText(identity, "sessionMapPath"), Is.EqualTo(composition.GetProperty("session_map_relative_path").GetString()));
            Assert.That(RequiredText(identity, "sessionMapSha256"), Is.EqualTo(composition.GetProperty("session_map_sha256").GetString()));
            Assert.That(RequiredText(identity, "marketHoursDatabaseSha256"), Is.EqualTo(composition.GetProperty("market_hours_database_sha256").GetString()));
            Assert.That(RequiredText(identity, "symbolPropertiesDatabaseSha256"), Is.EqualTo(composition.GetProperty("symbol_properties_database_sha256").GetString()));
            Assert.That(RequiredText(identity, "continuousHistorySemanticDigest"), Is.EqualTo(composition.GetProperty("ordered_source_semantic_digest").GetString()));
            Assert.That(identity.GetProperty("continuousHistoryMonthCount").GetInt32(), Is.EqualTo(composition.GetProperty("month_count").GetInt32()));
            Assert.That(identity.GetProperty("continuousHistoryPartitionCount").GetInt32(), Is.EqualTo(composition.GetProperty("partition_count").GetInt32()));
            Assert.That(identity.GetProperty("continuousHistoryQuoteCount").GetInt64(), Is.EqualTo(totals.GetProperty("accepted_row_count").GetInt64()));
            Assert.That(RequiredText(identity, "continuousHistoryFirstQuoteUtc"), Is.EqualTo(composition.GetProperty("first_canonical_utc").GetString()));
            Assert.That(RequiredText(identity, "continuousHistoryLastQuoteUtc"), Is.EqualTo(composition.GetProperty("last_canonical_utc").GetString()));
            Assert.That(RequiredText(identity, "sourceFileSetSha256"), Is.EqualTo(composition.GetProperty("source_file_set_sha256").GetString()));
            Assert.That(RequiredText(identity, "orderedMonthDigestChainSha256"), Is.EqualTo(composition.GetProperty("ordered_month_digest_chain_sha256").GetString()));

            Assert.That(identity.GetProperty("continuousHistoryMonthCount").GetInt32(), Is.EqualTo(90));
            Assert.That(identity.GetProperty("continuousHistoryPartitionCount").GetInt32(), Is.EqualTo(2332));
            Assert.That(identity.GetProperty("continuousHistoryQuoteCount").GetInt64(), Is.EqualTo(413750130L));
            Assert.That(replay.GetProperty("overall_qualification").GetString(), Is.EqualTo("PASS"));
            Assert.That(replay.GetProperty("missing_native_partitions").GetInt32(), Is.EqualTo(0));
            Assert.That(replay.GetProperty("source_coverage_gap_days").GetInt32(), Is.EqualTo(0));
        }

        [Test]
        public void MarginContractIsTheApprovedPr3Contract()
        {
            using var contract = ReadContract();
            var margin = contract.RootElement.GetProperty("marginContract");
            var live = new MarginParameters();

            Assert.That(margin.GetProperty("enabled").GetBoolean(), Is.True);
            Assert.That(RequiredText(margin, "accountCurrency"), Is.EqualTo("USD"));
            Assert.That(margin.GetProperty("contractSizeOzPerLot").GetDecimal(), Is.EqualTo(live.ContractSize));
            Assert.That(margin.GetProperty("leverage").GetDecimal(), Is.EqualTo(live.Leverage));
            Assert.That(margin.GetProperty("marginCallThresholdPercent").GetDecimal(), Is.EqualTo(live.MarginCallLevelPercent));
            Assert.That(margin.GetProperty("stopOutThresholdPercent").GetDecimal(), Is.EqualTo(live.StopOutLevelPercent));
            Assert.That(margin.GetProperty("initialMarginRate").GetDecimal(), Is.EqualTo(1.0m));
            Assert.That(margin.GetProperty("maintenanceMarginRate").GetDecimal(), Is.EqualTo(1.0m));
            Assert.That(margin.GetProperty("hostEnforced").GetBoolean(), Is.True);
            Assert.That(RequiredText(margin, "matchedHedgeMarginRule"), Does.Contain("zero margin"));
            Assert.That(RequiredText(margin, "uncoveredVolumeMarginRule"), Does.Contain("weighted-average open price"));
            Assert.That(RequiredText(margin, "negativeEquityHandling"), Does.Contain("negative equity"));
            Assert.That(RequiredText(margin, "stopOutSemantics"), Does.Contain("terminal"));

            Assert.That(live.ContractSize, Is.EqualTo(100m));
            Assert.That(live.Leverage, Is.EqualTo(500m));
            Assert.That(live.MarginCallLevelPercent, Is.EqualTo(50m));
            Assert.That(live.StopOutLevelPercent, Is.EqualTo(20m));
            Assert.That(SingleAnchorVNextAlgorithm.MarginHostContractError("XAUUSD", "Cfd", 100m), Is.Null);
            Assert.That(SingleAnchorVNextAlgorithm.MarginHostContractError("XAUUSD", "Cfd", 50m), Is.Not.Null);
            Assert.That(live.GetValidationErrors(), Is.Empty);
        }

        [Test]
        public void FailedDataPolicyIsBoundedAndNotWeakened()
        {
            using var contract = ReadContract();
            var root = contract.RootElement;
            var policy = root.GetProperty("failedDataRequestPolicy");
            var runHost = root.GetProperty("runHost");

            Assert.That(policy.GetProperty("allowMissingData").GetBoolean(), Is.True);
            Assert.That(policy.GetProperty("allowEngineErrors").GetBoolean(), Is.False);
            Assert.That(policy.GetProperty("classificationRequired").GetBoolean(), Is.True);
            Assert.That(runHost.GetProperty("allowMissingData").GetBoolean(), Is.True);
            Assert.That(runHost.GetProperty("allowEngineErrors").GetBoolean(), Is.False);
            Assert.That(RequiredText(root.GetProperty("runProcedure"), "exactRunCommand"), Does.Not.Contain("-AllowEngineErrors"));

            var auxiliary = policy.GetProperty("knownAuxiliaryRequestPaths").EnumerateArray().Select(item => item.GetString()).ToArray();
            Assert.That(auxiliary, Is.EqualTo(ExpectedAuxiliaryPaths), "the known auxiliary request list must be exact");

            var invalidating = policy.GetProperty("invalidatingCategories").EnumerateArray().Select(item => item.GetString()!).ToArray();
            Assert.That(invalidating.Length, Is.EqualTo(4));
            Assert.That(invalidating.Any(value => value.StartsWith("unexpected-missing-qualified-partition", StringComparison.Ordinal)), Is.True);
            Assert.That(invalidating.Any(value => value.StartsWith("unexpected-out-of-window-request", StringComparison.Ordinal)), Is.True);
            Assert.That(invalidating.Any(value => value.StartsWith("unexpected-unknown-request", StringComparison.Ordinal)), Is.True);
            Assert.That(invalidating.Any(value => value.StartsWith("unexpected-unrequested-absence", StringComparison.Ordinal)), Is.True);
            Assert.That(policy.GetProperty("expectedCategories").GetArrayLength(), Is.GreaterThanOrEqualTo(2));

            var reference = policy.GetProperty("qualifiedReplayReference");
            Assert.That(reference.GetProperty("sourceAbsentCalendarDayRequests").GetInt32(), Is.EqualTo(406));
            Assert.That(reference.GetProperty("unrelatedAuxiliaryRequests").GetInt32(), Is.EqualTo(1));
            Assert.That(reference.GetProperty("missingQualifiedPartitions").GetInt32(), Is.EqualTo(0));
            Assert.That(reference.GetProperty("coverageGaps").GetInt32(), Is.EqualTo(0));

            var rootDir = FindMarketLabRoot();
            Assert.That(File.Exists(Path.Combine(rootDir, "scripts", "Test-SingleAnchorBaselineFailedData.ps1")), Is.True);
            Assert.That(File.Exists(Path.Combine(rootDir, "scripts", "Get-SingleAnchorBaselineInvocation.ps1")), Is.True);
            Assert.That(File.Exists(Path.Combine(rootDir, "tests", "Test-SingleAnchorBaselineFailedData.ps1")), Is.True);

            var classifier = File.ReadAllText(Path.Combine(rootDir, "scripts", "Test-SingleAnchorBaselineFailedData.ps1"));
            Assert.That(classifier, Does.Contain("marketlab-single-anchor-baseline-failed-data-classification-v1"));
            Assert.That(classifier, Does.Contain("baselineContractSha256"));
            Assert.That(classifier, Does.Not.Contain("-AllowEngineErrors"), "the classifier must not weaken the engine-error policy");
        }

        [Test]
        public void AlgorithmBuildAndConfigIdentityAreFrozen()
        {
            using var contract = ReadContract();
            var runHost = contract.RootElement.GetProperty("runHost");
            var rootDir = FindMarketLabRoot();

            Assert.That(RequiredText(runHost, "buildConfiguration"), Is.EqualTo("Release"));
            Assert.That(RequiredText(runHost, "algorithmTypeName"), Is.EqualTo(nameof(SingleAnchorVNextAlgorithm)));
            Assert.That(typeof(SingleAnchorVNextAlgorithm).FullName, Is.EqualTo("MarketLab.SingleAnchor.SingleAnchorVNextAlgorithm"));
            Assert.That(
                RequiredText(runHost, "leanConfigSha256LfNormalized"),
                Is.EqualTo(Sha256LfNormalized(Path.Combine(rootDir, "config", "backtesting.json"))),
                "the qualified backtesting configuration content must still match the contract hash");
            Assert.That(File.Exists(Path.Combine(rootDir, "config", "baseline-decision-audit.json")), Is.True);
            Assert.That(File.Exists(Path.Combine(rootDir, "BASELINE_CONTRACT.md")), Is.True);
        }

        [Test]
        public void EveryEffectiveStrategyParameterIsBoundAndClassified()
        {
            // A new or removed SingleAnchorParameters property is an effective strategy input; it
            // must be mapped to an explicit host parameter and frozen deliberately.
            var mapping = new Dictionary<string, string>(StringComparer.Ordinal)
            {
                ["StepPercent"] = "single-anchor-step-percent",
                ["BaseLot"] = "single-anchor-base-lot",
                ["NormalTradeCount"] = "single-anchor-normal-trade-count",
                ["HardBreakevenCeilingPercent"] = "single-anchor-hard-be-ceiling-percent",
                ["EscapeEnabled"] = "single-anchor-escape-enabled",
                ["EscapeProfitUnits"] = "single-anchor-escape-profit-units",
                ["EscapeMinimumOpenPositions"] = "single-anchor-escape-minimum-open-positions",
                ["FixedTakeProfitUnits"] = "single-anchor-fixed-tp-units",
                ["TrailingEnabled"] = "single-anchor-trailing-enabled",
                ["TrailingActivationUnits"] = "single-anchor-trailing-activation-units",
                ["TrailingDropUnits"] = "single-anchor-trailing-drop-units",
                ["CommissionBuffer"] = "single-anchor-commission-buffer",
                ["PointValuePerLot"] = "single-anchor-point-value-per-lot",
                ["VolumeStep"] = "single-anchor-volume-step",
                ["MinimumVolume"] = "single-anchor-minimum-volume",
                ["MaximumVolume"] = "single-anchor-maximum-volume",
                ["CommissionPerLot"] = "single-anchor-commission-per-lot",
                ["Slippage"] = "single-anchor-slippage",
                ["ProjectedSpread"] = "single-anchor-projected-spread",
                ["BuySwapPerLotPerDay"] = "single-anchor-buy-swap-per-lot-per-day",
                ["SellSwapPerLotPerDay"] = "single-anchor-sell-swap-per-lot-per-day"
            };

            var strategyProperties = typeof(SingleAnchorParameters)
                .GetProperties(BindingFlags.Public | BindingFlags.Instance)
                .Where(property => property.CanRead && property.GetIndexParameters().Length == 0)
                .Select(property => property.Name)
                .OrderBy(name => name, StringComparer.Ordinal)
                .ToArray();

            Assert.That(
                strategyProperties,
                Is.EqualTo(mapping.Keys.OrderBy(name => name, StringComparer.Ordinal).ToArray()),
                "a new or removed SingleAnchorParameters property must be mapped to a frozen host parameter deliberately");
            Assert.That(mapping.Values.Distinct(StringComparer.Ordinal).Count(), Is.EqualTo(mapping.Count), "each strategy property must map to its own host parameter");
            foreach (var hostParameter in mapping.Values)
            {
                Assert.That(HostParameterOrder, Does.Contain(hostParameter), $"'{hostParameter}' must be a frozen explicit host parameter");
            }

            // The host-only parameters are the remaining explicit inputs (identity, dates, balance,
            // session map, account and margin mode); all are frozen by the contract too.
            Assert.That(HostParameterOrder.Length, Is.EqualTo(mapping.Count + 9));
        }

        private static string[] HostParameterNames()
        {
            return typeof(SingleAnchorVNextAlgorithm)
                .GetFields(ParameterAttribute.BindingFlags)
                .Cast<MemberInfo>()
                .Concat(typeof(SingleAnchorVNextAlgorithm).GetProperties(ParameterAttribute.BindingFlags))
                .Select(member => (Member: member, Attribute: member.GetCustomAttribute<ParameterAttribute>()))
                .Where(entry => entry.Attribute != null)
                .Select(entry => entry.Attribute!.Name ?? entry.Member.Name)
                .OrderBy(name => name, StringComparer.Ordinal)
                .ToArray();
        }

        private static string FindMarketLabRoot()
        {
            var candidate = new DirectoryInfo(TestContext.CurrentContext.TestDirectory);
            while (candidate != null)
            {
                if (File.Exists(Path.Combine(candidate.FullName, "SINGLE_ANCHOR_VNEXT_STRATEGY.md"))
                    && File.Exists(Path.Combine(candidate.FullName, "config", "baseline-contract.json"))
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

        private static JsonDocument ReadContract()
        {
            return JsonDocument.Parse(File.ReadAllText(Path.Combine(FindMarketLabRoot(), "config", "baseline-contract.json")));
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

        private static Dictionary<string, JsonElement> ContractParameters(JsonElement root)
        {
            var parameters = new Dictionary<string, JsonElement>(StringComparer.Ordinal);
            foreach (var entry in root.GetProperty("parameters").EnumerateArray())
            {
                var name = entry.GetProperty("name").GetString() ?? string.Empty;
                Assert.That(parameters.ContainsKey(name), Is.False, $"duplicate contract parameter '{name}'");
                parameters[name] = entry;
            }
            return parameters;
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

        private static string ClassOf(JsonElement field)
        {
            return RequiredText(field, "class");
        }

        private static string RequiredText(JsonElement field, string name)
        {
            var label = field.TryGetProperty("field", out var fieldName) ? fieldName.GetString()
                : field.TryGetProperty("name", out var parameterName) ? parameterName.GetString()
                : "?";
            Assert.That(field.TryGetProperty(name, out var value), Is.True, $"'{label}' must carry '{name}'");
            Assert.That(value.ValueKind, Is.EqualTo(JsonValueKind.String), $"'{label}': '{name}' must be a string");
            var text = value.GetString();
            Assert.That(string.IsNullOrWhiteSpace(text), Is.False, $"'{label}': '{name}' must not be empty");
            return text ?? string.Empty;
        }

        private static bool RequiredBool(JsonElement field, string name)
        {
            var id = field.GetProperty("field").GetString();
            Assert.That(field.TryGetProperty(name, out var value), Is.True, $"field '{id}' must carry '{name}'");
            Assert.That(value.ValueKind, Is.AnyOf(JsonValueKind.True, JsonValueKind.False), $"field '{id}': '{name}' must be a boolean");
            return value.GetBoolean();
        }
    }
}
