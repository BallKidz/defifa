// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {DefifaGamePhase} from "../enums/DefifaGamePhase.sol";

/// @notice Reports the current lifecycle phase of a Defifa game.
interface IDefifaGamePhaseReporter {
    /// @notice The current phase of a game (COUNTDOWN, MINT, REFUND, SCORING, COMPLETE, or NO_CONTEST).
    /// @param gameId The ID of the game.
    /// @return The current game phase.
    function currentGamePhaseOf(uint256 gameId) external view returns (DefifaGamePhase);
}
