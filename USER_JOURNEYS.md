# defifa-collection-deployer-v6 -- User Journeys

Complete interaction paths for every user role in the Defifa prediction game system. Each journey traces exact function signatures, parameters, state changes, events, and edge cases.

---

## Roles

| Role | Description |
|------|-------------|
| **Game Creator** | Calls `DefifaDeployer.launchGameWith()` to deploy a new prediction game |
| **Player** | Pays ETH/tokens to mint NFT tiers during MINT phase |
| **Refunder** | Cashes out NFTs during MINT, REFUND, or NO_CONTEST for full mint price |
| **Scorer** | Submits a scorecard proposing tier cash-out weights |
| **Attestor** | NFT holder who attests (votes) for a submitted scorecard |
| **Ratifier** | Anyone who triggers ratification of a scorecard that reached quorum |
| **Winner** | Cashes out NFTs during COMPLETE phase at scored weights |
| **No-Contest Trigger** | Anyone who triggers the no-contest refund mechanism |
| **Reserve Minter** | Anyone who mints pending reserved tokens for a tier |
| **Fulfiller** | Anyone who calls `fulfillCommitmentsOf()` to distribute fees |

---

## Journey 1: Create a Game

**Entry point:** `DefifaDeployer.launchGameWith(DefifaLaunchProjectData memory launchProjectData) external returns (uint256 gameId)`

**Who can call:** Anyone (no access control).

**Actor:** Game Creator
**Phase:** Any (game is created and starts in COUNTDOWN)

### Parameters

- `launchProjectData.name` -- Game name (e.g. `"Super Bowl LXII"`).
- `launchProjectData.projectUri` -- IPFS URI for project metadata.
- `launchProjectData.contractUri` -- Contract-level metadata URI.
- `launchProjectData.baseUri` -- Base URI for token metadata.
- `launchProjectData.tiers` -- Array of `DefifaTierParams` (name, reservedRate, reservedTokenBeneficiary, encodedIPFSUri, shouldUseReservedTokenBeneficiaryAsDefault).
- `launchProjectData.tierPrice` -- Uniform price per NFT across all tiers.
- `launchProjectData.token` -- `JBAccountingContext` (token address, decimals, currency).
- `launchProjectData.mintPeriodDuration` -- Duration of MINT phase in seconds.
- `launchProjectData.refundPeriodDuration` -- Duration of REFUND phase in seconds (0 = no refund phase).
- `launchProjectData.start` -- Unix timestamp when SCORING begins (0 = auto-calculate).
- `launchProjectData.splits` -- Optional custom splits for fee distribution.
- `launchProjectData.attestationStartTime` -- Timestamp when attestation begins (0 = `block.timestamp` at deploy).
- `launchProjectData.attestationGracePeriod` -- Minimum grace period before ratification (0 = enforced minimum of 1 day).
- `launchProjectData.defaultAttestationDelegate` -- Default attestation delegate (0 = each payer delegates to self).
- `launchProjectData.defaultTokenUriResolver` -- Token URI resolver (0 = use default SVG).
- `launchProjectData.terminal` -- `JBMultiTerminal` instance.
- `launchProjectData.store` -- `JB721TiersHookStore` instance.
- `launchProjectData.minParticipation` -- Minimum treasury balance for game to proceed to SCORING.
- `launchProjectData.scorecardTimeout` -- Max time after SCORING begins for a scorecard to be ratified.

### Step 1: Prepare launch data

Build a `DefifaLaunchProjectData` struct:

```solidity
DefifaLaunchProjectData({
    name: "Super Bowl LXII",
    projectUri: "ipfs://...",
    contractUri: "ipfs://...",
    baseUri: "ipfs://",
    tiers: [
        DefifaTierParams({
            name: "Kansas City Chiefs",
            reservedRate: 0,
            reservedTokenBeneficiary: address(0),
            encodedIPFSUri: bytes32(0),
            shouldUseReservedTokenBeneficiaryAsDefault: false
        }),
        DefifaTierParams({
            name: "Philadelphia Eagles",
            reservedRate: 0,
            reservedTokenBeneficiary: address(0),
            encodedIPFSUri: bytes32(0),
            shouldUseReservedTokenBeneficiaryAsDefault: false
        })
        // ... more tiers
    ],
    tierPrice: 0.01 ether,
    token: JBAccountingContext({
        token: JBConstants.NATIVE_TOKEN,
        decimals: 18,
        currency: JBCurrencyIds.ETH
    }),
    mintPeriodDuration: 7 days,
    refundPeriodDuration: 1 days,
    start: uint48(block.timestamp + 8 days),
    splits: [],                              // Optional custom splits
    attestationStartTime: 0,                 // 0 = block.timestamp at deploy
    attestationGracePeriod: 0,               // 0 = enforced minimum of 1 day
    defaultAttestationDelegate: address(0),  // 0 = each payer delegates to self
    defaultTokenUriResolver: IJB721TokenUriResolver(address(0)),  // use default SVG
    terminal: jbMultiTerminal,
    store: jb721TiersHookStore,
    minParticipation: 1 ether,               // Game needs >= 1 ETH to proceed
    scorecardTimeout: 7 days                 // 7 days to ratify or NO_CONTEST
})
```

### Step 2: Launch

```solidity
uint256 gameId = deployer.launchGameWith(launchProjectData);
```

### State changes

