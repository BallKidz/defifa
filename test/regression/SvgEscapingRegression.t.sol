// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {DefifaTokenUriResolver} from "../../src/DefifaTokenUriResolver.sol";

contract SvgEscapingHarness is DefifaTokenUriResolver {
    constructor() DefifaTokenUriResolver(address(this)) {}

    function exposedEscapeSvg(string memory input) external pure returns (string memory) {
        return _escapeSvg(input);
    }
}

contract SvgEscapingRegressionTest is Test {
    function test_EscapeSvg_EscapesDoubleQuotes() public {
        SvgEscapingHarness resolver = new SvgEscapingHarness();

        assertEq(resolver.exposedEscapeSvg('"'), "&quot;");
        assertEq(resolver.exposedEscapeSvg('Team "A"'), "Team &quot;A&quot;");
    }
}
