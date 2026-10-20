# Defifa

Defifa is an onchain prediction game system built on Juicebox. Each game is a Juicebox project with staged rulesets, tiered NFT game pieces, a referee that submits the game's scorecard, and a final settlement path that turns the project's surplus into winner payouts.

Defifa ships two game types side by side: the ERC-721 game (`DefifaHook`, one NFT per position) and the ERC-1155 game (`Defifa1155Hook`, one balance per tier, so large entries mint in one transfer). Each has its own `DefifaDeployer` and `DefifaGovernor`; both share one `DefifaTiersHookStore`, one `DefifaTokenUriResolver`, and one `DefifaVotingReferee`.

Use this repo when the question is about game lifecycle, referees and scorecard ratification, holder attestation in the voting referee, or Defifa-specific settlement behavior. Do not start here for generic project accounting, terminal behavior, or standard 721-tier mechanics.

## Documentation

- [ARCHITECTURE.md](./ARCHITECTURE.md) — system overview, module boundaries, where state lives.
- [USER_JOURNEYS.md](./USER_JOURNEYS.md) — end-to-end flows for players, scorers, and operators.
- [INVARIANTS.md](./INVARIANTS.md) — structural, authorization, and lifecycle invariants of the game protocol.
- [CRYPTO_ECON.md](./CRYPTO_ECON.md) — cryptoeconomic model: pot formation, prize distribution formula, fee pipeline, parimutuel game theory, parameter design.
- [RISKS.md](./RISKS.md) — known risk surfaces and trust assumptions.
- [ADMINISTRATION.md](./ADMINISTRATION.md) — privileged roles and operational responsibilities.
- [AUDIT_INSTRUCTIONS.md](./AUDIT_INSTRUCTIONS.md) — guidance for auditors entering the codebase.
- [SKILLS.md](./SKILLS.md) — reusable patterns and gotchas captured during development.
- [STYLE_GUIDE.md](./STYLE_GUIDE.md) — repo conventions.
- [CHANGELOG.md](./CHANGELOG.md) - V5 to V6 migration changelog.

## What this repo owns

Defifa adds game-specific behavior on top of Juicebox and the 721 hook stack:

- phased game launch and completion packaging in `DefifaDeployer`
- game-piece behavior, delegation, and settlement weighting in `DefifaHook` (ERC-721) and `Defifa1155Hook` (ERC-1155)
- count-based tier records in `DefifaTiersHookStore`, the upstream `JB721TiersHookStore` plus `recordMintCounts`, `recordBurnCounts` and a count form of `recordTransferForTier`
- each game's referee, timelock, and scorecard ratification in `DefifaGovernor`
- the sample holder-vote referee in `DefifaVotingReferee`: attestation, BWA power, quorum, grace periods, and revocation
- onchain card rendering and token metadata in `DefifaTokenUriResolver`

This repo does not own:

- canonical terminal accounting or surplus math
- generic 721 tier storage and most shared NFT-hook machinery
- generic Juicebox permission, project, or ruleset semantics

## Mental model

Defifa is easiest to read as one state machine split across three contracts, plus the game's referee:

1. `DefifaDeployer` launches the game and wires the components together
2. the game's referee decides the result and submits it to the governor. A referee is any address: a person, a multisig, or a contract that runs its own rule, such as `DefifaVotingReferee`'s holder vote
3. `DefifaGovernor` holds the referee's pending scorecard through the game's timelock, then lets anyone ratify it
4. the game hook (`DefifaHook` or `Defifa1155Hook`) converts that ratified result into cash-out weights for game-piece holders

The governor counts no votes. A game is as safe as its referee.

Most real issues live at the seams between those contracts.

## Read these files first

1. [`src/DefifaDeployer.sol`](./src/DefifaDeployer.sol)
2. [`src/DefifaHook.sol`](./src/DefifaHook.sol)
3. [`src/DefifaGovernor.sol`](./src/DefifaGovernor.sol)
4. [`src/referees/DefifaVotingReferee.sol`](./src/referees/DefifaVotingReferee.sol) and [`src/interfaces/IDefifaReferee.sol`](./src/interfaces/IDefifaReferee.sol)
5. [`src/libraries/DefifaHookLib.sol`](./src/libraries/DefifaHookLib.sol)
6. [`src/Defifa1155Hook.sol`](./src/Defifa1155Hook.sol) and [`src/libraries/Defifa1155HookLib.sol`](./src/libraries/Defifa1155HookLib.sol) for the ERC-1155 game
7. [`test/referee/DefifaGovernorCore.t.sol`](./test/referee/DefifaGovernorCore.t.sol) and [`test/referee/DefifaVotingReferee.t.sol`](./test/referee/DefifaVotingReferee.t.sol)
8. [`test/DefifaGovernor.t.sol`](./test/DefifaGovernor.t.sol)
9. [`test/DefifaFeeAccounting.t.sol`](./test/DefifaFeeAccounting.t.sol)
10. [`test/DefifaNoContest.t.sol`](./test/DefifaNoContest.t.sol)

