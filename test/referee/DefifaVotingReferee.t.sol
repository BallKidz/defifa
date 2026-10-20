// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {DefifaDeployer} from "../../src/DefifaDeployer.sol";
import {DefifaVotingReferee} from "../../src/referees/DefifaVotingReferee.sol";
import {DefifaScorecardState} from "../../src/enums/DefifaScorecardState.sol";
import {DefifaLaunchProjectData} from "../../src/structs/DefifaLaunchProjectData.sol";
import {DefifaTierCashOutWeight} from "../../src/structs/DefifaTierCashOutWeight.sol";

import {RefereeTestBase} from "./RefereeTestBase.sol";

/// @notice The sample referee keeps holder attestation and forwards an approved scorecard to the governor.
abstract contract DefifaVotingRefereeTest is RefereeTestBase {
    DefifaVotingReferee referee;

    function setUp() public virtual override {
        super.setUp();
        referee = new DefifaVotingReferee(jbController());
    }

    /// @notice Launch an `n`-tier game judged by the voting referee, one holder per tier, and move to scoring.
    function _launchVotingGame(uint8 n, uint256 gracePeriod) internal {
        _launch(
            _launchData({
                n: n, referee: address(referee), refereeData: abi.encode(0, gracePeriod), timelockDuration: 1 days
            })
        );
        for (uint256 i = 1; i <= n; i++) {
            _mint(_addr(i), i);
        }
        _toScoring();
    }

    /// @notice Every holder attests to `scorecardId`; reverts from zero-weight holders are ignored.
    function _attestAll(uint256 n, uint256 scorecardId) internal {
        vm.warp(block.timestamp + 1);
        for (uint256 i = 1; i <= n; i++) {
            vm.prank(_addr(i));
            try referee.attestToScorecardFrom(gameId, scorecardId) {} catch {}
        }
    }

    function test_initializeGameFor_onlyProjectOwner() external {
        _launchVotingGame(2, 1 days);
        vm.prank(_addr(9));
        vm.expectRevert(
            abi.encodeWithSelector(DefifaVotingReferee.DefifaVotingReferee_NotProjectOwner.selector, gameId, _addr(9))
        );
        referee.initializeGameFor(gameId, abi.encode(0, 1 days));
    }

    function test_initializeGameFor_once() external {
        _launchVotingGame(2, 1 days);
        vm.prank(address(deployer));
        vm.expectRevert(
            abi.encodeWithSelector(DefifaVotingReferee.DefifaVotingReferee_AlreadyInitialized.selector, gameId)
        );
        referee.initializeGameFor(gameId, abi.encode(0, 1 days));
    }

    function test_initializeGameFor_gracePeriodFloor() external {
        DefifaLaunchProjectData memory d = _launchData({
            n: 2, referee: address(referee), refereeData: abi.encode(0, 1 hours), timelockDuration: 1 days
        });
        vm.expectRevert(
            abi.encodeWithSelector(
                DefifaVotingReferee.DefifaVotingReferee_GracePeriodTooShort.selector, 1 hours, 1 days
            )
        );
        deployer.launchGameWith(d);
    }

    function test_holderVoteRatifies() external {
        _launchVotingGame(4, 1 days);
        DefifaTierCashOutWeight[] memory sc = _even(4);

        uint256 scorecardId = referee.submitScorecardFor(gameId, sc);
        _attestAll(4, scorecardId);
        vm.warp(block.timestamp + 1 days);
        assertEq(uint256(referee.stateOf(gameId, scorecardId)), uint256(DefifaScorecardState.SUCCEEDED));

        referee.forwardScorecardFor(gameId, sc);
        assertEq(uint256(governor.stateOf(gameId, scorecardId)), uint256(DefifaScorecardState.QUEUED));

        vm.warp(block.timestamp + 1 days);
        governor.ratifyScorecardFrom(gameId, sc);
        assertEq(uint256(referee.stateOf(gameId, scorecardId)), uint256(DefifaScorecardState.RATIFIED));
    }

    function test_forwardRequiresSucceeded() external {
        _launchVotingGame(4, 1 days);
        DefifaTierCashOutWeight[] memory sc = _even(4);

        uint256 scorecardId = referee.submitScorecardFor(gameId, sc);
        _attestAll(4, scorecardId);

        vm.expectRevert(
            abi.encodeWithSelector(
                DefifaVotingReferee.DefifaVotingReferee_NotAllowed.selector, gameId, scorecardId, address(this)
            )
        );
        referee.forwardScorecardFor(gameId, sc);
    }

    function test_forwardOnce() external {
        _launchVotingGame(4, 1 days);
        DefifaTierCashOutWeight[] memory a = _even(4);
        DefifaTierCashOutWeight[] memory b = _even(4);
        b[0].cashOutWeight += 1;
        b[1].cashOutWeight -= 1;

        uint256 aId = referee.submitScorecardFor(gameId, a);
        uint256 bId = referee.submitScorecardFor(gameId, b);
        _attestAll(4, aId);
        _attestAll(4, bId);
        vm.warp(block.timestamp + 1 days);

        referee.forwardScorecardFor(gameId, a);
        referee.forwardScorecardFor(gameId, b);
        vm.expectRevert(
            abi.encodeWithSelector(DefifaVotingReferee.DefifaVotingReferee_AlreadyForwarded.selector, gameId, aId)
        );
        referee.forwardScorecardFor(gameId, a);
        assertEq(uint256(governor.stateOf(gameId, aId)), uint256(DefifaScorecardState.DEFEATED));
    }

    function test_quorumCarriesOver() external {
        _launchVotingGame(2, 1 days);
        uint256 scorecardId = referee.submitScorecardFor(gameId, _winnerTakeAll(2, 1));
        assertEq(
            referee.quorumOf(gameId, scorecardId),
            referee.MAX_ATTESTATION_POWER_TIER() * referee.QUORUM_WINNER_TAKE_ALL_BPS() / 10_000
        );
    }

    function test_namedRefereeReplacesEnforcedFlag() external {
        address ref = address(0xBEEF);
        _launch(_launchData({n: 2, referee: ref, refereeData: "", timelockDuration: 0}));
        _mint(_addr(1), 1);
        _mint(_addr(2), 2);
        _toScoring();

        DefifaTierCashOutWeight[] memory sc = _winnerTakeAll(2, 2);
        vm.prank(ref);
        uint256 scorecardId = governor.submitScorecardFor(gameId, sc);
        governor.ratifyScorecardFrom(gameId, sc);
        assertEq(governor.ratifiedScorecardIdOf(gameId), scorecardId);
    }
}

contract DefifaVotingReferee721Test is DefifaVotingRefereeTest {
    function _is1155() internal pure override returns (bool) {
        return false;
    }
}

contract DefifaVotingReferee1155Test is DefifaVotingRefereeTest {
    function _is1155() internal pure override returns (bool) {
        return true;
    }
}
