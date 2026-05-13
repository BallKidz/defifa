# Changelog

## Scope

This repo was not part of the deployed v5 ecosystem that the top-level changelog measures, so it is excluded from the ecosystem delta.

This file instead describes the current v6 repo at a high level and the broad migration direction from the older `defifa-v5` codebase.

## Current v6 surface

- `DefifaDeployer`
- `DefifaHook`
- `DefifaGovernor`
- `DefifaProjectOwner`
- `DefifaTokenUriResolver`

## Summary

- The repo is now built directly on the v6 Juicebox stack, including the v6 core and 721-hook packages.
- The v6 surface is split across dedicated deployer, hook, governor, project-owner, and token-uri contracts, with dedicated regression and review test coverage around governance, fee accounting, attestations, and lifecycle edge cases.
- Solidity and tooling were upgraded to the v6 baseline around `0.8.28`.

## Local review remediations

- Reserve-minted NFTs are now excluded from refund calculations during MINT, REFUND, and NO_CONTEST phases. A public `isReserveMint` mapping tracks which tokens were created via tier reserve frequency rather than paid for. `beforeCashOutRecordedWith` subtracts their tier price from `cumulativeMintPrice`, preventing reserve beneficiaries from withdrawing funds they never contributed.
- One-tier games now revert at launch with `DefifaDeployer_InvalidGameConfiguration` if `scorecardTimeout == 0`. A one-tier game cannot reach quorum (the BWA multiplier reduces the sole tier's power to zero), so a zero timeout would leave funds permanently locked with no exit path. Enforcement moves this from a launcher-side responsibility (previously documented in `RISKS.md §8.6`) to a contract-level guarantee.
- `DefifaHook.mintReservesFor` now reverts with `DefifaHook_ReservedTokenMintingBlockedInNoContest` while the game is in `NO_CONTEST`. Reserve mints inflate `totalMintCost` so reserved recipients can claim fee tokens; without the block, a game that failed `minParticipation` could be revived back to SCORING via free notional face value before `triggerNoContestFor` latches the failure.

## Migration notes

- Do not treat this repo as part of the deployed v5-to-v6 ecosystem delta.
- If you need a Defifa-specific migration, rebuild from the current v6 ABIs and current contract set instead of relying on the ecosystem summary.
