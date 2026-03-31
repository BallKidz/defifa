# Audit Instructions

Defifa is a staged prediction-game system built on Juicebox and the 721 hook stack. The main risks are governance correctness, treasury settlement, and cash-out weight integrity.

## Objective

Find issues that:
- let players extract more than their fair share of the game pot
- break the game-phase lifecycle or let actions occur in the wrong phase
- corrupt scorecard submission, attestation, quorum, grace-period, or ratification logic
- miscompute tier cash-out weights or fee-token distribution
- let deployment or ownership helpers leave a game misconfigured

## Scope

In scope:
- `src/DefifaDeployer.sol`
- `src/DefifaGovernor.sol`
- `src/DefifaHook.sol`
- `src/DefifaProjectOwner.sol`
- `src/DefifaTokenUriResolver.sol`
- `src/libraries/DefifaHookLib.sol`
- `src/interfaces/`, `src/structs/`, and `src/enums/`
- deployment scripts in `script/`

Key integrations:
- `nana-core-v6`
- `nana-721-hook-v6`
- deployer and ownership helper patterns shared across the ecosystem

## System Model

High-level lifecycle:
- deploy a game as a Juicebox project
- sell outcome NFTs during mint phase
- optionally allow refunds or no-contest handling
- run scorecard governance through submissions and attestations
- ratify a scorecard
- update cash-out weights so winning pieces can redeem the treasury

The contracts split responsibility as follows:
- `DefifaDeployer`: project launch and lifecycle orchestration
- `DefifaHook`: minting, burning, and game-specific cash-out accounting
- `DefifaGovernor`: scorecard governance and ratification
- `DefifaTokenUriResolver`: game NFT metadata

## Critical Invariants

1. Pot conservation
Total redeemable value across all settled tiers must not exceed the game treasury after applying intended fees.

2. Governance phase safety
Submission, attestation, ratification, no-contest, and refund paths must be reachable only in the intended lifecycle windows.

3. Quorum and grace-period correctness
Attestation power, delegation, quorum thresholds, and grace-period timing must not be manipulable to ratify an invalid scorecard early or indefinitely block a valid one.

4. Settlement determinism
Once the winning scorecard is finalized, the resulting cash-out weights must match the intended outcome and remain internally consistent.

5. No fee-token dilution bugs
Fee accounting and reserve-related side effects must not dilute players or over-credit non-paying participants.

## Threat Model

Prioritize:
- whale participants trying to dominate attestation power
- players exploiting pending reserves, delegation, or snapshot timing
- callers trying to ratify with partially completed commitments
- phase-boundary and timestamp races
- settlement paths that assume external payout success

## Hotspots

- `DefifaGovernor` scorecard state transitions
- `DefifaHook` cash-out weight and fee-token accounting
- reserve-related denominators during governance and settlement
- deployer logic that queues or fulfills lifecycle rulesets
- any low-level call used during ratification or fulfillment
- token URI or metadata logic only insofar as it can desync governance or settlement assumptions

## Build And Verification

Standard workflow:
- `npm install`
- `forge build`
- `forge test`

The current tests focus on:
- quorum hardening
- no-contest and refund handling
- pending reserve dilution
- fee accounting
- regressions around attestation delegation and grace-period bypass

The best findings in this repo usually demonstrate either treasury over-redemption or a governance state transition that should be impossible.
