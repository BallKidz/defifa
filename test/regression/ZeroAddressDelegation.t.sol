// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {DefifaGamePhase} from "../../src/enums/DefifaGamePhase.sol";
import {DefifaERC1155Harness} from "../DefifaERC1155.t.sol";

/// @notice Delegation state must only change for accounts that actually receive or hold positions. Calls that move
/// nothing (a reserve mint with nothing pending, a zero-amount transfer) must not write delegation, and the zero
/// address must never act as a delegator for mints or burns.
contract ZeroAddressDelegationTest is DefifaERC1155Harness {
    address oracle = makeAddr("oracle");

    function _defaultDelegate() internal override returns (address) {
        return oracle;
    }

    /// @notice Minting zero reserves in a tier with no reserve beneficiary writes no delegation, so the default
    /// delegate keeps the tier's attestation power.
    function test_emptyReserveMintDoesNotDelegateTheZeroAddress() public {
        // Back to COUNTDOWN, when reserve minting is not paused.
        vm.warp(launchedAt);
        assertEq(uint256(nft.gamePhaseReporter().currentGamePhaseOf(gameId)), uint256(DefifaGamePhase.COUNTDOWN));

        vm.prank(makeAddr("stranger"));
        nft.mintReservesFor(2, 0);
        assertEq(nft.getTierDelegateOf(address(0), 2), address(0), "zero address has no delegate");

        vm.warp(launchData.start - launchData.mintPeriodDuration - launchData.refundPeriodDuration);
        _pay(alice, _ids(2, 3), _counts(3, 3));

        assertEq(nft.getTierAttestationUnitsOf(oracle, 2), 3 * TIER_PRICE, "default delegate holds tier 2 units");
        assertEq(nft.getTierTotalAttestationUnitsOf(2), 3 * TIER_PRICE, "tier 2 total");

        // Transfers in the tier keep working.
        vm.prank(alice);
        nft.safeTransferFrom(alice, bob, 2, 1, "");
        assertEq(nft.balanceOf(bob, 2), 1, "transfer went through");
    }

    /// @notice A zero-amount transfer cannot pin a recipient's delegate to themselves, so a later reserve mint still
    /// applies the default delegate.
    function test_zeroAmountTransferDoesNotSetDelegate() public {
        vm.prank(bob);
        nft.safeTransferFrom(bob, reserveBeneficiary, 1, 0, "");
        assertEq(nft.getTierDelegateOf(reserveBeneficiary, 1), address(0), "no delegate written");

        _pay(alice, _ids(1, 2), _counts(2, 1));
        vm.warp(launchData.start);
        nft.mintReservesFor(1, 1);

        assertEq(nft.getTierDelegateOf(reserveBeneficiary, 1), oracle, "reserve beneficiary delegates to default");
        assertEq(nft.getTierAttestationUnitsOf(oracle, 1), 3 * TIER_PRICE, "default delegate holds all tier 1 units");
    }
}
