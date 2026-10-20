# User Journeys

## Repo purpose

This repo turns a Juicebox project into a prediction-game lifecycle with fixed phase timing, tiered outcome pieces, a referee that submits each game's scorecard, and final cash-out weights that decide how the pot settles. It owns Defifa's game-specific launch, scoring, no-contest, and settlement logic.

## Primary actors

- game creators launching a new Defifa market with fixed timing, tiers, and fee routing
- players minting outcome pieces during MINT and later redeeming or refunding them
- referees submitting scorecards during SCORING, and anyone ratifying them after the timelock
- holders and delegates attesting to and revoking from scorecards in a game whose referee is `DefifaVotingReferee`
- developers writing referee contracts
- auditors tracing where game fairness depends on shared 721-store behavior, governor state, and core terminal flows
- operators handling no-contest recovery or optional fee-project ownership locking

## Key surfaces

- `DefifaDeployer.launchGameWith(...)`: launches a Defifa game as a JB project and wires hook, governor, splits, and lifecycle timing
- `DefifaHook.afterPayRecordedWith(...)`: mints outcome NFTs when players pay during the mintable phase (ERC-721 game)
- `Defifa1155Hook.afterPayRecordedWith(...)`: mints outcome positions (ERC-1155 balances, token ID = tier ID) when players pay during the mintable phase (ERC-1155 game)
- `beforeCashOutRecordedWith(...)` and `afterCashOutRecordedWith(...)` on either hook: define refund, winning-piece redemption, and fee-token claim behavior
- `DefifaGovernor.submitScorecardFor(...)` (referee only) and `ratifyScorecardFrom(...)` (anyone, after the timelock): scorecard lifecycle
- `DefifaVotingReferee.submitScorecardFor(...)`, `attestToScorecardFrom(...)`, `revokeAttestationFrom(...)`, `forwardScorecardFor(...)`: the sample referee's holder vote
- `DefifaDeployer.fulfillCommitmentsOf(...)` and `triggerNoContestFor(...)`: finalize commitments after ratification or unlock refund-oriented no-contest recovery

## Journey 1: Launch a Defifa game

**Actor:** game creator.

**Intent:** launch a prediction game with fixed timing, tiers, fee routing, and governance rules.

**Preconditions**

- the creator knows the game start time, mint duration, optional refund duration, and scoring-timeout assumptions
- tier count, tier names, tier price, and split commitments are finalized
- the chosen terminal and payment token are correct because the launch path is intentionally one-way
- if `JBProjects` has a creation fee, the direct caller or trusted forwarder sends that exact native-token amount

**Main Flow**

1. Prepare launch data with timing, tiers, splits, fee-project settings, terminal, and scoring params: `referee` (required), `refereeData`, `timelockDuration`, `scorecardTimeout` (must exceed `timelockDuration`), and `defaultAttestationDelegate`. For a holder vote, set `referee` to the `DefifaVotingReferee` deployment and `refereeData` to `abi.encode(attestationStartTime, attestationGracePeriod)`.
2. Call `launchGameWith(...)` on the `DefifaDeployer` for the chosen game type: the ERC-721 deployer clones `DefifaHook`, the ERC-1155 deployer clones `Defifa1155Hook`.
3. The deployer resolves the ERC-2771 caller, advertises that account as the creation-fee payer while reserving the JB project, clones and initializes the game hook, names the referee and timelock in the governor, calls the referee's `initializeGameFor(gameId, refereeData)` when `refereeData` is not empty, and stores the game's immutable ops data.
4. The game advances through its documented phase sequence.

**Failure Modes**

- launch parameters are wrong, but the creator assumes they can patch them later
- fee routing, token decimals, or terminal assumptions drift from the terminal actually configured
- the creator mistakes permissionless launch for ongoing admin power
- `referee` is the zero address, or `scorecardTimeout` does not exceed `timelockDuration`: launch reverts with `DefifaDeployer_InvalidGameConfiguration`
- a voting referee's attestation delay, grace period and the timelock together outlast `scorecardTimeout`: the deployer does not check this, and the game can only end in no-contest

**Postconditions**

- the game exists as a staged JB project with Defifa-specific lifecycle wiring

## Journey 2: Mint outcome pieces during open play

