# defifa-collection-deployer-v6 — Architecture

## Purpose

Prediction game platform built on Juicebox V6. Creates games where players buy NFT tiers representing outcomes, a governance process scores the outcomes, and winners claim treasury funds proportional to their tier's score.

## Contract Map

```
src/
├── DefifaDeployer.sol          — Deploys games: project + hook + governor + URI resolver
├── DefifaHook.sol              — Pay/cashout hook with game phase logic and attestation
├── DefifaGovernor.sol          — Scorecard ratification via tier-weighted governance
├── DefifaProjectOwner.sol      — Proxy owner for Defifa projects
├── DefifaTokenUriResolver.sol  — On-chain SVG metadata for game NFTs
├── enums/
│   ├── DefifaGamePhase.sol     — COUNTDOWN → MINT → REFUND → SCORING → COMPLETE → NO_CONTEST
│   └── DefifaScorecardState.sol
├── interfaces/                 — IDefifaDeployer, IDefifaHook, IDefifaGovernor, etc.
├── libraries/
│   ├── DefifaFontImporter.sol  — Font loading for on-chain SVG rendering
│   └── DefifaHookLib.sol       — Game logic helpers
└── structs/                    — Scorecards, attestations, tier params, delegations
```

## Key Data Flows

### Game Lifecycle
```
MINT Phase:
  Creator → DefifaDeployer.launchGameWith()
    → Create JB project with DefifaHook as data/pay/cashout hook
    → Deploy DefifaGovernor for scorecard governance
    → Players buy NFT tiers (outcomes they predict)
    → Delegation happens during this phase only

REFUND Phase:
  → Players can cash out for full refund (100% redemption rate)

SCORING Phase:
  → Anyone → DefifaGovernor.submitScorecard(weights[])
    → Tier holders attest to scorecards
    → Scorecard reaches quorum → ratified
    → DefifaHook receives final cash-out weights per tier

COMPLETE Phase:
  → Deployer → fulfillCommitmentsOf() sends fee payouts and queues the final ruleset
  → Winners → cash out NFTs at scored weights (see "Scored Weight Redemption" below)
```

### Governance Flow
```
Scorer → DefifaGovernor.submitScorecard(tierWeights[])
  → Validate: correct phase, valid tier order, weights sum correctly
  → Create proposal hash
  → Snapshot pending reserves per tier for BWA computation

Attestor → DefifaGovernor.attestToScorecard(proposalId)
  → Must hold NFT tier tokens at attestationsBegin - 1 checkpoint
  → Attestation weight = voting power from held tiers (diluted by snapshotted pending reserves)
  → When quorum reached → scorecard ratified
  → DefifaHook.setScorecard() called
```

### Scored Weight Redemption

When a scorecard is ratified, `setTierCashOutWeightsTo` stores a weight per tier. Weights must sum to `TOTAL_CASHOUT_WEIGHT` (1e18). A tier with weight 0 means that outcome lost and holders get nothing.

When a holder cashes out an NFT during the COMPLETE phase:

1. **Per-token weight**: The tier's weight is divided equally among all tokens minted in that tier: `tokenWeight = tierWeight / tokensInTier`.
2. **Cash out amount**: `amount = (surplus + totalAmountRedeemed) * tokenWeight / TOTAL_CASHOUT_WEIGHT`. The formula uses `surplus + totalAmountRedeemed` (the original pot size) so that early and late redeemers receive the same value.
3. The token is burned and the holder receives their share of the treasury.

Example: 100 ETH pot, 4 tiers, winning tier gets weight 500000000000000000 (50%). If that tier had 10 minted tokens, each token redeems for `100 * (500000000000000000 / 10) / 1e18 = 5 ETH`.

### fulfillCommitmentsOf

Called automatically when a scorecard is ratified (by `ratifyScorecardFrom`). It performs two actions:

1. **Sends fee payouts**: Computes the fee portion of the pot based on the split percentages configured at game creation, then calls `sendPayoutsOf` to distribute fees to the protocol. If the payout fails, the fee stays in the pot and the function continues (try-catch ensures the final ruleset is always queued).
2. **Queues the final ruleset**: Queues a new Juicebox ruleset with `pausePay: true` (no new payments), `cashOutTaxRate: 0` (no tax on cash-outs), and the data hook still active so scored weights are enforced. This transitions the game to its terminal state where only cash-outs remain.

## Extension Points

| Point | Interface | Purpose |
|-------|-----------|---------|
| Data hook | `IJBRulesetDataHook` | Phase-aware pay/cashout behavior |
| Pay hook | `IJBPayHook` | NFT minting during MINT phase |
| Cash out hook | `IJBCashOutHook` | Scored weight redemptions |
| Token URI resolver | `IJB721TokenUriResolver` | On-chain SVG generation |
| Governor | `IDefifaGovernor` | Scorecard governance |

## Dependencies
- `@bananapus/core-v6` — Core protocol
- `@bananapus/721-hook-v6` — NFT tier system
- `@bananapus/address-registry-v6` — Deterministic deploys
- `@bananapus/permission-ids-v6` — Permission constants
- `@croptop/core-v6` — Croptop integration
- `@rev-net/core-v6` — Revnet integration
- `@openzeppelin/contracts` — Checkpoints, Ownable, Clones
- `@prb/math` — mulDiv
- `scripty.sol` — On-chain scripting for SVG

## Design Decisions

**Attestation-based governance over token-weighted voting.** Each tier gets equal max attestation power (`MAX_ATTESTATION_POWER_TIER = 1e9`) regardless of how many tokens it sold. A holder's power within a tier is proportional to their share of that tier's supply. This prevents a popular outcome (e.g., the favorite team) from dominating the scorecard simply by having more buyers. Every outcome's community has equal say in ratification.

**Six distinct game phases.** The MINT, REFUND, SCORING, and COMPLETE phases enforce a strict lifecycle where each action is only valid in its phase. MINT allows buying in, REFUND provides a grace period for full refunds, SCORING locks the treasury while governance resolves, and COMPLETE enables scored cash-outs. The COUNTDOWN phase gates minting before the game starts, and NO_CONTEST acts as a fallback if no scorecard is ratified within the timeout. This phased approach prevents timing exploits (e.g., buying in after seeing results) and ensures the treasury is never drained during scoring.

**Proxy owner pattern (DefifaProjectOwner).** Game projects are owned by `DefifaDeployer` itself (`launchProjectFor` sets `owner: address(this)`), which restricts game operations to the deployer's hardcoded logic -- no EOA can rug the game by migrating terminals, minting tokens, or changing controllers. Separately, `DefifaProjectOwner` permanently holds the Defifa fee project NFT (DEFIFA_PROJECT_ID) and grants only `SET_SPLIT_GROUPS` permission to the `DefifaDeployer`, so the deployer can set splits on the fee project as needed for fee distribution.

**Weight-based redemption instead of per-tier pots.** Rather than splitting the treasury into separate pots per tier at scoring time, the system assigns each tier a weight out of `TOTAL_CASHOUT_WEIGHT` (1e18). Cash-outs compute their share of the entire surplus on the fly. This avoids complex accounting for partial redemptions and lets the bonding math work naturally as tokens are burned. Early and late redeemers within the same tier get the same per-token value because the formula uses `surplus + totalAmountRedeemed` as the denominator base.

**Scorecard immutability after ratification.** Once a scorecard reaches quorum and is ratified, `cashOutWeightIsSet` is permanently set to `true` and no new weights can be written. Combined with the final ruleset that pauses payments, this guarantees the game's outcome is final and the treasury can only decrease through cash-outs.
