// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice The state of a submitted scorecard, in the governor or in a voting referee.
/// @dev Governor: QUEUED while the referee's pending scorecard waits out the timelock, SUCCEEDED once it can be
/// ratified, RATIFIED once applied, DEFEATED if replaced or if another was ratified.
/// `DefifaVotingReferee`: PENDING before attestations open, ACTIVE while attestations are open (including after the
/// grace period while below quorum), SUCCEEDED once the grace period has ended with quorum met, then RATIFIED or
/// DEFEATED once the governor ratifies.
enum DefifaScorecardState {
    PENDING,
    ACTIVE,
    DEFEATED,
    SUCCEEDED,
    QUEUED,
    RATIFIED
}
