// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {Defifa1155Hook} from "../src/Defifa1155Hook.sol";
import {DefifaHook} from "../src/DefifaHook.sol";
import {IDefifa1155Hook} from "../src/interfaces/IDefifa1155Hook.sol";
import {IDefifaHook} from "../src/interfaces/IDefifaHook.sol";

/// @notice `DefifaDeployer`, `DefifaGovernor` and `DefifaTokenUriResolver` drive both game hooks through the ERC-721
/// hook's ABI. Every function they call must keep the same selector on the ERC-1155 hook. `cashOutWeightOf(uint256)`
/// is overloaded, so the resolver's use of it is covered by `DefifaERC1155Test.test_uriResolvesBothTokenIdsOfATier`.
contract DefifaHookParityTest is Test {
    function test_consumersCallTheSameSelectorsOnBothHooks() public pure {
        bytes4[2][16] memory pairs = [
            [DefifaHook.initialize.selector, Defifa1155Hook.initialize.selector],
            [IDefifaHook.setTierCashOutWeightsTo.selector, IDefifa1155Hook.setTierCashOutWeightsTo.selector],
            [IDefifaHook.TOTAL_CASHOUT_WEIGHT.selector, IDefifa1155Hook.TOTAL_CASHOUT_WEIGHT.selector],
            [IDefifaHook.adjustedPendingReservesFor.selector, IDefifa1155Hook.adjustedPendingReservesFor.selector],
            [IDefifaHook.amountRedeemed.selector, IDefifa1155Hook.amountRedeemed.selector],
            [IDefifaHook.baseURI.selector, IDefifa1155Hook.baseURI.selector],
            [IDefifaHook.cashOutWeightIsSet.selector, IDefifa1155Hook.cashOutWeightIsSet.selector],
            [IDefifaHook.currentSupplyOfTier.selector, IDefifa1155Hook.currentSupplyOfTier.selector],
            [IDefifaHook.defaultAttestationDelegate.selector, IDefifa1155Hook.defaultAttestationDelegate.selector],
            [IDefifaHook.gamePhaseReporter.selector, IDefifa1155Hook.gamePhaseReporter.selector],
            [IDefifaHook.gamePotReporter.selector, IDefifa1155Hook.gamePotReporter.selector],
            [
                IDefifaHook.getPastTierAttestationUnitsOf.selector,
                IDefifa1155Hook.getPastTierAttestationUnitsOf.selector
            ],
            [
                IDefifaHook.getPastTierTotalAttestationUnitsOf.selector,
                IDefifa1155Hook.getPastTierTotalAttestationUnitsOf.selector
            ],
            [IDefifaHook.store.selector, IDefifa1155Hook.store.selector],
            [IDefifaHook.tierNameOf.selector, IDefifa1155Hook.tierNameOf.selector],
            [IDefifaHook.totalMintCost.selector, IDefifa1155Hook.totalMintCost.selector]
        ];
        for (uint256 i; i < pairs.length; i++) {
            assertEq(pairs[i][0], pairs[i][1]);
        }
    }
}
