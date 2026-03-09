# defifa-collection-deployer-v6 — Risks

## Trust Assumptions

1. **Game Creator** — Configures tiers, timing, and fee parameters at deployment. Parameters are immutable after launch.
2. **DefifaGovernor** — All games share one DefifaGovernor instance. A bug in the governor affects all games.
3. **NFT Holders (Attestors)** — Collectively determine the scorecard through attestation. Requires quorum to ratify.
4. **Core Protocol** — Relies on JBMultiTerminal and JBController for payment/cashout execution.

## Known Risks

| Risk | Description | Mitigation |
|------|-------------|------------|
| Whale tier dominance | Attacker buys majority of 6+ tiers to control quorum | Per-tier attestation cap (1e9), but capital-intensive attack still possible |
| Dynamic quorum | Quorum uses live supply, not snapshot — can change after grace period | `NothingToClaim` revert prevents burns during SCORING |
| Cash-out weight truncation | Integer division `weight/tokens` permanently locks dust amounts | Bounded to ~1 wei per tier per game |
| Single governor | All games share one DefifaGovernor — bug affects all | Design choice; governor logic is deliberately simple |
| Fee token dilution | Reserved mints give fee tokens proportional to tier price (not amount paid) | By design; reduces real payers' claims slightly |
| Scorecard timeout | A scorecard that reaches quorum but isn't ratified before `scorecardTimeout` becomes blocked | Submit and ratify scorecards promptly |
| Delegation during MINT only | Token delegation only possible during MINT phase; later transfers inherit sender's delegate or address(0) | Delegate early |
| Phase transition timing | Ruleset transitions are time-based — cannot be accelerated or delayed | Set phase durations carefully at deployment |

## Privileged Roles

| Role | Capabilities | Notes |
|------|-------------|-------|
| Game creator | Configure tiers, phases, fees | One-time at deployment |
| NFT holders | Attest to scorecards, cash out | Weight proportional to holdings |
| DefifaGovernor owner | Administrative functions | Shared across all games |
| Fee project | Receives reserved token mints | Configured per game |

## Reentrancy Considerations

| Function | Protection | Risk |
|----------|-----------|------|
| `afterCashOutRecordedWith` | Tokens burned BEFORE state updates; terminal state committed | LOW |
| `fulfillCommitmentsOf` | `fulfilledCommitmentsOf` set BEFORE external calls | LOW |
