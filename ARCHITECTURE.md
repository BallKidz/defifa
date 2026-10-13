# Architecture

## Purpose

`defifa` builds phased prediction games on top of Juicebox and the 721 hook stack. A game is a Juicebox project with a custom NFT hook, a scorecard governor, and a deployer that launches the project and later fulfills the economic commitments that make completion real.

Defifa ships two game types side by side. `DefifaHook` is the ERC-721 game, one NFT per position. `Defifa1155Hook` is the ERC-1155 game, one balance per tier, so a payment mints a count per tier in one transfer. A launcher picks the game type by picking the deployer.

## System overview

`DefifaHook`, `DefifaGovernor`, and `DefifaDeployer` form one game-state machine even though they are deployed separately. The hook owns game-piece NFT behavior, attestation delegation, and phase-sensitive cash-out weighting. The governor owns scorecard submission, attestation, quorum, and ratification. The deployer owns game launch, phased ruleset setup, and commitment fulfillment after governance decides the outcome.

The deployer and governor are hook-agnostic. They call the hook by selector, and both hooks expose the selectors they use (`initialize`, `store`, `currentSupplyOfTier`, `adjustedPendingReservesFor`, `TOTAL_CASHOUT_WEIGHT`, `setTierCashOutWeightsTo`, and the attestation views), gated by `test/DefifaHookParity.t.sol`. Deployment is one `DefifaDeployer` plus `DefifaGovernor` pair per hook implementation, with the governor owned by its deployer. Both pairs share one `DefifaTiersHookStore` and one `DefifaTokenUriResolver`.

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
| `DefifaHook` | NFT minting, delegation, game-phase-aware cash-out behavior, and completion claims | ERC-721 game hook |
| `Defifa1155Hook` | ERC-1155 position minting (one balance per tier), delegation, game-phase-aware cash-out behavior, and completion claims | ERC-1155 game hook |
| `DefifaGovernor` | Scorecard submission, attestation weighting, quorum, grace periods, and ratification | Governance surface |
| `DefifaHookLib` | Shared validation and weight math extracted from the hook, including the per-tier cash-out weight (`computeTierCashOutWeight`) and fee-token claim share (`tokensClaimFor`) both hooks use | Bytecode-management helper |
| `Defifa1155HookLib` | ERC-1155 ID and amount logic (`tierIdOf`, `RESERVE_TOKEN_ID_OFFSET`, count-based attestation units, `(ids, amounts)` cash-out weight, mint price, claims, and burns); calls `DefifaHookLib` for shared rules | Bytecode-management helper |
| `DefifaTiersHookStore` | `JB721TiersHookStore`, unchanged, plus count-based `recordMintCounts`, `recordBurnCounts` and `recordTransferForTier(tierId, from, to, count)` | Shared by both game types; required by the ERC-1155 hook |
| `DefifaTokenUriResolver` | Dynamic token metadata and SVG rendering | Shared metadata layer; resolves the tier by ERC-165 (an ERC-1155 hook via `tierIdOf`, a 721 hook via `store.tierIdOfToken`) |

## Trust boundaries

- Canonical treasury accounting, project ownership, rulesets, terminals, and payout mechanics remain in `nana-core-v6`.
- Tier storage, reserve minting mechanics, and generic ERC-721 behavior come from `nana-721-hook-v6`.
- Both game types record tiers in `DefifaTiersHookStore`, the upstream store plus count-based records that must match the per-position originals (`test/DefifaTiersHookStore.t.sol`). ERC-1155 position ownership is `Defifa1155Hook`'s own OpenZeppelin `ERC1155` state, mirrored per tier in the store's holder views.
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
  -> ERC-721 hook mints one game-piece NFT per selected tier entry
  -> ERC-1155 hook records counts once per tier in the store, then mints one balance per selected tier; the ERC-1155 receiver check runs last
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
  -> holders burn pieces during complete phase to reclaim their weighted share of the pot
```

## ERC-1155 position model

Positions in an ERC-1155 game are balances, one per tier, so a payment mints a count per tier in one transfer. Per-position ERC-721 mints cost about 47k gas each, which caps one entry near 160 positions under Base's 2^24 per-transaction gas cap with the SDK's 2x gas headroom. Measured in `test/erc1155/DefifaERC1155.t.sol`, a pay of 160 positions in one tier costs about 443k gas and 1,000 positions across 8 tiers about 1.63M. The store records counts once per tier, so cost grows with the number of tiers, not positions.

- Paid positions use token ID = tier ID. Reserve-minted positions use `tierId + RESERVE_TOKEN_ID_OFFSET` (`1 << 16`), so refunds still reject them after transfers. `tierIdOf(id)` maps either ID back to its tier.
- Both IDs count toward tier supply, attestation units, and cash-out weight. Attestation units are hook balances times the tier's `votingUnits`.
- Pay metadata: `(address attestationDelegate, uint16[] tierIds, uint256[] counts)`, tier IDs strictly ascending. Cash-out metadata: `(uint256[] tokenIds, uint256[] amounts)`.
- Mints run the ERC-1155 receiver acceptance check (`onERC1155Received` / `onERC1155BatchReceived`) after every state change, so a contract beneficiary that does not accept ERC-1155 makes the pay or reserve mint revert. The 721 hook's `_mint` calls no receiver. Transfers are standard safe transfers that call `onERC1155Received` / `onERC1155BatchReceived`. Approvals are `setApprovalForAll` only.
- Errors are prefixed `Defifa1155Hook_`; shared-rule errors raised in `DefifaHookLib` keep the `DefifaHook_` prefix (for example `DefifaHook_BadTierOrder`).

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
- A change to game rules usually belongs in `DefifaHookLib` so both hooks keep one formula; check `Defifa1155Hook` and `DefifaHook` together, and keep the selectors the shared deployer, governor and resolver call (`test/DefifaHookParity.t.sol`).
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
- the ERC-1155 game: `test/erc1155/` (same file names as the 721 suite), including `test/erc1155/DefifaERC1155.t.sol`
- both hooks expose the selectors the shared deployer, governor and resolver call:
  `test/DefifaHookParity.t.sol`
- count-based store records match the per-position originals:
  `test/DefifaTiersHookStore.t.sol`

## Source map

- `src/DefifaDeployer.sol`
- `src/DefifaGovernor.sol`
- `src/DefifaHook.sol`
- `src/Defifa1155Hook.sol`
- `src/libraries/DefifaHookLib.sol`
- `src/libraries/Defifa1155HookLib.sol`
- `src/DefifaTiersHookStore.sol`
- `src/DefifaTokenUriResolver.sol`
- `test/DefifaGovernor.t.sol`
- `test/DefifaHookRegressions.t.sol`
- `test/DefifaFeeAccounting.t.sol`
- `test/regression/FulfillmentBlocksRatification.t.sol`
- `test/regression/PendingReserveSnapshotBypass.t.sol`
- `test/erc1155/DefifaERC1155.t.sol`
- `test/DefifaHookParity.t.sol`
- `test/DefifaTiersHookStore.t.sol`
