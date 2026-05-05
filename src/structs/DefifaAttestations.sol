// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice Tracks cumulative attestation weight for a scorecard and which accounts have attested.
/// @custom:member count The total attestation weight accumulated so far.
/// @custom:member attestedWeightOf The voting weight each account attested with (0 = has not attested).
struct DefifaAttestations {
    uint256 count;
    mapping(address => uint256) attestedWeightOf;
}
