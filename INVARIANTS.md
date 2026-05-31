# Invariants of Defifa

Scope: the Defifa game protocol (`@ballkidz/defifa`) — `DefifaDeployer`, `DefifaGovernor`, `DefifaHook`, `DefifaProjectOwner`, and `DefifaTokenUriResolver`. Each Defifa game is a standalone Juicebox V6 project owned by the `DefifaDeployer` contract, with a per-game `DefifaHook` clone owned by the singleton `DefifaGovernor`.

For the cryptoeconomic model (pot formation, prize distribution formula, fee pipeline, parimutuel game theory, parameter design), see `CRYPTO_ECON.md`. This document covers only the **structural / authorization / lifecycle invariants** of the contracts.

| Phase | Source of truth | What's allowed |
|-------|-----------------|----------------|
| COUNTDOWN | `currentRuleset.cycleNumber == 0` | nothing yet — ruleset hasn't started |
| MINT | `cycleNumber == 1` | `pay` mints tier NFTs at `tierPrice`; cash-outs at mint price; delegate changes |
| REFUND | `cycleNumber == 2 && refundPeriodDuration != 0` | `pausePay=true`, cash-outs at mint price |
| SCORING | `cycleNumber >= 2/3` and not NO_CONTEST/COMPLETE | scorecard submission + attestation + ratification |
| COMPLETE | `cashOutWeightIsSet == true` on hook | weighted reclaim by ratified tier weights |
| NO_CONTEST | `noContestTriggeredFor[gameId]` OR `totalMintCost < minParticipation` OR `block.timestamp > scoringStart + scorecardTimeout` (latched via `triggerNoContestFor`) | full refund at mint price after `triggerNoContestFor` queues the refund ruleset |

NO_CONTEST is reported by the view as soon as the condition is met; the on-chain ruleset only flips when `triggerNoContestFor` is called. The view-vs-state gap is the documented reason holders should check the active ruleset before cashing out (`DefifaDeployer.sol:734-737`).

---

# Section A — Guarantees to Users

## A.1 Players (paying / cashing out)

- **MINT phase issuance.** A `pay()` during MINT mints one NFT per tier ID in the metadata-encoded `tierIdsToMint` array, charging `tierPrice` per mint (uniform across tiers so attestation power is equal). Overspending (`leftoverAmount != 0`) reverts with `DefifaHook_Overspending` — payer cannot accidentally over-fund. (`DefifaHook.sol:1075-1079`)
- **Currency lock-in.** Payment currency must equal the `pricingCurrency` baked into the hook at `initialize`; mismatched currency reverts `DefifaHook_WrongCurrency`. (`DefifaHook.sol:1014-1018`)
- **No mints outside MINT.** All non-MINT rulesets carry `pausePay=true` (`DefifaDeployer.sol:961, 1020, 1076`). REFUND, SCORING, COMPLETE, and NO_CONTEST refund cycles all reject `pay`.
- **REFUND-phase reclaim.** During REFUND, surplus equals balance (no payout limits), so cash-out at the prevailing cash-out tax (0% for non-COMPLETE phases per `setTierCashOutWeightsTo` gating) returns each holder their proportional share of the pot — effectively the mint price for paid NFTs. Reserve-minted NFTs are flagged `isReserveMint` and contribute 0 to the cumulative mint price during refund cash-outs (`DefifaHook.sol:307-314`).
- **NO_CONTEST refund.** Once `triggerNoContestFor` runs, the queued ruleset has no payout limits and `cashOutTaxRate=0`, enabling cash-out at mint price. Anyone can trigger this — players are not at the mercy of the deployer. (`DefifaDeployer.sol:723-786`)
- **COMPLETE-phase weighted reclaim.** After scorecard ratification, the hook's `beforeCashOutRecordedWith` substitutes the ratified per-tier `cashOutWeight` for raw token count, so winning tiers reclaim more pot per NFT than losers. Total reclaim is bounded by `TOTAL_CASHOUT_WEIGHT = 1e18` for accounting precision (`DefifaHook.sol:69, 322-328`).
- **Cash-out always burns first.** `JBMultiTerminal.cashOutTokensOf` burns the NFT before transferring reclaim. The hook's `afterCashOutRecordedWith` is invoked only after the burn, decrementing `totalMintCost` (`DefifaHook.sol:707, 759`).
- **0-weight-tier protection against accidental burns.** Tokens whose tier received 0 cash-out weight (losing teams) revert with `DefifaHook_NothingToClaim` if neither reclaim nor fee tokens would be distributed — protecting holders from burning for nothing. (`DefifaHook.sol:752-756`)
- **Fee-token (`$DEFIFA`/`$BASE_PROTOCOL`) claims.** On COMPLETE-phase cash-out, holders also receive their pro-rata share of the fee-project tokens delivered to the hook during `fulfillCommitmentsOf`. Share = `cumulativeMintPrice / (totalMintCost + pendingReserveMintCost)`. Reserves are accounted in the denominator so paid holders cannot claim a disproportionate share before reserves mint. (`DefifaHook.sol:741-745`)
- **Reserve mints are permissionless and capped.** `mintReservesFor` mints to the pre-configured reserve beneficiary only, capped at `adjustedPendingReservesFor(tier)`. No caller can mint more than the tier's reserve frequency entitles. (`DefifaHook.sol:603-604, 607`)
- **Game configuration sanity.** `launchGameWith` reverts if start/mint/refund durations are inconsistent, if `tiers.length > 128`, if `scorecardTimeout == 0`, if ERC-20 games supply `currency=0`, or if `scorecardTimeout` is too short to ever allow ratification (`attestationDelay + gracePeriod + timelock`). (`DefifaDeployer.sol:417-478`)
- **Frozen tier price.** All tiers launch with the same `tierPrice`, `discountPercent=0`, `cantIncreaseDiscountPercent=true`, `cantBeRemoved=true`, `allowOwnerMint=false`. Operator cannot drop in cheap tiers post-launch or admin-mint into a winning tier. (`DefifaDeployer.sol:549-569`)

