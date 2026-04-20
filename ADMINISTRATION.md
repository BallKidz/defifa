# Administration

## At A Glance

| Item | Details |
| --- | --- |
| Scope | Game launch configuration, scorecard governance, no-contest recovery, and optional fee-project ownership locking |
| Control posture | Permissionless launch, then collective governance plus bounded contract-controlled lifecycle paths |
| Highest-risk actions | Launching with wrong immutable game settings, misconfiguring governance thresholds, and misunderstanding no-contest handling |
| Recovery posture | Mostly replacement or documented no-contest handling; there is no broad post-launch owner override |

## Purpose

`defifa` is unusual because game creation is permissionless but ongoing game control is intentionally narrow. The main administration job is understanding what is fixed at launch, what collective governance can still do, and what the deployer must do to finish settlement.

## Control Model

- `launchGameWith(...)` is the real governance commitment. Core game shape is fixed there.
- `DefifaGovernor` controls scorecard submission, attestation, and ratification.
- `DefifaHook` controls phase-aware mint and cash-out behavior but does not expose broad admin mutability.
- `DefifaDeployer` still owns structural lifecycle duties such as fulfillment and no-contest queuing.
- `DefifaProjectOwner` is an optional irreversible sink for the fee-project NFT.

## Roles

| Role | How Assigned | Scope | Notes |
| --- | --- | --- | --- |
| Game creator | Calls `launchGameWith(...)` | Launch only | Does not receive broad runtime admin power afterward |
| Scorecard participant | Holds or receives attestation power | Per game | Can submit, attest, revoke, and help ratify |
| Ratification path caller | Any caller who meets the documented conditions | Per game | Finalizes a valid scorecard |
| Fulfillment path caller | Any valid caller once ratified | Per game | Must run the completion commitment path |
| `DefifaProjectOwner` holder | Project NFT sent into sink | Per fee project | Irreversible ownership lock |

## Privileged Surfaces

- `launchGameWith(...)` fixes phase timing, tiers, fee routing, and governance shape
- `submitScorecardFor(...)`, `attestToScorecardFrom(...)`, `revokeAttestationFrom(...)`, and `ratifyScorecardFrom(...)` govern outcome selection
- `fulfillCommitmentsOf(...)` turns a ratified scorecard into real settlement
- `triggerNoContestFor(...)` moves failed games into the documented recovery path

## Immutable And One-Way

- Game phase timing is fixed at launch.
- Scorecard timeout, minimum participation, and default delegation choices are fixed at launch.
- `setTierCashOutWeightsTo()` is effectively one-way once final weights are installed.
- `cashOutWeightIsSet` permanently closes the score-setting path after success.
- `DefifaProjectOwner` permanently locks the project NFT it receives.
- `fulfillCommitmentsOf()` and `triggerNoContestFor()` are single-use style lifecycle paths.

## Operational Notes

- Validate game timings, tier setup, fee routing, and attestation settings before launch.
- Treat `launchGameWith()` as the real admin commitment.
- During scoring, follow the submission, attestation, and ratification flow rather than looking for discretionary overrides.
- Use `triggerNoContestFor()` only when the game has actually entered the documented no-contest condition.
- Treat the fee-project ownership proxy as a burn-lock mechanism, not a recoverable custody tool.

## Machine Notes

- Do not infer ongoing admin power for the game creator; launch is permissionless but not an ongoing authority grant.
- Treat `DefifaDeployer`, `DefifaGovernor`, `DefifaHook`, and `DefifaProjectOwner` as the minimum source-of-truth set for authority review.
- If scorecard state, quorum assumptions, or timeout state differ from the expected lifecycle, inspect the current phase before documenting the next action.
- If a game launched with wrong immutable economics, timing, or split assumptions, do not guess at an in-place fix.

## Recovery

- If a scorecard never reaches a valid ratification path and timeout conditions are met, use the documented no-contest flow.
- If a game launched with wrong immutable economics, timing, fee routing, or tier design, recovery is usually a replacement deployment.
- If fee-project ownership was transferred into `DefifaProjectOwner`, there is no recovery path for that NFT.
- There is no broad owner override that can pause, cancel, or rewrite a live game after launch.

## Admin Boundaries

- No one can change tier prices, timing, payment token, fees, or split configuration after launch.
- No one can unilaterally set scorecard weights without the documented governance path.
- No one can manually pause, cancel, or rewind a game phase.
- No one can set cash-out weights twice.
- No one can fulfill commitments twice.
- No one can recover the project NFT from `DefifaProjectOwner`.
