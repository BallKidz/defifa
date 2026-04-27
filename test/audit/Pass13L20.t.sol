// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {DefifaHook} from "../../src/DefifaHook.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title Same-token constructor guard for DefifaHook
/// @notice Verifies that the constructor reverts when defifaToken == baseProtocolToken.
contract Pass13L20Test is Test {
    IJBDirectory internal directory;

    function setUp() public {
        directory = IJBDirectory(makeAddr("directory"));
        vm.etch(address(directory), hex"00");
    }

    /// @notice Deploying with the same token for both fee streams must revert.
    function test_sameTokenConstructorReverts() public {
        IERC20 token = IERC20(makeAddr("token"));

        vm.expectRevert(DefifaHook.DefifaHook_IdenticalTokens.selector);
        new DefifaHook(directory, token, token);
    }

    /// @notice Deploying with different tokens succeeds.
    function test_differentTokensConstructorSucceeds() public {
        IERC20 defifaToken = IERC20(makeAddr("defifaToken"));
        IERC20 baseToken = IERC20(makeAddr("baseToken"));

        DefifaHook hook = new DefifaHook(directory, defifaToken, baseToken);

        assertEq(address(hook.DEFIFA_TOKEN()), address(defifaToken));
        assertEq(address(hook.BASE_PROTOCOL_TOKEN()), address(baseToken));
    }
}
