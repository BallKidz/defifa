# Administration

## At A Glance

| Item | Details |
| --- | --- |
| Scope | Defifa game launch, scorecard ratification, lifecycle progression, and optional fee-project ownership locking |
| Control posture | Mostly permissionless game lifecycle with protocol-contract coordination and collective NFT-holder governance during scoring |
| Highest-risk actions | Launching a game with bad immutable parameters, ratifying a winning scorecard, or transferring a fee-project NFT into `DefifaProjectOwner` |
| Recovery posture | Game parameters are intentionally immutable after launch. Bad setup usually means launching a replacement game or using the documented no-contest path if conditions permit |

## Purpose

`defifa` has a narrow but consequential control plane. Game creation is permissionless, but launch fixes the game’s economics, timing, tiers, fee routing, and governance parameters. After launch, no human admin can directly rewrite the game; lifecycle progression is time-based and scorecard ratification depends on collective attestation rather than discretionary owner action.

## Control Model

- `DefifaDeployer` is the structural owner of Defifa game projects and the governor.
- `DefifaGovernor` coordinates scorecard submission, attestation, and ratification.
- `DefifaHook` enforces per-game mint, cash-out, delegation, and weight-setting rules.
- Game creators are permissionless launch callers, not ongoing admins.
- Scorecard ratification is collective governance by NFT holders, not unilateral protocol control.
- `DefifaProjectOwner` is an optional irreversible ownership sink for the fee project NFT.

## Roles

| Role | Who | How Assigned |
| --- | --- | --- |
| Game creator | Any EOA or contract that calls `DefifaDeployer.launchGameWith()` | Self-selected; permissionless |
| `DefifaDeployer` | Singleton deployed at protocol setup | Immutable; owns all game JB projects and the governor |
| `DefifaGovernor` | Singleton; `Ownable` by the `DefifaDeployer` | Ownership transferred from deployer at construction |
| `DefifaHook` | One clone per game; `Ownable` by the `DefifaGovernor` | Ownership transferred from deployer during `launchGameWith()` |
| `DefifaProjectOwner` | Optional proxy contract that holds the Defifa fee project NFT | Receives project NFT; grants `SET_SPLIT_GROUPS` permission to the deployer |
| Scorecard submitter | Any address during SCORING phase | Permissionless via `submitScorecardFor()` |
| Attestor | Any NFT holder with attestation weight | Must hold game NFTs; weight is proportional to holdings per tier |
| Default attestation delegate | Address set at game launch | Set through `DefifaLaunchProjectData.defaultAttestationDelegate` |
| Tier delegate | Any address delegated attestation units by an NFT holder | Set through `setTierDelegateTo()` or `setTierDelegatesTo()` during MINT only |

## Privileged Surfaces

### DefifaDeployer

| Function | Who Can Call | Effect | Reversible |
| --- | --- | --- | --- |
| `launchGameWith()` | Anyone | Creates a new JB project, clones `DefifaHook`, initializes governance, and configures immutable game parameters | No |
| `fulfillCommitmentsOf()` | Anyone, once scoring is finalized and weights are set | Sends fee payouts and queues the final COMPLETE ruleset | No |
| `triggerNoContestFor()` | Anyone when the game is in `NO_CONTEST` and not yet triggered | Queues refund-friendly ruleset state for no-contest recovery | Partially |

### DefifaGovernor

| Function | Who Can Call | Effect | Reversible |
| --- | --- | --- | --- |
| `initializeGame()` | `DefifaDeployer` as owner | Stores attestation timing and optional timelock settings for the game | No |
| `submitScorecardFor()` | Anyone during SCORING | Creates a scorecard candidate and snapshots relevant attestation state | No |
| `attestToScorecardFrom()` | Eligible NFT holder | Adds attestation weight to a scorecard candidate | Partially |
| `ratifyScorecardFrom()` | Anyone once a scorecard is `SUCCEEDED` | Applies the winning weights and finalizes the game path | No |

### DefifaHook

