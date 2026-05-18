# Defifa Risk Register

This file focuses on the game-theoretic, governance, and settlement risks in Defifa's prediction-game flow: minting, attestation, scorecard ratification, and final cash out.

## How to use this file

- Read `Priority risks` first.
- Use the detailed sections below to reason about governor power, live supply assumptions, and downstream hook dependencies.
- Treat `Accepted Behaviors` and `Invariants to Verify` as explicit boundaries for review scope.

## Priority risks

| Priority | Risk | Why it matters | Primary controls |
|----------|------|----------------|------------------|
| P0 | Scorecard capture at quorum | An actor that assembles enough attestation power can ratify an arbitrary scorecard and redirect the pot. | Tier-level attestation caps, grace period, and governance review of delegate concentration. |
| P1 | Shared 721-hook store blast radius | Defifa inherits the same shared `JB721TiersHookStore` surface as the general 721-hook ecosystem. | Reuse of 721-hook invariants, store-focused testing, and ecosystem-level monitoring. |
| P1 | Supply and reserve accounting drift | Game fairness depends on attestation power, fee-token dilution, and cash-out weights tracking real mint and reserve state. | Explicit invariants on supply, reserve inclusion, and tier-weight arithmetic. |

## 1. Trust Assumptions

- **Governor as hook owner.** The governor can set tier cash-out weights through ratification.
- **Deployer as project owner.** The deployer owns game projects and controls ruleset queuing and commitment fulfillment.
- **DefifaProjectOwner irrecoverability.** Once the project NFT is transferred there, it cannot be recovered.
- **External dependencies.** Core protocol and shared 721-store behavior remain upstream trust boundaries.
- **Terminal provenance is the launcher's responsibility.** The hook authenticates terminals via directory registration, not implementation identity. A game is only as trustworthy as the terminal its launcher chose. Users must verify a game's terminal before participating.
- **Default attestation delegate.** If set, it can accumulate meaningful governance power across new minters.

## 2. Economic Risks

- **Scorecard manipulation via quorum.** Enough attestation power can redirect the whole pot. Once a coalition reaches the BWA (best winning attestation) quorum threshold, they can lock in a scorecard that favors their tiers. The grace period is the primary defense window for other participants to revoke attestations.
- **BWA quorum lockout.** If a scorecard reaches quorum and the grace period elapses before opponents can revoke, the scorecard becomes ratifiable. In games with concentrated attestation power (few large holders), quorum may be reached quickly, leaving little time for the grace period defense to be effective.
- **Supply and pending-reserve drift.** Governance and settlement both depend on correct reserve-aware denominators.
- **Cash-out-weight truncation.** Integer division can lock small dust amounts.
- **Commitment fee rounding to zero.** When commitment amounts are small relative to the fee percent, `mulDiv(amount, feePercent, MAX_FEE)` can round down to zero, allowing tiny commitments to bypass fees entirely. This is economically insignificant for practical game sizes but means fee accounting is not perfectly tight at dust amounts.
- **Fee-token dilution from reserved mints.** Reserved mints can dilute fee-token shares even though no ETH was paid for them.
- **128-tier settlement ceiling.** Games that rely on more than 128 scored tiers can fail settlement.

## 3. Governance Risks

- **Single governor instance across games.** A bug in the governor affects every game that uses it.
- **Scorecard timeout can block legitimate ratification.** Once timeout is reached, the game may have to fall into no-contest even if a scorecard was close to success.
- **Delegation is phase-sensitive.** Some delegation behavior freezes after mint phase.
- **No-contest requires an explicit trigger.** The fallback path does not activate itself just because the timeout happened.
- **No-contest trigger is not the same as active refund state.** Integrators must distinguish queued recovery from currently active refund rules.

## 4. Reentrancy Surface

- **`afterCashOutRecordedWith`.** Burns happen before external fee-token transfers, which narrows the surface, but transfer compatibility still matters.
- **Ratification uses a low-level call into the hook.** Double-set protections must hold.

## 5. DoS Vectors

- **Tier iteration in governance.** Quorum and attestation-weight calculations scale with tier count.
- **Large split arrays.** User-provided split arrays can increase gas and complexity even if practical counts stay bounded.

## 6. Integration Risks

- **Immutable phase timing.** Once deployed, the game timeline cannot be edited.
- **Permanent cash-out weights.** A ratified scorecard is final.
- **No deployer upgrade path.** Bugs require a new deployer, not an in-place fix.
- **Clone initialization assumptions matter.** Per-game clone setup must stay correct.

## 7. Invariants to Verify

- `_totalMintCost` stays consistent with live tier state and burns.
- Total cash-outs plus remaining surplus match the pre-fulfillment pot minus intended fees.
- Scorecard weights sum to `TOTAL_CASHOUT_WEIGHT`.
- Attestation units are conserved across transfers and delegation.
- `fulfilledCommitmentsOf[gameId]` is set at most once.
- Per-tier supply never exceeds `initialSupply`.

## 8. Accepted Behaviors

### 8.1 Scorecard timeout is intentionally irreversible

If timeout elapses before ratification, the game can permanently move toward `NO_CONTEST`. This bounds how long funds can remain locked in unresolved governance.

### 8.2 Permanent cash-out weights

Once cash-out weights are installed through a valid ratification path, they cannot be corrected in place. The design prefers determinism over mutable post-hoc fixes.

### 8.3 `fulfillCommitmentsOf` and ratification are deliberately guarded

