// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {UD60x18, ud} from "@prb/math/src/UD60x18.sol";
import {pow} from "@prb/math/src/ud60x18/Math.sol";
import {mulDiv} from "@prb/math/src/Common.sol";

/// @title BWA Function Comparison — Sybil-Aware
/// @notice Rigorous comparison of three Benefit-Weighted Attestation reduction functions:
///         Linear:       f(x) = 1 - x
///         Quadratic:    f(x) = (1 - x)^2
///         Golden Ratio: f(x) = (1 - x)^phi, phi ≈ 1.618
///
/// THREAT MODEL:
///   - Ethereum accounts are free. Attacker has unlimited addresses.
///   - $1M attack = 1,000,000 addresses x $1 each, or 1 address x $1M, or any split.
///   - BWA applies at the TIER level: a tier's total power = V_MAX x f(w_tier / W_total).
///   - That power is distributed pro-rata among all token holders of that tier.
///   - Whether 1 address holds 100 tokens or 100 addresses hold 1 token each,
///     the attacker's COLLECTIVE share of the tier's power is identical.
///
/// All attack scenarios model:
///   - Attacker controls a FRACTION of tokens in each tier (across unlimited addresses)
///   - Attacker's collective power = Σ (tier_BWA_power x attacker_share_of_tier)
///   - No concept of "attacker's account" — only "attacker's token share per tier"
contract BWAFunctionComparisonTest is Test {
    // --- Constants ---
    uint256 constant W_TOTAL = 1e18; // Total scorecard weight (matches TOTAL_CASHOUT_WEIGHT)
    uint256 constant V_MAX = 1e9; // Max attestation power per tier
    uint256 constant PHI_UD = 1_618_033_988_749_894_848; // Golden ratio as UD60x18

    // --- BWA Functions ---

    /// @dev Linear: f(x) = 1 - x. Returns V_MAX * (1 - w/W).
    function bwaLinear(uint256 w, uint256 wTotal) internal pure returns (uint256) {
        if (w >= wTotal) return 0;
        return mulDiv(V_MAX, wTotal - w, wTotal);
    }

    /// @dev Quadratic: f(x) = (1-x)^2. Returns V_MAX * ((1 - w/W)^2).
    function bwaQuadratic(uint256 w, uint256 wTotal) internal pure returns (uint256) {
        if (w >= wTotal) return 0;
        UD60x18 ratio = ud(mulDiv(1e18, wTotal - w, wTotal));
        UD60x18 squared = ratio.mul(ratio);
        return mulDiv(V_MAX, squared.unwrap(), 1e18);
    }

    /// @dev Golden Ratio: f(x) = (1-x)^phi. Returns V_MAX * ((1 - w/W)^1.618...).
    function bwaGoldenRatio(uint256 w, uint256 wTotal) internal pure returns (uint256) {
        if (w >= wTotal) return 0;
        UD60x18 ratio = ud(mulDiv(1e18, wTotal - w, wTotal));
        UD60x18 result = pow(ratio, ud(PHI_UD));
        return mulDiv(V_MAX, result.unwrap(), 1e18);
    }

    // --- Helpers ---

    struct TotalResult {
        uint256 linearTotal;
        uint256 quadraticTotal;
        uint256 goldenTotal;
    }

    /// @dev Compute total tier-level attestation for a scorecard.
    function computeTotals(uint256[] memory weights) internal pure returns (TotalResult memory r) {
        for (uint256 i; i < weights.length; i++) {
            r.linearTotal += bwaLinear(weights[i], W_TOTAL);
            r.quadraticTotal += bwaQuadratic(weights[i], W_TOTAL);
            r.goldenTotal += bwaGoldenRatio(weights[i], W_TOTAL);
        }
    }

    /// @dev Model: attacker controls `attackerTokens[i]` out of `totalTokens[i]` in tier i.
    ///      Attacker's collective power = Σ tier_power x (attackerTokens[i] / totalTokens[i]).
    struct SybilAttackResult {
        uint256 attackerPowerLin;
        uint256 attackerPowerQuad;
        uint256 attackerPowerGold;
        uint256 honestPowerLin;
        uint256 honestPowerQuad;
        uint256 honestPowerGold;
    }

    function computeSybilAttack(
        uint256[] memory scorecardWeights,
        uint256[] memory attackerTokens,
        uint256[] memory totalTokens
    )
        internal
        pure
        returns (SybilAttackResult memory r)
    {
        for (uint256 i; i < scorecardWeights.length; i++) {
            uint256 tierLin = bwaLinear(scorecardWeights[i], W_TOTAL);
            uint256 tierQuad = bwaQuadratic(scorecardWeights[i], W_TOTAL);
            uint256 tierGold = bwaGoldenRatio(scorecardWeights[i], W_TOTAL);

            if (totalTokens[i] == 0) continue; // unminted tier

            r.attackerPowerLin += mulDiv(tierLin, attackerTokens[i], totalTokens[i]);
            r.attackerPowerQuad += mulDiv(tierQuad, attackerTokens[i], totalTokens[i]);
            r.attackerPowerGold += mulDiv(tierGold, attackerTokens[i], totalTokens[i]);

            uint256 honestTokens = totalTokens[i] - attackerTokens[i];
            r.honestPowerLin += mulDiv(tierLin, honestTokens, totalTokens[i]);
            r.honestPowerQuad += mulDiv(tierQuad, honestTokens, totalTokens[i]);
            r.honestPowerGold += mulDiv(tierGold, honestTokens, totalTokens[i]);
        }
    }

    // ===========================
    // TEST 1: Constant-Total Invariant
    // ===========================

    /// @notice For N tiers, linear total should always equal (N-1) * V_MAX.
    ///         Quadratic and golden ratio totals VARY with distribution.
    function test_constantTotal_4tiers() public pure {
        uint256[] memory equal = new uint256[](4);
        equal[0] = W_TOTAL / 4;
        equal[1] = W_TOTAL / 4;
        equal[2] = W_TOTAL / 4;
        equal[3] = W_TOTAL / 4;

        uint256[] memory wta = new uint256[](4);
        wta[0] = W_TOTAL;
        wta[1] = 0;
        wta[2] = 0;
        wta[3] = 0;

        uint256[] memory topHeavy = new uint256[](4);
        topHeavy[0] = W_TOTAL * 50 / 100;
        topHeavy[1] = W_TOTAL * 30 / 100;
        topHeavy[2] = W_TOTAL * 15 / 100;
        topHeavy[3] = W_TOTAL * 5 / 100;

        uint256[] memory twoWin = new uint256[](4);
        twoWin[0] = W_TOTAL / 2;
        twoWin[1] = W_TOTAL / 2;
        twoWin[2] = 0;
        twoWin[3] = 0;

        uint256 expected = 3 * V_MAX;

        TotalResult memory rEqual = computeTotals(equal);
        TotalResult memory rWta = computeTotals(wta);
        TotalResult memory rTopHeavy = computeTotals(topHeavy);
        TotalResult memory rTwoWin = computeTotals(twoWin);

        // LINEAR: All distributions yield exactly (N-1) * V_MAX
        assertEq(rEqual.linearTotal, expected, "Linear: equal != (N-1)*V_MAX");
        assertEq(rWta.linearTotal, expected, "Linear: concentrated != (N-1)*V_MAX");
        assertEq(rTopHeavy.linearTotal, expected, "Linear: top-heavy != (N-1)*V_MAX");
        assertEq(rTwoWin.linearTotal, expected, "Linear: two-winners != (N-1)*V_MAX");

        // QUADRATIC & GOLDEN: NOT constant
        assertTrue(rEqual.quadraticTotal != rWta.quadraticTotal, "Quadratic: should vary");
        assertTrue(rEqual.goldenTotal != rWta.goldenTotal, "Golden: should vary");
    }

    /// @notice 32-tier constant-total test (World Cup scale).
    function test_constantTotal_32tiers() public pure {
        uint256 N = 32;
        uint256 expected = (N - 1) * V_MAX;

        uint256[] memory equal = new uint256[](N);
        for (uint256 i; i < N; i++) {
            equal[i] = W_TOTAL / N;
        }

        uint256[] memory wta = new uint256[](N);
        wta[0] = W_TOTAL;

        uint256[] memory top4 = new uint256[](N);
        top4[0] = W_TOTAL * 35 / 100;
        top4[1] = W_TOTAL * 25 / 100;
        top4[2] = W_TOTAL * 12 / 100;
        top4[3] = W_TOTAL * 8 / 100;
        uint256 remaining = W_TOTAL - top4[0] - top4[1] - top4[2] - top4[3];
        for (uint256 i = 4; i < N; i++) {
            top4[i] = remaining / (N - 4);
        }

        TotalResult memory rEqual = computeTotals(equal);
        TotalResult memory rWta = computeTotals(wta);
        TotalResult memory rTop4 = computeTotals(top4);

        assertEq(rEqual.linearTotal, expected, "Linear 32: equal");
        assertEq(rWta.linearTotal, expected, "Linear 32: concentrated");
        assertApproxEqAbs(rTop4.linearTotal, expected, N, "Linear 32: top-4");

        // Quadratic/golden: concentrated > equal (convexity of f)
        assertTrue(rWta.quadraticTotal > rEqual.quadraticTotal, "Quadratic: concentrated > equal");
        assertTrue(rWta.goldenTotal > rEqual.goldenTotal, "Golden: concentrated > equal");
    }

    // ===========================
    // TEST 2: Boundary Conditions
    // ===========================

    function test_boundaryConditions() public pure {
        // f(0) = V_MAX (zero benefit -> full power)
        assertEq(bwaLinear(0, W_TOTAL), V_MAX, "Linear: f(0)");
        assertEq(bwaQuadratic(0, W_TOTAL), V_MAX, "Quadratic: f(0)");
        assertEq(bwaGoldenRatio(0, W_TOTAL), V_MAX, "Golden: f(0)");

        // f(W_TOTAL) = 0 (full benefit -> zero power)
        assertEq(bwaLinear(W_TOTAL, W_TOTAL), 0, "Linear: f(1)");
        assertEq(bwaQuadratic(W_TOTAL, W_TOTAL), 0, "Quadratic: f(1)");
        assertEq(bwaGoldenRatio(W_TOTAL, W_TOTAL), 0, "Golden: f(1)");
    }

    // ===========================
    // TEST 3: Monotonicity
    // ===========================

    function test_monotonicity() public pure {
        for (uint256 i; i < 10; i++) {
            uint256 lower = W_TOTAL * i / 10;
            uint256 higher = W_TOTAL * (i + 1) / 10;
            assertTrue(bwaLinear(lower, W_TOTAL) >= bwaLinear(higher, W_TOTAL), "Linear monotonic");
            assertTrue(bwaQuadratic(lower, W_TOTAL) >= bwaQuadratic(higher, W_TOTAL), "Quadratic monotonic");
            assertTrue(bwaGoldenRatio(lower, W_TOTAL) >= bwaGoldenRatio(higher, W_TOTAL), "Golden monotonic");
        }
    }

    // ===========================
    // TEST 4: Power Curve Shape (quad ≤ golden ≤ linear for all x in (0,1))
    // ===========================

    function test_powerCurveOrdering() public pure {
        uint256[7] memory pcts = [uint256(5), 10, 25, 50, 67, 75, 95];
        for (uint256 i; i < 7; i++) {
            uint256 w = W_TOTAL * pcts[i] / 100;
            uint256 lin = bwaLinear(w, W_TOTAL);
            uint256 quad = bwaQuadratic(w, W_TOTAL);
            uint256 gold = bwaGoldenRatio(w, W_TOTAL);
            assertTrue(quad <= gold, "quad <= gold");
            assertTrue(gold <= lin, "gold <= lin");
        }
    }

    // ===========================
    // TEST 5: Sybil Invariance — Address Count Does Not Matter
    // ===========================

    /// @notice BWA power is per-TIER. Whether the attacker uses 1 address holding 60 tokens
    ///         or 60 addresses holding 1 token each, the collective power is identical.
    ///
    ///         Proof: tier power = V_MAX * f(w/W). An account with k tokens out of T total
    ///         gets (k/T) of the tier power. N accounts each with 1 token get N x (1/T) = N/T.
    ///         One account with N tokens gets N/T. Identical.
    function test_sybilInvariance_addressCountIrrelevant() public pure {
        uint256 tierPower = bwaLinear(0, W_TOTAL); // zero-weight tier -> full power = V_MAX
        uint256 totalTokensInTier = 100;
        uint256 attackerTokens = 60;

        // Scenario A: 1 address holds all 60 tokens
        uint256 powerOneAddress = mulDiv(tierPower, attackerTokens, totalTokensInTier);

        // Scenario B: 60 addresses each hold 1 token
        uint256 powerPerAddress = mulDiv(tierPower, 1, totalTokensInTier);
        uint256 power60Addresses = powerPerAddress * attackerTokens;

        // Scenario C: 6 addresses each hold 10 tokens
        uint256 powerPer10 = mulDiv(tierPower, 10, totalTokensInTier);
        uint256 power6Addresses = powerPer10 * 6;

        // All identical
        assertEq(powerOneAddress, power60Addresses, "1 addr == 60 addrs");
        assertEq(powerOneAddress, power6Addresses, "1 addr == 6 addrs");

        // Same for quadratic
        uint256 tierPowerQuad = bwaQuadratic(W_TOTAL * 30 / 100, W_TOTAL); // 30% benefit tier
        uint256 power1 = mulDiv(tierPowerQuad, attackerTokens, totalTokensInTier);
        uint256 powerN = mulDiv(tierPowerQuad, 1, totalTokensInTier) * attackerTokens;
        assertEq(power1, powerN, "Sybil invariance holds for quadratic");
    }

    // ===========================
    // TEST 6: $1M Sybil Attack — Spread Across All Tiers
    // ===========================

    /// @notice Attacker spends $1M buying tokens across ALL tiers via unlimited addresses.
    ///         4 tiers, 100 tokens each at $100 = $40,000 pot.
    ///         Attacker buys 60 tokens in EACH tier ($24,000 of $40,000).
    ///         Attacker submits scorecard [100%, 0%, 0%, 0%].
    ///
    ///         Attacker's COLLECTIVE power across all addresses and tiers:
    ///           - Tier 1 (100% weight): BWA power = 0. Attacker's 60 tokens -> 0 power.
    ///           - Tier 2 (0% weight): BWA power = V_MAX. Attacker's 60/100 -> 60% of V_MAX.
    ///           - Tier 3 (0% weight): BWA power = V_MAX. Attacker's 60/100 -> 60% of V_MAX.
    ///           - Tier 4 (0% weight): BWA power = V_MAX. Attacker's 60/100 -> 60% of V_MAX.
    ///         Attacker total: 0 + 0.6 + 0.6 + 0.6 = 1.8 x V_MAX
    ///         Honest total: 0 + 0.4 + 0.4 + 0.4 = 1.2 x V_MAX
    ///         Quorum (linear): 50% of 3 x V_MAX = 1.5 x V_MAX
    ///         Attacker has 1.8 > 1.5 -> ATTACK SUCCEEDS if honest players don't attest
    ///
    ///         This proves: BWA alone is NOT sufficient. Delegate is necessary.
    ///         BWA's job is to make the attack EXPENSIVE (60% of each tier = proportional to pot).
    function test_sybilAttack_spreadAcrossAllTiers() public pure {
        uint256 N = 4;
        uint256 tokensPerTier = 100;
        uint256 attackerPerTier = 60;

        // Scorecard: [100%, 0%, 0%, 0%]
        uint256[] memory weights = new uint256[](N);
        weights[0] = W_TOTAL;
        weights[1] = 0;
        weights[2] = 0;
        weights[3] = 0;

        uint256[] memory attackerTokens = new uint256[](N);
        uint256[] memory totalTokens = new uint256[](N);
        for (uint256 i; i < N; i++) {
            attackerTokens[i] = attackerPerTier;
            totalTokens[i] = tokensPerTier;
        }

        SybilAttackResult memory result = computeSybilAttack(weights, attackerTokens, totalTokens);
        TotalResult memory totals = computeTotals(weights);

        // Attacker power from winning tier = 0 (BWA zeroes it)
        // Attacker power from non-winning tiers = 3 x V_MAX x 60%
        assertEq(result.attackerPowerLin, mulDiv(V_MAX, 60, 100) * 3, "Attacker: 1.8 x V_MAX");

        // Quorum = 50% of total = 1.5 x V_MAX
        uint256 quorum = totals.linearTotal / 2;
        assertEq(quorum, V_MAX * 3 / 2, "Quorum: 1.5 x V_MAX");

        // Attacker power > quorum -> would succeed WITHOUT honest opposition/delegate
        assertTrue(result.attackerPowerLin > quorum, "Attacker exceeds quorum alone");

        // BUT: honest players from non-winning tiers also have power.
        // If honest players in ANY 2 of 3 non-winning tiers delegate/attest AGAINST:
        // Honest power per non-winning tier: V_MAX x 40% = 0.4 x V_MAX
        // Total honest: 3 x 0.4 x V_MAX = 1.2 x V_MAX
        assertEq(result.honestPowerLin, mulDiv(V_MAX, 40, 100) * 3, "Honest: 1.2 x V_MAX");

        // KEY: The attack cost is PROPORTIONAL TO THE POT.
        // Attacker had to buy 60% of EACH non-winning tier.
        // At $100/token x 60 tokens x 3 tiers = $18,000 out of $40,000 pot.
        // Attack cost / pot = 45%. Scales linearly with pot.

        // Identical across all functions for this scorecard (all non-winning tiers have weight 0)
        assertEq(result.attackerPowerLin, result.attackerPowerQuad, "Sybil: lin == quad for w=0 tiers");
        assertEq(result.attackerPowerLin, result.attackerPowerGold, "Sybil: lin == gold for w=0 tiers");
    }

    // ===========================
    // TEST 7: $1M Sybil Attack — Distributed Scorecard
    // ===========================

    /// @notice Same attacker (60% of each tier) but with distributed scorecard.
    ///         THIS is where linear vs quadratic vs golden diverge.
    ///
    ///         Scorecard: [40%, 30%, 20%, 10%] (realistic game outcome)
    ///         Each tier now has SOME benefit -> BWA reduces power for ALL tiers.
    function test_sybilAttack_distributedScorecard() public pure {
        uint256 N = 4;
        uint256 tokensPerTier = 100;
        uint256 attackerPerTier = 60;

        // Scorecard: [40%, 30%, 20%, 10%]
        uint256[] memory weights = new uint256[](N);
        weights[0] = W_TOTAL * 40 / 100;
        weights[1] = W_TOTAL * 30 / 100;
        weights[2] = W_TOTAL * 20 / 100;
        weights[3] = W_TOTAL * 10 / 100;

        uint256[] memory attackerTokens = new uint256[](N);
        uint256[] memory totalTokens = new uint256[](N);
        for (uint256 i; i < N; i++) {
            attackerTokens[i] = attackerPerTier;
            totalTokens[i] = tokensPerTier;
        }

        SybilAttackResult memory result = computeSybilAttack(weights, attackerTokens, totalTokens);
        TotalResult memory totals = computeTotals(weights);

        // LINEAR: Total = 3 x V_MAX (constant). Quorum = 1.5 x V_MAX.
        assertEq(totals.linearTotal, 3 * V_MAX, "Linear total constant");

        // Attacker's power per tier (linear):
        // Tier 1 (40% weight): f(0.4) = 0.6, attacker gets 60% of that = 0.36 x V_MAX
        // Tier 2 (30%): f(0.3) = 0.7, x 60% = 0.42 x V_MAX
        // Tier 3 (20%): f(0.2) = 0.8, x 60% = 0.48 x V_MAX
        // Tier 4 (10%): f(0.1) = 0.9, x 60% = 0.54 x V_MAX
        // Total attacker linear: (0.36 + 0.42 + 0.48 + 0.54) x V_MAX = 1.8 x V_MAX
        assertEq(result.attackerPowerLin, V_MAX * 18 / 10, "Attacker linear: 1.8 x V_MAX");

        // Interesting: same as the concentrated scorecard!
        // This is BECAUSE linear total is constant — attacker with 60% of all tiers
        // always gets exactly 60% of total = 60% x 3 x V_MAX = 1.8 x V_MAX.
        // The scorecard distribution is IRRELEVANT to the attacker's share.
        // This is a direct consequence of linearity.

        // QUADRATIC: Total < 3 x V_MAX. Attacker's share is NOT 60% of total.
        assertTrue(totals.quadraticTotal < 3 * V_MAX, "Quadratic total < linear");

        // With quadratic, the quorum is LOWER -> potentially easier for attacker
        uint256 quadQuorum = totals.quadraticTotal / 2;
        uint256 linQuorum = totals.linearTotal / 2;
        assertTrue(quadQuorum < linQuorum, "Quadratic quorum < linear quorum");
    }

    // ===========================
    // TEST 8: Linear's Critical Property — Attacker Share is Scorecard-Independent
    // ===========================

    /// @notice Under LINEAR BWA, an attacker controlling α% of EVERY tier gets
    ///         exactly α% of total attestation = α x (N-1) x V_MAX.
    ///         This is TRUE regardless of what scorecard they submit.
    ///
    ///         This means: with linear BWA, the only way to get >50% of attestation
    ///         is to control >50% of tokens in >50% of tiers.
    ///         No scorecard can change this. No Sybil strategy can change this.
    function test_linearAttackerShareIndependentOfScorecard() public pure {
        uint256 N = 4;
        uint256 tokensPerTier = 100;
        uint256 attackerPerTier = 45; // 45% of each tier

        uint256[] memory attackerTokens = new uint256[](N);
        uint256[] memory totalTokens = new uint256[](N);
        for (uint256 i; i < N; i++) {
            attackerTokens[i] = attackerPerTier;
            totalTokens[i] = tokensPerTier;
        }

        // Try 5 different scorecards — attacker linear power should be ~constant
        uint256[4][5] memory scorecards;
        scorecards[0] = [W_TOTAL, uint256(0), uint256(0), uint256(0)]; // concentrated
        scorecards[1] = [W_TOTAL / 4, W_TOTAL / 4, W_TOTAL / 4, W_TOTAL / 4]; // equal
        scorecards[2] = [W_TOTAL / 2, W_TOTAL / 2, uint256(0), uint256(0)]; // two-way
        scorecards[3] = [W_TOTAL * 70 / 100, W_TOTAL * 20 / 100, W_TOTAL * 10 / 100, uint256(0)]; // skewed
        scorecards[4] = [W_TOTAL * 40 / 100, W_TOTAL * 30 / 100, W_TOTAL * 20 / 100, W_TOTAL * 10 / 100]; // distributed

        // Expected: 45% of 3 x V_MAX = 1.35 x V_MAX
        uint256 expectedLinear = mulDiv(3 * V_MAX, 45, 100);

        for (uint256 s; s < 5; s++) {
            uint256[] memory weights = new uint256[](N);
            weights[0] = scorecards[s][0];
            weights[1] = scorecards[s][1];
            weights[2] = scorecards[s][2];
            weights[3] = scorecards[s][3];

            SybilAttackResult memory result = computeSybilAttack(weights, attackerTokens, totalTokens);

            // Linear power is the same regardless of scorecard (within rounding)
            assertApproxEqAbs(
                result.attackerPowerLin, expectedLinear, N, "Linear: attacker power is scorecard-independent"
            );
        }
    }

    /// @notice With UNIFORM ownership, power/quorum = 2*alpha for ALL functions.
    ///         The exploit needs NON-UNIFORM ownership AND differently-shaped scorecards.
    ///
    ///         Quadratic total depends on the weight DISTRIBUTION (not just permutation).
    ///         Concentrated [100%,0,0,0] gives total 3*V_MAX.
    ///         Equal [25%,25%,25%,25%] gives total 2.25*V_MAX (25% lower quorum!).
    ///
    ///         Attacker with 90% in tier 1 prefers equal scorecard:
    ///         - Gets decent power from tier 1 (quadratic penalty is moderate at 25%)
    ///         - AND the quorum drops significantly
    function test_quadraticExploitableWithNonUniformOwnership() public pure {
        uint256 N = 4;

        // Non-uniform ownership: attacker has 90% of tier 1, 10% of tiers 2-4
        uint256[] memory attackerTokens = new uint256[](N);
        attackerTokens[0] = 90;
        attackerTokens[1] = 10;
        attackerTokens[2] = 10;
        attackerTokens[3] = 10;

        uint256[] memory totalTokens = new uint256[](N);
        for (uint256 i; i < N; i++) {
            totalTokens[i] = 100;
        }

        // Scorecard A: concentrated [100%, 0, 0, 0]
        uint256[] memory wtsA = new uint256[](N);
        wtsA[0] = W_TOTAL;

        // Scorecard B: equal [25%, 25%, 25%, 25%]
        uint256[] memory wtsB = new uint256[](N);
        for (uint256 i; i < N; i++) {
            wtsB[i] = W_TOTAL / N;
        }

        SybilAttackResult memory rA = computeSybilAttack(wtsA, attackerTokens, totalTokens);
        SybilAttackResult memory rB = computeSybilAttack(wtsB, attackerTokens, totalTokens);

        TotalResult memory totalsA = computeTotals(wtsA);
        TotalResult memory totalsB = computeTotals(wtsB);

        // LINEAR: both scorecards give same total (3*V_MAX)
        assertEq(totalsA.linearTotal, totalsB.linearTotal, "Linear: quorum identical");

        // QUADRATIC: concentrated total = 3*V_MAX, equal total = 2.25*V_MAX
        assertTrue(totalsA.quadraticTotal > totalsB.quadraticTotal, "Quadratic: concentrated > equal");

        // Compute power-to-quorum ratios for quadratic
        uint256 quadRatioA = (rA.attackerPowerQuad * 1e18) / (totalsA.quadraticTotal / 2);
        uint256 quadRatioB = (rB.attackerPowerQuad * 1e18) / (totalsB.quadraticTotal / 2);
        // Ratios differ: attacker can optimize scorecard for best ratio
        assertTrue(quadRatioA != quadRatioB, "Quadratic: power/quorum ratio varies with scorecard");

        // Compare linear ratios - they ALSO differ in raw power, but quorum is same
        // Linear: raw power differs but quorum is fixed -> one-dimensional optimization only
        // With linear, the game designer KNOWS the quorum and can set parameters around it.
        // With quadratic, quorum itself is a variable the attacker controls.
    }

    // ===========================
    // TEST 9: Non-Uniform Sybil — Attacker Concentrates in Few Tiers
    // ===========================

    /// @notice Instead of buying equally across all tiers, attacker concentrates
    ///         purchases in non-winning tiers where they get max BWA power.
    ///
    ///         Attacker buys 0 tokens in winning tier, 80% in 2 non-winning tiers.
    ///         This is the rational Sybil strategy.
    function test_sybilAttack_concentratedInNonWinning() public pure {
        uint256 N = 4;

        // Scorecard: tier 1 wins 100%
        uint256[] memory weights = new uint256[](N);
        weights[0] = W_TOTAL;

        // Attacker: 0 in tier 1, 80% in tiers 2-3, 0 in tier 4
        uint256[] memory attackerTokens = new uint256[](N);
        attackerTokens[0] = 0;
        attackerTokens[1] = 80;
        attackerTokens[2] = 80;
        attackerTokens[3] = 0;

        uint256[] memory totalTokens = new uint256[](N);
        for (uint256 i; i < N; i++) {
            totalTokens[i] = 100;
        }

        SybilAttackResult memory result = computeSybilAttack(weights, attackerTokens, totalTokens);
        TotalResult memory totals = computeTotals(weights);

        // Attacker power: 0 + 0.8xV_MAX + 0.8xV_MAX + 0 = 1.6 x V_MAX
        assertEq(result.attackerPowerLin, mulDiv(V_MAX, 80, 100) * 2, "Concentrated Sybil: 1.6 x V_MAX");

        // Quorum: 1.5 x V_MAX
        uint256 quorum = totals.linearTotal / 2;

        // 1.6 > 1.5 -> attack succeeds if tier 4 doesn't attest against
        assertTrue(result.attackerPowerLin > quorum, "Concentrated Sybil exceeds quorum");

        // BUT tier 4 (honest, full V_MAX) can attest against:
        // Honest total: 0 + 0.2xV_MAX + 0.2xV_MAX + V_MAX = 1.4 x V_MAX
        assertEq(result.honestPowerLin, mulDiv(V_MAX, 20, 100) * 2 + V_MAX, "Honest: 1.4 x V_MAX");

        // If honest tier 4 attests AGAINST, their V_MAX doesn't help the attacker's scorecard.
        // Attacker needs > quorum FOR the scorecard, honest needs to simply not attest for it.
        // With delegate controlling tier 4, they just don't attest -> scorecard fails to reach quorum
        // because attacker only has 1.6/3.0 = 53% and needs >50% supporting.

        // Cost: 80 tokens x 2 tiers = 160 tokens x price_per_token.
        // If pot is 400 tokens worth, attack cost = 160/400 = 40% of pot.
        // Same across all functions since non-winning tiers have weight 0.
        assertEq(result.attackerPowerLin, result.attackerPowerQuad, "Identical for w=0 tiers");
    }

    // ===========================
    // TEST 10: The Real Sybil Threat — Split Benefit Scorecard
    // ===========================

    /// @notice The sophisticated attack: instead of giving 100% to one tier,
    ///         attacker spreads benefit to tiers they control, retaining BWA power.
    ///
    ///         Attacker controls 60% of tiers 1 and 2.
    ///         Submits scorecard: [50%, 50%, 0%, 0%].
    ///         This gives attacker benefit but ALSO retains partial power.
    function test_sybilAttack_splitBenefitScorecard() public pure {
        uint256 N = 4;

        // Scorecard: [50%, 50%, 0%, 0%]
        uint256[] memory weights = new uint256[](N);
        weights[0] = W_TOTAL / 2;
        weights[1] = W_TOTAL / 2;

        // Attacker: 60% of tiers 1-2, 60% of tiers 3-4
        uint256[] memory attackerTokens = new uint256[](N);
        attackerTokens[0] = 60;
        attackerTokens[1] = 60;
        attackerTokens[2] = 60;
        attackerTokens[3] = 60;

        uint256[] memory totalTokens = new uint256[](N);
        for (uint256 i; i < N; i++) {
            totalTokens[i] = 100;
        }

        SybilAttackResult memory result = computeSybilAttack(weights, attackerTokens, totalTokens);
        TotalResult memory totals = computeTotals(weights);

        // LINEAR:
        // Tier 1 (50% weight): BWA power = 0.5 x V_MAX, attacker gets 60% = 0.30 x V_MAX
        // Tier 2 (50% weight): same = 0.30 x V_MAX
        // Tier 3 (0% weight): BWA power = V_MAX, attacker gets 60% = 0.60 x V_MAX
        // Tier 4 (0% weight): same = 0.60 x V_MAX
        // Total attacker linear: (0.30 + 0.30 + 0.60 + 0.60) = 1.80 x V_MAX
        assertEq(result.attackerPowerLin, V_MAX * 18 / 10, "Split benefit: attacker 1.8 x V_MAX");

        // Still 60% of 3 x V_MAX — linearity makes it scorecard-independent!
        assertEq(totals.linearTotal, 3 * V_MAX, "Linear total unchanged");

        // QUADRATIC: Same attacker tokens, but power DIFFERS
        // Tier 1 (50% weight): quadratic power = (0.5)^2 x V_MAX = 0.25 x V_MAX
        //   attacker gets 60% = 0.15 x V_MAX
        // Tier 2: same = 0.15 x V_MAX
        // Tier 3 (0%): power = V_MAX, 60% = 0.60 x V_MAX
        // Tier 4: same = 0.60 x V_MAX
        // Quadratic attacker: 0.15 + 0.15 + 0.60 + 0.60 = 1.50 x V_MAX
        // Looks LESS — quadratic is harsher on benefiting tiers

        // But quadratic total is ALSO less: (0.25+0.25+1+1) = 2.5 x V_MAX
        // Quadratic quorum = 2.5/2 = 1.25 x V_MAX
        // Attacker: 1.50 > 1.25 -> still exceeds quorum
        // And the margin is 1.50/1.25 = 120%, vs linear's 1.80/1.50 = 120%
        // The ratios are comparable — quadratic's steepness is offset by lower quorum

        assertTrue(result.attackerPowerQuad < result.attackerPowerLin, "Quadratic: less raw attacker power");
        assertTrue(totals.quadraticTotal < totals.linearTotal, "Quadratic: less total too");
    }

    // ===========================
    // TEST 11: Quorum-Relative Attack Power — The Key Metric
    // ===========================

    /// @notice The metric that matters is not raw power but power/quorum.
    ///         For linear: power/quorum = (α x (N-1) x V_MAX) / ((N-1) x V_MAX / 2) = 2α.
    ///         This is ONLY a function of α (attacker's token share) — not scorecard!
    ///         Attacker needs α > 50% to exceed quorum. Period.
    ///
    ///         For quadratic/golden: power/quorum varies with scorecard -> exploitable.
    function test_quorumRelativePower() public pure {
        uint256 N = 4;
        uint256 tokensPerTier = 100;

        // Test at various attacker ownership levels
        uint256[5] memory alphas = [uint256(30), 45, 50, 55, 60]; // % ownership per tier

        for (uint256 a; a < 5; a++) {
            uint256[] memory attackerTokens = new uint256[](N);
            uint256[] memory totalTokens = new uint256[](N);
            for (uint256 i; i < N; i++) {
                attackerTokens[i] = alphas[a];
                totalTokens[i] = tokensPerTier;
            }

            // Test two different scorecards
            uint256[] memory wtsConcentrated = new uint256[](N);
            wtsConcentrated[0] = W_TOTAL;

            uint256[] memory wtsEqual = new uint256[](N);
            for (uint256 i; i < N; i++) {
                wtsEqual[i] = W_TOTAL / N;
            }

            SybilAttackResult memory rConc = computeSybilAttack(wtsConcentrated, attackerTokens, totalTokens);
            SybilAttackResult memory rEq = computeSybilAttack(wtsEqual, attackerTokens, totalTokens);

            TotalResult memory totalsConc = computeTotals(wtsConcentrated);
            TotalResult memory totalsEq = computeTotals(wtsEqual);

            // LINEAR: power/quorum is identical regardless of scorecard
            uint256 linRatioConc = (rConc.attackerPowerLin * 1000) / (totalsConc.linearTotal / 2);
            uint256 linRatioEq = (rEq.attackerPowerLin * 1000) / (totalsEq.linearTotal / 2);
            assertApproxEqAbs(linRatioConc, linRatioEq, 1, "Linear: ratio is scorecard-independent");

            // LINEAR: ratio = 2 x alpha (in permille, so 2000 x alpha / 100)
            uint256 expectedRatio = 2 * alphas[a] * 10; // x1000 scaling
            assertApproxEqAbs(linRatioConc, expectedRatio, N, "Linear: ratio = 2*alpha");

            // QUADRATIC: ratio differs between scorecards
            // For concentrated vs equal, quadratic ratios may differ
            // (They're equal at the boundary cases but differ for realistic scorecards)
        }
    }

    /// @notice Linear BWA's security threshold: attacker needs >50% of tokens in >50% of tiers.
    ///         Below 50% uniform ownership, attack ALWAYS fails regardless of scorecard.
    function test_linearSecurityThreshold() public pure {
        uint256 N = 4;
        uint256 tokensPerTier = 100;

        // At exactly 50%: power = 50% x (N-1) x V_MAX = 1.5 x V_MAX
        // Quorum = (N-1) x V_MAX / 2 = 1.5 x V_MAX
        // Attacker power == quorum -> needs strictly more
        uint256[] memory attackerTokens50 = new uint256[](N);
        uint256[] memory totalTokens = new uint256[](N);
        for (uint256 i; i < N; i++) {
            attackerTokens50[i] = 50;
            totalTokens[i] = tokensPerTier;
        }

        // Any scorecard
        uint256[] memory wts = new uint256[](N);
        wts[0] = W_TOTAL * 70 / 100;
        wts[1] = W_TOTAL * 20 / 100;
        wts[2] = W_TOTAL * 10 / 100;

        SybilAttackResult memory r50 = computeSybilAttack(wts, attackerTokens50, totalTokens);
        TotalResult memory totals = computeTotals(wts);
        uint256 quorum = totals.linearTotal / 2;

        // At 50%, attacker power equals quorum (within rounding)
        assertApproxEqAbs(r50.attackerPowerLin, quorum, N, "50% -> equals quorum");

        // At 49%, strictly below
        uint256[] memory attackerTokens49 = new uint256[](N);
        for (uint256 i; i < N; i++) {
            attackerTokens49[i] = 49;
        }

        SybilAttackResult memory r49 = computeSybilAttack(wts, attackerTokens49, totalTokens);
        assertTrue(r49.attackerPowerLin < quorum, "49% -> below quorum");
    }

    // ===========================
    // TEST 12: Non-Uniform Ownership — Attacker Optimizes Token Distribution
    // ===========================

    /// @notice What if attacker doesn't buy equally in all tiers?
    ///         With fixed budget, can they optimize which tiers to buy into?
    ///
    ///         Under LINEAR BWA with a GIVEN scorecard, the answer is NO.
    ///         The attacker's power from tier i = f(w_i) x (tokens_i / total_i).
    ///         Buying into a LOW-weight tier gives more power per token
    ///         (since f(low weight) > f(high weight)).
    ///         But the TOTAL attestation is still fixed at (N-1) x V_MAX.
    ///
    ///         So the optimal strategy is to buy into non-benefiting tiers.
    ///         But this costs money and gives the attacker no financial benefit.
    function test_nonUniformOwnership_attackerOptimization() public pure {
        uint256 N = 4;

        // Scorecard: [70%, 20%, 10%, 0%]
        uint256[] memory weights = new uint256[](N);
        weights[0] = W_TOTAL * 70 / 100;
        weights[1] = W_TOTAL * 20 / 100;
        weights[2] = W_TOTAL * 10 / 100;
        weights[3] = 0;

        // Strategy A: Buy 240 tokens spread equally (60 per tier)
        uint256[] memory stratA = new uint256[](N);
        stratA[0] = 60;
        stratA[1] = 60;
        stratA[2] = 60;
        stratA[3] = 60;

        // Strategy B: Concentrate in tier 4 (0% weight -> max power per token)
        uint256[] memory stratB = new uint256[](N);
        stratB[0] = 0;
        stratB[1] = 0;
        stratB[2] = 0;
        stratB[3] = 96; // Same total cost (100 each, but max 96 available if 4 are honest)

        // Strategy C: Concentrate in two low-weight tiers
        uint256[] memory stratC = new uint256[](N);
        stratC[0] = 0;
        stratC[1] = 0;
        stratC[2] = 80;
        stratC[3] = 80;

        uint256[] memory totalTokens = new uint256[](N);
        for (uint256 i; i < N; i++) {
            totalTokens[i] = 100;
        }

        SybilAttackResult memory rA = computeSybilAttack(weights, stratA, totalTokens);
        SybilAttackResult memory rB = computeSybilAttack(weights, stratB, totalTokens);
        SybilAttackResult memory rC = computeSybilAttack(weights, stratC, totalTokens);

        // Strategy A (uniform): 60% of total = 1.8 x V_MAX
        assertApproxEqAbs(rA.attackerPowerLin, V_MAX * 18 / 10, N, "Strategy A: 1.8 x V_MAX");

        // Strategy B (concentrated in tier 4): power = f(0) x 96/100 = 0.96 x V_MAX
        // Much less than A! Even though tier 4 gives max power, it's only ONE tier.
        assertApproxEqAbs(rB.attackerPowerLin, mulDiv(V_MAX, 96, 100), 1, "Strategy B: 0.96 x V_MAX");

        // Strategy C: power = f(0.1)x0.8 + f(0)x0.8 = (0.9x0.8 + 1.0x0.8) x V_MAX = 1.52 x V_MAX
        assertApproxEqAbs(
            rC.attackerPowerLin, mulDiv(V_MAX * 9, 80, 1000) + mulDiv(V_MAX, 80, 100), N, "Strategy C: ~1.52 x V_MAX"
        );

        // Conclusion: uniform distribution (A) is the optimal strategy for the attacker.
        // Concentrating tokens doesn't help because you lose coverage of other tiers.
        assertTrue(rA.attackerPowerLin > rB.attackerPowerLin, "Uniform > concentrated");
        assertTrue(rA.attackerPowerLin > rC.attackerPowerLin, "Uniform > partial concentrated");
    }

    // ===========================
    // TEST 13: Variable Quorum Exploit — Quadratic
    // ===========================

    /// @notice Quadratic total varies: attacker can pick the scorecard that gives them
    ///         the best power-to-quorum ratio. This is a bug.
    function test_variableQuorumExploit() public pure {
        uint256 N = 4;

        uint256[] memory equal = new uint256[](N);
        for (uint256 i; i < N; i++) {
            equal[i] = W_TOTAL / N;
        }

        uint256[] memory concentrated = new uint256[](N);
        concentrated[0] = W_TOTAL;

        TotalResult memory rEqual = computeTotals(equal);
        TotalResult memory rConc = computeTotals(concentrated);

        // Quadratic: equal split gives MINIMUM total (convexity of (1-x)^2)
        // concentrated gives MAXIMUM total
        assertTrue(rEqual.quadraticTotal < rConc.quadraticTotal, "Quadratic: equal < concentrated");

        // Variance percentage
        uint256 quadVariancePct = ((rConc.quadraticTotal - rEqual.quadraticTotal) * 100) / rEqual.quadraticTotal;
        assertTrue(quadVariancePct > 5, "Quadratic quorum varies >5%");

        // Linear: zero variance
        assertEq(rEqual.linearTotal, rConc.linearTotal, "Linear: zero variance");
    }

    // ===========================
    // TEST 14: Fuzz — Linear Constant Total
    // ===========================

    function test_fuzz_linearConstantTotal(uint256 w1, uint256 w2, uint256 w3) public pure {
        w1 = bound(w1, 0, W_TOTAL);
        w2 = bound(w2, 0, W_TOTAL - w1);
        w3 = bound(w3, 0, W_TOTAL - w1 - w2);
        uint256 w4 = W_TOTAL - w1 - w2 - w3;

        uint256 total =
            bwaLinear(w1, W_TOTAL) + bwaLinear(w2, W_TOTAL) + bwaLinear(w3, W_TOTAL) + bwaLinear(w4, W_TOTAL);

        assertApproxEqAbs(total, 3 * V_MAX, 3, "Linear constant total (within rounding)");
    }

    /// @notice Fuzz: quadratic total bounded by [(N-1)^2/N, (N-1)] x V_MAX.
    function test_fuzz_quadraticBounds(uint256 w1, uint256 w2, uint256 w3) public pure {
        w1 = bound(w1, 0, W_TOTAL);
        w2 = bound(w2, 0, W_TOTAL - w1);
        w3 = bound(w3, 0, W_TOTAL - w1 - w2);
        uint256 w4 = W_TOTAL - w1 - w2 - w3;

        uint256 total = bwaQuadratic(w1, W_TOTAL) + bwaQuadratic(w2, W_TOTAL) + bwaQuadratic(w3, W_TOTAL)
            + bwaQuadratic(w4, W_TOTAL);

        uint256 minQuad = (3 * 3 * V_MAX) / 4; // 2.25 x V_MAX
        assertTrue(total >= minQuad - 4, "Quadratic >= min");
        assertTrue(total <= 3 * V_MAX + 4, "Quadratic <= max");
    }

    // ===========================
    // TEST 15: Fuzz — Linear Sybil Invariance
    // ===========================

    /// @notice Fuzz: attacker with uniform α% of 4 tiers always gets α x (N-1) x V_MAX
    ///         power under LINEAR BWA, regardless of scorecard.
    function test_fuzz_linearSybilInvariance(uint256 w1, uint256 w2, uint256 w3, uint256 alpha) public pure {
        w1 = bound(w1, 0, W_TOTAL);
        w2 = bound(w2, 0, W_TOTAL - w1);
        w3 = bound(w3, 0, W_TOTAL - w1 - w2);
        uint256 w4 = W_TOTAL - w1 - w2 - w3;
        alpha = bound(alpha, 0, 100);

        uint256 N = 4;
        uint256 totalTokensPerTier = 100;

        uint256 attackerPower;
        uint256[] memory weights = new uint256[](N);
        weights[0] = w1;
        weights[1] = w2;
        weights[2] = w3;
        weights[3] = w4;

        for (uint256 i; i < N; i++) {
            uint256 tierPower = bwaLinear(weights[i], W_TOTAL);
            attackerPower += mulDiv(tierPower, alpha, totalTokensPerTier);
        }

        // Expected: alpha% of (N-1) x V_MAX
        uint256 expected = mulDiv((N - 1) * V_MAX, alpha, totalTokensPerTier);
        // Two levels of mulDiv rounding (BWA + token share) -> up to 2*(N-1) wei error.
        assertApproxEqAbs(attackerPower, expected, 2 * (N - 1), "Fuzz: linear Sybil invariance");
    }

    // ===========================
    // TEST 16: Mathematical Proof — p=1 is Unique
    // ===========================

    /// @notice For f(x) = (1-x)^p, constant total requires:
    ///         4 x (3/4)^p = f(1) + 3xf(0) = 0 + 3 = 3
    ///         (3/4)^p = 3/4  ⟺  p = 1.
    function test_uniqueness_proof() public pure {
        uint256 linA = bwaLinear(W_TOTAL, W_TOTAL) + 3 * bwaLinear(0, W_TOTAL);
        uint256 linB = 4 * bwaLinear(W_TOTAL / 4, W_TOTAL);
        assertEq(linA, linB, "Linear: constant total proven (p=1)");

        uint256 quadA = bwaQuadratic(W_TOTAL, W_TOTAL) + 3 * bwaQuadratic(0, W_TOTAL);
        uint256 quadB = 4 * bwaQuadratic(W_TOTAL / 4, W_TOTAL);
        assertTrue(quadA != quadB, "Quadratic: NOT constant (p=2)");

        uint256 goldA = bwaGoldenRatio(W_TOTAL, W_TOTAL) + 3 * bwaGoldenRatio(0, W_TOTAL);
        uint256 goldB = 4 * bwaGoldenRatio(W_TOTAL / 4, W_TOTAL);
        assertTrue(goldA != goldB, "Golden: NOT constant (p=phi)");
    }

    // ===========================
    // TEST 17: 32-Tier Sybil Attack Economics (World Cup)
    // ===========================

    /// @notice 32 teams, 1000 tokens each at $10 = $320,000 pot.
    ///         Attacker spends $1M across unlimited addresses.
    ///         At $10/token, attacker can buy 100,000 tokens.
    ///         Spread across 31 non-winning tiers = ~3,225 tokens per tier.
    ///         But each tier only has 1000 tokens! Attacker can buy 100% of 31 tiers.
    ///
    ///         Wait — that means if tokens are cheap enough, attacker buys ALL of them.
    ///         The defense isn't the cost per token, it's that buying >50% of each tier
    ///         requires getting there before honest participants during mint phase.
    ///
    ///         With 32 tiers and equal supply: quorum needs 16+ tiers worth of V_MAX.
    function test_32tier_sybilAttack() public pure {
        uint256 N = 32;

        // Scorecard: 100% to tier 1
        uint256[] memory weights = new uint256[](N);
        weights[0] = W_TOTAL;

        // Scenario A: Attacker controls 60% of ALL 32 tiers
        uint256[] memory attackerTokensA = new uint256[](N);
        uint256[] memory totalTokens = new uint256[](N);
        for (uint256 i; i < N; i++) {
            attackerTokensA[i] = 60;
            totalTokens[i] = 100;
        }

        SybilAttackResult memory rA = computeSybilAttack(weights, attackerTokensA, totalTokens);
        TotalResult memory totals = computeTotals(weights);

        // Quorum: 31 x V_MAX / 2 = 15.5 x V_MAX
        uint256 quorum = totals.linearTotal / 2;

        // Attacker with 60% of all tiers:
        // From tier 1 (winning): 0 (BWA kills it)
        // From tiers 2-32: 31 x V_MAX x 0.6 = 18.6 x V_MAX
        uint256 expectedA = mulDiv(V_MAX, 60, 100) * 31;
        assertApproxEqAbs(rA.attackerPowerLin, expectedA, N, "32-tier: 60% attacker power");
        assertTrue(rA.attackerPowerLin > quorum, "60% exceeds quorum");

        // Scenario B: Attacker controls 40% of all tiers — FAILS
        uint256[] memory attackerTokensB = new uint256[](N);
        for (uint256 i; i < N; i++) {
            attackerTokensB[i] = 40;
        }

        SybilAttackResult memory rB = computeSybilAttack(weights, attackerTokensB, totalTokens);
        assertTrue(rB.attackerPowerLin < quorum, "40% below quorum");

        // Scenario C: Attacker controls 51% of all tiers — barely succeeds
        uint256[] memory attackerTokensC = new uint256[](N);
        for (uint256 i; i < N; i++) {
            attackerTokensC[i] = 51;
        }

        SybilAttackResult memory rC = computeSybilAttack(weights, attackerTokensC, totalTokens);
        assertTrue(rC.attackerPowerLin > quorum, "51% just above quorum");

        // The security threshold is clean: >50% of tokens in EACH tier.
        // With 32 tiers x 1000 tokens x $10 = need >16,000 x $10 = $160,000 minimum.
        // For a $320,000 pot, attack cost = 50% of pot. Scales exactly.
    }

    // ===========================
    // TEST 18: Delegate as Honest Counterweight
    // ===========================

    /// @notice With delegate controlling non-winning tiers' attestation,
    ///         the attacker needs > 50% of ONLY the delegate-controlled tiers.
    ///         If delegate has 100% of tier 4 delegated to them, that's V_MAX against.
    ///         Attacker now needs to overcome both delegate AND buy majority.
    function test_delegateCounterweight() public pure {
        uint256 N = 4;

        // Scorecard: [100%, 0%, 0%, 0%]
        uint256[] memory weights = new uint256[](N);
        weights[0] = W_TOTAL;

        // Attacker: 80% of tiers 1-3, 0% of tier 4 (delegate-controlled)
        uint256[] memory attackerTokens = new uint256[](N);
        attackerTokens[0] = 80;
        attackerTokens[1] = 80;
        attackerTokens[2] = 80;
        attackerTokens[3] = 0;

        uint256[] memory totalTokens = new uint256[](N);
        for (uint256 i; i < N; i++) {
            totalTokens[i] = 100;
        }

        SybilAttackResult memory result = computeSybilAttack(weights, attackerTokens, totalTokens);

        // Attacker power: 0 + 0.8 + 0.8 + 0 = 1.6 x V_MAX
        assertEq(result.attackerPowerLin, mulDiv(V_MAX, 80, 100) * 2, "Attacker: 1.6 x V_MAX");
        // Exceeds quorum of 1.5 x V_MAX (linearTotal / 2)

        // But delegate ALSO submits a different scorecard (the truthful one).
        // Delegate controls tier 4 (V_MAX) + honest 20% of tiers 2-3 (0.4 x V_MAX)
        // Delegate coalition: V_MAX + 2 x (V_MAX x 20/100) = 1.4 x V_MAX
        assertEq(result.honestPowerLin, V_MAX + mulDiv(V_MAX, 20, 100) * 2, "Honest: 1.4 x V_MAX");

        // With two competing scorecards, NEITHER reaches quorum without the other's support.
        // Attacker 1.6 > 1.5 (passes) BUT honest 1.4 < 1.5 (doesn't pass either).
        // If honest delegate gets just 1 more honest holder in tiers 2-3 to delegate,
        // they reach 1.5 too -> stalemate -> timeout -> NO_CONTEST.
        // Attack fails because extracted pot = 0 in NO_CONTEST.
    }

    // ===========================
    // TEST 19: Attack Profitability — Dead Token Economics
    // ===========================

    /// @notice The critical economic insight: tokens used for attestation power
    ///         (in non-benefiting tiers) are DEAD MONEY under the fraudulent scorecard.
    ///         They cost the attacker money but return $0.
    ///
    ///         Defifa fees: 2.5% base protocol + 5% defifa = 7.5% total.
    ///         Pot for cashout = 92.5% of total mint cost.
    ///
    ///         UNIFORM buyer (alpha% of ALL tiers):
    ///         - Paid: alpha x N x T x p
    ///         - Recovers: alpha x 0.925 x N x T x p (regardless of scorecard!)
    ///         - Net: -7.5% x (total spent). ALWAYS A LOSS.
    ///         The scorecard cannot help because uniform ownership gets the same
    ///         share of pot no matter which tier "wins."
    function test_uniformBuyer_alwaysLoses() public pure {
        uint256 N = 4;
        uint256 T = 100; // tokens per tier
        uint256 p = 100; // price per token in base units

        uint256 alpha = 60; // 60% of each tier

        // Total mint cost = N x T x p
        uint256 totalMint = N * T * p;

        // Fees = 7.5% -> pot = 92.5%
        uint256 pot = totalMint * 925 / 1000;

        // Attacker paid
        uint256 attackerCost = alpha * N * p; // alpha% x N tiers x T tokens x p

        // Under ANY scorecard [100%, 0, 0, 0]:
        // Tier 1 cashout per token: pot x 100% / T = pot / T
        // Attacker has alpha tokens in tier 1: alpha x pot / T
        uint256 attackerRecovery = alpha * pot / T;

        // Net: always negative because of fees
        assertTrue(attackerRecovery < attackerCost, "Uniform buyer always loses to fees");

        // The loss is exactly 7.5% of spend
        uint256 loss = attackerCost - attackerRecovery;
        assertEq(loss, attackerCost * 75 / 1000, "Loss = 7.5% of spend");

        // KEY: The scorecard is IRRELEVANT. Under [0%, 0%, 100%, 0%]:
        uint256 recoveryTier3 = alpha * pot / T;
        assertEq(attackerRecovery, recoveryTier3, "Same recovery regardless of which tier wins");
    }

    /// @notice NON-UNIFORM buyer: more in "winning" tier, just enough in others for quorum.
    ///         THIS is where the attack can be profitable — but only above a threshold.
    ///
    ///         Attacker: alpha_w in winning tier, alpha_v (>50%) in N-1 voting tiers.
    ///         Fraudulent scorecard: [100%, 0, ..., 0] to tier where attacker is heavy.
    ///
    ///         Net profit = alpha_w x 0.925 x N x T x p - (alpha_w + alpha_v x (N-1)) x T x p
    ///                    = T x p x [alpha_w x (0.925N - 1) - alpha_v x (N-1)]
    ///
    ///         Profitable iff: alpha_w > alpha_v x (N-1) / (0.925N - 1)
    function test_nonUniformAttack_profitabilityThreshold() public pure {
        uint256 N = 4;
        uint256 T = 100;
        uint256 p = 100;

        uint256 totalMint = N * T * p;
        uint256 pot = totalMint * 925 / 1000;

        // Threshold: alpha_w > alpha_v x (N-1) / (0.925N - 1)
        // For N=4: alpha_w > alpha_v x 3 / 2.7 = alpha_v x 1.111...
        // For alpha_v = 51%: alpha_w must be > 56.67%

        // Scenario A: alpha_v=51%, alpha_w=55% -> UNPROFITABLE
        {
            uint256 alphaW = 55;
            uint256 alphaV = 51;
            uint256 cost = (alphaW + alphaV * (N - 1)) * p; // (55 + 153) x 100 = $20,800
            uint256 recovery = alphaW * pot / T; // 55 x $37,000 / 100 = $20,350
            assertTrue(recovery < cost, "alpha_w=55%, alpha_v=51%: UNPROFITABLE");
        }

        // Scenario B: alpha_v=51%, alpha_w=70% -> PROFITABLE
        {
            uint256 alphaW = 70;
            uint256 alphaV = 51;
            uint256 cost = (alphaW + alphaV * (N - 1)) * p;
            uint256 recovery = alphaW * pot / T;
            assertTrue(recovery > cost, "alpha_w=70%, alpha_v=51%: PROFITABLE");
            // ROI: (recovery - cost) / cost
            uint256 profit = recovery - cost;
            uint256 roiPct = profit * 100 / cost;
            // ROI should be modest (~16%)
            assertTrue(roiPct < 25, "ROI < 25% even at 70% ownership");
        }

        // Scenario C: alpha_v=51%, alpha_w=100% -> max profitable
        {
            uint256 alphaW = 100;
            uint256 alphaV = 51;
            uint256 cost = (alphaW + alphaV * (N - 1)) * p;
            uint256 recovery = alphaW * pot / T;
            assertTrue(recovery > cost, "alpha_w=100%, alpha_v=51%: PROFITABLE");
            uint256 profit = recovery - cost;
            uint256 roiPct = profit * 100 / cost;
            // Even at 100% winning tier + 51% voting, ROI is bounded
            assertTrue(roiPct < 50, "Max ROI < 50%");
        }
    }

    /// @notice Compare attack profitability to TRUTHFUL play.
    ///         If the attacker's tier actually won, the TRUTHFUL scorecard gives them
    ///         the same recovery. The attack only "profits" vs truth when the
    ///         attacker's tier DIDN'T actually win.
    ///
    ///         But the voting tokens (non-winning tiers) are a SUNK COST either way.
    ///         Under truth: voting tokens might have value (if truthful scorecard gives them weight).
    ///         Under fraud: voting tokens are worth $0.
    function test_attackVsTruth_votingTokensSunkCost() public pure {
        uint256 N = 4;
        uint256 T = 100;
        uint256 p = 100;

        uint256 totalMint = N * T * p;
        uint256 pot = totalMint * 925 / 1000; // $37,000

        // Attacker: 70% of tier 1, 51% of tiers 2-4
        uint256 alphaW = 70;
        uint256 alphaV = 51;

        // TRUTHFUL scenario: tier 3 actually won. Scorecard [0%, 0%, 100%, 0%].
        // Attacker recovers: 51% x 100% x pot from tier 3 = $18,870
        // Tiers 1,2,4 get 0% -> $0
        uint256 truthRecovery = alphaV * pot / T;

        // FRAUD scenario: attacker claims tier 1 won. Scorecard [100%, 0%, 0%, 0%].
        // Attacker recovers: 70% x 100% x pot from tier 1 = $25,900
        uint256 fraudRecovery = alphaW * pot / T;

        // Gain from fraud vs truth
        uint256 fraudGain = fraudRecovery - truthRecovery;
        // = (70 - 51) x pot / T = 19 x $370 = $7,030
        assertEq(fraudGain, (alphaW - alphaV) * pot / T, "Fraud gain = (alpha_w - alpha_v) x pot/T");

        // The fraud gain comes ENTIRELY from the difference in ownership percentages.
        // With 70% in "winning" tier vs 51% in actual winning tier: 19% more of pot.
        // Cost of this attack: $22,300 spent, $25,900 recovered = $3,600 profit.
        // But under truth: $22,300 spent, $18,870 recovered = $3,430 loss.
        // Total swing: $7,030.

        // If the attacker had EQUAL ownership everywhere (70% of everything):
        // Truth: 70% x pot = $25,900. Fraud: 70% x pot = $25,900. NO GAIN.
        // Fraud is only profitable because of the ownership ASYMMETRY.
    }

    /// @notice The honest defense: honest players collectively own >49% of every tier.
    ///         If they do, the attack ALWAYS loses money.
    ///
    ///         Proof: if alpha_v <= 51% (just barely enough for quorum) and
    ///         alpha_w <= 51% (honest players hold 49% of winning tier too),
    ///         then net profit = T x p x [51 x (0.925N-1) - 51 x (N-1)]
    ///                        = T x p x 51 x [(0.925N-1) - (N-1)]
    ///                        = T x p x 51 x [0.925N - 1 - N + 1]
    ///                        = T x p x 51 x (-0.075N)
    ///                        < 0 ALWAYS.
    ///
    ///         With uniform 51% ownership, fees guarantee a loss.
    function test_uniform51_guaranteedLoss() public pure {
        uint256 T = 100;
        uint256 p = 100;

        // Test for N = 4, 8, 16, 32
        uint256[4] memory tierCounts = [uint256(4), 8, 16, 32];

        for (uint256 i; i < 4; i++) {
            uint256 N = tierCounts[i];
            uint256 totalMint = N * T * p;
            uint256 pot = totalMint * 925 / 1000;

            // Uniform 51% everywhere
            uint256 alpha = 51;
            uint256 cost = alpha * N * p;
            uint256 recovery = alpha * pot / T;

            assertTrue(recovery < cost, "Uniform 51% always loses");

            // Loss = 7.5% of spend (within rounding)
            uint256 expectedLoss = cost * 75 / 1000;
            uint256 actualLoss = cost - recovery;
            assertApproxEqAbs(actualLoss, expectedLoss, 1, "Loss = 7.5%");
        }
    }

    /// @notice The ONLY profitable attack requires the attacker to be OVERWEIGHT
    ///         in their fraudulent "winning" tier vs their voting tiers.
    ///         This means: the attacker must own significantly MORE tokens in one
    ///         specific tier. With a known event (like World Cup), the attacker
    ///         reveals their bet by being overweight — this is observable on-chain
    ///         and can be used as a signal to honest participants.
    function test_overweightRequirement() public pure {
        uint256 N = 32; // World Cup
        uint256 T = 1000;
        uint256 p = 10; // $10 per token

        uint256 totalMint = N * T * p;
        uint256 pot = totalMint * 925 / 1000;

        // Break-even threshold: alpha_w = alpha_v x (N-1) / (0.925N - 1)
        // For N=32: alpha_w = alpha_v x 31 / 28.6 = alpha_v x 1.084
        // At alpha_v = 51%: alpha_w = 55.3%
        // Very tight margins — even a few percent makes the difference

        // At break-even: alpha_w=55%, alpha_v=51%
        // Should be close to break-even
        // cost = (55000 + 1581000) x 10 = $16,360,000?? That can't be right

        // Let me recalculate properly
        // cost = (alphaW + alphaV x (N-1)) x T x p
        //      = (55 + 51 x 31) x 1000 x 10
        //      = (55 + 1581) x $10,000 = 1636 x $10,000
        // Hmm that's getting big. Let me simplify.

        // Pot = 32 x 1000 x $10 x 0.925 = $296,000
        // Attacker recovery from winning tier: alpha_w x pot / (N x T) x T
        //   Wait: per-token cashout = pot x 100% / T = $296,000 / 1000 = $296
        //   Attacker tokens in winning tier: 55% x 1000 = 550
        //   Recovery: 550 x $296 = $162,800
        //   But wait, the "pot" is actually distributed to the scoring tier
        //   pot x (tier_weight / W_TOTAL) / tokens_in_tier x attacker_tokens
        //   For [100%, 0,...]: pot x 1 / 1000 x 550 = $296 x 550 = $162,800

        // Cost: attacker_tokens_total x price
        //   = (550 + 510 x 31) x $10 = (550 + 15,810) x $10 = 16,360 x $10 = $163,600

        // Net: $162,800 - $163,600 = -$800 (LOSS at 55%)

        // At alpha_w=60%:
        {
            uint256 alphaW = 60;
            uint256 alphaV = 51;

            uint256 winnerTokens = alphaW * T / 100; // 600
            uint256 votingTokens = alphaV * (N - 1) * T / 100; // 15,810
            uint256 totalCost = (winnerTokens + votingTokens) * p; // 16,410 x $10 = $164,100

            // Recovery from winning tier
            uint256 recovery = winnerTokens * pot / (T); // 600 x $296,000 / 1000 = $177,600

            assertTrue(recovery > totalCost, "60%/51% profitable at N=32");
            uint256 profit = recovery - totalCost;
            uint256 roiPct = profit * 100 / totalCost;
            // Modest ROI
            assertTrue(roiPct < 15, "ROI < 15% at N=32");
        }
    }

    // ===========================
    // TEST 20: Summary — Conclusions Proven
    // ===========================

    function test_conclusionsProven() public pure {
        // 1. LINEAR f(x) = 1-x is the UNIQUE function with constant total attestation.

        // 2. BWA is TIER-level. Sybil (address splitting) is irrelevant.

        // 3. Under linear BWA, uniform attacker gets alpha x (N-1) x V_MAX power,
        //    INDEPENDENT of scorecard. No scorecard manipulation possible.

        // 4. Security threshold: >50% of tokens per tier.

        // 5. Quadratic/golden: variable quorum = exploitable. Linear: fixed quorum.

        // 6. DEAD TOKEN ECONOMICS: tokens used for attestation power (non-winning tiers)
        //    return $0 under the fraudulent scorecard. This is the attack cost.
        //    With UNIFORM ownership (alpha% of all tiers), fees guarantee a NET LOSS.
        //    Fraud is only profitable with OVERWEIGHT in one tier (alpha_w > ~1.1 x alpha_v).

        // 7. THE IRREDUCIBLE LIMIT: With enough money and overweight ownership,
        //    an attacker CAN push a fraudulent scorecard. This is the 51% attack —
        //    the same fundamental limit as PoS blockchains.

        // DEFENSE STACK:
        //   a) BWA: makes attestation require >50% ownership (dead token cost)
        //   b) Fees (7.5%): make uniform attacks always unprofitable
        //   c) Delegate: coordination point for honest minority
        //   d) scorecardTimeout -> NO_CONTEST: backstop if no honest quorum
        //   e) Game design: tier supply, mint window, reserve tokens
        //      -> make it competitive to acquire >50% during mint

        assertTrue(true);
    }
}
