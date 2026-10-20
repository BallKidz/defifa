# Defifa Risk Register

This file focuses on the game-theoretic, governance, and settlement risks in Defifa's prediction-game flow: minting, the referee's scorecard, ratification, and final cash out.

## How to use this file

- Read `Priority risks` first.
- Use the detailed sections below to reason about governor power, live supply assumptions, and downstream hook dependencies.
- Treat `Accepted Behaviors` and `Invariants to Verify` as explicit boundaries for review scope.

## Priority risks

| Priority | Risk | Why it matters | Primary controls |
|----------|------|----------------|------------------|
| P0 | Scorecard capture | The referee decides the result. An address referee can submit any scorecard. Under `DefifaVotingReferee`, an outsider buying thin tiers, holders of more than half the tiers, or bribed holders who lose nothing can ratify a false scorecard (§8.9). | Choose the referee before minting; the governor's timelock makes every scorecard public before ratification; `scorecardTimeout` refunds a game whose referee never acts. Under the voting referee: BWA, the 50% to 75% quorum, the 1-day minimum grace period, and default delegation. |
| P1 | Shared 721-hook store blast radius | Defifa inherits the same shared `JB721TiersHookStore` surface as the general 721-hook ecosystem. | Reuse of 721-hook invariants, store-focused testing, and ecosystem-level monitoring. |
| P1 | Hook selector drift between game types | `DefifaDeployer`, `DefifaGovernor`, `DefifaVotingReferee` and `DefifaTokenUriResolver` call the hook by selector and are shared by `DefifaHook` (ERC-721) and `Defifa1155Hook` (ERC-1155). A selector one hook drops or changes breaks launch, ratification, or rendering for that game type. | `test/DefifaHookParity.t.sol` checks both hooks expose the selectors the shared contracts call; shared rules live in `DefifaHookLib`. |
| P1 | Supply and reserve accounting drift | Game fairness depends on attestation power, fee-token dilution, and cash-out weights tracking real mint and reserve state. | Explicit invariants on supply, reserve inclusion, and tier-weight arithmetic. |

## 1. Trust assumptions

- **Governor as hook owner.** The governor can set tier cash-out weights through ratification, and only for a scorecard the game's referee submitted.
- **Referee.** Each game's referee decides its result (§8.9). The governor checks only the scorecard's shape and the timelock.
- **Deployer as project owner.** The deployer owns game projects and controls ruleset queuing and commitment fulfillment.
- **External dependencies.** Core protocol and shared 721-store behavior remain upstream trust boundaries. Both game types record tiers through `DefifaTiersHookStore`, whose count-based records must stay equivalent to the upstream per-position ones. In an ERC-1155 game, the store's per-holder views count a tier's paid and reserve IDs together; use `hook.balanceOf(account, id)` to tell them apart.
- **Terminal provenance is the launcher's responsibility.** The hook authenticates terminals via directory registration, not implementation identity. A game is only as trustworthy as the terminal its launcher chose. Users must verify a game's terminal before participating.
- **Default attestation delegate.** If set, it can accumulate meaningful attestation power across new minters in a game whose referee counts holder votes.

## 2. Economic risks

- **Scorecard capture.** Whoever controls the referee controls the pot (§8.9).
- **Voting referee lockout.** Under `DefifaVotingReferee`, a scorecard at quorum when the grace period ends can be forwarded at once, and the first one forwarded is final. Revocation stops once the grace period has ended with quorum met (a scorecard short of quorum stays `ACTIVE` and revocable), so the grace period is the window to revoke. The governor's timelock that follows gives notice but cannot be used to replace the forwarded scorecard.
- **Supply and pending-reserve drift.** Governance and settlement both depend on correct reserve-aware denominators.
- **Cash-out-weight truncation.** Integer division can lock small dust amounts.
- **Commitment fee rounding to zero.** When commitment amounts are small relative to the fee percent, `mulDiv(amount, feePercent, MAX_FEE)` can round down to zero, allowing tiny commitments to bypass fees entirely. This is economically insignificant for practical game sizes but means fee accounting is not perfectly tight at dust amounts.
- **Fee-token dilution from reserved mints.** Reserved mints can dilute fee-token shares even though no ETH was paid for them.
- **128-tier settlement ceiling.** Games that rely on more than 128 scored tiers can fail settlement.