**Actor:** player.

**Intent:** buy one or more outcome pieces during the mint phase.

**Preconditions**

- the game is in the mintable phase
- the selected tier exists and is still mintable

**Main Flow**

1. Pay the game project during the mint window.
2. `DefifaHook` mints the selected outcome NFT tier.

   In an ERC-1155 game, pay with metadata `(address attestationDelegate, uint16[] tierIds, uint256[] counts)`, tier IDs strictly ascending, one count per tier. `Defifa1155Hook` records the counts in the store and mints `counts[i]` of token ID `tierIds[i]` to the beneficiary, one balance per tier. The ERC-1155 receiver check runs last, so a contract beneficiary without `onERC1155Received` / `onERC1155BatchReceived` makes the pay revert.
3. Delegation and mint-cost accounting are updated.
4. Reserved mints and pending reserves continue to matter for later governance and settlement.

**Failure Modes**

- mint is attempted in the wrong phase
- assumptions about attestation power ignore pending reserves or tier weighting
- ERC-1155 pay metadata repeats a tier or is out of order (`DefifaHook_BadTierOrder`), has a zero count, or uses mismatched lengths

**Postconditions**

- the player holds game pieces that later affect governance and settlement; in an ERC-1155 game they read as `hook.balanceOf(player, tierId)` and move with `safeTransferFrom` / `safeBatchTransferFrom` or `setApprovalForAll`

## Journey 3: Submit and ratify a scorecard

**Actor:** the game's referee, then any caller.

**Intent:** turn the game's result into a ratified scorecard.

**Preconditions**

- the game is in SCORING
- the actor understands the timelock and timeout rules

**Main Flow**

1. The referee calls `DefifaGovernor.submitScorecardFor(gameId, tierWeights)`. The governor checks the weights as the hook will, makes the scorecard pending, and starts the timelock. `stateOf` reads QUEUED.
2. To correct a mistake, the referee submits a different scorecard. It replaces the pending one, which reads DEFEATED, and restarts the timelock.
3. Once `timelockDuration` has passed, `stateOf` reads SUCCEEDED and anyone calls `ratifyScorecardFrom(gameId, tierWeights)` with the pending weights. The governor sets the hook's cash-out weights and fulfills commitments in the same transaction.

In a game whose referee is `DefifaVotingReferee`, steps 1 and 2 run through the referee:

1. Anyone calls `DefifaVotingReferee.submitScorecardFor(gameId, tierWeights)`. The referee freezes BWA power one second before submission, snapshots pending reserves, and fixes the scorecard's quorum (50% to 75% by concentration).
2. Holders, or their delegates, call `attestToScorecardFrom` once attestations open, and can `revokeAttestationFrom` while the scorecard is ACTIVE.
3. After the grace period (at least 1 day), a scorecard at quorum reads SUCCEEDED, and anyone calls `forwardScorecardFor(gameId, tierWeights)`. The referee submits it to the governor, starting the timelock. Only the first approved scorecard per game is forwarded; later ones revert with `DefifaVotingReferee_AlreadyForwarded`.

**Failure Modes**

- a caller other than the referee submits to the governor: `DefifaGovernor_NotReferee`
- the referee resubmits the pending scorecard: `DefifaGovernor_DuplicateScorecard`
- ratify before the timelock passes, or with weights that are not the pending scorecard: `DefifaGovernor_NotAllowed`
- the referee submits a new scorecard late enough that its timelock runs past `scorecardTimeout`: the game ends in no-contest
- under a voting referee, attestation power is concentrated enough to capture the result (see RISKS.md, "A game is as safe as its referee")
- timeout is reached before ratification
- integrations misread live attestation power or pending-reserve dilution

**Postconditions**

- exactly one scorecard can become the game's final outcome, or the game moves toward no-contest handling

## Journey 4: Fulfill commitments and settle the game

**Actor:** completion path caller.

**Intent:** turn the ratified scorecard into final redeemable economics.

**Preconditions**

- a scorecard has been ratified
- the fulfillment path has not already run

**Main Flow**

