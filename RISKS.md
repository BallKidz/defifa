# RISKS.md -- defifa-collection-deployer-v6

## 1. Trust Assumptions

- **Governor as Hook Owner.** The DefifaGovernor owns each DefifaHook clone. The governor can set tier cash-out weights via `ratifyScorecardFrom`, which executes an arbitrary call to the hook. If the governor is compromised, the hook's cash-out weights can be set to any values.
- **Deployer as Project Owner.** The DefifaDeployer contract owns all game projects. It controls ruleset queuing, payout sending, and split configuration. Its logic is immutable (no upgradability), so the trust boundary is the contract code itself.
- **DefifaProjectOwner Irrecoverability.** Once the Defifa project NFT is transferred to DefifaProjectOwner, it cannot be recovered. This is intentional but irreversible.
- **External Dependencies.** Relies on JB721TiersHookStore, JBController, JBMultiTerminal, JBRulesets, and JBPrices. Bugs in any upstream contract affect all Defifa games.
- **Default Attestation Delegate.** If set, the default attestation delegate receives delegated attestation power for all new minters who do not specify a delegate. This entity accumulates significant governance power.
- **721 hook store shared with nana-721-hook-v6.** DefifaHook extends `JB721TiersHook`, sharing the same `JB721TiersHookStore`. All store-level risks from [nana-721-hook-v6 RISKS.md](../nana-721-hook-v6/RISKS.md) apply — including the `totalCashOutWeight` tier iteration cost and the category sort order enforcement. Store bugs affect all Defifa games simultaneously.

## 2. Economic Risks

- **Scorecard manipulation via 50% quorum.** A single entity that acquires 50%+ of attestation power across tiers can unilaterally ratify any scorecard, directing the entire pot to chosen tiers. Per-tier cap at `MAX_ATTESTATION_POWER_TIER` limits single-tier dominance. 1-day minimum grace period gives counter-attestors time to respond.
- **Dynamic quorum from live supply.** Quorum is computed from `currentSupplyOfTier()` at call time, not from a snapshot. Token burns between attestation and ratification decrease quorum. During SCORING phase, burns revert with `NothingToClaim` preventing practical exploitation, but a future code path allowing SCORING burns could re-enable this.
- **Cash-out weight integer division truncation.** `_weight / _totalTokensForCashoutInTier` rounds down, permanently locking dust in the contract. Maximum loss: 1 wei per tier per game (128 wei max with 128 tiers).
- **Fee token dilution from reserved mints.** Reserved mints increment `_totalMintCost` by `tier.price * count` even though no ETH was paid. This dilutes paid minters' share of fee tokens (`$DEFIFA` / `$NANA`). Example: if 1000 NFTs are minted by payers (paying 1 ETH each = 1000 ETH total), and 100 reserved NFTs are minted (adding 100 ETH to `_totalMintCost` with no ETH deposited), fee token claims are diluted by ~9.1% (100/1100). The dilution is bounded by the reserve frequency — at `reserveFrequency=10`, every 10th mint is a reserve, capping dilution at ~10%.
- **128-tier limit hard-coded.** `_tierCashOutWeights` is a fixed `uint256[128]` array. Games with more than 128 tiers have tiers beyond index 128 unable to receive cash-out weights.

## 3. Governance Risks

- **Single governor instance across all games.** All games share one DefifaGovernor. A bug in `ratifyScorecardFrom`, `attestToScorecardFrom`, or `submitScorecardFor` affects every game simultaneously.
- **Scorecard timeout can block legitimate ratification.** If `scorecardTimeout` elapses before ratification, the game permanently enters NO_CONTEST. Even a scorecard that has reached quorum cannot be ratified. `triggerNoContestFor()` is permissionless and allows fund recovery.
- **Delegation locked after MINT phase.** `setTierDelegateTo` only works during MINT phase. After MINT, NFT transfers auto-delegate to the recipient, but holders cannot explicitly re-delegate to a third party.
- **No-contest requires explicit trigger.** In NO_CONTEST, users cannot immediately cash out -- someone must call `triggerNoContestFor()` to queue a refund ruleset. Without this trigger, the SCORING ruleset allocates the entire balance as payouts, leaving surplus at 0.