## A.2 Attesters (governance participants)

- **BWA snapshot at `attestationsBegin - 1`.** Voting power is read from the per-tier checkpoint one second before attestations open. If a submitted scorecard would otherwise open immediately, the governor moves `attestationsBegin` to the next timestamp so the checkpoint includes submission-time state, including same-timestamp reserve mints, while still defeating same-block "transfer-and-attest" sandwiches (`DefifaGovernor.sol:167-171`).
- **Benefit-Weighted Attestation (BWA) reduces beneficiary power.** Each tier's attestation power is scaled by `(totalCashOutWeight - tierWeight) / totalCashOutWeight`. A tier with 100% of the scorecard weight receives 0 attestation power on that scorecard — beneficiaries **cannot self-attest at full power** (`DefifaGovernor.sol:705-709`). Zero-power attestations revert (`DefifaGovernor.sol:175-177`).
- **Concentration-adjusted quorum.** Base quorum is 50% of `eligibleTierWeights × MAX_ATTESTATION_POWER_TIER`. When the scorecard concentrates weight on one tier, quorum is raised by `headroom × maxShare²`, but the penalty is capped so honest non-beneficiaries can always reach quorum (`DefifaGovernor.sol:387-418`).
- **Minimum grace period (1 day).** Enforced at `initializeGame`; prevents instant-ratification attacks (`DefifaGovernor.sol:52, 502-506`).
- **Timelock anchors to the later of grace-period end or quorum-reached time.** A late-arriving quorum still gets the full cooling period (`DefifaGovernor.sol:810-813`).
- **One attestation per (account, scorecard).** Re-attestation reverts `AlreadyAttested`. Revocation requires prior attestation (`DefifaGovernor.sol:162-163, 252-255`).
- **Revocation disabled once QUEUED.** Only `ACTIVE`-state attestations are revocable; this kills the attest/revoke griefing loop while still allowing course-correction during open debate. Quorum-reached timestamp resets to 0 if revocation drops the count below quorum (`DefifaGovernor.sol:243-265`).
- **Single ratification per game.** `ratifiedScorecardIdOf[gameId] != 0` reverts subsequent submissions and ratifications with `AlreadyRatified` (`DefifaGovernor.sol:206-208, 285-287`).
- **Duplicate-scorecard rejection.** `_scorecardOf[gameId][scorecardId].attestationsBegin != 0` ⇒ `DuplicateScorecard`. The scorecard ID is the keccak of `(hook, calldata)`, so the same weight vector cannot be re-submitted (`DefifaGovernor.sol:329-332`).
- **Submission rejects unrealizable weights.** A scorecard with `cashOutWeight > 0` for a tier with `currentSupplyOfTier == 0` reverts (`DefifaGovernor.sol:306-311`). Defends against scorecards that would route value to nobody.
- **Reserve-mint snapshots.** On submission, the governor snapshots each tier's pending reserves and minted attestation units. Immediate scorecards open at the next timestamp, making `attestationsBegin - 1` equal to the submission timestamp. BWA reads `getPastTierTotalAttestationUnitsOf` then clamps to the submitted snapshot, then adds back the snapshotted pending reserves — so reserve mints at or after submission cannot inflate the denominator twice, and same-timestamp reserve mints before submission are included in the checkpoint (`DefifaGovernor.sol:679-696`).
- **Quorum eligibility includes pending reserves.** A tier with all paid tokens burned during REFUND but with pending reserves still contributes to quorum, so a burner cannot erase another participant's quorum contribution (`DefifaGovernor.sol:744-753`).

## A.3 Protections against external interference

