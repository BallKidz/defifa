// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";

import {DefifaScorecardState} from "../enums/DefifaScorecardState.sol";
import {DefifaTierCashOutWeight} from "../structs/DefifaTierCashOutWeight.sol";

/// @notice Ratifies each game's scorecard as submitted by the game's referee, after the game's timelock.
interface IDefifaGovernor {
    /// @notice Emitted when a game's referee and timelock are set.
    /// @param gameId The ID of the game.
    /// @param referee The address that judges the game.
    /// @param timelockDuration The time a submitted scorecard waits before anyone can ratify it, in seconds.
    /// @param caller The address that initialized the game.
    event GameInitialized(uint256 indexed gameId, address referee, uint256 timelockDuration, address caller);

    /// @notice Emitted when a scorecard is ratified.
    /// @param gameId The ID of the game.
    /// @param scorecardId The ID of the ratified scorecard.
    /// @param caller The address that ratified the scorecard.
    event ScorecardRatified(uint256 indexed gameId, uint256 indexed scorecardId, address caller);

    /// @notice Emitted when a game's referee submits a scorecard.
    /// @param gameId The ID of the game.
    /// @param scorecardId The ID of the submitted scorecard.
    /// @param tierWeights The proposed tier cash-out weights.
    /// @param caller The address that submitted the scorecard.
    event ScorecardSubmitted(
        uint256 indexed gameId, uint256 indexed scorecardId, DefifaTierCashOutWeight[] tierWeights, address caller
    );

    /// @notice The Juicebox controller used to manage projects.
    /// @return The controller contract.
    function CONTROLLER() external view returns (IJBController);

    /// @notice The scorecard waiting out its timelock for a game.
    /// @param gameId The ID of the game.
    /// @return The scorecard ID, or 0 if none was submitted.
    function pendingScorecardIdOf(uint256 gameId) external view returns (uint256);

    /// @notice The ID of the ratified scorecard for a game.
    /// @param gameId The ID of the game.
    /// @return The ratified scorecard ID, or 0 if none.
    function ratifiedScorecardIdOf(uint256 gameId) external view returns (uint256);

    /// @notice The referee of a game.
    /// @param gameId The ID of the game.
    /// @return The address that judges the game, or the zero address if the game is unknown.
    function refereeOf(uint256 gameId) external view returns (address);

    /// @notice Compute the scorecard ID for a given hook and tier weights.
    /// @param gameHook The game hook address.
    /// @param tierWeights The tier cash-out weights.
    /// @return The scorecard ID.
    function scorecardIdOf(address gameHook, DefifaTierCashOutWeight[] calldata tierWeights) external returns (uint256);

    /// @notice When a scorecard was last submitted.
    /// @param gameId The ID of the game.
    /// @param scorecardId The ID of the scorecard.
    /// @return The submission timestamp, or 0 if never submitted.
    function scorecardSubmittedAtOf(uint256 gameId, uint256 scorecardId) external view returns (uint256);

    /// @notice The state of a submitted scorecard.
    /// @param gameId The ID of the game.
    /// @param scorecardId The ID of the scorecard.
    /// @return The scorecard state: QUEUED, SUCCEEDED, RATIFIED, or DEFEATED.
    function stateOf(uint256 gameId, uint256 scorecardId) external view returns (DefifaScorecardState);

    /// @notice The time a game's submitted scorecard waits before anyone can ratify it.
    /// @param gameId The ID of the game.
    /// @return The timelock duration, in seconds.
    function timelockDurationOf(uint256 gameId) external view returns (uint256);

    /// @notice Set a game's referee and timelock.
    /// @param gameId The ID of the game.
    /// @param referee The address that judges the game.
    /// @param timelockDuration The time a submitted scorecard waits before anyone can ratify it, in seconds.
    function initializeGame(uint256 gameId, address referee, uint256 timelockDuration) external;

    /// @notice Ratify a game's pending scorecard once its timelock has passed.
    /// @param gameId The ID of the game.
    /// @param tierWeights The tier cash-out weights (must match the pending scorecard).
    /// @return The scorecard ID that was ratified.
    function ratifyScorecardFrom(
        uint256 gameId,
        DefifaTierCashOutWeight[] calldata tierWeights
    )
        external
        returns (uint256);

    /// @notice Submit a game's scorecard, replacing any pending one and starting the timelock. Referee only.
    /// @param gameId The ID of the game.
    /// @param tierWeights The tier cash-out weights.
    /// @return The scorecard ID.
    function submitScorecardFor(
        uint256 gameId,
        DefifaTierCashOutWeight[] calldata tierWeights
    )
        external
        returns (uint256);
}
