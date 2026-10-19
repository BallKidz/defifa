# V5 to V6 Changelog

## Scope

This is a V5-to-V6 migration changelog, not a package release log or commit history. It compares `defifa-v5` in `../../v5/evm` with the current V6 `defifa` repo.

## Current V6 Surface

- `DefifaDeployer`
- `DefifaGovernor`
- `DefifaHook` (ERC-721 game)
- `Defifa1155Hook` (ERC-1155 game)
- `DefifaTiersHookStore`
- `DefifaTokenUriResolver`
- Defifa enums, interfaces, libraries, and structs under `src/`

## Summary

- Added the ERC-1155 game type next to the ERC-721 game. `Defifa1155Hook` (with `IDefifa1155Hook` and `Defifa1155HookLib`) holds positions as OpenZeppelin `ERC1155` balances, one per tier, so a payment mints a count per tier in one transfer. Per-position ERC-721 mints cost about 47k gas each, which caps one entry near 160 positions under Base's 2^24 per-transaction gas cap with the SDK's 2x gas headroom; the ERC-1155 game pays for 1,000 positions across 8 tiers in about 1.63M gas. `DefifaHook` remains the ERC-721 game. `DefifaDeployer` and `DefifaGovernor` are hook-agnostic, and each game type gets its own deployer plus governor pair. Both pairs share one `DefifaTiersHookStore` (`JB721TiersHookStore` plus count-based `recordMintCounts`, `recordBurnCounts` and `recordTransferForTier(tierId, from, to, count)`) and one `DefifaTokenUriResolver`, which resolves the tier with the hook's `tierIdOf`. `DefifaHook` and `IDefifaHook` gain `tierIdOf(uint256)`, so the `IDefifaHook` ERC-165 interface ID changes, and this resolver does not work with `DefifaHook` versions deployed before it. `DefifaHookLib` exposes `computeTierCashOutWeight` and an internal `tokensClaimFor` so both hooks use one formula. Both hooks fix a delegation bug: a reserve mint with nothing to mint, or in a tier without a reserve beneficiary, could set `_tierDelegation[address(0)]`, which later mints then charged as the default delegate, reverting pays. `mintReservesFor` now returns before any delegation write in that case, and mints and burns never read the zero address's delegate.
- Refund-phase cash-outs (MINT, REFUND, NO_CONTEST) that include a reserve-minted position now revert with `DefifaHook_CantRefundReserveMint(tokenId)` (`Defifa1155Hook_CantRefundReserveMint(tokenId)` in the ERC-1155 game) instead of pricing it at 0. Skipping it left its notional cost in `totalMintCost` and counted it in `refundedBurnsFrom`. Reserves exist only from SCORING on, so in practice this applies in NO_CONTEST. This changes the ERC-721 game's behavior: holders must leave reserve NFTs out of refund cash-outs.
- Both hooks take `(directory, tokens, defifaProjectId, baseProtocolProjectId)` instead of the two fee-token addresses, and `DEFIFA_TOKEN()` / `BASE_PROTOCOL_TOKEN()` look the tokens up in `JBTokens` by project ID. A project's token is set once, so the lookup never changes, and every constructor input is the same on all chains, so each Defifa contract has one address on mainnets and testnets. The constructor now rejects one project for both fee streams (`DefifaHook_IdenticalFeeProjects` / `Defifa1155Hook_IdenticalFeeProjects`).
- `DefifaDelegate` is now `DefifaHook`. Integrations should update both naming and ABI assumptions.
- `DefifaProjectOwner` was removed. The canonical fee project ownership path now belongs to the V6 revnet / `REVOwner` setup rather than a Defifa-specific sink contract.
- Chain-specific configuration was removed from the main deployer flow where values are deterministic or canonical. V6 binds those dependencies through constructor immutables and deterministic deployment inputs.
- Scorecard and attestation handling is stricter. V6 snapshots attestation power before submission and rejects duplicate or malformed scorecard state more explicitly.
- The concentration-adjusted quorum is capped `MAX_ATTESTATION_POWER_TIER / 10_000` per eligible tier below the maximum BWA, so unanimous attestation reaches it even when BWA truncates per (delegate, tier) pair. The earlier allowance of one unit per submitted tier weight left winner-take-all scorecards in tiers with several holders unable to reach quorum.
- Game launch and commitment accounting are aligned with the V6 Juicebox and 721 hook stack, including tier cash-out weights and V6 hook events.

## ABI, Event, and Error Changes

- Replaced interface and contract naming:
  - `IDefifaDelegate` / `DefifaDelegate` -> `IDefifaHook` / `DefifaHook`
