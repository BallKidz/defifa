# User Journeys

## Who This Repo Serves

- organizers launching prediction or tournament-style games
- players minting, refunding, attesting, and cashing out game pieces
- operators settling scorecards and fee commitments after a game ends

## Journey 1: Launch A Defifa Game

**Starting state:** you know the teams or outcomes, mint price, timing windows, and whether the game should allow refunds or safety fallbacks.

**Success:** a Juicebox project exists with phased rulesets, a Defifa hook, and a governor ready for scorecard voting.

**Flow**
1. Configure the game through the deployer with the intended phase timings and tier setup.
2. `DefifaDeployer` launches the project, clones the hook, and initializes the governor.
3. The game enters `COUNTDOWN`, then `MINT` when minting opens.
4. Players can then buy the outcome NFTs that represent their positions once minting is open.

## Journey 2: Participate As A Player

**Starting state:** the game is in `MINT` or `REFUND`.

**Success:** you either keep a live position into scoring or exit at refund value before the game locks.

**Flow**
1. Pay the game's terminal during `MINT` to receive an NFT tied to a team or outcome.
2. Optionally delegate attestation power to yourself or another address.
3. If the deployer configured a refund phase and you want out, burn the NFT during `REFUND` to reclaim the mint price.
4. Once `SCORING` begins, refunds stop and delegation freezes into the governance phase.

## Journey 3: Submit, Ratify, And Settle The Winning Scorecard

**Starting state:** the game has reached `SCORING`, and the result needs to be encoded into payout weights.

**Success:** a scorecard is ratified, the game enters `COMPLETE`, and winners can cash out their share of the pot.

**Flow**
1. Anyone submits a scorecard describing how the pot should be distributed across tiers.
2. NFT holders attest with voting power derived from their delegated tier positions.
3. Once a scorecard reaches quorum and the grace period passes, it can be ratified.
4. Ratification sets the hook's cash-out weights and fulfills fee commitments.
5. Holders burn winning NFTs through terminal cash outs to claim pot share and fee-token exposure.

**Fallbacks:** if minimum participation is not reached or no scorecard ratifies before timeout, the game can resolve to `NO_CONTEST`, where players recover mint value instead of prize weighting.

## Hand-Offs

- Use [nana-core-v6](../nana-core-v6/USER_JOURNEYS.md) for the underlying payment and cash-out primitives.
- Use [nana-721-hook-v6](../nana-721-hook-v6/USER_JOURNEYS.md) if you need the baseline tiered NFT mental model first.
