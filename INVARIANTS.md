# Invariants of Defifa

Scope: the Defifa game protocol (`@ballkidz/defifa`) — `DefifaDeployer`, `DefifaGovernor`, `DefifaVotingReferee`, `DefifaHook`, `Defifa1155Hook`, `DefifaTiersHookStore`, and `DefifaTokenUriResolver`. Each Defifa game is a standalone Juicebox V6 project owned by a `DefifaDeployer`, with a per-game hook clone owned by that deployer's `DefifaGovernor`. Each game names one referee at launch; only the referee submits the game's scorecard to the governor. `DefifaVotingReferee` is the sample referee, one deployment for both game types.

Two game types ship side by side. The ERC-721 game uses `DefifaHook` (one NFT per position). The ERC-1155 game uses `Defifa1155Hook` (one balance per tier; paid ID = tier ID, reserve ID = `tierId + RESERVE_TOKEN_ID_OFFSET`). Each game type has its own `DefifaDeployer` plus `DefifaGovernor` pair running the same code; both pairs share one `DefifaTiersHookStore` and one `DefifaTokenUriResolver`. Unless an invariant names one hook, it holds for both, and hook citations list `DefifaHook.sol` first and `Defifa1155Hook.sol` second.

For the cryptoeconomic model (pot formation, prize distribution formula, fee pipeline, parimutuel game theory, parameter design), see `CRYPTO_ECON.md`. This document covers only the **structural / authorization / lifecycle invariants** of the contracts.

| Phase | Source of truth | What's allowed |
|-------|-----------------|----------------|
| COUNTDOWN | `currentRuleset.cycleNumber == 0` | nothing yet — ruleset hasn't started |
| MINT | `cycleNumber == 1` | `pay` mints tier NFTs (ERC-721) or tier positions (ERC-1155 balances) at `tierPrice`; cash-outs at mint price; delegate changes |
| REFUND | `cycleNumber == 2 && refundPeriodDuration != 0` | `pausePay=true`, cash-outs at mint price |
| SCORING | `cycleNumber >= 2/3` and not NO_CONTEST/COMPLETE | referee scorecard submission + ratification after the timelock (plus attestation, under a voting referee) |
| COMPLETE | `cashOutWeightIsSet == true` on hook | weighted reclaim by ratified tier weights |
| NO_CONTEST | `noContestTriggeredFor[gameId]` OR `totalMintCost < minParticipation` OR `block.timestamp > scoringStart + scorecardTimeout` (latched via `triggerNoContestFor`) | full refund at mint price after `triggerNoContestFor` queues the refund ruleset |

NO_CONTEST is reported by the view as soon as the condition is met; the on-chain ruleset only flips when `triggerNoContestFor` is called. The view-vs-state gap is the documented reason holders should check the active ruleset before cashing out (`DefifaDeployer.sol:279-321`, `DefifaDeployer.sol:670-733`).

---

## Section A — Guarantees to users

### A.1 Players (paying / cashing out)

- **MINT phase issuance.** A `pay()` during MINT charges `tierPrice` per position (uniform across tiers so attestation power is equal). The ERC-721 game mints one NFT per tier ID in the metadata-encoded `(attestationDelegate, uint16[] tierIdsToMint)`, tier IDs non-decreasing (`DefifaHook_BadTierOrder`, `DefifaHookLib.sol:111-158`). The ERC-1155 game mints `counts[i]` positions of each tier in the metadata-encoded `(attestationDelegate, uint16[] tierIds, uint256[] counts)` as one balance per tier (token ID = tier ID); tier IDs must be strictly ascending (`DefifaHook_BadTierOrder`), counts non-zero (`Defifa1155Hook_ZeroAmount`), and lengths equal (`Defifa1155Hook_LengthMismatch`) (`Defifa1155HookLib.sol:66-93`). Overspending (`leftoverAmount != 0`) reverts with `DefifaHook_Overspending` / `Defifa1155Hook_Overspending` — payer cannot accidentally over-fund. (`DefifaHook.sol:1135`, `Defifa1155Hook.sol:1158`)
- **Currency lock-in.** Payment currency must equal the `pricingCurrency` baked into the hook at `initialize`; mismatched currency reverts `DefifaHook_WrongCurrency` / `Defifa1155Hook_WrongCurrency`. (`DefifaHook.sol:1070-1074`, `Defifa1155Hook.sol:1087-1091`)
- **No mints outside MINT.** All non-MINT rulesets carry `pausePay=true` (`DefifaDeployer.sol:702`, `DefifaDeployer.sol:908`, `DefifaDeployer.sol:967`, `DefifaDeployer.sol:1023`). REFUND, SCORING, COMPLETE, and NO_CONTEST refund cycles all reject `pay`.
- **REFUND-phase reclaim.** During REFUND, surplus equals balance (no payout limits), so cash-out at the prevailing cash-out tax (0% for non-COMPLETE phases per `setTierCashOutWeightsTo` gating) returns each holder their proportional share of the pot — effectively the mint price for paid positions. Reserve-minted positions cannot be refunded: a MINT/REFUND/NO_CONTEST cash-out that includes one reverts (`DefifaHook_CantRefundReserveMint` / `Defifa1155Hook_CantRefundReserveMint`), including after transfer, so its notional cost never stays in `totalMintCost` or counts as a refunded burn. Reserves exist only from SCORING on, so in practice this applies in NO_CONTEST. ERC-721 reserve NFTs are flagged `isReserveMint` (`DefifaHook.sol:360-367`, `DefifaHookLib.sol:319-321`); ERC-1155 reserve positions live under token ID `tierId + RESERVE_TOKEN_ID_OFFSET` (`Defifa1155Hook.sol:397-404`, `Defifa1155HookLib.sol:182-184`).
- **NO_CONTEST refund.** Once `triggerNoContestFor` runs, the queued ruleset has no payout limits and `cashOutTaxRate=0`, enabling cash-out at mint price. Anyone can trigger this — players are not at the mercy of the deployer. (`DefifaDeployer.sol:670-733`)
- **COMPLETE-phase weighted reclaim.** After scorecard ratification, the hook's `beforeCashOutRecordedWith` substitutes the ratified per-tier `cashOutWeight` for raw token count, so winning tiers reclaim more pot per position than losers. Total reclaim is bounded by `TOTAL_CASHOUT_WEIGHT = 1e18` for accounting precision (`DefifaHook.sol:95, 374-381`, `Defifa1155Hook.sol:116, 412-418`).
- **Cash-out burns the positions.** The ERC-721 hook's `afterCashOutRecordedWith` requires `context.holder` to own each token ID, burns it, and decrements `totalMintCost` (`DefifaHook.sol:752-781, 815`). The ERC-1155 hook checks the holder's balance for each `(tokenId, amount)`, burns them with `_burnBatch`, records the burns in the store, and decrements `totalMintCost` (`Defifa1155Hook.sol:785-808, 839`).
- **0-weight-tier protection against accidental burns.** Positions whose tier received 0 cash-out weight (losing teams) revert with `DefifaHook_NothingToClaim` / `Defifa1155Hook_NothingToClaim` if neither reclaim nor fee tokens would be distributed — protecting holders from burning for nothing. (`DefifaHook.sol:808-812`, `Defifa1155Hook.sol:832-836`)
- **Fee-token (`$DEFIFA`/`$BASE_PROTOCOL`) claims.** On COMPLETE-phase cash-out, holders also receive their pro-rata share of the fee-project tokens delivered to the hook during `fulfillCommitmentsOf`. Share = `cumulativeMintPrice / (totalMintCost + pendingReserveMintCost)`. Reserves are accounted in the denominator so paid holders cannot claim a disproportionate share before reserves mint. Both hooks compute the share with `DefifaHookLib.tokensClaimFor` (`DefifaHookLib.sol:554-570`). (`DefifaHook.sol:797-801`, `Defifa1155Hook.sol:821-825`)
- **Reserve mints are permissionless and capped.** `mintReservesFor` mints to the pre-configured reserve beneficiary only, capped at `adjustedPendingReservesFor(tier)`. No caller can mint more than the tier's reserve frequency entitles. (`DefifaHook.sol:644-645`, `Defifa1155Hook.sol:698-699`)
- **Empty reserve mints write no delegation.** `mintReservesFor` returns before any delegation write when the capped count is 0 or the tier has no reserve beneficiary, and mints and burns never read or write the zero address's tier delegate. A reserve-mint call with nothing to mint therefore cannot set `_tierDelegation[address(0)]`, which later pays would otherwise charge as the source delegate and revert. (`DefifaHook.sol:649, 1175, 1184`, `Defifa1155Hook.sol:703, 1198, 1207`)
- **Game configuration sanity.** `launchGameWith` reverts if start/mint/refund durations are inconsistent, if `tiers.length > 128`, if `scorecardTimeout == 0`, if `referee` is the zero address, if ERC-20 games supply `currency=0`, or if `scorecardTimeout <= timelockDuration` (no scorecard could ever be ratified). A referee's own windows, such as a voting referee's attestation delay and grace period, are not checked against the timeout. (`DefifaDeployer.sol:437-524`)
- **Frozen tier price.** All tiers launch with the same `tierPrice`, `discountPercent=0`, `cantIncreaseDiscountPercent=true`, `cantBeRemoved=true`, `allowOwnerMint=false`. Operator cannot drop in cheap tiers post-launch or admin-mint into a winning tier. (`DefifaDeployer.sol:563-584`)

