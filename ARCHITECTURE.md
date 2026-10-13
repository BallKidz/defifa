# Architecture

## Purpose

`defifa` builds phased prediction games on top of Juicebox and the 721 tier store. A game is a Juicebox project with a custom ERC-1155 game-piece hook, a scorecard governor, and a deployer that launches the project and later fulfills the economic commitments that make completion real.

## System overview

`DefifaHook`, `DefifaGovernor`, and `DefifaDeployer` form one game-state machine even though they are deployed separately. The hook owns game-piece position balances, attestation delegation, and phase-sensitive cash-out weighting. The governor owns scorecard submission, attestation, quorum, and ratification. The deployer owns game launch, phased ruleset setup, and commitment fulfillment after governance decides the outcome.

## Core invariants

- The game is economically coherent only if deployer, governor, and hook agree on phase progression.
- Ratification is the only path that should install final cash-out weights for the complete phase.
- Attestation power should reflect tier semantics, not raw circulating supply.
- Refund, scoring, complete, and no-contest behavior must be mutually coherent.
- The deployer's post-ratification fulfillment path is mandatory economics, not optional housekeeping.
- Completion-phase cash outs must account for already redeemed tokens and pending reserve dilution correctly.

## Modules

| Module | Responsibility | Notes |
| --- | --- | --- |
| `DefifaDeployer` | Launches games, sets phased rulesets, clones hooks, resolves ERC-2771 launch callers, initializes governance, and fulfills commitments | Launch-time and completion-time runtime surface |
| `DefifaHook` | ERC-1155 position minting, delegation, game-phase-aware cash-out behavior, and completion claims | Main game-facing runtime hook |
| `DefifaGovernor` | Scorecard submission, attestation weighting, quorum, grace periods, and ratification | Governance surface |
| `DefifaHookLib` | Shared validation and weight math extracted from the hook | Bytecode-management helper |
| `DefifaTokenUriResolver` | Dynamic token metadata and SVG rendering | Metadata layer |

## Trust boundaries

- Canonical treasury accounting, project ownership, rulesets, terminals, and payout mechanics remain in `nana-core-v6`.
- Tier config, supply, reserve, burn, and per-holder tier accounting come from `DefifaTiersHookStore`: `nana-721-hook-v6`'s `JB721TiersHookStore`, unchanged, plus count-based `recordMintCounts`, `recordBurnCounts` and `recordTransferForTier(tierId, from, to, count)` so the hook records once per tier. Position ownership is the hook's own ERC-1155 (OpenZeppelin `ERC1155`) state, mirrored per tier in the store's holder views.
- `DefifaGovernor` is trusted to ratify scorecards only through its quorum, grace-period, and timelock rules.
- `DefifaDeployer` is trusted to convert governance output into the final completion envelope.

## Critical flows

### Launch game

```text
creator
  -> deployer validates mint/refund/start timings
  -> deployer resolves the ERC-2771 caller and advertises that account as the creation-fee payer
  -> deployer predicts the game project ID and clones a game hook deterministically
  -> deployer builds phased rulesets and optional fee splits
  -> deployer reserves the game project via createFor
  -> controller launches the project
  -> governor is initialized for the game
  -> hook ownership and project ownership are transferred into the intended long-term shape
```

### Mint during open play

```text
player
  -> pays the game project during the mint window
  -> hook records each position in the store, then mints one ERC-1155 balance per selected tier (no receiver callback)
  -> delegation state and total mint-cost accounting are updated
  -> reserved mints and pending reserves continue to affect later completion claims
```

### Scorecard governance

```text
attester or proposer
  -> governor accepts a scorecard candidate
  -> attestation power is computed from tier-relative holdings
  -> quorum, grace period, and timelock gates are enforced
  -> governor ratifies exactly one winning scorecard
```

### Fulfill commitments and complete

