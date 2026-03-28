// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @custom:param count A count of attestation weight.
/// @custom:param attestedWeightOf The BWA weight each account attested with (0 = not attested).
struct DefifaAttestations {
    uint256 count;
    mapping(address => uint256) attestedWeightOf;
}