### A.2 Referees and ratification

- **Only the referee submits.** `DefifaGovernor.submitScorecardFor` reverts `DefifaGovernor_NotReferee` for any caller other than `refereeOf[gameId]`, and `DefifaGovernor_GameNotFound` for a game with no referee. The deployer and the governor both reject a zero referee (`DefifaGovernor.sol` `initializeGame`, `submitScorecardFor`).
- **One pending scorecard.** A submission replaces the pending scorecard and restarts the timelock. Resubmitting the pending scorecard reverts `DefifaGovernor_DuplicateScorecard`, so a submission always changes the pending result. A replaced scorecard reads DEFEATED (`DefifaGovernor.sol` `submitScorecardFor`, `stateOf`).
- **Timelock before ratification.** `stateOf` returns QUEUED while `block.timestamp < submittedAt + timelockDurationOf[gameId]` and SUCCEEDED after. `ratifyScorecardFrom` requires SUCCEEDED, so only the pending scorecard, past its timelock, can be ratified. Anyone can ratify (`DefifaGovernor.sol` `stateOf`, `ratifyScorecardFrom`).
- **Single ratification per game.** `ratifiedScorecardIdOf[gameId] != 0` reverts later submissions and ratifications with `AlreadyRatified`. Once one scorecard is ratified, every other reads DEFEATED (`DefifaGovernor.sol` `submitScorecardFor`, `ratifyScorecardFrom`, `stateOf`).
- **Submission rejects unrealizable weights.** A scorecard with `cashOutWeight > 0` for a tier with `currentSupplyOfTier == 0` reverts, and `DefifaHookLib.validateAndBuildWeights` runs the hook's own checks at submission, so a malformed scorecard fails before its timelock (`DefifaGovernor.sol` `submitScorecardFor`).
- **Submission only in SCORING.** `submitScorecardFor` reverts `NotAllowed` outside SCORING, so a referee cannot submit after the timeout (the phase is then NO_CONTEST).
- **Referee settings come from the deployer.** When `refereeData` is not empty, `launchGameWith` calls `IDefifaReferee(referee).initializeGameFor(gameId, refereeData)` after naming the referee in the governor. `IDefifaReferee` requires implementations to accept this call only from the game's project owner (`DefifaDeployer.sol:634-645`).

### A.2.1 DefifaVotingReferee attesters

These hold for games whose referee is `DefifaVotingReferee`. They are rules of that referee, not of the governor.

- **Owner-only game setup.** `initializeGameFor` reverts `DefifaVotingReferee_NotProjectOwner` unless the caller owns the game's project (the deployer), and `AlreadyInitialized` on a second call. `refereeData` is `abi.encode(attestationStartTime, attestationGracePeriod)`; a zero start time means attestation opens as soon as a scorecard is submitted (`DefifaVotingReferee.sol` `initializeGameFor`).
- **BWA snapshot one second before submission.** Voting power is read at `scorecard.snapshotTimestamp` = submission timestamp − 1. Checkpoints are `block.timestamp`-keyed and same-timestamp writes overwrite in place, so reading before the submission block excludes any mint or transfer that shares that block, in either order relative to submission — neither a post-submission `mintReservesFor` nor a same-block `transferFrom` / `safeTransferFrom` can grant or move attestation power for that scorecard. `attestationsBegin` is still advanced to the next timestamp so the attestation window opens in a later block than submission (`DefifaVotingReferee.sol` `attestToScorecardFrom` and `submitScorecardFor`).
- **Benefit-Weighted Attestation (BWA) reduces beneficiary power.** Each tier's attestation power is scaled by `(totalCashOutWeight - tierWeight) / totalCashOutWeight`. A tier with 100% of the scorecard weight receives 0 attestation power on that scorecard — beneficiaries **cannot self-attest at full power** (`DefifaVotingReferee.sol` `getBWAAttestationWeight`). Zero-power attestations revert (`attestToScorecardFrom`).
- **Concentration-adjusted quorum.** With N quorum-eligible tiers, the most attestation any scorecard can collect is `maxBWA = (N - 1) × MAX_ATTESTATION_POWER_TIER`, because a tier never attests to its own payout. At submission the referee snapshots `quorum = max(1, maxBWA × bps / 10_000)` with `bps = QUORUM_EVEN_BPS + (QUORUM_WINNER_TAKE_ALL_BPS - QUORUM_EVEN_BPS) × maxShare²`, where `maxShare` is the largest tier weight over `TOTAL_CASHOUT_WEIGHT`, `QUORUM_EVEN_BPS = 5_000` and `QUORUM_WINNER_TAKE_ALL_BPS = 7_500`. Quorum is a share of aggregate losing-tier power, not of each tier. It never exceeds 75% of `maxBWA`, so BWA rounding (under 2 units per attesting delegate and tier) cannot put it out of reach of unanimous non-beneficiary attestation when every tier's units can attest (pending reserves can't until minted and delegated before submission); the floor of 1 keeps a one-tier game unratifiable. `quorum(gameId)` reports the 50% baseline and `quorumOf(gameId, scorecardId)` a scorecard's snapshot (`DefifaVotingReferee.sol` `submitScorecardFor`, `_quorumOf`, `_maxAttestationWeightOf`).

  | Largest tier share | Near 0 (spread over many tiers) | 25% | 50% | 75% | 100% |
  | --- | --- | --- | --- | --- | --- |
  | Share of `maxBWA` needed | 50% | 51.6% | 56.25% | 64.1% | 75% |