1. `DefifaDeployer._opsOf[gameId]` -- Stores `DefifaOpsData` with token, start, durations, safety params.
2. `DefifaDeployer._commitmentPercentOf[gameId]` -- Stores total absolute split percent for fee distribution.
3. `DefifaDeployer._nonce` -- Incremented for deterministic clone salt.
4. `DefifaHook.store` -- Set to the provided `JB721TiersHookStore`.
5. `DefifaHook.rulesets` -- Set to `CONTROLLER.RULESETS()`.
6. `DefifaHook.pricingCurrency` -- Set to `launchProjectData.token.currency`.
7. `DefifaHook.gamePhaseReporter` -- Set to `DefifaDeployer` (this).
8. `DefifaHook.gamePotReporter` -- Set to `DefifaDeployer` (this).
9. `DefifaHook.defaultAttestationDelegate` -- Set to the provided address.
10. `DefifaHook.baseURI` -- Set if non-empty.
11. `DefifaHook.contractURI` -- Set if non-empty.
12. `DefifaGovernor._packedScorecardInfoOf[gameId]` -- Packed attestation start time + grace period.
13. JB project created via `CONTROLLER.launchProjectFor()` with 2-3 rulesets (MINT, optional REFUND, SCORING).

### Events

- `LaunchGame(uint256 indexed gameId, IDefifaHook indexed hook, IDefifaGovernor indexed governor, IJB721TokenUriResolver tokenUriResolver, address caller)` -- Emitted by `DefifaDeployer` on successful launch.
- `GameInitialized(uint256 indexed gameId, uint256 attestationStartTime, uint256 attestationGracePeriod, address caller)` -- Emitted by `DefifaGovernor` when `initializeGame` is called internally.

### Edge cases

- `DefifaDeployer_InvalidGameConfiguration` -- `mintPeriodDuration == 0` or `start < block.timestamp + refundPeriodDuration + mintPeriodDuration`.
- `DefifaDeployer_InvalidGameConfiguration` -- JB project ID mismatch (front-run by another project creation).
- `DefifaDeployer_SplitsDontAddUp` -- User splits + protocol fees exceed 100%.
- If `start == 0`: auto-calculated as `block.timestamp + mintPeriodDuration + refundPeriodDuration`.
- If `start > 0` and `mintPeriodDuration == 0`: mint duration auto-fills to `start - block.timestamp - refundPeriodDuration`.
- MINT ruleset `mustStartAtOrAfter = start - mintPeriodDuration - refundPeriodDuration`.
- REFUND ruleset `mustStartAtOrAfter = start - refundPeriodDuration`.
- SCORING ruleset `mustStartAtOrAfter = start`.

---

## Journey 2: Play a Game (Buy NFTs)

**Entry point:** `JBMultiTerminal.pay{value: amount}(uint256 projectId, address token, uint256 amount, address beneficiary, uint256 minReturnedTokens, string memo, bytes metadata) external payable returns (uint256)`

**Who can call:** Anyone. The terminal forwards the call to `DefifaHook.afterPayRecordedWith()` which validates the caller is a registered terminal for the project.

**Actor:** Player
**Phase:** MINT

### Parameters

- `projectId` -- The game ID.
- `token` -- Token address (e.g. `JBConstants.NATIVE_TOKEN` for ETH).
- `amount` -- Must equal `tierPrice * numberOfTiersMinted` exactly.
- `beneficiary` -- Address that receives the minted NFTs.
- `minReturnedTokens` -- Minimum tokens to receive (typically 0 for NFT mints).
- `memo` -- Optional memo string.
- `metadata` -- JBMetadataResolver-encoded bytes containing `(address attestationDelegate, uint16[] tierIds)`.

### Step 1: Prepare payment metadata

Encode the tier IDs to mint and optional attestation delegate:

```solidity
// Tier IDs to mint (must be ascending order)
uint16[] memory tierIds = new uint16[](2);
tierIds[0] = 1;  // "Kansas City Chiefs"
tierIds[1] = 1;  // Mint 2 of the same tier

address attestationDelegate = address(0); // 0 = use default or self

bytes memory payMetadata = abi.encode(attestationDelegate, tierIds);
```

Wrap in JBMetadataResolver format:

```solidity
bytes memory metadata = metadataHelper.createMetadata({
    id: JBMetadataResolver.getId("pay", hookCodeOrigin),
    data: payMetadata
});
```

### Step 2: Pay the terminal

```solidity
jbMultiTerminal.pay{value: 0.02 ether}({
    projectId: gameId,
    token: JBConstants.NATIVE_TOKEN,
    amount: 0.02 ether,       // Must equal tierPrice * numberOfTiers minted
    beneficiary: msg.sender,
    minReturnedTokens: 0,
    memo: "Go Chiefs!",
    metadata: metadata
});
```

### State changes

1. `DefifaHook._totalMintCost` -- Incremented by `context.amount.value` (the paid amount).
2. `DefifaHook._tierDelegation[payer][tierId]` -- Set to `attestationDelegate` for each minted tier (if payer had no delegate).
3. `DefifaHook._delegateTierCheckpoints[delegate][tierId]` -- Checkpointed with new attestation units.
4. `DefifaHook._totalTierCheckpoints[tierId]` -- Checkpointed with increased total attestation units.
5. ERC-721 token ownership records updated (one token per tier mint).
6. `JB721TiersHookStore` records the mint (supply, token IDs).

### Events

- `Mint(uint256 indexed tokenId, uint256 indexed tierId, address indexed beneficiary, uint256 totalAmountContributed, address caller)` -- Emitted per token minted by `DefifaHook._mintAll()`.
- `DelegateChanged(address indexed delegator, address indexed fromDelegate, address indexed toDelegate)` -- Emitted when attestation delegation is set for a tier.
- `TierDelegateAttestationsChanged(address indexed delegate, uint256 indexed tierId, uint256 previousBalance, uint256 newBalance, address caller)` -- Emitted when attestation units are transferred.

### Edge cases

- `DefifaHook_WrongCurrency` -- Payment currency does not match `pricingCurrency`.
- `DefifaHook_NothingToMint` -- No tier IDs in metadata, or metadata not found.
- `DefifaHook_Overspending` -- Payment amount exceeds exact cost of tiers minted (leftover != 0).
- `DefifaHook_BadTierOrder` -- Tier IDs in metadata not in ascending order (validated by `DefifaHookLib.computeAttestationUnits`).
- `JB721Hook_InvalidPay` -- Caller not a terminal, or wrong project ID, or ETH sent directly to hook.

