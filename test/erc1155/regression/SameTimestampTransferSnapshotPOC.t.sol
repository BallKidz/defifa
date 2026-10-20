// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {DefifaGovernanceHardeningTest} from "../DefifaGovernanceHardening.t.sol";
import {DefifaGovernor} from "../../../src/DefifaGovernor.sol";
import {DefifaVotingReferee} from "../../../src/referees/DefifaVotingReferee.sol";
import {DefifaTierCashOutWeight} from "../../../src/structs/DefifaTierCashOutWeight.sol";

/// @notice Regression test for the same-timestamp checkpoint-overwrite class: a transfer (or reserve mint)
/// in the SAME block as submission used to be folded into that scorecard's snapshot because attestation checkpoints
/// are `block.timestamp`-keyed and equal-key writes overwrite in place. The fix reads the BWA snapshot one second
/// before submission, so the whole submission block is excluded. This test asserts a same-block transfer recipient
/// gains no attestation power while the pre-submission holders keep theirs.
contract SameTimestampTransferSnapshotPOC is DefifaGovernanceHardeningTest {
    function test_sameTimestampTransferCannotMoveScorecardSnapshot() external {
        _setupGame({nTiers: 4, tierPrice: 1 ether});
        _toScoring();

        DefifaTierCashOutWeight[] memory scorecard = _evenScorecard(4);
        uint256 scorecardId = votingReferee.submitScorecardFor(_gameId, scorecard);

        address attacker = address(0xBEEF);

        // Same block, after submission: sweep three holders' positions to the attacker.
        for (uint256 i; i < 3; i++) {
            address originalHolder = _users[i];
            uint256 tokenId = i + 1;

            vm.prank(originalHolder);
            _nft.safeTransferFrom({from: originalHolder, to: attacker, id: tokenId, value: 1, data: ""});

            assertEq(_nft.balanceOf(originalHolder, tokenId), 0, "holder swept");
            assertEq(_nft.balanceOf(attacker, tokenId), 1, "attacker holds the position");
        }

        // Move into the attestation window.
        vm.warp(block.timestamp + 1);

        // The attacker received every unit in the submission block, so the frozen pre-submission snapshot grants it
        // no power and attesting reverts on the zero-weight guard.
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(
                DefifaVotingReferee.DefifaVotingReferee_NotAllowed.selector, _gameId, scorecardId, attacker
            )
        );
        votingReferee.attestToScorecardFrom(_gameId, scorecardId);

        // Each original holder kept its pre-submission snapshot power and can still attest with it.
        for (uint256 i; i < 3; i++) {
            vm.prank(_users[i]);
            uint256 weight = votingReferee.attestToScorecardFrom(_gameId, scorecardId);
            assertGt(weight, 0, "pre-submission holder retains its frozen attestation power");
        }
    }
}