- **Minimum grace period (1 day).** Enforced at `initializeGameFor`; prevents instant approval (`DefifaVotingReferee.sol` `MIN_ATTESTATION_GRACE_PERIOD`, `initializeGameFor`).
- **States end at SUCCEEDED.** The referee's `stateOf` returns PENDING before attestations begin, ACTIVE until the grace period ends with quorum met, then SUCCEEDED. It returns RATIFIED or DEFEATED once the governor ratifies a scorecard. Scorecards below quorum stay ACTIVE; `scorecardTimeout` is the backstop (`DefifaVotingReferee.sol` `stateOf`).
- **First forwarded wins.** `forwardScorecardFor` requires SUCCEEDED and reverts `AlreadyForwarded` once `forwardedScorecardIdOf[gameId]` is set, then calls the game's governor `submitScorecardFor`. A competing approved scorecard therefore cannot replace the forwarded one just before its timelock ends and push the game past its timeout (`DefifaVotingReferee.sol` `forwardScorecardFor`).
- **Governor found through the project owner.** The referee reads each game's governor as `IDefifaDeployer(PROJECTS.ownerOf(gameId)).GOVERNOR()`, so one deployment serves 721 and 1155 games (`DefifaVotingReferee.sol` `_governorOf`).
- **One attestation per (account, scorecard).** Re-attestation reverts `AlreadyAttested`. Revocation requires prior attestation (`DefifaVotingReferee.sol` `attestToScorecardFrom`, `revokeAttestationFrom`).
- **Revocation only while ACTIVE.** Once a scorecard is SUCCEEDED, revocation reverts; this kills the attest/revoke griefing loop while still allowing course-correction during the grace period (`DefifaVotingReferee.sol` `revokeAttestationFrom`).
- **Duplicate-scorecard rejection.** `_scorecardOf[gameId][scorecardId].attestationsBegin != 0` ⇒ `DuplicateScorecard`. The scorecard ID is the keccak of `(hook, calldata)`, so the same weight vector cannot be re-submitted to the referee (`DefifaVotingReferee.sol` `submitScorecardFor`).
- **Reserve-mint snapshots.** On submission, the referee snapshots each tier's pending reserves and minted-unit total, and BWA reads each tier's total from those snapshots. Because account power is read at `snapshotTimestamp` (before the submission block), a reserve minted at or after submission gains no numerator, and the snapshotted pending reserves dilute exactly once (`DefifaVotingReferee.sol` `_tierAttestationUnitsAt`).
- **Quorum eligibility includes pending reserves.** A tier with all paid tokens burned during REFUND but with pending reserves still contributes to quorum, so a burner cannot erase another participant's quorum contribution (`DefifaVotingReferee.sol` `_maxAttestationWeightOf`).

### A.3 Protections against external interference

- **No third-party can change cash-out weights.** `setTierCashOutWeightsTo` is `onlyOwner` (the governor) AND gated on `gamePhase == SCORING` AND single-shot (`cashOutWeightIsSet`). Even the governor can't re-score a game once set. (`DefifaHook.sol:840-861`, `Defifa1155Hook.sol:864-885`)
- **No third-party can re-route fee splits.** Splits are written by the deployer once during `_buildSplits` for the scoring ruleset and never changed (`DefifaDeployer.sol:739-828`). The deployer permanently holds the game's `JBProjects` NFT (`DefifaDeployer.sol:532-533`).
- **No third-party can mint admin pieces.** `allowOwnerMint=false` on every tier (`DefifaDeployer.sol:574`); the controller's `allowOwnerMinting=false` on every ruleset.
- **Reserve mints blocked in NO_CONTEST.** Prevents a malicious reserve mint from inflating `totalMintCost` past `minParticipation` after the game has already failed the participation check, which would otherwise revive the game from NO_CONTEST → SCORING (`DefifaHook.sol:632-634`, `Defifa1155Hook.sol:686-688`).
- **Delegate changes locked after MINT.** `setTierDelegateTo` / `setTierDelegatesTo` revert outside the MINT phase. This freezes the attestation power voting referees read before scoring begins, so attestation can't be hot-swapped to a colluding delegate after scorecards drop (`DefifaHook.sol:873-875, 886-888`, `Defifa1155Hook.sol:897-899, 910-912`).
- **`addToBalanceOf` cannot inflate participation.** `minParticipation` is checked against `totalMintCost` (incremented only by paid mints and reserve mints), not terminal balance — donations to the terminal cannot artificially satisfy the participation threshold (`DefifaDeployer.sol:303-310`).
- **Front-run-resistant hook clone.** `cloneDeterministic` salts on `keccak256(_msgSender(), nonce)` so a different resolved caller produces a different address; a watcher cannot front-run `launchGameWith` to deploy a hook at the predicted address and DoS initialization. For trusted-forwarder calls, `_msgSender()` is the ERC-2771 signer, not the forwarder (`DefifaDeployer.sol:597-606`).
- **Commitment fulfillment is single-shot.** `commitmentsFulfilledFor[gameId]` set BEFORE external calls; a re-entrant call returns early (`DefifaDeployer.sol:370-371`).
- **NO_CONTEST trigger is single-shot.** `noContestTriggeredFor[gameId]` set BEFORE queuing the refund ruleset; a re-entrant call reverts `NoContestAlreadyTriggered` (`DefifaDeployer.sol:677-685`).

---

## Section B — Guarantees to owners

### B.1 DefifaDeployer bindings

- **Dependency bindings are constructor `immutable`s, not a runtime setter.** `HOOK_CODE_ORIGIN`, `TOKEN_URI_RESOLVER`, `GOVERNOR`, `CONTROLLER`, `REGISTRY`, `DEFIFA_PROJECT_ID`, `BASE_PROTOCOL_PROJECT_ID`, `HOOK_STORE`, and the ERC-2771 `trustedForwarder` are all fixed at construction (`DefifaDeployer.sol:336-360`). These dependencies share unified CREATE2 addresses / canonical project IDs across chains, so nothing chain-specific remains to wire post-deploy — no address can mutate them after deployment.

No caller can retro-edit any existing game's rulesets, splits, fee divisors, or tier configuration. The protocol-fee divisor (`BASE_PROTOCOL_FEE_DIVISOR = 40` ⇒ 2.5%) and Defifa-fee divisor (`DEFIFA_FEE_DIVISOR = 20` ⇒ 5%) are `constant` (`DefifaDeployer.sol:99, 103`).

### B.2 DefifaGovernor owner (governor as game-hook owner)

- **`initializeGame(gameId, referee, timelockDuration)`** — `onlyOwner` (the deployer, called from `launchGameWith`), one-time per game (`refereeOf[gameId] != address(0)` reverts `AlreadyInitialized`). Rejects a zero referee (`ZeroReferee`) and a timelock above `uint48` (`DefifaGovernor.sol` `initializeGame`).

The governor itself is the `owner` of every hook its deployer launches (`DefifaDeployer.sol:646-647`). This means the governor — and only the governor — can call `setTierCashOutWeightsTo` on those hooks. The governor's `ratifyScorecardFrom` is the **only** path that exercises this owner power, and it requires the referee's pending scorecard to be SUCCEEDED (`DefifaGovernor.sol` `ratifyScorecardFrom`). The governor's own `Ownable` `owner` is set at deploy; that owner has no further authority over individual games once `initializeGame` has been called.

### B.3 Liveness guarantees

- **Phase progression doesn't require any privileged action.** Phase transitions are pure functions of `block.timestamp` and ruleset cycle number (`DefifaDeployer.sol:279-321`). Anyone can call `fulfillCommitmentsOf` (after `cashOutWeightIsSet`), `triggerNoContestFor` (when conditions match), or `mintReservesFor`.
- **Ratification triggers commitment fulfillment atomically.** `ratifyScorecardFrom` calls `IDefifaDeployer.fulfillCommitmentsOf(gameId)` after setting the cash-out weights, so the final ruleset is queued in the same tx that finalizes scoring (`DefifaGovernor.sol` `ratifyScorecardFrom`). `fulfillCommitmentsOf` wraps `sendPayoutsOf` in try/catch and always queues the final ruleset (`DefifaDeployer.sol:403-418`).
- **`scorecardTimeout` backstop.** If no scorecard ratifies in time, including when the referee never submits, the game transitions to NO_CONTEST via the view; `triggerNoContestFor` then queues the refund ruleset (`DefifaDeployer.sol:312-318`, `DefifaDeployer.sol:670-733`).

