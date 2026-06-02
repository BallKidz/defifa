# Changelog

## 0.0.53 — Freeze BWA attestation snapshot to the pre-submission block

- **Security fix.** A scorecard's BWA attestation power was read at the submission timestamp. Attestation checkpoints are `block.timestamp`-keyed and equal-key writes overwrite in place, so a `mintReservesFor` or `transferFrom` in the submission block — in either order relative to submission — could grant or move attestation power for that scorecard, letting a reserve beneficiary (or a same-block transfer recipient) manufacture quorum for a self-serving cash-out scorecard. The BWA snapshot is now read at `scorecard.snapshotTimestamp` (submission − 1), excluding the entire submission block.
- **Behavior change.** A reserve minted in the same block as submission no longer carries attestation power for that scorecard — reserves must be minted in an earlier block. This supersedes the 0.0.51 "include same-timestamp reserve mints" behavior: timestamp-keyed checkpoints cannot distinguish a pre- from a post-submission same-block mint, so the whole submission block is excluded. The minted-unit clamp and pending-reserve snapshot are retained (they still bound the denominator for reads at a later timestamp, e.g. delayed-attestation games).
- Updated `INVARIANTS.md` and `CRYPTO_ECON.md`; added regression coverage for the reserve-mint and same-block-transfer variants.

## 0.0.52 — Raise dependency floors; document NatSpec, comment, and lint conventions

- Raised dependency caret floors to the latest published versions: `@bananapus/core-v6` `^0.0.72 → ^0.0.78`, `@bananapus/721-hook-v6` `^0.0.59 → ^0.0.65`, `@bananapus/address-registry-v6` `^0.0.29 → ^0.0.32`, `@bananapus/permission-ids-v6` `^0.0.27 → ^0.0.28`.
- Documented NatSpec, comment, and lint conventions in `STYLE_GUIDE.md`: expanded the NatSpec section with the required tags for every member, added a Comments section, and clarified the linting expectations. These make existing conventions explicit; no source behavior changes.

## 0.0.51 — Include same-timestamp reserve mints in immediate scorecard snapshots

- Immediate scorecard submissions now open attestations at the next timestamp. This keeps the BWA checkpoint at `attestationsBegin - 1` while ensuring same-timestamp reserve mints that happened before submission are included in the snapshot.
- Added regression coverage for same-timestamp reserve minting before scorecard submission.

## 0.0.50 — Remove `DefifaDeployer.setChainSpecificConstants`; bind dependencies as constructor immutables

