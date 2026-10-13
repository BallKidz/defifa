# V5 to V6 Changelog

## Scope

This is a V5-to-V6 migration changelog, not a package release log or commit history. It compares `defifa-v5` in `../../v5/evm` with the current V6 `defifa` repo.

## Current V6 Surface

- `DefifaDeployer`
- `DefifaGovernor`
- `DefifaHook`
- `DefifaTokenUriResolver`
- Defifa enums, interfaces, libraries, and structs under `src/`

## Summary

- Game positions are ERC-1155 balances. `DefifaHook` is an OpenZeppelin `ERC1155` game-piece hook, no longer a `JB721Hook` / ERC-721: a payment mints a count per tier in one transfer instead of one token per position. Per-position ERC-721 mints cost about 47k gas each, which capped one entry near 160 positions under Base's 2^24 per-transaction gas cap with the SDK's 2x gas headroom. Games already deployed stay ERC-721; this needs a new hook implementation and deployer deployment.
- `DefifaDelegate` is now `DefifaHook`. Integrations should update both naming and ABI assumptions.
- `DefifaProjectOwner` was removed. The canonical fee project ownership path now belongs to the V6 revnet / `REVOwner` setup rather than a Defifa-specific sink contract.
- Chain-specific configuration was removed from the main deployer flow where values are deterministic or canonical. V6 binds those dependencies through constructor immutables and deterministic deployment inputs.
- Scorecard and attestation handling is stricter. V6 snapshots attestation power before submission and rejects duplicate or malformed scorecard state more explicitly.
- Game launch and commitment accounting are aligned with the V6 Juicebox and 721 hook stack, including tier cash-out weights and V6 hook events.

## ABI, Event, and Error Changes

- Replaced interface and contract naming:
  - `IDefifaDelegate` / `DefifaDelegate` -> `IDefifaHook` / `DefifaHook`
- ERC-1155 game positions (`IDefifaHook` now extends `IJBRulesetDataHook`, `IJBPayHook`, `IJBCashOutHook` instead of `IJB721Hook`):
  - removed `firstOwnerOf`, `isReserveMint`, `tokenURI`, `totalCashOutWeight()` (use the `TOTAL_CASHOUT_WEIGHT` constant), and ERC-721 `ownerOf` / `transferFrom` / `approve`
  - added `uri`, `name`, `symbol`, `tierIdOf`, `RESERVE_TOKEN_ID_OFFSET`, `METADATA_ID_TARGET`, `cashOutWeightOf(uint256[] tokenIds, uint256[] amounts)`, and `tokensClaimableFor(uint256[] tokenIds, uint256[] amounts)`; `cashOutWeightOf(uint256)` is now the weight of one position
  - `Mint(uint256 indexed tierId, address indexed beneficiary, uint256 count, uint256 totalAmountContributed, address caller)` and `MintReservedToken(uint256 indexed tierId, address indexed beneficiary, uint256 count, address caller)` carry a tier ID and count instead of a token ID; ERC-1155 `TransferSingle` / `TransferBatch` replace ERC-721 `Transfer`, and ERC-721 `Approval` is gone (`ApprovalForAll` remains)
  - `JB721Hook_InvalidPay`, `JB721Hook_InvalidCashOut`, `JB721Hook_UnexpectedTokenCashedOut` -> `DefifaHook_InvalidPay`, `DefifaHook_InvalidCashOut`, `DefifaHook_UnexpectedTokenCashedOut`; `DefifaHook_Unauthorized` now reports `(tokenId, amount, balance, holder)`; new `DefifaHook_LengthMismatch`, `DefifaHook_InvalidTokenId`, `DefifaHook_ZeroAmount`; repeated pay tiers revert `DefifaHook_BadTierOrder`
- Removed surface:
  - `DefifaProjectOwner`
  - deployer chain-constant setter paths that are now constructor/deterministic inputs
- Added or migration-sensitive events:
  - `TierCashOutWeightsSet`
  - `TierDelegateAttestationsChanged`
  - `DelegateChanged`
  - `Mint`
  - `MintReservedToken`
  - governor scorecard events such as `ScorecardSubmitted`, `ScorecardAttested`, and `ScorecardRatified`
- Added or migration-sensitive errors include:
  - `DefifaHook_CashoutWeightsAlreadySet`
  - `DefifaHook_GameIsntScoringYet`
  - `DefifaHook_InvalidCashoutWeights`
  - `DefifaHook_ReservedTokenMintingBlockedInNoContest`
  - `DefifaGovernor_DuplicateScorecard`
  - `DefifaGovernor_UnownedProposedCashoutValue`

## Machine-Checked ABI Coverage

Generated from Foundry `out/**/*.json` artifacts before the ERC-1155 game-positions change (the `DefifaHook` / `IDefifaHook` counts and the ERC-721 event and error names below predate it; see the ABI section above), filtered to this repo's own runtime source roots and excluding tests, scripts, and dependencies.

