// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {DefifaGovernorTest} from "../DefifaGovernor.t.sol";
import {DefifaGovernor} from "../../src/DefifaGovernor.sol";
import {DefifaHook} from "../../src/DefifaHook.sol";
import {DefifaScorecardState} from "../../src/enums/DefifaScorecardState.sol";
import {DefifaLaunchProjectData} from "../../src/structs/DefifaLaunchProjectData.sol";
import {DefifaTierCashOutWeight} from "../../src/structs/DefifaTierCashOutWeight.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";

/// @notice Regression test for the same-timestamp reserve-mint snapshot-injection case.
/// @dev A reserve beneficiary used to be able to call `mintReservesFor` in the SAME block as `submitScorecardFor`,
/// after submission, and have the equally-keyed attestation checkpoint overwritten so the freshly minted units
/// counted toward that scorecard's BWA power — manufacturing quorum for a self-serving cash-out scorecard. The fix
/// freezes the BWA snapshot one second before submission, excluding the whole submission block. This test asserts
/// the reserve beneficiary gains NO attestation power and the scorecard cannot reach quorum.
contract SameTimestampReserveMintSnapshotPOC is DefifaGovernorTest {
    address internal constant LOSING_HOLDER = address(0x1001);
    address internal constant WINNING_HOLDER = address(0x1002);
    address internal constant RESERVE_BENEFICIARY = address(0x1003);

    function test_sameTimestampReserveMintCannotGainSubmittedScorecardSnapshot() public {
        DefifaLaunchProjectData memory data = getBasicDefifaLaunchData(2);
        data.tiers[0].reservedRate = 1;
        data.tiers[0].reservedTokenBeneficiary = RESERVE_BENEFICIARY;

        (uint256 projectId, DefifaHook nft, DefifaGovernor gov) = createDefifaProject(data);

        vm.warp(data.start - data.mintPeriodDuration - data.refundPeriodDuration);
        _mintOne(projectId, LOSING_HOLDER, 1);
        _mintOne(projectId, WINNING_HOLDER, 2);

        assertEq(nft.adjustedPendingReservesFor(1), 1, "tier 1 should have one pending reserve at submission");

        vm.warp(data.start + 1);
        uint256 submitTimestamp = block.timestamp;

        DefifaTierCashOutWeight[] memory weights = new DefifaTierCashOutWeight[](2);
        weights[0] = DefifaTierCashOutWeight({id: 1, cashOutWeight: 0});
        weights[1] = DefifaTierCashOutWeight({id: 2, cashOutWeight: nft.TOTAL_CASHOUT_WEIGHT()});

        uint256 scorecardId = gov.submitScorecardFor(projectId, weights);

        // Same block, after submission: mint the tier-1 reserve to the beneficiary the attacker controls.
        nft.mintReservesFor(1, 1);

        vm.warp(submitTimestamp + 1);

        // The paid losing-tier holder held its unit before submission, so it still supplies half quorum.
        vm.prank(LOSING_HOLDER);
        uint256 holderWeight = gov.attestToScorecardFrom(projectId, scorecardId);
        assertEq(holderWeight, gov.MAX_ATTESTATION_POWER_TIER() / 2, "paid losing holder supplies half quorum");

        // The reserve beneficiary minted AFTER submission: the frozen snapshot gives it zero power, so attesting
        // reverts on the zero-weight guard. It cannot top up quorum for the self-serving scorecard.
        vm.prank(RESERVE_BENEFICIARY);
        vm.expectRevert(
            abi.encodeWithSelector(
                DefifaGovernor.DefifaGovernor_NotAllowed.selector, projectId, scorecardId, RESERVE_BENEFICIARY
            )
        );
        gov.attestToScorecardFrom(projectId, scorecardId);

        // Quorum is not reached and the scorecard never succeeds.
        assertLt(
            gov.attestationCountOf(projectId, scorecardId),
            gov.quorum(projectId),
            "same-timestamp reserve mint must not reach quorum"
        );

        vm.warp(submitTimestamp + 1 + gov.attestationGracePeriodOf(projectId));
        assertTrue(
            gov.stateOf(projectId, scorecardId) != DefifaScorecardState.SUCCEEDED,
            "scorecard must not succeed off a post-submission reserve mint"
        );
    }

    function _mintOne(uint256 projectId, address beneficiary, uint16 tierId) internal {
        uint16[] memory tiers = new uint16[](1);
        tiers[0] = tierId;
        bytes memory metadata = _buildPayMetadata(abi.encode(beneficiary, tiers));

        vm.deal(beneficiary, 1 ether);
        vm.prank(beneficiary);
        jbMultiTerminal().pay{value: 1 ether}(
            projectId, JBConstants.NATIVE_TOKEN, 1 ether, beneficiary, 0, "", metadata
        );
    }
}
