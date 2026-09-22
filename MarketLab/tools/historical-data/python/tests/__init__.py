"""Shared helpers for the MarketLab historical-data tool tests."""

from __future__ import annotations

import sys
from pathlib import Path

PACKAGE_ROOT = Path(__file__).resolve().parents[1]
if str(PACKAGE_ROOT) not in sys.path:
    sys.path.insert(0, str(PACKAGE_ROOT))

FIXTURES = Path(__file__).resolve().parents[2] / "fixtures"
LEAN_ROOT = Path(__file__).resolve().parents[5]
