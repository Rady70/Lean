# Retired-source provenance for PR 1

The retired repositories are reference material, not runtime dependencies. This
file records every retired file or behaviour that was reused or adapted for the
PR 1 historical-data qualification tooling. The MarketLab-owned result is much
smaller than the retired module: only the CSV/timestamp/decimal-qualification
and transactional-publication pieces needed by PR 1 were migrated.

## Pinned sources

| Repository | Commit |
|---|---|
| `Rady70/quant_research_app` | `36a977fae0942cf49f856a3c9c3aa7aaba7f2dbb` |
| `Rady70/quant_research_platform` | `a5b64625a549da6d136f3491f7219fbddffdd35d` |
| `Rady70/single_anchor_research` | `0f2aca3cc87f2b368a8ccfbe8814e94b1d78763a` |

## Migrated or adapted

| Source repository | Source commit | Source path | Destination path | Adaptations |
|---|---|---|---|---|
| quant_research_app | `36a977fae0942cf49f856a3c9c3aa7aaba7f2dbb` | `src/quant_research_app/market_data/timestamps.py` | `MarketLab/tools/historical-data/python/marketlab_historical_data/canonical.py`, `.../csv_source.py` | Kept: timestamp-text parsing with `Z`/`\u00b1HH:MM` offset recognition, rejection of fraction digits beyond microseconds instead of truncation, naive/aware representation contract per file, source-timezone localization that rejects DST gaps and ambiguous folds. Changed: canonical UTC text is fixed at millisecond precision for the LEAN tick contract; the canonical decimal form and the semantic digest were added; tzdata is optional (standard `zoneinfo`). |
| quant_research_app | `36a977fae0942cf49f856a3c9c3aa7aaba7f2dbb` | `src/quant_research_app/market_data/data_quality.py` | `MarketLab/tools/historical-data/python/marketlab_historical_data/csv_source.py` | Kept: deterministic header normalization (trim, lower, `<...>` unwrap, `-`/space to `_`), fixed candidate lists and explicit-column precedence, delimiter sniffing with deterministic fallback, first-duplicate-header-wins, the permissive `Ask == Bid` policy, duplicate timestamp counting, source-order processing. Changed: one authoritative strict path (a rejected or decreasing row fails the dataset instead of being counted and kept); `nan`/`inf`/exponent spellings are rejected (the retired float-based parser accepted them); prices are parsed and retained as `decimal.Decimal` text, never binary64; the semantic digest and the LEAN millisecond collision statistics were added. |
| quant_research_app | `36a977fae0942cf49f856a3c9c3aa7aaba7f2dbb` | `src/quant_research_app/market_data/data_loader.py` | `MarketLab/tools/historical-data/python/marketlab_historical_data/csv_source.py` | Kept: the same timestamp/date+time/bid/ask candidate tuples and explicit column/format handling. Changed: no `DictReader`, no binary64 price path, no Parquet, no extra-column tolerance. |
| quant_research_app | `36a977fae0942cf49f856a3c9c3aa7aaba7f2dbb` | `src/quant_research_app/adapters/csv_quote_source.py` | `MarketLab/tools/historical-data/python/marketlab_historical_data/csv_source.py` | Kept: the `ask >= bid` rule, decimal-only numeric regex, strict timestamp text shapes and source-order checks, duplicate preservation. Changed: columns are configurable beyond the fixed `timestamp,bid,ask` header; timezone handling follows the retired `timestamps.py` contract. |
| quant_research_app | `36a977fae0942cf49f856a3c9c3aa7aaba7f2dbb` | `src/quant_research_app/market_data/validation.py` | `MarketLab/tools/historical-data/python/marketlab_historical_data/csv_source.py` | Kept: non-finite and malformed numeric rejection, positive-price checks, non-decreasing timestamp rule. Changed: `ask == bid` is accepted (the current C# `SingleAnchor.Quote` contract is authoritative); the archive's rejection of zero spread is deliberately not used. |
| quant_research_app | `36a977fae0942cf49f856a3c9c3aa7aaba7f2dbb` | `src/quant_research_app/market_data/file_transaction.py` | `MarketLab/tools/historical-data/python/marketlab_historical_data/transactions.py` | Kept: hidden adjacent staging paths, atomic `os.replace` installation, rollback of installed files and restoration of overwritten backups, created-directory cleanup, no-overwrite default. Changed: simplified (no source/output comparison, no `os.link` no-overwrite path, no backup-retention warnings); it is not a crash-durability primitive (no `fsync`), matching the retired code. |
| quant_research_app | `36a977fae0942cf49f856a3c9c3aa7aaba7f2dbb` | `tests/test_market_data_quality.py`, `tests/test_market_data_timestamps.py`, `tests/test_market_data_loader.py`, `tests/test_market_data_archive.py`, `tests/test_market_data_operator_edges.py`, `tests/test_csv_source.py` | `MarketLab/tools/historical-data/python/tests/` | Ported as focused tests for this project's changed contracts: zero-spread acceptance, crossed/non-positive/malformed rejection, equal-timestamp and duplicate preservation, source-order preservation, no sorting, exact decimal text preservation, DST gap/fold rejection, transactional rollback and overwrite behaviour. The digest, LEAN-format conversion, collision statistics, manifest determinism and replay-record tests are new for this project. |

## Used as semantic reference only (no code copied)

| Repository | Commit | Relevance |
|---|---|---|
| `Rady70/single_anchor_research` | `0f2aca3cc87f2b368a8ccfbe8814e94b1d78763a` | Data/reproducibility contracts: non-decreasing timestamps, duplicates kept in source order, deterministic digest practices. Used to shape the PR 1 tests and the manifest/digest contract. No Python strategy code was migrated. |
| `Rady70/quant_research_platform` | `a5b64625a549da6d136f3491f7219fbddffdd35d` | Account/analytics semantics; relevant to PR 2, not to PR 1. Nothing was migrated. |

## Deliberately not migrated

The retired Parquet archive stack, monthly archive composition, seekable
archives, PyArrow/pandas dependencies, generic experiment systems, Python
strategy code, generic analytics and account models were not brought over.
They solve broader problems than PR 1 and have no concrete PR 1 requirement.
