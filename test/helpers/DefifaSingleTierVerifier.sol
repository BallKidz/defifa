// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// forge-lint: disable-start(unaliased-plain-import)
import "forge-std/Test.sol";
// forge-lint: disable-end(unaliased-plain-import)

import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBCurrencyIds} from "@bananapus/core-v6/src/libraries/JBCurrencyIds.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBCashOutTerminal} from "@bananapus/core-v6/src/interfaces/IJBCashOutTerminal.sol";

/// @notice Holds the redemption + post-redemption surplus assertions for
/// `testSetCashOutRatesAndRedeem_singleTier`. Lives in its own contract so the test reaches it over an
/// external CALL — that boundary is what keeps Yul under the stack budget, since the IR optimizer cannot
/// inline the JBAccountingContext-iterating body of `currentSurplusOf` back into the (already over-tall)
/// fuzz test body.
contract DefifaSingleTierVerifier is Test {
    struct Args {
        IJBTerminal terminal;
        IJBCashOutTerminal cashOutTerminal;
        address[] users;
        bytes[] cashOutMetadatas;
        uint256 projectId;
        uint256 nOfOtherTiers;
        uint256 nUsersWithWinningTier;
        uint256 totalWeight;
        uint256 totalCashOutWeight;
        uint256 assignedCashOutWeight;
        uint8 baseCashOutWeight;
        uint8 winningTierExtraWeight;
    }

    function verify(Args memory a) external {
        uint256 pot = a.terminal.currentSurplusOf(a.projectId, new address[](0), 18, JBCurrencyIds.ETH);

        for (uint256 i = 0; i < a.users.length; i++) {
            _redeemAndAssertUser(a, pot, i);
        }

        uint256 remainingSurplus = a.terminal.currentSurplusOf(a.projectId, new address[](0), 18, JBCurrencyIds.ETH);
        assertApproxEqAbs(
            remainingSurplus, pot * (a.totalCashOutWeight - a.assignedCashOutWeight) / a.totalCashOutWeight, 10 ** 14
        );
    }

    function _redeemAndAssertUser(Args memory a, uint256 pot, uint256 i) internal {
        address user = a.users[i];
        uint256 tier = i <= a.nOfOtherTiers ? i + 1 : a.nOfOtherTiers + 1;
        uint256 tierWeight = tier == a.nOfOtherTiers + 1
            ? uint256(a.baseCashOutWeight) + uint256(a.winningTierExtraWeight)
            : a.baseCashOutWeight;

        vm.prank(user);
        a.cashOutTerminal
            .cashOutTokensOf({
                holder: user,
                projectId: a.projectId,
                cashOutCount: 0,
                tokenToReclaim: JBConstants.NATIVE_TOKEN,
                minTokensReclaimed: 0,
                beneficiary: payable(user),
                metadata: a.cashOutMetadatas[i],
                referralProjectId: 0
            });

        uint256 expected = (pot * tierWeight) / a.totalWeight;
        if (tier == a.nOfOtherTiers + 1) {
            expected = expected / a.nUsersWithWinningTier;
        }
        assertApproxEqRel(expected, user.balance, 0.0001 ether);
    }
}
