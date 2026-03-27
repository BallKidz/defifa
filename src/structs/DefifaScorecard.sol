// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @custom:member attestationsBegin The block at which attestations to the scorecard become allowed.
/// @custom:member gracePeriodEnds The block at which the scorecard can become ratified.
/// @custom:member quorumSnapshot The quorum threshold snapshotted at scorecard submission time. This prevents
///  reserve mints from retroactively raising the quorum and invalidating a scorecard that already reached SUCCEEDED.
struct DefifaScorecard {
    uint48 attestationsBegin;
    uint48 gracePeriodEnds;
    uint256 quorumSnapshot;
}
