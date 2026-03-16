# RISKS.md -- defifa-collection-deployer-v6

## 1. Trust Assumptions

- **Governor as Hook Owner.** The DefifaGovernor owns each DefifaHook clone. The governor can set tier cash-out weights via `ratifyScorecardFrom`, which executes an arbitrary call to the hook. If the governor is compromised, the hook's cash-out weights can be set to any values.
- **Deployer as Project Owner.** The DefifaDeployer contract owns all game projects. It controls ruleset queuing, payout sending, and split configuration. Its logic is immutable (no upgradability), so the trust boundary is the contract code itself.
- **DefifaProjectOwner Irrecoverability.** Once the Defifa project NFT is transferred to DefifaProjectOwner, it cannot be recovered. This is intentional but irreversible.
- **External Dependencies.** Relies on JB721TiersHookStore, JBController, JBMultiTerminal, JBRulesets, and JBPrices. Bugs in any upstream contract affect all Defifa games.
- **Default Attestation Delegate.** If set, the default attestation delegate receives delegated attestation power for all new minters who do not specify a delegate. This entity accumulates significant governance power.

## 2. Economic Risks

- **Scorecard manipulation via 50% quorum.** A single entity that acquires 50%+ of attestation power across tiers can unilaterally ratify any scorecard, directing the entire pot to chosen tiers. Per-tier cap at `MAX_ATTESTATION_POWER_TIER` limits single-tier dominance. 1-day minimum grace period gives counter-attestors time to respond.
- **Dynamic quorum from live supply.** Quorum is computed from `currentSupplyOfTier()` at call time, not from a snapshot. Token burns between attestation and ratification decrease quorum. During SCORING phase, burns revert with `NothingToClaim` preventing practical exploitation, but a future code path allowing SCORING burns could re-enable this.
- **Cash-out weight integer division truncation.** `_weight / _totalTokensForCashoutInTier` rounds down, permanently locking dust in the contract. Maximum loss: 1 wei per tier per game (128 wei max with 128 tiers).
- **Fee token dilution from reserved mints.** Reserved mints increment `_totalMintCost` by `tier.price * count` even though no ETH was paid. This dilutes paid minters' share of fee tokens (`$DEFIFA` / `$NANA`).
- **128-tier limit hard-coded.** `_tierCashOutWeights` is a fixed `uint256[128]` array. Games with more than 128 tiers have tiers beyond index 128 unable to receive cash-out weights.

## 3. Governance Risks

- **Single governor instance across all games.** All games share one DefifaGovernor. A bug in `ratifyScorecardFrom`, `attestToScorecardFrom`, or `submitScorecardFor` affects every game simultaneously.
- **Scorecard timeout can block legitimate ratification.** If `scorecardTimeout` elapses before ratification, the game permanently enters NO_CONTEST. Even a scorecard that has reached quorum cannot be ratified. `triggerNoContestFor()` is permissionless and allows fund recovery.
- **Delegation locked after MINT phase.** `setTierDelegateTo` only works during MINT phase. After MINT, NFT transfers auto-delegate to the recipient, but holders cannot explicitly re-delegate to a third party.
- **No-contest requires explicit trigger.** In NO_CONTEST, users cannot immediately cash out -- someone must call `triggerNoContestFor()` to queue a refund ruleset. Without this trigger, the SCORING ruleset allocates the entire balance as payouts, leaving surplus at 0.

## 4. Reentrancy Surface

- **afterCashOutRecordedWith.** Burns tokens before external calls. `_claimTokensFor` calls `safeTransfer` on ERC-20 tokens (DEFIFA_TOKEN, BASE_PROTOCOL_TOKEN). Preceding burn and state updates prevent meaningful reentrancy profit.
- **fulfillCommitmentsOf.** Uses `fulfilledCommitmentsOf[gameId]` as a reentrancy guard (set before `sendPayoutsOf`). Returns early if already non-zero. Uses `max(feeAmount, 1)` to ensure the guard works even when pot rounds to 0.
- **ratifyScorecardFrom.** Executes arbitrary calldata on the hook via low-level call. The hook's `setTierCashOutWeightsTo` has an `onlyOwner` guard and a `cashOutWeightIsSet` check preventing double-set.

## 5. DoS Vectors

- **Unbounded tier iteration in governance.** `getAttestationWeight` and `quorum` iterate over all tiers (`maxTierIdOf`). Gas cost grows linearly. Games with many tiers may cause view functions to exceed block gas limits.
- **_buildSplits iteration.** Iterates over user-provided splits array. No explicit cap, but total percent constraint limits practical count.

## 6. Integration Risks

- **Immutable phase timing.** Game rulesets are queued at launch and progress automatically based on duration. Once deployed, phase timing cannot be changed.
- **Permanent cash-out weights.** Cash-out weights are set once via the governor. There is no mechanism to correct a ratified scorecard.
- **No deployer upgrade.** The deployer contract has no upgrade mechanism. Bugs require deploying a new deployer.
- **Clone initialization.** Clones use `cloneDeterministic` with `msg.sender` + nonce in the salt. Salt includes `msg.sender`, preventing cross-caller collision. `initialize()` has a re-initialization guard.

## 7. Invariants to Verify

- `_totalMintCost == tierPrice * liveTokenCount` after every mint and burn.
- Total cash-outs + remaining surplus == pre-fulfillment pot minus fees.
- Scorecard weights sum to exactly `TOTAL_CASHOUT_WEIGHT` (1e18).
- Attestation units are conserved across all transfers (no units lost to `address(0)`).
- `fulfilledCommitmentsOf[gameId]` is set at most once per game.
- Per-tier supply never exceeds `initialSupply`.
- Sum of all delegate attestation units equals total attestation supply.
