# defifa-collection-deployer-v6 -- Audit Instructions

Prediction game platform built on Juicebox V6. Players buy NFT tiers representing outcomes, a governance process scores the outcomes, and winners claim treasury funds proportional to their tier's score.

---

## Architecture

Five contracts, one library. Total ~2,800 lines of production Solidity.

```
DefifaDeployer.sol       (906 lines)  -- Game factory. Owns all game JB projects. Manages lifecycle rulesets, fee splits, fulfillment, no-contest.
DefifaHook.sol           (1082 lines) -- Pay/cashout hook. NFT minting, burning, attestation delegation, fee token distribution, cash-out weight logic.
DefifaGovernor.sol       (514 lines)  -- Scorecard governance. Submit, attest, ratify scorecards. Singleton across all games.
DefifaHookLib.sol        (368 lines)  -- Pure/view helpers. Weight validation, cash-out math, attestation computation, token claiming.
DefifaProjectOwner.sol   (67 lines)   -- Permanent holder of the Defifa project NFT. Grants SET_SPLIT_GROUPS permission.
DefifaTokenUriResolver.sol (313 lines) -- On-chain SVG metadata for game NFTs.
```

### Contract Relationships

```
DefifaDeployer
  ├── creates JB projects via CONTROLLER.launchProjectFor()
  ├── clones DefifaHook via Clones.cloneDeterministic()
  ├── initializes DefifaGovernor.initializeGame() for each game
  ├── implements IDefifaGamePhaseReporter (phase state machine)
  ├── implements IDefifaGamePotReporter (treasury balance queries)
  ├── fulfillCommitmentsOf() -- sends fee payouts, queues final ruleset
  └── triggerNoContestFor() -- queues refund ruleset for NO_CONTEST games

DefifaHook (clone, one per game)
  ├── extends JB721Hook (ERC-721 with Juicebox terminal integration)
  ├── extends Ownable (owner = DefifaGovernor)
  ├── afterPayRecordedWith() -- mints NFTs on payment
  ├── beforeCashOutRecordedWith() -- calculates reclaim amounts
  ├── afterCashOutRecordedWith() -- burns NFTs, distributes fee tokens
  ├── setTierCashOutWeightsTo() -- onlyOwner, called by governor
  ├── attestation delegation system (checkpoints, per-tier, per-account)
  └── delegates to DefifaHookLib for computation

DefifaGovernor (singleton, shared across all games)
  ├── extends Ownable (owner = DefifaDeployer)
  ├── submitScorecardFor() -- anyone during SCORING
  ├── attestToScorecardFrom() -- NFT holders during SCORING
  ├── ratifyScorecardFrom() -- anyone when SUCCEEDED
  │   ├── calls DefifaHook.setTierCashOutWeightsTo() via low-level call
  │   └── try-catch calls DefifaDeployer.fulfillCommitmentsOf()
  └── quorum() -- 50% of minted tiers' max attestation power
```

### Dependencies

| Dependency | Used For |
|-----------|---------|
| `@bananapus/core-v6` | JBController, JBMultiTerminal, JBTerminalStore, JBRulesets, JBDirectory, JBPrices |
| `@bananapus/721-hook-v6` | JB721Hook, JB721TiersHookStore, tier management, NFT minting/burning |
| `@bananapus/address-registry-v6` | Deterministic hook deployment tracking |
| `@bananapus/permission-ids-v6` | SET_SPLIT_GROUPS permission constant |
| `@openzeppelin/contracts` | Ownable, Clones, Checkpoints.Trace208, SafeERC20, IERC721Receiver |
| `@prb/math` | mulDiv for precise fee and weight calculations |
| `scripty.sol` / `typeface` | On-chain SVG font rendering |

---

## Game Lifecycle

### Phase State Machine

Phases are determined by Juicebox ruleset cycle numbers, safety mechanism checks, and scorecard ratification status. The state machine is in `DefifaDeployer.currentGamePhaseOf()` (line 221-257).