- **No third-party can change cash-out weights.** `setTierCashOutWeightsTo` is `onlyOwner` (the governor) AND gated on `gamePhase == SCORING` AND single-shot (`cashOutWeightIsSet`). Even the governor can't re-score a game once set. (`DefifaHook.sol:784-805`)
- **No third-party can re-route fee splits.** Splits are written by the deployer once during `_buildSplits` for the scoring ruleset and never changed (`DefifaDeployer.sol:1042-1049`). The deployer permanently holds the game's `JBProjects` NFT (`DefifaDeployer.sol:481`).
- **No third-party can mint admin NFTs.** `allowOwnerMint=false` on every tier (`DefifaDeployer.sol:559`); the controller's `allowOwnerMinting=false` on every ruleset.
- **Reserve mints blocked in NO_CONTEST.** Prevents a malicious reserve mint from inflating `totalMintCost` past `minParticipation` after the game has already failed the participation check, which would otherwise revive the game from NO_CONTEST → SCORING (`DefifaHook.sol:577-579`).
- **Delegate changes locked after MINT.** `setTierDelegateTo` / `setTierDelegatesTo` revert outside the MINT phase. This freezes voting power before scoring begins, so attestation can't be hot-swapped to a colluding delegate after scorecards drop (`DefifaHook.sol:817-819, 830-832`).
- **`addToBalanceOf` cannot inflate participation.** `minParticipation` is checked against `totalMintCost` (incremented only by paid mints and reserve mints), not terminal balance — donations to the terminal cannot artificially satisfy the participation threshold (`DefifaDeployer.sol:275-281`).
- **Front-run-resistant hook clone.** `cloneDeterministic` salts on `keccak256(msg.sender, nonce)` so a different caller produces a different address; a watcher cannot front-run `launchGameWith` to deploy a hook at the predicted address and DoS initialization (`DefifaDeployer.sol:582-591`).
- **Commitment fulfillment is single-shot.** `commitmentsFulfilledFor[gameId]` set BEFORE external calls; a re-entrant call returns early (`DefifaDeployer.sol:316-317`).
- **NO_CONTEST trigger is single-shot.** `noContestTriggeredFor[gameId]` set BEFORE queuing the refund ruleset; a re-entrant call reverts `NoContestAlreadyTriggered` (`DefifaDeployer.sol:730-738`).

---

# Section B — Guarantees to Owners

## B.1 DefifaDeployer owner

Ownable surface, intentionally tiny.

- **`setReferralProjectId(newReferralProjectId, newReferralChainId)`** — `onlyOwner`. Updates the packed `(chainId << 48) | projectId` reference credited as the referrer on every `sendPayoutsOf` made during `fulfillCommitmentsOf`. Bounded so the pack is lossless (`projectId ≤ uint48.max`, `chainId ≤ uint208.max`). `(0,0)` disables referral credit. The owner **cannot** change ruleset configurations, fees, or the protocol-fee project ID. (`DefifaDeployer.sol:680-700`)
- **Dependency bindings are constructor `immutable`s, not a runtime setter.** `HOOK_CODE_ORIGIN`, `TOKEN_URI_RESOLVER`, `GOVERNOR`, `CONTROLLER`, `REGISTRY`, `DEFIFA_PROJECT_ID`, `BASE_PROTOCOL_PROJECT_ID`, and `HOOK_STORE` are all fixed at construction (`DefifaDeployer.sol:300-328`). These dependencies share unified CREATE2 addresses / canonical project IDs across chains, so nothing chain-specific remains to wire post-deploy — no address can mutate them after deployment.

The owner cannot retro-edit any existing game's rulesets, splits, fee divisors, or tier configuration. The protocol-fee divisor (`BASE_PROTOCOL_FEE_DIVISOR = 40` ⇒ 2.5%) and Defifa-fee divisor (`DEFIFA_FEE_DIVISOR = 20` ⇒ 5%) are `constant` (`DefifaDeployer.sol:77, 81`).

## B.2 DefifaGovernor owner (singleton governor as DefifaHook owner)

- **`initializeGame(gameId, attestationStartTime, attestationGracePeriod, timelockDuration)`** — `onlyOwner` (the deployer, called from `launchGameWith`), one-time per game (`_packedScorecardInfoOf[gameId] != 0` reverts `AlreadyInitialized`). Enforces `attestationGracePeriod >= 1 day` and `uint48` bounds on each field (`DefifaGovernor.sol:484-538`).

The governor itself is the `owner` of every `DefifaHook` after launch (`DefifaDeployer.sol:628`). This means the governor — and only the governor — can call `DefifaHook.setTierCashOutWeightsTo`. The governor's `ratifyScorecardFrom` is the **only** path that exercises this owner power, and it requires `state == SUCCEEDED` (`DefifaGovernor.sol:220-229`). The governor's own `Ownable` `owner` is set at deploy; that owner has no further authority over individual games once `initializeGame` has been called.

