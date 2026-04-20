# Architecture

## Purpose

`defifa` builds phased prediction games on top of Juicebox and the 721 hook stack. A game is a Juicebox project with a custom NFT hook, a scorecard governor, and a deployer that launches the project and later fulfills the final economic commitments that make completion real.

If a change affects game phases, scorecard governance, cash-out weights, prize-pool distribution, or post-ratification fulfillment, this repo is the source of truth.

## System Overview

`DefifaHook`, `DefifaGovernor`, and `DefifaDeployer` form one game-state machine even though they are deployed separately. The hook owns game-piece NFT behavior, attestation delegation, and phase-sensitive cash-out weighting. The governor owns scorecard submission, attestation, quorum, and ratification. The deployer owns game launch, phased ruleset setup, and commitment fulfillment after governance decides the outcome. Generic 721 storage remains in `nana-721-hook-v6`, and canonical treasury accounting remains in `nana-core-v6`.

## Core Invariants

- The game is economically coherent only if deployer, governor, and hook agree on phase progression.
- Ratification is the only path that should install final cash-out weights for the complete phase.
- Attestation power should reflect tier semantics, not raw circulating supply; otherwise the game can be dominated by whichever outcome minted the most pieces.
- Refund, scoring, complete, and no-contest behavior must be mutually coherent. A phase bug can strand funds or let users claim from the wrong envelope.
- The deployer's post-ratification fulfillment path is mandatory economics, not optional housekeeping.
- Completion-phase cash outs must account for already redeemed tokens and pending reserve dilution correctly.

## Modules

| Module | Responsibility | Notes |
| --- | --- | --- |
| `DefifaDeployer` | Launches games, sets phased rulesets, clones hooks, initializes governance, and fulfills commitments | Launch-time and completion-time runtime surface |
| `DefifaHook` | NFT minting, delegation, game-phase-aware cash-out behavior, and completion claims | Main game-facing runtime hook |
| `DefifaGovernor` | Scorecard submission, attestation weighting, quorum, grace periods, and ratification | Governance surface |
| `DefifaHookLib` | Shared validation and weight math extracted from the hook | Size-management helper, not an authority boundary |
| `DefifaTokenUriResolver` | Dynamic token metadata and SVG rendering | Metadata layer |
| `DefifaProjectOwner` | Irreversible project-owner sink that preserves selected Defifa operator permissions | Governance-sensitive helper |

## Trust Boundaries

- Canonical treasury accounting, project ownership, rulesets, terminals, and payout mechanics remain in `nana-core-v6`.
- Tier storage, reserve minting mechanics, and generic ERC-721 behavior come from `nana-721-hook-v6`.
- `DefifaHookLib` is a bytecode-management extraction, not a separate trust boundary.
- `DefifaGovernor` is trusted to ratify scorecards only through its quorum, grace-period, and timelock rules.
- `DefifaDeployer` is trusted to convert governance output into the final completion envelope; the game does not settle correctly without that step.

## Critical Flows

### Launch Game

```text
creator
  -> deployer validates mint/refund/start timings
  -> deployer predicts the game project ID and clones a game hook deterministically
  -> deployer builds phased rulesets and optional fee splits
  -> controller launches the project
  -> governor is initialized for the game
  -> hook ownership and project ownership are transferred into the intended long-term shape
```

### Mint During Open Play

```text
player
  -> pays the game project during the mint window
  -> hook mints the selected game-piece NFT tier
  -> delegation state and total mint-cost accounting are updated
  -> reserved mints and pending reserves continue to affect later completion claims
```

### Refund Or No-Contest Exit

```text
holder
  -> cashes out during the refund-compatible phase
  -> hook computes cash-out count from game phase and cumulative mint price
  -> terminal settles reclaim value
  -> hook burns NFTs and applies the phase-specific redemption rules
```

### Scorecard Governance

```text
attester or proposer
  -> governor accepts a scorecard candidate
  -> attestation power is computed from tier-relative holdings
  -> quorum, grace period, and timelock gates are enforced
  -> governor ratifies exactly one winning scorecard
```

### Fulfill Commitments And Complete

```text
authorized completion path
  -> deployer reads the ratified outcome
  -> deployer fulfills the game's promised commitments and queues the final ruleset
  -> hook installs final cash-out weights
  -> holders burn pieces during complete phase to reclaim their weighted share of the pot and fee-token side claims
```

## Accounting Model

This repo does not replace `nana-core-v6` treasury accounting. Its critical economic state is:

- phase timestamps and game ops data in the deployer
- scorecard and attestation state in the governor
- tier cash-out weights, redeemed-token tracking, mint-cost totals, and delegation state in the hook

The hook's completion math is intentionally phase-sensitive:

- before completion, cash-out behavior is refund or fallback oriented
- after ratification and fulfillment, cash-out weights become the game outcome
- completion claims use minted cost, redeemed amount tracking, and pending reserve-aware dilution logic together

## Security Model

- The primary risk is semantic drift across hook, governor, and deployer. Reviewing only one of them is usually insufficient.
- Ratification and fulfillment are separate steps; a ratified scorecard without correct fulfillment still leaves the game economically unfinished.
- Attestation weighting is part of game fairness, not just governance plumbing.
- Pending reserves and reserved-mint behavior affect both quorum fairness and completion-time claim dilution.
- Phase transitions are safety-critical. A timing or phase bug can enable refunds, scoring, or completion in the wrong order.
- `DefifaProjectOwner` is intentionally one-way once a project NFT is sent there.

## Safe Change Guide

- Review `DefifaHook`, `DefifaGovernor`, and `DefifaDeployer` together for any nontrivial change.
- If phase semantics change, re-check mint, refund, scoring, ratification, fulfillment, and completion cash-out behavior together.
- If attestation math changes, inspect tier semantics, delegation, quorum, and scorecard ratification thresholds together.
- If completion claim math changes, re-check redeemed tracking, pending reserve dilution, and fee-token side claims in the same review.
- Keep `DefifaHookLib` behavior synchronized with hook storage assumptions; it exists for bytecode size, not for independent evolution.
- Do not move generic 721 or terminal behavior into Defifa just because the game relies on it heavily.

## Canonical Checks

- governor state transitions and scorecard handling:
  `test/DefifaGovernor.t.sol`
- fulfillment and ratification coupling:
  `test/regression/FulfillmentBlocksRatification.t.sol`
- pending reserve effects on completion fairness:
  `test/audit/PendingReserveSnapshotBypass.t.sol`

## Source Map

- `src/DefifaDeployer.sol`
- `src/DefifaGovernor.sol`
- `src/DefifaHook.sol`
- `src/libraries/DefifaHookLib.sol`
- `src/DefifaTokenUriResolver.sol`
- `test/DefifaGovernor.t.sol`
- `test/DefifaHookRegressions.t.sol`
- `test/DefifaFeeAccounting.t.sol`
- `test/regression/FulfillmentBlocksRatification.t.sol`
- `test/audit/PendingReserveSnapshotBypass.t.sol`
