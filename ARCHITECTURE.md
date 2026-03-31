# Architecture

## Purpose

`defifa-collection-deployer-v6` builds prediction games on top of Juicebox and the 721 tiers hook. Each game is a project with phased rulesets, a hook that mints and cashes out game-piece NFTs, and a governor that ratifies scorecards which decide how the prize pool is distributed.

## Boundaries

- `DefifaHook` owns game-piece behavior, delegation, and cash-out math.
- `DefifaGovernor` owns scorecard submission, attestation, quorum, and ratification.
- `DefifaDeployer` owns game launch and post-ratification commitment fulfillment.
- Generic tier storage and terminal accounting stay in `nana-721-hook-v6` and `nana-core-v6`.

## Main Components

| Component | Responsibility |
| --- | --- |
| `DefifaDeployer` | Launches phased projects, clones hooks, initializes the governor, and fulfills commitments |
| `DefifaHook` | ERC-721 game pieces, attestation delegation, custom cash-out weighting, and game-state aware behavior |
| `DefifaGovernor` | Scorecard proposals, attestations, quorum checks, grace periods, and ratification |
| `DefifaHookLib` | Shared validation and weight math extracted to keep the hook within size limits |
| `DefifaTokenUriResolver` | Dynamic token metadata and SVG rendering |
| `DefifaProjectOwner` | Lock helper for the fee project |

## Runtime Model

```text
creator
  -> DefifaDeployer launches a project with staged rulesets
players
  -> mint tiered NFTs during the mint window
holders
  -> optionally refund during the refund window
attesters
  -> submit and attest to scorecards during scoring
governor
  -> ratifies the winning scorecard after quorum and grace-period checks
holders
  -> cash out NFTs for their share of the prize pool during completion
```

## Critical Invariants

- Delegation and attestation power must stay aligned with tier semantics; a scorecard system that can be inflated by supply alone breaks the game.
- Ratification is the only path that should install final cash-out weights.
- Refund, scoring, complete, and no-contest phases must remain mutually coherent. If phase transitions drift, funds get stuck.
- The deployer's commitment-fulfillment logic is part of game completion, not optional bookkeeping.

## Where Complexity Lives

- The game is split across hook, governor, and deployer contracts, but users experience it as one state machine.
- Scorecard weighting, attestation accounting, and phase transitions are tightly coupled.
- Completion logic is economically sensitive because it combines prize distribution with fee fulfillment.

## Dependencies

- `nana-721-hook-v6` for tiered NFT infrastructure
- `nana-core-v6` for phased rulesets, terminals, and payout mechanics
- Juicebox governance and permission surfaces for project ownership and split updates

## Safe Change Guide

- Treat phase logic, governor logic, and hook cash-out logic as one system.
- If you change scorecard validation, also inspect attestation weighting and ratification thresholds.
- Keep `DefifaHookLib` and hook storage assumptions in sync; library extraction is for size, not for a separate trust boundary.
- Do not move generic 721 behavior into Defifa just because the game uses it heavily.
- When in doubt, trace an end-to-end game lifecycle rather than auditing one contract in isolation.