## B.3 DefifaProjectOwner

- **Dead-end project NFT custodian.** If a project NFT is transferred to `DefifaProjectOwner`, `onERC721Received` (caller must equal `PROJECTS`) grants `SET_SPLIT_GROUPS` on that project to the `DEPLOYER`. There is no `transfer-out` function — the NFT is irrevocably stuck. Useful when a launcher wants to relinquish ownership while still letting the deployer manage splits. (`DefifaProjectOwner.sol:53-87`)

## B.4 Liveness guarantees

- **Phase progression doesn't require any privileged action.** Phase transitions are pure functions of `block.timestamp` and ruleset cycle number (`DefifaDeployer.sol:250-292`). Anyone can call `fulfillCommitmentsOf` (after `cashOutWeightIsSet`), `triggerNoContestFor` (when conditions match), or `mintReservesFor`.
- **Ratification triggers commitment fulfillment atomically.** `ratifyScorecardFrom` calls `IDefifaDeployer.fulfillCommitmentsOf(gameId)` after setting the cash-out weights, so the final ruleset is queued in the same tx that finalizes scoring (`DefifaGovernor.sol:231-233`). `fulfillCommitmentsOf` wraps `sendPayoutsOf` in try/catch and always queues the final ruleset (`DefifaDeployer.sol:356-372`).
- **`scorecardTimeout` backstop.** If no scorecard ratifies in time, the game transitions to NO_CONTEST via the view; `triggerNoContestFor` then queues the refund ruleset (`DefifaDeployer.sol:287-289`, `723-786`).

---

# Section C — Per-Contract Operation Inventory

## C.1 DefifaDeployer — `defifa/src/DefifaDeployer.sol`

Owns every game's project NFT (`PROJECTS.createFor(this)` in `launchGameWith`). Ownable but the owner surface is limited to the referral reference.

**Permissionless game launch:**

- **`launchGameWith(DefifaLaunchProjectData)` payable → gameId** — anyone. Forwards `msg.value` to `JBProjects.createFor` for the creation fee. Validates timing/tier/currency/timeout consistency; clones the Defifa hook via `cloneDeterministic` salted with `msg.sender || nonce`; queues MINT (optional REFUND) and SCORING rulesets via `controller.launchRulesetsFor`; calls `governor.initializeGame`; transfers hook ownership to the governor; registers the clone in the address registry. (`DefifaDeployer.sol:381-641`)
  - **Invariant:** game ID reserved before hook deployment so an interleaving `createFor` cannot invalidate the salt. Project NFT permanently held by this contract.

**Permissionless lifecycle triggers:**

- **`fulfillCommitmentsOf(uint256 gameId)`** — anyone after `cashOutWeightIsSet`. Single-shot (`commitmentsFulfilledFor` set before external calls). Pays `pot × commitmentPercent / SPLITS_TOTAL_PERCENT` via `sendPayoutsOf` with `referralProjectId` as the fee-volume credit; queues the final ruleset (no payouts, surplus = balance). Wraps payout in try/catch; if payout fails, fee stays in pot and `fulfilledCommitmentsOf` resets to 0. Final ruleset always queued. (`DefifaDeployer.sol:314-375`)
  - **Invariant:** caller cannot route the fee elsewhere; recipients are the user splits + Defifa project + base-protocol project, all baked in at launch. Pot accounting via `currentGamePotOf(includeCommitments=true)` stays consistent regardless of payout success.
- **`triggerNoContestFor(uint256 gameId)`** — anyone when `currentGamePhaseOf == NO_CONTEST` (i.e. participation failed or scorecard timeout elapsed). Single-shot via `noContestTriggeredFor`. Queues a `pausePay=true`, no-payout-limit, `cashOutTaxRate=0` ruleset that turns the entire balance into surplus, enabling refund cash-outs. (`DefifaDeployer.sol:723-786`)
  - **Invariant:** cannot be called when scorecard ratified (`cashOutWeightIsSet` ⇒ phase = COMPLETE, not NO_CONTEST); cannot be called twice; queued ruleset uses the current ruleset's `dataHook`/`baseCurrency`.

**Owner-only:**

- **`setReferralProjectId(newReferralProjectId, newReferralChainId)`** — `onlyOwner`. Lossless-pack-bounded; emits `SetReferralProjectId`. (`DefifaDeployer.sol:696-716`)

**Construction-time bindings:**

- All Defifa dependencies (hook origin, URI resolver, governor, controller, registry, fee project IDs, hook store) are constructor `immutable`s — there is no post-deploy setter to bind or rebind them. `referralProjectId` defaults to `(1 << 48) | DEFIFA_PROJECT_ID` at construction. (`DefifaDeployer.sol:300-328`)

**ERC-721 receipt:**

- **`onERC721Received(...)`** — accepts any 721 (returns selector). Used during `createFor` and to receive transferred game NFTs. (`DefifaDeployer.sol:644-646`)

