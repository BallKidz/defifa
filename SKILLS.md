# Defifa

## Purpose

On-chain prediction game framework built on Juicebox V6. Players mint NFT game pieces representing teams/outcomes, a governor-based scorecard system determines tier payouts, and winners burn NFTs to claim proportional shares of the pot plus accumulated fee tokens ($DEFIFA/$NANA).

## Game Lifecycle

```
                     start time reached
   COUNTDOWN ──────────────────────────────► MINT
                                              │
                              mintPeriodDuration expires
                                              │
                  ┌───────────────────────────┤
                  │                           ▼
                  │ (refundPeriodDuration=0)  REFUND
                  │                           │
                  │           refundPeriodDuration expires
                  │                           │
                  ├◄──────────────────────────┘
                  ▼
               SCORING
                  │
                  ├── scorecard ratified + commitments fulfilled ──► COMPLETE
                  │
                  └── safety trigger (minParticipation not met
                      OR scorecardTimeout elapsed) ──────────────► NO_CONTEST
                                                                  (full refunds)
```

- **COUNTDOWN**: Before `start`. No minting.
- **MINT**: Players mint NFTs and delegate attestation power. Delegation changes only allowed here.
- **REFUND**: Optional. Players can burn NFTs for full refund at mint price. Skipped if `refundPeriodDuration=0`.
- **SCORING**: Scorecards are submitted, attested, and ratified. Cash outs blocked until scorecard is set.
- **COMPLETE**: Commitments fulfilled. Players burn NFTs for weighted pot share + fee tokens.
- **NO_CONTEST**: Safety exit. Full refunds enabled. Irreversible once triggered.

## Contracts

| Contract | Role |
|----------|------|
| `DefifaDeployer` | Factory that creates games as Juicebox projects with phased rulesets, cloned hooks, and governor initialization. Manages post-game commitment fulfillment. Implements `IDefifaGamePhaseReporter` and `IDefifaGamePotReporter`. |
| `DefifaHook` | ERC-721 hook (extends `JB721Hook`) managing cash-out weights, attestation delegation with checkpointed voting, and proportional pot distribution. Deployed as minimal proxy clones. |
| `DefifaGovernor` | Shared singleton for scorecard submission, attestation, and ratification. |
| `DefifaHookLib` | External library: scorecard validation, cash-out weight calculation, fee token distribution, attestation aggregation. |
| `DefifaTokenUriResolver` | On-chain SVG renderer for game card metadata with phase-aware display. Uses embedded Capsules typeface. |
| `DefifaFontImporter` | Loads Capsules typeface font for SVG renderer. |
| `DefifaProjectOwner` | Receives Defifa fee project's ownership NFT and permanently grants the deployer `SET_SPLIT_GROUPS` permission. |

## Key Functions

