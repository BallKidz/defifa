# defifa-collection-deployer-v6 — Architecture

## Purpose

Prediction game platform built on Juicebox V6 NFTs. Players buy NFT tiers representing outcomes (teams, predictions). After the event, a governance process ratifies a scorecard that determines each tier's cash-out weight. Winners cash out proportionally; losers' funds redistribute to winners.

## Contract Map

```
src/
├── DefifaDeployer.sol        — Deploys games: JB project + DefifaHook + DefifaGovernor
├── DefifaHook.sol            — JB721-based hook with game phases and attestation-weighted cash outs
├── DefifaGovernor.sol        — Scorecard ratification via token-weighted attestation
├── DefifaProjectOwner.sol    — Holds project ownership during game lifecycle
├── DefifaTokenUriResolver.sol — On-chain SVG metadata for game NFTs
├── enums/
│   ├── DefifaGamePhase.sol    — MINT → REFUND → SCORING → COMPLETE
│   └── DefifaScorecardState.sol — PENDING → RATIFIED
├── libraries/
│   └── DefifaHookLib.sol      — Tier weight calculation helpers
├── interfaces/                — IDefifaDeployer, IDefifaHook, IDefifaGovernor, etc.
└── structs/                   — Scorecards, tier params, attestations, delegations
```

## Key Data Flows

### Game Deployment
```
Creator → DefifaDeployer.launchGameFor()
  → Create JB project with timed rulesets
  → Deploy DefifaHook (721-based, game-phase-aware)
  → Deploy DefifaGovernor (scorecard ratification)
  → Configure ruleset phases:
    → MINT: payments open, refunds disabled
    → REFUND: no new mints, full refunds available
    → SCORING: governance submits scorecards
    → COMPLETE: cash outs use ratified weights
```

### Scorecard Ratification
```
NFT Holder → DefifaGovernor.submitScorecards()
  → Submit tier cash-out weights (must sum to total)
  → Each NFT holder attests to a scorecard
  → Attestation weight = number of NFTs held (capped at 1e9 per tier)
  → When scorecard reaches quorum → ratified
  → DefifaHook uses ratified weights for cash outs

After ratification:
Player → JBMultiTerminal.cashOutTokensOf()
  → DefifaHook.afterCashOutRecordedWith()
    → Weight from ratified scorecard determines reclaim
    → Winning tiers get proportionally more
    → Losing tiers get less or nothing
```

### Fulfillment
```
Anyone → DefifaDeployer.fulfillCommitmentsOf()
  → After COMPLETE phase
  → Distribute reserved tokens (fee tokens)
  → Clean up game state
```

## Extension Points

| Point | Interface | Purpose |
|-------|-----------|---------|
| Data hook | `IJBRulesetDataHook` | DefifaDeployer controls pay/cashout |
| Cash out hook | `IJBCashOutHook` | DefifaHook applies scorecard weights |
| Pay hook | `IJBPayHook` | DefifaHook tracks delegations during MINT |
| Token URI | `IJB721TokenUriResolver` | DefifaTokenUriResolver renders on-chain SVGs |
| Governor | `IDefifaGovernor` | Scorecard submission and ratification |

## Dependencies
- `@bananapus/core-v6` — Core protocol
- `@bananapus/721-hook-v6` — NFT tier system (DefifaHook extends JB721Hook)
- `@bananapus/address-registry-v6` — Deterministic deploy addresses
- `@bananapus/permission-ids-v6` — Permission constants
- `@openzeppelin/contracts` — Checkpoints, Clones, SafeERC20, Ownable
- `@prb/math` — mulDiv
- `scripty.sol` — On-chain SVG rendering