**Views:** `currentGamePhaseOf`, `currentGamePotOf`, `nextPhaseNeedsQueueing`, `safetyParamsOf`, `timesFor`, `tokenOf`, `BASE_PROTOCOL_FEE_DIVISOR`, `DEFIFA_FEE_DIVISOR`, `SPLIT_GROUP`, `defifaProjectId`, `baseProtocolProjectId`, `hookCodeOrigin`, `tokenUriResolver`, `governor`, `controller`, `registry`, `hookStore`, `fulfilledCommitmentsOf`, `commitmentsFulfilledFor`, `noContestTriggeredFor`, `referralProjectId`.

## C.2 DefifaGovernor — `defifa/src/DefifaGovernor.sol`

Singleton. Owns every `DefifaHook` clone post-launch.

**Owner-only (one-shot per game):**

- **`initializeGame(gameId, attestationStartTime, attestationGracePeriod, timelockDuration)`** — `onlyOwner` (deployer, during `launchGameWith`). Reverts `AlreadyInitialized` on re-call; enforces `attestationGracePeriod >= MIN_ATTESTATION_GRACE_PERIOD (1 day)`; bounds each field to `uint48`. Packs into `_packedScorecardInfoOf[gameId]`. (`DefifaGovernor.sol:484-538`)

**Permissionless during SCORING:**