| Function | Contract | What it does |
|----------|----------|--------------|
| `launchGameWith(data)` | `DefifaDeployer` | Creates a game: clones the hook, launches a Juicebox project with phased rulesets, initializes the governor, transfers hook ownership to the governor. Returns the game ID. |
| `fulfillCommitmentsOf(gameId)` | `DefifaDeployer` | After ratification, sends fee payouts via `sendPayoutsOf`, then queues a final ruleset enabling cash outs. |
| `triggerNoContestFor(gameId)` | `DefifaDeployer` | Checks safety conditions and queues a NO_CONTEST ruleset enabling full refunds. Once per game. |
| `currentGamePhaseOf(gameId)` | `DefifaDeployer` | Returns the current `DefifaGamePhase`. |
| `currentGamePotOf(gameId, includeCommitments)` | `DefifaDeployer` | Returns pot size, token address, and decimals. |
| `timesFor(gameId)` | `DefifaDeployer` | Returns `(start, mintPeriodDuration, refundPeriodDuration)`. |
| `safetyParamsOf(gameId)` | `DefifaDeployer` | Returns `(minParticipation, scorecardTimeout)`. |
| `nextPhaseNeedsQueueing(gameId)` | `DefifaDeployer` | True if the next phase ruleset hasn't been queued yet. |
| `submitScorecardFor(gameId, tierWeights)` | `DefifaGovernor` | Submits a scorecard proposal. Only during SCORING. |
| `attestToScorecardFrom(gameId, scorecardId)` | `DefifaGovernor` | Attests to a scorecard using tier-delegated voting power. One attestation per address per scorecard. |
| `ratifyScorecardFrom(gameId, tierWeights)` | `DefifaGovernor` | Ratifies a `SUCCEEDED` scorecard (50% quorum met + grace period elapsed). Executes weights on the hook, then fulfills commitments. |
| `initializeGame(gameId, ...)` | `DefifaGovernor` | Sets attestation start time and grace period. Called by deployer during launch. |
| `quorum(gameId)` | `DefifaGovernor` | Returns the quorum threshold. See Attestation & Governance for formula. |
| `getAttestationWeight(gameId, account, timestamp)` | `DefifaGovernor` | Returns an account's attestation power. See Attestation & Governance for formula. |
| `stateOf(gameId, scorecardId)` | `DefifaGovernor` | Returns scorecard state: `RATIFIED`, `PENDING`, `SUCCEEDED`, `ACTIVE`, or `DEFEATED`. |
| `setTierCashOutWeightsTo(tierWeights)` | `DefifaHook` | Sets cash-out weights. Weights must sum to exactly `TOTAL_CASHOUT_WEIGHT` (1e18). Owner-only (governor), SCORING phase only, one-time. |
| `afterPayRecordedWith(context)` | `DefifaHook` | Processes payments. Adds `msg.value != 0` check over base `JB721Hook`. |
| `beforeCashOutRecordedWith(context)` | `DefifaHook` | Returns cash-out parameters based on game phase. Always returns `noop: false`. |
| `afterCashOutRecordedWith(context)` | `DefifaHook` | Burns NFTs and tracks redemptions. During COMPLETE, also distributes fee tokens. |
| `cashOutWeightOf(tokenIds)` | `DefifaHook` | Cumulative cash-out weight for token IDs: `tierWeight / (minted - burned)` per token. |
| `totalCashOutWeight()` | `DefifaHook` | Returns `TOTAL_CASHOUT_WEIGHT` (1e18). |
| `setTierDelegateTo(delegatee, tierId)` | `DefifaHook` | Delegates attestation power for a tier. MINT phase only. |
| `setTierDelegatesTo(delegations)` | `DefifaHook` | Batch delegation. MINT phase only. |
| `mintReservesFor(tierId, count)` | `DefifaHook` | Mints reserved tokens. Increments `_totalMintCost` so reserved recipients share fee tokens. |
| `initialize(gameId, ...)` | `DefifaHook` | One-time init for cloned hook. Sets project ID, store, reporters, tiers, and default attestation delegate. |

## Integration Points

| Dependency | Import | Used For |
|------------|--------|----------|
| `@bananapus/core-v6` | `IJBController`, `IJBDirectory`, `IJBRulesets`, `IJBTerminal`, `IJBMultiTerminal`, `JBRulesetConfig`, `JBSplit`, `JBConstants`, `JBMetadataResolver` | Project creation, ruleset management, terminal interactions, payout distribution, metadata encoding. |
| `@bananapus/721-hook-v6` | `JB721Hook`, `IJB721TiersHookStore`, `JB721TierConfig`, `JB721Tier`, `ERC721`, `JB721TiersRulesetMetadataResolver` | Hook base class, NFT tier management, tier storage, transfer pause checking. |
| `@bananapus/address-registry-v6` | `IJBAddressRegistry` | Hook address registration for discoverability. |
| `@bananapus/permission-ids-v6` | `JBPermissionIds` | Permission constants (`SET_SPLIT_GROUPS`). |
| `@openzeppelin/contracts` | `Ownable`, `Clones`, `IERC721Receiver`, `SafeERC20`, `Checkpoints`, `Strings`, `IERC20` | Access control, minimal proxy cloning, safe token handling, checkpointed voting, string formatting, fee token transfers. |
| `@prb/math` | `mulDiv` | Fixed-point arithmetic for attestation weight and pot distribution. |

## Key Types

