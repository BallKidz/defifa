# defifa-collection-deployer-v6 Changelog (v5 → v6)

This document describes the changes between `defifa-collection-deployer` (v5) and `defifa-collection-deployer-v6` (v6). Defifa is an on-chain prediction game framework built on Juicebox where players mint NFTs representing outcomes, a governor ratifies scorecard distributions, and winners burn NFTs to claim proportional shares.

## Summary

- **V6 hook migration**: All 721 hook interactions updated from `nana-721-hook-v5` to `nana-721-hook-v6`, including the new tier splits system and `splitPercent` field in `JB721TierConfig`.
- **Dependency modernization**: Core, permission IDs, address registry, and ownable dependencies all updated to v6. New ecosystem dependencies on `croptop-core-v6` and `revnet-core-v6`.
- **Error naming standardized**: Error names changed from bare names (e.g., `InvalidCashoutWeights`) to contract-prefixed names (e.g., `DefifaHook_InvalidCashoutWeights`).
- **Cash out hook spec gains `noop` field**: `beforeCashOutRecordedWith` now returns `noop=false` in all specifications, ensuring the terminal always calls the hook callback.
- **Compiler/tooling updated**: The v6 repo now builds and tests on Solidity `0.8.28`, matching the rest of the V6 ecosystem.
- **Game lifecycle preserved**: The core game phases (COUNTDOWN → MINT → REFUND → SCORING → COMPLETE) and governance model (50% quorum, scorecard ratification) remain the same at the product level even though the underlying hook/controller integrations changed.

## ABI Status

This repo does have meaningful ABI migration surface. The main ABI-facing contracts for integrators are:
- `IDefifaDeployer`
- `IDefifaHook`
- `IDefifaGovernor`

The largest ABI risks are:
- inherited 721-hook/core-v6 struct and return-shape changes flowing through Defifa interfaces;
- event families now living on v6 interfaces/contracts with prefixed errors and updated dependent types;
- hook return values that now include v6 `noop`-aware hook-spec structures.

---

## 1. Breaking Changes

### 1.1 Dependency Updates

| Dependency | v5 | v6 |
|------------|----|----|
| `@bananapus/core` | `v5` | `v6` |
| `@bananapus/721-hook` | `v5` | `v6` |
| `@bananapus/address-registry` | `v5` | `v6` |
| `@bananapus/permission-ids` | `v5` | `v6` (new dependency) |
| `@openzeppelin/contracts` | `^5.4.0` | `5.2.0` (pinned) |
| `@croptop/core` | N/A | `v6` (new) |
| `@rev-net/core` | N/A | `v6` (new) |

### 1.2 Error Naming Convention

All custom errors now use a contract-name prefix:

| v5 | v6 |
|----|----|
| `InvalidCashoutWeights` | `DefifaHook_InvalidCashoutWeights` |
| `InvalidPhase` | `DefifaHook_InvalidPhase` |
| (and similar for all other errors) | Contract prefix added throughout |

### 1.3 `JBCashOutHookSpecification` Gains `noop` Field

The v6 `JBCashOutHookSpecification` struct has a `noop` boolean field. `DefifaHook.beforeCashOutRecordedWith` returns `noop=false` in all specifications, ensuring the terminal always invokes `afterCashOutRecordedWith` for game-phase-aware cashout processing.

### 1.4 Solidity Version

- **v5:** `pragma solidity 0.8.23`
- **v6:** `pragma solidity 0.8.28`

### 1.5 721 Hook API Changes

Inherited from `nana-721-hook-v6`:
- `cashOutWeightOf()` and `totalCashOutWeight()` signatures simplified (removed `JBBeforeCashOutRecordedContext` parameter)
- `pricingContext()` returns 2 values instead of 3
- `JB721TierConfig` gained `splitPercent` and `splits` fields
- `JB721TiersHookFlags` gained `issueTokensForSplits` field

### 1.6 Function-Level Integration Changes

These are the main V6 surface changes integrators should care about:
- `beforeCashOutRecordedWith(...)` now returns a `JBCashOutHookSpecification` that includes the new `noop` field from core-v6.
- Any integration constructing or decoding `JB721TierConfig` must account for the added `splitPercent` and `splits` fields.
- Any integration reading pricing context from the inherited 721 hook must expect 2 return values, not 3.
- Defifa deployer integrations should re-check `launchGameWith(...)`, `fulfillCommitmentsOf(...)`, `triggerNoContestFor(...)`, `nextPhaseNeedsQueueing(...)`, `safetyParamsOf(...)`, and `timesFor(...)` against the v6 ABIs and dependent core-v6 structs.

---

## 2. Game Lifecycle (Unchanged)

The core game phases remain identical between v5 and v6:

```
COUNTDOWN (ruleset 0) → MINT (ruleset 1) → REFUND (ruleset 2)
    → SCORING (ruleset 3+) → COMPLETE (after ratification)
```

Safety mechanisms:
- **NO_CONTEST**: Triggered if `minParticipation` not met or `scorecardTimeout` exceeded
- **Scorecard governance**: 50% quorum, tier-delegated voting power with checkpointed snapshots
- **Grace period**: Minimum 1 day for governance proposals

