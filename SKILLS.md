# Defifa

## Purpose

On-chain prediction game framework built on Juicebox V6. Players mint NFT game pieces representing teams/outcomes, a governor-based scorecard system determines tier payouts, and winners burn NFTs to claim proportional shares of the pot plus accumulated fee tokens ($DEFIFA/$NANA).

## Contracts

| Contract | Role |
|----------|------|
| `DefifaDeployer` | Factory that creates games as Juicebox projects with phased rulesets, cloned hooks, and governor initialization. Manages post-game commitment fulfillment. Implements `IDefifaGamePhaseReporter` and `IDefifaGamePotReporter`. |
| `DefifaHook` | ERC-721 hook (extends `JB721Hook`) that manages cash-out weights per tier, attestation delegation with checkpointed voting power, and proportional pot distribution on burn. Deployed as minimal proxy clones via `Clones.cloneDeterministic`. |
| `DefifaGovernor` | Governance contract for scorecard submission, attestation, and ratification with 50% quorum requirement. Shared singleton across all games. |
| `DefifaHookLib` | External library with pure/view helpers: scorecard validation, cash-out weight calculation, fee token distribution, attestation unit aggregation, supply computation. |
| `DefifaTokenUriResolver` | On-chain SVG renderer for game card metadata with phase-aware display, pot size, rarity, and current value. Uses embedded Capsules typeface. |
| `DefifaFontImporter` | Library that loads Capsules typeface font for SVG renderer. |
| `DefifaProjectOwner` | Receives Defifa fee project's ownership NFT and permanently grants the deployer `SET_SPLIT_GROUPS` permission. |

## Key Functions