- Added ERC-1155 game surface (`IDefifa1155Hook` extends `IJBRulesetDataHook`, `IJBPayHook`, `IJBCashOutHook`; it is not an `IJB721Hook`):
  - compared with `IDefifaHook`: no `firstOwnerOf`, `isReserveMint`, `tokenURI`, `totalCashOutWeight()` (use the `TOTAL_CASHOUT_WEIGHT` constant), or ERC-721 `ownerOf` / `transferFrom` / `approve`
  - adds `uri`, `name`, `symbol`, `RESERVE_TOKEN_ID_OFFSET`, `METADATA_ID_TARGET`, `cashOutWeightOf(uint256[] tokenIds, uint256[] amounts)`, and `tokensClaimableFor(uint256[] tokenIds, uint256[] amounts)`; `cashOutWeightOf(uint256)` is the weight of one position
  - `Mint(uint256 indexed tierId, address indexed beneficiary, uint256 count, uint256 totalAmountContributed, address caller)` and `MintReservedToken(uint256 indexed tierId, address indexed beneficiary, uint256 count, address caller)` carry a tier ID and count; ERC-1155 `TransferSingle` / `TransferBatch` and `ApprovalForAll` replace ERC-721 `Transfer` and `Approval`
  - errors are prefixed `Defifa1155Hook_` (for example `Defifa1155Hook_InvalidPay`, `Defifa1155Hook_Unauthorized(tokenId, amount, balance, holder)`, `Defifa1155Hook_LengthMismatch`, `Defifa1155Hook_InvalidTokenId`, `Defifa1155Hook_ZeroAmount`, `Defifa1155Hook_CantRefundReserveMint`); repeated or unordered pay tiers revert `DefifaHook_BadTierOrder` from `DefifaHookLib`
  - `initialize` takes `_gameName` / `_gameSymbol` where `DefifaHook` takes `_name` / `_symbol`
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
  - `DefifaHook_CantRefundReserveMint`
  - `DefifaHook_CashoutWeightsAlreadySet`
  - `DefifaHook_GameIsntScoringYet`
  - `DefifaHook_InvalidCashoutWeights`
  - `DefifaHook_ReservedTokenMintingBlockedInNoContest`
  - `DefifaGovernor_DuplicateScorecard`
  - `DefifaGovernor_UnownedProposedCashoutValue`

## Machine-Checked ABI Coverage

Generated from Foundry `out/**/*.json` artifacts before the ERC-1155 game type was added (`Defifa1155Hook`, `IDefifa1155Hook`, `Defifa1155HookLib`, `DefifaTiersHookStore` and `IDefifaTiersHookStore` are not counted; see the ABI section above), filtered to this repo's own runtime source roots and excluding tests, scripts, and dependencies.

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
  - `DefifaGovernor_UnknownProposal`, `DefifaGovernor_UnownedProposedCashoutValue`, `DefifaHook_BadTierOrder`, `DefifaHook_CashoutWeightsAlreadySet`, `DefifaHook_DelegateAddressZero`, `DefifaHook_DelegateChangesUnavailableInThisPhase`, `DefifaHook_GameIsntScoringYet`, `DefifaHook_IdenticalFeeProjects`.
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
- ERC-1155 games: paid positions use token ID = tier ID; reserve-minted positions use `tierId + RESERVE_TOKEN_ID_OFFSET` (`1 << 16`) so refunds reject them after transfers. Both count toward supply, attestation units, and cash-out weight; `tierIdOf(id)` maps back. Encode pay metadata as `(address attestationDelegate, uint16[] tierIds, uint256[] counts)` with tier IDs strictly ascending (collapse repeated tiers into counts), and cash-out metadata as `(uint256[] tokenIds, uint256[] amounts)`. The store's per-holder views count a tier's paid and reserve IDs together; read a single ID with `hook.balanceOf(account, id)`. Mints run the ERC-1155 receiver acceptance check after every state change, so a contract beneficiary must implement `onERC1155Received` / `onERC1155BatchReceived` or the pay (or that reserve mint) reverts; transfers are standard safe transfers that call receivers, and approvals are `setApprovalForAll` only. Detect the game type (ERC-165 `IERC1155`) before encoding metadata, and index ERC-721 and ERC-1155 games separately.
- Re-check any scorecard, attestation, or cash-out indexing code against the V6 events. V5 scorecard assumptions are not selector- or payload-stable.
- Do not depend on `DefifaProjectOwner` in V6 deployments.
- `DefifaDeployer` now implements `IJBPayerTracker` and `ERC2771Context`. Its constructor accepts a `trustedForwarder`, and while forwarding a project-creation fee to `JBProjects.createFor`, it advertises the resolved fee payer (the `launchGameWith` ERC-2771 caller) through the transient `originalPayer` getter, so a `pay`-routing fee receiver credits the player who paid rather than the deployer or forwarder. Regenerate ABI types to pick up the constructor and ABI changes.
- `DefifaDeployer` caches its controller's `PROJECTS`, `RULESETS`, and `DIRECTORY` as constructor immutables (resolved once from `CONTROLLER`) instead of reading `CONTROLLER.PROJECTS()` / `CONTROLLER.RULESETS()` / `CONTROLLER.DIRECTORY()` at each use. They are exposed as `IDefifaDeployer` getters alongside `CONTROLLER`; regenerate ABI types to pick them up.