```
COUNTDOWN (cycleNumber == 0)
    │
    ▼
MINT (cycleNumber == 1)
    │  Players buy NFTs. Delegation available. Refunds allowed at mint price.
    │  Reserved minting paused (pauseMintPendingReserves: true).
    ▼
REFUND (cycleNumber == 2, if refundPeriodDuration != 0)
    │  No new payments (pausePay: true). Refunds at mint price.
    │  Reserved minting paused.
    ▼
SCORING (cycleNumber >= 2/3, duration == 0)
    │  Checks applied IN THIS ORDER:
    │  1. cashOutWeightIsSet? → COMPLETE (ratified scorecard is final)
    │  2. noContestTriggeredFor? → NO_CONTEST
    │  3. minParticipation check: balance < threshold? → NO_CONTEST
    │  4. scorecardTimeout check: block.timestamp > start + timeout? → NO_CONTEST
    │  5. Otherwise → SCORING
    ▼
COMPLETE (cashOutWeightIsSet == true)
    │  Winners cash out at scored weights. Fee tokens distributed.
    │
NO_CONTEST (safety mechanism triggered)
    │  Requires triggerNoContestFor() before cash-outs work.
    │  Full refund at mint price.
```

### Ruleset Configuration per Phase

| Phase | pausePay | cashOutTaxRate | ownerMustSendPayouts | payoutLimits | fundAccessLimitGroups |
|-------|----------|---------------|---------------------|-------------|----------------------|
| MINT | false | 0 | false | none | none |
| REFUND | true | 0 | false | none | none |
| SCORING | true | 0 | true | uint224.max | yes (fee splits) |
| COMPLETE (post-fulfill) | true | 0 | true | none | none |
| NO_CONTEST (post-trigger) | true | 0 | true | none | none |

---

## Key Flows

### Payment and Minting (DefifaHook.afterPayRecordedWith → _processPayment)

1. Verify caller is a project terminal, currency matches `pricingCurrency`.
2. Decode metadata: `(address _attestationDelegate, uint16[] _tierIdsToMint)`.
3. Compute attestation units per unique tier via `DefifaHookLib.computeAttestationUnits()`.
4. For each unique tier: set delegation if needed, transfer attestation units from address(0) to payer.
5. Call `_mintAll()`: `store.recordMint()`, increment `_totalMintCost += amount`, mint ERC-721s.
6. Revert if `leftoverAmount != 0` (exact pricing enforced, `DefifaHook_Overspending`).

### Cash-Out (DefifaHook.beforeCashOutRecordedWith + afterCashOutRecordedWith)

**Before (view, returns reclaim params):**
1. Decode token IDs from metadata.
2. Compute cumulative mint price via `DefifaHookLib.computeCumulativeMintPrice()`.
3. Compute `cashOutCount` based on game phase:
   - MINT/REFUND/NO_CONTEST: `cashOutCount = cumulativeMintPrice` (full refund).
   - SCORING/COMPLETE: `cashOutCount = mulDiv(surplus + amountRedeemed, cumulativeCashOutWeight, TOTAL_CASHOUT_WEIGHT)`.