- **`DefifaDeployer.setChainSpecificConstants(...)` is removed.** None of the values it bound are actually chain-specific: `controller`, `registry`, and `hookStore` have unified CREATE2 addresses; `governor`, `tokenUriResolver`, and the hook code origin deploy deterministically from chain-same salt + ctor args; and `defifaProjectId` (5) / `baseProtocolProjectId` (1) are canonical project IDs identical on every chain (verified against `deploy-all-v6`). They are now bound as constructor `immutable`s, so the one-shot setter is unnecessary. (`DefifaTokenUriResolver.setChainSpecificConstants(ITypeface)` is unaffected — the typeface address genuinely differs per chain.)
- **Breaking constructor signature change.** `DefifaDeployer`'s constructor now takes `(address initialOwner, address hookCodeOrigin, IJB721TokenUriResolver tokenUriResolver, IDefifaGovernor governor, IJBController controller, IJBAddressRegistry registry, uint256 defifaProjectId, uint256 baseProtocolProjectId, IJB721TiersHookStore hookStore)`. The `address deployer` binder arg and the internal `_DEPLOYER` immutable are gone.
- **Breaking getter renames.** The eight fields are now `immutable` and follow the `ALL_CAPS` convention: `controller()→CONTROLLER()`, `registry()→REGISTRY()`, `hookStore()→HOOK_STORE()`, `governor()→GOVERNOR()`, `tokenUriResolver()→TOKEN_URI_RESOLVER()`, `hookCodeOrigin()→HOOK_CODE_ORIGIN()`, `defifaProjectId()→DEFIFA_PROJECT_ID()`, `baseProtocolProjectId()→BASE_PROTOCOL_PROJECT_ID()`.
- Removed the now-unused `DefifaDeployer_AlreadyConfigured` and `DefifaDeployer_Unauthorized` errors (the deployer's `setChainSpecificConstants` was their only user).
- `referralProjectId` is unchanged in behavior — still defaulted to `(1 << 48) | DEFIFA_PROJECT_ID` in the constructor and owner-settable via `setReferralProjectId`.

## 0.0.41 — Owner-settable referral target on `DefifaDeployer`

- `DefifaDeployer` now inherits OpenZeppelin `Ownable`. New constructor arg `address initialOwner` is passed straight to `Ownable(initialOwner)`. **This is a breaking constructor signature change** — `script/Deploy.s.sol` and every test that instantiates `DefifaDeployer` directly was updated to pass `initialOwner` (typically `safeAddress()` in the deploy script; `address(this)` in tests).
- New `referralProjectId()` view returning the packed `(chainId << 48) | projectId` reference credited as the referrer on every fee-payout `sendPayoutsOf` call from `fulfillCommitmentsOf`.
- New `setReferralProjectId(uint256 projectId, uint256 chainId)` (`onlyOwner`): takes the two fields unpacked, packs and stores them. Bounded so the pack is lossless — `projectId <= type(uint48).max`, `chainId <= type(uint208).max`. Reverts with `DefifaDeployer_ReferralProjectIdTooLarge` / `DefifaDeployer_ReferralChainIdTooLarge` otherwise. Emits `SetReferralProjectId(referralChainId, referralProjectId, caller)`.
- Default at construction: `(chainId = 1, projectId = DEFIFA_PROJECT_ID)` — fee-volume credit still lands on the Defifa project on Ethereum mainnet regardless of which chain a game runs on. Owner can repoint this or pass `(0, 0)` to disable referral credit entirely.
- The inline `(uint256(1) << 48) | DEFIFA_PROJECT_ID` pack inside `fulfillCommitmentsOf` is replaced by a read of the new storage slot. No external behavior change for default deployments.

## 0.0.35 — Bump v6 deps to nana-core-v6 0.0.53 cohort

- `@bananapus/core-v6`: `^0.0.48 → ^0.0.53` ([PR #145](https://github.com/Bananapus/nana-core-v6/pull/145)).
- `@bananapus/721-hook-v6`: `^0.0.46 → ^0.0.50`.
- `@bananapus/permission-ids-v6`: `^0.0.22 → ^0.0.25`.
- All `JBRulesetMetadata` literals (src + test) patched to include `pauseCrossProjectFeeFreeInflows: false`.

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
- Reserve minting now caps `count` by `adjustedPendingReservesFor(tierId)` inside `DefifaHook.mintReservesFor`. Without the cap, a caller could request more reserves than the refund-adjusted pending balance, inflating `totalMintCost` from already-refunded mints and breaking the supply-vs-pending-reserves invariant that fee-token claims rely on.
- One-tier games now revert at launch with `DefifaDeployer_InvalidGameConfiguration` if `scorecardTimeout == 0`. A one-tier game cannot reach quorum (the BWA multiplier reduces the sole tier's power to zero), so a zero timeout would leave funds permanently locked with no exit path. Enforcement moves this from a launcher-side responsibility (previously documented in `RISKS.md §8.6`) to a contract-level guarantee.
- `DefifaHook.mintReservesFor` now reverts with `DefifaHook_ReservedTokenMintingBlockedInNoContest` while the game is in `NO_CONTEST`. Reserve mints inflate `totalMintCost` so reserved recipients can claim fee tokens; without the block, a game that failed `minParticipation` could be revived back to SCORING via free notional face value before `triggerNoContestFor` latches the failure.

## Migration notes

- Do not treat this repo as part of the deployed v5-to-v6 ecosystem delta.
- If you need a Defifa-specific migration, rebuild from the current v6 ABIs and current contract set instead of relying on the ecosystem summary.