## 3. Governance risks

- **Single governor instance across games.** A bug in the governor affects every game that uses it. Each game type has its own governor deployment, but both run the same `DefifaGovernor` code. One `DefifaVotingReferee` deployment serves every game that names it, of both types.
- **A referee can replace its pending scorecard.** Each new submission restarts the timelock. A referee that submits late, or a referee contract that lets competing results replace each other, can push the game past `scorecardTimeout`. `DefifaVotingReferee` forwards only the first approved scorecard for this reason.
- **The deployer checks only `scorecardTimeout > timelockDuration`.** A voting referee's attestation delay and grace period are not checked against the timeout; a game whose windows don't fit ends in no-contest.
- **Scorecard timeout can block legitimate ratification.** Once timeout is reached, the game may have to fall into no-contest even if a scorecard was close to success.
- **Delegation is phase-sensitive.** Some delegation behavior freezes after mint phase.
- **No-contest requires an explicit trigger.** The fallback path does not activate itself just because the timeout happened.
- **No-contest trigger is not the same as active refund state.** Integrators must distinguish queued recovery from currently active refund rules.

## 4. Reentrancy surface

- **`afterCashOutRecordedWith`.** Burns happen before external fee-token transfers, which narrows the surface, but transfer compatibility still matters.
- **ERC-1155 mints and transfers.** `Defifa1155Hook` pay and reserve mints call the beneficiary's `onERC1155Received` / `onERC1155BatchReceived` when it is a contract (`DefifaHook`'s `_mint` calls no receiver). The call runs after every state change in the mint (store records, `totalMintCost`, attestation units), so a reentrant call sees final state. A beneficiary that rejects the call makes that pay revert; a rejecting reserve beneficiary blocks only its own tier's reserve mints. Holder transfers (`safeTransferFrom`, `safeBatchTransferFrom`) are standard ERC-1155 safe transfers that call `onERC1155Received` / `onERC1155BatchReceived` on contract recipients after balances and attestation units move.
- **Ratification uses a low-level call into the hook.** Double-set protections must hold.

## 5. DoS vectors

- **Tier iteration in the voting referee.** Quorum and attestation-weight calculations in `DefifaVotingReferee` scale with tier count.
- **Store fork drift.** `DefifaTiersHookStore` inherits the upstream store and adds count-based records. An upstream store change that alters per-position semantics must be mirrored in the count functions; `test/DefifaTiersHookStore.t.sol` fuzzes their equivalence.
- **Large split arrays.** User-provided split arrays can increase gas and complexity even if practical counts stay bounded.

## 6. Integration risks

- **Immutable phase timing.** Once deployed, the game timeline cannot be edited.
- **Permanent cash-out weights.** A ratified scorecard is final.
- **No deployer upgrade path.** Bugs require a new deployer, not an in-place fix.
- **Clone initialization assumptions matter.** Per-game clone setup must stay correct.
- **Two game types coexist.** ERC-721 and ERC-1155 games use different pay and cash-out metadata layouts and holdings reads. Integrators must detect the hook kind (for example `supportsInterface(type(IERC1155).interfaceId)`) before encoding metadata or reading holdings, and pick the deployer for the game type they launch.
- **Two hook implementations must keep the selectors the shared deployer, governor and resolver call.** A change to one hook's interface that drops or alters a shared selector breaks that game type. Gated by `test/DefifaHookParity.t.sol`.

## 7. Invariants to verify