| Struct/Enum | Key Fields | Used In |
|-------------|------------|---------|
| `DefifaLaunchProjectData` | `name`, `projectUri`, `contractUri`, `baseUri`, `tiers` (DefifaTierParams[]), `tierPrice` (uint104), `token` (JBAccountingContext), `mintPeriodDuration` (uint24), `refundPeriodDuration` (uint24), `start` (uint48), `splits` (JBSplit[]), `attestationStartTime`, `attestationGracePeriod`, `defaultAttestationDelegate`, `defaultTokenUriResolver` (IJB721TokenUriResolver), `terminal`, `store`, `minParticipation` (uint256), `scorecardTimeout` (uint32) | `DefifaDeployer.launchGameWith` |
| `DefifaTierParams` | `name` (string), `reservedRate` (uint16), `reservedTokenBeneficiary` (address), `encodedIPFSUri` (bytes32), `shouldUseReservedTokenBeneficiaryAsDefault` (bool) | `DefifaLaunchProjectData.tiers` |
| `DefifaTierCashOutWeight` | `id` (uint256), `cashOutWeight` (uint256) | Scorecard proposals, `DefifaHook.setTierCashOutWeightsTo` |
| `DefifaOpsData` | `token` (address), `start` (uint48), `mintPeriodDuration` (uint24), `refundPeriodDuration` (uint24), `minParticipation` (uint256), `scorecardTimeout` (uint32) | Internal game state in `DefifaDeployer` |
| `DefifaDelegation` | `delegatee` (address), `tierId` (uint256) | `DefifaHook.setTierDelegatesTo` |
| `DefifaGamePhase` | `COUNTDOWN`, `MINT`, `REFUND`, `SCORING`, `COMPLETE`, `NO_CONTEST` | Phase reporting throughout |
| `DefifaScorecard` | `attestationsBegin` (uint48), `gracePeriodEnds` (uint48), `quorumSnapshot` (uint256) — set at submission time, used by `stateOf()` for ratification check | `DefifaGovernor._scorecardOf` |
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
| `_tierCashOutWeights` | `uint256[128]` | `DefifaHook` | Fixed-size array of cash-out weights per tier, set once by the governor. |
| `cashOutWeightIsSet` | `bool` | `DefifaHook` | Flag preventing re-setting of cash-out weights. |
| `amountRedeemed` | `uint256` | `DefifaHook` | Cumulative ETH redeemed from the pot (refunds not counted). |
| `_totalMintCost` | `uint256` | `DefifaHook` | Cumulative mint price of all live tokens. Denominator for fee token distribution. |
| `tokensRedeemedFrom` | `mapping(uint256 => uint256)` | `DefifaHook` | Number of tokens redeemed per tier. |
| `ratifiedScorecardIdOf` | `mapping(uint256 => uint256)` | `DefifaGovernor` | Maps game ID to the ratified scorecard ID (0 if none). |
| `_packedScorecardInfoOf` | `mapping(uint256 => uint256)` | `DefifaGovernor` | Bit-packed: attestation start time (bits 0-47), grace period (bits 48-95). |
| `_scorecardOf` | `mapping(uint256 => mapping(uint256 => DefifaScorecard))` | `DefifaGovernor` | Maps (gameId, scorecardId) to scorecard data. |
| `_scorecardAttestationsOf` | `mapping(uint256 => mapping(uint256 => DefifaAttestations))` | `DefifaGovernor` | Maps (gameId, scorecardId) to attestation data. |
| `defaultAttestationDelegateProposalOf` | `mapping(uint256 => uint256)` | `DefifaGovernor` | Maps game ID to the scorecard ID submitted by the default attestation delegate. |
| `fulfilledCommitmentsOf` | `mapping(uint256 => uint256)` | `DefifaDeployer` | Non-zero means commitments fulfilled; value of 1 is a sentinel for reentrancy guard. |
| `noContestTriggeredFor` | `mapping(uint256 => bool)` | `DefifaDeployer` | Whether no-contest has been triggered. Can only be set once. |
| `_opsOf` | `mapping(uint256 => DefifaOpsData)` | `DefifaDeployer` | Operational data (token, start, durations, safety params). |
| `_commitmentPercentOf` | `mapping(uint256 => uint256)` | `DefifaDeployer` | Total commitment percentage (fees + splits). |

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