| Function | Who Can Call | Effect | Reversible |
| --- | --- | --- | --- |
| `initialize()` | `DefifaDeployer` | One-time hook clone initialization and ownership setup | No |
| `setTierCashOutWeightsTo()` | `DefifaGovernor` as owner | Sets irreversible cash-out weights for the game | No |
| `setTierDelegateTo()` | NFT holder during MINT | Delegates attestation units for one tier | Yes, during MINT |
| `setTierDelegatesTo()` | NFT holder during MINT | Batch delegation across tiers | Yes, during MINT |
| `mintReservesFor()` | Anyone when allowed by ruleset metadata | Mints pending reserve supply for a tier | No |
| `afterPayRecordedWith()` | JB terminal | Processes payments and mints NFTs | No |
| `afterCashOutRecordedWith()` | JB terminal | Burns NFTs on cash-out and handles COMPLETE-phase fee-token distribution | No |
| `transferOwnership()` | Current owner | Transfers hook ownership; used structurally during deployment | Partially |

### DefifaProjectOwner

| Function | Who Can Call | Effect | Reversible |
| --- | --- | --- | --- |
| `onERC721Received()` | `JBProjects` contract | Locks the fee-project NFT and auto-grants `SET_SPLIT_GROUPS` to the `DefifaDeployer` | No |

## Immutable And One-Way

| Parameter | Set In | Notes |
| --- | --- | --- |
| Tier prices | `launchGameWith()` | Uniform price across all tiers through `tierPrice` |
| Tier count and names | `launchGameWith()` | Stored in the hook during `initialize()` |
| Game timing | `launchGameWith()` | Encoded as `JBRuleset` durations |
| Payment token | `launchGameWith()` | Single payment token per game |
| Fee structure | Constructor constants | `DEFIFA_FEE_DIVISOR = 20` and `BASE_PROTOCOL_FEE_DIVISOR = 40` |
| Attestation start time | `launchGameWith()` | Stored in the governor during `initializeGame()` |
| Attestation grace period | `launchGameWith()` | Minimum one day enforced in `initializeGame()` |
| Timelock duration | `launchGameWith()` | Optional post-quorum cooling period |
| Default attestation delegate | `launchGameWith()` | Stored in the hook |
| `minParticipation` threshold | `launchGameWith()` | `0` disables the check |
| `scorecardTimeout` | `launchGameWith()` | `0` disables the timeout |
| User splits | `launchGameWith()` | Stored as split groups at creation |
| Hook code origin | Constructor | Template contract for hook cloning |
| `TOTAL_CASHOUT_WEIGHT` | Constant | `1e18` and not mutable |
| JB project ownership | `launchGameWith()` | Project is owned by `DefifaDeployer` |

- `setTierCashOutWeightsTo()` is irreversible once weights are set.
- `cashOutWeightIsSet` permanently closes the score-setting path after success.
- `DefifaProjectOwner` permanently locks the project NFT it receives.
- `fulfillCommitmentsOf()` and `triggerNoContestFor()` are single-use flows.

## Operational Notes

- Validate game timings, tier setup, fee routing, and attestation settings before calling `launchGameWith()`.
- Treat `launchGameWith()` as the real admin commitment; the creator has no privileged control afterward.
- During scoring, follow the submission, attestation, and ratification flow rather than looking for discretionary overrides.
- Use `triggerNoContestFor()` only when the game has actually entered the documented no-contest condition.
- Treat the fee-project ownership proxy as a burn-lock mechanism, not a recoverable custody tool.

## Game Lifecycle Administration

The game lifecycle is automated through Juicebox rulesets configured at launch. No admin can manually advance or rewind phases.

```text
COUNTDOWN --> MINT --> REFUND (optional) --> SCORING --> COMPLETE or NO_CONTEST
```

Phase transitions are time-based and encoded in `JBRuleset` durations:

- `COUNTDOWN`: before `start - mintPeriodDuration - refundPeriodDuration`
- `MINT`: payments open and refunds remain at mint price
- `REFUND`: optional refund window with payments paused
- `SCORING`: payments paused and scorecard governance active
- `COMPLETE`: reached after cash-out weights are set and commitments are fulfilled
- `NO_CONTEST`: reached when participation or scorecard conditions fail and refunds must be unlocked

Scoring control is collective:

1. Anyone submits a scorecard during SCORING via `submitScorecardFor()`.
2. NFT holders attest with per-tier voting weight through `attestToScorecardFrom()`.
3. Once quorum, grace period, and any configured timelock conditions are met, a scorecard reaches `SUCCEEDED`.
4. Anyone can ratify the succeeded scorecard with `ratifyScorecardFrom()`.
5. The governor applies `setTierCashOutWeightsTo()` on the hook.
6. `fulfillCommitmentsOf()` sends payouts and queues the final COMPLETE ruleset.

### Attestation Quorum Details

The quorum threshold is 50% of total attestation power across all tiers with nonzero minted supply. Attestation power uses tier supply checkpointing plus a pending-reserve snapshot taken at scorecard submission.

- Tiers with zero mints are excluded from quorum.
- Concentrated participation in one tier still uses the same 50% threshold.
- Attestations can continue while a scorecard is `ACTIVE`, `QUEUED`, or `SUCCEEDED`, but revocations are limited to `ACTIVE`.
- Multiple competing scorecards can exist, but only the first ratified winning scorecard takes effect.
- If `scorecardTimeout` elapses without ratification and the game enters `NO_CONTEST`, anyone can unlock refunds through `triggerNoContestFor()`.

## Machine Notes

- Do not infer ongoing admin power for the game creator; launch is permissionless but not an ongoing authority grant.
- Treat `src/DefifaDeployer.sol`, `src/DefifaGovernor.sol`, `src/DefifaHook.sol`, and `src/DefifaProjectOwner.sol` as the minimum source-of-truth set for authority crawling.
- If scorecard state, quorum assumptions, or timeout state differ from the expected lifecycle, stop and inspect the game’s current phase before documenting or executing the next action.
- If a game was launched with wrong immutable economics, timing, or split assumptions, do not guess at an in-place fix; the normal recovery path is a replacement game or a valid no-contest flow.

## Recovery

- If a scorecard never reaches a valid ratification path and timeout conditions are met, use the documented no-contest flow.
- If a game launched with wrong immutable economics, timing, fee routing, or tier design, recovery is a replacement deployment rather than an admin patch.
- If fee-project ownership was transferred into `DefifaProjectOwner`, there is no recovery path for the NFT itself.
- There is no broad owner override that can pause, cancel, or rewrite a live game after launch.

## Admin Boundaries

- No one can change tier prices, timing, payment token, fees, or split configuration after launch.
- No one can unilaterally set scorecard weights without collective quorum and the documented governance path.
- No one can manually pause, cancel, or rewind a game phase.
- No one can extract treasury funds outside the configured payout and ruleset constraints.
- No one can mint new tiers or relax immutable tier-shape assumptions after initialization.
- No one can change delegation state outside the MINT phase.
- No one can set cash-out weights twice.
- No one can ratify more than one winning scorecard per game.
- No one can fulfill commitments twice.
- No one can recover the project NFT from `DefifaProjectOwner`.
- The game creator has no special runtime privileges after `launchGameWith()` returns.

## Source Map

- `src/DefifaDeployer.sol`
- `src/DefifaGovernor.sol`
- `src/DefifaHook.sol`
- `src/DefifaProjectOwner.sol`
- `src/structs/DefifaLaunchProjectData.sol`
- `script/Deploy.s.sol`
- `script/helpers/DefifaDeploymentLib.sol`
- `test/DefifaGovernor.t.sol`
- `test/DefifaGovernanceHardening.t.sol`
- `test/DefifaNoContest.t.sol`
- `test/DefifaSecurity.t.sol`
- `test/regression/`
- `test/audit/`