---

## Journey 3: Refund During MINT Phase

**Entry point:** `JBMultiTerminal.cashOutTokensOf(address holder, uint256 projectId, uint256 cashOutCount, address tokenToReclaim, uint256 minTokensReclaimed, address payable beneficiary, bytes metadata) external returns (uint256)`

**Who can call:** Anyone can initiate, but the hook validates that `context.holder` owns the tokens being burned.

**Actor:** Refunder
**Phase:** MINT

### Parameters

- `holder` -- Address that holds the NFTs being cashed out.
- `projectId` -- The game ID.
- `cashOutCount` -- Pass `0` for NFT cash-outs.
- `tokenToReclaim` -- Token to receive (e.g. `JBConstants.NATIVE_TOKEN`).
- `minTokensReclaimed` -- Minimum amount to receive (set to expected mint price).
- `beneficiary` -- Address that receives the reclaimed funds.
- `metadata` -- JBMetadataResolver-encoded bytes containing `(uint256[] tokenIds)`.

### Step 1: Prepare cash-out metadata

```solidity
uint256[] memory tokenIds = new uint256[](1);
tokenIds[0] = myTokenId;

bytes memory cashOutMetadata = metadataHelper.createMetadata({
    id: JBMetadataResolver.getId("cashOut", hookCodeOrigin),
    data: abi.encode(tokenIds)
});
```

### Step 2: Cash out

```solidity
jbMultiTerminal.cashOutTokensOf({
    holder: msg.sender,
    projectId: gameId,
    cashOutCount: 0,           // 0 for NFT cash-outs
    tokenToReclaim: JBConstants.NATIVE_TOKEN,
    minTokensReclaimed: 0.01 ether,  // Expect full tier price back
    beneficiary: payable(msg.sender),
    metadata: cashOutMetadata
});
```

### State changes

1. ERC-721 token burned via `DefifaHook._burn(tokenId)`.
2. `DefifaHook._totalMintCost` -- Decremented by `cumulativeMintPrice` of burned tokens.
3. `JB721TiersHookStore` records the burn.
4. During MINT phase: `DefifaHook.tokensRedeemedFrom[tierId]` is NOT incremented (only during COMPLETE).
5. `DefifaHook.amountRedeemed` -- NOT incremented (only during COMPLETE).

### Events

No Defifa-specific events are emitted during MINT/REFUND phase cash-outs. Standard ERC-721 `Transfer(from, address(0), tokenId)` is emitted by the burn.

### Edge cases

- `DefifaHook_Unauthorized(tokenId, owner, caller)` -- Token holder in context does not own the token.
- `DefifaHook_NothingToClaim` -- Reclaimed amount is 0 AND no fee tokens distributed.
- `JB721Hook_InvalidCashOut` -- Caller not a terminal, or wrong project ID.
- During MINT phase: `cashOutTaxRate = 0`, so full mint price is refunded.

---

## Journey 4: Refund During REFUND Phase

**Entry point:** Same as Journey 3: `JBMultiTerminal.cashOutTokensOf(...)`

**Who can call:** Anyone (same restrictions as Journey 3).

**Actor:** Refunder
**Phase:** REFUND

Identical to Journey 3. The REFUND phase has `pausePay: true` (no new mints) but cash-outs still return full mint price. The `cashOutTaxRate = 0` and the hook returns `cashOutCount = cumulativeMintPrice`.

### State changes

Same as Journey 3.

### Events

Same as Journey 3 (no Defifa-specific events; standard ERC-721 burn `Transfer` event).

### Edge cases

Same as Journey 3. Additionally, new payments are blocked (`pausePay: true`).

---

## Journey 5: Submit a Scorecard

**Entry point:** `DefifaGovernor.submitScorecardFor(uint256 gameId, DefifaTierCashOutWeight[] calldata tierWeights) external returns (uint256 scorecardId)`

**Who can call:** Anyone. No access control on submission. However, if `msg.sender == defaultAttestationDelegate`, the scorecard is stored as `defaultAttestationDelegateProposalOf[gameId]`.

**Actor:** Scorer (anyone)
**Phase:** SCORING

### Parameters

- `gameId` -- The ID of the game.
- `tierWeights` -- Array of `DefifaTierCashOutWeight` structs. Each has `id` (tier ID) and `cashOutWeight` (weight). All weights must sum to exactly `TOTAL_CASHOUT_WEIGHT` (1e18). Tier IDs must be in ascending order.

### Step 1: Prepare tier weights

All weights must sum to exactly `TOTAL_CASHOUT_WEIGHT` (1e18). Tier IDs must be in ascending order.

```solidity
DefifaTierCashOutWeight[] memory tierWeights = new DefifaTierCashOutWeight[](3);
tierWeights[0] = DefifaTierCashOutWeight({id: 1, cashOutWeight: 500_000_000_000_000_000}); // 50%
tierWeights[1] = DefifaTierCashOutWeight({id: 2, cashOutWeight: 300_000_000_000_000_000}); // 30%
tierWeights[2] = DefifaTierCashOutWeight({id: 3, cashOutWeight: 200_000_000_000_000_000}); // 20%
// Sum = 1e18
```

### Step 2: Submit

```solidity
uint256 scorecardId = governor.submitScorecardFor(gameId, tierWeights);
```

### State changes

1. `DefifaGovernor._scorecardOf[gameId][scorecardId].attestationsBegin` -- Set to `max(block.timestamp, attestationStartTime)`.
2. `DefifaGovernor._scorecardOf[gameId][scorecardId].gracePeriodEnds` -- Set to `attestationsBegin + attestationGracePeriod`.
3. `DefifaGovernor.defaultAttestationDelegateProposalOf[gameId]` -- Set to `scorecardId` if sender is the default attestation delegate.

### Events

