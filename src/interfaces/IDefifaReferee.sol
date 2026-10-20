// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice A contract that judges Defifa games and submits each game's scorecard to the governor.
/// @dev A referee can be any address. A contract referee that needs per-game settings implements this, and the
/// deployer calls it at launch when the game's `refereeData` is not empty.
interface IDefifaReferee {
    /// @notice Set up a game this referee judges.
    /// @dev Implementations must accept the call only from the game's project owner.
    /// @param gameId The ID of the game.
    /// @param data The referee's settings for the game, encoded as the referee expects.
    function initializeGameFor(uint256 gameId, bytes calldata data) external;
}