| Function | Contract | What it does |
|----------|----------|--------------|
| `launchGameWith(data)` | `DefifaDeployer` | Creates a new game: clones the hook via `Clones.cloneDeterministic`, initializes it with tiers and reporters, launches a Juicebox project with phased rulesets (Mint → optional Refund → Scoring), initializes the governor, transfers hook ownership to the governor. Returns the game ID (Juicebox project ID). |
| `fulfillCommitmentsOf(gameId)` | `DefifaDeployer` | After scorecard ratification, sends the fee portion (Defifa fee + protocol fee + user splits) as payouts via `sendPayoutsOf`, then queues a final ruleset with `pausePay=true` and zero payout limits so the remaining pot is available for cash outs. Uses `max(amount, 1)` as reentrancy guard. |
| `triggerNoContestFor(gameId)` | `DefifaDeployer` | Checks safety conditions (min participation or scorecard timeout) and queues a NO_CONTEST ruleset enabling full refunds. Can only be called once per game. |
| `currentGamePhaseOf(gameId)` | `DefifaDeployer` | Returns the current game phase based on ruleset cycle number, cash-out weight state, and no-contest status. Implements `IDefifaGamePhaseReporter`. |
| `currentGamePotOf(gameId, includeCommitments)` | `DefifaDeployer` | Returns pot size, token address, and decimals. If `includeCommitments` is false, subtracts already-fulfilled commitment amount. |
| `timesFor(gameId)` | `DefifaDeployer` | Returns `(start, mintPeriodDuration, refundPeriodDuration)` for a game. |
| `safetyParamsOf(gameId)` | `DefifaDeployer` | Returns `(minParticipation, scorecardTimeout)` for a game. |
| `nextPhaseNeedsQueueing(gameId)` | `DefifaDeployer` | Returns true if the current ruleset has a duration > 0 and the latest queued ruleset is the same as the current one (meaning no new ruleset has been queued yet). |
| `submitScorecardFor(gameId, tierWeights)` | `DefifaGovernor` | Submits a proposed scorecard (array of tier cash-out weights). Hashes the encoded calldata to produce a scorecard ID. Stores attestation begin and grace period end timestamps. Only during SCORING phase. If `defaultAttestationDelegateProposalOf[gameId]` is 0, the first proposal from the default delegate auto-sets it. |
| `attestToScorecardFrom(gameId, scorecardId)` | `DefifaGovernor` | Attests to a scorecard. Weight is proportional to the caller's tier-delegated voting power at the attestation begin timestamp. Each address can only attest once per scorecard. Returns the attestation weight. |
| `ratifyScorecardFrom(gameId, tierWeights)` | `DefifaGovernor` | Ratifies a scorecard that has reached `SUCCEEDED` state (50% quorum). Executes `setTierCashOutWeightsTo` on the hook via low-level `.call`, then calls `fulfillCommitmentsOf`. Scorecard is immutable once ratified. |
| `initializeGame(gameId, attestationStartTime, attestationGracePeriod)` | `DefifaGovernor` | Sets attestation start time and grace period for a game. Grace period minimum is 1 day. Called by the deployer during game launch. |
| `quorum(gameId)` | `DefifaGovernor` | Returns `50% of (MAX_ATTESTATION_POWER_TIER * numberOfMintedTiers)`. Only tiers with non-zero minted supply count toward quorum. |
| `getAttestationWeight(gameId, account, timestamp)` | `DefifaGovernor` | Calculates an account's attestation power across all tiers (up to 128) using checkpointed delegation snapshots at `timestamp` (uint48, not uint256). Per-tier power: `mulDiv(MAX_ATTESTATION_POWER_TIER, accountTierUnits, totalTierUnits)`. |
| `stateOf(gameId, scorecardId)` | `DefifaGovernor` | Returns scorecard state: `RATIFIED` if matches ratified ID, `PENDING` if before attestation begin, `SUCCEEDED` if quorum reached + grace period elapsed, `ACTIVE` if attestation in progress, `DEFEATED` otherwise. |
| `setTierCashOutWeightsTo(tierWeights)` | `DefifaHook` | Sets cash-out weights for each tier. Validates weights sum to exactly `TOTAL_CASHOUT_WEIGHT` (1e18), tiers are in ascending order, and all tiers exist. Only callable by owner (the governor). Only callable during SCORING phase. Once set, cannot be changed (`cashOutWeightIsSet` flag). |
| `afterPayRecordedWith(context)` | `DefifaHook` | Processes payments: validates caller is a project terminal and `msg.value == 0`, then delegates to `_processPayment`. Overrides `JB721Hook` to add the `msg.value != 0` check. |
| `beforeCashOutRecordedWith(context)` | `DefifaHook` | Returns cash-out parameters based on game phase. During MINT/REFUND/NO_CONTEST: returns cumulative mint price as `cashOutCount` (full refund). During SCORING/COMPLETE: returns weighted share based on tier scorecard weights. Uses surplus as `totalSupply`. Returns a `JBCashOutHookSpecification` with `noop: false` (the hook always needs its callback to process burns and fee token distribution). |
| `afterCashOutRecordedWith(context)` | `DefifaHook` | Burns NFTs, validates ownership, tracks redemptions per tier. During COMPLETE phase: increments `amountRedeemed`, distributes proportional $DEFIFA/$NANA tokens to the holder based on `_totalMintCost` share. Reverts with `NothingToClaim` if no ETH and no fee tokens received. Decrements `_totalMintCost` by the burned tokens' cumulative mint price. |
| `cashOutWeightOf(tokenIds)` | `DefifaHook` | Returns the cumulative cash-out weight for an array of token IDs. Each token's weight: `tierWeight / (minted - burned)`, accounting for already-redeemed tokens. Overrides `JB721Hook`. |
| `cashOutWeightOf(tokenId)` | `DefifaHook` | Returns the cash-out weight for a single token ID. |
| `totalCashOutWeight()` | `DefifaHook` | Returns `TOTAL_CASHOUT_WEIGHT` (1e18). Overrides `JB721Hook`. |
| `setTierDelegateTo(delegatee, tierId)` | `DefifaHook` | Delegates attestation voting power for a specific tier to another address. Only during MINT phase. Reverts during other phases. |
| `setTierDelegatesTo(delegations)` | `DefifaHook` | Batch variant. Sets delegates for multiple tiers at once. Only during MINT phase. |
| `mintReservesFor(tierId, count)` | `DefifaHook` | Mints reserved tokens for a tier. Auto-delegates to default attestation delegate if no delegate set. Increments `_totalMintCost` by `tier.price * count` so reserved recipients get their share of fee tokens. |
| `initialize(gameId, name, symbol, ...)` | `DefifaHook` | One-time initialization for a cloned hook. Sets project ID, name, symbol, store, rulesets, reporters, tiers, tier names, and default attestation delegate. Reverts if called on code origin or if already initialized. |

## Integration Points