- `ScorecardSubmitted(uint256 indexed gameId, uint256 indexed scorecardId, DefifaTierCashOutWeight[] tierWeights, bool isDefaultAttestationDelegate, address caller)` -- Emitted by `DefifaGovernor`.

### Edge cases

- `DefifaGovernor_AlreadyRatified` -- A scorecard has already been ratified for this game.
- `DefifaGovernor_GameNotFound` -- Game not initialized (`_packedScorecardInfoOf[gameId] == 0`).
- `DefifaGovernor_NotAllowed` -- Game not in SCORING phase.
- `DefifaGovernor_UnownedProposedCashoutValue` -- Weight > 0 assigned to a tier with `currentSupplyOfTier == 0`.
- `DefifaGovernor_DuplicateScorecard` -- Identical scorecard (same hash) already submitted.
- Scorecard state starts as PENDING (until `attestationsBegin`) or ACTIVE (if attestations start immediately).

---

## Journey 6: Attest to a Scorecard

**Entry point:** `DefifaGovernor.attestToScorecardFrom(uint256 gameId, uint256 scorecardId) external returns (uint256 weight)`

**Who can call:** Anyone. However, attestation weight is zero unless the caller (or their delegate) held NFTs at the `attestationsBegin` snapshot timestamp.

**Actor:** Attestor (NFT holder or delegate)
**Phase:** SCORING

### Parameters

- `gameId` -- The ID of the game.
- `scorecardId` -- The scorecard ID to attest to.

### Step 1: Get scorecard ID

Either compute it or use the ID from the `ScorecardSubmitted` event:

```solidity
uint256 scorecardId = governor.scorecardIdOf(hookAddress, tierWeights);
```

### Step 2: Attest

```solidity
uint256 weight = governor.attestToScorecardFrom(gameId, scorecardId);
```

### State changes

1. `DefifaGovernor._scorecardAttestationsOf[gameId][scorecardId].count` -- Incremented by `weight`.
2. `DefifaGovernor._scorecardAttestationsOf[gameId][scorecardId].hasAttested[msg.sender]` -- Set to `true`.

### Events

- `ScorecardAttested(uint256 indexed gameId, uint256 indexed scorecardId, uint256 weight, address caller)` -- Emitted by `DefifaGovernor`.

### Edge cases

- `DefifaGovernor_NotAllowed` -- Game not in SCORING phase, or scorecard not in ACTIVE/SUCCEEDED state.
- `DefifaGovernor_AlreadyAttested` -- Account already attested to this scorecard.
- `DefifaGovernor_UnknownProposal` -- Scorecard ID has no submission record.
- Attestation weight is computed at `attestationsBegin` timestamp using checkpointed values (snapshot, not live).
- Each tier caps at `MAX_ATTESTATION_POWER_TIER` (1e9) regardless of how many tokens exist in that tier.

---

## Journey 7: Ratify a Scorecard

**Entry point:** `DefifaGovernor.ratifyScorecardFrom(uint256 gameId, DefifaTierCashOutWeight[] calldata tierWeights) external returns (uint256 scorecardId)`

**Who can call:** Anyone. No access control -- the function validates that the scorecard is in SUCCEEDED state.

**Actor:** Ratifier (anyone)
**Phase:** SCORING (scorecard in SUCCEEDED state)

### Parameters

- `gameId` -- The ID of the game.
- `tierWeights` -- The tier weights that match the scorecard being ratified (used to recompute the scorecard hash).

### Precondition

A scorecard must be in SUCCEEDED state:
- `attestationsBegin <= block.timestamp`
- `gracePeriodEnds <= block.timestamp`
- `attestation count >= quorum`

### Step 1: Ratify

```solidity
uint256 scorecardId = governor.ratifyScorecardFrom(gameId, tierWeights);
```

### State changes

1. `DefifaGovernor.ratifiedScorecardIdOf[gameId]` -- Set to `scorecardId`.
2. `DefifaHook._tierCashOutWeights` -- Set via `setTierCashOutWeightsTo()` executed as a low-level call.
3. `DefifaHook.cashOutWeightIsSet` -- Set to `true`.
4. `DefifaDeployer.fulfilledCommitmentsOf[gameId]` -- Set to the fee amount (or sentinel value 1 if pot is 0 or payout fails).
5. Final ruleset queued via `CONTROLLER.queueRulesetsOf()` with no payout limits.

### Events

- `TierCashOutWeightsSet(DefifaTierCashOutWeight[] tierWeights, address caller)` -- Emitted by `DefifaHook.setTierCashOutWeightsTo()`.
- `FulfilledCommitments(uint256 indexed gameId, uint256 pot, address caller)` -- Emitted by `DefifaDeployer.fulfillCommitmentsOf()`.
- `CommitmentPayoutFailed(uint256 indexed gameId, uint256 amount, bytes reason)` -- Emitted if `sendPayoutsOf` fails (try-catch).
- `ScorecardRatified(uint256 indexed gameId, uint256 indexed scorecardId, address caller)` -- Emitted by `DefifaGovernor`.

### Edge cases

- `DefifaGovernor_AlreadyRatified` -- Game already has a ratified scorecard.
- `DefifaGovernor_NotAllowed` -- Scorecard not in SUCCEEDED state.
- `DefifaGovernor_UnknownProposal` -- Scorecard ID has no submission record.
- If `sendPayoutsOf` fails: try-catch emits `CommitmentPayoutFailed`, fee stays in pot, but final ruleset is still queued.
- If `queueRulesetsOf` fails: the entire ratification reverts (no try-catch on that call).
- Game state transitions to COMPLETE because `cashOutWeightIsSet == true`.

---

## Journey 8: Cash Out as Winner

**Entry point:** `JBMultiTerminal.cashOutTokensOf(address holder, uint256 projectId, uint256 cashOutCount, address tokenToReclaim, uint256 minTokensReclaimed, address payable beneficiary, bytes metadata) external returns (uint256)`

