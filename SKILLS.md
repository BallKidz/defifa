# Defifa

## Use This File For

- Use this file when the task involves Defifa game deployment, phase transitions, scorecards, attestations, governance thresholds, fee accounting, or Defifa token URI behavior.
- Start here, then decide whether the issue is launch shape, hook runtime, governor ratification, or resolver output. Defifa looks like one game, but the code is split across those four ownership surfaces.

## Read This Next

| If you need... | Open this next |
|---|---|
| Lifecycle framing and repo boundaries | [`ARCHITECTURE.md`](./ARCHITECTURE.md) |
| Launch shape, phase queueing, and commitment fulfillment | [`src/DefifaDeployer.sol`](./src/DefifaDeployer.sol), [`script/Deploy.s.sol`](./script/Deploy.s.sol), [`script/helpers/DefifaDeploymentLib.sol`](./script/helpers/DefifaDeploymentLib.sol) |
| Minting, delegation, game-state gating, and cash-out behavior | [`src/DefifaHook.sol`](./src/DefifaHook.sol), [`src/libraries/DefifaHookLib.sol`](./src/libraries/DefifaHookLib.sol) |
| Scorecard submission, attestation power, quorum, and ratification | [`src/DefifaGovernor.sol`](./src/DefifaGovernor.sol) |
| Token URI rendering and fee-project ownership helper | [`src/DefifaTokenUriResolver.sol`](./src/DefifaTokenUriResolver.sol), [`src/DefifaProjectOwner.sol`](./src/DefifaProjectOwner.sol) |
| Runtime and operational invariants | [`references/runtime.md`](./references/runtime.md), [`references/operations.md`](./references/operations.md) |
| Governance and lifecycle proofs | [`test/DefifaGovernor.t.sol`](./test/DefifaGovernor.t.sol), [`test/DefifaGovernanceHardening.t.sol`](./test/DefifaGovernanceHardening.t.sol), [`test/DefifaNoContest.t.sol`](./test/DefifaNoContest.t.sol) |
| Fee, mint-cost, and adversarial accounting coverage | [`test/DefifaFeeAccounting.t.sol`](./test/DefifaFeeAccounting.t.sol), [`test/DefifaMintCostInvariant.t.sol`](./test/DefifaMintCostInvariant.t.sol), [`test/DefifaSecurity.t.sol`](./test/DefifaSecurity.t.sol), [`test/DefifaAdversarialQuorum.t.sol`](./test/DefifaAdversarialQuorum.t.sol) |
| Audit fixes and pinned regressions | [`test/TestAuditGaps.sol`](./test/TestAuditGaps.sol), [`test/DefifaHookRegressions.t.sol`](./test/DefifaHookRegressions.t.sol), [`test/audit/`](./test/audit/), [`test/regression/`](./test/regression/) |

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

- Start in [`src/DefifaDeployer.sol`](./src/DefifaDeployer.sol) for phase shape and commitment fulfillment, [`src/DefifaHook.sol`](./src/DefifaHook.sol) for NFT runtime and settlement behavior, and [`src/DefifaGovernor.sol`](./src/DefifaGovernor.sol) for scorecards, attestation, and ratification.
- Treat phase transitions, scorecard ratification, no-contest behavior, and fee accounting as one economic system. A local-looking change can alter final redemption outcomes.
- Defifa-specific cash-out weights and governance thresholds sit on top of `nana-721-hook-v6` and `nana-core-v6`. Verify whether a bug is game-specific before editing shared protocol code.
- When a task mentions NFT rendering or metadata, confirm whether it belongs in [`src/DefifaTokenUriResolver.sol`](./src/DefifaTokenUriResolver.sol) instead of the hook or deployer.
- If you edit phase transitions, check lifecycle, governance, and fee-accounting tests together. Defifa behavior is intentionally cross-coupled.
- If ratification, attestation, or quorum behavior changes, re-read the audit and regression tests before trusting a clean happy-path result.