| Dependency | Import | Used For |
|------------|--------|----------|
| `@bananapus/core-v6` | `IJBController`, `IJBDirectory`, `IJBRulesets`, `IJBTerminal`, `IJBMultiTerminal`, `JBRulesetConfig`, `JBSplit`, `JBConstants`, `JBMetadataResolver` | Project creation, ruleset management, terminal interactions, payout distribution, metadata encoding. |
| `@bananapus/721-hook-v6` | `JB721Hook`, `IJB721TiersHookStore`, `JB721TierConfig`, `JB721Tier`, `ERC721`, `JB721TiersRulesetMetadataResolver` | Hook base class, NFT tier management, tier storage, transfer pause checking. |
| `@bananapus/address-registry-v6` | `IJBAddressRegistry` | Hook address registration for discoverability. |
| `@bananapus/permission-ids-v6` | `JBPermissionIds` | Permission constants for split management (`SET_SPLIT_GROUPS`). |
| `@openzeppelin/contracts` | `Ownable`, `Clones`, `IERC721Receiver`, `SafeERC20`, `Checkpoints`, `Strings`, `IERC20` | Access control, minimal proxy cloning, safe token handling, checkpointed voting, string formatting, fee token transfers. |
| `@prb/math` | `mulDiv` | Precise fixed-point arithmetic for attestation weight and pot distribution calculations. |

## Key Types

| Struct/Enum | Key Fields | Used In |
|-------------|------------|---------|
| `DefifaLaunchProjectData` | `name`, `projectUri`, `contractUri`, `baseUri`, `tiers` (DefifaTierParams[]), `tierPrice` (uint104), `token` (JBAccountingContext), `mintPeriodDuration` (uint24), `refundPeriodDuration` (uint24), `start` (uint48), `splits` (JBSplit[]), `attestationStartTime`, `attestationGracePeriod`, `defaultAttestationDelegate`, `defaultTokenUriResolver` (IJB721TokenUriResolver), `terminal`, `store`, `minParticipation` (uint256), `scorecardTimeout` (uint32) | `DefifaDeployer.launchGameWith` |
| `DefifaTierParams` | `name` (string), `reservedRate` (uint16), `reservedTokenBeneficiary` (address), `encodedIPFSUri` (bytes32), `shouldUseReservedTokenBeneficiaryAsDefault` (bool) | `DefifaLaunchProjectData.tiers` |
| `DefifaTierCashOutWeight` | `id` (uint256), `cashOutWeight` (uint256) | Scorecard proposals, `DefifaHook.setTierCashOutWeightsTo` |
| `DefifaOpsData` | `token` (address), `start` (uint48), `mintPeriodDuration` (uint24), `refundPeriodDuration` (uint24), `minParticipation` (uint256), `scorecardTimeout` (uint32) | Internal game state in `DefifaDeployer` |
| `DefifaDelegation` | `delegatee` (address), `tierId` (uint256) | `DefifaHook.setTierDelegatesTo` |
| `DefifaGamePhase` | `COUNTDOWN`, `MINT`, `REFUND`, `SCORING`, `COMPLETE`, `NO_CONTEST` | Phase reporting throughout |
| `DefifaScorecard` | `attestationsBegin` (uint48), `gracePeriodEnds` (uint48) | `DefifaGovernor._scorecardOf` |
| `DefifaAttestations` | `count` (uint256), `hasAttested` (mapping(address => bool)) | `DefifaGovernor._scorecardAttestationsOf` |
| `DefifaScorecardState` | `PENDING`, `ACTIVE`, `DEFEATED`, `SUCCEEDED`, `RATIFIED` | `DefifaGovernor.stateOf` |

## Events