- **`submitScorecardFor(gameId, DefifaTierCashOutWeight[]) → scorecardId`** — anyone. Reverts if `ratifiedScorecardIdOf[gameId] != 0` or game not initialized or not in SCORING. Validates each weight via `DefifaHookLib.validateAndBuildWeights` (same validation the hook applies at ratification); ensures any `cashOutWeight > 0` tier has live ownership. Snapshots pending reserves and minted attestation units per tier (BWA denominator stability). Computes concentration-adjusted quorum (`baseQuorum + headroom × maxShare² / totalCashOutWeight`). Same hash twice reverts `DuplicateScorecard`. (`DefifaGovernor.sol:276-435`)
- **`attestToScorecardFrom(gameId, scorecardId) → weight`** — anyone with BWA power > 0 during ACTIVE/SUCCEEDED/QUEUED. Reads voting power at `attestationsBegin - 1`. Zero-power callers revert `NotAllowed` (prevents zero-weight repeat). Records when quorum is first reached. (`DefifaGovernor.sol:135-191`)
- **`revokeAttestationFrom(gameId, scorecardId)`** — prior attester only, ACTIVE state only. Decrements `attestations.count`; resets `_quorumReachedAtOf` if count drops below quorum. (`DefifaGovernor.sol:243-270`)
- **`ratifyScorecardFrom(gameId, DefifaTierCashOutWeight[]) → scorecardId`** — anyone once `state == SUCCEEDED`. Reverts if already ratified. Stores `ratifiedScorecardIdOf`, low-level-calls `metadata.dataHook.setTierCashOutWeightsTo(tierWeights)` (the governor is the hook's owner), then calls `IDefifaDeployer.fulfillCommitmentsOf(gameId)`. (`DefifaGovernor.sol:197-236`)
  - **Invariant:** ratification and commitment fulfillment are atomic; cash-out weights set exactly once per game.

**Views:** `attestationCountOf`, `hasAttestedTo`, `scorecardIdOf`, `attestationGracePeriodOf`, `attestationStartTimeOf`, `getAttestationWeight`, `getBWAAttestationWeight`, `quorum`, `stateOf` (PENDING → ACTIVE → QUEUED/SUCCEEDED → RATIFIED/DEFEATED), `timelockDurationOf`, `MAX_ATTESTATION_POWER_TIER`, `MIN_ATTESTATION_GRACE_PERIOD`, `CONTROLLER`, `defaultAttestationDelegateProposalOf`, `ratifiedScorecardIdOf`.

## C.3 DefifaHook — `defifa/src/DefifaHook.sol`

Per-game clone, extends `JB721Hook`. Ownable; the deployer transfers ownership to the governor immediately after `initialize`.

**Clone-factory one-shot:**

- **`initialize(...)`** — anyone, exactly once per clone. Reverts on the code origin or when `store` already set. Records tiers via `_store.recordAddTiers`; stores per-tier names; sets `pricingCurrency`, `gamePhaseReporter`, `gamePotReporter`, `defaultAttestationDelegate`; transfers ownership back to `msg.sender` (the deployer). (`DefifaHook.sol:498-563`)

**Governor-only (during SCORING, single-shot):**

- **`setTierCashOutWeightsTo(DefifaTierCashOutWeight[])`** — `onlyOwner` (governor). Reverts if `gamePhase != SCORING` or `cashOutWeightIsSet`. Validates and stores `_tierCashOutWeights`; sets `cashOutWeightIsSet = true`. (`DefifaHook.sol:784-805`)
  - **Invariant:** exactly one weight assignment per game; flips the phase view to COMPLETE.

**Permissionless (gated by phase):**

- **`mintReservesFor(uint256 tierId, uint256 count)`** — anyone, but blocked when `mintPendingReservesPaused` (set during MINT/REFUND) or `gamePhase == NO_CONTEST`. Caps `count` at `adjustedPendingReservesFor(tierId)`. Mints to the tier's reserve beneficiary; flags `isReserveMint[tokenId] = true`; increments `totalMintCost` by `tier.price * count`; auto-delegates reserve units. (`DefifaHook.sol:568-644`)
  - **Invariant:** cannot inflate participation past `minParticipation` after the game has failed (NO_CONTEST gate); cannot mint more than the tier's reserve frequency entitles.
- **`mintReservesFor(JB721TiersMintReservesConfig[])`** — batch variant. (`DefifaHook.sol:764-779`)

**Holder-only (MINT-phase-gated):**

- **`setTierDelegateTo(address delegatee, uint256 tierId)`** — caller (delegating own units). Reverts outside MINT. Zero-address delegate reverts. (`DefifaHook.sol:810-822`)
- **`setTierDelegatesTo(DefifaDelegation[])`** — batch variant; same phase + non-zero checks per entry. (`DefifaHook.sol:826-853`)
  - **Invariant:** voting power locked before scoring starts.

**Terminal-only callbacks:**

- **`afterPayRecordedWith(JBAfterPayRecordedContext) payable`** — only project terminal; reverts on `msg.value != 0` or wrong context. Decodes `(attestationDelegate, tierIdsToMint)` from metadata; mints via `_mintAll`; reverts `Overspending` on leftover. Third-party payer cannot overwrite the beneficiary's existing tier delegate via metadata (only payer=beneficiary may rewire). (`DefifaHook.sol:459-477, 1010-1080`)
- **`afterCashOutRecordedWith(JBAfterCashOutRecordedContext) payable`** — only project terminal; verifies caller-supplied token IDs all belong to `context.holder`; burns each; tracks per-tier `tokensRedeemedFrom` (COMPLETE) or `refundedBurnsFrom` (REFUND/NO_CONTEST); decrements `totalMintCost`. Reverts `NothingToClaim` if reclaim is 0 AND no fee tokens distributed. (`DefifaHook.sol:654-760`)
- **`beforeCashOutRecordedWith(JBBeforeCashOutRecordedContext) view`** — `IJBRulesetDataHook`. Reverts if fungible tokens are being cashed out (NFTs only). Computes `cumulativeMintPrice` (excluding reserve mints in non-COMPLETE phases); returns this contract as the cash-out hook with the encoded cumulative mint price; uses surplus as totalSupply / effectiveSurplusValue. (`DefifaHook.sol:275-338`)

**Views:** `firstOwnerOf`, `getPastTierAttestationUnitsOf`, `getPastTierTotalAttestationUnitsOf`, `getTierAttestationUnitsOf`, `getTierDelegateOf`, `getTierTotalAttestationUnitsOf`, `tierCashOutWeights`, `tierNameOf`, `cashOutWeightOf` (single + batch), `currentSupplyOfTier`, `adjustedPendingReservesFor`, `supportsInterface`, `tokenURI`, `tokensClaimableFor`, `totalCashOutWeight`, `TOTAL_CASHOUT_WEIGHT`, `CODE_ORIGIN`, `DEFIFA_TOKEN`, `BASE_PROTOCOL_TOKEN`, `totalMintCost`, `amountRedeemed`, `baseURI`, `cashOutWeightIsSet`, `contractURI`, `defaultAttestationDelegate`, `gamePhaseReporter`, `gamePotReporter`, `isReserveMint`, `pricingCurrency`, `refundedBurnsFrom`, `rulesets`, `store`, `tokensRedeemedFrom`.

## C.4 DefifaProjectOwner — `defifa/src/DefifaProjectOwner.sol`

Dead-end JBProjects NFT custodian. No transfer-out path.

- **`onERC721Received(operator, from, tokenId, data) → selector`** — only `JBProjects`. On receipt, grants `SET_SPLIT_GROUPS` for that project ID to the `DEPLOYER` via `PERMISSIONS.setPermissionsFor`. (`DefifaProjectOwner.sol:53-87`)
  - **Invariant:** there is no transfer-out function — project ownership becomes permanent while the deployer can still rotate splits.

## C.5 DefifaTokenUriResolver — `defifa/src/DefifaTokenUriResolver.sol`

Pure rendering surface — no privileged surface that affects game outcome or fund flow. Resolves tier-specific token URIs via `DefifaFontImporter` SVG composition. Reads from the hook's store + tier names; does not write any state that affects accounting.

---

# Section D — Cross-Cutting Invariants

1. **Frozen game configuration.** Once `launchGameWith` returns, the per-game tier prices, reserve frequencies, fees, scorecard timeouts, and ruleset cadence (MINT → REFUND? → SCORING → COMPLETE/NO_CONTEST) are immutable. The deployer owner's `setReferralProjectId` does not retro-edit any existing game's payouts; it only changes which project ID is credited for fee-volume on **future** `fulfillCommitmentsOf` calls.
2. **Single ratification per game.** `DefifaGovernor.ratifiedScorecardIdOf[gameId] != 0` blocks further submissions and ratifications (`DefifaGovernor.sol:206, 285`). `DefifaHook.cashOutWeightIsSet` blocks repeated `setTierCashOutWeightsTo` (`DefifaHook.sol:795`).
3. **Single commitment fulfillment per game.** `commitmentsFulfilledFor[gameId]` is set before any external call (`DefifaDeployer.sol:317`); re-entry returns early.
4. **Single NO_CONTEST trigger per game.** `noContestTriggeredFor[gameId]` set before queuing the refund ruleset; `NoContestAlreadyTriggered` on second call (`DefifaDeployer.sol:731, 738`).
5. **Reserve mints blocked in NO_CONTEST.** Prevents reviving a failed `minParticipation` game by free-minting reserved face value (`DefifaHook.sol:577-579`).
6. **Delegate changes restricted to MINT.** Locks voting power before scoring opens (`DefifaHook.sol:817-819, 830-832`).
7. **BWA snapshot one second before attestations open.** Blocks same-block transfer-and-attest sandwich (`DefifaGovernor.sol:167-171`).
8. **Beneficiaries cannot self-attest at full power.** BWA reduces tier power by `tierWeight / totalCashOutWeight`; zero-power attestations revert (`DefifaGovernor.sol:705-709, 175-177`).
9. **Revocation disabled once QUEUED.** Kills attest/revoke griefing (`DefifaGovernor.sol:243-247`).
10. **Atomic ratification + commitment.** `ratifyScorecardFrom` calls `fulfillCommitmentsOf` in the same tx, ensuring the COMPLETE ruleset is always queued after weights are set (`DefifaGovernor.sol:231-233`).
11. **State-before-external-call ordering.** `commitmentsFulfilledFor`, `noContestTriggeredFor`, `ratifiedScorecardIdOf`, and `cashOutWeightIsSet` are all written BEFORE the external call that consumes them — re-entrancy cannot replay the action.
12. **Permissionless settlement triggers extract no value beyond canonical allocation.** `fulfillCommitmentsOf`, `triggerNoContestFor`, `mintReservesFor`, `submitScorecardFor`, `attestToScorecardFrom`, `ratifyScorecardFrom` — caller's reward is exactly the gas-funded service to the game, never a redirected payout.
13. **One-shot bindings.** `DefifaHook.initialize`, `DefifaHook.setTierCashOutWeightsTo`, `DefifaGovernor.initializeGame` — all irreversible. `DefifaDeployer`'s own dependencies are constructor `immutable`s (no setter at all).
14. **Front-run-resistant clone deployment.** `cloneDeterministic` salt includes `msg.sender`; a different caller produces a different address (`DefifaDeployer.sol:589`).
15. **Participation immune to balance inflation.** `minParticipation` checks `hook.totalMintCost`, not terminal balance — `addToBalanceOf` donations cannot satisfy the threshold (`DefifaDeployer.sol:274-281`).
16. **NFT-only cash-out path.** `beforeCashOutRecordedWith` reverts if fungible project tokens are cashed out (`DefifaHook.sol:289`). The hook is the sole cash-out surface for Defifa games.

For the underlying parimutuel game mechanics, pot-formation math, fee pipeline, attacker economics on governance, and parameter design guidance, see **`CRYPTO_ECON.md`**.

---

# Section E — Out-of-Scope Centralization Caveats

These are NOT third-party attack vectors but are powers held by privileged addresses:

- **`DefifaDeployer` Ownable owner** can rotate `referralProjectId`. Worst case: future game commitments credit a different project ID for fee volume (the volume itself still flows to the configured fee projects via splits — only the indexer's "referrer" attribution is affected). No game's payouts redirected; no surplus mis-routed.
- **`DefifaDeployer` dependency wiring** (governor, controller, registry, fee project IDs, hook origin, URI resolver, hook store) is fixed at construction as `immutable`s — there is no privileged post-deploy setter. Misconfiguration would require deploying with wrong constructor args (wrong governor, wrong fee project IDs, etc.) — operationally caught by deploy script validation.
- **`DefifaGovernor` Ownable owner** can call `initializeGame`. In production deployment this owner is the `DefifaDeployer` (called during `launchGameWith`). If the governor's owner were ever rotated to a non-deployer address, that address could bootstrap rogue scorecards for games it didn't deploy — but only games whose hook ownership it also controls, which would require breaking `DefifaDeployer.launchGameWith`'s `hook.transferOwnership(governor)` flow.
- **`DefifaGovernor` as `DefifaHook` owner** is the **single ratifier** of every game's scorecard. The governor itself doesn't decide outcomes — it only enforces the BWA quorum + grace + timelock state machine. But the governor's *bytecode* is the source of truth for ratification rules; replacing the governor (via a controller-level migration or hook-ownership transfer) would change the rules. The deploy script intentionally leaves the governor in place and the hooks owned by it — there is no path in this codebase to rotate hook ownership away from the original governor.
- **`DefifaDeployer` as `JBProjects` NFT holder** is the sole `ownerMustSendPayouts` invoker during SCORING (the SCORING ruleset sets `ownerMustSendPayouts=true`). `fulfillCommitmentsOf` is the deployer's `sendPayoutsOf` invocation — and it's permissionless. No human address has owner power over a Defifa game's payouts post-launch.
- **`launchGameWith` caller** picks the `defaultAttestationDelegate`, `attestationStartTime`, `attestationGracePeriod`, `timelockDuration`, `minParticipation`, `scorecardTimeout`, splits, tier metadata, and reserve beneficiaries. Players opting into a game are trusting the launcher's parameters. The governor and hook enforce structural bounds (≥ 1-day grace period, ratification window must fit inside scorecard timeout, valid currency), but cannot detect launcher-chosen parameter combinations that economically disadvantage players (e.g. a launcher could allocate 100% of splits to themselves; the protocol's role is to make this fact verifiable on-chain at launch, not to prevent the launcher from offering it).

---

# Section F — Key Code References

- Phase view: `defifa/src/DefifaDeployer.sol:250-292`
- Game configuration validation: `defifa/src/DefifaDeployer.sol:417-478`
- Front-run-resistant clone deploy: `defifa/src/DefifaDeployer.sol:582-591`
- Project NFT custody: `defifa/src/DefifaDeployer.sol:481, 628`
- Commitment fulfillment single-shot: `defifa/src/DefifaDeployer.sol:314-375`
- NO_CONTEST trigger single-shot + ruleset queue: `defifa/src/DefifaDeployer.sol:723-786`
- Referral pack bounds: `defifa/src/DefifaDeployer.sol:696-716`
- Chain-specific one-shot: `defifa/src/DefifaDeployer.sol:658-686`
- Splits fee construction: `defifa/src/DefifaDeployer.sol:792-881`
- SCORING ruleset (`ownerMustSendPayouts=true`): `defifa/src/DefifaDeployer.sol:1008-1049`
- `minParticipation` check uses `totalMintCost`: `defifa/src/DefifaDeployer.sol:274-281`
- Governor `initializeGame` (grace period + uint48 bounds): `defifa/src/DefifaGovernor.sol:484-538`
- BWA snapshot at `attestationsBegin - 1`: `defifa/src/DefifaGovernor.sol:167-171`
- BWA self-attest guard (zero-power revert): `defifa/src/DefifaGovernor.sol:175-177`
- BWA tier-weight reduction: `defifa/src/DefifaGovernor.sol:705-709`
- Revocation gated to ACTIVE: `defifa/src/DefifaGovernor.sol:243-247`
- Single ratification per game: `defifa/src/DefifaGovernor.sol:206-208, 285-287`
- Concentration-adjusted quorum: `defifa/src/DefifaGovernor.sol:387-418`
- Atomic ratify + fulfillCommitments: `defifa/src/DefifaGovernor.sol:231-233`
- Submission rejects unrealizable weights: `defifa/src/DefifaGovernor.sol:306-311`
- Hook `setTierCashOutWeightsTo` (governor-only, SCORING-only, single-shot): `defifa/src/DefifaHook.sol:784-805`
- Hook `initialize` one-shot: `defifa/src/DefifaHook.sol:498-563`
- Reserve mints blocked in NO_CONTEST: `defifa/src/DefifaHook.sol:577-579`
- Reserve mint cap: `defifa/src/DefifaHook.sol:603-604`
- Delegate changes MINT-only: `defifa/src/DefifaHook.sol:817-819, 830-832`
- Hook cash-out path NFTs-only: `defifa/src/DefifaHook.sol:289`
- Hook 0-weight tier `NothingToClaim` guard: `defifa/src/DefifaHook.sol:752-756`
- Hook overspend guard: `defifa/src/DefifaHook.sol:1075-1079`
- Hook currency-lock guard: `defifa/src/DefifaHook.sol:1014-1018`
- Hook payer ≠ beneficiary delegate guard: `defifa/src/DefifaHook.sol:1056-1061`
- DefifaProjectOwner dead-end + permission grant: `defifa/src/DefifaProjectOwner.sol:53-87`

For the game's economic model and rational-actor analysis, see `CRYPTO_ECON.md`.