---

## Section C — Per-contract operation inventory

### C.1 DefifaDeployer — `defifa/src/DefifaDeployer.sol`

Owns every game's project NFT (`PROJECTS.createFor(this)` in `launchGameWith`). Hook-agnostic: one deployment per game type, each with its own `HOOK_CODE_ORIGIN` (`DefifaHook` or `Defifa1155Hook`) and governor. It calls the hook only through selectors both hooks expose (`test/DefifaHookParity.t.sol`).

**Permissionless game launch:**

- **`launchGameWith(DefifaLaunchProjectData)` payable → gameId** — anyone, including through the configured ERC-2771 trusted forwarder. Forwards `msg.value` to `JBProjects.createFor` for the creation fee and advertises the resolved `_msgSender()` as `originalPayer` while `createFor` runs. Validates timing/tier/currency/timeout consistency; clones the Defifa hook via `cloneDeterministic` salted with `_msgSender() || nonce`; queues MINT (optional REFUND) and SCORING rulesets via `controller.launchRulesetsFor`; calls `governor.initializeGame(gameId, referee, timelockDuration)`; calls `IDefifaReferee(referee).initializeGameFor(gameId, refereeData)` when `refereeData` is not empty; transfers hook ownership to the governor; registers the clone in the address registry. (`DefifaDeployer.sol:427-658`)
  - **Invariant:** game ID reserved before hook deployment so an interleaving `createFor` cannot invalidate the salt. Project NFT permanently held by this contract.

**Permissionless lifecycle triggers:**

- **`fulfillCommitmentsOf(uint256 gameId)`** — anyone after `cashOutWeightIsSet`. Single-shot (`commitmentsFulfilledFor` set before external calls). Pays `pot × commitmentPercent / SPLITS_TOTAL_PERCENT` via `sendPayoutsOf`; queues the final ruleset (no payouts, surplus = balance). Wraps payout in try/catch; if payout fails, fee stays in pot and `fulfilledCommitmentsOf` resets to 0. Final ruleset always queued. (`DefifaDeployer.sol:368-421`)
  - **Invariant:** caller cannot route the fee elsewhere; recipients are the user splits + Defifa project + base-protocol project, all baked in at launch. Pot accounting via `currentGamePotOf(includeCommitments=true)` stays consistent regardless of payout success.
- **`triggerNoContestFor(uint256 gameId)`** — anyone when `currentGamePhaseOf == NO_CONTEST` (i.e. participation failed or scorecard timeout elapsed). Single-shot via `noContestTriggeredFor`. Queues a `pausePay=true`, no-payout-limit, `cashOutTaxRate=0` ruleset that turns the entire balance into surplus, enabling refund cash-outs. (`DefifaDeployer.sol:670-733`)
  - **Invariant:** cannot be called when scorecard ratified (`cashOutWeightIsSet` ⇒ phase = COMPLETE, not NO_CONTEST); cannot be called twice; queued ruleset uses the current ruleset's `dataHook`/`baseCurrency`.

**Construction-time bindings:**

- All Defifa dependencies (hook origin, URI resolver, governor, controller, registry, fee project IDs, hook store, and trusted forwarder) are constructor `immutable`s — there is no post-deploy setter to bind or rebind them. (`DefifaDeployer.sol:336-360`)

**ERC-721 receipt:**

- **`onERC721Received(...)`** — accepts any 721 (returns selector). Used during `createFor` to receive the game's `JBProjects` NFT. (`DefifaDeployer.sol:661-663`)

**Views:** `currentGamePhaseOf`, `currentGamePotOf`, `nextPhaseNeedsQueueing`, `safetyParamsOf`, `timesFor`, `tokenOf`, `BASE_PROTOCOL_FEE_DIVISOR`, `DEFIFA_FEE_DIVISOR`, `defifaProjectId`, `baseProtocolProjectId`, `hookCodeOrigin`, `tokenUriResolver`, `governor`, `controller`, `registry`, `hookStore`, `fulfilledCommitmentsOf`, `commitmentsFulfilledFor`, `noContestTriggeredFor`.

### C.2 DefifaGovernor — `defifa/src/DefifaGovernor.sol`

One per deployer, so one per game type. Owns every hook clone its deployer launches. Hook-agnostic: it calls the hook only through selectors both hooks expose (`test/DefifaHookParity.t.sol`). Counts no votes: it takes each game's scorecard from the game's referee, holds it through the timelock, and lets anyone ratify it.

**Owner-only (one-shot per game):**

- **`initializeGame(gameId, referee, timelockDuration)`** — `onlyOwner` (deployer, during `launchGameWith`). Reverts `AlreadyInitialized` on re-call, `ZeroReferee` for a zero referee, and `Uint48Overflow` for a timelock above `uint48`. Stores `refereeOf` and `timelockDurationOf`; emits `GameInitialized(gameId, referee, timelockDuration, caller)`.

**Referee-only during SCORING:**

- **`submitScorecardFor(gameId, DefifaTierCashOutWeight[]) → scorecardId`** — `refereeOf[gameId]` only (`NotReferee` otherwise). Reverts if `ratifiedScorecardIdOf[gameId] != 0`, the game has no referee (`GameNotFound`), or the game is not in SCORING. Ensures any `cashOutWeight > 0` tier has live ownership and runs `DefifaHookLib.validateAndBuildWeights` (the hook's own validation). Reverts `DuplicateScorecard` if the scorecard is already pending; otherwise makes it pending and records `scorecardSubmittedAtOf[gameId][scorecardId] = block.timestamp`, replacing any earlier pending scorecard.

**Permissionless:**

- **`ratifyScorecardFrom(gameId, DefifaTierCashOutWeight[]) → scorecardId`** — anyone once the scorecard's state is SUCCEEDED (pending, timelock passed). Reverts if already ratified. Stores `ratifiedScorecardIdOf`, low-level-calls `metadata.dataHook.setTierCashOutWeightsTo(tierWeights)` (the governor is the hook's owner), then calls `IDefifaDeployer.fulfillCommitmentsOf(gameId)`.
  - **Invariant:** ratification and commitment fulfillment are atomic; cash-out weights set exactly once per game.

**Views:** `refereeOf`, `timelockDurationOf`, `pendingScorecardIdOf`, `scorecardSubmittedAtOf`, `ratifiedScorecardIdOf`, `scorecardIdOf`, `stateOf` (QUEUED → SUCCEEDED → RATIFIED, or DEFEATED when replaced or another is ratified; reverts `UnknownProposal` for a scorecard never submitted), `CONTROLLER`.

### C.2.1 DefifaVotingReferee — `defifa/src/referees/DefifaVotingReferee.sol`

The sample referee. One deployment serves every game that names it, of both types; it finds each game's hook through the controller and each game's governor through the game's project owner (`GOVERNOR()`). Reads attestation units through the hook's delegation checkpoints, which both hooks expose.

**Project-owner-only (one-shot per game):**

- **`initializeGameFor(gameId, data)`** — the game's project owner only (`NotProjectOwner`). Decodes `(attestationStartTime, attestationGracePeriod)`; a zero start time becomes `block.timestamp`. Reverts `AlreadyInitialized` on re-call, `GracePeriodTooShort` below `MIN_ATTESTATION_GRACE_PERIOD` (1 day), and `Uint48Overflow` beyond `uint48`. Emits `GameInitialized(gameId, attestationStartTime, attestationGracePeriod, caller)`.

**Permissionless during SCORING:**