| Event | Contract | Parameters |
|-------|----------|------------|
| `LaunchGame` | `DefifaDeployer` | `gameId` (indexed), `hook` (indexed), `governor` (indexed), `tokenUriResolver`, `caller` |
| `FulfilledCommitments` | `DefifaDeployer` | `gameId` (indexed), `pot`, `caller` |
| `CommitmentPayoutFailed` | `DefifaDeployer` | `gameId` (indexed), `amount`, `reason` (bytes) |
| `DistributeToSplit` | `DefifaDeployer` | `split` (JBSplit), `amount`, `caller` |
| `QueuedNoContest` | `DefifaDeployer` | `gameId` (indexed), `caller` |
| `QueuedRefundPhase` | `DefifaDeployer` | `gameId` (indexed), `caller` |
| `QueuedScoringPhase` | `DefifaDeployer` | `gameId` (indexed), `caller` |
| `Mint` | `DefifaHook` | `tokenId` (indexed), `tierId` (indexed), `beneficiary` (indexed), `totalAmountContributed`, `caller` |
| `MintReservedToken` | `DefifaHook` | `tokenId` (indexed), `tierId` (indexed), `beneficiary` (indexed), `caller` |
| `TierDelegateAttestationsChanged` | `DefifaHook` | `delegate` (indexed), `tierId` (indexed), `previousBalance`, `newBalance`, `caller` |
| `DelegateChanged` | `DefifaHook` | `delegator` (indexed), `fromDelegate` (indexed), `toDelegate` (indexed) |
| `ClaimedTokens` | `DefifaHook` | `beneficiary` (indexed), `defifaTokenAmount`, `baseProtocolTokenAmount`, `caller` |
| `TierCashOutWeightsSet` | `DefifaHook` | `tierWeights` (DefifaTierCashOutWeight[]), `caller` |
| `GameInitialized` | `DefifaGovernor` | `gameId` (indexed), `attestationStartTime`, `attestationGracePeriod`, `caller` |
| `ScorecardSubmitted` | `DefifaGovernor` | `gameId` (indexed), `scorecardId` (indexed), `tierWeights` (DefifaTierCashOutWeight[]), `isDefaultAttestationDelegate`, `caller` |
| `ScorecardAttested` | `DefifaGovernor` | `gameId` (indexed), `scorecardId` (indexed), `weight`, `caller` |
| `ScorecardRatified` | `DefifaGovernor` | `gameId` (indexed), `scorecardId` (indexed), `caller` |

## Errors

| Error | Contract | When |
|-------|----------|------|
| `DefifaDeployer_CantFulfillYet` | `DefifaDeployer` | `fulfillCommitmentsOf` called before scorecard is ratified. |
| `DefifaDeployer_GameOver` | `DefifaDeployer` | Attempting to queue a phase after the game is already complete. |
| `DefifaDeployer_InvalidFeePercent` | `DefifaDeployer` | Fee configuration is invalid. |
| `DefifaDeployer_InvalidGameConfiguration` | `DefifaDeployer` | Launch data fails validation (e.g., missing tiers, bad durations). |
| `DefifaDeployer_IncorrectDecimalAmount` | `DefifaDeployer` | Token accounting context has wrong decimal count. |
| `DefifaDeployer_NotNoContest` | `DefifaDeployer` | Safety conditions for no-contest are not met. |
| `DefifaDeployer_NoContestAlreadyTriggered` | `DefifaDeployer` | `triggerNoContestFor` called more than once for the same game. |
| `DefifaDeployer_TerminalNotFound` | `DefifaDeployer` | No terminal found for the game's project. |
| `DefifaDeployer_PhaseAlreadyQueued` | `DefifaDeployer` | The next phase ruleset has already been queued. |
| `DefifaDeployer_SplitsDontAddUp` | `DefifaDeployer` | Split percentages don't sum correctly. |
| `DefifaDeployer_UnexpectedTerminalCurrency` | `DefifaDeployer` | Terminal's accounting currency doesn't match expected currency. |
| `DefifaHook_BadTierOrder` | `DefifaHook` | Scorecard tier IDs are not in strict ascending order. |
| `DefifaHook_DelegateAddressZero` | `DefifaHook` | Attempting to delegate to the zero address. |
| `DefifaHook_DelegateChangesUnavailableInThisPhase` | `DefifaHook` | Delegation change attempted outside MINT phase. |
| `DefifaHook_GameIsntScoringYet` | `DefifaHook` | `setTierCashOutWeightsTo` called before SCORING phase. |
| `DefifaHook_InvalidTierId` | `DefifaHook` | Tier ID in scorecard doesn't exist. |
| `DefifaHook_InvalidCashoutWeights` | `DefifaHook` | Scorecard tier weights don't sum to exactly `TOTAL_CASHOUT_WEIGHT` (1e18). |
| `DefifaHook_NothingToClaim` | `DefifaHook` | Cash out during COMPLETE yields no ETH and no fee tokens. |
| `DefifaHook_NothingToMint` | `DefifaHook` | Reserved mint attempted with zero count or no available reserves. |
| `DefifaHook_WrongCurrency` | `DefifaHook` | Payment currency doesn't match the hook's pricing currency. |
| `DefifaHook_Overspending` | `DefifaHook` | Payment exceeds allowed amount for the tier. |
| `DefifaHook_CashoutWeightsAlreadySet` | `DefifaHook` | `setTierCashOutWeightsTo` called after weights were already set. |
| `DefifaHook_ReservedTokenMintingPaused` | `DefifaHook` | Reserved token minting is paused in the current ruleset. |
| `DefifaHook_TransfersPaused` | `DefifaHook` | Token transfers are paused in the current ruleset. |
| `DefifaHook_Unauthorized(tokenId, owner, caller)` | `DefifaHook` | Caller doesn't own the token being operated on. |
| `DefifaGovernor_AlreadyAttested` | `DefifaGovernor` | Account already attested to this scorecard. |
| `DefifaGovernor_AlreadyInitialized` | `DefifaGovernor` | `initializeGame` called for a game that's already initialized. |
| `DefifaGovernor_AlreadyRatified` | `DefifaGovernor` | Attempting to submit or ratify when a scorecard is already ratified. |
| `DefifaGovernor_DuplicateScorecard` | `DefifaGovernor` | Submitting a scorecard that produces the same hash as an existing one. |
| `DefifaGovernor_GameNotFound` | `DefifaGovernor` | Game has not been initialized (`_packedScorecardInfoOf` is 0). |
| `DefifaGovernor_IncorrectTierOrder` | `DefifaGovernor` | Tier weights not in ascending order. |
| `DefifaGovernor_NotAllowed` | `DefifaGovernor` | Operation not permitted in the current game phase or scorecard state. |
| `DefifaGovernor_Uint48Overflow` | `DefifaGovernor` | `attestationStartTime` or `attestationGracePeriod` exceeds uint48 max. |
| `DefifaGovernor_UnknownProposal` | `DefifaGovernor` | `stateOf` called with a scorecard ID that hasn't been submitted. |
| `DefifaGovernor_UnownedProposedCashoutValue` | `DefifaGovernor` | Scorecard assigns non-zero weight to a tier with zero minted supply. |