Completion and ratification paths use one-way state to prevent replay or double-finalization.

### 8.4 Pending reserves are intentionally included in governance and fee-accounting logic

This is conservative, but it prevents users from front-running reserve dilution out of governance power or fee-token distribution.

### 8.5 Launcher-selected terminals are trusted per game

`DefifaDeployer.launchGameWith(...)` is permissionless and allows the launcher to choose the terminal registered for the game. `DefifaHook` trusts any registered terminal as the source of pay and cash-out callbacks. This means a malicious launcher can register a callback-forging terminal that fabricates hook contexts without recording real payments. Users and integrators must verify a game's registered terminal before trusting or participating in it. The same applies to scorecard timing parameters and tier configuration — a game's safety depends on the launcher choosing sane inputs. Frontends and aggregators should cross-reference a game's terminal against the canonical `JBMultiTerminal` for the chain before displaying it as trustworthy.

### 8.6 One-tier games always resolve via no-contest

A single-tier game cannot complete normal governance because the governance attestation model gives zero weight to holders of a tier that receives 100% of the scorecard, making quorum unreachable. This is expected: the game falls through to `NO_CONTEST` once `scorecardTimeout` elapses, and players recover their mint price via the permissionless `triggerNoContestFor()` refund path that queues a refund ruleset. This only works when `scorecardTimeout > 0` — a one-tier game launched with `scorecardTimeout = 0` would disable the timeout path entirely and leave funds permanently locked. `DefifaDeployer.launchGameWith` now enforces this at the contract level: a one-tier game with `scorecardTimeout == 0` reverts with `DefifaDeployer_InvalidGameConfiguration`. Two-tier games are still rounding-fragile in the same direction and should also be launched with a nonzero `scorecardTimeout`, but this is not enforced because some two-tier configurations can still reach quorum.

### 8.7 Commitment splits are responsible for never reverting

`DefifaDeployer.fulfillCommitmentsOf` calls `terminal.sendPayoutsOf` to distribute the commitment portion of the pot. Core processes splits inside a try/catch — when an individual split reverts (rejecting split hook, recipient terminal that does not accept the game token, fee project with a missing currency feed) the failed amount is silently re-credited to the game's terminal balance and the outer call succeeds. The unpaid commitment funds then remain available to game players via the cash-out path.

This means **a single bad split cannot block the others from being paid**, and the unpaid funds are never lost — but it also means the recipient configured behind the failing split does not get paid through `fulfillCommitmentsOf` and must be settled separately if the game launcher cares. Game launchers are responsible for configuring commitment splits that will not revert under the game's terminal/currency setup. Recipients of commitment splits should treat split delivery as best-effort; the canonical post-game pot accounting still holds.

`fulfilledCommitmentsOf[gameId]` always equals the requested commitment amount whenever any portion was attempted, regardless of whether every split succeeded. `currentGamePotOf(gameId, true)` adds this back to the remaining balance so the displayed pot represents the original pre-commitment value, but the actual on-terminal balance may be higher than the displayed pot when splits silently failed — by exactly the failed split amounts, which remain redeemable by game players. The bound therefore stays one-sided: real balance ≥ reported pot.

### 8.9 `DefifaProjectOwner.onERC721Received` accepts any project NFT and grants `SET_SPLIT_GROUPS` on its ID

`DefifaProjectOwner.onERC721Received` (line 53) checks `msg.sender == address(PROJECTS)` but explicitly discards the `from` argument (`from;` at line 63). It then calls `PERMISSIONS.setPermissionsFor` to grant `SET_SPLIT_GROUPS` to the deployer for the received `tokenId`, regardless of whether the transfer was a mint or a stray transfer of an existing project NFT.

Anyone holding any project NFT can `safeTransferFrom` it to this contract and trigger a real on-chain permission grant: the DEPLOYER address gains `SET_SPLIT_GROUPS` authority on whatever projectId was transferred. The grant is dormant in current code because `DefifaDeployer` only invokes `SET_SPLIT_GROUPS` on its own `DEFIFA_PROJECT_ID` lifecycle, but it is a real grant and would activate if any future deployer code path acts on caller-supplied project IDs. The same shape exists in `CTProjectOwner` (croptop) for the `ADJUST_721_TIERS` permission and was previously fixed for `JBOmnichainDeployer.onERC721Received` (finding 72).

Accepted because the grants are dormant against the current deployer surface and the receiving contract's project (the Defifa fee/governance project) is never the recipient of a hostile transfer in canonical flows. Anyone integrating `DefifaProjectOwner` into a deployer that operates on arbitrary projectIds must add the `require(from == address(0))` guard before relying on it.

### 8.8 Reserve minting is blocked during NO_CONTEST

`DefifaHook.mintReservesFor` reverts with `DefifaHook_ReservedTokenMintingBlockedInNoContest` once `currentGamePhaseOf` reports `NO_CONTEST`. Reserve mints inflate `totalMintCost` so reserved recipients can claim a proportional share of fee tokens. Without this block, a game that failed `minParticipation` could be revived back into a SCORING-eligible state via free notional face value (reserves bump `totalMintCost` over the threshold) before `triggerNoContestFor()` latches the failure into a refund ruleset. The block tightens the §8.4 trust assumption that pending reserves are folded into governance and fee accounting: that remains true while the game is live, but once a game has already failed participation the reserve channel is closed so the no-contest outcome is final.