- **`submitScorecardFor(gameId, DefifaTierCashOutWeight[]) → scorecardId`** — anyone. Reverts if the governor has ratified, the game is not initialized here, or the game is not in SCORING. Runs the governor's weight checks. Snapshots pending reserves and minted attestation units per tier. Computes the concentration-adjusted quorum (`maxBWA × (QUORUM_EVEN_BPS + (QUORUM_WINNER_TAKE_ALL_BPS - QUORUM_EVEN_BPS) × maxShare²) / 10_000`, at least 1). Same hash twice reverts `DuplicateScorecard`.
- **`attestToScorecardFrom(gameId, scorecardId) → weight`** — anyone with BWA power > 0 while the scorecard is ACTIVE or SUCCEEDED. Reads voting power at `scorecard.snapshotTimestamp` (one second before submission). Zero-power callers revert `NotAllowed`.
- **`revokeAttestationFrom(gameId, scorecardId)`** — prior attester only, ACTIVE state only. Subtracts the stored weight.
- **`forwardScorecardFor(gameId, DefifaTierCashOutWeight[]) → scorecardId`** — anyone once the scorecard is SUCCEEDED and no scorecard has been forwarded for the game (`AlreadyForwarded` otherwise). Sets `forwardedScorecardIdOf[gameId]`, then calls the governor's `submitScorecardFor` as the game's referee. Emits `ScorecardForwarded`.
  - **Invariant:** at most one scorecard per game reaches the governor from this referee.

**Views:** `attestationCountOf`, `hasAttestedTo`, `scorecardIdOf`, `attestationGracePeriodOf`, `attestationStartTimeOf`, `forwardedScorecardIdOf`, `getAttestationWeight`, `getBWAAttestationWeight`, `quorum`, `quorumOf`, `stateOf` (PENDING → ACTIVE → SUCCEEDED, then RATIFIED/DEFEATED from the governor), `MAX_ATTESTATION_POWER_TIER`, `MIN_ATTESTATION_GRACE_PERIOD`, `QUORUM_EVEN_BPS`, `QUORUM_WINNER_TAKE_ALL_BPS`, `CONTROLLER`.

### C.3 DefifaHook — `defifa/src/DefifaHook.sol` (ERC-721 game)

Per-game clone, extends `JB721Hook`; one NFT per position. Ownable; the deployer transfers ownership to the governor immediately after `initialize`.

**Clone-factory one-shot:**

- **`initialize(...)`** — anyone, exactly once per clone. Reverts on the code origin or when `store` already set. Records tiers via `_store.recordAddTiers`; stores per-tier names; sets `pricingCurrency`, `gamePhaseReporter`, `gamePotReporter`, `defaultAttestationDelegate`; transfers ownership back to `msg.sender` (the deployer). (`DefifaHook.sol:553-618`)

**Governor-only (during SCORING, single-shot):**

- **`setTierCashOutWeightsTo(DefifaTierCashOutWeight[])`** — `onlyOwner` (governor). Reverts if `gamePhase != SCORING` or `cashOutWeightIsSet`. Validates and stores `_tierCashOutWeights`; sets `cashOutWeightIsSet = true`. (`DefifaHook.sol:840-861`)
  - **Invariant:** exactly one weight assignment per game; flips the phase view to COMPLETE.

**Permissionless (gated by phase):**

- **`mintReservesFor(uint256 tierId, uint256 count)`** — anyone, but blocked when `mintPendingReservesPaused` (set during MINT/REFUND) or `gamePhase == NO_CONTEST`. Caps `count` at `adjustedPendingReservesFor(tierId)` and returns before any delegation write if the capped count is 0 or the tier has no reserve beneficiary. Mints to the tier's reserve beneficiary; flags `isReserveMint[tokenId] = true`; increments `totalMintCost` by `tier.price * count`; auto-delegates reserve units. (`DefifaHook.sol:623-700`)
  - **Invariant:** cannot inflate participation past `minParticipation` after the game has failed (NO_CONTEST gate); cannot mint more than the tier's reserve frequency entitles; never writes `_tierDelegation[address(0)]`.
- **`mintReservesFor(JB721TiersMintReservesConfig[])`** — batch variant. (`DefifaHook.sol:820-835`)

**Holder-only (MINT-phase-gated):**

- **`setTierDelegateTo(address delegatee, uint256 tierId)`** — caller (delegating own units). Reverts outside MINT. Zero-address delegate reverts. (`DefifaHook.sol:866-878`)
- **`setTierDelegatesTo(DefifaDelegation[])`** — batch variant; same phase + non-zero checks per entry. (`DefifaHook.sol:882-909`)
  - **Invariant:** voting power locked before scoring starts.

**Terminal-only callbacks:**

- **`afterPayRecordedWith(JBAfterPayRecordedContext) payable`** — only project terminal; reverts on `msg.value != 0` or wrong context. Decodes `(attestationDelegate, tierIdsToMint)` from metadata; mints via `_mintAll`; reverts `Overspending` on leftover. Third-party payer cannot overwrite the beneficiary's existing tier delegate via metadata (only payer=beneficiary may rewire). (`DefifaHook.sol:514-532, 1068-1136`)
- **`afterCashOutRecordedWith(JBAfterCashOutRecordedContext) payable`** — only project terminal; verifies caller-supplied token IDs all belong to `context.holder`; burns each; tracks per-tier `tokensRedeemedFrom` (COMPLETE) or `refundedBurnsFrom` (REFUND/NO_CONTEST); decrements `totalMintCost`. Reverts `NothingToClaim` if reclaim is 0 AND no fee tokens distributed. (`DefifaHook.sol:710-816`)
- **`beforeCashOutRecordedWith(JBBeforeCashOutRecordedContext) view`** — `IJBRulesetDataHook`. Reverts if fungible tokens are being cashed out (NFTs only). Computes `cumulativeMintPrice`, reverting `DefifaHook_CantRefundReserveMint` if a reserve mint is included in MINT/REFUND/NO_CONTEST; returns this contract as the cash-out hook with the encoded cumulative mint price; uses surplus as totalSupply / effectiveSurplusValue. (`DefifaHook.sol:328-391`)

**Transfers:** `_update` reverts `DefifaHook_TransfersPaused` on paused transfers (burns allowed), records the first owner, moves attestation units, and records the transfer in the store. Mints use `_mint`, which calls no receiver. (`DefifaHook.sol:1196-1230`, `DefifaHook.sol:685, 1004`)

**Views:** `firstOwnerOf`, `getPastTierAttestationUnitsOf`, `getPastTierTotalAttestationUnitsOf`, `getTierAttestationUnitsOf`, `getTierDelegateOf`, `getTierTotalAttestationUnitsOf`, `tierCashOutWeights`, `tierIdOf`, `tierNameOf`, `cashOutWeightOf` (single + batch), `currentSupplyOfTier`, `adjustedPendingReservesFor`, `supportsInterface`, `tokenURI`, `tokensClaimableFor`, `totalCashOutWeight`, `TOTAL_CASHOUT_WEIGHT`, `CODE_ORIGIN`, `DEFIFA_TOKEN`, `BASE_PROTOCOL_TOKEN`, `totalMintCost`, `amountRedeemed`, `baseURI`, `cashOutWeightIsSet`, `contractURI`, `defaultAttestationDelegate`, `gamePhaseReporter`, `gamePotReporter`, `isReserveMint`, `pricingCurrency`, `refundedBurnsFrom`, `rulesets`, `store`, `tokensRedeemedFrom`.

### C.4 Defifa1155Hook — `defifa/src/Defifa1155Hook.sol` (ERC-1155 game)