- `_totalMintCost` stays consistent with live tier state and burns (`test/DefifaMintCostInvariant.t.sol` and `test/erc1155/DefifaMintCostInvariant.t.sol`, each gated by `afterInvariant` so every run mints and refunds).
- Total cash-outs plus remaining surplus match the pre-fulfillment pot minus intended fees.
- Scorecard weights sum to `TOTAL_CASHOUT_WEIGHT`.
- Attestation units are conserved across transfers and delegation. In an ERC-1155 game they equal (paid + reserve-ID balance) × `tier.votingUnits` per holder and tier.
- `_tierDelegation[address(0)]` is never written or read for mints and burns, in either hook.
- Reserve positions cannot be refunded: a MINT/REFUND/NO_CONTEST cash-out that includes one reverts (`DefifaHook_CantRefundReserveMint` for `isReserveMint` NFTs, `Defifa1155Hook_CantRefundReserveMint` for `tierId + RESERVE_TOKEN_ID_OFFSET` IDs), including after transfer. Reserves exist only from SCORING on, so in practice this applies in NO_CONTEST.
- `fulfilledCommitmentsOf[gameId]` is set at most once.
- Per-tier supply never exceeds `initialSupply`.

## 8. Accepted behaviors

### 8.1 Scorecard timeout is intentionally irreversible

If timeout elapses before ratification, the game can permanently move toward `NO_CONTEST`. This bounds how long funds can remain locked in unresolved governance.

### 8.2 Permanent cash-out weights

Once cash-out weights are installed through a valid ratification path, they cannot be corrected in place. The design prefers determinism over mutable post-hoc fixes.

### 8.3 `fulfillCommitmentsOf` and ratification are deliberately guarded

Completion and ratification paths use one-way state to prevent replay or double-finalization.

### 8.4 Pending reserves are intentionally included in governance and fee-accounting logic

This is conservative, but it prevents users from front-running reserve dilution out of governance power or fee-token distribution.

### 8.5 Launcher-selected terminals are trusted per game

`DefifaDeployer.launchGameWith(...)` is permissionless and allows the launcher to choose the terminal registered for the game. `DefifaHook` (and `Defifa1155Hook`) trusts any registered terminal as the source of pay and cash-out callbacks. This means a malicious launcher can register a callback-forging terminal that fabricates hook contexts without recording real payments. Users and integrators must verify a game's registered terminal before trusting or participating in it. The same applies to scorecard timing parameters and tier configuration — a game's safety depends on the launcher choosing sane inputs. Frontends and aggregators should cross-reference a game's terminal against the canonical `JBMultiTerminal` for the chain before displaying it as trustworthy.

### 8.6 One-tier games always resolve via no-contest

A single-tier game whose referee is `DefifaVotingReferee` cannot complete scoring, because BWA gives zero weight to holders of a tier that receives 100% of the scorecard, making quorum unreachable. (An address referee can ratify a one-tier game.) More generally, a voting-referee scorecard passes only if holders of enough of its possible power can attest: pending reserves count in each tier's frozen total but can't attest, so mint and delegate reserves before a scorecard is submitted, since minting later doesn't change that scorecard's snapshot. This is expected: the game falls through to `NO_CONTEST` once `scorecardTimeout` elapses, and players recover their mint price via the permissionless `triggerNoContestFor()` refund path that queues a refund ruleset. `DefifaDeployer.launchGameWith` rejects every game with `scorecardTimeout == 0` (`DefifaDeployer_InvalidGameConfiguration`), so this path always exists. Under the voting referee, a game with two or more eligible tiers can always reach quorum through unanimous non-beneficiary attestation: quorum never exceeds 75% of the attestation possible, and BWA rounding loses far less than the 25% margin.

### 8.7 Commitment splits are responsible for never reverting

`DefifaDeployer.fulfillCommitmentsOf` calls `terminal.sendPayoutsOf` to distribute the commitment portion of the pot. Core processes splits inside a try/catch — when an individual split reverts (rejecting split hook, recipient terminal that does not accept the game token, fee project with a missing currency feed) the failed amount is silently re-credited to the game's terminal balance and the outer call succeeds. The unpaid commitment funds then remain available to game players via the cash-out path.

