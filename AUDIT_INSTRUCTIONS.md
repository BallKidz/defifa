# Audit Instructions

Defifa is a staged prediction-game system built on Juicebox and the tiered 721 store. Game pieces are ERC-1155 balances held by `DefifaHook`. Audit it as a governance-and-settlement protocol, not only a token game.

## Audit objective

There is a billion dollars of well-meaning projects' money in the Juicebox Money Engine, growing exponentially. Your job is to hack it before anyone else. Whoever hacks it first saves/steals the money, and you are obsessed with being this winner, while also being a steward of the protocol and wanting it to keep growing safely.

Suggestions of where to look:

- let players extract more than their fair share of the game pot
- break the game-phase lifecycle or allow actions in the wrong phase
- corrupt scorecard submission, attestation, quorum, delegation, grace-period, or ratification logic
- miscompute tier cash-out weights or fee-token distribution
- leave a deployed game misconfigured through deployer mistakes

## Scope

In scope:

- `src/DefifaDeployer.sol`
- `src/DefifaGovernor.sol`
- `src/DefifaHook.sol`
- `src/DefifaTokenUriResolver.sol`
- `src/libraries/DefifaHookLib.sol`
- enums, interfaces, structs, and deployment helpers

## Start here

1. `src/DefifaGovernor.sol`
2. `src/DefifaHook.sol`
3. `src/DefifaDeployer.sol`

## Security model

High-level lifecycle:

- deploy a game as a Juicebox project
- sell outcome positions (ERC-1155 balances, one per tier) during the mint phase
- optionally allow refunds or no-contest handling
- run scorecard governance through submissions and attestations
- ratify one scorecard
- update cash-out weights so winning pieces can redeem the treasury

The contracts split responsibility as follows:

- `DefifaDeployer` launches the project and wires lifecycle configuration
- `DefifaHook` handles minting, burning, fee accounting, and game-specific cash-out math
- `DefifaGovernor` owns scorecard governance and ratification
- `DefifaTokenUriResolver` handles game-piece metadata (`uri(id)`)

## Roles and privileges

| Role | Powers | How constrained |
|------|--------|-----------------|
| Game deployer or owner path | Configure a game's initial lifecycle wiring | Must not retain hidden post-launch powers |
| Governor participants | Submit, attest to, and ratify scorecards | Must remain bounded by phase, quorum, and delegation rules |
| `DefifaHook` | Determine mint and final redeem economics | Must not over-credit players or under-account fees |

## Integration assumptions

| Dependency | Assumption | What breaks if wrong |
|------------|------------|----------------------|
| `nana-core-v6` | Treasury accounting, rulesets, and cash-out surfaces stay coherent | Pot settlement and redeem math become unsound |
| `nana-721-hook-v6` | `JB721TiersHookStore` tier config, supply, reserve, and burn accounting match Defifa's game logic when called once per position; its per-holder views are unused (they read 0 for Defifa hooks) | Voting power, supply, and cash-out weights drift |
| Deployer launch patterns | Launch-time authority fully converges to the intended game authority | Games remain misconfigured or over-privileged |

## Critical invariants

1. Pot conservation.
2. Governance phase safety.
3. Quorum and grace-period correctness.
4. Settlement determinism once a scorecard is final.
5. Fee-token and reserve correctness.

## Attack surfaces

- `DefifaGovernor` scorecard state transitions and ratification gating
- delegation, attestation, and quorum calculations
- `DefifaHook` cash-out weight and fee-token accounting
- reserve-related denominators during governance and settlement
- the ERC-1155 position layout: paid ID = tier ID vs reserve ID = `tierId + RESERVE_TOKEN_ID_OFFSET`, refund exclusion of reserve IDs after transfers, `(ids, amounts)` metadata decoding, duplicate IDs in cash-out metadata, and attestation movement in `_update`
- deployer logic that queues or fulfills lifecycle rulesets

## Accepted risks or behaviors

- Governance and settlement are intentionally phase-heavy, so timestamp and lifecycle transitions are core audit targets rather than edge cases.

## Verification

- `npm install`
- `forge fmt --check`
- `forge build --deny notes`
- `forge build --deny notes --sizes --skip "*/test/**" --skip "*/script/**"`
- `forge build --deny notes --build-info --skip "*/test/**" --skip "*/script/**"`
- `forge test --deny notes`
- `npm pack --dry-run --json`
