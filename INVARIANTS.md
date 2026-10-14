# Invariants of Defifa

Scope: the Defifa game protocol (`@ballkidz/defifa`) — `DefifaDeployer`, `DefifaGovernor`, `DefifaHook`, `Defifa1155Hook`, `DefifaTiersHookStore`, and `DefifaTokenUriResolver`. Each Defifa game is a standalone Juicebox V6 project owned by a `DefifaDeployer`, with a per-game hook clone owned by that deployer's `DefifaGovernor`.

Two game types ship side by side. The ERC-721 game uses `DefifaHook` (one NFT per position). The ERC-1155 game uses `Defifa1155Hook` (one balance per tier; paid ID = tier ID, reserve ID = `tierId + RESERVE_TOKEN_ID_OFFSET`). Each game type has its own `DefifaDeployer` plus `DefifaGovernor` pair running the same code; both pairs share one `DefifaTiersHookStore` and one `DefifaTokenUriResolver`. Unless an invariant names one hook, it holds for both, and hook citations list `DefifaHook.sol` first and `Defifa1155Hook.sol` second.

For the cryptoeconomic model (pot formation, prize distribution formula, fee pipeline, parimutuel game theory, parameter design), see `CRYPTO_ECON.md`. This document covers only the **structural / authorization / lifecycle invariants** of the contracts.

| Phase | Source of truth | What's allowed |
|-------|-----------------|----------------|
| COUNTDOWN | `currentRuleset.cycleNumber == 0` | nothing yet — ruleset hasn't started |
| MINT | `cycleNumber == 1` | `pay` mints tier NFTs (ERC-721) or tier positions (ERC-1155 balances) at `tierPrice`; cash-outs at mint price; delegate changes |
| REFUND | `cycleNumber == 2 && refundPeriodDuration != 0` | `pausePay=true`, cash-outs at mint price |
| SCORING | `cycleNumber >= 2/3` and not NO_CONTEST/COMPLETE | scorecard submission + attestation + ratification |
| COMPLETE | `cashOutWeightIsSet == true` on hook | weighted reclaim by ratified tier weights |
| NO_CONTEST | `noContestTriggeredFor[gameId]` OR `totalMintCost < minParticipation` OR `block.timestamp > scoringStart + scorecardTimeout` (latched via `triggerNoContestFor`) | full refund at mint price after `triggerNoContestFor` queues the refund ruleset |

NO_CONTEST is reported by the view as soon as the condition is met; the on-chain ruleset only flips when `triggerNoContestFor` is called. The view-vs-state gap is the documented reason holders should check the active ruleset before cashing out (`DefifaDeployer.sol:277-319`, `DefifaDeployer.sol:664-727`).

---

## Section A — Guarantees to users

### A.1 Players (paying / cashing out)

- **MINT phase issuance.** A `pay()` during MINT charges `tierPrice` per position (uniform across tiers so attestation power is equal). The ERC-721 game mints one NFT per tier ID in the metadata-encoded `(attestationDelegate, uint16[] tierIdsToMint)`, tier IDs non-decreasing (`DefifaHook_BadTierOrder`, `DefifaHookLib.sol:140-187`). The ERC-1155 game mints `counts[i]` positions of each tier in the metadata-encoded `(attestationDelegate, uint16[] tierIds, uint256[] counts)` as one balance per tier (token ID = tier ID); tier IDs must be strictly ascending (`DefifaHook_BadTierOrder`), counts non-zero (`Defifa1155Hook_ZeroAmount`), and lengths equal (`Defifa1155Hook_LengthMismatch`) (`Defifa1155HookLib.sol:79-106`). Overspending (`leftoverAmount != 0`) reverts with `DefifaHook_Overspending` / `Defifa1155Hook_Overspending` — payer cannot accidentally over-fund. (`DefifaHook.sol:1107`, `Defifa1155Hook.sol:1130`)
- **Currency lock-in.** Payment currency must equal the `pricingCurrency` baked into the hook at `initialize`; mismatched currency reverts `DefifaHook_WrongCurrency` / `Defifa1155Hook_WrongCurrency`. (`DefifaHook.sol:1042-1046`, `Defifa1155Hook.sol:1059-1063`)
- **No mints outside MINT.** All non-MINT rulesets carry `pausePay=true` (`DefifaDeployer.sol:696`, `DefifaDeployer.sol:902`, `DefifaDeployer.sol:961`, `DefifaDeployer.sol:1017`). REFUND, SCORING, COMPLETE, and NO_CONTEST refund cycles all reject `pay`.
- **REFUND-phase reclaim.** During REFUND, surplus equals balance (no payout limits), so cash-out at the prevailing cash-out tax (0% for non-COMPLETE phases per `setTierCashOutWeightsTo` gating) returns each holder their proportional share of the pot — effectively the mint price for paid positions. Reserve-minted positions cannot be refunded: a MINT/REFUND/NO_CONTEST cash-out that includes one reverts (`DefifaHook_CantRefundReserveMint` / `Defifa1155Hook_CantRefundReserveMint`), including after transfer, so its notional cost never stays in `totalMintCost` or counts as a refunded burn. Reserves exist only from SCORING on, so in practice this applies in NO_CONTEST. ERC-721 reserve NFTs are flagged `isReserveMint` (`DefifaHook.sol:334-341`, `DefifaHookLib.sol:348-350`); ERC-1155 reserve positions live under token ID `tierId + RESERVE_TOKEN_ID_OFFSET` (`Defifa1155Hook.sol:378-385`, `Defifa1155HookLib.sol:195-197`).
- **NO_CONTEST refund.** Once `triggerNoContestFor` runs, the queued ruleset has no payout limits and `cashOutTaxRate=0`, enabling cash-out at mint price. Anyone can trigger this — players are not at the mercy of the deployer. (`DefifaDeployer.sol:664-727`)
- **COMPLETE-phase weighted reclaim.** After scorecard ratification, the hook's `beforeCashOutRecordedWith` substitutes the ratified per-tier `cashOutWeight` for raw token count, so winning tiers reclaim more pot per position than losers. Total reclaim is bounded by `TOTAL_CASHOUT_WEIGHT = 1e18` for accounting precision (`DefifaHook.sol:94, 348-355`, `Defifa1155Hook.sol:115, 393-399`).
- **Cash-out burns the positions.** The ERC-721 hook's `afterCashOutRecordedWith` requires `context.holder` to own each token ID, burns it, and decrements `totalMintCost` (`DefifaHook.sol:724-753, 787`). The ERC-1155 hook checks the holder's balance for each `(tokenId, amount)`, burns them with `_burnBatch`, records the burns in the store, and decrements `totalMintCost` (`Defifa1155Hook.sol:757-780, 811`).
- **0-weight-tier protection against accidental burns.** Positions whose tier received 0 cash-out weight (losing teams) revert with `DefifaHook_NothingToClaim` / `Defifa1155Hook_NothingToClaim` if neither reclaim nor fee tokens would be distributed — protecting holders from burning for nothing. (`DefifaHook.sol:780-784`, `Defifa1155Hook.sol:804-808`)
- **Fee-token (`$DEFIFA`/`$BASE_PROTOCOL`) claims.** On COMPLETE-phase cash-out, holders also receive their pro-rata share of the fee-project tokens delivered to the hook during `fulfillCommitmentsOf`. Share = `cumulativeMintPrice / (totalMintCost + pendingReserveMintCost)`. Reserves are accounted in the denominator so paid holders cannot claim a disproportionate share before reserves mint. Both hooks compute the share with `DefifaHookLib.tokensClaimFor` (`DefifaHookLib.sol:68-84`). (`DefifaHook.sol:769-773`, `Defifa1155Hook.sol:793-797`)
- **Reserve mints are permissionless and capped.** `mintReservesFor` mints to the pre-configured reserve beneficiary only, capped at `adjustedPendingReservesFor(tier)`. No caller can mint more than the tier's reserve frequency entitles. (`DefifaHook.sol:616-617`, `Defifa1155Hook.sol:670-671`)
- **Empty reserve mints write no delegation.** `mintReservesFor` returns before any delegation write when the capped count is 0 or the tier has no reserve beneficiary, and mints and burns never read or write the zero address's tier delegate. A reserve-mint call with nothing to mint therefore cannot set `_tierDelegation[address(0)]`, which later pays would otherwise charge as the source delegate and revert. (`DefifaHook.sol:621, 1147, 1156`, `Defifa1155Hook.sol:675, 1170, 1179`)
- **Game configuration sanity.** `launchGameWith` reverts if start/mint/refund durations are inconsistent, if `tiers.length > 128`, if `scorecardTimeout == 0`, if ERC-20 games supply `currency=0`, or if `scorecardTimeout` is too short to ever allow ratification (`attestationDelay + gracePeriod + timelock`). (`DefifaDeployer.sol:435-522`)
- **Frozen tier price.** All tiers launch with the same `tierPrice`, `discountPercent=0`, `cantIncreaseDiscountPercent=true`, `cantBeRemoved=true`, `allowOwnerMint=false`. Operator cannot drop in cheap tiers post-launch or admin-mint into a winning tier. (`DefifaDeployer.sol:561-582`)

