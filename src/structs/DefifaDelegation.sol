// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice A delegation of a player's voting power for a specific tier to another address.
/// @custom:member delegatee The account to delegate tier voting units to.
/// @custom:member tierId The ID of the tier to delegate voting units for.
struct DefifaDelegation {
    address delegatee;
    uint256 tierId;
}