Per-game clone, an OpenZeppelin `ERC1155` game-piece hook (not `JB721Hook`/ERC-721) that implements the data, pay, and cash-out hook interfaces directly. Positions are balances: paid positions use token ID = tier ID, reserve-minted positions use `tierId + RESERVE_TOKEN_ID_OFFSET` (`1 << 16`), and `tierIdOf` maps either back (`Defifa1155HookLib.sol:37, 272-275`). Tier config, supply, reserve, burn, and per-tier holder accounting stay in `DefifaTiersHookStore`, called once per tier; attestation units are hook balances × `tier.votingUnits`. Mints run the ERC-1155 receiver acceptance check last, after every state change; transfers are standard safe transfers. Errors are prefixed `Defifa1155Hook_`; shared-rule errors from `DefifaHookLib` keep `DefifaHook_`. Ownable; the deployer transfers ownership to the governor immediately after `initialize`.

**Clone-factory one-shot:**

- **`initialize(...)`** — same rules as `DefifaHook.initialize`, with `_gameName` / `_gameSymbol` naming the collection. (`Defifa1155Hook.sol:605-672`)

**Governor-only (during SCORING, single-shot):**

- **`setTierCashOutWeightsTo(DefifaTierCashOutWeight[])`** — same rules as `DefifaHook`. (`Defifa1155Hook.sol:864-885`)
  - **Invariant:** exactly one weight assignment per game; flips the phase view to COMPLETE.

**Permissionless (gated by phase):**

- **`mintReservesFor(uint256 tierId, uint256 count)`** — same gates, cap, and early return as `DefifaHook`. Mints `count` positions of token ID `tierId + RESERVE_TOKEN_ID_OFFSET` to the tier's reserve beneficiary in one balance; increments `totalMintCost` by `tier.price * count`; auto-delegates reserve units; emits `MintReservedToken(tierId, beneficiary, count, caller)`. (`Defifa1155Hook.sol:677-744`)
  - **Invariant:** same as `DefifaHook`; reserve IDs stay distinct from paid IDs after transfer.
- **`mintReservesFor(JB721TiersMintReservesConfig[])`** — batch variant. (`Defifa1155Hook.sol:844-859`)

**Holder-only (MINT-phase-gated):**

- **`setTierDelegateTo` / `setTierDelegatesTo`** — same rules as `DefifaHook`. (`Defifa1155Hook.sol:890-902, 906-933`)

**Terminal-only callbacks:**

- **`afterPayRecordedWith(JBAfterPayRecordedContext) payable`** — only project terminal; reverts on `msg.value != 0` or wrong context. Decodes `(attestationDelegate, uint16[] tierIds, uint256[] counts)` from metadata; reverts `Defifa1155Hook_InvalidBeneficiary` for a zero beneficiary; records the counts in the store and mints one balance per tier via `_mintAll` (emitting `Mint(tierId, beneficiary, count, totalAmountContributed, caller)`); reverts `Overspending` on leftover. Same payer ≠ beneficiary delegate guard as `DefifaHook`. (`Defifa1155Hook.sol:555-568, 1085-1159`)
- **`afterCashOutRecordedWith(JBAfterCashOutRecordedContext) payable`** — only project terminal; decodes `(uint256[] tokenIds, uint256[] amounts)` and reverts `Defifa1155Hook_Unauthorized` if `context.holder`'s balance of any ID is below its amount; burns them in one `_burnBatch`; records per-tier burns and `tokensRedeemedFrom` (COMPLETE) or `refundedBurnsFrom` (REFUND/NO_CONTEST) through `Defifa1155HookLib.recordBurns`; decrements `totalMintCost`. Reverts `NothingToClaim` if reclaim is 0 AND no fee tokens distributed. (`Defifa1155Hook.sol:754-840`)
- **`beforeCashOutRecordedWith(JBBeforeCashOutRecordedContext) view`** — `IJBRulesetDataHook`. Reverts if fungible tokens are being cashed out (positions only). Computes `cumulativeMintPrice` from `(ids, amounts)`, reverting `Defifa1155Hook_CantRefundReserveMint` if a reserve ID is included in MINT/REFUND/NO_CONTEST; mismatched lengths revert `Defifa1155Hook_LengthMismatch`. Returns this contract as the cash-out hook; uses surplus as totalSupply / effectiveSurplusValue. (`Defifa1155Hook.sol:361-428`)

**Transfers:** `_update` skips zero-amount entries, reverts `Defifa1155Hook_TransfersPaused` on paused transfers (burns allowed), moves `tier.votingUnits × amount` attestation units for transfers and burns, and records every move, mints included, in the store with the count form of `recordTransferForTier`. Paid mints (`_mintAll`) and reserve mints (`mintReservesFor`, after attestation units move) both end with `_mintWithAcceptanceCheck`, which runs `_update` and then `Defifa1155HookLib.checkMintAcceptance` by delegatecall, so the hook stays the caller of `onERC1155Received` (one ID) or `onERC1155BatchReceived`. The receiver callback runs after every state change, and a contract beneficiary that rejects it reverts the mint. (`Defifa1155Hook.sol:1222-1274`, `Defifa1155Hook.sol:1025, 1032-1035`, `Defifa1155HookLib.sol:48-58`)

**Views:** ERC-1155 `balanceOf`/`balanceOfBatch`/`isApprovedForAll`, `uri`, `name`, `symbol`, `tierIdOf`, `RESERVE_TOKEN_ID_OFFSET`, `METADATA_ID_TARGET`, `getPastTierAttestationUnitsOf`, `getPastTierTotalAttestationUnitsOf`, `getTierAttestationUnitsOf`, `getTierDelegateOf`, `getTierTotalAttestationUnitsOf`, `tierCashOutWeights`, `tierNameOf`, `cashOutWeightOf` (one ID, or `(ids, amounts)`), `currentSupplyOfTier`, `adjustedPendingReservesFor`, `supportsInterface`, `tokensClaimableFor(ids, amounts)`, `TOTAL_CASHOUT_WEIGHT`, `CODE_ORIGIN`, `DEFIFA_TOKEN`, `BASE_PROTOCOL_TOKEN`, `totalMintCost`, `amountRedeemed`, `baseURI`, `cashOutWeightIsSet`, `contractURI`, `defaultAttestationDelegate`, `gamePhaseReporter`, `gamePotReporter`, `pricingCurrency`, `projectId`, `refundedBurnsFrom`, `rulesets`, `store`, `tokensRedeemedFrom`.

### C.5 DefifaTiersHookStore — `defifa/src/DefifaTiersHookStore.sol`

`JB721TiersHookStore`, unchanged, plus count-based records. Shared by both game types; the ERC-1155 hook requires it. `recordMintCounts` (`DefifaTiersHookStore.sol:46-117`), `recordBurnCounts` (`DefifaTiersHookStore.sol:23-36`) and `recordTransferForTier(tierId, from, to, count)` (`DefifaTiersHookStore.sol:124-147`) apply the same checks and accounting as their per-position counterparts, once per tier, and act only on the calling hook's state (`msg.sender`-keyed, as upstream).

- **Invariant:** for any sequence of mints, burns and transfers, the count functions leave the same supply, reserve, burn, and per-holder tier state as the per-position originals (`test/DefifaTiersHookStore.t.sol`).

### C.6 DefifaTokenUriResolver — `defifa/src/DefifaTokenUriResolver.sol`

Pure rendering surface — no privileged surface that affects game outcome or fund flow. Resolves tier-specific token URIs via `DefifaFontImporter` SVG composition. Reads from the hook's store + tier names; does not write any state that affects accounting. Shared by both game types: it maps a token ID to its tier with the hook's `tierIdOf`, which each hook implements (`DefifaTokenUriResolver.sol:122-123`).

---

## Section D — Cross-cutting invariants