## Storage

| Variable | Type | Contract | Description |
|----------|------|----------|-------------|
| `_tierCashOutWeights` | `uint256[128]` | `DefifaHook` | Fixed-size array of cash-out weights per tier, set once by the governor via `setTierCashOutWeightsTo`. |
| `cashOutWeightIsSet` | `bool` | `DefifaHook` | Flag indicating whether cash-out weights have been set. Prevents re-setting. |
| `amountRedeemed` | `uint256` | `DefifaHook` | Cumulative ETH redeemed from the game pot (refunds not counted). |
| `_totalMintCost` | `uint256` | `DefifaHook` | Cumulative mint price of all live tokens. Denominator for fee token distribution. Incremented on pay/reserve mint, decremented on cash out. |
| `tokensRedeemedFrom` | `mapping(uint256 => uint256)` | `DefifaHook` | Number of tokens redeemed per tier. |
| `ratifiedScorecardIdOf` | `mapping(uint256 => uint256)` | `DefifaGovernor` | Maps game ID to the ratified scorecard ID (0 if none). |
| `_packedScorecardInfoOf` | `mapping(uint256 => uint256)` | `DefifaGovernor` | Bit-packed governance params per game: attestation start time (bits 0-47), attestation grace period (bits 48-95). |
| `_scorecardOf` | `mapping(uint256 => mapping(uint256 => DefifaScorecard))` | `DefifaGovernor` | Maps (gameId, scorecardId) to scorecard data (attestationsBegin, gracePeriodEnds). |
| `_scorecardAttestationsOf` | `mapping(uint256 => mapping(uint256 => DefifaAttestations))` | `DefifaGovernor` | Maps (gameId, scorecardId) to attestation data (count, per-account flag). |
| `defaultAttestationDelegateProposalOf` | `mapping(uint256 => uint256)` | `DefifaGovernor` | Maps game ID to the scorecard ID submitted by the default attestation delegate. |
| `fulfilledCommitmentsOf` | `mapping(uint256 => uint256)` | `DefifaDeployer` | Maps game ID to fulfilled commitment amount. Non-zero means commitments fulfilled; value of 1 is a sentinel for reentrancy guard. |
| `noContestTriggeredFor` | `mapping(uint256 => bool)` | `DefifaDeployer` | Maps game ID to whether no-contest has been triggered. Can only be set once. |
| `_opsOf` | `mapping(uint256 => DefifaOpsData)` | `DefifaDeployer` | Maps game ID to operational data (token, start, durations, safety params). |
| `_commitmentPercentOf` | `mapping(uint256 => uint256)` | `DefifaDeployer` | Maps game ID to the total commitment percentage (fees + splits). |