**Who can call:** Anyone can initiate, but the hook validates that `context.holder` owns the tokens being burned.

**Actor:** Winner
**Phase:** COMPLETE

### Parameters

Same as Journey 3 (Refund).

### Step 1: Check claimable amounts

```solidity
// Check cash-out value
uint256 weight = hook.cashOutWeightOf(myTokenId);
// weight > 0 means this tier won something

// Check fee token claims
(uint256 defifaTokens, uint256 nanaTokens) = hook.tokensClaimableFor(tokenIds);
```

### Step 2: Cash out

```solidity
uint256[] memory tokenIds = new uint256[](1);
tokenIds[0] = myTokenId;

bytes memory cashOutMetadata = metadataHelper.createMetadata({
    id: JBMetadataResolver.getId("cashOut", hookCodeOrigin),
    data: abi.encode(tokenIds)
});

jbMultiTerminal.cashOutTokensOf({
    holder: msg.sender,
    projectId: gameId,
    cashOutCount: 0,
    tokenToReclaim: JBConstants.NATIVE_TOKEN,
    minTokensReclaimed: expectedAmount,
    beneficiary: payable(msg.sender),
    metadata: cashOutMetadata
});
```

### State changes

1. ERC-721 tokens burned via `DefifaHook._burn(tokenId)`.
2. `DefifaHook.tokensRedeemedFrom[tierId]` -- Incremented for each burned token (only during COMPLETE).
3. `DefifaHook.amountRedeemed` -- Incremented by `context.reclaimedAmount.value`.
4. `DefifaHook._totalMintCost` -- Decremented by `cumulativeMintPrice` of burned tokens.
5. Fee tokens ($DEFIFA and $NANA) transferred to holder proportional to their mint cost share.
6. `JB721TiersHookStore` records the burn.

### Events

- `ClaimedTokens(address indexed beneficiary, uint256 defifaTokenAmount, uint256 baseProtocolTokenAmount, address caller)` -- Emitted by `DefifaHookLib.claimTokensFor()` when fee tokens are distributed.

Standard ERC-721 `Transfer(from, address(0), tokenId)` emitted by the burn. Standard ERC-20 `Transfer` events emitted by the token transfers.

### Edge cases

- `DefifaHook_Unauthorized(tokenId, owner, caller)` -- Token holder in context does not own the token.
- `DefifaHook_NothingToClaim` -- Reclaimed amount is 0 AND no fee tokens distributed.
- `JB721Hook_InvalidCashOut` -- Caller not a terminal, or wrong project ID.
- Reclaim calculation: `perTokenWeight = tierCashOutWeight[tierId] / totalTokensForCashoutInTier`, then `reclaimAmount = mulDiv(surplus + amountRedeemed, perTokenWeight, TOTAL_CASHOUT_WEIGHT)`.
- `totalTokensForCashoutInTier = initialSupply - remainingSupply - (burnedTokens - tokensRedeemedFrom[tierId])`.

---

## Journey 9: Cash Out from Losing Tier

**Entry point:** Same as Journey 8: `JBMultiTerminal.cashOutTokensOf(...)`

**Who can call:** Anyone (same restrictions as Journey 8).

**Actor:** Holder of a zero-weight tier
**Phase:** COMPLETE

If a tier received `cashOutWeight = 0` in the ratified scorecard:

```solidity
// cashOutWeightOf(tokenId) returns 0
// beforeCashOutRecordedWith returns cashOutCount = 0
// afterCashOutRecordedWith: reclaimedAmount.value == 0
// _claimTokensFor is called -- if fee tokens exist, they are distributed
// If no fee tokens distributed either -> reverts with DefifaHook_NothingToClaim
```

### State changes

Same as Journey 8, but `context.reclaimedAmount.value == 0`.

### Events

- `ClaimedTokens(address indexed beneficiary, uint256 defifaTokenAmount, uint256 baseProtocolTokenAmount, address caller)` -- Emitted only if fee tokens are available to distribute.

### Edge cases

- `DefifaHook_NothingToClaim` -- Reverts if both reclaimed ETH is 0 AND no fee tokens are distributed.
- Holders of losing tiers receive fee tokens proportional to their mint cost but zero ETH. If no fee tokens exist at all, the cash-out reverts.

---

## Journey 10: No-Contest via Minimum Participation

**Entry point:** `DefifaDeployer.triggerNoContestFor(uint256 gameId) external`

**Who can call:** Anyone. No access control -- the function validates that the game is in NO_CONTEST phase.

**Actor:** Any user
**Phase:** SCORING (when balance < minParticipation)

### Parameters

- `gameId` -- The ID of the game to trigger no-contest for.

### Scenario

Game had `minParticipation = 10 ether`. During MINT, 5 ETH was deposited but then refunded down to 3 ETH. When SCORING begins, `currentGamePhaseOf()` checks:

```solidity
if (_ops.minParticipation > 0) {
    uint256 _balance = terminal.STORE().balanceOf(terminal, gameId, token);
    if (_balance < _ops.minParticipation) return DefifaGamePhase.NO_CONTEST;
}
```

Since 3 ETH < 10 ETH, the game is NO_CONTEST.

### Step 1: Trigger no-contest

```solidity
deployer.triggerNoContestFor(gameId);
```

### State changes

1. `DefifaDeployer.noContestTriggeredFor[gameId]` -- Set to `true`.
2. New ruleset queued via `CONTROLLER.queueRulesetsOf()` with no `fundAccessLimitGroups`, making entire balance = surplus. Has `pausePay: true` and `cashOutTaxRate: 0`.

### Events

- `QueuedNoContest(uint256 indexed gameId, address caller)` -- Emitted by `DefifaDeployer`.

### Edge cases