Then read the upstream repos this package depends on:

- [`../nana-721-hook-v6/README.md`](../nana-721-hook-v6/README.md)
- [`../nana-core-v6/README.md`](../nana-core-v6/README.md)

## Key contracts

| Contract | Role |
| --- | --- |
| `DefifaDeployer` | Launches games, clones hooks, resolves ERC-2771 callers for launch attribution, names each game's referee in the governor, passes `refereeData` to a contract referee, and fulfills post-game fee commitments. |
| `DefifaHook` | ERC-721 game-piece hook that tracks tiers, delegation, pending reserves, and cash-out weights for settlement. |
| `DefifaGovernor` | Accepts scorecards from each game's referee only, holds the pending one through the game's timelock, and lets anyone ratify it. Counts no votes. |
| `DefifaVotingReferee` | Sample referee, one deployment for both game types. Anyone submits; holders attest with BWA power; a scorecard at its 50% to 75% quorum after the grace period is forwarded to the governor. Only the first approved scorecard per game is forwarded. |
| `Defifa1155Hook` | ERC-1155 game-piece hook (one balance per tier) that tracks delegation, pending reserves, and cash-out weights for settlement. |
| `DefifaHookLib` | Shared validation and weight logic extracted from the hook, used by both hooks. |
| `Defifa1155HookLib` | ERC-1155 ID and amount logic for `Defifa1155Hook`; calls `DefifaHookLib` for shared rules. |
| `DefifaTiersHookStore` | `JB721TiersHookStore` plus count-based records. Shared by both game types, required by the ERC-1155 hook. |
| `DefifaTokenUriResolver` | Onchain metadata renderer for game cards, shared by both game types. |

## Lifecycle

Each Defifa game is a Juicebox project with a staged lifecycle:

1. countdown before minting opens
2. mint phase where players buy outcome NFTs (ERC-721 game) or outcome positions (ERC-1155 game)
3. optional refund or no-contest handling if the game cannot settle normally
4. scoring phase where the game's referee submits a scorecard. A new submission replaces the pending one and restarts the timelock
5. completion after anyone ratifies the pending scorecard once the timelock has passed
6. final cash out where winning pieces redeem against the prize pot

If no scorecard is ratified within `scorecardTimeout`, the game ends in `NO_CONTEST` and players refund at mint price.

The important boundary is that the pot is still ordinary Juicebox project value until the governor ratifies a scorecard. Defifa-specific settlement starts only when the governor installs final cash-out weights on the hook.

## Install

```bash
npm install @ballkidz/defifa
```

## Development

```bash
npm install
forge build --deny notes
forge test --deny notes
```

Useful checks before opening or updating a PR:

```bash
forge fmt --check
forge build --deny notes --sizes --skip "*/test/**" --skip "*/script/**"
forge build --deny notes --build-info --skip "*/test/**" --skip "*/script/**"
npm pack --dry-run --json
```

Useful scripts:

- `npm run deploy:mainnets`
- `npm run deploy:testnets`

## Repository layout

```text
src/
  DefifaDeployer.sol
  DefifaGovernor.sol
  DefifaHook.sol
  DefifaTokenUriResolver.sol
  enums/
  interfaces/
  libraries/
  referees/
    DefifaVotingReferee.sol
  structs/
test/
  governance, fee-accounting, no-contest, adversarial, regression, fork, and review coverage
  referee/: core governor and voting referee tests
script/
  Deploy.s.sol
  helpers/
references/
  operations.md
  runtime.md
```

## Integration traps

- Defifa is not a generic tournament payout primitive
- canonical Defifa infrastructure does not make every terminal or game instance canonical; frontends should still curate
  game addresses and scorecard parameters
- `DefifaGovernor` and `DefifaHook` must be read together
- fee accounting and prize accounting are coupled
- a timeout into `NO_CONTEST` is a real terminal state
- a game's result is whatever its referee submits; read `DefifaGovernor.refereeOf(gameId)` and show it before a player mints. Holder attestation means something only when the referee is a voting referee such as `DefifaVotingReferee`
- an address referee decides alone; trust it as you'd trust a bookmaker
- the deployer checks only that `scorecardTimeout` exceeds `timelockDuration`; a voting referee's attestation delay and grace period must also fit inside the timeout, and the UI should check that
- `NO_CONTEST` view state should not be shown as refund-ready until the relevant settlement path is actually available
- games with many outcome tiers need curation around scorecard liveness and, under a voting referee, attestation overhead
- the shared `JB721TiersHookStore` surface is an upstream ecosystem dependency, not a Defifa-only detail
- detect the game type (for example `supportsInterface(type(IERC1155).interfaceId)`) before encoding pay or cash-out
  metadata or reading holdings: the two hooks use different metadata layouts
