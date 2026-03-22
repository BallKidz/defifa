# defifa-collection-deployer-v6 Changelog (v5 → v6)

This document describes the changes between `defifa-collection-deployer` (v5) and `defifa-collection-deployer-v6` (v6). Defifa is an on-chain prediction game framework built on Juicebox where players mint NFTs representing outcomes, a governor ratifies scorecard distributions, and winners burn NFTs to claim proportional shares.

## Summary

- **V6 hook migration**: All 721 hook interactions updated from `nana-721-hook-v5` to `nana-721-hook-v6`, including the new tier splits system and `splitPercent` field in `JB721TierConfig`.
- **Dependency modernization**: Core, permission IDs, address registry, and ownable dependencies all updated to v6. New ecosystem dependencies on `croptop-core-v6` and `revnet-core-v6`.
- **Error naming standardized**: Error names changed from bare names (e.g., `InvalidCashoutWeights`) to contract-prefixed names (e.g., `DefifaHook_InvalidCashoutWeights`).
- **Cash out hook spec gains `noop` field**: `beforeCashOutRecordedWith` now returns `noop=false` in all specifications, ensuring the terminal always calls the hook callback.
- **Game lifecycle unchanged**: The core game phases (COUNTDOWN → MINT → REFUND → SCORING → COMPLETE) and governance model (50% quorum, scorecard ratification) remain identical.

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

Compiler remains at `pragma solidity 0.8.23` (not bumped to 0.8.26 unlike most other v6 repos).

### 1.5 721 Hook API Changes

Inherited from `nana-721-hook-v6`:
- `cashOutWeightOf()` and `totalCashOutWeight()` signatures simplified (removed `JBBeforeCashOutRecordedContext` parameter)
- `pricingContext()` returns 2 values instead of 3
- `JB721TierConfig` gained `splitPercent` and `splits` fields
- `JB721TiersHookFlags` gained `issueTokensForSplits` field

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

---

## 4. Migration Table

| Aspect | v5 | v6 |
|--------|----|----|
| Core dependency | `@bananapus/core-v5` | `@bananapus/core-v6` |
| 721 hook dependency | `@bananapus/721-hook-v5` | `@bananapus/721-hook-v6` |
| Permission IDs | Not a direct dependency | `@bananapus/permission-ids-v6` |
| Error naming | Bare names | Contract-prefixed names |
| `JBCashOutHookSpecification` | No `noop` field | `noop=false` on all specs |
| Solidity version | `0.8.23` | `0.8.23` (unchanged) |
| Game lifecycle | COUNTDOWN->MINT->REFUND->SCORING->COMPLETE | Identical |
| Governance model | 50% quorum, tier-delegated | Identical |

> **Cross-repo impact**: Uses `nana-721-hook-v6` for all tier management and cashout weight distribution. The `nana-permission-ids-v6` ID shifts affect any hardcoded permission checks. Not yet included in `deploy-all-v6` deployment phases (awaiting source updates).
