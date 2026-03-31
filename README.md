# Defifa

Defifa is an on-chain prediction game system built on Juicebox. Players mint NFT game pieces, scorecards determine how the pot is distributed, and winners cash out by burning the NFTs that backed their position.

Architecture: [ARCHITECTURE.md](./ARCHITECTURE.md)

## Overview

Each Defifa game is a Juicebox project with a staged lifecycle:

- countdown before minting opens
- mint phase where players buy outcome NFTs
- optional refund window
- scoring phase where holders attest to scorecards
- completion or no-contest settlement

The project's surplus is the prize pot. Once a scorecard reaches quorum and survives its grace period, the hook updates cash-out weights so players can redeem winning pieces for their share.

Use this repo when you want a full game system with lifecycle, governance, and settlement. Do not treat it as a generic tournament payout primitive; its assumptions are Defifa-specific.

If the issue is basic NFT issuance, project accounting, or generic governance plumbing, start in the underlying protocol repos first. Defifa is where the game-specific lifecycle and settlement assumptions get introduced.

## Key Contracts

| Contract | Role |
| --- | --- |
| `DefifaDeployer` | Launches games, clones hooks, initializes governance, and fulfills post-game fee commitments. |
| `DefifaHook` | ERC-721 game piece hook that tracks tiers, delegation, and cash-out weights for settlement. |
| `DefifaGovernor` | Scorecard governance surface that accepts submissions, attestations, and ratification. |
| `DefifaTokenUriResolver` | On-chain metadata renderer for game cards. |
| `DefifaProjectOwner` | Ownership helper for the Defifa fee project. |

## Mental Model

Defifa is easiest to read as three layers:

1. launch and lifecycle packaging in `DefifaDeployer`
2. player position and settlement state in `DefifaHook`
3. scorecard selection in `DefifaGovernor`

Most system-level issues come from how those layers interact, not from one layer in isolation.

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

## Deployment Notes

Deployments are handled through Sphinx. The system composes Juicebox core, the 721 hook stack, and Defifa-specific governance and resolver contracts into a single game-launch surface.

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
  lifecycle, fee, governance, invariant, fork, audit, and regression coverage
script/
  Deploy.s.sol
  helpers/
```

## Risks And Notes

- scorecard governance quality depends on quorum, grace period, and participation assumptions set at launch
- optional refund windows and no-contest thresholds materially change game economics
- settlement is only as good as the ratified scorecard; bad governance configuration can still produce bad outcomes
- fee-accounting and pending-reserve edge cases are heavily tested because they are easy places for pot dilution or griefing