1. Read the ratified outcome.
2. Call `fulfillCommitmentsOf(...)`.
3. Queue the completion ruleset and finalize the promised commitment flow.
4. Let winning-piece holders redeem under the installed cash-out weights. In an ERC-1155 game, cash-out metadata is `(uint256[] tokenIds, uint256[] amounts)` over paid IDs and `tierId + RESERVE_TOKEN_ID_OFFSET` reserve IDs.

**Failure Modes**

- ratification succeeds but fulfillment is never run
- commitment logic or fee accounting drifts from the documented outcome

**Postconditions**

- the game enters its final redeemable state

## Journey 5: Enter no-contest and unlock refund recovery

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

## Journey 6: Launch a game with a named referee

**Actor:** game creator, and the person or multisig who will report the result.

**Intent:** launch a game whose result comes from one known address, so disengaged holders cannot stall scoring.

**Preconditions**

- the referee address is controlled by whoever will report the result, and players accept it as the game's oracle
- the usual launch preconditions from Journey 1 hold

**Main Flow**

1. Prepare launch data as in Journey 1, with `referee` set to the reporting address and `refereeData` empty, so the deployer makes no referee call.
2. Call `launchGameWith(...)`. The governor records the referee; `GameInitialized` emits it and `refereeOf(gameId)` reads it back.
3. During SCORING, the referee calls `DefifaGovernor.submitScorecardFor(...)` with the result.
4. After `timelockDuration`, anyone ratifies the pending scorecard. During the timelock the scorecard is public, and the referee can still replace it.

**Failure Modes**

- the referee never submits: the game reaches `scorecardTimeout` and falls through to no-contest refunds (Journey 5)
- the referee submits a wrong or self-serving result: nothing in the protocol stops it; players trust the referee as they would a bookmaker
- players expect their own attestations or delegation to matter; in this game they do not

**Postconditions**

- the game's result is whatever scorecard the referee last submitted, once its timelock has passed

## Journey 7: Write a referee contract

**Actor:** developer.

**Intent:** decide games by a rule of your own (a holder vote, a jury, an attested committee) instead of a single address.

**Preconditions**

- you have read [`src/referees/DefifaVotingReferee.sol`](./src/referees/DefifaVotingReferee.sol), the sample referee
- your rule decides one scorecard per game, in time for the governor's timelock to pass before `scorecardTimeout`

**Main Flow**

1. If your referee needs per-game settings, implement `IDefifaReferee.initializeGameFor(gameId, data)` and decode your settings from `data`. Accept the call only when `msg.sender` is the game's project owner (`CONTROLLER.PROJECTS().ownerOf(gameId)`), which is the deployer at launch. A referee without settings needs no interface; game creators pass empty `refereeData`.
2. Find the game's governor through its project owner: `IDefifaDeployer(CONTROLLER.PROJECTS().ownerOf(gameId)).GOVERNOR()`. One referee deployment can then serve 721 and 1155 games.
3. Run your rule. When it decides, call the governor's `submitScorecardFor(gameId, tierWeights)`. Only the game's named referee can call it.
4. Decide whether a decision is final. A new submission replaces the pending scorecard and restarts the timelock, so a referee that lets competing results replace each other can be pushed past `scorecardTimeout`. `DefifaVotingReferee` forwards only the first approved scorecard per game for this reason.

**Failure Modes**

- `initializeGameFor` accepts any caller: anyone can rewrite a game's settings
- the rule's windows plus the timelock outlast `scorecardTimeout`: every game ends in no-contest
- the rule can be bought: see RISKS.md, "A game is as safe as its referee"

**Postconditions**

- game creators name your contract as `referee` and pass your settings as `refereeData`

## Trust boundaries

- this repo is trusted for game-specific phase logic, ratification, and settlement weighting
- each game's referee is trusted for its result; the governor does not check what the referee submits beyond its shape
- terminal accounting still comes from `nana-core-v6`
- shared tier-storage behavior still comes from `nana-721-hook-v6`, through `DefifaTiersHookStore` (the upstream store plus count-based records) for both game types

## Hand-offs

- Use [nana-core-v6](../nana-core-v6/USER_JOURNEYS.md) for underlying treasury and terminal behavior.
- Use [nana-721-hook-v6](../nana-721-hook-v6/USER_JOURNEYS.md) for shared tier-store and reserve semantics that Defifa builds on.