## 4. Reentrancy Surface

- **afterCashOutRecordedWith.** Burns tokens before external calls. `_claimTokensFor` calls `safeTransfer` on ERC-20 tokens (DEFIFA_TOKEN, BASE_PROTOCOL_TOKEN). Preceding burn and state updates prevent meaningful reentrancy profit.

## 5. DoS Vectors

- **Unbounded tier iteration in governance.** `getAttestationWeight` and `quorum` iterate over all tiers (`maxTierIdOf`). Gas cost: ~3-5k per tier (storage read + bitmap check). At 128 tiers (the hard cap), ~400-650k gas for a single `quorum()` call. At the block gas limit (30M), this is safe, but composing `quorum()` inside a larger transaction (e.g., `ratifyScorecardFrom`) adds the iteration cost on top of the ratification logic. Games should target <64 tiers for comfortable gas headroom.
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

## 8. Accepted Behaviors

### 8.1 Scorecard timeout is intentionally irreversible

If `scorecardTimeout` elapses before ratification, the game permanently enters NO_CONTEST. Even a scorecard that has reached quorum cannot be ratified after timeout. This is accepted because: (1) allowing late ratification would keep player funds locked indefinitely while governance debates, (2) NO_CONTEST triggers a refund path (`triggerNoContestFor`) that returns funds pro-rata, and (3) the timeout creates a credible commitment to resolve the game within a bounded time. The timeout duration is set at deployment and cannot be changed.

### 8.2 Permanent cash-out weights (no correction mechanism)

Cash-out weights set via `ratifyScorecardFrom` cannot be updated or corrected. This is accepted because: (1) allowing weight changes would introduce governance attack surfaces where a quorum re-ratifies to steal from other tiers, (2) the attestation process provides a dispute window (grace period) before ratification finalizes, and (3) the alternative (upgradeable weights) would undermine the trust-minimized game design. If a scorecard is wrong, the game should be allowed to timeout into NO_CONTEST for refunds.

### 8.3 fulfillCommitmentsOf reentrancy is guarded

`fulfillCommitmentsOf` uses `fulfilledCommitmentsOf[gameId]` as a reentrancy guard (set before `sendPayoutsOf`). Returns early if already non-zero. Uses `max(feeAmount, 1)` to ensure the guard works even when pot rounds to 0. `sendPayoutsOf` is wrapped in try-catch: on failure, resets to sentinel (1) and emits `CommitmentPayoutFailed`, ensuring the final ruleset is always queued.

### 8.4 ratifyScorecardFrom reentrancy is double-guarded

`ratifyScorecardFrom` executes arbitrary calldata on the hook via low-level call. The hook's `setTierCashOutWeightsTo` has an `onlyOwner` guard and a `cashOutWeightIsSet` check preventing double-set. Both guards prevent reentrancy exploitation.

### 8.5 Attestation snapshot uses block.timestamp - 1 (Codex R2 fix)

`attestToScorecardFrom` snapshots attestation weight at `block.timestamp - 1` instead of `attestationsBegin`. This prevents same-block transfer manipulation where a holder attests, transfers the NFT, and the recipient also attests in the same block. The trade-off is that NFTs minted in the same block as an attestation call have zero weight for that call -- the holder must wait 1 second. This is acceptable because attestation typically happens well after minting, and the 1-second delay is negligible.

### 8.6 Pending reserves dilute cash-out weight (Codex R2 fix)

`computeCashOutWeight` includes pending (unminted) reserve NFTs in the denominator. This means a paid holder's per-token cash-out share is reduced by the number of pending reserves in their tier. The trade-off is that if reserve NFTs are never minted (e.g., the reserve beneficiary is set to address(0) and minting reverts), those shares remain locked in the contract. This is acceptable because: (1) it prevents paid holders from front-running reserve minting to extract the reserves' share, and (2) reserve beneficiaries are set at deployment and should always be valid.