### A.2 Attesters (governance participants)

- **BWA snapshot one second before submission.** Voting power is read at `scorecard.snapshotTimestamp` = submission timestamp − 1. Checkpoints are `block.timestamp`-keyed and same-timestamp writes overwrite in place, so reading before the submission block excludes any mint or transfer that shares that block, in either order relative to submission — neither a post-submission `mintReservesFor` nor a same-block `transferFrom` / `safeTransferFrom` can grant or move attestation power for that scorecard. `attestationsBegin` is still advanced to the next timestamp so the attestation window opens in a later block than submission (`DefifaGovernor.sol` `attestToScorecardFrom` and `submitScorecardFor`).
- **Benefit-Weighted Attestation (BWA) reduces beneficiary power.** Each tier's attestation power is scaled by `(totalCashOutWeight - tierWeight) / totalCashOutWeight`. A tier with 100% of the scorecard weight receives 0 attestation power on that scorecard — beneficiaries **cannot self-attest at full power** (`DefifaGovernor.sol:742-746`). Zero-power attestations revert (`DefifaGovernor.sol:195-199`).
- **Concentration-adjusted quorum.** Base quorum is 50% of `eligibleTierWeights × MAX_ATTESTATION_POWER_TIER`. When the scorecard concentrates weight on one tier, quorum is raised by `headroom × maxShare²`, but the penalty is capped so honest non-beneficiaries can always reach quorum (`DefifaGovernor.sol:424-455`).
- **Minimum grace period (1 day).** Enforced at `initializeGame`; prevents instant-ratification attacks (`DefifaGovernor.sol:74, 538-543`).
- **Timelock anchors to the later of grace-period end or quorum-reached time.** A late-arriving quorum still gets the full cooling period (`DefifaGovernor.sol:847-850`).
- **One attestation per (account, scorecard).** Re-attestation reverts `AlreadyAttested`. Revocation requires prior attestation (`DefifaGovernor.sol:183-186, 274-277`).
- **Revocation disabled once QUEUED.** Only `ACTIVE`-state attestations are revocable; this kills the attest/revoke griefing loop while still allowing course-correction during open debate. Quorum-reached timestamp resets to 0 if revocation drops the count below quorum (`DefifaGovernor.sol:265-292`).
- **Single ratification per game.** `ratifiedScorecardIdOf[gameId] != 0` reverts subsequent submissions and ratifications with `AlreadyRatified` (`DefifaGovernor.sol:227-230, 306-309`).
- **Duplicate-scorecard rejection.** `_scorecardOf[gameId][scorecardId].attestationsBegin != 0` ⇒ `DuplicateScorecard`. The scorecard ID is the keccak of `(hook, calldata)`, so the same weight vector cannot be re-submitted (`DefifaGovernor.sol:350-354`).
- **Submission rejects unrealizable weights.** A scorecard with `cashOutWeight > 0` for a tier with `currentSupplyOfTier == 0` reverts (`DefifaGovernor.sol:325-337`). Defends against scorecards that would route value to nobody.
- **Reserve-mint snapshots.** On submission, the governor snapshots each tier's pending reserves and minted-unit total. Because attestation reads at `snapshotTimestamp` (before the submission block), a reserve minted at or after submission gains no numerator. The minted-unit snapshot additionally clamps the denominator for reads at a later timestamp (e.g. delayed-attestation games, where the snapshot timestamp passed to the view is in the future relative to submission), and the snapshotted pending reserves are added back so unminted reserves dilute exactly once (`DefifaGovernor.sol` `getBWAAttestationWeight`).
- **Quorum eligibility includes pending reserves.** A tier with all paid tokens burned during REFUND but with pending reserves still contributes to quorum, so a burner cannot erase another participant's quorum contribution (`DefifaGovernor.sol:781-790`).

### A.3 Protections against external interference