1. **Frozen game configuration.** Once `launchGameWith` returns, the per-game tier prices, reserve frequencies, fees, scorecard timeouts, and ruleset cadence (MINT → REFUND? → SCORING → COMPLETE/NO_CONTEST) are immutable.
2. **Single ratification per game.** `DefifaGovernor.ratifiedScorecardIdOf[gameId] != 0` blocks further submissions and ratifications (`DefifaGovernor.sol` `submitScorecardFor`, `ratifyScorecardFrom`). `cashOutWeightIsSet` on either hook blocks repeated `setTierCashOutWeightsTo` (`DefifaHook.sol:851`, `Defifa1155Hook.sol:875`).
3. **Single commitment fulfillment per game.** `commitmentsFulfilledFor[gameId]` is set before any external call (`DefifaDeployer.sol:371`); re-entry returns early.
4. **Single NO_CONTEST trigger per game.** `noContestTriggeredFor[gameId]` set before queuing the refund ruleset; `NoContestAlreadyTriggered` on second call (`DefifaDeployer.sol:678, 685`).
5. **Reserve mints blocked in NO_CONTEST.** Prevents reviving a failed `minParticipation` game by free-minting reserved face value (`DefifaHook.sol:632-634`, `Defifa1155Hook.sol:686-688`).
6. **Delegate changes restricted to MINT.** Locks voting power before scoring opens (`DefifaHook.sol:873-875, 886-888`, `Defifa1155Hook.sol:897-899, 910-912`).
7. **Referee-only submission, timelocked ratification.** Only `refereeOf[gameId]` submits to the governor; only the pending scorecard, past `timelockDurationOf[gameId]`, ratifies (`DefifaGovernor.sol` `submitScorecardFor`, `stateOf`, `ratifyScorecardFrom`).
8. **Voting referee: BWA snapshot one second before submission.** Excludes the whole submission block, blocking same-block mint/transfer-and-attest injection in either order (`DefifaVotingReferee.sol` `attestToScorecardFrom` / `submitScorecardFor`).
9. **Voting referee: beneficiaries cannot self-attest at full power, revocation only while ACTIVE, first forwarded wins.** BWA reduces tier power by `tierWeight / totalCashOutWeight` and zero-power attestations revert; revocation after SUCCEEDED reverts; `forwardScorecardFor` sends at most one scorecard per game (`DefifaVotingReferee.sol`).
10. **Atomic ratification + commitment.** `ratifyScorecardFrom` calls `fulfillCommitmentsOf` in the same tx, ensuring the COMPLETE ruleset is always queued after weights are set (`DefifaGovernor.sol` `ratifyScorecardFrom`).
11. **State-before-external-call ordering.** `commitmentsFulfilledFor`, `noContestTriggeredFor`, `ratifiedScorecardIdOf`, `forwardedScorecardIdOf`, and `cashOutWeightIsSet` are all written BEFORE the external call that consumes them — re-entrancy cannot replay the action.
12. **Permissionless settlement triggers extract no value beyond canonical allocation.** `fulfillCommitmentsOf`, `triggerNoContestFor`, `mintReservesFor`, `ratifyScorecardFrom`, and the voting referee's `submitScorecardFor`, `attestToScorecardFrom`, `forwardScorecardFor` — caller's reward is exactly the gas-funded service to the game, never a redirected payout.
13. **One-shot bindings.** `initialize` and `setTierCashOutWeightsTo` on either hook, `DefifaGovernor.initializeGame`, `DefifaVotingReferee.initializeGameFor` — all irreversible. `DefifaDeployer`'s own dependencies are constructor `immutable`s (no setter at all).
14. **Front-run-resistant clone deployment.** `cloneDeterministic` salt includes `_msgSender()`; a different resolved caller produces a different address (`DefifaDeployer.sol:602-606`).
15. **Participation immune to balance inflation.** `minParticipation` checks `hook.totalMintCost`, not terminal balance — `addToBalanceOf` donations cannot satisfy the threshold (`DefifaDeployer.sol:303-310`).
16. **Game-piece-only cash-out path.** `beforeCashOutRecordedWith` reverts if fungible project tokens are cashed out (`DefifaHook.sol:342`, `Defifa1155Hook.sol:375-377`). The hook is the sole cash-out surface for Defifa games.
17. **No zero-address delegation.** Neither hook writes or reads `_tierDelegation[address(0)]` for mints, burns, or empty reserve mints (`DefifaHook.sol:649, 1175, 1184`, `Defifa1155Hook.sol:703, 1198, 1207`). Regression tests: `test/regression/AttestationDelegateBeneficiary.t.sol::test_emptyReserveMintDoesNotDelegateTheZeroAddress`, `test/erc1155/regression/ZeroAddressDelegation.t.sol`.
18. **Shared selectors.** The shared deployer, governor, voting referee and resolver call the hook only through selectors both hooks expose (`initialize`, `store`, `currentSupplyOfTier`, `adjustedPendingReservesFor`, `TOTAL_CASHOUT_WEIGHT`, `setTierCashOutWeightsTo`, and the attestation views). Gated by `test/DefifaHookParity.t.sol`.
19. **Reserve positions never refund.** A MINT/REFUND/NO_CONTEST cash-out that includes an `isReserveMint` NFT or a position under `tierId + RESERVE_TOKEN_ID_OFFSET` reverts, including after transfer (`DefifaHookLib.sol:319-321`, `Defifa1155HookLib.sol:182-184`).
20. **ERC-1155 attestation units match balances.** For every holder and tier, attestation units equal (paid + reserve-ID balance) × `tier.votingUnits`; `_update` moves them with every transfer and burn, and mints add them where they mint (`Defifa1155Hook.sol:1142-1144, 733-735, 1261-1263`).
21. **Count records match per-position records.** `DefifaTiersHookStore`'s count functions leave the same store state as the upstream per-position functions (`test/DefifaTiersHookStore.t.sol`).

For the underlying parimutuel game mechanics, pot-formation math, fee pipeline, attacker economics on governance, and parameter design guidance, see **`CRYPTO_ECON.md`**.

---

## Section E — Out-of-scope centralization caveats

These are NOT third-party attack vectors but are powers held by privileged addresses:

- **`DefifaDeployer` dependency wiring** (governor, controller, registry, fee project IDs, hook origin, URI resolver, hook store, trusted forwarder) is fixed at construction as `immutable`s — there is no privileged post-deploy setter. Misconfiguration would require deploying with wrong constructor args (wrong governor, wrong fee project IDs, wrong forwarder, etc.) — operationally caught by deploy script validation.
- **`DefifaGovernor` Ownable owner** can call `initializeGame`. In production deployment this owner is the `DefifaDeployer` (called during `launchGameWith`). If the governor's owner were ever rotated to a non-deployer address, that address could bootstrap rogue scorecards for games it didn't deploy — but only games whose hook ownership it also controls, which would require breaking `DefifaDeployer.launchGameWith`'s `hook.transferOwnership(governor)` flow.
- **Each game's referee decides its result.** The governor checks only the scorecard's shape, the referee's identity, and the timelock. An address referee decides alone; a referee contract is as sound as its rule (see `RISKS.md` §8.9).
- **`DefifaGovernor` as game-hook owner** is the **single ratifier** of every scorecard for games its deployer launched. The governor itself doesn't decide outcomes — it only enforces the referee-only submission and timelock state machine. But the governor's *bytecode* is the source of truth for ratification rules; replacing the governor (via a controller-level migration or hook-ownership transfer) would change the rules. The deploy script intentionally leaves the governor in place and the hooks owned by it — there is no path in this codebase to rotate hook ownership away from the original governor.
- **`DefifaDeployer` as `JBProjects` NFT holder** is the sole `ownerMustSendPayouts` invoker during SCORING (the SCORING ruleset sets `ownerMustSendPayouts=true`). `fulfillCommitmentsOf` is the deployer's `sendPayoutsOf` invocation — and it's permissionless. No human address has owner power over a Defifa game's payouts post-launch.
- **`launchGameWith` caller** picks the `referee`, `refereeData` (for `DefifaVotingReferee`, the attestation start time and grace period), the `defaultAttestationDelegate`, `timelockDuration`, `minParticipation`, `scorecardTimeout`, splits, tier metadata, and reserve beneficiaries. Players opting into a game are trusting the launcher's parameters. The deployer, governor and hook enforce structural bounds (nonzero referee, timelock shorter than the scorecard timeout, valid currency; the voting referee adds a ≥ 1-day grace period), but cannot detect launcher-chosen parameter combinations that economically disadvantage players (e.g. a launcher could allocate 100% of splits to themselves; the protocol's role is to make this fact verifiable on-chain at launch, not to prevent the launcher from offering it).

