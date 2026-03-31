# Defifa Runtime

## Contract Roles

- [`src/DefifaDeployer.sol`](../src/DefifaDeployer.sol) launches games, manages phase progression, fulfills commitments, and triggers safety exits such as no-contest.
- [`src/DefifaHook.sol`](../src/DefifaHook.sol) manages the NFT game pieces, delegation, and settlement-side cash-out behavior.
- [`src/DefifaGovernor.sol`](../src/DefifaGovernor.sol) handles scorecard submission, attestation, quorum, and ratification.
- [`src/DefifaTokenUriResolver.sol`](../src/DefifaTokenUriResolver.sol) renders game-card metadata.
- [`src/DefifaProjectOwner.sol`](../src/DefifaProjectOwner.sol) is the ownership helper for the fee project.

## Lifecycle

1. Countdown before minting opens.
2. Mint phase where players buy outcome NFTs and can delegate attestation power.
3. Optional refund phase.
4. Scoring phase where scorecards are submitted, attested, and ratified.
5. Complete or no-contest settlement depending on governance and safety conditions.

## High-Risk Areas

- Scorecard ratification and quorum assumptions: changes here directly affect who can settle the pot.
- No-contest and refund behavior: these paths are economic safety valves, not edge-case garnish.
- Fee accounting and commitment fulfillment: payout ordering and accounting drift can change final redemption value.
- Hook/governor/deployer coupling: many bugs come from changing one layer while assuming the others are passive.

## Tests To Trust First

- [`test/DefifaGovernor.t.sol`](../test/DefifaGovernor.t.sol) for governance flow.
- [`test/DefifaNoContest.t.sol`](../test/DefifaNoContest.t.sol) for safety exits.
- [`test/DefifaFeeAccounting.t.sol`](../test/DefifaFeeAccounting.t.sol) and [`test/DefifaMintCostInvariant.t.sol`](../test/DefifaMintCostInvariant.t.sol) for economic correctness.
- [`test/DefifaHookRegressions.t.sol`](../test/DefifaHookRegressions.t.sol) and [`test/regression/`](../test/regression/) for pinned regressions.
- [`test/DefifaSecurity.t.sol`](../test/DefifaSecurity.t.sol) and [`test/DefifaGovernanceHardening.t.sol`](../test/DefifaGovernanceHardening.t.sol) for adversarial cases.