- **No third-party can change cash-out weights.** `setTierCashOutWeightsTo` is `onlyOwner` (the governor) AND gated on `gamePhase == SCORING` AND single-shot (`cashOutWeightIsSet`). Even the governor can't re-score a game once set. (`DefifaHook.sol:812-833`, `Defifa1155Hook.sol:836-857`)
- **No third-party can re-route fee splits.** Splits are written by the deployer once during `_buildSplits` for the scoring ruleset and never changed (`DefifaDeployer.sol:733-822`). The deployer permanently holds the game's `JBProjects` NFT (`DefifaDeployer.sol:530-531`).
- **No third-party can mint admin pieces.** `allowOwnerMint=false` on every tier (`DefifaDeployer.sol:572`); the controller's `allowOwnerMinting=false` on every ruleset.
- **Reserve mints blocked in NO_CONTEST.** Prevents a malicious reserve mint from inflating `totalMintCost` past `minParticipation` after the game has already failed the participation check, which would otherwise revive the game from NO_CONTEST → SCORING (`DefifaHook.sol:604-606`, `Defifa1155Hook.sol:658-660`).
- **Delegate changes locked after MINT.** `setTierDelegateTo` / `setTierDelegatesTo` revert outside the MINT phase. This freezes voting power before scoring begins, so attestation can't be hot-swapped to a colluding delegate after scorecards drop (`DefifaHook.sol:845-847, 858-860`, `Defifa1155Hook.sol:869-871, 882-884`).
- **`addToBalanceOf` cannot inflate participation.** `minParticipation` is checked against `totalMintCost` (incremented only by paid mints and reserve mints), not terminal balance — donations to the terminal cannot artificially satisfy the participation threshold (`DefifaDeployer.sol:301-308`).
- **Front-run-resistant hook clone.** `cloneDeterministic` salts on `keccak256(_msgSender(), nonce)` so a different resolved caller produces a different address; a watcher cannot front-run `launchGameWith` to deploy a hook at the predicted address and DoS initialization. For trusted-forwarder calls, `_msgSender()` is the ERC-2771 signer, not the forwarder (`DefifaDeployer.sol:595-604`).
- **Commitment fulfillment is single-shot.** `commitmentsFulfilledFor[gameId]` set BEFORE external calls; a re-entrant call returns early (`DefifaDeployer.sol:367-369`).
- **NO_CONTEST trigger is single-shot.** `noContestTriggeredFor[gameId]` set BEFORE queuing the refund ruleset; a re-entrant call reverts `NoContestAlreadyTriggered` (`DefifaDeployer.sol:671-679`).

---

## Section B — Guarantees to owners

### B.1 DefifaDeployer bindings

- **Dependency bindings are constructor `immutable`s, not a runtime setter.** `HOOK_CODE_ORIGIN`, `TOKEN_URI_RESOLVER`, `GOVERNOR`, `CONTROLLER`, `REGISTRY`, `DEFIFA_PROJECT_ID`, `BASE_PROTOCOL_PROJECT_ID`, `HOOK_STORE`, and the ERC-2771 `trustedForwarder` are all fixed at construction (`DefifaDeployer.sol:334-358`). These dependencies share unified CREATE2 addresses / canonical project IDs across chains, so nothing chain-specific remains to wire post-deploy — no address can mutate them after deployment.

No caller can retro-edit any existing game's rulesets, splits, fee divisors, or tier configuration. The protocol-fee divisor (`BASE_PROTOCOL_FEE_DIVISOR = 40` ⇒ 2.5%) and Defifa-fee divisor (`DEFIFA_FEE_DIVISOR = 20` ⇒ 5%) are `constant` (`DefifaDeployer.sol:98, 102`).

### B.2 DefifaGovernor owner (governor as game-hook owner)

- **`initializeGame(gameId, attestationStartTime, attestationGracePeriod, timelockDuration)`** — `onlyOwner` (the deployer, called from `launchGameWith`), one-time per game (`_packedScorecardInfoOf[gameId] != 0` reverts `AlreadyInitialized`). Enforces `attestationGracePeriod >= 1 day` and `uint48` bounds on each field (`DefifaGovernor.sol:521-575`).

The governor itself is the `owner` of every hook its deployer launches (`DefifaDeployer.sol:640-641`). This means the governor — and only the governor — can call `setTierCashOutWeightsTo` on those hooks. The governor's `ratifyScorecardFrom` is the **only** path that exercises this owner power, and it requires `state == SUCCEEDED` (`DefifaGovernor.sol:241-244`). The governor's own `Ownable` `owner` is set at deploy; that owner has no further authority over individual games once `initializeGame` has been called.

### B.3 Liveness guarantees

- **Phase progression doesn't require any privileged action.** Phase transitions are pure functions of `block.timestamp` and ruleset cycle number (`DefifaDeployer.sol:277-319`). Anyone can call `fulfillCommitmentsOf` (after `cashOutWeightIsSet`), `triggerNoContestFor` (when conditions match), or `mintReservesFor`.
- **Ratification triggers commitment fulfillment atomically.** `ratifyScorecardFrom` calls `IDefifaDeployer.fulfillCommitmentsOf(gameId)` after setting the cash-out weights, so the final ruleset is queued in the same tx that finalizes scoring (`DefifaGovernor.sol:253-255`). `fulfillCommitmentsOf` wraps `sendPayoutsOf` in try/catch and always queues the final ruleset (`DefifaDeployer.sol:401-416`).
- **`scorecardTimeout` backstop.** If no scorecard ratifies in time, the game transitions to NO_CONTEST via the view; `triggerNoContestFor` then queues the refund ruleset (`DefifaDeployer.sol:310-316`, `DefifaDeployer.sol:664-727`).

---

## Section C — Per-contract operation inventory

### C.1 DefifaDeployer — `defifa/src/DefifaDeployer.sol`

Owns every game's project NFT (`PROJECTS.createFor(this)` in `launchGameWith`). Hook-agnostic: one deployment per game type, each with its own `HOOK_CODE_ORIGIN` (`DefifaHook` or `Defifa1155Hook`) and governor. It calls the hook only through selectors both hooks expose (`test/DefifaHookParity.t.sol`).

**Permissionless game launch:**

- **`launchGameWith(DefifaLaunchProjectData)` payable → gameId** — anyone, including through the configured ERC-2771 trusted forwarder. Forwards `msg.value` to `JBProjects.createFor` for the creation fee and advertises the resolved `_msgSender()` as `originalPayer` while `createFor` runs. Validates timing/tier/currency/timeout consistency; clones the Defifa hook via `cloneDeterministic` salted with `_msgSender() || nonce`; queues MINT (optional REFUND) and SCORING rulesets via `controller.launchRulesetsFor`; calls `governor.initializeGame`; transfers hook ownership to the governor; registers the clone in the address registry. (`DefifaDeployer.sol:425-652`)
  - **Invariant:** game ID reserved before hook deployment so an interleaving `createFor` cannot invalidate the salt. Project NFT permanently held by this contract.

