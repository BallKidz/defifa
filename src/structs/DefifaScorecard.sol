// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice A submitted scorecard's governance state — when attestations begin, when the grace period ends, and the
/// quorum threshold needed for ratification.
/// @custom:member attestationsBegin The block at which attestations to the scorecard become allowed.
/// @custom:member gracePeriodEnds The block at which the scorecard can become ratified.
/// @custom:member snapshotTimestamp The timestamp at which BWA attestation power is read. Set to the second before
/// submission so attestation units are frozen as of the block before the scorecard was submitted — any mint or
/// transfer sharing the submission block (which would overwrite the equally-keyed checkpoint, in either order)
/// cannot influence this scorecard.
/// @custom:member quorumSnapshot The HHI-adjusted quorum threshold snapshotted at submission time.
struct DefifaScorecard {
    uint48 attestationsBegin;
    uint48 gracePeriodEnds;
    uint48 snapshotTimestamp;
    uint256 quorumSnapshot;
}