4. Return `totalSupply = surplus.value` (the surplus IS the total supply for Juicebox's bonding curve).

**After (state-changing, burns tokens):**
1. Verify caller is a project terminal.
2. For each token: verify ownership, burn it, increment `tokensRedeemedFrom[tierId]` if COMPLETE.
3. Call `store.recordBurn()`.
4. If COMPLETE: increment `amountRedeemed`, call `_claimTokensFor()` to distribute fee tokens.
5. Revert with `DefifaHook_NothingToClaim` if reclaimed amount is 0 AND no fee tokens were distributed.
6. Decrement `_totalMintCost -= cumulativeMintPrice`.

### Scorecard Governance

**Submit (DefifaGovernor.submitScorecardFor):**
1. Require SCORING phase, game initialized, no ratified scorecard.
2. Validate: no weight on tiers with zero supply.
3. Hash scorecard: `keccak256(abi.encode(dataHook, abi.encodeWithSelector(setTierCashOutWeightsTo.selector, tierWeights)))`.
4. Store `attestationsBegin = max(block.timestamp, attestationStartTime)`.
5. Store `gracePeriodEnds = attestationsBegin + attestationGracePeriod`.

**Attest (DefifaGovernor.attestToScorecardFrom):**
1. Require SCORING phase, scorecard ACTIVE or SUCCEEDED.
2. Prevent double attestation per account per scorecard.
3. Compute weight via `getAttestationWeight()` at `attestationsBegin` timestamp.
4. Increment `_scorecardAttestationsOf[gameId][scorecardId].count += weight`.

**Ratify (DefifaGovernor.ratifyScorecardFrom):**
1. Require no prior ratification, scorecard in SUCCEEDED state.
2. Store `ratifiedScorecardIdOf[gameId] = scorecardId`.
3. Execute scorecard via low-level call: `dataHook.call(abi.encodeWithSelector(setTierCashOutWeightsTo.selector, tierWeights))`.
4. Try-catch: `IDefifaDeployer(owner).fulfillCommitmentsOf(gameId)`.

### Commitment Fulfillment (DefifaDeployer.fulfillCommitmentsOf)

1. Guard: `fulfilledCommitmentsOf[gameId] != 0` → return (idempotent).
2. Require `cashOutWeightIsSet == true`.
3. Compute `feeAmount = mulDiv(pot, _commitmentPercentOf[gameId], SPLITS_TOTAL_PERCENT)`.
4. Store `fulfilledCommitmentsOf[gameId] = max(feeAmount, 1)` (reentrancy guard).
5. Call `terminal.sendPayoutsOf(gameId, token, feeAmount, ...)`.
6. Queue final ruleset: no payout limits, no fund access constraints, surplus = entire balance.

### No-Contest Trigger (DefifaDeployer.triggerNoContestFor)

1. Require `currentGamePhaseOf(gameId) == NO_CONTEST`.
2. Require `!noContestTriggeredFor[gameId]`.
3. Set `noContestTriggeredFor[gameId] = true`.
4. Queue ruleset: no `fundAccessLimitGroups`, making balance = surplus for full refunds.

---

## Attestation and Governance Mechanics

### Attestation Power Calculation (DefifaGovernor.getAttestationWeight)

Per-tier attestation power for an account:
```
tierPower = MAX_ATTESTATION_POWER_TIER * (account's attestation units / tier's total attestation units)
```

Where:
- `MAX_ATTESTATION_POWER_TIER = 1,000,000,000` (1e9)
- Account's units come from `getPastTierAttestationUnitsOf()` (checkpoint at `attestationsBegin` timestamp)
- Total tier units from `getPastTierTotalAttestationUnitsOf()`

Total attestation power = sum of per-tier powers across all tiers.

### Quorum Calculation (DefifaGovernor.quorum)

```
quorum = (number_of_minted_tiers * MAX_ATTESTATION_POWER_TIER) / 2
```

A tier is "minted" if `currentSupplyOfTier(tierId) != 0` (live supply, reads current state, not snapshotted).

### Scorecard State Machine (DefifaGovernor.stateOf)

```
If ratifiedScorecardIdOf[gameId] != 0:
    This scorecard == ratified? → RATIFIED
    Otherwise → DEFEATED
If attestationsBegin > block.timestamp → PENDING
If gracePeriodEnds > block.timestamp → ACTIVE
If quorum <= attestation count → SUCCEEDED
Otherwise → ACTIVE
```

### Cash-Out Weight Validation (DefifaHookLib.validateAndBuildWeights)

1. Tier IDs must be in strictly ascending order (prevents duplicates).
2. Each tier must be in category 0.
3. Each tier must exist (id <= maxTierId).
4. Cumulative weight must equal exactly `TOTAL_CASHOUT_WEIGHT` (1e18).
5. Stored as `uint256[128]` array indexed by `tierId - 1`.

### Per-Token Cash-Out Weight (DefifaHookLib.computeCashOutWeight)

```
totalTokensForCashoutInTier = initialSupply - remainingSupply - (burnedTokens - tokensRedeemedFrom[tierId])
perTokenWeight = tierWeight / totalTokensForCashoutInTier
```

Integer division rounds down. Maximum dust loss: 1 wei per tier per game (128 wei max across all tiers).

---

## Fee Structure

### Constants

```
DEFIFA_FEE_DIVISOR = 20     → 5.0% to Defifa project
BASE_PROTOCOL_FEE_DIVISOR = 40  → 2.5% to NANA/base protocol project
Total platform fees: 7.5% of the pot
```

### Split Normalization (_buildSplits)

1. Compute absolute percents: `nanaPercent = SPLITS_TOTAL_PERCENT / 40`, `defifaPercent = SPLITS_TOTAL_PERCENT / 20`.
2. Add any user-defined splits.
3. Sum total absolute percent; revert if > SPLITS_TOTAL_PERCENT.
4. Normalize each split: `normalizedPercent = mulDiv(absolutePercent, SPLITS_TOTAL_PERCENT, totalAbsolute)`.
5. NANA split placed last, absorbs rounding remainder: `SPLITS_TOTAL_PERCENT - normalizedTotal`.
6. Store `_commitmentPercentOf[gameId] = totalAbsolutePercent` for fulfillment calculation.

### Fee Token Distribution (_claimTokensFor via DefifaHookLib.claimTokensFor)

During COMPLETE cash-outs, the hook distributes `$DEFIFA` and `$NANA` tokens proportionally:
```
defifaAmount = mulDiv(defifaBalance, shareToBeneficiary, outOfTotal)
baseProtocolAmount = mulDiv(baseProtocolBalance, shareToBeneficiary, outOfTotal)
```

Where `shareToBeneficiary = cumulativeMintPrice` of burned tokens and `outOfTotal = _totalMintCost`.

---

## Priority Audit Areas

### P0 -- Critical (Fund Safety)

1. **Cash-out weight arithmetic**: Verify `computeCashOutWeight()` and `computeCashOutCount()` in `DefifaHookLib` cannot overflow or return inflated values. The `_weight / _totalTokensForCashoutInTier` division is the core economic calculation. Confirm `tokensRedeemedFrom` tracking is correct: incremented ONLY during COMPLETE cash-outs (line 656), NOT during MINT/REFUND refunds.

2. **`_totalMintCost` integrity**: This variable is the denominator for fee token distribution. It is incremented on paid mint (`_mintAll`, line 869), reserved mint (`mintReservesFor`, line 571), and decremented on cash-out (`afterCashOutRecordedWith`, line 685). Verify no path exists where `_totalMintCost` underflows or becomes inconsistent with actual live token count.

3. **Fulfillment reentrancy guard**: `fulfilledCommitmentsOf[gameId]` is set to `max(feeAmount, 1)` BEFORE external calls to `sendPayoutsOf` and `queueRulesetsOf` (DefifaDeployer lines 325-382). Verify this guard prevents double fulfillment via reentrancy through the terminal.

4. **Scorecard execution via low-level call**: `ratifyScorecardFrom` calls `_metadata.dataHook.call(_calldata)` (DefifaGovernor line 402). The `_calldata` is `abi.encodeWithSelector(setTierCashOutWeightsTo.selector, tierWeights)`. Verify that the hash-based proposal system prevents any calldata that does not match the submitted scorecard from being executed.

5. **Fee accounting during fulfillment**: `fulfillCommitmentsOf` computes `feeAmount = mulDiv(pot, _commitmentPercentOf[gameId], SPLITS_TOTAL_PERCENT)` and sends exactly this amount as payouts. Verify that `pot - feeAmount` remains as surplus for cash-outs, and that no rounding error causes `sendPayoutsOf` to revert or leave the project in an inconsistent state.

### P1 -- High (Governance Integrity)

6. **Quorum manipulation via live supply**: `quorum()` reads `currentSupplyOfTier()` at call time (not snapshotted). Verify that burning tokens during SCORING is prevented by `DefifaHook_NothingToClaim` (cash-out weights not set yet). Check if any other burn path exists that could reduce quorum after attestations have begun.

7. **Attestation snapshotting**: Attestation weight is computed at the `attestationsBegin` timestamp via `getPastTierAttestationUnitsOf()`. Verify that the `Checkpoints.Trace208.upperLookup()` correctly captures the state at that exact timestamp, and that minting or transferring NFTs after `attestationsBegin` does not retroactively affect attestation power.

8. **Double attestation prevention**: `_attestations.hasAttested[msg.sender]` (DefifaGovernor line 354) prevents double voting. But verify that an attacker cannot attest, transfer NFTs to another address, and have that address attest with the same attestation power (the snapshot at `attestationsBegin` should prevent this, but verify the checkpoint resolution).

9. **Grace period anchoring**: `gracePeriodEnds = attestationsBegin + attestationGracePeriod` (DefifaGovernor line 477). Verify that early scorecard submission (before `attestationStartTime`) correctly delays the grace period start, preventing instant ratification.

### P2 -- Medium (Access Control and State Transitions)

10. **Hook ownership chain**: DefifaDeployer creates the hook clone, calls `initialize()`, then `transferOwnership(GOVERNOR)` (line 568). Verify that no window exists between `initialize()` and `transferOwnership()` where an attacker could call `setTierCashOutWeightsTo()` (requires `onlyOwner`).

11. **Phase check ordering in `currentGamePhaseOf()`**: The function checks `cashOutWeightIsSet` BEFORE `noContestTriggeredFor` (lines 233-236). Verify this ordering is correct: a ratified scorecard should always take priority over no-contest.

12. **Clone initialization guard**: `DefifaHook.initialize()` checks `address(this) == CODE_ORIGIN` (line 486, prevents initializing the implementation) and `address(store) != address(0)` (line 489, prevents re-initialization). Verify these guards are sufficient against proxy/clone attacks.

13. **Delegation lockdown**: `setTierDelegateTo` and `setTierDelegatesTo` require `MINT` phase (DefifaHook lines 740, 751). Verify that auto-delegation on transfer (`_transferTierAttestationUnits`, lines 1027-1031) correctly handles the case where a recipient already has a delegate set.

### P3 -- Low (Edge Cases and Rounding)

14. **Integer division dust**: `computeCashOutWeight()` returns `_weight / _totalTokensForCashoutInTier`. The maximum loss is 1 wei per tier. With 128 max tiers, at most 128 wei locked per game. Verify this bound is correct.

15. **`uint208` overflow in checkpoints**: Attestation units use `Checkpoints.Trace208`. Maximum per tier: `tier.votingUnits * tier.initialSupply`. With `initialSupply = 999_999_999` and typical voting units, verify this cannot overflow `uint208`.

16. **Token URI resolver interaction**: `DefifaTokenUriResolver.tokenUriOf()` calls `gamePotReporter.currentGamePotOf()` and `hook.cashOutWeightOf()`. Verify that a malicious URI resolver cannot cause state changes or excessive gas consumption.

---

## Invariants

These properties should hold for all games in all states. The test suite validates most of them.

### Fund Conservation
- `totalCashOuts + remainingSurplus + fulfilledCommitments == originalPot` (within N wei where N = total user count)
- `amountRedeemed` (DefifaHook) only increases during COMPLETE cash-outs, never during MINT/REFUND/NO_CONTEST
- `fulfilledCommitmentsOf[gameId]` is set exactly once (idempotent guard)

### Token Accounting
- `_totalMintCost == sum(tier.price * liveTokenCount[tier])` for all tiers at all times
- `tokensRedeemedFrom[tierId]` only incremented during COMPLETE phase cash-outs
- `_totalMintCost` decremented by exactly `cumulativeMintPrice` on each cash-out

### Scorecard Integrity
- `sum(tierWeights[i].cashOutWeight) == TOTAL_CASHOUT_WEIGHT` (exactly 1e18) for any ratified scorecard
- Tier IDs in scorecard are strictly ascending (no duplicates)
- Only tiers in category 0 can receive cash-out weight
- Only tiers with `currentSupply > 0` can receive nonzero weight at submission time

### Governance
- Each account can attest to a given scorecard at most once
- Attestation power is snapshotted at `attestationsBegin` (not live)
- Quorum threshold: 50% of minted tiers' total max attestation power (live at call time)
- Only one scorecard can be ratified per game
- Minimum grace period: 1 day (enforced in `initializeGame`, line 303)

### Phase Transitions
- A ratified scorecard (`cashOutWeightIsSet == true`) always produces COMPLETE, regardless of other conditions
- NO_CONTEST is only reachable from SCORING (never from MINT or REFUND)
- `triggerNoContestFor` can be called exactly once per game
- Phase progression is monotonic: COUNTDOWN -> MINT -> REFUND -> SCORING -> COMPLETE/NO_CONTEST

### Attestation Units
- Sum of all delegate attestation units for a tier == total tier attestation units (conservation on transfer)
- Auto-delegation on transfer prevents units from being lost to `address(0)`
- Delegation changes only allowed during MINT phase (except auto-delegation on transfer)

---

## Testing

### Test Files (14 files, ~100 test functions)

| File | Focus |
|------|-------|
| `DefifaGovernor.t.sol` | Core lifecycle: minting, refunding, scoring, cash-out. Fuzz tests on tier counts and distributions. |
| `DefifaSecurity.t.sol` | Fund conservation (fuzz), high-volume 32 tiers, winner-take-all, extreme weights, quorum manipulation, delegation lockdown, reserved minter fee tokens. |
| `DefifaNoContest.t.sol` | Both NO_CONTEST triggers: minParticipation threshold and scorecardTimeout. Trigger/refund/idempotency. |
| `DefifaFeeAccounting.t.sol` | Fee split normalization, rounding loss bounds, cash-out after fees, user splits. |
| `DefifaMintCostInvariant.t.sol` | Stateful fuzz: `_totalMintCost` invariant across random mints and refunds. |
| `DefifaHookRegressions.t.sol` | Audit finding M-5: attestation unit conservation on transfer to undelegated recipients. |
| `DefifaAuditLowGuards.t.sol` | Input validation: double initialization, uint48 overflow, zero-address delegation. |
| `Fork.t.sol` | Mainnet fork tests: full lifecycle, edge cases, all revert conditions, scorecard state machine. ~50 tests. |
| `regression/FulfillmentBlocksRatification.t.sol` | Fulfillment failure does not block ratification (try-catch behavior). |
| `regression/GracePeriodBypass.t.sol` | Grace period extends from attestation start, not submission time. |
| `DefifaUSDC.t.sol` | ERC-20 (USDC) game variant. |
| `SVG.t.sol` | Token URI resolver SVG rendering. |

### Running Tests

```bash
forge test --match-path "test/*.t.sol" -vvv
forge test --match-path "test/regression/*.t.sol" -vvv
```

For invariant tests:
```bash
forge test --match-contract DefifaMintCostInvariant -vvv
```

### Known Test Gaps

| Area | Current Coverage | Risk |
|------|-----------------|------|
| ERC-20 token games (non-ETH) | Single USDC test file | LOW |
| Games with >32 tiers | Fuzz caps at 12, one test at 32 | LOW |
| Concurrent multi-game governor | Tests use single game per governor | MEDIUM |
| Adversarial token URI resolver | No malicious resolver test | LOW |
| Clone address collision | No explicit collision test | LOW |

---

## Constants Reference

| Constant | Value | Location |
|----------|-------|---------|
| `TOTAL_CASHOUT_WEIGHT` | 1e18 | DefifaHookLib line 28 |
| `MAX_ATTESTATION_POWER_TIER` | 1e9 | DefifaGovernor line 64 |
| `DEFIFA_FEE_DIVISOR` | 20 (5%) | DefifaDeployer line 111 |
| `BASE_PROTOCOL_FEE_DIVISOR` | 40 (2.5%) | DefifaDeployer line 107 |
| `SPLITS_TOTAL_PERCENT` | 1e9 | JBConstants |
| `initialSupply` per tier | 999,999,999 | DefifaDeployer line 491 |
| Max tiers per game | 128 | DefifaHook `uint256[128]` (line 76) |
| Min grace period | 1 day | DefifaGovernor line 303 |
| Compiler | Solidity 0.8.26 | All files |

---

## Entry Points for Review

Start with the money: follow ETH from payment to cash-out.

1. `DefifaHook._processPayment()` (line 929) -- where tokens enter
2. `DefifaHook.beforeCashOutRecordedWith()` (line 253) -- reclaim calculation
3. `DefifaHook.afterCashOutRecordedWith()` (line 605) -- where tokens leave
4. `DefifaDeployer.fulfillCommitmentsOf()` (line 296) -- fee distribution
5. `DefifaGovernor.ratifyScorecardFrom()` (line 372) -- scorecard execution
6. `DefifaHookLib.validateAndBuildWeights()` (line 35) -- weight validation
7. `DefifaHookLib.computeCashOutWeight()` (line 95) -- per-token value
8. `DefifaDeployer._buildSplits()` (line 826) -- fee normalization
9. `DefifaDeployer.currentGamePhaseOf()` (line 221) -- phase state machine
10. `DefifaDeployer.triggerNoContestFor()` (line 586) -- no-contest safety valve