- V5 comparison package: `defifa-v5`.
- Own-source ABI artifacts compared: V6 `12`, V5 `19`.
- Contract/interface coverage: `3` added, `10` removed, `6` shared names with ABI changes, `3` shared names ABI-identical.
- Shared-name ABI item deltas: `61` added, `50` removed, `1` modified.

Added V6 ABI artifacts:
- `DefifaHook` from `src/DefifaHook.sol`: `62` functions, `10` events, `29` errors.
- `DefifaHookLib` from `src/libraries/DefifaHookLib.sol`: `8` functions, `1` events, `5` errors.
- `IDefifaHook` from `src/interfaces/IDefifaHook.sol`: `44` functions, `6` events, `0` errors.

Removed V5 ABI artifacts:
- `DefifaAttestations` from `contracts/structs/DefifaAttestations.sol`: `0` functions, `0` events, `0` errors.
- `DefifaDelegation` from `contracts/structs/DefifaDelegation.sol`: `0` functions, `0` events, `0` errors.
- `DefifaGamePhase` from `contracts/enums/DefifaGamePhase.sol`: `0` functions, `0` events, `0` errors.
- `DefifaLaunchProjectData` from `contracts/structs/DefifaLaunchProjectData.sol`: `0` functions, `0` events, `0` errors.
- `DefifaOpsData` from `contracts/structs/DefifaOpsData.sol`: `0` functions, `0` events, `0` errors.
- `DefifaProjectOwner` from `contracts/DefifaProjectOwner.sol`: `4` functions, `0` events, `0` errors.
- `DefifaScorecard` from `contracts/structs/DefifaScorecard.sol`: `0` functions, `0` events, `0` errors.
- `DefifaScorecardState` from `contracts/enums/DefifaScorecardState.sol`: `0` functions, `0` events, `0` errors.
- `DefifaTierCashOutWeight` from `contracts/structs/DefifaTierCashOutWeight.sol`: `0` functions, `0` events, `0` errors.
- `DefifaTierParams` from `contracts/structs/DefifaTierParams.sol`: `0` functions, `0` events, `0` errors.

Shared ABI artifacts with changes:
- `DefifaDeployer`: `18` added, `24` removed, `1` modified ABI items.
- `DefifaGovernor`: `19` added, `11` removed, `0` modified ABI items.
- `DefifaTokenUriResolver`: `4` added, `0` removed, `0` modified ABI items.
- `IDefifaDeployer`: `11` added, `12` removed, `0` modified ABI items.
- `IDefifaGovernor`: `8` added, `3` removed, `0` modified ABI items.
- `IDefifaTokenUriResolver`: `1` added, `0` removed, `0` modified ABI items.

Generated event/error name deltas:
- Event names added:
  - `Approval`, `ApprovalForAll`, `AttestationRevoked`, `ClaimedTokens`, `CommitmentPayoutFailed`, `DelegateChanged`, `GameInitialized`, `Mint`.
  - `MintReservedToken`, `OwnershipTransferred`, `TierCashOutWeightsSet`, `TierDelegateAttestationsChanged`, `Transfer`.
- Event names removed or replaced:
  - `DistributeToSplit`, `GameInitialized`, `QueuedRefundPhase`, `QueuedScoringPhase`.
- Error names added:
  - `CheckpointUnorderedInsertion`, `DefifaDeployer_CantFulfillYet`, `DefifaDeployer_InvalidCurrency`, `DefifaDeployer_InvalidGameConfiguration`, `DefifaDeployer_NoContestAlreadyTriggered`, `DefifaDeployer_NotNoContest`, `DefifaDeployer_SplitsDontAddUp`, `DefifaGovernor_AlreadyAttested`.
  - `DefifaGovernor_AlreadyInitialized`, `DefifaGovernor_AlreadyRatified`, `DefifaGovernor_DuplicateScorecard`, `DefifaGovernor_GameNotFound`, `DefifaGovernor_GracePeriodTooShort`, `DefifaGovernor_NotAllowed`, `DefifaGovernor_NotAttested`, `DefifaGovernor_Uint48Overflow`.
  - `DefifaGovernor_UnknownProposal`, `DefifaGovernor_UnownedProposedCashoutValue`, `DefifaHook_BadTierOrder`, `DefifaHook_CashoutWeightsAlreadySet`, `DefifaHook_DelegateAddressZero`, `DefifaHook_DelegateChangesUnavailableInThisPhase`, `DefifaHook_GameIsntScoringYet`, `DefifaHook_IdenticalTokens`.
  - `DefifaHook_InvalidCashoutWeights`, `DefifaHook_InvalidTierId`, `DefifaHook_NothingToClaim`, `DefifaHook_NothingToMint`, `DefifaHook_Overspending`, `DefifaHook_ReservedTokenMintingBlockedInNoContest`, `DefifaHook_ReservedTokenMintingPaused`, `DefifaHook_TransfersPaused`.
  - `DefifaHook_Unauthorized`, `DefifaHook_WrongCurrency`, `DefifaTokenUriResolver_AlreadyConfigured`, `DefifaTokenUriResolver_Unauthorized`, `ERC721IncorrectOwner`, `ERC721InsufficientApproval`, `ERC721InvalidApprover`, `ERC721InvalidOperator`.
  - `ERC721InvalidOwner`, `ERC721InvalidReceiver`, `ERC721InvalidSender`, `ERC721NonexistentToken`, `JB721Hook_InvalidCashOut`, `JB721Hook_InvalidPay`, `JB721Hook_InvalidPayValue`, `JB721Hook_UnauthorizedToken`.
  - `JB721Hook_UnexpectedTokenCashedOut`, `OwnableInvalidOwner`, `OwnableUnauthorizedAccount`, `PRBMath_MulDiv_Overflow`, `SafeERC20FailedOperation`, `StringsInsufficientHexLength`.
