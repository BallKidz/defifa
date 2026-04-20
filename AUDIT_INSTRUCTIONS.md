# Audit Instructions

Defifa is a staged prediction-game system built on Juicebox and the tiered 721 stack. Audit it as a governance-and-settlement protocol, not just an NFT game.

## Audit Objective

Find issues that:

- let players extract more than their fair share of the game pot
- break the game-phase lifecycle or allow actions in the wrong phase
- corrupt scorecard submission, attestation, quorum, delegation, grace-period, or ratification logic
- miscompute tier cash-out weights or fee-token distribution
- leave a deployed game misconfigured through deployer or owner-helper mistakes

## Scope

In scope:

- `src/DefifaDeployer.sol`
- `src/DefifaGovernor.sol`
- `src/DefifaHook.sol`
- `src/DefifaProjectOwner.sol`
- `src/DefifaTokenUriResolver.sol`
- `src/libraries/DefifaHookLib.sol`
- enums, interfaces, structs, and deployment helpers

## Start Here

1. `src/DefifaGovernor.sol`
2. `src/DefifaHook.sol`
3. `src/DefifaDeployer.sol`
4. `src/DefifaProjectOwner.sol`

## Security Model

High-level lifecycle:

- deploy a game as a Juicebox project
- sell outcome NFTs during the mint phase
- optionally allow refunds or no-contest handling
- run scorecard governance through submissions and attestations
- ratify one scorecard
- update cash-out weights so winning pieces can redeem the treasury

The contracts split responsibility as follows:

- `DefifaDeployer` launches the project and wires lifecycle configuration
- `DefifaHook` handles minting, burning, fee accounting, and game-specific cash-out math
- `DefifaGovernor` owns scorecard governance and ratification
- `DefifaProjectOwner` acts as a project-owner helper where governance needs a stable admin surface
- `DefifaTokenUriResolver` handles game NFT metadata

## Roles And Privileges

| Role | Powers | How constrained |
|------|--------|-----------------|
| Game deployer or owner path | Configure a game's initial lifecycle and helper wiring | Must not retain hidden post-launch powers |
| Governor participants | Submit, attest to, and ratify scorecards | Must remain bounded by phase, quorum, and delegation rules |
| `DefifaHook` | Determine mint and final redeem economics | Must not over-credit players or under-account fees |
| Project owner helper | Stand in for project ownership where configured | Must not diverge from the intended governance authority |

## Integration Assumptions

| Dependency | Assumption | What breaks if wrong |
|------------|------------|----------------------|
| `nana-core-v6` | Treasury accounting, rulesets, and cash-out surfaces stay coherent | Pot settlement and redeem math become unsound |
| `nana-721-hook-v6` | Tier issuance and reserve behavior match Defifa's game logic | Voting power, supply, and cash-out weights drift |
| Owner-helper and deployer patterns | Launch-time authority fully converges to the intended game authority | Games remain misconfigured or over-privileged |

## Critical Invariants

1. Pot conservation.
2. Governance phase safety.
3. Quorum and grace-period correctness.
4. Settlement determinism once a scorecard is final.
5. Fee-token and reserve correctness.

## Attack Surfaces

- `DefifaGovernor` scorecard state transitions and ratification gating
- delegation, attestation, and quorum calculations
- `DefifaHook` cash-out weight and fee-token accounting
- reserve-related denominators during governance and settlement
- deployer logic that queues or fulfills lifecycle rulesets

## Accepted Risks Or Behaviors

- Governance and settlement are intentionally phase-heavy, so timestamp and lifecycle transitions are core audit targets rather than edge cases.

## Verification

- `npm install`
- `forge build`
- `forge test`
