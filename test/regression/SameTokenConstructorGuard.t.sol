// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Defifa1155Hook} from "../../src/Defifa1155Hook.sol";
import {DefifaHook} from "../../src/DefifaHook.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBToken} from "@bananapus/core-v6/src/interfaces/IJBToken.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";

/// @title Fee-project constructor guard for both hooks
/// @notice Verifies that the constructors reject one project for both fee streams, and that the fee tokens are the
/// projects' tokens in `JBTokens`.
contract SameTokenConstructorGuardTest is Test {
    IJBDirectory internal directory;
    IJBTokens internal tokens;

    function setUp() public {
        directory = IJBDirectory(makeAddr("directory"));
        vm.etch(address(directory), hex"00");
        tokens = IJBTokens(makeAddr("tokens"));
        vm.etch(address(tokens), hex"00");
    }

    /// @notice Deploying with the same project for both fee streams must revert.
    function test_sameProjectConstructorReverts() public {
        vm.expectRevert(abi.encodeWithSelector(DefifaHook.DefifaHook_IdenticalFeeProjects.selector, 5));
        new DefifaHook(directory, tokens, 5, 5);

        vm.expectRevert(abi.encodeWithSelector(Defifa1155Hook.Defifa1155Hook_IdenticalFeeProjects.selector, 5));
        new Defifa1155Hook(directory, tokens, 5, 5);
    }

    /// @notice The fee tokens are whatever `JBTokens` holds for each project.
    function test_feeTokensAreTheProjectsTokens() public {
        address defifaToken = makeAddr("defifaToken");
        address baseToken = makeAddr("baseToken");
        vm.mockCall(address(tokens), abi.encodeCall(IJBTokens.tokenOf, (5)), abi.encode(IJBToken(defifaToken)));
        vm.mockCall(address(tokens), abi.encodeCall(IJBTokens.tokenOf, (1)), abi.encode(IJBToken(baseToken)));

        DefifaHook hook = new DefifaHook(directory, tokens, 5, 1);
        assertEq(address(hook.DEFIFA_TOKEN()), defifaToken);
        assertEq(address(hook.BASE_PROTOCOL_TOKEN()), baseToken);

        Defifa1155Hook hook1155 = new Defifa1155Hook(directory, tokens, 5, 1);
        assertEq(address(hook1155.DEFIFA_TOKEN()), defifaToken);
        assertEq(address(hook1155.BASE_PROTOCOL_TOKEN()), baseToken);
    }
}
