# User Journeys

## Repo Purpose

This repo turns a Juicebox project into a prediction-game lifecycle with immutable phase timing, tiered outcome pieces,
attestation-based scorecard governance, and final cash-out weights that decide how the pot settles. It owns Defifa's
game-specific launch, scoring, no-contest, and settlement logic. It does not replace core Juicebox accounting or the
shared 721 tier store beneath it.

## Primary Actors

- game creators launching a new Defifa market with fixed timing, tiers, and fee routing
- players minting outcome pieces during MINT and later redeeming or refunding them
- attestors and delegates submitting, supporting, revoking, and ratifying scorecards during SCORING
- auditors tracing where game fairness depends on shared 721 store behavior, governor state, and core terminal flows
- operators handling no-contest recovery or optional fee-project ownership locking

## Key Surfaces

- `DefifaDeployer.launchGameWith(...)`: launches a Defifa game as a JB project and wires hook, governor, splits, and lifecycle timing
- `DefifaHook.afterPayRecordedWith(...)`: mints outcome NFTs when players pay during the mintable phase
- `DefifaHook.beforeCashOutRecordedWith(...)` and `afterCashOutRecordedWith(...)`: define refund, winning-piece redemption, and fee-token claim behavior
- `DefifaGovernor.submitScorecardFor(...)`, `attestToScorecardFrom(...)`, `revokeAttestationFrom(...)`, `ratifyScorecardFrom(...)`: scorecard governance lifecycle
- `DefifaDeployer.fulfillCommitmentsOf(...)` and `triggerNoContestFor(...)`: finalize commitments after ratification or unlock refund-oriented no-contest recovery
- `DefifaProjectOwner.onERC721Received(...)`: optional irreversible sink for the Defifa fee-project NFT

## Journey 1: Launch A Defifa Game

**Actor:** game creator.

**Intent:** launch a prediction game with fixed tiers, lifecycle timing, fee routing, and governance rules.

**Preconditions**
- the creator knows the game start time, mint duration, optional refund duration, and scoring timeout assumptions
- tier count, tier names, tier price, and split commitments are finalized
- the chosen terminal and payment token are correct because the launch path is intentionally one-way

**Main Flow**
1. Prepare `DefifaLaunchProjectData` with timing, tiers, splits, fee-project settings, terminal, and governance params.
2. Call `DefifaDeployer.launchGameWith(...)`.
3. The deployer launches the JB project, clones and initializes `DefifaHook`, initializes the governor state, and stores the game's immutable ops data.
4. The new game now advances through `COUNTDOWN -> MINT -> REFUND` if configured `-> SCORING -> COMPLETE` or `NO_CONTEST` according to launch-time rules.

**Failure Modes**
- launch parameters are wrong, but the creator assumes they can patch them later
- fee routing, token decimals, or terminal assumptions drift from the terminal actually configured
- the creator mistakes permissionless launch for ongoing admin power after deployment

**Postconditions**
- the game exists as a staged JB project owned structurally by the deployer rather than by the creator
- the next important runtime surfaces are `DefifaHook` during play and `DefifaGovernor` during scoring

## Journey 2: Mint Outcome Pieces During The Playable Window

**Actor:** player.

**Intent:** buy one or more outcome pieces while the game is in its payable phase.

**Preconditions**
- the game is in `MINT`
- the payer knows which tier they want and can provide the right metadata for that tier
- the terminal and token match the game's configured payment path

**Main Flow**
1. The payer calls the terminal payment path for the game.
2. `DefifaHook.afterPayRecordedWith(...)` decodes tier metadata, enforces game-phase and pricing assumptions, and mints the chosen outcome NFTs.
3. The payment becomes part of the game pot and the minted piece starts carrying the tier-specific attestation and later cash-out context.
4. If a default attestation delegate is configured, delegation power may be assigned immediately for new minters who do not set their own delegate.

**Failure Modes**
- payment happens outside `MINT`
- metadata points at the wrong tier or overspending behavior is not allowed
- users think the NFT is a normal collectible and miss that it also governs later scorecard power and cash-out rights

**Postconditions**
- the player holds Defifa NFTs representing their chosen outcome positions
- the game pot and future governance power both depend on what was minted and what reserves remain pending

## Journey 3: Submit And Attest To A Scorecard During SCORING

**Actor:** attestor, delegate, or competing participant.

**Intent:** push a preferred scorecard toward ratification once the game enters scoring.

**Preconditions**
- the game is in `SCORING`
- the participant holds or controls attestation power for one or more tiers
- a scorecard with nonzero weight only assigns value to tiers that actually have live ownership

**Main Flow**
1. Any participant calls `DefifaGovernor.submitScorecardFor(...)` with tier cash-out weights that sum to the total allowed weight.
2. The governor snapshots the scorecard, tier weights, and pending-reserve state relevant to later BWA attestation accounting.
3. Holders or delegates call `attestToScorecardFrom(...)` to add weight, or `revokeAttestationFrom(...)` while the scorecard remains `ACTIVE`.
4. A scorecard moves through `ACTIVE`, `QUEUED`, and `SUCCEEDED` depending on quorum, grace-period, and timelock conditions.

**Failure Modes**
- a scorecard assigns weight to an unminted tier
- users ignore pending-reserve dilution and misread their real attestation power
- delegates or default delegates accumulate more governance influence than operators realized
- participants wait past `scorecardTimeout` and assume a late scorecard can still settle the game

**Postconditions**
- the game either has a viable winning scorecard path or remains on track for timeout-driven no-contest
- governance state is now the main determinant of whether the game reaches `COMPLETE` or `NO_CONTEST`

## Journey 4: Ratify The Winning Scorecard And Fulfill Commitments

**Actor:** any caller once a scorecard has succeeded.

