# defifa-collection-deployer-v6 -- User Journeys

Complete interaction paths for every user role in the Defifa prediction game system. Each journey traces exact function signatures, parameters, and state changes.

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

**Actor:** Game Creator
**Phase:** Any (game is created and starts in COUNTDOWN)

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

**What happens internally:**
1. `DefifaDeployer` validates timing: `mintPeriodDuration > 0`, start >= now + refund + mint.
2. Stores `_opsOf[gameId]` with token, start, durations, safety params.
3. If user splits provided: copies them plus a Defifa fee split, stores via `CONTROLLER.setSplitGroupsOf()`.
4. Creates `JB721TierConfig[]` from `DefifaTierParams[]`. All tiers share `tierPrice`, `initialSupply = 999_999_999`, `category = 0`.
5. Clones `DefifaHook` deterministically: `Clones.cloneDeterministic(HOOK_CODE_ORIGIN, keccak256(abi.encodePacked(msg.sender, nonce)))`.
6. Calls `hook.initialize(...)` with game config, tier names, URI resolver.
7. Launches JB project via `CONTROLLER.launchProjectFor()` with 2-3 rulesets (MINT, optional REFUND, SCORING).
8. Initializes governor: `GOVERNOR.initializeGame(gameId, attestationStartTime, attestationGracePeriod)`.
9. Transfers hook ownership: `hook.transferOwnership(address(GOVERNOR))`.
10. Registers hook in address registry.
11. Emits `LaunchGame(gameId, hook, governor, uriResolver, msg.sender)`.

**Timing rules:**
- If `start == 0`: auto-calculated as `block.timestamp + mintPeriodDuration + refundPeriodDuration`.
- If `start > 0` and `mintPeriodDuration == 0`: mint duration auto-fills to `start - block.timestamp - refundPeriodDuration`.
- MINT ruleset `mustStartAtOrAfter = start - mintPeriodDuration - refundPeriodDuration`.
- REFUND ruleset `mustStartAtOrAfter = start - refundPeriodDuration`.
- SCORING ruleset `mustStartAtOrAfter = start`.

---

## Journey 2: Play a Game (Buy NFTs)

**Actor:** Player
**Phase:** MINT

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

**What happens internally:**
1. `JBMultiTerminal` processes payment, calls `DefifaHook.afterPayRecordedWith()`.
2. Hook verifies: caller is terminal, currency matches `pricingCurrency`.
3. Decodes `(attestationDelegate, tierIdsToMint)` from metadata.
4. If `attestationDelegate == address(0)`: uses `defaultAttestationDelegate` or `context.payer`.
5. Computes attestation units per unique tier via `DefifaHookLib.computeAttestationUnits()`.
6. For each unique tier: delegates attestation if payer has no delegate set, transfers attestation units.
7. Calls `_mintAll()`: records mint in store, increments `_totalMintCost`, mints ERC-721 tokens.
8. Reverts with `DefifaHook_Overspending` if payment exceeds exact tier prices.

**Player receives:**
- NFT token(s) representing their chosen tier(s).
- Attestation delegation set to their chosen delegate (or themselves).
- Attestation units proportional to tier's `votingUnits` (used for scorecard governance).

---

## Journey 3: Refund During MINT Phase

**Actor:** Refunder
**Phase:** MINT

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

**What happens internally:**
1. `beforeCashOutRecordedWith` computes `cashOutCount = cumulativeMintPrice` (full refund during MINT).
2. Terminal computes reclaim amount from the bonding curve with `cashOutTaxRate = 0`.
3. `afterCashOutRecordedWith` burns the NFT(s), decrements `_totalMintCost`.
4. During MINT phase: `tokensRedeemedFrom` is NOT incremented (only during COMPLETE).
5. No fee tokens distributed (game not COMPLETE).
6. ETH returned to beneficiary at exact mint price.

---

## Journey 4: Refund During REFUND Phase

**Actor:** Refunder
**Phase:** REFUND

Identical to Journey 3. The REFUND phase has `pausePay: true` (no new mints) but cash-outs still return full mint price. The `cashOutTaxRate = 0` and the hook returns `cashOutCount = cumulativeMintPrice`.

---

## Journey 5: Submit a Scorecard

