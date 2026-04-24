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
- The v6 surface is split across dedicated deployer, hook, governor, project-owner, and token-uri contracts, with dedicated regression and audit test coverage around governance, fee accounting, attestations, and lifecycle edge cases.
- Solidity and tooling were upgraded to the v6 baseline around `0.8.28`.

## Local audit remediations

- Reserve-minted NFTs are now excluded from refund calculations during MINT, REFUND, and NO_CONTEST phases. A public `isReserveMint` mapping tracks which tokens were created via tier reserve frequency rather than paid for. `beforeCashOutRecordedWith` subtracts their tier price from `cumulativeMintPrice`, preventing reserve beneficiaries from withdrawing funds they never contributed.

## Migration notes

- Do not treat this repo as part of the deployed v5-to-v6 ecosystem delta.
- If you need a Defifa-specific migration, rebuild from the current v6 ABIs and current contract set instead of relying on the ecosystem summary.
