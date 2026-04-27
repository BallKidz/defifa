// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {DefifaUSDCTest} from "../DefifaUSDC.t.sol";
import {DefifaLaunchProjectData} from "../../src/structs/DefifaLaunchProjectData.sol";
import {DefifaTierCashOutWeight} from "../../src/structs/DefifaTierCashOutWeight.sol";
import {DefifaTierParams} from "../../src/structs/DefifaTierParams.sol";
import {IJB721TokenUriResolver} from "@bananapus/721-hook-v6/src/interfaces/IJB721TokenUriResolver.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBSplit} from "@bananapus/core-v6/src/structs/JBSplit.sol";

/// @notice Regression test for the currency mismatch fix: ERC-20 games now correctly resolve payout limits via
/// baseCurrency. Before the fix, using a non-canonical currency (e.g. currency=1 for USDC) caused sendPayoutsOf to use
/// uint32(uint160(token)) which didn't match the stored payout limit currency, silently skipping payouts.
/// After the fix, fulfillCommitmentsOf uses metadata.baseCurrency which always matches the stored limit.
contract CurrencyMismatchBypassTest is DefifaUSDCTest {
    /// @notice Verify that an ERC-20 game with non-canonical currency (1) correctly pays out commitment fees.
    function test_nonCanonicalCurrencyPayoutsNowSucceed() external {
        uint104 tierPrice = 100e6;

        (_pid, _nft, _gov) = _launch(_launchDataUsdcNonCanonical(tierPrice));
        _users = new address[](2);
        _users[0] = _addr(0);
        _users[1] = _addr(1);

        vm.warp(block.timestamp + 1 days + 1);

        _mintUsdc(_users[0], 1, tierPrice);
        _mintUsdc(_users[1], 2, tierPrice);
        _delegateSelf(_users[0], 1);
        _delegateSelf(_users[1], 2);

        vm.warp(block.timestamp + 2 days);

        DefifaTierCashOutWeight[] memory scorecard = new DefifaTierCashOutWeight[](2);
        scorecard[0] = DefifaTierCashOutWeight({id: 1, cashOutWeight: _nft.TOTAL_CASHOUT_WEIGHT()});
        scorecard[1] = DefifaTierCashOutWeight({id: 2, cashOutWeight: 0});

        vm.prank(_users[1]);
        uint256 scorecardId = _gov.submitScorecardFor(_pid, scorecard);

        vm.prank(_users[1]);
        _gov.attestToScorecardFrom(_pid, scorecardId);

        vm.warp(block.timestamp + _gov.attestationGracePeriodOf(_pid) + 1);

        uint256 preRatificationBalance = _balance();
        uint256 expectedFee = (preRatificationBalance * 75_000_000) / JBConstants.SPLITS_TOTAL_PERCENT;

        vm.prank(_users[1]);
        _gov.ratifyScorecardFrom(_pid, scorecard);

        // After the fix: payout succeeds, fulfilledCommitmentsOf stores the actual fee (not the sentinel).
        assertEq(
            deployer.fulfilledCommitmentsOf(_pid), expectedFee, "fulfilled commitments equals the expected fee amount"
        );

        // The fee has been paid out, reducing the game pot.
        assertEq(_balance(), preRatificationBalance - expectedFee, "balance decreased by the fee amount");

        // Winner cashes out and receives only the post-fee surplus, not the full pot.
        uint256 winnerBalBefore = usdc.balanceOf(_users[0]);
        _cashOutUsdc(_users[0], 1, 1);
        uint256 winnerReceived = usdc.balanceOf(_users[0]) - winnerBalBefore;

        assertEq(
            winnerReceived,
            preRatificationBalance - expectedFee,
            "winner receives the post-fee surplus, not the full pot"
        );
    }

    function _launchDataUsdcNonCanonical(uint104 tierPrice) internal returns (DefifaLaunchProjectData memory) {
        DefifaTierParams[] memory tp = new DefifaTierParams[](2);
        for (uint256 i; i < 2; i++) {
            tp[i] = DefifaTierParams({
                reservedRate: 1001,
                reservedTokenBeneficiary: address(0),
                encodedIPFSUri: bytes32(0),
                shouldUseReservedTokenBeneficiaryAsDefault: false,
                name: "DEFIFA"
            });
        }

        // Non-canonical currency (1 = ETH currency ID) for a USDC token.
        // Before the fix, this caused fulfillCommitmentsOf to silently skip payouts.
        return DefifaLaunchProjectData({
            name: "DEFIFA_USDC_NONCANONICAL",
            projectUri: "",
            contractUri: "",
            baseUri: "",
            token: JBAccountingContext({token: address(usdc), decimals: 6, currency: 1}),
            mintPeriodDuration: 1 days,
            start: uint48(block.timestamp + 3 days),
            refundPeriodDuration: 1 days,
            splits: new JBSplit[](0),
            attestationStartTime: 0,
            attestationGracePeriod: 1 days,
            defaultAttestationDelegate: address(0),
            tierPrice: tierPrice,
            tiers: tp,
            defaultTokenUriResolver: IJB721TokenUriResolver(address(0)),
            terminal: jbMultiTerminal(),
            minParticipation: 0,
            scorecardTimeout: 0,
            timelockDuration: 0
        });
    }
}