**Permissionless lifecycle triggers:**

- **`fulfillCommitmentsOf(uint256 gameId)`** — anyone after `cashOutWeightIsSet`. Single-shot (`commitmentsFulfilledFor` set before external calls). Pays `pot × commitmentPercent / SPLITS_TOTAL_PERCENT` via `sendPayoutsOf`; queues the final ruleset (no payouts, surplus = balance). Wraps payout in try/catch; if payout fails, fee stays in pot and `fulfilledCommitmentsOf` resets to 0. Final ruleset always queued. (`DefifaDeployer.sol:366-419`)
  - **Invariant:** caller cannot route the fee elsewhere; recipients are the user splits + Defifa project + base-protocol project, all baked in at launch. Pot accounting via `currentGamePotOf(includeCommitments=true)` stays consistent regardless of payout success.
- **`triggerNoContestFor(uint256 gameId)`** — anyone when `currentGamePhaseOf == NO_CONTEST` (i.e. participation failed or scorecard timeout elapsed). Single-shot via `noContestTriggeredFor`. Queues a `pausePay=true`, no-payout-limit, `cashOutTaxRate=0` ruleset that turns the entire balance into surplus, enabling refund cash-outs. (`DefifaDeployer.sol:664-727`)
  - **Invariant:** cannot be called when scorecard ratified (`cashOutWeightIsSet` ⇒ phase = COMPLETE, not NO_CONTEST); cannot be called twice; queued ruleset uses the current ruleset's `dataHook`/`baseCurrency`.

**Construction-time bindings:**

- All Defifa dependencies (hook origin, URI resolver, governor, controller, registry, fee project IDs, hook store, and trusted forwarder) are constructor `immutable`s — there is no post-deploy setter to bind or rebind them. (`DefifaDeployer.sol:334-358`)

**ERC-721 receipt:**

- **`onERC721Received(...)`** — accepts any 721 (returns selector). Used during `createFor` to receive the game's `JBProjects` NFT. (`DefifaDeployer.sol:655-657`)

**Views:** `currentGamePhaseOf`, `currentGamePotOf`, `nextPhaseNeedsQueueing`, `safetyParamsOf`, `timesFor`, `tokenOf`, `BASE_PROTOCOL_FEE_DIVISOR`, `DEFIFA_FEE_DIVISOR`, `defifaProjectId`, `baseProtocolProjectId`, `hookCodeOrigin`, `tokenUriResolver`, `governor`, `controller`, `registry`, `hookStore`, `fulfilledCommitmentsOf`, `commitmentsFulfilledFor`, `noContestTriggeredFor`.

### C.2 DefifaGovernor — `defifa/src/DefifaGovernor.sol`

One per deployer, so one per game type. Owns every hook clone its deployer launches. Hook-agnostic: it calls the hook only through selectors both hooks expose (`test/DefifaHookParity.t.sol`).

**Owner-only (one-shot per game):**

- **`initializeGame(gameId, attestationStartTime, attestationGracePeriod, timelockDuration)`** — `onlyOwner` (deployer, during `launchGameWith`). Reverts `AlreadyInitialized` on re-call; enforces `attestationGracePeriod >= MIN_ATTESTATION_GRACE_PERIOD (1 day)`; bounds each field to `uint48`. Packs into `_packedScorecardInfoOf[gameId]`. (`DefifaGovernor.sol:521-575`)

**Permissionless during SCORING:**