- Error names removed or replaced:
  - `DefifaDeployer_CantFulfillYet`, `DefifaDeployer_GameOver`, `DefifaDeployer_IncorrectDecimalAmount`, `DefifaDeployer_InvalidFeePercent`, `DefifaDeployer_InvalidGameConfiguration`, `DefifaDeployer_NoContestAlreadyTriggered`, `DefifaDeployer_NotNoContest`, `DefifaDeployer_NothingToFulfill`.
  - `DefifaDeployer_PhaseAlreadyQueued`, `DefifaDeployer_SplitsDontAddUp`, `DefifaDeployer_TerminalNotFound`, `DefifaDeployer_UnexpectedTerminalCurrency`, `DefifaGovernor_AlreadyAttested`, `DefifaGovernor_AlreadyRatified`, `DefifaGovernor_DuplicateScorecard`, `DefifaGovernor_GameNotFound`.
  - `DefifaGovernor_IncorrectTierOrder`, `DefifaGovernor_NotAllowed`, `DefifaGovernor_UnknownProposal`, `DefifaGovernor_UnownedProposedCashoutValue`.

Shared ABI artifacts checked with no ABI item changes:
- `DefifaFontImporter`, `IDefifaGamePhaseReporter`, `IDefifaGamePotReporter`.

## Migration Notes

- Replace every `DefifaDelegate` reference with `DefifaHook` and regenerate ABI types.
- ERC-1155 game positions: paid positions use token ID = tier ID; reserve-minted positions use `tierId + RESERVE_TOKEN_ID_OFFSET` (`1 << 16`) so refunds exclude them after transfers. Both count toward supply, attestation units, and cash-out weight; `tierIdOf(id)` maps back. Encode pay metadata as `(address attestationDelegate, uint16[] tierIds, uint256[] counts)` with tier IDs strictly ascending (collapse repeated tiers into counts), and cash-out metadata as `(uint256[] tokenIds, uint256[] amounts)`. `JB721TiersHookStore` still owns tier config, supply, reserve, and burn accounting, but its per-holder views (`balanceOf`, `tierBalanceOf`, `votingUnitsOf`, `tierVotingUnitsOf`) read 0 for these hooks: read `hook.balanceOf(account, id)` and the hook's attestation views. Mints skip the ERC-1155 receiver callback; transfers are standard safe transfers that call receivers, and approvals are `setApprovalForAll` only. `initialize` named args `_name` / `_symbol` are now `_gameName` / `_gameSymbol`. Index existing ERC-721 games and new ERC-1155 games separately.
- Re-check any scorecard, attestation, or cash-out indexing code against the V6 events. V5 scorecard assumptions are not selector- or payload-stable.
- Do not depend on `DefifaProjectOwner` in V6 deployments.
- `DefifaDeployer` now implements `IJBPayerTracker` and `ERC2771Context`. Its constructor accepts a `trustedForwarder`, and while forwarding a project-creation fee to `JBProjects.createFor`, it advertises the resolved fee payer (the `launchGameWith` ERC-2771 caller) through the transient `originalPayer` getter, so a `pay`-routing fee receiver credits the player who paid rather than the deployer or forwarder. Regenerate ABI types to pick up the constructor and ABI changes.
- `DefifaDeployer` caches its controller's `PROJECTS`, `RULESETS`, and `DIRECTORY` as constructor immutables (resolved once from `CONTROLLER`) instead of reading `CONTROLLER.PROJECTS()` / `CONTROLLER.RULESETS()` / `CONTROLLER.DIRECTORY()` at each use. They are exposed as `IDefifaDeployer` getters alongside `CONTROLLER`; regenerate ABI types to pick them up.