- **Per-tier power**: `mulDiv(MAX_ATTESTATION_POWER_TIER, accountTierUnits, totalTierUnits)`. Each tier contributes equal weight regardless of supply -- a tier with 1 NFT has the same governance weight as a tier with 100.
- **Quorum**: `50% of (MAX_ATTESTATION_POWER_TIER * numberOfMintedTiers)`. Only tiers with at least one minted token count.
- Snapshots taken at the scorecard's `attestationsBegin` timestamp, locking voting power to prevent post-submission manipulation.
- Each address can only attest once per scorecard.
- Grace period (minimum 1 day) prevents instant ratification after quorum is reached.

## Gotchas

- `TOTAL_CASHOUT_WEIGHT` is 1e18. Submitted scorecard tier weights must sum to **exactly** this value or `setTierCashOutWeightsTo` reverts. No tolerance.
- Tier IDs in a scorecard must be in **strict ascending order** with no duplicates.
- Max 128 tiers (`uint256[128] _tierCashOutWeights`).
- `DefifaHook` is a **minimal proxy clone** (`Clones.cloneDeterministic`). `initialize` can only be called once.
- All tiers share the same price (`tierPrice` on `DefifaLaunchProjectData`).
- **Delegation only during MINT phase**. Other phases revert with `DefifaHook_DelegateChangesUnavailableInThisPhase`.
- If `totalTierUnits` is 0 for a tier (no delegations), that tier contributes no attestation power.
- **Quorum snapshot**: Quorum is snapshotted at scorecard submission time (`submitScorecardFor`). `stateOf` uses `scorecard.quorumSnapshot` instead of calling `quorum()` live. The `quorum()` function counts tiers with either minted supply (`currentSupplyOfTier > 0`) OR pending reserves (`numberOfPendingReservesFor > 0`). The pending reserves check matters when all paid tokens in a tier were burned during REFUND — `currentSupplyOfTier` drops to 0, but pending reserves remain because they're tracked separately. The reserve beneficiary still has a stake in the tier's outcome, so the tier should count toward quorum.
- `ratifyScorecardFrom` uses **low-level `.call`** to execute the scorecard on the hook (necessary because `setTierCashOutWeightsTo` is `onlyOwner`).
- `fulfillCommitmentsOf` uses `max(amount, 1)` as a reentrancy sentinel. `sendPayoutsOf` is wrapped in try-catch: on failure, resets to sentinel (1) and emits `CommitmentPayoutFailed`.
- `_buildSplits` normalizes split percentages. Rounding remainder absorbed by the protocol fee split (last in array).
- `_totalMintCost` tracks cumulative mint prices (paid + reserved). Incremented on pay/reserve, decremented on cash out. Denominator for fee token distribution.
- Cash outs during COMPLETE revert with `DefifaHook_NothingToClaim` if **both** reclaimed ETH is 0 **and** no fee tokens transferred.
- `minParticipation` is compared against terminal surplus. Value of 0 disables the check.
- `scorecardTimeout` counts seconds from SCORING start. Value of 0 disables. Both enable `triggerNoContestFor` when exceeded.
- `triggerNoContestFor` can only be called once per game and is irreversible.
- Token IDs follow `JB721TiersHookStore` encoding: `tierId * 1_000_000_000 + tokenNumber`.
- Metadata IDs use the **code origin address** (uncloned implementation), not the clone: `JBMetadataResolver.getId("pay", codeOrigin)`.

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
    // reservedRate maps to JB721's `reserveFrequency`: 1 reserved mint per N paid mints.
    // 1001 means "1 reserve per 1001 mints" -- effectively no reserves for normal game sizes.
    reservedRate: 1001,
    reservedTokenBeneficiary: address(0),
    encodedIPFSUri: bytes32(0),
    shouldUseReservedTokenBeneficiaryAsDefault: false
});
tiers[1] = DefifaTierParams({
    name: "Team B",
    reservedRate: 1001, // effectively no reserves (see above)
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
