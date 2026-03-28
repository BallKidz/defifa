// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @custom:member attestationsBegin The block at which attestations to the scorecard become allowed.
/// @custom:member gracePeriodEnds The block at which the scorecard can become ratified.
/// @custom:member quorumSnapshot The HHI-adjusted quorum threshold snapshotted at submission time.
struct DefifaScorecard {
    uint48 attestationsBegin;
    uint48 gracePeriodEnds;
    uint256 quorumSnapshot;
}
