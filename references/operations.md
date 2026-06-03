# Defifa Operations

Use this file when the task is about launch config, phase timing, governance windows, or deciding whether a symptom is operational drift or runtime logic.

## Deployment surface

- [`src/DefifaDeployer.sol`](../src/DefifaDeployer.sol) is the first stop for launch-time config, phase queueing, and post-ratification fulfillment.
- [`script/Deploy.s.sol`](../script/Deploy.s.sol) and [`script/helpers/DefifaDeploymentLib.sol`](../script/helpers/DefifaDeploymentLib.sol) are the deployment entrypoints when the task is about current wiring rather than game mechanics.
- [`src/structs/`](../src/structs/) and [`src/enums/`](../src/enums/) define launch data, phase types, and other inputs that often drift from remembered assumptions.

## Change checklist

- If you edit lifecycle timing, verify phase transitions, no-contest triggers, and the governor's attestation windows together.
- If you edit hook settlement logic, re-check fee accounting and mint-cost invariants.
- If you touch governance thresholds or attestation behavior, inspect the governor tests before assuming the change is local.
- If you touch token metadata or rendering, verify whether the bug belongs in the resolver instead of settlement code.
- If you touch anything supply-sensitive, inspect the review tests around pending reserves and quorum before relying on current intuition.

## Common failure modes

- Game-state issue is blamed on the hook even though the deployer queued the wrong phase or timing.
- Governance behavior looks wrong, but the real issue is stale launch configuration.
- Settlement changes accidentally affect fee distribution or redemption accounting.
- Resolver issues get misdiagnosed as hook or governor problems because they surface through NFTs.
- Review-style failures around reserve dilution or attestation counting are treated as isolated math issues even though they cross deployer, hook, and governor boundaries.

## Useful proof points

- [`test/Fork.t.sol`](../test/Fork.t.sol) for live-integration assumptions.
- [`test/TestRegressionGaps.sol`](../test/TestRegressionGaps.sol) and [`test/TestQALastMile.t.sol`](../test/TestQALastMile.t.sol) for pinned edge cases.
- [`test/BWAFunctionComparison.t.sol`](../test/BWAFunctionComparison.t.sol) and [`test/DefifaUSDC.t.sol`](../test/DefifaUSDC.t.sol) when currency or accounting context matters.
- [`test/regression/`](../test/regression/) when a change touches pending reserves, registry alignment, quorum griefing, or double-counting.
