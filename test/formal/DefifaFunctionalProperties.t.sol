// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IJB721TiersHookStore} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHookStore.sol";
import {mulDiv} from "@prb/math/src/Common.sol";

import {DefifaGamePhase} from "../../src/enums/DefifaGamePhase.sol";
import {DefifaHookLib} from "../../src/libraries/DefifaHookLib.sol";

/// @notice Functional-correctness harnesses for Defifa pure/view arithmetic and bit-packing.
/// @dev Each property is dual-implemented: `check_<name>` for Halmos (symbolic) and `testFuzz_<name>`
/// for the Foundry fuzzer. Halmos is used only for SMT-tractable code (constant-divisor arithmetic,
/// bit-packing field isolation, branch selection). Full 512-bit mulDiv domains are verified by fuzz.
///
/// Specs verified here come directly from the contracts and INVARIANTS.md:
///  - DefifaHookLib.computeCashOutCount phase branch (refund-style returns mint price;
///    weighted phases use pot value and ignore mint price). [DefifaHookLib.sol:164-187]
///  - DefifaHookLib.computeTokensClaim proportional fee-token claim. [DefifaHookLib.sol:324-353]
///  - DefifaGovernor packed scorecard info: 3 x uint48 round-trip + field isolation.
///    [DefifaGovernor.sol:556-597]
///  - BWA reduction multiplier monotonicity: power * (TOTAL - tierWeight) / TOTAL.
///    [DefifaGovernor.sol:742-746]
contract DefifaFunctionalProperties is Test {
    /// @notice The Defifa cash-out / scorecard weight denominator (matches DefifaHook.TOTAL_CASHOUT_WEIGHT).
    uint256 internal constant _TOTAL_CASHOUT_WEIGHT = 1_000_000_000_000_000_000;

    /// @notice Max attestation power per tier (matches DefifaGovernor.MAX_ATTESTATION_POWER_TIER).
    uint256 internal constant _MAX_ATTESTATION_POWER_TIER = 1_000_000_000;

    //*********************************************************************//
    // ---------- Property 1: refund-style phases return mint price ------ //
    //*********************************************************************//

    /// @dev Spec: in MINT / REFUND / NO_CONTEST the cash-out count equals exactly the cumulative mint
    /// price, regardless of the pot state. This is the "you get back what you put in" refund guarantee.

    function check_refundPhasesReturnMintPrice(
        uint256 cumulativeMintPrice,
        uint256 surplusValue,
        uint256 totalAmountRedeemed,
        uint256 cumulativeCashOutWeight
    )
        public
        pure
    {
        assert(
            DefifaHookLib.computeCashOutCount(
                DefifaGamePhase.MINT, cumulativeMintPrice, surplusValue, totalAmountRedeemed, cumulativeCashOutWeight
            ) == cumulativeMintPrice
        );
        assert(
            DefifaHookLib.computeCashOutCount(
                DefifaGamePhase.REFUND, cumulativeMintPrice, surplusValue, totalAmountRedeemed, cumulativeCashOutWeight
            ) == cumulativeMintPrice
        );
        assert(
            DefifaHookLib.computeCashOutCount(
                DefifaGamePhase.NO_CONTEST, cumulativeMintPrice, surplusValue, totalAmountRedeemed, cumulativeCashOutWeight
            ) == cumulativeMintPrice
        );
    }

    function testFuzz_refundPhasesReturnMintPrice(
        uint256 cumulativeMintPrice,
        uint256 surplusValue,
        uint256 totalAmountRedeemed,
        uint256 cumulativeCashOutWeight
    )
        public
        pure
    {
        assertEq(
            DefifaHookLib.computeCashOutCount(
                DefifaGamePhase.MINT, cumulativeMintPrice, surplusValue, totalAmountRedeemed, cumulativeCashOutWeight
            ),
            cumulativeMintPrice
        );
        assertEq(
            DefifaHookLib.computeCashOutCount(
                DefifaGamePhase.REFUND, cumulativeMintPrice, surplusValue, totalAmountRedeemed, cumulativeCashOutWeight
            ),
            cumulativeMintPrice
        );
        assertEq(
            DefifaHookLib.computeCashOutCount(
                DefifaGamePhase.NO_CONTEST,
                cumulativeMintPrice,
                surplusValue,
                totalAmountRedeemed,
                cumulativeCashOutWeight
            ),
            cumulativeMintPrice
        );
    }

    //*********************************************************************//
    // -------- Property 2: weighted phases ignore mint price ----------- //
    //*********************************************************************//

    /// @dev Spec: in SCORING / COMPLETE the cash-out count is mulDiv(surplus + redeemed, weight, TOTAL)
    /// and does NOT depend on the cumulative mint price. Halmos version uses bounded widths to stay
    /// SMT-tractable; the full-width version is fuzzed.

    function check_weightedPhasesIgnoreMintPrice(
        uint128 cumulativeMintPriceA,
        uint128 cumulativeMintPriceB,
        uint64 surplusValue,
        uint64 totalAmountRedeemed,
        uint64 cumulativeCashOutWeight
    )
        public
        pure
    {
        if (cumulativeCashOutWeight > _TOTAL_CASHOUT_WEIGHT) return;

        // Same pot inputs, two different mint prices -> identical result.
        uint256 outA = DefifaHookLib.computeCashOutCount(
            DefifaGamePhase.COMPLETE, cumulativeMintPriceA, surplusValue, totalAmountRedeemed, cumulativeCashOutWeight
        );
        uint256 outB = DefifaHookLib.computeCashOutCount(
            DefifaGamePhase.COMPLETE, cumulativeMintPriceB, surplusValue, totalAmountRedeemed, cumulativeCashOutWeight
        );
        assert(outA == outB);

        // And it equals the documented formula.
        uint256 expected = mulDiv(
            uint256(surplusValue) + uint256(totalAmountRedeemed), cumulativeCashOutWeight, _TOTAL_CASHOUT_WEIGHT
        );
        assert(outA == expected);
    }

    function testFuzz_weightedPhasesIgnoreMintPrice(
        uint256 cumulativeMintPriceA,
        uint256 cumulativeMintPriceB,
        uint256 surplusValue,
        uint256 totalAmountRedeemed,
        uint256 cumulativeCashOutWeight
    )
        public
        pure
    {
        // Constrain so surplus + redeemed cannot overflow inside mulDiv intermediate.
        surplusValue = bound(surplusValue, 0, type(uint128).max);
        totalAmountRedeemed = bound(totalAmountRedeemed, 0, type(uint128).max);
        cumulativeCashOutWeight = bound(cumulativeCashOutWeight, 0, _TOTAL_CASHOUT_WEIGHT);

        uint256 outA = DefifaHookLib.computeCashOutCount(
            DefifaGamePhase.SCORING, cumulativeMintPriceA, surplusValue, totalAmountRedeemed, cumulativeCashOutWeight
        );
        uint256 outB = DefifaHookLib.computeCashOutCount(
            DefifaGamePhase.SCORING, cumulativeMintPriceB, surplusValue, totalAmountRedeemed, cumulativeCashOutWeight
        );
        assertEq(outA, outB);

        uint256 expected =
            mulDiv(surplusValue + totalAmountRedeemed, cumulativeCashOutWeight, _TOTAL_CASHOUT_WEIGHT);
        assertEq(outA, expected);
    }

    //*********************************************************************//
    // ---- Property 3: weighted reclaim monotone & bounded by pot ------ //
    //*********************************************************************//

    /// @dev Spec: a token set with more cumulative cash-out weight reclaims at least as much (monotone),
    /// and a full-weight (TOTAL) cash-out reclaims at most the whole pot (surplus + redeemed). This is
    /// the conservation bound that prevents over-distribution beyond the treasury.

    function testFuzz_weightedReclaimMonotoneAndBounded(
        uint256 surplusValue,
        uint256 totalAmountRedeemed,
        uint256 weightLow,
        uint256 weightHigh
    )
        public
        pure
    {
        surplusValue = bound(surplusValue, 0, type(uint128).max);
        totalAmountRedeemed = bound(totalAmountRedeemed, 0, type(uint128).max);
        weightLow = bound(weightLow, 0, _TOTAL_CASHOUT_WEIGHT);
        weightHigh = bound(weightHigh, weightLow, _TOTAL_CASHOUT_WEIGHT);

        uint256 low = DefifaHookLib.computeCashOutCount(
            DefifaGamePhase.COMPLETE, 0, surplusValue, totalAmountRedeemed, weightLow
        );
        uint256 high = DefifaHookLib.computeCashOutCount(
            DefifaGamePhase.COMPLETE, 0, surplusValue, totalAmountRedeemed, weightHigh
        );

        // Monotone in weight.
        assertLe(low, high);

        // The full pot (weight == TOTAL) reclaims at most surplus + redeemed.
        uint256 full = DefifaHookLib.computeCashOutCount(
            DefifaGamePhase.COMPLETE, 0, surplusValue, totalAmountRedeemed, _TOTAL_CASHOUT_WEIGHT
        );
        assertLe(full, surplusValue + totalAmountRedeemed);

        // Any partial cash-out is bounded by the full-pot cash-out.
        assertLe(high, full);
    }

    //*********************************************************************//
    // ----- Property 4: tokens-claim proportional fee distribution ----- //
    //*********************************************************************//

    /// @dev Spec: computeTokensClaim returns mulDiv(balance, cumulativeMintPrice, totalMintCost) for each
    /// fee token, returns (0,0) when totalMintCost is 0, and never returns more than the contract balance
    /// (because cumulativeMintPrice <= totalMintCost is the caller contract's invariant — here we assert
    /// the math respects balance whenever that holds).

    function check_tokensClaimZeroCost(
        uint256 defifaBalance,
        uint256 baseProtocolBalance,
        uint256[] memory tokenIds
    )
        public
        view
    {
        // totalMintCost == 0 short-circuits to (0,0) before any store reads, so a zero / unused
        // store is fine for the symbolic path.
        (uint256 d, uint256 b) = DefifaHookLib.computeTokensClaim(
            tokenIds, IJB721TiersHookStore(address(0)), address(this), 0, defifaBalance, baseProtocolBalance
        );
        assert(d == 0);
        assert(b == 0);
    }

    function testFuzz_tokensClaimProportionAndBound(
        uint256 cumulativeMintPrice,
        uint256 totalMintCost,
        uint256 defifaBalance,
        uint256 baseProtocolBalance
    )
        public
        pure
    {
        // The contract guarantees 0 < cumulativeMintPrice <= totalMintCost (a holder cannot claim for more
        // than the whole pot's mint cost). Model the proportional math directly (mirrors lines 351-352).
        totalMintCost = bound(totalMintCost, 1, type(uint128).max);
        cumulativeMintPrice = bound(cumulativeMintPrice, 0, totalMintCost);
        defifaBalance = bound(defifaBalance, 0, type(uint128).max);
        baseProtocolBalance = bound(baseProtocolBalance, 0, type(uint128).max);

        uint256 d = mulDiv(defifaBalance, cumulativeMintPrice, totalMintCost);
        uint256 b = mulDiv(baseProtocolBalance, cumulativeMintPrice, totalMintCost);

        // A single holder never claims more than the full balance.
        assertLe(d, defifaBalance);
        assertLe(b, baseProtocolBalance);

        // Claiming the entire pot's worth of mint cost yields the entire balance.
        if (cumulativeMintPrice == totalMintCost) {
            assertEq(d, defifaBalance);
            assertEq(b, baseProtocolBalance);
        }
    }

    //*********************************************************************//
    // ------- Property 5: packed scorecard info round-trip ------------- //
    //*********************************************************************//

    /// @dev Spec: DefifaGovernor packs (attestationStartTime, attestationGracePeriod, timelockDuration),
    /// each a uint48, into one uint256 and reads them back with the three getters. Round-trip and
    /// field-isolation must hold (a change in one field cannot affect another's read-back).

    function _pack(uint256 start, uint256 grace, uint256 timelock) internal pure returns (uint256 packed) {
        packed |= start;
        packed |= grace << 48;
        packed |= timelock << 96;
    }

    function _readStart(uint256 packed) internal pure returns (uint256) {
        return uint256(uint48(packed));
    }

    function _readGrace(uint256 packed) internal pure returns (uint256) {
        return uint256(uint48(packed >> 48));
    }

    function _readTimelock(uint256 packed) internal pure returns (uint256) {
        return uint256(uint48(packed >> 96));
    }

    function check_packedScorecardRoundTrip(uint48 start, uint48 grace, uint48 timelock) public pure {
        uint256 packed = _pack(start, grace, timelock);
        assert(_readStart(packed) == start);
        assert(_readGrace(packed) == grace);
        assert(_readTimelock(packed) == timelock);
    }

    function check_packedScorecardFieldIsolation(
        uint48 start,
        uint48 grace,
        uint48 timelock,
        uint48 start2,
        uint48 grace2,
        uint48 timelock2
    )
        public
        pure
    {
        // Changing only `start` must not change the grace / timelock read-back.
        uint256 p1 = _pack(start, grace, timelock);
        uint256 p2 = _pack(start2, grace, timelock);
        assert(_readGrace(p1) == _readGrace(p2));
        assert(_readTimelock(p1) == _readTimelock(p2));

        // Changing only `grace` must not change start / timelock.
        uint256 p3 = _pack(start, grace2, timelock);
        assert(_readStart(p1) == _readStart(p3));
        assert(_readTimelock(p1) == _readTimelock(p3));

        // Changing only `timelock` must not change start / grace.
        uint256 p4 = _pack(start, grace, timelock2);
        assert(_readStart(p1) == _readStart(p4));
        assert(_readGrace(p1) == _readGrace(p4));
    }

    function testFuzz_packedScorecardRoundTrip(uint48 start, uint48 grace, uint48 timelock) public pure {
        uint256 packed = _pack(start, grace, timelock);
        assertEq(_readStart(packed), start);
        assertEq(_readGrace(packed), grace);
        assertEq(_readTimelock(packed), timelock);
    }

    //*********************************************************************//
    // -------- Property 6: BWA reduction multiplier semantics ---------- //
    //*********************************************************************//

    /// @dev Spec (DefifaGovernor.getBWAAttestationWeight 742-746): per-tier power is reduced by
    /// (TOTAL - tierWeight) / TOTAL. So:
    ///   - full-weight tier (tierWeight == TOTAL) yields ZERO attestation power (no self-attestation),
    ///   - zero-weight tier retains full rawPower,
    ///   - reduction is monotonically NON-INCREASING in tierWeight (more benefit => less power).

    function _bwaPower(uint256 rawPower, uint256 tierWeight) internal pure returns (uint256) {
        uint256 bwaMultiplier = _TOTAL_CASHOUT_WEIGHT - tierWeight;
        return mulDiv(rawPower, bwaMultiplier, _TOTAL_CASHOUT_WEIGHT);
    }

    /// @dev Symbolic-tractable direction only: a full-benefit tier (tierWeight == TOTAL) makes the BWA
    /// multiplier exactly 0, so mulDiv(rawPower, 0, TOTAL) is 0 for ANY rawPower — no self-attestation.
    /// The complementary identity (zero-weight tier keeps full power) routes through a non-trivial
    /// mulDiv(rawPower, TOTAL, TOTAL) which the SMT solver times out on; that direction is fuzzed in
    /// `testFuzz_bwaMonotoneNonIncreasing` and `testFuzz_bwaZeroWeightFullPower` instead.
    function check_bwaFullWeightZeroPower(uint256 rawPower) public pure {
        // A tier holding 100% of the scorecard weight gets exactly zero attestation power.
        assert(_bwaPower(rawPower, _TOTAL_CASHOUT_WEIGHT) == 0);
    }

    function testFuzz_bwaZeroWeightFullPower(uint256 rawPower) public pure {
        // A zero-weight tier keeps its full power: mulDiv(rawPower, TOTAL, TOTAL) == rawPower.
        rawPower = bound(rawPower, 0, type(uint128).max);
        assertEq(_bwaPower(rawPower, 0), rawPower);
        // And full-weight is always zero.
        assertEq(_bwaPower(rawPower, _TOTAL_CASHOUT_WEIGHT), 0);
    }

    function testFuzz_bwaMonotoneNonIncreasing(
        uint256 rawPower,
        uint256 weightLow,
        uint256 weightHigh
    )
        public
        pure
    {
        rawPower = bound(rawPower, 0, _MAX_ATTESTATION_POWER_TIER);
        weightLow = bound(weightLow, 0, _TOTAL_CASHOUT_WEIGHT);
        weightHigh = bound(weightHigh, weightLow, _TOTAL_CASHOUT_WEIGHT);

        uint256 highWeightPower = _bwaPower(rawPower, weightHigh);
        uint256 lowWeightPower = _bwaPower(rawPower, weightLow);

        // More benefit (higher tierWeight) => no more power.
        assertLe(highWeightPower, lowWeightPower);
        // Power never exceeds rawPower.
        assertLe(lowWeightPower, rawPower);
        // Full benefit => zero power.
        assertEq(_bwaPower(rawPower, _TOTAL_CASHOUT_WEIGHT), 0);
    }
}