**Actor:** Scorer (anyone)
**Phase:** SCORING

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

**What happens internally:**
1. Verifies: game initialized, no ratified scorecard, game in SCORING phase.
2. For each weight > 0: verifies `currentSupplyOfTier(tierId) > 0` (cannot assign weight to unminted tiers).
3. Hashes the scorecard: `keccak256(abi.encode(dataHook, abi.encodeWithSelector(setTierCashOutWeightsTo.selector, tierWeights)))`.
4. Reverts with `DefifaGovernor_DuplicateScorecard` if this exact scorecard was already submitted.
5. Sets `attestationsBegin = max(block.timestamp, attestationStartTime)`.
6. Sets `gracePeriodEnds = attestationsBegin + attestationGracePeriod`.
7. If sender is `defaultAttestationDelegate`: stores as `defaultAttestationDelegateProposalOf`.
8. Emits `ScorecardSubmitted(gameId, scorecardId, tierWeights, isDefault, msg.sender)`.

**Scorecard state:** PENDING (until `attestationsBegin`) or ACTIVE (if attestations start immediately).

---

## Journey 6: Attest to a Scorecard

**Actor:** Attestor (NFT holder or delegate)
**Phase:** SCORING

### Step 1: Get scorecard ID

Either compute it or use the ID from the `ScorecardSubmitted` event:

```solidity
uint256 scorecardId = governor.scorecardIdOf(hookAddress, tierWeights);
```

### Step 2: Attest

```solidity
uint256 weight = governor.attestToScorecardFrom(gameId, scorecardId);
```

**What happens internally:**
1. Verifies: game in SCORING phase, scorecard is ACTIVE or SUCCEEDED.
2. Verifies: `!hasAttested[msg.sender]` for this scorecard. Reverts with `DefifaGovernor_AlreadyAttested` otherwise.
3. Computes attestation weight at `attestationsBegin` timestamp:
   - For each tier: `MAX_ATTESTATION_POWER_TIER * (account's checkpoint units / tier's total checkpoint units)`.
   - Uses `getPastTierAttestationUnitsOf()` (snapshot, not live).
4. Increments `_attestations.count += weight`.
5. Marks `hasAttested[msg.sender] = true`.
6. Emits `ScorecardAttested(gameId, scorecardId, weight, msg.sender)`.

**Attestation power depends on:**
- How many NFTs the attestor (or their delegate) held at `attestationsBegin` timestamp.
- What fraction of each tier's total supply those NFTs represent.
- Each tier caps at `MAX_ATTESTATION_POWER_TIER` (1e9) regardless of how many tokens exist in that tier.

---

## Journey 7: Ratify a Scorecard

**Actor:** Ratifier (anyone)
**Phase:** SCORING (scorecard in SUCCEEDED state)

### Precondition

A scorecard must be in SUCCEEDED state:
- `attestationsBegin <= block.timestamp`
- `gracePeriodEnds <= block.timestamp`
- `attestation count >= quorum`

### Step 1: Ratify

```solidity
uint256 scorecardId = governor.ratifyScorecardFrom(gameId, tierWeights);
```

**What happens internally:**
1. Verifies: no prior ratification (`ratifiedScorecardIdOf[gameId] == 0`).
2. Computes `scorecardId` from `tierWeights`, verifies it matches a SUCCEEDED scorecard.
3. Stores `ratifiedScorecardIdOf[gameId] = scorecardId`.
4. Executes scorecard via low-level call: `dataHook.call(abi.encodeWithSelector(setTierCashOutWeightsTo.selector, tierWeights))`.
   - This calls `DefifaHook.setTierCashOutWeightsTo()` which validates weights sum to `TOTAL_CASHOUT_WEIGHT` and sets `cashOutWeightIsSet = true`.
5. Calls `DefifaDeployer.fulfillCommitmentsOf(gameId)`:
   - Sends fee payouts via `terminal.sendPayoutsOf()` (try-catch: if payout fails, emits `CommitmentPayoutFailed` and sets sentinel).
   - Queues final ruleset with no payout limits.
   - Exceptional failures (e.g., `queueRulesetsOf` failure) propagate and revert ratification.
6. Emits `ScorecardRatified(gameId, scorecardId, msg.sender)`.