**Intent:** finalize the game's winning weights and move it into its completed settlement path.

**Preconditions**
- no scorecard has been ratified yet
- the target scorecard is in `SUCCEEDED`
- the caller provides the same scorecard weights that hash to the succeeded proposal

**Main Flow**
1. Call `DefifaGovernor.ratifyScorecardFrom(...)` with the winning tier-weight array.
2. The governor marks the scorecard as ratified, calls `DefifaHook.setTierCashOutWeightsTo(...)`, and closes the score-setting path permanently.
3. The governor triggers `DefifaDeployer.fulfillCommitmentsOf(...)` to send fee or split commitments and queue the final `COMPLETE` ruleset.
4. From this point forward, cash-out behavior uses the ratified weights rather than mint-price or refund logic.

**Failure Modes**
- callers try to ratify a scorecard that has not truly succeeded
- teams miss that cash-out weights are permanent once set
- payout sending partially fails and observers assume the game is unsettled instead of reading the deployer's documented recovery behavior

**Postconditions**
- the game is economically settled on one scorecard path
- winners and losers can now be reasoned about through `DefifaHook` cash-out semantics

## Journey 5: Trigger No-Contest Recovery Instead Of Normal Settlement

**Actor:** any caller when the game has entered `NO_CONTEST`.

**Intent:** unlock the documented refund-oriented recovery path when the game cannot settle normally.

**Preconditions**
- the game is in `NO_CONTEST` because participation was too low or the scorecard timeout elapsed without ratification
- no one has already triggered the no-contest flow

**Main Flow**
1. Confirm the current phase really is `NO_CONTEST`; this is not a discretionary admin override.
2. Call `DefifaDeployer.triggerNoContestFor(...)`.
3. The deployer queues the refund-friendly ruleset state that lets participants exit according to the no-contest rules rather than the normal winning-scorecard path.
4. Players then use the hook-mediated cash-out path under the no-contest economics.

**Failure Modes**
- teams assume refunds are automatically available without calling `triggerNoContestFor(...)`
- someone treats no-contest as reversible and waits for late ratification
- observers mistake a scoring dispute for a no-contest state when the timeout has not actually elapsed

**Postconditions**
- the game is locked into its no-contest recovery path
- participants should stop reasoning about scorecard winners and start reasoning about refund semantics

## Journey 6: Cash Out Winning Pieces, Refund, Or Claim Fee Tokens

**Actor:** player holding game NFTs after mint.

**Intent:** exit a position through refund, no-contest recovery, or completed-game redemption.

**Preconditions**
- the holder knows which token IDs they are cashing out
- the game phase is understood because the same hook uses different economics across refund, scoring-adjacent, no-contest, and complete states
- the holder understands that fee-token claims and prize-pot claims are coupled to mint-cost and pending-reserve accounting

**Main Flow**
1. Call the terminal cash-out path with the Defifa token IDs encoded in cash-out metadata.
2. `DefifaHook.beforeCashOutRecordedWith(...)` determines the relevant cash-out count and routes the exit through Defifa's hook path instead of a plain fungible-token cash-out.
3. `DefifaHook.afterCashOutRecordedWith(...)` burns the NFTs, updates redeemed accounting, and handles fee-token distribution or refund/winning-piece payout logic appropriate to the game phase.
4. The holder exits with the value the phase and scorecard state entitle them to, not with an ad hoc operator-set amount.

**Failure Modes**
- users try to redeem before the game reached a phase that allows the intended exit path
- users ignore pending-reserve or reserved-mint dilution when estimating fee-token claims
- teams assume all redemptions are winner-take-all when refund and no-contest flows use different reclaim logic

**Postconditions**
- the holder's NFTs are burned for the exited position
- redeemed accounting and claimable value stay aligned with the game's ratified or no-contest state

## Journey 7: Lock The Defifa Fee Project NFT Into DefifaProjectOwner

**Actor:** protocol operator or fee-project owner.

**Intent:** permanently lock the Defifa fee-project NFT while still allowing the deployer to manage split groups on its behalf.

**Preconditions**
- the operator understands this transfer is intentionally irreversible
- the project being transferred is the intended fee-project NFT

**Main Flow**
1. Transfer the relevant JB project NFT into `DefifaProjectOwner`.
2. `onERC721Received(...)` confirms the sender is the JB projects contract.
3. The contract grants `SET_SPLIT_GROUPS` permission to the `DefifaDeployer` for that project.
4. The NFT remains locked in the owner sink with no general recovery path.

**Failure Modes**
- operators treat the sink as normal custody rather than as a burn-lock mechanism
- the wrong project NFT is transferred in

**Postconditions**
- split-group administration remains possible for the deployer
- project ownership itself is not recoverable from the sink

## Trust Boundaries

- this repo depends on `nana-core-v6` for the underlying project, terminal, ruleset, and accounting model
- this repo depends on shared `JB721TiersHookStore` behavior even though Defifa has its own hook implementation
- `DefifaGovernor` is trusted to snapshot, count, and ratify scorecards according to the documented quorum and timeout rules
- launch-time config is intentionally high-stakes because game timing, fee routing, tiers, and governance settings are mostly immutable after deployment

## Hand-Offs

- Use [nana-core-v6](../nana-core-v6/USER_JOURNEYS.md) when the question becomes about base project accounting, terminal settlement, payouts, or permissions.
- Use [nana-721-hook-v6](../nana-721-hook-v6/USER_JOURNEYS.md) when the question is about shared tier-store assumptions or standard 721-hook mechanics underneath Defifa's game logic.
- Use [nana-permission-ids-v6](../nana-permission-ids-v6/USER_JOURNEYS.md) if the question is specifically about the permission constant granted by `DefifaProjectOwner`.
