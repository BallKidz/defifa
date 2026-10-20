// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IJB721TokenUriResolver} from "@bananapus/721-hook-v6/src/interfaces/IJB721TokenUriResolver.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBSplit} from "@bananapus/core-v6/src/structs/JBSplit.sol";

import {DefifaTierParams} from "./DefifaTierParams.sol";

/// @notice All parameters needed to launch a new Defifa game — the name, tiers, timing, splits, and governance
/// configuration.
/// @custom:member name The name of the game to create.
/// @custom:member projectUri Metadata to associate with the project.
/// @custom:member contractUri The URI to associate with the 721.
/// @custom:member baseUri The URI base to prepend onto any tier token URIs.
/// @custom:member tiers Parameters describing the tiers.
/// @custom:member tierPrice The uniform price for all tiers. All tiers use the same price so that price-based voting
/// power is equal across tiers.
/// @custom:member token The token configuration the game is played with.
/// @custom:member mintPeriodDuration The duration of the game's mint phase, measured in seconds.
/// @custom:member refundPeriodDuration The time between the mint phase and the start time when mints are no longer open
/// but refunds are still allowed, measured in seconds.
/// @custom:member start The time at which the game should start, measured in seconds since the Unix epoch.
/// @custom:member splits Splits to distribute funds between during the game's scoring phase.
/// @custom:member defaultAttestationDelegate The address holders' tier attestation units are delegated to by default,
/// for referees that count holder votes.
/// @custom:member defaultTokenUriResolver The contract used to resolve token URIs if not provided by a tier
/// specifically, serving as the fallback resolver for the game.
/// @custom:member terminal The payment terminal that the project will accept funds through.
/// @custom:member minParticipation The minimum cumulative NFT mint cost required for the game to proceed to scoring.
/// Compared against the hook's `totalMintCost` (immune to `addToBalanceOf` inflation). If below this when scoring
/// would begin, the game enters NO_CONTEST. Set to 0 to disable.
/// @custom:member scorecardTimeout The maximum time (in seconds) after the scoring phase begins for a scorecard to be
/// ratified. If exceeded, the game enters NO_CONTEST. Must be nonzero.
/// @custom:member timelockDuration The time (in seconds) a submitted scorecard waits before anyone can ratify it. Must
/// be less than `scorecardTimeout`.
/// @custom:member referee The address that judges the game. Only it can submit scorecards. Any address; a contract can
/// run its own rule, such as a holder vote.
/// @custom:member refereeData Settings passed to the referee's `initializeGameFor` at launch. Empty to skip the call.
struct DefifaLaunchProjectData {
    string name;
    string projectUri;
    string contractUri;
    string baseUri;
    DefifaTierParams[] tiers;
    uint104 tierPrice;
    JBAccountingContext token;
    uint24 mintPeriodDuration;
    uint24 refundPeriodDuration;
    uint48 start;
    JBSplit[] splits;
    address defaultAttestationDelegate;
    IJB721TokenUriResolver defaultTokenUriResolver;
    IJBTerminal terminal;
    uint256 minParticipation;
    uint32 scorecardTimeout;
    uint256 timelockDuration;
    address referee;
    bytes refereeData;
}
