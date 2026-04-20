# Defifa Runtime

Use this file when `defifa/SKILLS.md` has already routed you here and you need to reason about the game as a state machine rather than as isolated contracts.

## Contract Roles

- [`src/DefifaDeployer.sol`](../src/DefifaDeployer.sol) launches games, manages phase progression, fulfills commitments, and triggers safety exits such as no-contest.
- [`src/DefifaHook.sol`](../src/DefifaHook.sol) manages the NFT game pieces, delegation, and settlement-side cash-out behavior.
- [`src/DefifaGovernor.sol`](../src/DefifaGovernor.sol) handles scorecard submission, attestation, quorum, and ratification.
- [`src/DefifaTokenUriResolver.sol`](../src/DefifaTokenUriResolver.sol) renders game-card metadata.
- [`src/DefifaProjectOwner.sol`](../src/DefifaProjectOwner.sol) is the ownership helper for the fee project.

## Lifecycle

1. Countdown before minting opens.
2. Mint phase where players buy outcome NFTs and can delegate attestation power.
3. Optional refund phase if the launch configuration allows it.
4. Scoring phase where scorecards are submitted, attested, and ratified.
5. Complete or no-contest settlement depending on governance outcome and safety checks.

## High-Risk Areas

- Scorecard ratification and quorum assumptions: changes here directly affect who can settle the pot.
- No-contest and refund behavior: these paths are economic safety valves, not edge-case garnish.
- Fee accounting and commitment fulfillment: payout ordering and accounting drift can change final redemption value.
- Hook/governor/deployer coupling: many bugs come from changing one layer while assuming the others are passive.
- Pending reserved supply and snapshot assumptions: settlement and quorum logic can drift if supply-sensitive views are taken at the wrong time.
- Scorecards that miss quorum do not naturally “finish.” New scorecards can still be submitted until no-contest logic takes over, so do not assume a clean defeated terminal state.

## Common Misdiagnoses

- A settlement bug is blamed on [`src/DefifaHook.sol`](../src/DefifaHook.sol) even though the wrong phase or grace-period state was created in [`src/DefifaDeployer.sol`](../src/DefifaDeployer.sol) or [`src/DefifaGovernor.sol`](../src/DefifaGovernor.sol).
- A governance bug is blamed on the governor even though attestation power or delegation semantics were wrong in the hook layer.
- An NFT-facing bug is blamed on settlement code even though the problem is resolver output in [`src/DefifaTokenUriResolver.sol`](../src/DefifaTokenUriResolver.sol).
- A Defifa-specific payout result is patched in this repo when the real bug is shared 721 or core protocol behavior upstream.

## Tests To Trust First

- [`test/DefifaGovernor.t.sol`](../test/DefifaGovernor.t.sol) for governance flow.
- [`test/DefifaNoContest.t.sol`](../test/DefifaNoContest.t.sol) for safety exits.
- [`test/DefifaFeeAccounting.t.sol`](../test/DefifaFeeAccounting.t.sol) and [`test/DefifaMintCostInvariant.t.sol`](../test/DefifaMintCostInvariant.t.sol) for economic correctness.
- [`test/DefifaHookRegressions.t.sol`](../test/DefifaHookRegressions.t.sol), [`test/regression/GracePeriodBypass.t.sol`](../test/regression/GracePeriodBypass.t.sol), [`test/regression/FulfillmentBlocksRatification.t.sol`](../test/regression/FulfillmentBlocksRatification.t.sol), and [`test/regression/AttestationDelegateBeneficiary.t.sol`](../test/regression/AttestationDelegateBeneficiary.t.sol) for pinned regressions.
- [`test/DefifaSecurity.t.sol`](../test/DefifaSecurity.t.sol), [`test/DefifaGovernanceHardening.t.sol`](../test/DefifaGovernanceHardening.t.sol), [`test/DefifaAdversarialQuorum.t.sol`](../test/DefifaAdversarialQuorum.t.sol), and [`test/audit/`](../test/audit/) for adversarial and audit-derived cases.
