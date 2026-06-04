// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice The lifecycle phases of a Defifa game.
/// COUNTDOWN — before minting opens. MINT — players can mint tier NFTs.
/// REFUND — minting closed, refunds allowed. SCORING — scorecards can be submitted and attested.
/// COMPLETE — scorecard ratified, cash-outs open.
/// NO_CONTEST — game voided (minimum participation not met or scorecard timed out), full refunds available.
enum DefifaGamePhase {
    COUNTDOWN,
    MINT,
    REFUND,
    SCORING,
    COMPLETE,
    NO_CONTEST
}
