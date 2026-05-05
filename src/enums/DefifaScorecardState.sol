// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice The governance lifecycle of a submitted scorecard.
/// PENDING — submitted but attestation period hasn't started. ACTIVE — accepting attestations.
/// DEFEATED — failed to reach quorum. SUCCEEDED — reached quorum, in grace period.
/// QUEUED — grace period passed, awaiting application. RATIFIED — applied to the game's cash-out weights.
enum DefifaScorecardState {
    PENDING,
    ACTIVE,
    DEFEATED,
    SUCCEEDED,
    QUEUED,
    RATIFIED
}
