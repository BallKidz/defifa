# Defifa

## Use This File For

- Use this file when the task involves Defifa game deployment, phase transitions, scorecards, attestations, governance thresholds, fee accounting, or Defifa token URI behavior.
- Start here, then open the deployer, hook, governor, resolver, or tests based on which phase or subsystem is relevant.

## Read This Next

| If you need... | Open this next |
|---|---|
| Repo overview and lifecycle framing | [`README.md`](./README.md), [`ARCHITECTURE.md`](./ARCHITECTURE.md) |
| Deployment and phase scheduling | [`src/DefifaDeployer.sol`](./src/DefifaDeployer.sol), [`script/Deploy.s.sol`](./script/Deploy.s.sol) |
| Cash-out and game-phase behavior | [`src/DefifaHook.sol`](./src/DefifaHook.sol), [`src/libraries/`](./src/libraries/) |
| Governance and scorecards | [`src/DefifaGovernor.sol`](./src/DefifaGovernor.sol) |
| Project-owner or token URI behavior | [`src/DefifaProjectOwner.sol`](./src/DefifaProjectOwner.sol), [`src/DefifaTokenUriResolver.sol`](./src/DefifaTokenUriResolver.sol) |
| Security, lifecycle, and regressions | [`test/DefifaGovernor.t.sol`](./test/DefifaGovernor.t.sol), [`test/DefifaNoContest.t.sol`](./test/DefifaNoContest.t.sol), [`test/DefifaFeeAccounting.t.sol`](./test/DefifaFeeAccounting.t.sol), [`test/regression/`](./test/regression/) |

## Repo Map

| Area | Where to look |
|---|---|
| Main contracts | [`src/`](./src/) |
| Libraries, enums, interfaces, and structs | [`src/libraries/`](./src/libraries/), [`src/enums/`](./src/enums/), [`src/interfaces/`](./src/interfaces/), [`src/structs/`](./src/structs/) |
| Scripts | [`script/`](./script/) |
| Tests | [`test/`](./test/) |

## Purpose

Defifa is an on-chain prediction game system built on Juicebox. This repo packages game launch, phased lifecycle control, scorecard governance, and NFT-based settlement into a single game-specific deployment surface.

## Reference Files

- Open [`references/runtime.md`](./references/runtime.md) when you need the game lifecycle, contract roles, settlement path, or the main economic and governance invariants.
- Open [`references/operations.md`](./references/operations.md) when you need deployment and phase-queueing behavior, test breadcrumbs, or the common sources of stale operational assumptions.

## Working Rules

- Start in [`src/DefifaDeployer.sol`](./src/DefifaDeployer.sol) for lifecycle and queueing behavior, but verify hook and governor assumptions before treating a game-state issue as deployer-only.
- Treat scorecard ratification, no-contest behavior, and fee accounting as treasury-sensitive. Small changes there can alter settlement outcomes materially.
- When a task mentions NFT rendering or metadata, confirm whether it belongs in [`src/DefifaTokenUriResolver.sol`](./src/DefifaTokenUriResolver.sol) instead of the hook or deployer.
- If you edit phase transitions, check both lifecycle tests and fee/governance tests. Defifa behavior is cross-coupled.