**Game state transitions to:** COMPLETE (because `cashOutWeightIsSet == true`).

---

## Journey 8: Cash Out as Winner

**Actor:** Winner
**Phase:** COMPLETE

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

**What happens internally:**
1. `beforeCashOutRecordedWith`: computes `cashOutCount = mulDiv(surplus + amountRedeemed, cumulativeCashOutWeight, TOTAL_CASHOUT_WEIGHT)`.
2. Terminal sends reclaimed ETH to beneficiary.
3. `afterCashOutRecordedWith`: burns NFTs, increments `tokensRedeemedFrom[tierId]`, increments `amountRedeemed`.
4. Distributes fee tokens: `_claimTokensFor(holder, cumulativeMintPrice, _totalMintCost)`.
   - Transfers proportional share of `$DEFIFA` and `$NANA` tokens held by the hook.
5. Decrements `_totalMintCost -= cumulativeMintPrice`.

**Reclaim calculation:**
```
perTokenWeight = tierCashOutWeight[tierId] / totalTokensForCashoutInTier
reclaimAmount = mulDiv(surplus + amountRedeemed, perTokenWeight, TOTAL_CASHOUT_WEIGHT)
```

Where `totalTokensForCashoutInTier = initialSupply - remainingSupply - (burnedTokens - tokensRedeemedFrom[tierId])`.

---

## Journey 9: Cash Out from Losing Tier

**Actor:** Holder of a zero-weight tier
**Phase:** COMPLETE

If a tier received `cashOutWeight = 0` in the ratified scorecard:

```solidity
// cashOutWeightOf(tokenId) returns 0
// beforeCashOutRecordedWith returns cashOutCount = 0
// afterCashOutRecordedWith: reclaimedAmount.value == 0
// _claimTokensFor is called -- if fee tokens exist, they are distributed
// If no fee tokens distributed either → reverts with DefifaHook_NothingToClaim
```

**Result:** Holders of losing tiers can only cash out if fee tokens (`$DEFIFA`/`$NANA`) are available. They receive fee tokens proportional to their mint cost but zero ETH. If no fee tokens exist at all, the cash-out reverts.

---

## Journey 10: No-Contest via Minimum Participation

**Actor:** Any user
**Phase:** SCORING (when balance < minParticipation)

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

**What happens internally:**
1. Verifies `currentGamePhaseOf(gameId) == NO_CONTEST`.
2. Verifies `!noContestTriggeredFor[gameId]`.
3. Sets `noContestTriggeredFor[gameId] = true`.
4. Queues new ruleset: no `fundAccessLimitGroups`, making entire balance = surplus.
5. Emits `QueuedNoContest(gameId, msg.sender)`.

### Step 2: Cash out (full refund)

After triggering, users can cash out at mint price (same as Journey 3/4). The new ruleset has no payout limits, so all balance is surplus and `cashOutTaxRate = 0`.

---

## Journey 11: No-Contest via Scorecard Timeout

**Actor:** Any user
**Phase:** SCORING (when timeout elapsed without ratification)

### Scenario

Game had `scorecardTimeout = 7 days`. Scoring started 8 days ago. No scorecard was ratified.

```solidity
if (_ops.scorecardTimeout > 0 && block.timestamp > _currentRuleset.start + _ops.scorecardTimeout) {
    return DefifaGamePhase.NO_CONTEST;
}
```

### Steps

Same as Journey 10: call `triggerNoContestFor()`, then cash out.

**Important:** If a scorecard is ratified BEFORE the timeout, the game transitions to COMPLETE and the timeout becomes irrelevant. `cashOutWeightIsSet` is checked before the timeout condition in `currentGamePhaseOf()`.

---

## Journey 12: Delegate Attestation Power

**Actor:** Player (NFT holder)
**Phase:** MINT only

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

**Restrictions:**
- Only during MINT phase. Reverts with `DefifaHook_DelegateChangesUnavailableInThisPhase` after MINT.
- Cannot delegate to `address(0)`. Reverts with `DefifaHook_DelegateAddressZero`.
- On NFT transfer after MINT: auto-delegates to recipient if recipient has no delegate (DefifaHook lines 1027-1031).

---

