# Defifa

## Use this file for

- Use this file when the task involves Defifa game deployment, phase transitions, referees, scorecards, attestations, voting thresholds, fee accounting, or Defifa token URI behavior.
- Start here, then decide whether the issue is launch shape, hook runtime, governor ratification, the referee's rule, or resolver output.

## Read this next

| If you need... | Open this next |
|---|---|
| Lifecycle framing and repo boundaries | [`ARCHITECTURE.md`](./ARCHITECTURE.md) |
| Launch shape, phase queueing, and commitment fulfillment | [`src/DefifaDeployer.sol`](./src/DefifaDeployer.sol), [`script/Deploy.s.sol`](./script/Deploy.s.sol) |
| Minting, delegation, game-state gating, and cash-out behavior | [`src/DefifaHook.sol`](./src/DefifaHook.sol), [`src/libraries/DefifaHookLib.sol`](./src/libraries/DefifaHookLib.sol) |
| Referee-only submission, timelock, and ratification | [`src/DefifaGovernor.sol`](./src/DefifaGovernor.sol), [`src/interfaces/IDefifaReferee.sol`](./src/interfaces/IDefifaReferee.sol) |
| Holder attestation, BWA power, quorum, grace period, and forwarding (the sample referee) | [`src/referees/DefifaVotingReferee.sol`](./src/referees/DefifaVotingReferee.sol) |
| Token URI rendering | [`src/DefifaTokenUriResolver.sol`](./src/DefifaTokenUriResolver.sol) |
| Runtime and operational invariants | [`references/runtime.md`](./references/runtime.md), [`references/operations.md`](./references/operations.md) |
| Governance and lifecycle proofs | [`test/referee/DefifaGovernorCore.t.sol`](./test/referee/DefifaGovernorCore.t.sol), [`test/referee/DefifaVotingReferee.t.sol`](./test/referee/DefifaVotingReferee.t.sol), [`test/DefifaGovernor.t.sol`](./test/DefifaGovernor.t.sol), [`test/DefifaGovernanceHardening.t.sol`](./test/DefifaGovernanceHardening.t.sol), [`test/DefifaNoContest.t.sol`](./test/DefifaNoContest.t.sol) |
| Fee and adversarial accounting coverage | [`test/DefifaFeeAccounting.t.sol`](./test/DefifaFeeAccounting.t.sol), [`test/DefifaMintCostInvariant.t.sol`](./test/DefifaMintCostInvariant.t.sol), [`test/DefifaSecurity.t.sol`](./test/DefifaSecurity.t.sol), [`test/DefifaAdversarialQuorum.t.sol`](./test/DefifaAdversarialQuorum.t.sol) |

## Repo map

| Area | Where to look |
|---|---|
| Main contracts | [`src/`](./src/) |
| Libraries, enums, interfaces, and structs | [`src/libraries/`](./src/libraries/), [`src/enums/`](./src/enums/), [`src/interfaces/`](./src/interfaces/), [`src/structs/`](./src/structs/) |
| Scripts | [`script/`](./script/) |
| Tests | [`test/`](./test/) |

## Purpose

Defifa is an onchain prediction game system built on Juicebox. This repo packages game launch, phased lifecycle control, referee-submitted scorecards, and NFT-based settlement into one game-specific deployment surface. It ships two game types: the ERC-721 game (`DefifaHook`) and the ERC-1155 game (`Defifa1155Hook`, one balance per tier).

## Reference files

- Open [`references/runtime.md`](./references/runtime.md) for the game lifecycle, contract roles, settlement path, and the main economic and governance invariants.
- Open [`references/operations.md`](./references/operations.md) for deployment and phase-queueing behavior, test breadcrumbs, and common stale operational assumptions.

## Working rules

- Start in [`src/DefifaDeployer.sol`](./src/DefifaDeployer.sol) for phase shape and commitment fulfillment, [`src/DefifaHook.sol`](./src/DefifaHook.sol) for ERC-721 runtime and settlement behavior, [`src/Defifa1155Hook.sol`](./src/Defifa1155Hook.sol) for ERC-1155 position runtime, [`src/DefifaGovernor.sol`](./src/DefifaGovernor.sol) for the referee, timelock, and ratification, and [`src/referees/DefifaVotingReferee.sol`](./src/referees/DefifaVotingReferee.sol) for holder attestation.
- Treat phase transitions, scorecard ratification, no-contest behavior, and fee accounting as one economic system.
- Defifa-specific cash-out weights and governance thresholds sit on top of `nana-721-hook-v6` and `nana-core-v6`.
- Put game rules both hooks need in [`src/libraries/DefifaHookLib.sol`](./src/libraries/DefifaHookLib.sol); [`src/libraries/Defifa1155HookLib.sol`](./src/libraries/Defifa1155HookLib.sol) holds only ERC-1155 ID and amount logic. Keep the selectors the shared deployer, governor and resolver call on both hooks ([`test/DefifaHookParity.t.sol`](./test/DefifaHookParity.t.sol)).
- ERC-1155 positions: paid ID = tier ID, reserve ID = `tierId + RESERVE_TOKEN_ID_OFFSET`. Read holdings with `hook.balanceOf(account, id)`; the store's per-holder views count a tier's paid and reserve IDs together. ERC-1155 tests live in [`test/erc1155/`](./test/erc1155/) under the same file names as the 721 suite.
- When a task mentions NFT rendering or metadata, confirm whether it belongs in [`src/DefifaTokenUriResolver.sol`](./src/DefifaTokenUriResolver.sol).
- If you edit phase transitions, check lifecycle, governance, and fee-accounting tests together.
- The governor counts no votes. Each game names one `referee` at launch (required, any address). Only the referee calls `submitScorecardFor`; a new submission replaces the pending one and restarts the timelock, and resubmitting the pending one reverts. Anyone ratifies once `timelockDuration` has passed. `stateOf` returns QUEUED, SUCCEEDED, RATIFIED, or DEFEATED. `scorecardTimeout` must exceed `timelockDuration` and ends unratified games in NO_CONTEST.
- When `refereeData` is not empty, the deployer calls `IDefifaReferee(referee).initializeGameFor(gameId, refereeData)` at launch. A referee contract must accept that call only from the game's project owner.
- `DefifaVotingReferee` keeps holder attestation: `refereeData = abi.encode(attestationStartTime, attestationGracePeriod)`, grace period at least 1 day, quorum 50% to 75% of `(N - 1) * MAX_ATTESTATION_POWER_TIER` by the scorecard's largest share squared, revocation only while ACTIVE. `forwardScorecardFor` sends a SUCCEEDED scorecard to the governor; only the first one per game is forwarded (`forwardedScorecardIdOf`). One deployment serves both game types and finds each game's governor through the game's project owner.
- `defaultAttestationDelegate` stays in launch data: it is the holders' default delegate, read by voting referees. A game that wants one address to decide names that address as its referee.
- To write a referee, copy `DefifaVotingReferee`'s shape: implement `IDefifaReferee` only if you need per-game settings, accept `initializeGameFor` only from the project owner, and call the governor's `submitScorecardFor` when your rule decides.
- If ratification, attestation, or quorum behavior changes, re-read the review and regression tests before trusting a clean happy-path result.