- `DefifaDeployer_NotNoContest` -- Game not in NO_CONTEST phase.
- `DefifaDeployer_NoContestAlreadyTriggered` -- Already triggered for this game.
- The queued ruleset does not take effect until the current ruleset's cycle ends. During this gap, the game reports NO_CONTEST but the on-chain ruleset still has payout limits. Callers should verify the active ruleset before cashing out.

### Step 2: Cash out (full refund)

After triggering, users can cash out at mint price (same as Journey 3/4). The new ruleset has no payout limits, so all balance is surplus and `cashOutTaxRate = 0`.

---

## Journey 11: No-Contest via Scorecard Timeout

**Entry point:** Same as Journey 10: `DefifaDeployer.triggerNoContestFor(uint256 gameId) external`

**Who can call:** Anyone. Same restrictions as Journey 10.

**Actor:** Any user
**Phase:** SCORING (when timeout elapsed without ratification)

### Parameters

- `gameId` -- The ID of the game.

### Scenario

Game had `scorecardTimeout = 7 days`. Scoring started 8 days ago. No scorecard was ratified.

```solidity
if (_ops.scorecardTimeout > 0 && block.timestamp > _currentRuleset.start + _ops.scorecardTimeout) {
    return DefifaGamePhase.NO_CONTEST;
}
```

### State changes

Same as Journey 10.

### Events

Same as Journey 10: `QueuedNoContest(uint256 indexed gameId, address caller)`.

### Edge cases

Same as Journey 10. Additionally: if a scorecard is ratified BEFORE the timeout, the game transitions to COMPLETE and the timeout becomes irrelevant. `cashOutWeightIsSet` is checked before the timeout condition in `currentGamePhaseOf()`.

---

## Journey 12: Delegate Attestation Power

**Entry point (single tier):** `DefifaHook.setTierDelegateTo(address delegatee, uint256 tierId) public`

**Entry point (multiple tiers):** `DefifaHook.setTierDelegatesTo(DefifaDelegation[] memory delegations) external`

**Who can call:** Any NFT holder (`msg.sender` is the delegator). Only callable during MINT phase.

**Actor:** Player (NFT holder)
**Phase:** MINT only

### Parameters (single)

- `delegatee` -- Address to delegate attestation power to. Cannot be `address(0)`.
- `tierId` -- The tier ID to delegate attestation units for.

### Parameters (multiple)

- `delegations` -- Array of `DefifaDelegation` structs, each containing `delegatee` and `tierId`.

### Single tier delegation

```solidity
hook.setTierDelegateTo(trustedDelegate, tierId);
```

### Multiple tier delegations

```solidity
DefifaDelegation[] memory delegations = new DefifaDelegation[](2);
delegations[0] = DefifaDelegation({delegatee: trustedDelegate, tierId: 1});
delegations[1] = DefifaDelegation({delegatee: anotherDelegate, tierId: 2});

hook.setTierDelegatesTo(delegations);
```

### State changes

1. `DefifaHook._tierDelegation[msg.sender][tierId]` -- Set to the new `delegatee`.
2. `DefifaHook._delegateTierCheckpoints[oldDelegate][tierId]` -- Checkpointed with decreased attestation units.
3. `DefifaHook._delegateTierCheckpoints[newDelegate][tierId]` -- Checkpointed with increased attestation units.

### Events

- `DelegateChanged(address indexed delegator, address indexed fromDelegate, address indexed toDelegate)` -- Emitted per tier delegation change.
- `TierDelegateAttestationsChanged(address indexed delegate, uint256 indexed tierId, uint256 previousBalance, uint256 newBalance, address caller)` -- Emitted for both the old delegate (units removed) and the new delegate (units added).

### Edge cases

- `DefifaHook_DelegateAddressZero` -- Delegatee is `address(0)`.
- `DefifaHook_DelegateChangesUnavailableInThisPhase` -- Not in MINT phase.
- On NFT transfer after MINT: auto-delegates to recipient if recipient has no delegate (DefifaHook lines 1036-1047).

---

## Journey 13: Mint Reserved Tokens

**Entry point (single tier):** `DefifaHook.mintReservesFor(uint256 tierId, uint256 count) public`

**Entry point (multiple tiers):** `DefifaHook.mintReservesFor(JB721TiersMintReservesConfig[] calldata mintReservesForTiersData) external`

**Who can call:** Anyone. No access control. Must not be paused (`pauseMintPendingReserves` must be false).

**Actor:** Anyone
**Phase:** After MINT (reserved minting is paused during MINT via `pauseMintPendingReserves: true`)

### Parameters (single)

- `tierId` -- The tier ID to mint reserved tokens for.
- `count` -- Number of reserved tokens to mint.

### Parameters (multiple)

- `mintReservesForTiersData` -- Array of `JB721TiersMintReservesConfig` structs, each containing `tierId` and `count`.

### Single tier

```solidity
hook.mintReservesFor(tierId, count);
```

### Multiple tiers

```solidity
JB721TiersMintReservesConfig[] memory configs = new JB721TiersMintReservesConfig[](1);
configs[0] = JB721TiersMintReservesConfig({tierId: 1, count: 5});

hook.mintReservesFor(configs);
```

### State changes

1. `DefifaHook._totalMintCost` -- Incremented by `tier.price * count`.
2. `DefifaHook._tierDelegation[beneficiary][tierId]` -- Set to `defaultAttestationDelegate` or self (if no delegate exists).
3. `DefifaHook._delegateTierCheckpoints[delegate][tierId]` -- Checkpointed with new attestation units.
4. `DefifaHook._totalTierCheckpoints[tierId]` -- Checkpointed with increased total attestation units.
5. ERC-721 tokens minted to `reserveBeneficiary`.
6. `JB721TiersHookStore` records the reserve mint.

### Events

- `MintReservedToken(uint256 indexed tokenId, uint256 indexed tierId, address indexed beneficiary, address caller)` -- Emitted per reserved token minted.
- `DelegateChanged(address indexed delegator, address indexed fromDelegate, address indexed toDelegate)` -- Emitted if delegation is set for the reserve beneficiary.
- `TierDelegateAttestationsChanged(address indexed delegate, uint256 indexed tierId, uint256 previousBalance, uint256 newBalance, address caller)` -- Emitted when attestation units are transferred to the delegate.

