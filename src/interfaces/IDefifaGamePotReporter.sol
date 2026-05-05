// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice Reports the treasury pot size and commitment status of a Defifa game.
interface IDefifaGamePotReporter {
    /// @notice The total amount already distributed from a game's pot to commitment splits.
    /// @param gameId The ID of the game.
    /// @return The fulfilled commitment amount.
    function fulfilledCommitmentsOf(uint256 gameId) external view returns (uint256);

    /// @notice The current pot size for a game, optionally including unfulfilled commitments.
    /// @param gameId The ID of the game.
    /// @param includeCommitments Whether to include unfulfilled commitment amounts.
    /// @return pot The current pot amount.
    /// @return token The token address.
    /// @return decimals The token's decimal precision.
    function currentGamePotOf(uint256 gameId, bool includeCommitments) external view returns (uint256, address, uint256);
}