- **`submitScorecardFor(gameId, DefifaTierCashOutWeight[]) → scorecardId`** — anyone. Reverts if `ratifiedScorecardIdOf[gameId] != 0` or game not initialized or not in SCORING. Validates each weight via `DefifaHookLib.validateAndBuildWeights` (same validation the hook applies at ratification); ensures any `cashOutWeight > 0` tier has live ownership. Snapshots pending reserves and minted attestation units per tier (BWA denominator stability). Computes concentration-adjusted quorum (`baseQuorum + headroom × maxShare² / totalCashOutWeight`). Same hash twice reverts `DuplicateScorecard`. (`DefifaGovernor.sol:298-472`)
- **`attestToScorecardFrom(gameId, scorecardId) → weight`** — anyone with BWA power > 0 during ACTIVE/SUCCEEDED/QUEUED. Reads voting power at `scorecard.snapshotTimestamp` (one second before submission). Zero-power callers revert `NotAllowed` (prevents zero-weight repeat). Records when quorum is first reached. (`DefifaGovernor.sol` `attestToScorecardFrom`)
- **`revokeAttestationFrom(gameId, scorecardId)`** — prior attester only, ACTIVE state only. Decrements `attestations.count`; resets `_quorumReachedAtOf` if count drops below quorum. (`DefifaGovernor.sol:265-292`)
- **`ratifyScorecardFrom(gameId, DefifaTierCashOutWeight[]) → scorecardId`** — anyone once `state == SUCCEEDED`. Reverts if already ratified. Stores `ratifiedScorecardIdOf`, low-level-calls `metadata.dataHook.setTierCashOutWeightsTo(tierWeights)` (the governor is the hook's owner), then calls `IDefifaDeployer.fulfillCommitmentsOf(gameId)`. (`DefifaGovernor.sol:219-258`)
  - **Invariant:** ratification and commitment fulfillment are atomic; cash-out weights set exactly once per game.

**Views:** `attestationCountOf`, `hasAttestedTo`, `scorecardIdOf`, `attestationGracePeriodOf`, `attestationStartTimeOf`, `getAttestationWeight`, `getBWAAttestationWeight`, `quorum`, `stateOf` (PENDING → ACTIVE → QUEUED/SUCCEEDED → RATIFIED/DEFEATED), `timelockDurationOf`, `MAX_ATTESTATION_POWER_TIER`, `MIN_ATTESTATION_GRACE_PERIOD`, `CONTROLLER`, `defaultAttestationDelegateProposalOf`, `ratifiedScorecardIdOf`.

### C.3 DefifaHook — `defifa/src/DefifaHook.sol` (ERC-721 game)

Per-game clone, extends `JB721Hook`; one NFT per position. Ownable; the deployer transfers ownership to the governor immediately after `initialize`.

**Clone-factory one-shot:**

- **`initialize(...)`** — anyone, exactly once per clone. Reverts on the code origin or when `store` already set. Records tiers via `_store.recordAddTiers`; stores per-tier names; sets `pricingCurrency`, `gamePhaseReporter`, `gamePotReporter`, `defaultAttestationDelegate`; transfers ownership back to `msg.sender` (the deployer). (`DefifaHook.sol:525-590`)

**Governor-only (during SCORING, single-shot):**

- **`setTierCashOutWeightsTo(DefifaTierCashOutWeight[])`** — `onlyOwner` (governor). Reverts if `gamePhase != SCORING` or `cashOutWeightIsSet`. Validates and stores `_tierCashOutWeights`; sets `cashOutWeightIsSet = true`. (`DefifaHook.sol:812-833`)
  - **Invariant:** exactly one weight assignment per game; flips the phase view to COMPLETE.

**Permissionless (gated by phase):**

- **`mintReservesFor(uint256 tierId, uint256 count)`** — anyone, but blocked when `mintPendingReservesPaused` (set during MINT/REFUND) or `gamePhase == NO_CONTEST`. Caps `count` at `adjustedPendingReservesFor(tierId)` and returns before any delegation write if the capped count is 0 or the tier has no reserve beneficiary. Mints to the tier's reserve beneficiary; flags `isReserveMint[tokenId] = true`; increments `totalMintCost` by `tier.price * count`; auto-delegates reserve units. (`DefifaHook.sol:595-672`)
  - **Invariant:** cannot inflate participation past `minParticipation` after the game has failed (NO_CONTEST gate); cannot mint more than the tier's reserve frequency entitles; never writes `_tierDelegation[address(0)]`.
- **`mintReservesFor(JB721TiersMintReservesConfig[])`** — batch variant. (`DefifaHook.sol:792-807`)

**Holder-only (MINT-phase-gated):**

- **`setTierDelegateTo(address delegatee, uint256 tierId)`** — caller (delegating own units). Reverts outside MINT. Zero-address delegate reverts. (`DefifaHook.sol:838-850`)
- **`setTierDelegatesTo(DefifaDelegation[])`** — batch variant; same phase + non-zero checks per entry. (`DefifaHook.sol:854-881`)
  - **Invariant:** voting power locked before scoring starts.

**Terminal-only callbacks:**

- **`afterPayRecordedWith(JBAfterPayRecordedContext) payable`** — only project terminal; reverts on `msg.value != 0` or wrong context. Decodes `(attestationDelegate, tierIdsToMint)` from metadata; mints via `_mintAll`; reverts `Overspending` on leftover. Third-party payer cannot overwrite the beneficiary's existing tier delegate via metadata (only payer=beneficiary may rewire). (`DefifaHook.sol:486-504, 1040-1108`)
- **`afterCashOutRecordedWith(JBAfterCashOutRecordedContext) payable`** — only project terminal; verifies caller-supplied token IDs all belong to `context.holder`; burns each; tracks per-tier `tokensRedeemedFrom` (COMPLETE) or `refundedBurnsFrom` (REFUND/NO_CONTEST); decrements `totalMintCost`. Reverts `NothingToClaim` if reclaim is 0 AND no fee tokens distributed. (`DefifaHook.sol:682-788`)
- **`beforeCashOutRecordedWith(JBBeforeCashOutRecordedContext) view`** — `IJBRulesetDataHook`. Reverts if fungible tokens are being cashed out (NFTs only). Computes `cumulativeMintPrice`, reverting `DefifaHook_CantRefundReserveMint` if a reserve mint is included in MINT/REFUND/NO_CONTEST; returns this contract as the cash-out hook with the encoded cumulative mint price; uses surplus as totalSupply / effectiveSurplusValue. (`DefifaHook.sol:302-365`)

**Transfers:** `_update` reverts `DefifaHook_TransfersPaused` on paused transfers (burns allowed), records the first owner, moves attestation units, and records the transfer in the store. Mints use `_mint`, which calls no receiver. (`DefifaHook.sol:1168-1202`, `DefifaHook.sol:657, 976`)

**Views:** `firstOwnerOf`, `getPastTierAttestationUnitsOf`, `getPastTierTotalAttestationUnitsOf`, `getTierAttestationUnitsOf`, `getTierDelegateOf`, `getTierTotalAttestationUnitsOf`, `tierCashOutWeights`, `tierNameOf`, `cashOutWeightOf` (single + batch), `currentSupplyOfTier`, `adjustedPendingReservesFor`, `supportsInterface`, `tokenURI`, `tokensClaimableFor`, `totalCashOutWeight`, `TOTAL_CASHOUT_WEIGHT`, `CODE_ORIGIN`, `DEFIFA_TOKEN`, `BASE_PROTOCOL_TOKEN`, `totalMintCost`, `amountRedeemed`, `baseURI`, `cashOutWeightIsSet`, `contractURI`, `defaultAttestationDelegate`, `gamePhaseReporter`, `gamePotReporter`, `isReserveMint`, `pricingCurrency`, `refundedBurnsFrom`, `rulesets`, `store`, `tokensRedeemedFrom`.

### C.4 Defifa1155Hook — `defifa/src/Defifa1155Hook.sol` (ERC-1155 game)

Per-game clone, an OpenZeppelin `ERC1155` game-piece hook (not `JB721Hook`/ERC-721) that implements the data, pay, and cash-out hook interfaces directly. Positions are balances: paid positions use token ID = tier ID, reserve-minted positions use `tierId + RESERVE_TOKEN_ID_OFFSET` (`1 << 16`), and `tierIdOf` maps either back (`Defifa1155HookLib.sol:37, 47-50`). Tier config, supply, reserve, burn, and per-tier holder accounting stay in `DefifaTiersHookStore`, called once per tier; attestation units are hook balances × `tier.votingUnits`. Mints run the ERC-1155 receiver acceptance check last, after every state change; transfers are standard safe transfers. Errors are prefixed `Defifa1155Hook_`; shared-rule errors from `DefifaHookLib` keep `DefifaHook_`. Ownable; the deployer transfers ownership to the governor immediately after `initialize`.

**Clone-factory one-shot:**

- **`initialize(...)`** — same rules as `DefifaHook.initialize`, with `_gameName` / `_gameSymbol` naming the collection. (`Defifa1155Hook.sol:577-644`)

**Governor-only (during SCORING, single-shot):**

- **`setTierCashOutWeightsTo(DefifaTierCashOutWeight[])`** — same rules as `DefifaHook`. (`Defifa1155Hook.sol:836-857`)
  - **Invariant:** exactly one weight assignment per game; flips the phase view to COMPLETE.

**Permissionless (gated by phase):**

- **`mintReservesFor(uint256 tierId, uint256 count)`** — same gates, cap, and early return as `DefifaHook`. Mints `count` positions of token ID `tierId + RESERVE_TOKEN_ID_OFFSET` to the tier's reserve beneficiary in one balance; increments `totalMintCost` by `tier.price * count`; auto-delegates reserve units; emits `MintReservedToken(tierId, beneficiary, count, caller)`. (`Defifa1155Hook.sol:649-716`)
  - **Invariant:** same as `DefifaHook`; reserve IDs stay distinct from paid IDs after transfer.
- **`mintReservesFor(JB721TiersMintReservesConfig[])`** — batch variant. (`Defifa1155Hook.sol:816-831`)

**Holder-only (MINT-phase-gated):**

- **`setTierDelegateTo` / `setTierDelegatesTo`** — same rules as `DefifaHook`. (`Defifa1155Hook.sol:862-874, 878-905`)

**Terminal-only callbacks:**

- **`afterPayRecordedWith(JBAfterPayRecordedContext) payable`** — only project terminal; reverts on `msg.value != 0` or wrong context. Decodes `(attestationDelegate, uint16[] tierIds, uint256[] counts)` from metadata; reverts `Defifa1155Hook_InvalidBeneficiary` for a zero beneficiary; records the counts in the store and mints one balance per tier via `_mintAll` (emitting `Mint(tierId, beneficiary, count, totalAmountContributed, caller)`); reverts `Overspending` on leftover. Same payer ≠ beneficiary delegate guard as `DefifaHook`. (`Defifa1155Hook.sol:527-540, 1057-1131`)
- **`afterCashOutRecordedWith(JBAfterCashOutRecordedContext) payable`** — only project terminal; decodes `(uint256[] tokenIds, uint256[] amounts)` and reverts `Defifa1155Hook_Unauthorized` if `context.holder`'s balance of any ID is below its amount; burns them in one `_burnBatch`; records per-tier burns and `tokensRedeemedFrom` (COMPLETE) or `refundedBurnsFrom` (REFUND/NO_CONTEST) through `Defifa1155HookLib.recordBurns`; decrements `totalMintCost`. Reverts `NothingToClaim` if reclaim is 0 AND no fee tokens distributed. (`Defifa1155Hook.sol:726-812`)
- **`beforeCashOutRecordedWith(JBBeforeCashOutRecordedContext) view`** — `IJBRulesetDataHook`. Reverts if fungible tokens are being cashed out (positions only). Computes `cumulativeMintPrice` from `(ids, amounts)`, reverting `Defifa1155Hook_CantRefundReserveMint` if a reserve ID is included in MINT/REFUND/NO_CONTEST; mismatched lengths revert `Defifa1155Hook_LengthMismatch`. Returns this contract as the cash-out hook; uses surplus as totalSupply / effectiveSurplusValue. (`Defifa1155Hook.sol:342-409`)

**Transfers:** `_update` skips zero-amount entries, reverts `Defifa1155Hook_TransfersPaused` on paused transfers (burns allowed), moves `tier.votingUnits × amount` attestation units for transfers and burns, and records every move, mints included, in the store with the count form of `recordTransferForTier`. Paid mints (`_mintAll`) and reserve mints (`mintReservesFor`, after attestation units move) both end with `_mintWithAcceptanceCheck`, which runs `_update` and then `Defifa1155HookLib.checkMintAcceptance` by delegatecall, so the hook stays the caller of `onERC1155Received` (one ID) or `onERC1155BatchReceived`. The receiver callback runs after every state change, and a contract beneficiary that rejects it reverts the mint. (`Defifa1155Hook.sol:1194-1246`, `Defifa1155Hook.sol:997, 1004-1007`, `Defifa1155HookLib.sol:61-71`)

**Views:** ERC-1155 `balanceOf`/`balanceOfBatch`/`isApprovedForAll`, `uri`, `name`, `symbol`, `tierIdOf`, `RESERVE_TOKEN_ID_OFFSET`, `METADATA_ID_TARGET`, `getPastTierAttestationUnitsOf`, `getPastTierTotalAttestationUnitsOf`, `getTierAttestationUnitsOf`, `getTierDelegateOf`, `getTierTotalAttestationUnitsOf`, `tierCashOutWeights`, `tierNameOf`, `cashOutWeightOf` (one ID, or `(ids, amounts)`), `currentSupplyOfTier`, `adjustedPendingReservesFor`, `supportsInterface`, `tokensClaimableFor(ids, amounts)`, `TOTAL_CASHOUT_WEIGHT`, `CODE_ORIGIN`, `DEFIFA_TOKEN`, `BASE_PROTOCOL_TOKEN`, `totalMintCost`, `amountRedeemed`, `baseURI`, `cashOutWeightIsSet`, `contractURI`, `defaultAttestationDelegate`, `gamePhaseReporter`, `gamePotReporter`, `pricingCurrency`, `projectId`, `refundedBurnsFrom`, `rulesets`, `store`, `tokensRedeemedFrom`.

### C.5 DefifaTiersHookStore — `defifa/src/DefifaTiersHookStore.sol`

`JB721TiersHookStore`, unchanged, plus count-based records. Shared by both game types; the ERC-1155 hook requires it. `recordMintCounts` (`DefifaTiersHookStore.sol:46-117`), `recordBurnCounts` (`DefifaTiersHookStore.sol:23-36`) and `recordTransferForTier(tierId, from, to, count)` (`DefifaTiersHookStore.sol:124-147`) apply the same checks and accounting as their per-position counterparts, once per tier, and act only on the calling hook's state (`msg.sender`-keyed, as upstream).

- **Invariant:** for any sequence of mints, burns and transfers, the count functions leave the same supply, reserve, burn, and per-holder tier state as the per-position originals (`test/DefifaTiersHookStore.t.sol`).

### C.6 DefifaTokenUriResolver — `defifa/src/DefifaTokenUriResolver.sol`

Pure rendering surface — no privileged surface that affects game outcome or fund flow. Resolves tier-specific token URIs via `DefifaFontImporter` SVG composition. Reads from the hook's store + tier names; does not write any state that affects accounting. Shared by both game types: it picks the tier by ERC-165, mapping an ERC-1155 hook's ID with `tierIdOf` and a 721 hook's token ID with `store.tierIdOfToken` (`DefifaTokenUriResolver.sol:125-131`).

---

## Section D — Cross-cutting invariants

1. **Frozen game configuration.** Once `launchGameWith` returns, the per-game tier prices, reserve frequencies, fees, scorecard timeouts, and ruleset cadence (MINT → REFUND? → SCORING → COMPLETE/NO_CONTEST) are immutable.
2. **Single ratification per game.** `DefifaGovernor.ratifiedScorecardIdOf[gameId] != 0` blocks further submissions and ratifications (`DefifaGovernor.sol:228, 307`). `cashOutWeightIsSet` on either hook blocks repeated `setTierCashOutWeightsTo` (`DefifaHook.sol:823`, `Defifa1155Hook.sol:847`).
3. **Single commitment fulfillment per game.** `commitmentsFulfilledFor[gameId]` is set before any external call (`DefifaDeployer.sol:369`); re-entry returns early.
4. **Single NO_CONTEST trigger per game.** `noContestTriggeredFor[gameId]` set before queuing the refund ruleset; `NoContestAlreadyTriggered` on second call (`DefifaDeployer.sol:672, 679`).
5. **Reserve mints blocked in NO_CONTEST.** Prevents reviving a failed `minParticipation` game by free-minting reserved face value (`DefifaHook.sol:604-606`, `Defifa1155Hook.sol:658-660`).
6. **Delegate changes restricted to MINT.** Locks voting power before scoring opens (`DefifaHook.sol:845-847, 858-860`, `Defifa1155Hook.sol:869-871, 882-884`).
7. **BWA snapshot one second before submission.** Excludes the whole submission block, blocking same-block mint/transfer-and-attest injection in either order (`DefifaGovernor.sol` `attestToScorecardFrom` / `submitScorecardFor`).
8. **Beneficiaries cannot self-attest at full power.** BWA reduces tier power by `tierWeight / totalCashOutWeight`; zero-power attestations revert (`DefifaGovernor.sol:742-746, 195-199`).
9. **Revocation disabled once QUEUED.** Kills attest/revoke griefing (`DefifaGovernor.sol:266-269`).
10. **Atomic ratification + commitment.** `ratifyScorecardFrom` calls `fulfillCommitmentsOf` in the same tx, ensuring the COMPLETE ruleset is always queued after weights are set (`DefifaGovernor.sol:253-255`).
11. **State-before-external-call ordering.** `commitmentsFulfilledFor`, `noContestTriggeredFor`, `ratifiedScorecardIdOf`, and `cashOutWeightIsSet` are all written BEFORE the external call that consumes them — re-entrancy cannot replay the action.
12. **Permissionless settlement triggers extract no value beyond canonical allocation.** `fulfillCommitmentsOf`, `triggerNoContestFor`, `mintReservesFor`, `submitScorecardFor`, `attestToScorecardFrom`, `ratifyScorecardFrom` — caller's reward is exactly the gas-funded service to the game, never a redirected payout.
13. **One-shot bindings.** `initialize` and `setTierCashOutWeightsTo` on either hook, `DefifaGovernor.initializeGame` — all irreversible. `DefifaDeployer`'s own dependencies are constructor `immutable`s (no setter at all).
14. **Front-run-resistant clone deployment.** `cloneDeterministic` salt includes `_msgSender()`; a different resolved caller produces a different address (`DefifaDeployer.sol:600-604`).
15. **Participation immune to balance inflation.** `minParticipation` checks `hook.totalMintCost`, not terminal balance — `addToBalanceOf` donations cannot satisfy the threshold (`DefifaDeployer.sol:301-308`).
16. **Game-piece-only cash-out path.** `beforeCashOutRecordedWith` reverts if fungible project tokens are cashed out (`DefifaHook.sol:316`, `Defifa1155Hook.sol:356-358`). The hook is the sole cash-out surface for Defifa games.
17. **No zero-address delegation.** Neither hook writes or reads `_tierDelegation[address(0)]` for mints, burns, or empty reserve mints (`DefifaHook.sol:621, 1147, 1156`, `Defifa1155Hook.sol:675, 1170, 1179`). Regression tests: `test/regression/AttestationDelegateBeneficiary.t.sol::test_emptyReserveMintDoesNotDelegateTheZeroAddress`, `test/erc1155/regression/ZeroAddressDelegation.t.sol`.
18. **Shared selectors.** The shared deployer, governor and resolver call the hook only through selectors both hooks expose (`initialize`, `store`, `currentSupplyOfTier`, `adjustedPendingReservesFor`, `TOTAL_CASHOUT_WEIGHT`, `setTierCashOutWeightsTo`, and the attestation views). Gated by `test/DefifaHookParity.t.sol`.
19. **Reserve positions never refund.** A MINT/REFUND/NO_CONTEST cash-out that includes an `isReserveMint` NFT or a position under `tierId + RESERVE_TOKEN_ID_OFFSET` reverts, including after transfer (`DefifaHookLib.sol:348-350`, `Defifa1155HookLib.sol:195-197`).
20. **ERC-1155 attestation units match balances.** For every holder and tier, attestation units equal (paid + reserve-ID balance) × `tier.votingUnits`; `_update` moves them with every transfer and burn, and mints add them where they mint (`Defifa1155Hook.sol:1114-1116, 705-707, 1233-1235`).
21. **Count records match per-position records.** `DefifaTiersHookStore`'s count functions leave the same store state as the upstream per-position functions (`test/DefifaTiersHookStore.t.sol`).

For the underlying parimutuel game mechanics, pot-formation math, fee pipeline, attacker economics on governance, and parameter design guidance, see **`CRYPTO_ECON.md`**.

---

## Section E — Out-of-scope centralization caveats

These are NOT third-party attack vectors but are powers held by privileged addresses:

- **`DefifaDeployer` dependency wiring** (governor, controller, registry, fee project IDs, hook origin, URI resolver, hook store, trusted forwarder) is fixed at construction as `immutable`s — there is no privileged post-deploy setter. Misconfiguration would require deploying with wrong constructor args (wrong governor, wrong fee project IDs, wrong forwarder, etc.) — operationally caught by deploy script validation.
- **`DefifaGovernor` Ownable owner** can call `initializeGame`. In production deployment this owner is the `DefifaDeployer` (called during `launchGameWith`). If the governor's owner were ever rotated to a non-deployer address, that address could bootstrap rogue scorecards for games it didn't deploy — but only games whose hook ownership it also controls, which would require breaking `DefifaDeployer.launchGameWith`'s `hook.transferOwnership(governor)` flow.
- **`DefifaGovernor` as game-hook owner** is the **single ratifier** of every scorecard for games its deployer launched. The governor itself doesn't decide outcomes — it only enforces the BWA quorum + grace + timelock state machine. But the governor's *bytecode* is the source of truth for ratification rules; replacing the governor (via a controller-level migration or hook-ownership transfer) would change the rules. The deploy script intentionally leaves the governor in place and the hooks owned by it — there is no path in this codebase to rotate hook ownership away from the original governor.
- **`DefifaDeployer` as `JBProjects` NFT holder** is the sole `ownerMustSendPayouts` invoker during SCORING (the SCORING ruleset sets `ownerMustSendPayouts=true`). `fulfillCommitmentsOf` is the deployer's `sendPayoutsOf` invocation — and it's permissionless. No human address has owner power over a Defifa game's payouts post-launch.
- **`launchGameWith` caller** picks the `defaultAttestationDelegate`, `attestationStartTime`, `attestationGracePeriod`, `timelockDuration`, `minParticipation`, `scorecardTimeout`, splits, tier metadata, and reserve beneficiaries. Players opting into a game are trusting the launcher's parameters. The governor and hook enforce structural bounds (≥ 1-day grace period, ratification window must fit inside scorecard timeout, valid currency), but cannot detect launcher-chosen parameter combinations that economically disadvantage players (e.g. a launcher could allocate 100% of splits to themselves; the protocol's role is to make this fact verifiable on-chain at launch, not to prevent the launcher from offering it).

