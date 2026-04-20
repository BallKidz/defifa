# Defifa Risk Register

This file focuses on the game-theoretic, governance, and settlement risks in Defifa's prediction-game flow: minting, attestation, scorecard ratification, and final cash out.

## How to use this file

- Read `Priority risks` first.
- Use the detailed sections below to reason about governor power, live supply assumptions, and downstream hook dependencies.
- Treat `Accepted Behaviors` and `Invariants to Verify` as explicit boundaries for audit scope.

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
- **Default attestation delegate.** If set, it can accumulate meaningful governance power across new minters.

## 2. Economic Risks

- **Scorecard manipulation via quorum.** Enough attestation power can redirect the whole pot.
- **Supply and pending-reserve drift.** Governance and settlement both depend on correct reserve-aware denominators.
- **Cash-out-weight truncation.** Integer division can lock small dust amounts.
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

### 8.5 One-tier games always resolve via no-contest

A single-tier game cannot complete normal governance because the governance attestation model gives zero weight to holders of a tier that receives 100% of the scorecard, making quorum unreachable. This is expected: the game falls through to `NO_CONTEST` once `scorecardTimeout` elapses, and players recover their mint price via the permissionless `triggerNoContestFor()` refund path that queues a refund ruleset. This only works when `scorecardTimeout > 0`. A one-tier game launched with `scorecardTimeout = 0` disables the timeout path entirely, and funds become permanently locked with no exit. Game deployers must ensure `scorecardTimeout > 0` for single-tier configurations.
