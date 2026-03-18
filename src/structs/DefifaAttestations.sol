// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @custom:param A count of attestations.
/// @custom:param A mapping of which accounts have attested.
struct DefifaAttestations {
    uint256 count;
    mapping(address => bool) hasAttested;
}