### Edge cases

- `DefifaHook_ReservedTokenMintingPaused` -- `pauseMintPendingReserves` is true in current ruleset metadata.
- Reserved mints inflate `_totalMintCost` even though no ETH was paid. This dilutes paid minters' share of fee tokens. This is by design (see RISKS.md, RISK-4).

---

## Journey 14: Fulfill Commitments Separately

**Entry point:** `DefifaDeployer.fulfillCommitmentsOf(uint256 gameId) external`

**Who can call:** Anyone. No access control. Requires `cashOutWeightIsSet == true`.

**Actor:** Anyone
**Phase:** COMPLETE (after scorecard ratification)

### Parameters

- `gameId` -- The ID of the game to fulfill commitments for.

`fulfillCommitmentsOf()` is called automatically during ratification. If `sendPayoutsOf` fails internally, the try-catch in `fulfillCommitmentsOf` emits `CommitmentPayoutFailed`, sets the sentinel value, and still queues the final ruleset. The fee amount stays in the pot.

If needed, `fulfillCommitmentsOf` can be called again manually -- but since the sentinel is already set and the final ruleset already queued, it returns immediately (idempotent):

```solidity
deployer.fulfillCommitmentsOf(gameId);
```

### State changes

1. `DefifaDeployer.fulfilledCommitmentsOf[gameId]` -- Set to fee amount (or sentinel value 1 if pot is 0 or payout fails).
2. Fee payouts sent via `terminal.sendPayoutsOf()` (distributes to splits).
3. Final ruleset queued via `CONTROLLER.queueRulesetsOf()` with no payout limits.

### Events

- `FulfilledCommitments(uint256 indexed gameId, uint256 pot, address caller)` -- Emitted by `DefifaDeployer` on success.
- `CommitmentPayoutFailed(uint256 indexed gameId, uint256 amount, bytes reason)` -- Emitted if `sendPayoutsOf` fails (try-catch).

### Edge cases

- `DefifaDeployer_CantFulfillYet` -- `cashOutWeightIsSet == false`.
- Idempotent: If `fulfilledCommitmentsOf[gameId] != 0`, returns immediately without reverting.
- Fee computation: `mulDiv(pot, _commitmentPercentOf[gameId], SPLITS_TOTAL_PERCENT)`.

---

## Journey 15: Transfer NFT to Another Player

**Entry point:** `DefifaHook.transferFrom(address from, address to, uint256 tokenId) external` or `DefifaHook.safeTransferFrom(address from, address to, uint256 tokenId) external`

**Who can call:** Token owner or approved operator (standard ERC-721 access control). Transfers may be paused if `transfersPausable` is set and paused in the current ruleset.

**Actor:** NFT holder
**Phase:** Any (unless `transfersPausable` is set and transfers are paused)

### Parameters

- `from` -- Current token owner.
- `to` -- Recipient address.
- `tokenId` -- The token to transfer.

```solidity
hook.transferFrom(from, to, tokenId);
// or
hook.safeTransferFrom(from, to, tokenId);
```

### State changes

1. ERC-721 ownership updated from `from` to `to`.
2. `DefifaHook._firstOwnerOf[tokenId]` -- Stored as `from` on first transfer of this token.
3. `JB721TiersHookStore` records the transfer via `recordTransferForTier(tierId, from, to)`.
4. `DefifaHook._tierDelegation[to][tierId]` -- Auto-set to `to` if recipient has no delegate.
5. `DefifaHook._delegateTierCheckpoints[fromDelegate][tierId]` -- Checkpointed with decreased attestation units.
6. `DefifaHook._delegateTierCheckpoints[toDelegate][tierId]` -- Checkpointed with increased attestation units.

### Events

- `DelegateChanged(address indexed delegator, address indexed fromDelegate, address indexed toDelegate)` -- Emitted if recipient has no delegate and auto-delegates to self.
- `TierDelegateAttestationsChanged(address indexed delegate, uint256 indexed tierId, uint256 previousBalance, uint256 newBalance, address caller)` -- Emitted for both sender's delegate (units removed) and recipient's delegate (units added).

Standard ERC-721 `Transfer(from, to, tokenId)` is also emitted.

### Edge cases

- `DefifaHook_TransfersPaused` -- `transfersPausable` is set and transfers paused in current ruleset.
- On transfer after MINT phase: attestation units are transferred but delegation cannot be changed by the sender.
- Auto-delegation: if recipient has no delegate, they auto-delegate to themselves.

---

## Journey 16: Query Game State

**Actor:** Frontend / anyone

### Check game phase

**Entry point:** `DefifaDeployer.currentGamePhaseOf(uint256 gameId) public view returns (DefifaGamePhase)`

**Who can call:** Anyone (view function).

```solidity
DefifaGamePhase phase = deployer.currentGamePhaseOf(gameId);
```

### Check game pot

**Entry point:** `DefifaDeployer.currentGamePotOf(uint256 gameId, bool includeCommitments) external view returns (uint256, address, uint256)`

**Who can call:** Anyone (view function).

```solidity
(uint256 pot, address token, uint256 decimals) = deployer.currentGamePotOf(gameId, false);
// includeCommitments = true adds fulfilled fee amounts back
```

### Check timing

**Entry point:** `DefifaDeployer.timesFor(uint256 gameId) external view returns (uint48, uint24, uint24)`

**Who can call:** Anyone (view function).

```solidity
(uint48 start, uint24 mintDuration, uint24 refundDuration) = deployer.timesFor(gameId);
```

### Check safety params

**Entry point:** `DefifaDeployer.safetyParamsOf(uint256 gameId) external view returns (uint256 minParticipation, uint32 scorecardTimeout)`

