// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice A tier's share of the treasury pot after scoring. Tiers with higher weight let their NFT holders cash out
/// for more of the treasury.
/// @custom:member id The tier's ID.
/// @custom:member cashOutWeight The cash-out weight assigned to this tier (relative to all other tiers' weights).
struct DefifaTierCashOutWeight {
    uint256 id;
    uint256 cashOutWeight;
}