This means **a single bad split cannot block the others from being paid**, and the unpaid funds are never lost — but it also means the recipient configured behind the failing split does not get paid through `fulfillCommitmentsOf` and must be settled separately if the game launcher cares. Game launchers are responsible for configuring commitment splits that will not revert under the game's terminal/currency setup. Recipients of commitment splits should treat split delivery as best-effort; the canonical post-game pot accounting still holds.

`fulfilledCommitmentsOf[gameId]` always equals the requested commitment amount whenever any portion was attempted, regardless of whether every split succeeded. `currentGamePotOf(gameId, true)` adds this back to the remaining balance so the displayed pot represents the original pre-commitment value, but the actual on-terminal balance may be higher than the displayed pot when splits silently failed — by exactly the failed split amounts, which remain redeemable by game players. The bound therefore stays one-sided: real balance ≥ reported pot.

### 8.8 Reserve minting is blocked during NO_CONTEST

`DefifaHook.mintReservesFor` reverts with `DefifaHook_ReservedTokenMintingBlockedInNoContest` (`Defifa1155Hook_ReservedTokenMintingBlockedInNoContest` in the ERC-1155 game) once `currentGamePhaseOf` reports `NO_CONTEST`. Reserve mints inflate `totalMintCost` so reserved recipients can claim a proportional share of fee tokens. Without this block, a game that failed `minParticipation` could be revived back into a SCORING-eligible state via free notional face value (reserves bump `totalMintCost` over the threshold) before `triggerNoContestFor()` latches the failure into a refund ruleset. The block tightens the §8.4 trust assumption that pending reserves are folded into governance and fee accounting: that remains true while the game is live, but once a game has already failed participation the reserve channel is closed so the no-contest outcome is final.

### 8.9 A game is as safe as its referee

The governor counts no votes. Each game names one referee at launch, and only the referee submits scorecards. The governor's timelock makes each submission public before anyone can ratify it, and `scorecardTimeout` refunds every player if nothing is ratified in time. Nothing else checks the result.

**An address referee decides alone.** A person or multisig referee can submit any scorecard, and a new submission replaces the pending one. Trust it as you'd trust a bookmaker. Frontends should show `DefifaGovernor.refereeOf(gameId)` before a player mints.

**The voting referee can be captured.** `DefifaVotingReferee` counts holder attestations with benefit-weighted attestation (BWA): each tier carries the same power, scaled down by the tier's share of the scorecard, and a scorecard passes at 50% (even split) to 75% (winner-take-all) of the power possible, `(N - 1) * MAX_ATTESTATION_POWER_TIER`. The quorum is a share of aggregate losing-tier power, not of each losing tier. It can be captured three ways:

- **An outsider buys the votes of thin tiers.** Each tier carries equal power however little money is in it. Buying most of the cheapest tiers buys most of the power, at a fraction of the pot.
- **Holders of more than half the tiers vote to split the pot among their own tiers.** A tier's power falls only by its own share of the scorecard. When the pot is spread over many tiers, that 1 − share discount is small, and the coalition meets the low quorum an even split needs without anyone outside it.
- **Holders who lose nothing by a result can be paid to sign it.** Holders of tiers that get nothing under both the true and the false scorecard carry full power and have no stake in which one passes. A bribe smaller than the pot moves them.

The reverse also holds: holders of a large enough share of the losing side can force a refund by withholding. A winner-take-all scorecard needs 75% of losing-tier power, so withholding more than 25% blocks it, and losers recover their stake in `NO_CONTEST`.

Default delegation, the 1-day minimum grace period, revocation while ACTIVE, and the governor's timelock make these attacks public and slower. They do not stop a coalition that holds the power. Games that need more should name a different referee.

**A referee contract must guard its settings.** `initializeGameFor` must accept calls only from the game's project owner, or anyone could rewrite a game's settings.