---

## Section F — Key code references

- Phase view: `defifa/src/DefifaDeployer.sol:277-319`
- Game configuration validation: `defifa/src/DefifaDeployer.sol:435-522`
- Front-run-resistant clone deploy: `defifa/src/DefifaDeployer.sol:595-604`
- Project NFT custody: `defifa/src/DefifaDeployer.sol:530-531`
- Commitment fulfillment single-shot: `defifa/src/DefifaDeployer.sol:366-419`
- NO_CONTEST trigger single-shot + ruleset queue: `defifa/src/DefifaDeployer.sol:664-727`
- Splits fee construction: `defifa/src/DefifaDeployer.sol:733-822`
- SCORING ruleset (`ownerMustSendPayouts=true`): `defifa/src/DefifaDeployer.sol:932-990`
- `minParticipation` check uses `totalMintCost`: `defifa/src/DefifaDeployer.sol:301-308`
- Governor `initializeGame` (grace period + uint48 bounds): `defifa/src/DefifaGovernor.sol:521-575`
- BWA snapshot at `scorecard.snapshotTimestamp` (submission − 1): set in `defifa/src/DefifaGovernor.sol` `submitScorecardFor`, read in `attestToScorecardFrom`
- BWA self-attest guard (zero-power revert): `defifa/src/DefifaGovernor.sol:195-199`
- BWA tier-weight reduction: `defifa/src/DefifaGovernor.sol:742-746`
- Revocation gated to ACTIVE: `defifa/src/DefifaGovernor.sol:266-269`
- Single ratification per game: `defifa/src/DefifaGovernor.sol:227-230, 306-309`
- Concentration-adjusted quorum: `defifa/src/DefifaGovernor.sol:424-455`
- Atomic ratify + fulfillCommitments: `defifa/src/DefifaGovernor.sol:253-255`
- Submission rejects unrealizable weights: `defifa/src/DefifaGovernor.sol:325-337`
- Hook `setTierCashOutWeightsTo` (governor-only, SCORING-only, single-shot): `defifa/src/DefifaHook.sol:812-833`, `defifa/src/Defifa1155Hook.sol:836-857`
- Hook `initialize` one-shot: `defifa/src/DefifaHook.sol:525-590`, `defifa/src/Defifa1155Hook.sol:577-644`
- Reserve mints blocked in NO_CONTEST: `defifa/src/DefifaHook.sol:604-606`, `defifa/src/Defifa1155Hook.sol:658-660`
- Reserve mint cap: `defifa/src/DefifaHook.sol:616-617`, `defifa/src/Defifa1155Hook.sol:670-671`
- Empty reserve mint returns before any delegation write: `defifa/src/DefifaHook.sol:621`, `defifa/src/Defifa1155Hook.sol:675`
- Mints and burns never use the zero address's delegate: `defifa/src/DefifaHook.sol:1147, 1156`, `defifa/src/Defifa1155Hook.sol:1170, 1179`
- Delegate changes MINT-only: `defifa/src/DefifaHook.sol:845-847, 858-860`, `defifa/src/Defifa1155Hook.sol:869-871, 882-884`
- Hook cash-out path game-pieces-only: `defifa/src/DefifaHook.sol:316`, `defifa/src/Defifa1155Hook.sol:356-358`
- Hook 0-weight tier `NothingToClaim` guard: `defifa/src/DefifaHook.sol:780-784`, `defifa/src/Defifa1155Hook.sol:804-808`
- Hook overspend guard: `defifa/src/DefifaHook.sol:1107`, `defifa/src/Defifa1155Hook.sol:1130`
- Hook currency-lock guard: `defifa/src/DefifaHook.sol:1042-1046`, `defifa/src/Defifa1155Hook.sol:1059-1063`
- Hook payer ≠ beneficiary delegate guard: `defifa/src/DefifaHook.sol:1084-1089`, `defifa/src/Defifa1155Hook.sol:1106-1111`
- Fee-token claim share (shared formula): `defifa/src/libraries/DefifaHookLib.sol:68-84` (`tokensClaimFor`)
- Per-tier cash-out weight (shared formula): `defifa/src/libraries/DefifaHookLib.sol:255` (`computeTierCashOutWeight`)
- ERC-721 pay tier order (non-decreasing): `defifa/src/libraries/DefifaHookLib.sol:140-187` (`computeAttestationUnits`)
- ERC-721 cash-out ownership check + burn: `defifa/src/DefifaHook.sol:724-753`
- ERC-721 reserve rejection in refunds (`isReserveMint`): `defifa/src/DefifaHook.sol:334-341`, `defifa/src/libraries/DefifaHookLib.sol:348-350`
- ERC-721 transfer pause + attestation movement on transfers/burns: `defifa/src/DefifaHook.sol:1168-1202`
- ERC-1155 pay metadata validation (ascending tiers, non-zero counts, equal lengths): `defifa/src/libraries/Defifa1155HookLib.sol:79-106` (`computeAttestationUnits`)
- ERC-1155 cash-out holder balance check + batch burn: `defifa/src/Defifa1155Hook.sol:757-780`
- ERC-1155 reserve-ID rejection in refunds: `defifa/src/Defifa1155Hook.sol:378-385`, `defifa/src/libraries/Defifa1155HookLib.sol:195-197`
- ERC-1155 token ID → tier mapping (`RESERVE_TOKEN_ID_OFFSET = 1 << 16`): `defifa/src/libraries/Defifa1155HookLib.sol:37, 47-50`
- ERC-1155 mints end with the receiver acceptance check: `defifa/src/Defifa1155Hook.sol:997, 1004-1007`, `defifa/src/libraries/Defifa1155HookLib.sol:61-71` (`checkMintAcceptance`)
- ERC-1155 transfer pause + attestation movement on transfers/burns: `defifa/src/Defifa1155Hook.sol:1194-1246`
- Count-based store records: `defifa/src/DefifaTiersHookStore.sol:23-36, 46-117, 124-147`
- Resolver tier lookup by ERC-165: `defifa/src/DefifaTokenUriResolver.sol:125-131`

For the game's economic model and rational-actor analysis, see `CRYPTO_ECON.md`.
