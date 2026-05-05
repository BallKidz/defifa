# Defifa

Defifa is an onchain prediction game system built on Juicebox. Each game is a Juicebox project with staged rulesets, tiered NFT game pieces, scorecard governance, and a final settlement path that turns the project's surplus into winner payouts.

Use this repo when the question is about game lifecycle, scorecard ratification, attestation power, or Defifa-specific settlement behavior. Do not start here for generic project accounting, terminal behavior, or standard 721-tier mechanics.

Architecture: [ARCHITECTURE.md](./ARCHITECTURE.md)  
User journeys: [USER_JOURNEYS.md](./USER_JOURNEYS.md)  
Skills: [SKILLS.md](./SKILLS.md)  
Risks: [RISKS.md](./RISKS.md)  
Administration: [ADMINISTRATION.md](./ADMINISTRATION.md)  
Audit instructions: [AUDIT_INSTRUCTIONS.md](./AUDIT_INSTRUCTIONS.md)

## What This Repo Owns

Defifa adds game-specific behavior on top of Juicebox and the 721 hook stack:

- phased game launch and completion packaging in `DefifaDeployer`
- game-piece behavior, delegation, and settlement weighting in `DefifaHook`
- scorecard submission, attestation, quorum, grace periods, and ratification in `DefifaGovernor`
- onchain card rendering and token metadata in `DefifaTokenUriResolver`

This repo does not own:

- canonical terminal accounting or surplus math
- generic 721 tier storage and most shared NFT-hook machinery
- generic Juicebox permission, project, or ruleset semantics

## Mental Model

Defifa is easiest to read as one state machine split across three contracts:

1. `DefifaDeployer` launches the game and wires the components together
2. `DefifaGovernor` decides which scorecard, if any, becomes final
3. `DefifaHook` converts that ratified result into cash-out weights for game-piece holders

Most real issues live at the seams between those contracts.

## Read These Files First

1. [`src/DefifaDeployer.sol`](./src/DefifaDeployer.sol)
2. [`src/DefifaHook.sol`](./src/DefifaHook.sol)
3. [`src/DefifaGovernor.sol`](./src/DefifaGovernor.sol)
4. [`src/libraries/DefifaHookLib.sol`](./src/libraries/DefifaHookLib.sol)
5. [`test/DefifaGovernor.t.sol`](./test/DefifaGovernor.t.sol)
6. [`test/DefifaFeeAccounting.t.sol`](./test/DefifaFeeAccounting.t.sol)
7. [`test/DefifaNoContest.t.sol`](./test/DefifaNoContest.t.sol)

Then read the upstream repos this package depends on:

- [`../nana-721-hook-v6/README.md`](../nana-721-hook-v6/README.md)
- [`../nana-core-v6/README.md`](../nana-core-v6/README.md)

## Key Contracts

| Contract | Role |
| --- | --- |
| `DefifaDeployer` | Launches games, clones hooks, initializes governance, and fulfills post-game fee commitments. |
| `DefifaHook` | ERC-721 game-piece hook that tracks tiers, delegation, pending reserves, and cash-out weights for settlement. |
| `DefifaGovernor` | Scorecard governance surface that accepts submissions, attestations, quorum checks, grace periods, and ratification. |
| `DefifaHookLib` | Shared validation and weight logic extracted from the hook. |
| `DefifaTokenUriResolver` | Onchain metadata renderer for game cards. |
| `DefifaProjectOwner` | Ownership sink used for the fee-project surface. |

## Lifecycle

Each Defifa game is a Juicebox project with a staged lifecycle:

1. countdown before minting opens
2. mint phase where players buy outcome NFTs
3. optional refund or no-contest handling if the game cannot settle normally
4. scoring phase where participants submit and attest to scorecards
5. completion after a scorecard reaches quorum and survives its grace period
6. final cash out where winning pieces redeem against the prize pot

The important boundary is that the pot is still ordinary Juicebox project value until governance ratifies a scorecard. Defifa-specific settlement starts only when the governor installs final cash-out weights on the hook.

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

## Repository Layout

```text
src/
  DefifaDeployer.sol
  DefifaGovernor.sol
  DefifaHook.sol
  DefifaProjectOwner.sol
  DefifaTokenUriResolver.sol
  enums/
  interfaces/
  libraries/
  structs/
test/
  governance, fee-accounting, no-contest, adversarial, regression, fork, and audit coverage
script/
  Deploy.s.sol
  helpers/
references/
  operations.md
  runtime.md
```

## Integration Traps

- Defifa is not a generic tournament payout primitive
- `DefifaGovernor` and `DefifaHook` must be read together
- fee accounting and prize accounting are coupled
- a timeout into `NO_CONTEST` is a real terminal state
- the shared `JB721TiersHookStore` surface is an upstream ecosystem dependency, not a Defifa-only detail

## High-Signal Tests

- [`test/DefifaGovernor.t.sol`](./test/DefifaGovernor.t.sol)
- [`test/DefifaGovernanceHardening.t.sol`](./test/DefifaGovernanceHardening.t.sol)
- [`test/DefifaFeeAccounting.t.sol`](./test/DefifaFeeAccounting.t.sol)
- [`test/DefifaNoContest.t.sol`](./test/DefifaNoContest.t.sol)
- [`test/DefifaAdversarialQuorum.t.sol`](./test/DefifaAdversarialQuorum.t.sol)
- [`test/audit/PendingReserveDilution.t.sol`](./test/audit/PendingReserveDilution.t.sol)
- [`test/audit/AttestationDoubleCount.t.sol`](./test/audit/AttestationDoubleCount.t.sol)
- [`test/regression/GracePeriodBypass.t.sol`](./test/regression/GracePeriodBypass.t.sol)

## Deployment Notes

Deployments are handled through Sphinx. The deployer composes Juicebox core, the 721 hook stack, Defifa-specific governance, and metadata rendering into one game-launch surface.

## Where State Lives

- game lifecycle config and post-game fulfillment bookkeeping: `DefifaDeployer`
- submitted scorecards, attestations, quorum state, and ratification timing: `DefifaGovernor`
- tier state, delegation, pending reserve awareness, and final cash-out weights: `DefifaHook`
- base project balance and terminal settlement: `nana-core-v6`
- shared 721 tier store semantics: `nana-721-hook-v6`

## For AI Agents

- Treat Defifa as a game-specific layer on top of `nana-core-v6` and `nana-721-hook-v6`, not as a standalone accounting system.
- Use `DefifaDeployer`, `DefifaHook`, and `DefifaGovernor` as the primary execution surfaces.
- Treat `NO_CONTEST`, refund handling, and grace-period logic as normal product behavior.
- If the question is about generic tier storage, terminal settlement, or project accounting, hand off to upstream repos first.
