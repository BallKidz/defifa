# defifa-collection-deployer-v6 -- Audit Instructions

Prediction game platform built on Juicebox V6. Players buy NFT tiers representing outcomes, a governance process scores the outcomes, and winners claim treasury funds proportional to their tier's score.

---

## Architecture

Five contracts, one library. Total ~3,990 lines in `src/` (~3,320 in the six main files below).

```
DefifaDeployer.sol       (937 lines)  -- Game factory. Owns all game JB projects. Manages lifecycle rulesets, fee splits, fulfillment, no-contest.
DefifaHook.sol           (1097 lines) -- Pay/cashout hook. NFT minting, burning, attestation delegation, fee token distribution, cash-out weight logic.
DefifaGovernor.sol       (516 lines)  -- Scorecard governance. Submit, attest, ratify scorecards. Singleton across all games.
DefifaHookLib.sol        (373 lines)  -- Pure/view helpers. Weight validation, cash-out math, attestation computation, token claiming.
DefifaProjectOwner.sol   (86 lines)   -- Permanent holder of the Defifa project NFT. Grants SET_SPLIT_GROUPS permission.
DefifaTokenUriResolver.sol (315 lines) -- On-chain SVG metadata for game NFTs.
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
  │   └── calls DefifaDeployer.fulfillCommitmentsOf() (internal try-catch on sendPayoutsOf)
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

Phases are determined by Juicebox ruleset cycle numbers, safety mechanism checks, and scorecard ratification status. The state machine is in `DefifaDeployer.currentGamePhaseOf()`.

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
4. Direct call: `IDefifaDeployer(owner).fulfillCommitmentsOf(gameId)`.

### Commitment Fulfillment (DefifaDeployer.fulfillCommitmentsOf)

1. Guard: `fulfilledCommitmentsOf[gameId] != 0` → return (idempotent).
2. Require `cashOutWeightIsSet == true`.
3. Compute `feeAmount = mulDiv(pot, _commitmentPercentOf[gameId], SPLITS_TOTAL_PERCENT)`.
4. Store `fulfilledCommitmentsOf[gameId] = max(feeAmount, 1)` (reentrancy guard).
5. Try-catch: `terminal.sendPayoutsOf(gameId, token, feeAmount, ..., minTokensPaidOut: 0)`. On failure, reset to sentinel (1) and emit `CommitmentPayoutFailed`.
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

### Entry Points for Review

Start with the money: follow ETH from payment to cash-out.

1. `DefifaHook._processPayment()` -- where tokens enter
2. `DefifaHook.beforeCashOutRecordedWith()` -- reclaim calculation
3. `DefifaHook.afterCashOutRecordedWith()` -- where tokens leave
4. `DefifaDeployer.fulfillCommitmentsOf()` -- fee distribution
5. `DefifaGovernor.ratifyScorecardFrom()` -- scorecard execution
6. `DefifaHookLib.validateAndBuildWeights()` -- weight validation
7. `DefifaHookLib.computeCashOutWeight()` -- per-token value
8. `DefifaDeployer._buildSplits()` -- fee normalization
9. `DefifaDeployer.currentGamePhaseOf()` -- phase state machine
10. `DefifaDeployer.triggerNoContestFor()` -- no-contest safety valve

### P0 -- Critical (Fund Safety)

1. **Cash-out weight arithmetic**: Verify `computeCashOutWeight()` and `computeCashOutCount()` in `DefifaHookLib` cannot overflow or return inflated values. The `_weight / _totalTokensForCashoutInTier` division is the core economic calculation. Confirm `tokensRedeemedFrom` tracking is correct: incremented ONLY during COMPLETE cash-outs, NOT during MINT/REFUND refunds.

2. **`_totalMintCost` integrity**: This variable is the denominator for fee token distribution. It is incremented on paid mint (`_mintAll`), reserved mint (`mintReservesFor`), and decremented on cash-out (`afterCashOutRecordedWith`). Verify no path exists where `_totalMintCost` underflows or becomes inconsistent with actual live token count.

3. **Fulfillment reentrancy guard**: `fulfilledCommitmentsOf[gameId]` is set to `max(feeAmount, 1)` BEFORE external calls to `sendPayoutsOf` and `queueRulesetsOf`. Verify this guard prevents double fulfillment via reentrancy through the terminal.

4. **Scorecard execution via low-level call**: `ratifyScorecardFrom` calls `_metadata.dataHook.call(_calldata)`. The `_calldata` is `abi.encodeWithSelector(setTierCashOutWeightsTo.selector, tierWeights)`. Verify that the hash-based proposal system prevents any calldata that does not match the submitted scorecard from being executed.

5. **Fee accounting during fulfillment**: `fulfillCommitmentsOf` computes `feeAmount = mulDiv(pot, _commitmentPercentOf[gameId], SPLITS_TOTAL_PERCENT)` and sends this amount as payouts via try-catch. On success, `fulfilledCommitmentsOf` retains the fee amount; on failure, it resets to sentinel (1) and the fee stays in the pot. Verify that `currentGamePotOf` correctly subtracts `fulfilledCommitmentsOf` and that the sentinel value (1 wei) does not cause meaningful accounting error.

### P1 -- High (Governance Integrity)

6. **Quorum manipulation via live supply**: `quorum()` reads `currentSupplyOfTier()` at call time (not snapshotted). Verify that burning tokens during SCORING is prevented by `DefifaHook_NothingToClaim` (cash-out weights not set yet). Check if any other burn path exists that could reduce quorum after attestations have begun.

7. **Attestation snapshotting**: Attestation weight is computed at the `attestationsBegin` timestamp via `getPastTierAttestationUnitsOf()`. Verify that the `Checkpoints.Trace208.upperLookup()` correctly captures the state at that exact timestamp, and that minting or transferring NFTs after `attestationsBegin` does not retroactively affect attestation power.

8. **Double attestation prevention**: `_attestations.hasAttested[msg.sender]` prevents double voting. But verify that an attacker cannot attest, transfer NFTs to another address, and have that address attest with the same attestation power (the snapshot at `attestationsBegin` should prevent this, but verify the checkpoint resolution).

9. **Grace period anchoring**: `gracePeriodEnds = attestationsBegin + attestationGracePeriod`. Verify that early scorecard submission (before `attestationStartTime`) correctly delays the grace period start, preventing instant ratification.

### P2 -- Medium (Access Control and State Transitions)

10. **Hook ownership chain**: DefifaDeployer creates the hook clone, calls `initialize()`, then `transferOwnership(GOVERNOR)`. Verify that no window exists between `initialize()` and `transferOwnership()` where an attacker could call `setTierCashOutWeightsTo()` (requires `onlyOwner`).

11. **Phase check ordering in `currentGamePhaseOf()`**: The function checks `cashOutWeightIsSet` BEFORE `noContestTriggeredFor`. Verify this ordering is correct: a ratified scorecard should always take priority over no-contest.

12. **Clone initialization guard**: `DefifaHook.initialize()` checks `address(this) == CODE_ORIGIN` (prevents initializing the implementation) and `address(store) != address(0)` (prevents re-initialization). Verify these guards are sufficient against proxy/clone attacks.

13. **Delegation lockdown**: `setTierDelegateTo` and `setTierDelegatesTo` require `MINT` phase. Verify that auto-delegation on transfer (`_transferTierAttestationUnits`) correctly handles the case where a recipient already has a delegate set.

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
- Minimum grace period: 1 day (enforced in `initializeGame`)

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

### Test Files (16 files, ~172 test functions)

| File | Focus |
|------|-------|
| `DefifaGovernor.t.sol` | Core lifecycle: minting, refunding, scoring, cash-out. Fuzz tests on tier counts and distributions. |
| `DefifaSecurity.t.sol` | Fund conservation (fuzz), high-volume 32 tiers, winner-take-all, extreme weights, quorum manipulation, delegation lockdown, reserved minter fee tokens. |
| `DefifaNoContest.t.sol` | Both NO_CONTEST triggers: minParticipation threshold and scorecardTimeout. Trigger/refund/idempotency. |
| `DefifaFeeAccounting.t.sol` | Fee split normalization, rounding loss bounds, cash-out after fees, user splits. |
| `DefifaMintCostInvariant.t.sol` | Stateful fuzz: `_totalMintCost` invariant across random mints and refunds. |
| `DefifaHookRegressions.t.sol` | Audit finding M-5: attestation unit conservation on transfer to undelegated recipients. |
| `DefifaAuditLowGuards.t.sol` | Input validation: double initialization, uint48 overflow, zero-address delegation. |
| `Fork.t.sol` | Mainnet fork tests: full lifecycle, edge cases, all revert conditions, scorecard state machine. 69 tests. |
| `regression/FulfillmentBlocksRatification.t.sol` | Fulfillment failure does not block ratification (try-catch behavior). |
| `regression/GracePeriodBypass.t.sol` | Grace period extends from attestation start, not submission time. |
| `DefifaAdversarialQuorum.t.sol` | Adversarial governance: late-buyer attestation power, delegation lockdown, double attestation, quorum manipulation, competing scorecards. 9 tests. |
| `TestQALastMile.t.sol` | Edge cases: cash-out DoS during fulfillment window, game ID prediction race condition. 2 tests. |
| `deployScript.t.sol` | Deploy script smoke test. |
| `DefifaUSDC.t.sol` | ERC-20 (USDC) game variant. |
| `SVG.t.sol` | Token URI resolver SVG rendering. |
| `TestAuditGaps.sol` | Audit gap coverage: ERC-20 game mechanics (mint, refund, scoring, fee fulfillment, cash-out distribution, no-contest with ERC-20 tokens, pot reporting), multi-game governor isolation (independent project IDs, balances, NFT hooks, scorecard submission/attestation/ratification isolation, quorum independence, fulfilled commitments independence). 17 tests across 2 test contracts. |

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
| ERC-20 token games (non-ETH) | Expanded: USDC test file + 8 ERC-20 tests in TestAuditGaps.sol (mint, refund, scoring, fee accounting, even distribution, no-contest, pot calculation) | LOW |
| Games with >32 tiers | Fuzz caps at 12, one test at 32 | LOW |
| Concurrent multi-game governor | Expanded: 9 multi-game isolation tests in TestAuditGaps.sol (independent IDs, balances, hooks, scorecard isolation, attestation power isolation, quorum, fulfilled commitments, full lifecycle) | LOW |
| Adversarial token URI resolver | No malicious resolver test | LOW |
| Clone address collision | No explicit collision test | LOW |

---

## Constants Reference

| Constant | Value | Location |
|----------|-------|---------|
| `TOTAL_CASHOUT_WEIGHT` | 1e18 | `DefifaHookLib` |
| `MAX_ATTESTATION_POWER_TIER` | 1e9 | `DefifaGovernor` |
| `DEFIFA_FEE_DIVISOR` | 20 (5%) | `DefifaDeployer` |
| `BASE_PROTOCOL_FEE_DIVISOR` | 40 (2.5%) | `DefifaDeployer` |
| `SPLITS_TOTAL_PERCENT` | 1e9 | `JBConstants` |
| `initialSupply` per tier | 999,999,999 | `DefifaDeployer` |
| Max tiers per game | 128 | `DefifaHook` (`uint256[128]`) |
| Min grace period | 1 day | `DefifaGovernor` |
| Compiler | Solidity 0.8.26 | All files |

---

## Anti-Patterns to Hunt

| Pattern | Where | Why Dangerous |
|---------|-------|---------------|
| Low-level `.call()` with arbitrary calldata | `DefifaGovernor.ratifyScorecardFrom()` | Executes `_metadata.dataHook.call(_calldata)` -- if hash-based proposal verification is flawed, arbitrary calldata could be executed on the hook |
| `unchecked` block around state mutation | `DefifaHook.afterCashOutRecordedWith()` | `++tokensRedeemedFrom[tierId]` in `unchecked` -- overflow of this counter would corrupt cash-out weight calculations for the tier |
| Optimistic project ID prediction | `DefifaDeployer.launchGameWith()` | `gameId = PROJECTS.count() + 1` -- race condition with concurrent project creation. Mitigated by post-launch equality check, but `_opsOf[gameId]` is written before the check |
| No reentrancy guard (no `ReentrancyGuard`) | All contracts | Relies on state ordering (storage writes before external calls) instead of explicit reentrancy locks. Any future refactor that reorders could introduce reentrancy |
| `minTokensPaidOut: 0` on `sendPayoutsOf` | `DefifaDeployer.fulfillCommitmentsOf()` | Zero slippage protection -- MEV sandwich could extract value from the payout if the terminal swaps tokens |
| Casting `address` to `uint32` for currency | `DefifaDeployer.fulfillCommitmentsOf()` | `uint32(uint160(_token))` truncates the address to 32 bits. Must match terminal's accounting context exactly or payout fails |
| Clone initialization window | `DefifaDeployer.launchGameWith()` | Hook is initialized before `transferOwnership(GOVERNOR)`. Between `initialize()` (owner = deployer) and `transferOwnership()`, the hook's `onlyOwner` functions are callable by the deployer. Mitigated by atomic transaction |
| `delegatecall` from library | `DefifaHookLib.claimTokensFor()` | Executes via `delegatecall` to the library -- `address(this)` is the hook's address, `safeTransfer` sends from the hook's balance. Incorrect library linkage could drain the hook |
| Live supply in quorum calculation | `DefifaGovernor.quorum()` | Uses `currentSupplyOfTier()` (live, not snapshotted). If burns become possible during SCORING, quorum could be manipulated downward after attestations begin |
| Integer division dust accumulation | `DefifaHookLib.computeCashOutWeight()` | `_weight / _totalTokensForCashoutInTier` rounds down. Dust (up to 1 wei per tier) is permanently locked. 128 tiers = max 128 wei locked per game |
| `_totalMintCost` as fee token denominator | `DefifaHook._totalMintCost` internal variable | Incremented on mint, decremented on cash-out. If any path allows underflow (e.g., reserved mint followed by full refund), fee token claims revert or distribute incorrectly |
| Try-catch swallowing failures silently | `DefifaDeployer.fulfillCommitmentsOf()` | `sendPayoutsOf` failure is caught and fee stays in pot. The sentinel value (1 wei) subtracted from pot in `currentGamePotOf` is an accounting approximation |
| External call in view function | `DefifaTokenUriResolver.tokenUriOf()` | Calls `gamePotReporter.currentGamePotOf()`, `hook.cashOutWeightOf()`, and `hook.store().totalSupplyOf()`. A malicious URI resolver could cause excessive gas consumption in off-chain reads |
| `block.timestamp` as scorecard ID component | `DefifaGovernor.submitScorecardFor()` | `attestationsBegin = uint48(block.timestamp + ...)` -- miner manipulation of timestamp (within 15s drift) could affect grace period boundaries |

---

## How to Report Findings

### Finding Format

Each finding should use this 7-point structure:

1. **Title** -- One-line summary (e.g., "Quorum manipulation via token burns during SCORING phase")
2. **Affected Contract(s)** -- List the specific contract(s) and function(s) involved
3. **Description** -- Clear explanation of the vulnerability and its root cause
4. **Trigger Sequence** -- Step-by-step reproduction instructions:
   - Step 1: Deploy game with X configuration...
   - Step 2: Attacker calls Y with Z parameters...
   - Step 3: Observe unexpected state change...
5. **Impact** -- Concrete consequences: funds at risk (in ETH/USD), governance bypass capability, denial-of-service scope, affected user count
6. **Proof** -- Code snippet showing the vulnerable path, or a Foundry PoC test (`forge test --match-test testExploitName -vvvv`)
7. **Fix** -- Suggested remediation with specific code changes

### Severity Guide

| Severity | Criteria | Examples |
|----------|----------|---------|
| **CRITICAL** | Direct, unconditional fund loss or theft. Exploitable by anyone without special permissions. | Draining the game pot, bypassing cash-out weight validation, minting unlimited tokens |
| **HIGH** | Conditional fund loss requiring specific timing or state, or authorization/access-control bypass. | Scorecard ratification without quorum, fulfillment reentrancy, phase transition manipulation |
| **MEDIUM** | State inconsistency, griefing, or economic damage bounded by dust amounts or requiring unlikely conditions. | Quorum drift from live supply, fee token dilution from reserved mints, rounding errors above documented bounds |
| **LOW** | Cosmetic issues, gas inefficiencies, informational observations, or theoretical attacks with no practical exploit path. | Token URI gas consumption, unused return values, documentation inaccuracies |

---

## Previous Audit Findings

No prior formal audit with finding IDs has been conducted for defifa-collection-deployer-v6. Known risks, trust assumptions, and economic edge cases are documented in [RISKS.md](./RISKS.md). The test suite (16 files, ~172 test functions) includes regression tests for specific issues discovered during development:

- `DefifaHookRegressions.t.sol` -- Attestation unit conservation on transfer to undelegated recipients (M-5 equivalent)
- `regression/AttestationDelegateBeneficiary.t.sol` -- Default attestation delegate is beneficiary, not payer (H-6)
- `regression/FulfillmentBlocksRatification.t.sol` -- Fulfillment failure does not block ratification
- `regression/GracePeriodBypass.t.sol` -- Grace period extends from attestation start, not submission time

---

## Compiler and Version Info

| Setting | Value | Source |
|---------|-------|--------|
| Solidity version | `0.8.26` | `foundry.toml` `solc` field; all `src/*.sol` files use `pragma solidity 0.8.26` (library uses `^0.8.17`) |
| EVM target | `cancun` | `foundry.toml` `evm_version` field |
| Optimizer | Enabled, 200 runs | `foundry.toml` `optimizer_runs = 200` |
| Via IR | `true` | `foundry.toml` `via_ir = true` -- uses the Yul-based compilation pipeline |
| Fuzz runs | 4096 | `foundry.toml` `[fuzz]` section |
| Invariant runs | 1024, depth 100 | `foundry.toml` `[invariant]` section |
| Invariant fail-on-revert | `false` | `foundry.toml` -- reverts do not fail invariant tests |
| Framework | Foundry (forge) | Standard Foundry project layout |

**Notes for auditors:**
- `via_ir = true` enables the Yul intermediate representation pipeline, which can produce different optimization artifacts than the legacy pipeline. Stack-too-deep workarounds may mask complexity.
- `optimizer_runs = 200` balances deployment cost vs. runtime gas. Low run counts favor deployment cost, which may produce less-optimized runtime bytecode.
- `evm_version = cancun` enables Cancun opcodes (TSTORE/TLOAD, MCOPY, etc.). Verify the target deployment chain supports Cancun.