---

## Section F — Key code references

- Phase view: `defifa/src/DefifaDeployer.sol:279-321`
- Game configuration validation: `defifa/src/DefifaDeployer.sol:437-524`
- Front-run-resistant clone deploy: `defifa/src/DefifaDeployer.sol:597-606`
- Project NFT custody: `defifa/src/DefifaDeployer.sol:532-533`
- Commitment fulfillment single-shot: `defifa/src/DefifaDeployer.sol:368-421`
- NO_CONTEST trigger single-shot + ruleset queue: `defifa/src/DefifaDeployer.sol:670-733`
- Splits fee construction: `defifa/src/DefifaDeployer.sol:739-828`
- SCORING ruleset (`ownerMustSendPayouts=true`): `defifa/src/DefifaDeployer.sol:938-996`
- `minParticipation` check uses `totalMintCost`: `defifa/src/DefifaDeployer.sol:303-310`
- Launch referee check: `defifa/src/DefifaDeployer.sol:497-505`; timeout must exceed timelock: `defifa/src/DefifaDeployer.sol:515-524`; governor init and referee settings call: `defifa/src/DefifaDeployer.sol:634-645`
- Governor `initializeGame` (zero referee + uint48 bound): `defifa/src/DefifaGovernor.sol` `initializeGame`
- Referee-only submit, pending replacement, duplicate rejection: `defifa/src/DefifaGovernor.sol` `submitScorecardFor`
- Timelock states (QUEUED, SUCCEEDED, DEFEATED when replaced): `defifa/src/DefifaGovernor.sol` `stateOf`
- Single ratification per game: `defifa/src/DefifaGovernor.sol` `submitScorecardFor`, `ratifyScorecardFrom`
- Atomic ratify + fulfillCommitments: `defifa/src/DefifaGovernor.sol` `ratifyScorecardFrom`
- Submission rejects unrealizable weights: `defifa/src/DefifaGovernor.sol` `submitScorecardFor`
- Voting referee setup (project owner only, grace period + uint48 bounds): `defifa/src/referees/DefifaVotingReferee.sol` `initializeGameFor`
- Voting referee BWA snapshot at `scorecard.snapshotTimestamp` (submission − 1): set in `submitScorecardFor`, read in `attestToScorecardFrom`
- Voting referee BWA self-attest guard (zero-power revert): `attestToScorecardFrom`; tier-weight reduction: `getBWAAttestationWeight`
- Voting referee revocation gated to ACTIVE: `revokeAttestationFrom`
- Voting referee concentration-adjusted quorum: `submitScorecardFor`, `_quorumOf`, `_maxAttestationWeightOf`
- Voting referee first-forwarded-wins: `forwardScorecardFor`
- Hook `setTierCashOutWeightsTo` (governor-only, SCORING-only, single-shot): `defifa/src/DefifaHook.sol:840-861`, `defifa/src/Defifa1155Hook.sol:864-885`
- Hook `initialize` one-shot: `defifa/src/DefifaHook.sol:553-618`, `defifa/src/Defifa1155Hook.sol:605-672`
- Reserve mints blocked in NO_CONTEST: `defifa/src/DefifaHook.sol:632-634`, `defifa/src/Defifa1155Hook.sol:686-688`
- Reserve mint cap: `defifa/src/DefifaHook.sol:644-645`, `defifa/src/Defifa1155Hook.sol:698-699`
- Empty reserve mint returns before any delegation write: `defifa/src/DefifaHook.sol:649`, `defifa/src/Defifa1155Hook.sol:703`
- Mints and burns never use the zero address's delegate: `defifa/src/DefifaHook.sol:1175, 1184`, `defifa/src/Defifa1155Hook.sol:1198, 1207`
- Delegate changes MINT-only: `defifa/src/DefifaHook.sol:873-875, 886-888`, `defifa/src/Defifa1155Hook.sol:897-899, 910-912`
- Hook cash-out path game-pieces-only: `defifa/src/DefifaHook.sol:342`, `defifa/src/Defifa1155Hook.sol:375-377`
- Hook 0-weight tier `NothingToClaim` guard: `defifa/src/DefifaHook.sol:808-812`, `defifa/src/Defifa1155Hook.sol:832-836`
- Hook overspend guard: `defifa/src/DefifaHook.sol:1135`, `defifa/src/Defifa1155Hook.sol:1158`
- Hook currency-lock guard: `defifa/src/DefifaHook.sol:1070-1074`, `defifa/src/Defifa1155Hook.sol:1087-1091`
- Hook payer ≠ beneficiary delegate guard: `defifa/src/DefifaHook.sol:1112-1117`, `defifa/src/Defifa1155Hook.sol:1134-1139`
- Fee-token claim share (shared formula): `defifa/src/libraries/DefifaHookLib.sol:554-570` (`tokensClaimFor`)
- Per-tier cash-out weight (shared formula): `defifa/src/libraries/DefifaHookLib.sol:226` (`computeTierCashOutWeight`)
- ERC-721 pay tier order (non-decreasing): `defifa/src/libraries/DefifaHookLib.sol:111-158` (`computeAttestationUnits`)
- ERC-721 cash-out ownership check + burn: `defifa/src/DefifaHook.sol:752-781`
- ERC-721 reserve rejection in refunds (`isReserveMint`): `defifa/src/DefifaHook.sol:360-367`, `defifa/src/libraries/DefifaHookLib.sol:319-321`
- ERC-721 transfer pause + attestation movement on transfers/burns: `defifa/src/DefifaHook.sol:1196-1230`
- ERC-1155 pay metadata validation (ascending tiers, non-zero counts, equal lengths): `defifa/src/libraries/Defifa1155HookLib.sol:66-93` (`computeAttestationUnits`)
- ERC-1155 cash-out holder balance check + batch burn: `defifa/src/Defifa1155Hook.sol:785-808`
- ERC-1155 reserve-ID rejection in refunds: `defifa/src/Defifa1155Hook.sol:397-404`, `defifa/src/libraries/Defifa1155HookLib.sol:182-184`
- ERC-1155 token ID → tier mapping (`RESERVE_TOKEN_ID_OFFSET = 1 << 16`): `defifa/src/libraries/Defifa1155HookLib.sol:37, 272-275`
- ERC-1155 mints end with the receiver acceptance check: `defifa/src/Defifa1155Hook.sol:1025, 1032-1035`, `defifa/src/libraries/Defifa1155HookLib.sol:48-58` (`checkMintAcceptance`)
- ERC-1155 transfer pause + attestation movement on transfers/burns: `defifa/src/Defifa1155Hook.sol:1222-1274`
- Count-based store records: `defifa/src/DefifaTiersHookStore.sol:23-36, 46-117, 124-147`
- Resolver tier lookup via `tierIdOf`: `defifa/src/DefifaTokenUriResolver.sol:122-123`

For the game's economic model and rational-actor analysis, see `CRYPTO_ECON.md`.
