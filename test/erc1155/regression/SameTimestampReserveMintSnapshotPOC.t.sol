// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {DefifaGovernorTest} from "../DefifaGovernor.t.sol";
import {DefifaGovernor} from "../../../src/DefifaGovernor.sol";
import {DefifaVotingReferee} from "../../../src/referees/DefifaVotingReferee.sol";
import {Defifa1155Hook} from "../../../src/Defifa1155Hook.sol";
import {DefifaScorecardState} from "../../../src/enums/DefifaScorecardState.sol";
import {DefifaLaunchProjectData} from "../../../src/structs/DefifaLaunchProjectData.sol";
import {DefifaTierCashOutWeight} from "../../../src/structs/DefifaTierCashOutWeight.sol";
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

        (uint256 projectId, Defifa1155Hook nft, DefifaGovernor gov) = createDefifaProject(data);

        vm.warp(data.start - data.mintPeriodDuration - data.refundPeriodDuration);
        _mintOne(projectId, LOSING_HOLDER, 1);
        _mintOne(projectId, WINNING_HOLDER, 2);

        assertEq(nft.adjustedPendingReservesFor(1), 1, "tier 1 should have one pending reserve at submission");

        vm.warp(data.start + 1);
        uint256 submitTimestamp = block.timestamp;

        DefifaTierCashOutWeight[] memory weights = new DefifaTierCashOutWeight[](2);
        weights[0] = DefifaTierCashOutWeight({id: 1, cashOutWeight: 0});
        weights[1] = DefifaTierCashOutWeight({id: 2, cashOutWeight: nft.TOTAL_CASHOUT_WEIGHT()});

        uint256 scorecardId = votingReferee.submitScorecardFor(projectId, weights);

        // Same block, after submission: mint the tier-1 reserve to the beneficiary the attacker controls.
        nft.mintReservesFor(1, 1);

        vm.warp(submitTimestamp + 1);

        // The paid losing-tier holder held its unit before submission, so it supplies half its tier's power.
        vm.prank(LOSING_HOLDER);
        uint256 holderWeight = votingReferee.attestToScorecardFrom(projectId, scorecardId);
        assertEq(
            holderWeight,
            votingReferee.MAX_ATTESTATION_POWER_TIER() / 2,
            "paid losing holder supplies half its tier's power"
        );

        // The reserve beneficiary minted AFTER submission: the frozen snapshot gives it zero power, so attesting
        // reverts on the zero-weight guard. It cannot top up quorum for the self-serving scorecard.
        vm.prank(RESERVE_BENEFICIARY);
        vm.expectRevert(
            abi.encodeWithSelector(
                DefifaVotingReferee.DefifaVotingReferee_NotAllowed.selector, projectId, scorecardId, RESERVE_BENEFICIARY
            )
        );
        votingReferee.attestToScorecardFrom(projectId, scorecardId);

        // A winner-take-all scorecard needs 75% of the attestation possible, (2 - 1) * MAX, so quorum is not reached
        // and the scorecard never succeeds.
        assertLt(
            votingReferee.attestationCountOf(projectId, scorecardId),
            votingReferee.MAX_ATTESTATION_POWER_TIER() * 3 / 4,
            "same-timestamp reserve mint must not reach quorum"
        );

        vm.warp(submitTimestamp + 1 + votingReferee.attestationGracePeriodOf(projectId));
        assertTrue(
            votingReferee.stateOf(projectId, scorecardId) != DefifaScorecardState.SUCCEEDED,
            "scorecard must not succeed off a post-submission reserve mint"
        );
    }

    /// @notice Reserves minted in the submission block, before submission, must stay in the tier's attestation
    /// total, so a holder of 3 of a tier's 8 units cannot attest as if they held 3 of 4.
    function test_reserveMintBeforeSameTimestampSubmissionCannotInflatePower() public {
        DefifaLaunchProjectData memory data = getBasicDefifaLaunchData(2);
        data.tiers[0].reservedRate = 1;
        data.tiers[0].reservedTokenBeneficiary = RESERVE_BENEFICIARY;

        (uint256 projectId, Defifa1155Hook nft, DefifaGovernor gov) = createDefifaProject(data);

        vm.warp(data.start - data.mintPeriodDuration - data.refundPeriodDuration);
        _mintOne(projectId, LOSING_HOLDER, 1);
        _mintOne(projectId, LOSING_HOLDER, 1);
        _mintOne(projectId, LOSING_HOLDER, 1);
        _mintOne(projectId, address(0x1004), 1);
        _mintOne(projectId, WINNING_HOLDER, 2);
        assertEq(nft.adjustedPendingReservesFor(1), 4, "tier 1 owes four reserves");

        vm.warp(data.start + 1);

        // Same block: mint every pending reserve, then submit a scorecard paying the attacker's other tier.
        nft.mintReservesFor(1, 4);
        DefifaTierCashOutWeight[] memory weights = new DefifaTierCashOutWeight[](2);
        weights[0] = DefifaTierCashOutWeight({id: 1, cashOutWeight: 0});
        weights[1] = DefifaTierCashOutWeight({id: 2, cashOutWeight: nft.TOTAL_CASHOUT_WEIGHT()});
        uint256 scorecardId = votingReferee.submitScorecardFor(projectId, weights);

        vm.warp(block.timestamp + 1);

        // The attacker holds 3 of tier 1's 8 units.
        vm.prank(LOSING_HOLDER);
        uint256 weight = votingReferee.attestToScorecardFrom(projectId, scorecardId);
        assertEq(weight, votingReferee.MAX_ATTESTATION_POWER_TIER() * 3 / 8, "3 of 8 units");

        vm.warp(block.timestamp + votingReferee.attestationGracePeriodOf(projectId));
        assertTrue(
            votingReferee.stateOf(projectId, scorecardId) != DefifaScorecardState.SUCCEEDED,
            "a minority of the losing tier cannot pass a winner-take-all scorecard"
        );
    }

    function _mintOne(uint256 projectId, address beneficiary, uint16 tierId) internal {
        uint16[] memory tiers = new uint16[](1);
        tiers[0] = tierId;
        bytes memory metadata = _buildPayMetadata(abi.encode(beneficiary, tiers, _ones(1)));

        vm.deal(beneficiary, 1 ether);
        vm.prank(beneficiary);
        jbMultiTerminal().pay{value: 1 ether}(
            projectId, JBConstants.NATIVE_TOKEN, 1 ether, beneficiary, 0, "", metadata
        );
    }
}
