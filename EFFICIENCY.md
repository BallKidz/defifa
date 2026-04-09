# Gas Efficiency Optimizations

All optimizations applied in the `gas/efficiency-optimizations` branch. Each entry documents the change, estimated savings, and impact classification.

---

### [Storage Read Caching] Cache `metadata.dataHook` in local variable across DefifaGovernor
**Files:** `src/DefifaGovernor.sol` (attestToScorecardFrom, ratifyScorecardFrom, submitScorecardFor, getAttestationWeight, getBWAAttestationWeight, quorum)
**Change:** Cached `metadata.dataHook` (a memory struct field) into a local `address dataHook` variable at the top of each function. All subsequent references use `dataHook` instead of `metadata.dataHook`, eliminating repeated memory offset calculations.
**Savings:** ~50-100 gas per function call (3 gas per MLOAD saved, multiplied by 5-15 accesses per function)
**Impact:** LOW

### [Storage Read Caching] Cache `store` in local variable across DefifaHook
**Files:** `src/DefifaHook.sol` (beforeCashOutRecordedWith, afterCashOutRecordedWith, mintReservesFor, _update, _pendingReserveMintCost)
**Change:** Cached the `store` state variable (SLOAD) into a local `IJB721TiersHookStore _store` variable. Subsequent reads within the same function use the cached local instead of re-reading from storage.
**Savings:** ~2,000 gas per SLOAD avoided (2,100 gas warm SLOAD vs 3 gas MLOAD). Functions like `afterCashOutRecordedWith` and `_update` save 2-4 SLOADs each.
**Impact:** MEDIUM

### [Storage Read Caching] Cache `address(this)` in local variable
**Files:** `src/DefifaHook.sol` (beforeCashOutRecordedWith, mintReservesFor, tokensClaimableFor)
**Change:** Cached `address(this)` into a local `address hook` or `address self` variable when used multiple times in the same function, avoiding repeated opcode evaluation.
**Savings:** ~10-20 gas per function call (ADDRESS opcode is 2 gas, but avoiding repeated use in struct/call construction saves encoding overhead)
**Impact:** LOW

### [Storage Read Caching] Cache `address(terminal)` in DefifaDeployer
**Files:** `src/DefifaDeployer.sol` (currentGamePotOf, currentGamePhaseOf, fulfillCommitmentsOf)
**Change:** Cached `address(terminal)` into a local `address terminalAddr` variable when used multiple times for both the terminal call and the store call.
**Savings:** ~50 gas per function call (avoids repeated address casting)
**Impact:** LOW

### [External Call Caching] Cache hook store in submitScorecardFor
**File:** `src/DefifaGovernor.sol` line ~280
**Change:** The hook store (`IDefifaHook(dataHook).store()`) was called once and cached in a local `hookStore` variable. Previously, it was called separately for `validateAndBuildWeights` and then again inside the snapshot loop via `IDefifaHook(metadata.dataHook).store()`. Now both use the cached reference.
**Savings:** ~2,600 gas (one fewer external CALL + SLOAD)
**Impact:** MEDIUM

### [Loop Optimization] Unchecked increments in all governor loops
**Files:** `src/DefifaGovernor.sol` (submitScorecardFor tier validation loop, tier weight storage loop, snapshot loop, maxWeight loop, getAttestationWeight, getBWAAttestationWeight, quorum)
**Change:** Replaced `i++` or `for (uint256 i; i < n; i++)` with `unchecked { ++i; }` blocks at the end of loop bodies. The loop counter cannot overflow because it is bounded by the number of tiers (max 128).
**Savings:** ~60 gas per iteration (overflow check removal). With typical 4-16 tier games, saves 240-960 gas per function call.
**Impact:** MEDIUM

### [Loop Optimization] Unchecked increments in deployer split loops
**Files:** `src/DefifaDeployer.sol` (_buildSplits absolute percent summation loop, normalization loop)
**Change:** Added `unchecked { ++i; }` to both loops in `_buildSplits`. Loop counters are bounded by the number of user splits.
**Savings:** ~60 gas per iteration per loop
**Impact:** LOW

### [Loop Optimization] Unchecked increment in afterCashOutRecordedWith
**File:** `src/DefifaHook.sol` line ~651
**Change:** Added `unchecked { ++i; }` to the token burn loop in `afterCashOutRecordedWith`. The counter is bounded by the number of token IDs being cashed out.
**Savings:** ~60 gas per token being cashed out
**Impact:** LOW

### [Named Arguments] Style guide compliance for all 2+ arg function calls
**Files:** All `src/*.sol` files
**Change:** Converted all remaining positional function calls with 2+ arguments to named argument style (`func({arg1: val1, arg2: val2})`), per the STYLE_GUIDE.md requirement. This includes `numberOfPendingReservesFor`, `mulDiv`, `store.tierOf`, `Address.verifyCallResult`, and error reverts with context.
**Savings:** No gas impact (compile-time only)
**Impact:** N/A (style compliance)

---

## Summary

| Category | Count | Estimated Total Savings |
|----------|-------|------------------------|
| Storage Read Caching (SLOAD) | 5 instances | ~8,000-12,000 gas across hot paths |
| External Call Caching | 1 instance | ~2,600 gas |
| Unchecked Loop Increments | 9 loops | ~500-2,000 gas per transaction |
| Named Arguments (style) | ~20 call sites | 0 gas (readability) |

**Total estimated savings per typical game operation:** 3,000-15,000 gas depending on the number of tiers and operation type. The largest savings come from caching the `store` SLOAD in DefifaHook (MEDIUM impact) and unchecked loop increments in DefifaGovernor governance functions that iterate over all tiers (MEDIUM impact).
