---
name: design-gridtrader-version-scheme
description: GridTrader version increment convention — +0.01 per version since v1.00
metadata: 
  node_type: memory
  type: project
  originSessionId: acaae4cb-91bb-4a61-9f1f-0f5a95bfcae8
---

Since the official v1.00 release, every GridTrader EA version **increments by +0.01** (1.00 → 1.01 → 1.02 …), reflected in `#property version` of `GridTrader.mq5`.

**How to apply:** Whenever a new version is released/committed, add 0.01 to the current `#property version`; commit / PR messages include that version number. v1.00 is the first official release (PR #1, branch release/v1.00); earlier versions used old development numbers such as 3.00 (obsolete, no longer used).
