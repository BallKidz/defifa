# Defifa

Defifa is an on-chain prediction game system built on Juicebox. Each game is a Juicebox project with staged rulesets, tiered NFT game pieces, scorecard governance, and a final settlement path that turns the project's surplus into winner payouts.

Use this repo when the question is about game lifecycle, scorecard ratification, attestation power, or Defifa-specific settlement behavior. Do not start here for generic project accounting, terminal behavior, or standard 721-tier mechanics. Those live upstream in `nana-core-v6` and `nana-721-hook-v6`.

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
- on-chain card rendering and token metadata in `DefifaTokenUriResolver`

This repo does not own:

- canonical terminal accounting or surplus math
- generic 721 tier storage and most shared NFT-hook machinery
- generic Juicebox permission, project, or ruleset semantics

## Mental Model

Defifa is easiest to read as one state machine split across three contracts:

1. `DefifaDeployer` launches the game and wires the components together.
2. `DefifaGovernor` decides which scorecard, if any, becomes final.
3. `DefifaHook` converts that ratified result into cash-out weights for game-piece holders.

Most real issues live at the seams between those contracts, not inside one contract in isolation.

## Read These Files First

If you are auditing or debugging the repo for the first time, start here:

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
| `DefifaHookLib` | Shared validation and weight logic extracted from the hook to stay within contract-size limits. |
| `DefifaTokenUriResolver` | On-chain metadata renderer for game cards. |
| `DefifaProjectOwner` | Ownership sink used for the fee-project surface. |

## Lifecycle

Each Defifa game is a Juicebox project with a staged lifecycle:

1. countdown before minting opens
2. mint phase where players buy outcome NFTs
3. optional refund or no-contest handling if the game cannot settle normally
4. scoring phase where participants submit and attest to scorecards
5. completion after a scorecard reaches quorum and survives its grace period
6. final cash out where winning pieces redeem against the prize pot

The important boundary is that the pot is still ordinary Juicebox project value until governance ratifies a scorecard. Defifa-specific settlement happens only when the governor installs final cash-out weights on the hook.

## Install

```bash
npm install @ballkidz/defifa
```

## Development

```bash
npm install
forge build
forge test
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

- Defifa is not a generic tournament payout primitive. Its phase model, scorecard governance, and no-contest behavior are part of the product.
- `DefifaGovernor` and `DefifaHook` must be read together. Ratification is meaningful only because the hook later converts the result into redeemable cash-out weights.
- Fee accounting and prize accounting are coupled. Pending reserves, reserve dilution, and post-game fulfillment logic can change who effectively bears dilution.
- A timeout into `NO_CONTEST` is a real terminal state, not just a temporary failure.
- This repo inherits the shared `JB721TiersHookStore` surface from the broader 721-hook ecosystem. Store-level bugs are upstream ecosystem risks, not Defifa-only bugs.

## High-Signal Tests

These tests are especially useful for understanding the repo's risk surface:

- [`test/DefifaGovernor.t.sol`](./test/DefifaGovernor.t.sol): core scorecard submission, attestation, and ratification flow
- [`test/DefifaGovernanceHardening.t.sol`](./test/DefifaGovernanceHardening.t.sol): governance edge cases and hardening assumptions
- [`test/DefifaFeeAccounting.t.sol`](./test/DefifaFeeAccounting.t.sol): prize-pot and fee-token accounting behavior
- [`test/DefifaNoContest.t.sol`](./test/DefifaNoContest.t.sol): no-contest and recovery behavior
- [`test/DefifaAdversarialQuorum.t.sol`](./test/DefifaAdversarialQuorum.t.sol): quorum manipulation pressure
- [`test/audit/PendingReserveDilution.t.sol`](./test/audit/PendingReserveDilution.t.sol): reserve-dilution edge cases
- [`test/audit/AttestationDoubleCount.t.sol`](./test/audit/AttestationDoubleCount.t.sol): attestation accounting abuse cases
- [`test/regression/GracePeriodBypass.t.sol`](./test/regression/GracePeriodBypass.t.sol): ratification timing regression coverage

## Deployment Notes

Deployments are handled through Sphinx. The deployer composes Juicebox core, the 721 hook stack, Defifa-specific governance, and metadata rendering into a single game-launch surface. `deploy-all-v6` may orchestrate wider workspace deployment, but Defifa runtime behavior is still owned here and in the upstream shared protocol repos.

## Where State Lives

- game lifecycle configuration and post-game fulfillment bookkeeping: `DefifaDeployer`
- submitted scorecards, attestations, quorum state, and ratification timing: `DefifaGovernor`
- tier state, delegation, pending reserve awareness, and final cash-out weights: `DefifaHook`
- base project balance, terminal accounting, and redemption settlement: `nana-core-v6`
- shared 721 tier store semantics: `nana-721-hook-v6`

## For AI Agents

When summarizing this repo or answering questions about it:

- treat Defifa as a game-specific layer on top of `nana-core-v6` and `nana-721-hook-v6`, not as a standalone accounting system
- use `DefifaDeployer`, `DefifaHook`, and `DefifaGovernor` as the primary execution surfaces
- treat `NO_CONTEST`, refund handling, and grace-period logic as part of normal product behavior, not rare admin-only exceptions
- if the question is about generic tier storage, terminal settlement, or project accounting, hand off to the upstream repos before making Defifa-specific claims
- use the governance and fee-accounting tests as higher-signal evidence than prose summaries when there is any ambiguity

## Risks And Notes

- scorecard governance quality depends on quorum, grace period, delegation concentration, and launch-time configuration
- optional refund windows and no-contest thresholds materially change the game's economic behavior
- settlement is only as good as the ratified scorecard; bad governance configuration can still produce unfair outcomes
- fee-accounting and pending-reserve edge cases are economically sensitive because they can dilute or distort claims on value
- deployer commitment-fulfillment logic is part of completion, not optional aftercare

## License

MIT