## Journey 13: Mint Reserved Tokens

**Actor:** Anyone
**Phase:** After MINT (reserved minting is paused during MINT via `pauseMintPendingReserves: true`)

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

**What happens internally:**
1. Checks `pauseMintPendingReserves` is false in current ruleset metadata.
2. Gets `reserveBeneficiary` from store for the tier.
3. If beneficiary has no delegate: auto-delegates to `defaultAttestationDelegate` or self.
4. Records mint in store, increments `_totalMintCost += tier.price * count`.
5. Mints ERC-721 tokens to the reserve beneficiary.
6. Transfers attestation units to the beneficiary's delegate.

**Note:** Reserved mints inflate `_totalMintCost` even though no ETH was paid. This dilutes paid minters' share of fee tokens. This is by design (see RISKS.md, RISK-4).

---

## Journey 14: Fulfill Commitments Separately

**Actor:** Anyone
**Phase:** COMPLETE (after scorecard ratification)

If `fulfillCommitmentsOf()` failed during ratification (caught by try-catch), it can be retried:

```solidity
deployer.fulfillCommitmentsOf(gameId);
```

**What happens internally:**
1. If `fulfilledCommitmentsOf[gameId] != 0`: returns immediately (idempotent).
2. Requires `cashOutWeightIsSet == true`.
3. Computes fee from pot: `mulDiv(pot, _commitmentPercentOf[gameId], SPLITS_TOTAL_PERCENT)`.
4. Calls `terminal.sendPayoutsOf()` to distribute fees to splits.
5. Queues final ruleset with no payout limits.

---

## Journey 15: Transfer NFT to Another Player

**Actor:** NFT holder
**Phase:** Any (unless `transfersPausable` is set and transfers are paused)

```solidity
hook.transferFrom(from, to, tokenId);
// or
hook.safeTransferFrom(from, to, tokenId);
```

**What happens internally (DefifaHook._update):**
1. Gets tier info from store.
2. Calls `super._update()` for standard ERC-721 transfer.
3. If `transfersPausable` and transfers paused in current ruleset: reverts.
4. If first transfer of this token: stores `_firstOwnerOf[tokenId] = from`.
5. Records transfer in store: `store.recordTransferForTier(tierId, from, to)`.
6. Skips attestation transfer on mint (handled separately in `_processPayment`).
7. On regular transfer: `_transferTierAttestationUnits(from, to, tierId, tier.votingUnits)`.
   - If recipient has no delegate set: auto-delegates to self.
   - Moves attestation units from sender's delegate to recipient's delegate.

---

## Journey 16: Query Game State

**Actor:** Frontend / anyone

### Check game phase

```solidity
DefifaGamePhase phase = deployer.currentGamePhaseOf(gameId);
```

### Check game pot

```solidity
(uint256 pot, address token, uint256 decimals) = deployer.currentGamePotOf(gameId, false);
// includeCommitments = true adds fulfilled fee amounts back
```

### Check timing

```solidity
(uint48 start, uint24 mintDuration, uint24 refundDuration) = deployer.timesFor(gameId);
```

### Check safety params

```solidity
(uint256 minParticipation, uint32 scorecardTimeout) = deployer.safetyParamsOf(gameId);
```

### Check scorecard state

```solidity
DefifaScorecardState state = governor.stateOf(gameId, scorecardId);
// PENDING → ACTIVE → SUCCEEDED → RATIFIED (or DEFEATED)
```

### Check attestation status

```solidity
uint256 count = governor.attestationCountOf(gameId, scorecardId);
uint256 needed = governor.quorum(gameId);
bool hasAttested = governor.hasAttestedTo(gameId, scorecardId, account);
```

### Check cash-out value

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
| `DefifaDeployer_NothingToFulfill` | Project balance is 0 |

### Game Creation Errors (Journey 1)

| Error | Condition |
|-------|-----------|
| `DefifaDeployer_InvalidGameConfiguration` | Timing constraints violated: `mintPeriodDuration == 0` or `start < block.timestamp + refund + mint` |
| `DefifaDeployer_SplitsDontAddUp` | User splits + protocol fees exceed 100% |
| `DefifaDeployer_InvalidGameConfiguration` | JB project ID mismatch (front-run) |
