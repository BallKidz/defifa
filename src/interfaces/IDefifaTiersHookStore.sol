// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IJB721TiersHookStore} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHookStore.sol";

/// @notice The 721 tiers hook store with count-based records for ERC-1155 game positions, so a hook records a tier's
/// mints, burns and transfers once per tier instead of once per position.
interface IDefifaTiersHookStore is IJB721TiersHookStore {
    /// @notice Record burned positions for the calling hook.
    /// @param tierIds The tier of each burn entry. Entries may repeat a tier.
    /// @param counts The number of positions burned in each entry.
    function recordBurnCounts(uint256[] calldata tierIds, uint256[] calldata counts) external;

    /// @notice Record paid mints of `counts[i]` positions in `tierIds[i]` for the calling hook.
    /// @param amount The amount to spend. The total price must not exceed it.
    /// @param tierIds The tiers to mint from.
    /// @param counts The number of positions to mint in each tier.
    /// @return leftoverAmount The `amount` remaining after minting.
    function recordMintCounts(
        uint256 amount,
        uint16[] calldata tierIds,
        uint256[] calldata counts
    )
        external
        returns (uint256 leftoverAmount);

    /// @notice Record `count` positions of a tier moving between holders for the calling hook.
    /// @param tierId The tier the positions belong to.
    /// @param from The holder sending (zero for mints).
    /// @param to The holder receiving (zero for burns).
    /// @param count The number of positions.
    function recordTransferForTier(uint256 tierId, address from, address to, uint256 count) external;
}
