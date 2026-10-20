// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {DefifaGovernor} from "../../src/DefifaGovernor.sol";
import {DefifaDeployer} from "../../src/DefifaDeployer.sol";
import {DefifaGamePhase} from "../../src/enums/DefifaGamePhase.sol";
import {DefifaScorecardState} from "../../src/enums/DefifaScorecardState.sol";
import {DefifaLaunchProjectData} from "../../src/structs/DefifaLaunchProjectData.sol";
import {DefifaTierCashOutWeight} from "../../src/structs/DefifaTierCashOutWeight.sol";

import {RefereeTestBase} from "./RefereeTestBase.sol";

/// @notice The governor ratifies only its referee's scorecard, after the game's timelock.
abstract contract DefifaGovernorCoreTest is RefereeTestBase {
    address internal constant _REFEREE = address(0xBEEF);

    function _launchTwoTierGame(uint256 timelockDuration) internal {
        _launch(_launchData({n: 2, referee: _REFEREE, refereeData: "", timelockDuration: timelockDuration}));
        _mint(_addr(1), 1);
        _mint(_addr(2), 2);
        _toScoring();
    }

    function _invalidConfig(DefifaLaunchProjectData memory d) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(
            DefifaDeployer.DefifaDeployer_InvalidGameConfiguration.selector,
            d.start,
            d.mintPeriodDuration,
            d.refundPeriodDuration,
            d.tiers.length
        );
    }

    function test_onlyRefereeSubmits() external {
        _launchTwoTierGame(1 days);
        DefifaTierCashOutWeight[] memory sc = _winnerTakeAll(2, 1);

        vm.prank(_addr(1));
        vm.expectRevert(abi.encodeWithSelector(DefifaGovernor.DefifaGovernor_NotReferee.selector, gameId, _addr(1)));
        governor.submitScorecardFor(gameId, sc);
    }

    function test_ratifyAfterTimelock() external {
        _launchTwoTierGame(1 days);
        DefifaTierCashOutWeight[] memory sc = _winnerTakeAll(2, 1);

        vm.prank(_REFEREE);
        uint256 scorecardId = governor.submitScorecardFor(gameId, sc);
        assertEq(uint256(governor.stateOf(gameId, scorecardId)), uint256(DefifaScorecardState.QUEUED));

        vm.expectRevert(
            abi.encodeWithSelector(
                DefifaGovernor.DefifaGovernor_NotAllowed.selector, gameId, scorecardId, address(this)
            )
        );
        governor.ratifyScorecardFrom(gameId, sc);

        vm.warp(block.timestamp + 1 days);
        assertEq(uint256(governor.stateOf(gameId, scorecardId)), uint256(DefifaScorecardState.SUCCEEDED));

        vm.prank(_addr(9));
        governor.ratifyScorecardFrom(gameId, sc);
        assertEq(uint256(governor.stateOf(gameId, scorecardId)), uint256(DefifaScorecardState.RATIFIED));
        assertEq(governor.ratifiedScorecardIdOf(gameId), scorecardId);
        assertTrue(game.cashOutWeightIsSet());
        assertEq(uint256(deployer.currentGamePhaseOf(gameId)), uint256(DefifaGamePhase.COMPLETE));
    }

    function test_replacedScorecardCannotRatify() external {
        _launchTwoTierGame(1 days);
        DefifaTierCashOutWeight[] memory a = _winnerTakeAll(2, 1);
        DefifaTierCashOutWeight[] memory b = _winnerTakeAll(2, 2);

        vm.prank(_REFEREE);
        uint256 aId = governor.submitScorecardFor(gameId, a);
        vm.warp(block.timestamp + 1 days);
        vm.prank(_REFEREE);
        uint256 bId = governor.submitScorecardFor(gameId, b);

        assertEq(uint256(governor.stateOf(gameId, aId)), uint256(DefifaScorecardState.DEFEATED));
        assertEq(uint256(governor.stateOf(gameId, bId)), uint256(DefifaScorecardState.QUEUED));
        vm.expectRevert(
            abi.encodeWithSelector(DefifaGovernor.DefifaGovernor_NotAllowed.selector, gameId, aId, address(this))
        );
        governor.ratifyScorecardFrom(gameId, a);
    }

    function test_resubmitPendingReverts() external {
        _launchTwoTierGame(1 days);
        DefifaTierCashOutWeight[] memory sc = _winnerTakeAll(2, 1);

        vm.prank(_REFEREE);
        uint256 scorecardId = governor.submitScorecardFor(gameId, sc);
        vm.prank(_REFEREE);
        vm.expectRevert(
            abi.encodeWithSelector(DefifaGovernor.DefifaGovernor_DuplicateScorecard.selector, gameId, scorecardId)
        );
        governor.submitScorecardFor(gameId, sc);
    }

    function test_ratifySameBlockWhenNoTimelock() external {
        _launchTwoTierGame(0);
        DefifaTierCashOutWeight[] memory sc = _even(2);

        vm.prank(_REFEREE);
        uint256 scorecardId = governor.submitScorecardFor(gameId, sc);
        governor.ratifyScorecardFrom(gameId, sc);
        assertEq(governor.ratifiedScorecardIdOf(gameId), scorecardId);
    }

    function test_noRefereeActionMeansNoContest() external {
        _launchTwoTierGame(1 days);
        vm.warp(block.timestamp + 30 days + 1);
        assertEq(uint256(deployer.currentGamePhaseOf(gameId)), uint256(DefifaGamePhase.NO_CONTEST));

        DefifaTierCashOutWeight[] memory sc = _winnerTakeAll(2, 1);
        vm.prank(_REFEREE);
        vm.expectRevert(abi.encodeWithSelector(DefifaGovernor.DefifaGovernor_NotAllowed.selector, gameId, 0, _REFEREE));
        governor.submitScorecardFor(gameId, sc);
    }

    function test_unknownScorecardStateReverts() external {
        _launchTwoTierGame(1 days);
        vm.expectRevert(abi.encodeWithSelector(DefifaGovernor.DefifaGovernor_UnknownProposal.selector, gameId, 123));
        governor.stateOf(gameId, 123);
    }

    function test_launch_zeroRefereeReverts() external {
        DefifaLaunchProjectData memory d =
            _launchData({n: 2, referee: address(0), refereeData: "", timelockDuration: 0});
        vm.expectRevert(_invalidConfig(d));
        deployer.launchGameWith(d);
    }

    function test_launch_refereeDataNeedsContract() external {
        DefifaLaunchProjectData memory d =
            _launchData({n: 2, referee: _REFEREE, refereeData: hex"01", timelockDuration: 0});
        vm.expectRevert();
        deployer.launchGameWith(d);
    }

    function test_launch_timeoutMustExceedTimelock() external {
        DefifaLaunchProjectData memory d =
            _launchData({n: 2, referee: _REFEREE, refereeData: "", timelockDuration: 30 days});
        vm.expectRevert(_invalidConfig(d));
        deployer.launchGameWith(d);
    }
}

contract DefifaGovernorCore721Test is DefifaGovernorCoreTest {
    function _is1155() internal pure override returns (bool) {
        return false;
    }
}

contract DefifaGovernorCore1155Test is DefifaGovernorCoreTest {
    function _is1155() internal pure override returns (bool) {
        return true;
    }
}
