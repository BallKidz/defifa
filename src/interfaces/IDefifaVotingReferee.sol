// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";

import {DefifaScorecardState} from "../enums/DefifaScorecardState.sol";
import {DefifaTierCashOutWeight} from "../structs/DefifaTierCashOutWeight.sol";
import {IDefifaReferee} from "./IDefifaReferee.sol";

/// @notice A sample referee: holders attest to scorecards with benefit-weighted power, and a scorecard that reaches its
/// quorum after the grace period can be forwarded to the game's governor.
interface IDefifaVotingReferee is IDefifaReferee {
    /// @notice Emitted when a game's voting settings are set.
    /// @param gameId The ID of the game.
    /// @param attestationStartTime The timestamp when attestation begins.
    /// @param attestationGracePeriod The grace period after attestation begins.
    /// @param caller The address that initialized the game.
    event GameInitialized(
        uint256 indexed gameId, uint256 attestationStartTime, uint256 attestationGracePeriod, address caller
    );

    /// @notice Emitted when an account attests to a scorecard.
    /// @param gameId The ID of the game.
    /// @param scorecardId The ID of the scorecard attested to.
    /// @param weight The attestation weight applied.
    /// @param caller The address that submitted the attestation.
    event ScorecardAttested(uint256 indexed gameId, uint256 indexed scorecardId, uint256 weight, address caller);

    /// @notice Emitted when an approved scorecard is forwarded to the game's governor.
    /// @param gameId The ID of the game.
    /// @param scorecardId The ID of the forwarded scorecard.
    /// @param caller The address that forwarded the scorecard.
    event ScorecardForwarded(uint256 indexed gameId, uint256 indexed scorecardId, address caller);

    /// @notice Emitted when a scorecard is submitted for attestation.
    /// @param gameId The ID of the game.
    /// @param scorecardId The ID of the submitted scorecard.
    /// @param tierWeights The proposed tier cash-out weights.
    /// @param caller The address that submitted the scorecard.
    event ScorecardSubmitted(
        uint256 indexed gameId, uint256 indexed scorecardId, DefifaTierCashOutWeight[] tierWeights, address caller
    );

    /// @notice Emitted when an attestation is revoked from a scorecard.
    /// @param gameId The ID of the game.
    /// @param scorecardId The ID of the scorecard.
    /// @param account The address whose attestation was revoked.
    /// @param weight The revoked attestation weight.
    /// @param caller The address that revoked the attestation.
    event AttestationRevoked(
        uint256 indexed gameId, uint256 indexed scorecardId, address account, uint256 weight, address caller
    );

    /// @notice The number of attestations for a scorecard.
    /// @param gameId The ID of the game.
    /// @param scorecardId The ID of the scorecard.
    /// @return The attestation count.
    function attestationCountOf(uint256 gameId, uint256 scorecardId) external view returns (uint256);

    /// @notice The grace period after attestation starts during which a scorecard can't pass.
    /// @param gameId The ID of the game.
    /// @return The grace period in seconds.
    function attestationGracePeriodOf(uint256 gameId) external view returns (uint256);

    /// @notice The timestamp when attestation begins for a game.
    /// @param gameId The ID of the game.
    /// @return The attestation start time.
    function attestationStartTimeOf(uint256 gameId) external view returns (uint256);

    /// @notice The Juicebox controller used to find games.
    /// @return The controller contract.
    function CONTROLLER() external view returns (IJBController);

    /// @notice Whether a scorecard has been forwarded to the game's governor.
    /// @param gameId The ID of the game.
    /// @param scorecardId The ID of the scorecard.
    /// @return True if forwarded.
    function forwardedScorecardOf(uint256 gameId, uint256 scorecardId) external view returns (bool);

    /// @notice Get the attestation weight for an account at a specific timestamp.
    /// @param gameId The ID of the game.
    /// @param account The account to check.
    /// @param timestamp The timestamp to check.
    /// @return attestationPower The attestation power.
    function getAttestationWeight(
        uint256 gameId,
        address account,
        uint48 timestamp
    )
        external
        view
        returns (uint256 attestationPower);

