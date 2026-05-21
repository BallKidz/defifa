// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {mulDiv} from "@prb/math/src/Common.sol";

import {DefifaGamePhase} from "../../src/enums/DefifaGamePhase.sol";
import {DefifaHookLib} from "../../src/libraries/DefifaHookLib.sol";

/// @notice Halmos smoke proofs for Defifa cash-out phase arithmetic.
contract DefifaHookLibHalmos {
    /// @notice The Defifa cash-out weight denominator.
    uint256 internal constant _TOTAL_CASHOUT_WEIGHT = 1_000_000_000_000_000_000;

    /// @notice Checks representative weighted cash-out amounts in scoring-style phases.
    function check_cashOutWeightedBoundaryTable() public pure {
        assert(
            DefifaHookLib.computeCashOutCount({
                gamePhase: DefifaGamePhase.SCORING,
                cumulativeMintPrice: 999,
                surplusValue: 7,
                totalAmountRedeemed: 3,
                cumulativeCashOutWeight: 0
            }) == 0
        );
        assert(
            DefifaHookLib.computeCashOutCount({
                gamePhase: DefifaGamePhase.COMPLETE,
                cumulativeMintPrice: 999,
                surplusValue: 7,
                totalAmountRedeemed: 3,
                cumulativeCashOutWeight: _TOTAL_CASHOUT_WEIGHT
            }) == 10
        );
        assert(
            DefifaHookLib.computeCashOutCount({
                gamePhase: DefifaGamePhase.SCORING,
                cumulativeMintPrice: 999,
                surplusValue: 10,
                totalAmountRedeemed: 4,
                cumulativeCashOutWeight: _TOTAL_CASHOUT_WEIGHT / 2
            }) == 7
        );
    }

    /// @notice Proves refund-style phases return the cumulative mint price, independent of pot state.
    /// @param cumulativeMintPrice The amount paid to mint the cashed-out NFTs.
    /// @param surplusValue The current project surplus.
    /// @param totalAmountRedeemed The amount already redeemed.
    /// @param cumulativeCashOutWeight The scorecard weight for the NFTs.
    function check_refundPhasesReturnMintPrice(
        uint128 cumulativeMintPrice,
        uint128 surplusValue,
        uint128 totalAmountRedeemed,
        uint128 cumulativeCashOutWeight
    )
        public
        pure
    {
        assert(
            DefifaHookLib.computeCashOutCount({
                gamePhase: DefifaGamePhase.MINT,
                cumulativeMintPrice: cumulativeMintPrice,
                surplusValue: surplusValue,
                totalAmountRedeemed: totalAmountRedeemed,
                cumulativeCashOutWeight: cumulativeCashOutWeight
            }) == cumulativeMintPrice
        );
        assert(
            DefifaHookLib.computeCashOutCount({
                gamePhase: DefifaGamePhase.NO_CONTEST,
                cumulativeMintPrice: cumulativeMintPrice,
                surplusValue: surplusValue,
                totalAmountRedeemed: totalAmountRedeemed,
                cumulativeCashOutWeight: cumulativeCashOutWeight
            }) == cumulativeMintPrice
        );
        assert(
            DefifaHookLib.computeCashOutCount({
                gamePhase: DefifaGamePhase.REFUND,
                cumulativeMintPrice: cumulativeMintPrice,
                surplusValue: surplusValue,
                totalAmountRedeemed: totalAmountRedeemed,
                cumulativeCashOutWeight: cumulativeCashOutWeight
            }) == cumulativeMintPrice
        );
    }

    /// @notice Proves weighted phases use cumulative pot value and ignore the original mint price.
    /// @param cumulativeMintPrice The amount paid to mint the cashed-out NFTs.
    /// @param surplusValue The current project surplus.
    /// @param totalAmountRedeemed The amount already redeemed.
    /// @param cumulativeCashOutWeight The scorecard weight for the NFTs.
    function check_weightedPhasesIgnoreMintPrice(
        uint128 cumulativeMintPrice,
        uint64 surplusValue,
        uint64 totalAmountRedeemed,
        uint64 cumulativeCashOutWeight
    )
        public
        pure
    {
        if (cumulativeCashOutWeight > _TOTAL_CASHOUT_WEIGHT) return;

        uint256 expected = mulDiv({
            x: uint256(surplusValue) + uint256(totalAmountRedeemed),
            y: cumulativeCashOutWeight,
            denominator: _TOTAL_CASHOUT_WEIGHT
        });

        assert(
            DefifaHookLib.computeCashOutCount({
                gamePhase: DefifaGamePhase.COMPLETE,
                cumulativeMintPrice: cumulativeMintPrice,
                surplusValue: surplusValue,
                totalAmountRedeemed: totalAmountRedeemed,
                cumulativeCashOutWeight: cumulativeCashOutWeight
            }) == expected
        );
        assert(
            DefifaHookLib.computeCashOutCount({
                gamePhase: DefifaGamePhase.SCORING,
                cumulativeMintPrice: cumulativeMintPrice,
                surplusValue: surplusValue,
                totalAmountRedeemed: totalAmountRedeemed,
                cumulativeCashOutWeight: cumulativeCashOutWeight
            }) == expected
        );
    }
}