- in an ERC-1155 game, paid positions use token ID = tier ID and reserve-minted positions use
  `tierId + RESERVE_TOKEN_ID_OFFSET` (`1 << 16`); read holdings with `hook.balanceOf(account, id)`, because the store's
  per-holder views (`balanceOf`, `tierBalanceOf`, `votingUnitsOf`, `tierVotingUnitsOf`) count a tier's paid and
  reserve IDs together

## High-signal tests

- [`test/referee/DefifaGovernorCore.t.sol`](./test/referee/DefifaGovernorCore.t.sol): referee-only submit, timelock, replacement, ratify, states, timeout
- [`test/referee/DefifaVotingReferee.t.sol`](./test/referee/DefifaVotingReferee.t.sol): the voting referee, including first-forwarded-wins
- [`test/DefifaGovernor.t.sol`](./test/DefifaGovernor.t.sol)
- [`test/DefifaGovernanceHardening.t.sol`](./test/DefifaGovernanceHardening.t.sol)
- [`test/DefifaFeeAccounting.t.sol`](./test/DefifaFeeAccounting.t.sol)
- [`test/DefifaNoContest.t.sol`](./test/DefifaNoContest.t.sol)
- [`test/DefifaAdversarialQuorum.t.sol`](./test/DefifaAdversarialQuorum.t.sol)
- [`test/regression/PendingReserveDilution.t.sol`](./test/regression/PendingReserveDilution.t.sol)
- [`test/regression/AttestationDoubleCount.t.sol`](./test/regression/AttestationDoubleCount.t.sol)
- [`test/regression/GracePeriodBypass.t.sol`](./test/regression/GracePeriodBypass.t.sol)
- [`test/erc1155/`](./test/erc1155/): the ERC-1155 suite, same file names as the 721 suite, plus [`test/erc1155/DefifaERC1155.t.sol`](./test/erc1155/DefifaERC1155.t.sol)
- [`test/DefifaHookParity.t.sol`](./test/DefifaHookParity.t.sol): both hooks expose the selectors the shared deployer, governor and resolver call
- [`test/DefifaTiersHookStore.t.sol`](./test/DefifaTiersHookStore.t.sol): count-based store records match the per-position originals

## Deployment notes

Deployments are handled through Sphinx. The deployer composes Juicebox core, the 721 hook stack, Defifa-specific governance, metadata rendering, and the core trusted forwarder into one ERC-2771-aware game-launch surface. `script/Deploy.s.sol` deploys one `DefifaDeployer` plus `DefifaGovernor` pair per game type over one shared `DefifaTiersHookStore` and `DefifaTokenUriResolver`; the ERC-1155 pair uses the salt `keccak256(abi.encode(_salt, "ERC1155"))`. It also deploys one `DefifaVotingReferee` (salt `DefifaVotingRefereeV6_`) for both game types; it finds each game's governor through the game's project owner.

## Where state lives

- game lifecycle config and post-game fulfillment bookkeeping: `DefifaDeployer`
- each game's referee, timelock, pending scorecard, and ratified scorecard: `DefifaGovernor`
- voting windows, submitted scorecards, attestations, quorum snapshots, reserve snapshots, and the forwarded scorecard: `DefifaVotingReferee`
- tier state, delegation, pending reserve awareness, and final cash-out weights: `DefifaHook` (ERC-721) or `Defifa1155Hook` (ERC-1155 position balances)
- tier config, supply, reserve, and burn accounting for both game types: `DefifaTiersHookStore`
- base project balance and terminal settlement: `nana-core-v6`
- shared 721 tier store semantics: `nana-721-hook-v6`

## For AI agents

- Treat Defifa as a game-specific layer on top of `nana-core-v6` and `nana-721-hook-v6`, not as a standalone accounting system.
- Use `DefifaDeployer`, `DefifaHook` or `Defifa1155Hook`, and `DefifaGovernor` as the primary execution surfaces. Both game types are supported products. Holder voting lives in `DefifaVotingReferee`, not the governor.
- Treat `NO_CONTEST`, refund handling, the governor's timelock, and a voting referee's grace period as normal product behavior.
- Do not describe Defifa as an unlimited-outcome market deployer; game parameters should be curated for practical
  settlement and scorecard review.
- If the question is about generic tier storage, terminal settlement, or project accounting, hand off to upstream repos first.
