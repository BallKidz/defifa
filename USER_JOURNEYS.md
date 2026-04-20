# User Journeys

## Repo Purpose

This repo turns a Juicebox project into a prediction-game lifecycle with fixed phase timing, tiered outcome pieces, attestation-based scorecard governance, and final cash-out weights that decide how the pot settles. It owns Defifa's game-specific launch, scoring, no-contest, and settlement logic.

## Primary Actors

- game creators launching a new Defifa market with fixed timing, tiers, and fee routing
- players minting outcome pieces during MINT and later redeeming or refunding them
- attestors and delegates submitting, supporting, revoking, and ratifying scorecards during SCORING
- auditors tracing where game fairness depends on shared 721-store behavior, governor state, and core terminal flows
- operators handling no-contest recovery or optional fee-project ownership locking

## Key Surfaces

- `DefifaDeployer.launchGameWith(...)`: launches a Defifa game as a JB project and wires hook, governor, splits, and lifecycle timing
- `DefifaHook.afterPayRecordedWith(...)`: mints outcome NFTs when players pay during the mintable phase
- `DefifaHook.beforeCashOutRecordedWith(...)` and `afterCashOutRecordedWith(...)`: define refund, winning-piece redemption, and fee-token claim behavior
- `DefifaGovernor.submitScorecardFor(...)`, `attestToScorecardFrom(...)`, `revokeAttestationFrom(...)`, `ratifyScorecardFrom(...)`: scorecard governance lifecycle
- `DefifaDeployer.fulfillCommitmentsOf(...)` and `triggerNoContestFor(...)`: finalize commitments after ratification or unlock refund-oriented no-contest recovery

## Journey 1: Launch A Defifa Game

**Actor:** game creator.

**Intent:** launch a prediction game with fixed timing, tiers, fee routing, and governance rules.

**Preconditions**

- the creator knows the game start time, mint duration, optional refund duration, and scoring-timeout assumptions
- tier count, tier names, tier price, and split commitments are finalized
- the chosen terminal and payment token are correct because the launch path is intentionally one-way

**Main Flow**

1. Prepare launch data with timing, tiers, splits, fee-project settings, terminal, and governance params.
2. Call `DefifaDeployer.launchGameWith(...)`.
3. The deployer launches the JB project, clones and initializes `DefifaHook`, initializes the governor state, and stores the game's immutable ops data.
4. The game now advances through its documented phase sequence.

**Failure Modes**

- launch parameters are wrong, but the creator assumes they can patch them later
- fee routing, token decimals, or terminal assumptions drift from the terminal actually configured
- the creator mistakes permissionless launch for ongoing admin power

**Postconditions**

- the game exists as a staged JB project with Defifa-specific lifecycle wiring

## Journey 2: Mint Outcome Pieces During Open Play

**Actor:** player.

**Intent:** buy one or more outcome pieces during the mint phase.

**Preconditions**

- the game is in the mintable phase
- the selected tier exists and is still mintable

**Main Flow**

1. Pay the game project during the mint window.
2. `DefifaHook` mints the selected outcome NFT tier.
3. Delegation and mint-cost accounting are updated.
4. Reserved mints and pending reserves continue to matter for later governance and settlement.

**Failure Modes**

- mint is attempted in the wrong phase
- assumptions about attestation power ignore pending reserves or tier weighting

**Postconditions**

- the player holds game pieces that later affect governance and settlement

## Journey 3: Submit And Ratify A Scorecard

**Actor:** proposer, attestor, or delegate.

**Intent:** turn the game's result into a ratified scorecard.

**Preconditions**

- the game is in SCORING
- the actor understands quorum, grace-period, and timeout rules

**Main Flow**

1. Submit a scorecard candidate.
2. Attest or revoke while the scorecard is active.
3. Wait for quorum and the grace period.
4. Ratify one winning scorecard.

**Failure Modes**

- attestation power is concentrated enough to capture the result
- timeout is reached before ratification
- integrations misread live attestation power or pending-reserve dilution

**Postconditions**

- exactly one scorecard can become the game's final outcome, or the game moves toward no-contest handling

## Journey 4: Fulfill Commitments And Settle The Game

**Actor:** completion path caller.

**Intent:** turn the ratified scorecard into final redeemable economics.

**Preconditions**

- a scorecard has been ratified
- the fulfillment path has not already run

**Main Flow**

1. Read the ratified outcome.
2. Call `fulfillCommitmentsOf(...)`.
3. Queue the completion ruleset and finalize the promised commitment flow.
4. Let winning-piece holders redeem under the installed cash-out weights.

**Failure Modes**

- ratification succeeds but fulfillment is never run
- commitment logic or fee accounting drifts from the documented outcome

**Postconditions**

- the game enters its final redeemable state

## Journey 5: Enter No-Contest And Unlock Refund Recovery

**Actor:** any caller when the no-contest conditions are met.

**Intent:** move a game out of failed scoring and into the documented refund-oriented fallback path.

**Preconditions**

- the game has hit its no-contest conditions
- the caller understands that `NO_CONTEST` and active refund rules are related but not identical states

**Main Flow**

1. Call `triggerNoContestFor(...)` when the timeout or participation conditions make the game ineligible for normal settlement.
2. Queue the no-contest recovery ruleset.
3. Let players exit under the fallback path once the queued ruleset becomes active.

**Failure Modes**

- integrators assume same-transaction full refunds immediately after the trigger
- the game becomes stuck because nobody triggers the no-contest path

**Postconditions**

- the game moves onto the documented no-contest recovery track

## Trust Boundaries

- this repo is trusted for game-specific phase logic, governance, and settlement weighting
- terminal accounting still comes from `nana-core-v6`
- shared tier-storage behavior still comes from `nana-721-hook-v6`

## Hand-Offs

- Use [nana-core-v6](../nana-core-v6/USER_JOURNEYS.md) for underlying treasury and terminal behavior.
- Use [nana-721-hook-v6](../nana-721-hook-v6/USER_JOURNEYS.md) for shared tier-store and reserve semantics that Defifa builds on.