    /// @notice Get the BWA-adjusted attestation weight for an account relative to a specific scorecard.
    /// @param gameId The ID of the game.
    /// @param scorecardId The ID of the scorecard (for tier weight lookup).
    /// @param account The account to check.
    /// @param timestamp The timestamp to check.
    /// @return bwaAttestationPower The BWA-adjusted attestation power.
    // forge-lint: disable-next-line(mixed-case-function)
    function getBWAAttestationWeight(
        uint256 gameId,
        uint256 scorecardId,
        address account,
        uint48 timestamp
    )
        external
        view
        returns (uint256 bwaAttestationPower);

    /// @notice Whether an account has attested to a specific scorecard.
    /// @param gameId The ID of the game.
    /// @param scorecardId The ID of the scorecard.
    /// @param account The account to check.
    /// @return True if the account has attested.
    function hasAttestedTo(uint256 gameId, uint256 scorecardId, address account) external view returns (bool);

    /// @notice The attestation power each tier has if every token within the tier attests.
    /// @return The attestation power of one tier.
    function MAX_ATTESTATION_POWER_TIER() external view returns (uint256);

    /// @notice The minimum attestation grace period.
    /// @return The minimum grace period in seconds.
    function MIN_ATTESTATION_GRACE_PERIOD() external view returns (uint256);

    /// @notice The attestation an evenly split scorecard needs to pass.
    /// @dev More concentrated scorecards need more, up to `QUORUM_WINNER_TAKE_ALL_BPS` of the attestation possible.
    /// @param gameId The ID of the game.
    /// @return The quorum threshold.
    function quorum(uint256 gameId) external view returns (uint256);

    /// @notice The attestation a submitted scorecard needs to pass, fixed at its submission.
    /// @param gameId The ID of the game.
    /// @param scorecardId The ID of the scorecard.
    /// @return The quorum threshold.
    function quorumOf(uint256 gameId, uint256 scorecardId) external view returns (uint256);

    /// @notice The share of the attestation possible that an evenly split scorecard needs, in basis points.
    /// @return The basis points.
    function QUORUM_EVEN_BPS() external view returns (uint256);

    /// @notice The share of the attestation possible that a winner-take-all scorecard needs, in basis points.
    /// @return The basis points.
    function QUORUM_WINNER_TAKE_ALL_BPS() external view returns (uint256);

    /// @notice Compute the scorecard ID for a given hook and tier weights.
    /// @param gameHook The game hook address.
    /// @param tierWeights The tier cash-out weights.
    /// @return The scorecard ID.
    function scorecardIdOf(address gameHook, DefifaTierCashOutWeight[] calldata tierWeights) external returns (uint256);

    /// @notice The voting state of a submitted scorecard.
    /// @param gameId The ID of the game.
    /// @param scorecardId The ID of the scorecard.
    /// @return The scorecard state: PENDING, ACTIVE, SUCCEEDED, then RATIFIED or DEFEATED once the governor ratifies.
    function stateOf(uint256 gameId, uint256 scorecardId) external view returns (DefifaScorecardState);

    /// @notice Attest to a submitted scorecard using your NFT voting power.
    /// @param gameId The ID of the game.
    /// @param scorecardId The ID of the scorecard to attest to.
    /// @return weight The attestation weight applied.
    function attestToScorecardFrom(uint256 gameId, uint256 scorecardId) external returns (uint256 weight);

    /// @notice Send an approved scorecard to the game's governor, starting the governor's timelock.
    /// @param gameId The ID of the game.
    /// @param tierWeights The tier cash-out weights of the approved scorecard.
    /// @return scorecardId The scorecard ID.
    function forwardScorecardFor(
        uint256 gameId,
        DefifaTierCashOutWeight[] calldata tierWeights
    )
        external
        returns (uint256 scorecardId);

    /// @notice Revoke a previously submitted attestation during the ACTIVE phase.
    /// @param gameId The ID of the game.
    /// @param scorecardId The ID of the scorecard to revoke attestation from.
    function revokeAttestationFrom(uint256 gameId, uint256 scorecardId) external;

    /// @notice Submit a scorecard for attestation.
    /// @param gameId The ID of the game.
    /// @param tierWeights The tier cash-out weights.
    /// @return The scorecard ID.
    function submitScorecardFor(
        uint256 gameId,
        DefifaTierCashOutWeight[] calldata tierWeights
    )
        external
        returns (uint256);
}
