# User Journeys

## Who This Repo Serves

- teams launching Defifa prediction games
- players minting outcome pieces and later redeeming winning positions
- participants submitting, attesting to, and ratifying scorecards
- operators handling refund, no-contest, and fee-settlement edges

## Journey 1: Launch A Defifa Game

**Starting state:** the team knows the countdown, mint window, scoring mechanics, and payout assumptions for a new game.

**Success:** the game launches as a staged Juicebox project with hook, governor, and metadata surfaces all aligned.

**Flow**
1. Use `DefifaDeployer` with launch config, tier params, governance settings, and fee commitments.
2. The deployer launches the project, clones or wires the game hook, and initializes governance through `DefifaGovernor`.
3. The game now has a defined lifecycle instead of being a plain NFT sale.

## Journey 2: Participate As A Player During The Mint Phase

**Starting state:** the game is in its countdown or live mint window and players want to buy outcome pieces.

**Success:** the player mints the intended game pieces and their payment becomes part of the prize pot.

**Flow**
1. Wait until the lifecycle enters the mintable phase.
2. Pay into the game to mint the chosen outcome NFTs through `DefifaHook`.
3. The treasury accumulates the prize pot and the player's position is now represented by the minted pieces.

## Journey 3: Handle Refund Or No-Contest Outcomes

**Starting state:** the game cannot settle normally, either because the refund window is triggered or because governance fails to reach a contestable result.

**Success:** participants can exit under the repo's explicit failure-mode rules instead of ad hoc admin intervention.

**Flow**
1. Observe the current game phase and whether it has entered refund or no-contest handling.
2. Use the game-defined exit path for participants rather than assuming the winning-scorecard path will eventually resolve.
3. Keep treasury and piece-state assumptions aligned with the phase actually reached.

## Journey 4: Submit, Attest To, And Ratify A Scorecard

**Starting state:** minting is over and the game is in its scoring phase.

**Success:** a valid scorecard reaches quorum, survives any grace period, and becomes the game's settled result.

**Flow**
1. A participant submits a scorecard through `DefifaGovernor`.
2. Holders attest, delegate where permitted, and push the preferred scorecard toward quorum.
3. After the grace period, the governor ratifies the winning scorecard if it still satisfies the game's rules.
4. `DefifaHook` updates the relevant cash-out weights for settlement.

## Journey 5: Redeem Winning Pieces And Settle The Pot

**Starting state:** the game has a ratified result and winning positions are now known.

**Success:** holders of winning pieces burn or cash out them for their share of the prize pot.

**Flow**
1. Holders use the game's redemption path after settlement.
2. The hook applies the now-final weights associated with the winning scorecard.
3. Winners receive their proportional share while losers no longer have equivalent claim on the pot.

## Hand-Offs

- Use [nana-721-hook-v6](../nana-721-hook-v6/USER_JOURNEYS.md) for the standard tiered NFT mechanics underneath the game-specific logic.
- Use [nana-core-v6](../nana-core-v6/USER_JOURNEYS.md) for base project accounting once the question is no longer Defifa-specific lifecycle or governance behavior.
