"""MarketLab offline historical-data qualification and native-LEAN conversion.

This package is offline preparation tooling only. It reads a historical bid/ask
CSV source, applies the authoritative SingleAnchor qualification contract
(``Bid > 0``, ``Ask > 0``, ``Ask >= Bid``, valid non-decreasing timestamps,
source order preserved), and - only after the source passes - writes native
LEAN quote-tick files for the XAUUSD/Oanda CFD subscription together with a
deterministic qualification manifest and the replay expectation consumed by the
MarketLab LEAN replay probe.

Python never participates in the per-tick strategy runtime: the converted files
are read by the unchanged LEAN engine, and the C# probe verifies the stream
LEAN actually delivers.

See ``MarketLab/tools/historical-data/README.md`` for the workflow and
``MarketLab/SINGLE_ANCHOR_RESEARCH_IMPLEMENTATION_PLAN.md`` for the
authoritative plan.
"""

__all__ = [
    "canonical",
    "csv_source",
    "lean_native",
    "market_hours",
    "qualification",
    "replay",
    "transactions",
]