**Who can call:** Anyone (view function).

```solidity
(uint256 minParticipation, uint32 scorecardTimeout) = deployer.safetyParamsOf(gameId);
```

### Check scorecard state

**Entry point:** `DefifaGovernor.stateOf(uint256 gameId, uint256 scorecardId) public view returns (DefifaScorecardState)`

**Who can call:** Anyone (view function).

```solidity
DefifaScorecardState state = governor.stateOf(gameId, scorecardId);
// PENDING -> ACTIVE -> SUCCEEDED -> RATIFIED (or DEFEATED)
```

### Check attestation status

**Entry points:**
- `DefifaGovernor.attestationCountOf(uint256 gameId, uint256 scorecardId) external view returns (uint256)`
- `DefifaGovernor.quorum(uint256 gameId) public view returns (uint256)`
- `DefifaGovernor.hasAttestedTo(uint256 gameId, uint256 scorecardId, address account) external view returns (bool)`

**Who can call:** Anyone (view functions).

```solidity
uint256 count = governor.attestationCountOf(gameId, scorecardId);
uint256 needed = governor.quorum(gameId);
bool hasAttested = governor.hasAttestedTo(gameId, scorecardId, account);
```

### Check cash-out value

**Entry points:**
- `DefifaHook.cashOutWeightOf(uint256 tokenId) external view returns (uint256)`
- `DefifaHook.cashOutWeightOf(uint256[] tokenIds) external view returns (uint256)` (aggregate)

**Who can call:** Anyone (view functions).

```solidity
// Single token
uint256 weight = hook.cashOutWeightOf(tokenId);

// Multiple tokens
uint256[] memory ids = new uint256[](2);
ids[0] = tokenId1;
ids[1] = tokenId2;
uint256 totalWeight = hook.cashOutWeightOf(ids);
```

### Check fee token claims

**Entry points:**
- `DefifaHook.tokensClaimableFor(uint256[] memory tokenIds) external view returns (uint256, uint256)`
- `DefifaHook.tokenAllocations() external view returns (uint256, uint256)`

**Who can call:** Anyone (view functions).

```solidity
(uint256 defifaTokens, uint256 nanaTokens) = hook.tokensClaimableFor(tokenIds);
(uint256 defifaBalance, uint256 nanaBalance) = hook.tokenAllocations();
```

---

## Error Conditions by Journey

### Payment Errors (Journey 2)

| Error | Condition |
|-------|-----------|
| `DefifaHook_WrongCurrency` | Payment currency does not match `pricingCurrency` |
| `DefifaHook_NothingToMint` | No tier IDs in metadata, or metadata not found |
| `DefifaHook_Overspending` | Payment amount exceeds exact cost of tiers minted |
| `DefifaHook_BadTierOrder` | Tier IDs in metadata not in ascending order |
| `JB721Hook_InvalidPay` | Caller not a terminal, or wrong project ID, or ETH sent to hook |

### Cash-Out Errors (Journeys 3, 4, 8, 9)

| Error | Condition |
|-------|-----------|
| `DefifaHook_Unauthorized(tokenId, owner, caller)` | Token holder in context does not own the token |
| `DefifaHook_NothingToClaim` | Reclaimed amount is 0 AND no fee tokens distributed |
| `JB721Hook_InvalidCashOut` | Caller not a terminal, or wrong project ID |

### Scorecard Errors (Journeys 5, 6, 7)

| Error | Condition |
|-------|-----------|
| `DefifaGovernor_NotAllowed` | Game not in SCORING, or scorecard not in correct state |
| `DefifaGovernor_UnownedProposedCashoutValue` | Weight > 0 assigned to tier with 0 supply |
| `DefifaGovernor_DuplicateScorecard` | Identical scorecard already submitted |
| `DefifaGovernor_AlreadyAttested` | Account already attested to this scorecard |
| `DefifaGovernor_AlreadyRatified` | Game already has a ratified scorecard |
| `DefifaGovernor_UnknownProposal` | Scorecard ID has no submission record |
| `DefifaHook_InvalidCashoutWeights` | Weights do not sum to TOTAL_CASHOUT_WEIGHT |
| `DefifaHook_BadTierOrder` | Tier IDs not in ascending order |
| `DefifaHook_InvalidTierId` | Tier not in category 0, or tier ID > maxTierId |
| `DefifaHook_GameIsntScoringYet` | Game not in SCORING phase when setting weights |
| `DefifaHook_CashoutWeightsAlreadySet` | Weights already set (double-set attempt) |

### No-Contest Errors (Journeys 10, 11)

| Error | Condition |
|-------|-----------|
| `DefifaDeployer_NotNoContest` | Game not in NO_CONTEST when triggering |
| `DefifaDeployer_NoContestAlreadyTriggered` | Already triggered for this game |

### Delegation Errors (Journey 12)

| Error | Condition |
|-------|-----------|
| `DefifaHook_DelegateAddressZero` | Delegatee is address(0) |
| `DefifaHook_DelegateChangesUnavailableInThisPhase` | Not in MINT phase |

### Fulfillment Errors (Journey 14)

| Error | Condition |
|-------|-----------|
| `DefifaDeployer_CantFulfillYet` | `cashOutWeightIsSet == false` |

### Game Creation Errors (Journey 1)

| Error | Condition |
|-------|-----------|
| `DefifaDeployer_InvalidGameConfiguration` | Timing constraints violated: `mintPeriodDuration == 0` or `start < block.timestamp + refund + mint` |
| `DefifaDeployer_SplitsDontAddUp` | User splits + protocol fees exceed 100% |
| `DefifaDeployer_InvalidGameConfiguration` | JB project ID mismatch (front-run) |

### Transfer Errors (Journey 15)

| Error | Condition |
|-------|-----------|
| `DefifaHook_TransfersPaused` | `transfersPausable` is set and transfers paused in current ruleset |