```text
authorized completion path
  -> deployer reads the ratified outcome
  -> deployer fulfills the game's promised commitments and queues the final ruleset
  -> hook installs final cash-out weights
  -> holders burn position balances during complete phase to reclaim their weighted share of the pot
```

## Position model

Positions are ERC-1155 balances, one balance per tier, so a payment mints a count per tier in one transfer. Per-position ERC-721 mints cost about 47k gas each, which capped one entry near 160 positions under Base's 2^24 per-transaction gas cap with the SDK's 2x gas headroom. Measured in `test/DefifaERC1155.t.sol`, a pay of 160 positions in one tier costs about 443k gas and 1,000 positions across 8 tiers about 1.63M. The store records counts once per tier, so cost grows with the number of tiers, not positions.

- Paid positions use token ID = tier ID. Reserve-minted positions use `tierId + RESERVE_TOKEN_ID_OFFSET` (`1 << 16`), so refunds still exclude them after transfers. `tierIdOf(id)` maps either ID back to its tier.
- Both IDs count toward tier supply, attestation units, and cash-out weight. Attestation units are hook balances times the tier's `votingUnits`.
- Pay metadata: `(address attestationDelegate, uint16[] tierIds, uint256[] counts)`, tier IDs strictly ascending. Cash-out metadata: `(uint256[] tokenIds, uint256[] amounts)`.
- Mints skip the ERC-1155 receiver callback, as the earlier 721 `_mint` did, so no external call runs inside pay or cash-out. Transfers are standard safe transfers that call `onERC1155Received` / `onERC1155BatchReceived`. Approvals are `setApprovalForAll` only.
- Games deployed before this change keep their ERC-721 hook; the ERC-1155 layout needs a new hook implementation and deployer deployment.

## Accounting model

This repo does not replace `nana-core-v6` treasury accounting. Its critical economic state is:

- phase timestamps and game ops data in the deployer
- scorecard and attestation state in the governor
- tier cash-out weights, redeemed-token tracking, mint-cost totals, and delegation state in the hook

The hook's completion math is intentionally phase-sensitive:

- before completion, cash-out behavior is refund or fallback oriented
- after ratification and fulfillment, cash-out weights become the game outcome
- completion claims use minted cost, redeemed tracking, and pending-reserve-aware dilution together

## Security model

- The primary risk is semantic drift across hook, governor, and deployer.
- Ratification and fulfillment are separate steps; a ratified scorecard without correct fulfillment still leaves the game economically unfinished.
- Attestation weighting is part of game fairness, not only governance plumbing.
- Pending reserves and reserved-mint behavior affect both quorum fairness and completion-time claim dilution.
- Phase transitions are safety-critical. A timing bug can enable refunds, scoring, or completion in the wrong order.

## Safe change guide

- Review `DefifaHook`, `DefifaGovernor`, and `DefifaDeployer` together for any nontrivial change.
- If phase semantics change, re-check mint, refund, scoring, ratification, fulfillment, and completion cash-out behavior together.
- If attestation math changes, inspect tier semantics, delegation, quorum, and ratification thresholds together.
- If completion claim math changes, re-check redeemed tracking, pending reserve dilution, and fee-token side claims in the same review.

## Canonical checks

- governor state transitions and scorecard handling:
  `test/DefifaGovernor.t.sol`
- fulfillment and ratification coupling:
  `test/regression/FulfillmentBlocksRatification.t.sol`
- pending reserve effects on completion fairness:
  `test/regression/PendingReserveSnapshotBypass.t.sol`

## Source map

- `src/DefifaDeployer.sol`
- `src/DefifaGovernor.sol`
- `src/DefifaHook.sol`
- `src/libraries/DefifaHookLib.sol`
- `src/DefifaTokenUriResolver.sol`
- `test/DefifaGovernor.t.sol`
- `test/DefifaHookRegressions.t.sol`
- `test/DefifaFeeAccounting.t.sol`
- `test/regression/FulfillmentBlocksRatification.t.sol`
- `test/regression/PendingReserveSnapshotBypass.t.sol`