---

## 3. Architecture

### 3.1 Key Contracts

| Contract | Role |
|----------|------|
| `DefifaDeployer` | Game factory -- launches projects with phased rulesets, manages fulfillment |
| `DefifaHook` | ERC-721 hook with game logic, attestation, per-tier cashout weights |
| `DefifaGovernor` | Shared singleton for scorecard submission/attestation/ratification |
| `DefifaProjectOwner` | Proxy that receives project NFT and grants deployer permissions |
| `DefifaTokenUriResolver` | On-chain SVG metadata with dynamic game state |

### 3.2 Deployment Pattern

DefifaHook instances are deployed as minimal proxy clones via `Clones.cloneDeterministic()`:
- Salt includes `msg.sender` + nonce (prevents cross-caller collision)
- One-time `initialize()` call per clone
- Owned by DefifaGovernor for scorecard weight setting

## 4. Events and Errors

The most important integration-facing patterns are:
- Errors are now consistently contract-prefixed (`DefifaHook_*`, `DefifaDeployer_*`, `DefifaGovernor_*`, `DefifaProjectOwner_*`) instead of using the older unprefixed style.
- Defifa-specific events remain centered around game launch, phase transitions, fulfillment, scoring, minting, claims, and delegation, but they now live against the V6 hook/controller stack and should be indexed using the V6 ABIs.
- `CommitmentPayoutFailed`, `LaunchGame`, `QueuedRefundPhase`, `QueuedScoringPhase`, `QueuedNoContest`, `GameInitialized`, `ScorecardSubmitted`, `ScorecardAttested`, `ScorecardRatified`, `Mint`, `MintReservedToken`, `ClaimedTokens`, and `TierCashOutWeightsSet` are the key integration events to watch across the deployer, governor, and hook.
- Other hook-level events worth indexing for governance clients are `TierDelegateAttestationsChanged` and `DelegateChanged`.

Key runtime errors now exposed by the v6 contracts include:
- `DefifaDeployer_*` errors such as `DefifaDeployer_InvalidGameConfiguration`, `DefifaDeployer_TerminalNotFound`, `DefifaDeployer_SplitsDontAddUp`, `DefifaDeployer_CantFulfillYet`, and `DefifaDeployer_NoContestAlreadyTriggered`.
- `DefifaHook_*` errors such as `DefifaHook_InvalidCashoutWeights`, `DefifaHook_InvalidTierId`, `DefifaHook_ReservedTokenMintingPaused`, `DefifaHook_TransfersPaused`, and `DefifaHook_Unauthorized(...)`.
- `DefifaGovernor_*` errors such as `DefifaGovernor_AlreadyAttested`, `DefifaGovernor_AlreadyRatified`, `DefifaGovernor_DuplicateScorecard`, `DefifaGovernor_NotAllowed`, and `DefifaGovernor_UnknownProposal`.

---

## 5. Migration Table

| Aspect | v5 | v6 |
|--------|----|----|
| Core dependency | `@bananapus/core-v5` | `@bananapus/core-v6` |
| 721 hook dependency | `@bananapus/721-hook-v5` | `@bananapus/721-hook-v6` |
| Permission IDs | Not a direct dependency | `@bananapus/permission-ids-v6` |
| Error naming | Bare names | Contract-prefixed names |
| `JBCashOutHookSpecification` | No `noop` field | `noop=false` on all specs |
| Solidity version | `0.8.23` | `0.8.28` |
| Game lifecycle | COUNTDOWN->MINT->REFUND->SCORING->COMPLETE | Identical |
| Governance model | 50% quorum, tier-delegated | Identical |

> **Cross-repo impact**: Uses `nana-721-hook-v6` for all tier management and cashout weight distribution. The `nana-permission-ids-v6` ID shifts affect any hardcoded permission checks. `deploy-all-v6` now includes Defifa as Phase 10, so canonical deployments can source Defifa addresses from the top-level rollout.

---

## 6. Post-Audit Fixes (Codex R2)

### 6.1 H-1: Prevent same-block double attestation via timestamp snapshot

**File:** `DefifaGovernor.sol` -- `attestToScorecardFrom()`

Previously, attestation weight was snapshot at `_scorecard.attestationsBegin`, which could equal `block.timestamp` during the same block as a transfer. This allowed a holder to attest, transfer the NFT, and have the recipient also attest in the same block -- both counting because `upperLookup(block.timestamp)` includes same-block checkpoints.

**Fix:** Changed the snapshot to `block.timestamp - 1`, ensuring only state from before the current block is visible. Same-block transfer recipients now receive zero attestation weight.

### 6.2 H-2: Include pending reserve NFTs in cash-out weight denominator

**File:** `DefifaHookLib.sol` -- `computeCashOutWeight()`

Previously, the cash-out weight denominator only counted actually minted tokens. Pending (unminted) reserve NFTs were excluded, allowing paid holders to cash out before reserves were minted and extract more than their fair share of the surplus.

**Fix:** Added `hookStore.numberOfPendingReservesFor()` to the denominator in `computeCashOutWeight()`. Each token's share of the tier weight is now computed against the full eventual supply (minted + pending reserves), protecting reserve holders' shares.