## Constants

| Constant | Value | Location | Meaning |
|----------|-------|----------|---------|
| `TOTAL_CASHOUT_WEIGHT` | `1_000_000_000_000_000_000` (1e18) | `DefifaHook` | Total weight that scorecard tier weights must sum to exactly. |
| `MAX_ATTESTATION_POWER_TIER` | `1_000_000_000` | `DefifaGovernor` | Per-tier attestation power cap. Each minted tier contributes this amount to quorum regardless of supply. |
| `BASE_PROTOCOL_FEE_DIVISOR` | `40` | `DefifaDeployer` | 2.5% fee to the base protocol project. |
| `DEFIFA_FEE_DIVISOR` | `20` | `DefifaDeployer` | 5% fee to the Defifa project. |
| Max tiers | `128` | `DefifaHook` | `_tierCashOutWeights` is a fixed `uint256[128]` array. |
| Grace period minimum | `1 day` | `DefifaGovernor` | Minimum attestation grace period enforced during `initializeGame`. |

## Cash-Out Logic by Phase

| Phase | `cashOutCount` | `totalSupply` | Effect |
|-------|---------------|---------------|--------|
| `MINT` / `REFUND` / `NO_CONTEST` | Cumulative mint price of tokens | Surplus | Full refund at mint price |
| `SCORING` (no scorecard) | 0 | Surplus | Reverts (nothing to claim) |
| `SCORING` / `COMPLETE` (scorecard set) | Weighted share of surplus minus amount already redeemed | Surplus | Proportional pot distribution based on tier weights |

During COMPLETE phase cash outs, players also receive proportional $DEFIFA and $NANA tokens based on their tokens' cumulative mint price relative to `_totalMintCost`.

## Attestation & Governance

- Each tier contributes equal `MAX_ATTESTATION_POWER_TIER` to quorum regardless of supply -- a tier with 1 NFT has the same governance weight as a tier with 100.
- Attestation power per account per tier: `mulDiv(MAX_ATTESTATION_POWER_TIER, accountTierUnits, totalTierUnits)`.
- Quorum: `50% of (MAX_ATTESTATION_POWER_TIER * numberOfMintedTiers)`. Only tiers with at least one minted token count.
- Attestation snapshots are taken at the scorecard's `attestationsBegin` timestamp, locking voting power to prevent post-submission manipulation.
- Each address can only attest once per scorecard.
- The grace period (minimum 1 day) prevents instant ratification after quorum is reached.

## Gotchas

- `TOTAL_CASHOUT_WEIGHT` is 1e18. Submitted scorecard tier weights must sum to **exactly** this value or `setTierCashOutWeightsTo` reverts with `DefifaHook_InvalidCashoutWeights`. No tolerance.
- Tier IDs in a scorecard must be in **strict ascending order** with no duplicates, or validation reverts with `DefifaHook_BadTierOrder`.
- Tier IDs are limited to 128 (`uint256[128] _tierCashOutWeights`). Games with more than 128 tiers are not supported.
- `DefifaHook` is deployed as a **minimal proxy clone** (`Clones.cloneDeterministic`). The `initialize` function can only be called once -- the code origin reverts (has `store != address(0)` after its own construction prevents re-init).
- All tiers share the same price (`tierPrice` on `DefifaLaunchProjectData`). The hook enforces this uniformity.
- Delegation changes are **only allowed during MINT phase**. During REFUND, SCORING, and COMPLETE, attestation delegation is frozen to prevent manipulation. Calling `setTierDelegateTo` outside MINT reverts with `DefifaHook_DelegateChangesUnavailableInThisPhase`.
- Scorecard attestation weight uses `mulDiv(MAX_ATTESTATION_POWER_TIER, userTierUnits, totalTierUnits)` per tier. If `totalTierUnits` is 0 for a tier (no delegations), that tier contributes no attestation power.
- The governor's `quorum` is **dynamic**: it only counts tiers that have at least one minted token. Adding minted tiers changes the quorum retroactively for all active proposals.
- `ratifyScorecardFrom` executes the scorecard via a **low-level `.call`** to the hook address. This is necessary because the hook's `setTierCashOutWeightsTo` is `onlyOwner` and the governor is the hook's owner.
- `fulfillCommitmentsOf` uses `max(amount, 1)` as a reentrancy guard. If called when the pot is 0, it stores 1 as the fulfilled amount to prevent re-entry. `sendPayoutsOf` is wrapped in try-catch: on failure, resets to sentinel (1) and emits `CommitmentPayoutFailed`.
- `_buildSplits` normalizes all split percentages relative to the total absolute percent. Rounding remainder is absorbed by the protocol fee split (last in the array).
- `_totalMintCost` tracks cumulative mint prices of all live tokens (paid + reserved). It's incremented on pay and reserve mint, decremented on cash out. This is the denominator for fee token ($DEFIFA/$NANA) distribution.
- Cash outs during COMPLETE phase revert with `DefifaHook_NothingToClaim` if **both** the reclaimed ETH amount is 0 **and** no fee tokens were transferred. This prevents burning NFTs for nothing.
- `minParticipation` is compared against the terminal's surplus. If surplus never reaches this value, `triggerNoContestFor` can be called to enter NO_CONTEST. A value of 0 disables this check.
- `scorecardTimeout` counts seconds from when SCORING begins. If no scorecard is ratified within this window, `triggerNoContestFor` can be called. A value of 0 disables this check.
- `triggerNoContestFor` can only be called once per game. It queues a new ruleset enabling full refunds and is irreversible.
- `afterPayRecordedWith` overrides `JB721Hook`'s version to add a `msg.value != 0` check. The base `JB721Hook` does not include this check.
- Token IDs follow the `JB721TiersHookStore` encoding: `tierId * 1_000_000_000 + tokenNumber`.
- Metadata IDs for pay and cashout use the **code origin address** (the uncloned implementation), not the clone address: `JBMetadataResolver.getId("pay", codeOrigin)`.

## Example Integration

```solidity
import {IDefifaDeployer} from "./interfaces/IDefifaDeployer.sol";
import {DefifaLaunchProjectData} from "./structs/DefifaLaunchProjectData.sol";
import {DefifaTierParams} from "./structs/DefifaTierParams.sol";
import {DefifaTierCashOutWeight} from "./structs/DefifaTierCashOutWeight.sol";

// 1. Launch a game with 2 teams
DefifaTierParams[] memory tiers = new DefifaTierParams[](2);
tiers[0] = DefifaTierParams({
    name: "Team A",
    reservedRate: 1001, // no reserves
    reservedTokenBeneficiary: address(0),
    encodedIPFSUri: bytes32(0),
    shouldUseReservedTokenBeneficiaryAsDefault: false
});
tiers[1] = DefifaTierParams({
    name: "Team B",
    reservedRate: 1001,
    reservedTokenBeneficiary: address(0),
    encodedIPFSUri: bytes32(0),
    shouldUseReservedTokenBeneficiaryAsDefault: false
});

uint256 gameId = deployer.launchGameWith(DefifaLaunchProjectData({
    name: "Championship",
    tierPrice: 0.01 ether,
    tiers: tiers,
    start: uint48(block.timestamp + 7 days),
    mintPeriodDuration: 3 days,
    refundPeriodDuration: 1 days,
    minParticipation: 0,       // no minimum
    scorecardTimeout: 7 days,  // 7-day timeout
    // ... other fields
}));

// 2. Submit a scorecard (Team A wins 70%, Team B gets 30%)
DefifaTierCashOutWeight[] memory weights = new DefifaTierCashOutWeight[](2);
weights[0] = DefifaTierCashOutWeight({id: 1, cashOutWeight: 7e17});
weights[1] = DefifaTierCashOutWeight({id: 2, cashOutWeight: 3e17});
// Total must equal 1e18

uint256 scorecardId = governor.submitScorecardFor(gameId, weights);

// 3. Attest to the scorecard (weight based on tier delegation)
governor.attestToScorecardFrom(gameId, scorecardId);

// 4. Ratify once quorum is reached and grace period elapsed
governor.ratifyScorecardFrom(gameId, weights);

// 5. Players burn NFTs via terminal cash-out to claim their share
//    They receive proportional ETH + proportional $DEFIFA/$NANA tokens
```
