// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IJBAddressRegistry} from "@bananapus/address-registry-v6/src/interfaces/IJBAddressRegistry.sol";
import {IJB721TiersHookStore} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHookStore.sol";
import {IJB721TokenUriResolver} from "@bananapus/721-hook-v6/src/interfaces/IJB721TokenUriResolver.sol";
import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {JBSplit} from "@bananapus/core-v6/src/structs/JBSplit.sol";

import {DefifaLaunchProjectData} from "../structs/DefifaLaunchProjectData.sol";
import {IDefifaGovernor} from "./IDefifaGovernor.sol";
import {IDefifaHook} from "./IDefifaHook.sol";

/// @notice Deploys and manages Defifa prediction games, including lifecycle phase transitions
/// and commitment fulfillment.
interface IDefifaDeployer {
    /// @notice Emitted when a commitment payout fails during fulfillment.
    /// @param gameId The ID of the game being fulfilled.
    /// @param amount The amount that failed to pay out.
    /// @param reason The revert reason bytes from the failed payout.
    event CommitmentPayoutFailed(uint256 indexed gameId, uint256 amount, bytes reason);

    /// @notice Emitted when a split receives a portion of the game pot.
    /// @param split The split that received funds.
    /// @param amount The amount sent to the split.
    /// @param caller The address that triggered the distribution.
    event DistributeToSplit(JBSplit split, uint256 amount, address caller);

    /// @notice Emitted when a game's commitments have been fulfilled.
    /// @param gameId The ID of the fulfilled game.
    /// @param pot The total game pot that was fulfilled.
    /// @param caller The address that triggered fulfillment.
    event FulfilledCommitments(uint256 indexed gameId, uint256 pot, address caller);

    /// @notice Emitted when a new Defifa game is launched.
    /// @param gameId The ID of the launched game.
    /// @param hook The hook deployed for the game.
    /// @param governor The governor responsible for scorecard ratification.
    /// @param tokenUriResolver The token URI resolver used for the game's NFTs.
    /// @param caller The address that launched the game.
    event LaunchGame(
        uint256 indexed gameId,
        IDefifaHook indexed hook,
        IDefifaGovernor indexed governor,
        IJB721TokenUriResolver tokenUriResolver,
        address caller
    );

    /// @notice Emitted when a game is queued into its no-contest phase.
    /// @param gameId The ID of the game.
    /// @param caller The address that queued the phase transition.
    event QueuedNoContest(uint256 indexed gameId, address caller);

    /// @notice Emitted when a game is queued into its refund phase.
    /// @param gameId The ID of the game.
    /// @param caller The address that queued the phase transition.
    event QueuedRefundPhase(uint256 indexed gameId, address caller);

    /// @notice Emitted when a game is queued into its scoring phase.
    /// @param gameId The ID of the game.
    /// @param caller The address that queued the phase transition.
    event QueuedScoringPhase(uint256 indexed gameId, address caller);

    /// @notice The fee divisor for base protocol fees (100 / fee percent).
    /// @return The fee divisor.
    function BASE_PROTOCOL_FEE_DIVISOR() external view returns (uint256);

    /// @notice The Juicebox project ID of the base protocol project.
    /// @return The project ID.
    function BASE_PROTOCOL_PROJECT_ID() external view returns (uint256);

    /// @notice The Juicebox controller used to manage projects.
    /// @return The controller contract.
    function CONTROLLER() external view returns (IJBController);

    /// @notice The fee divisor for Defifa fees (100 / fee percent).
    /// @return The fee divisor.
    function DEFIFA_FEE_DIVISOR() external view returns (uint256);

    /// @notice The Juicebox project ID of the Defifa project.
    /// @return The project ID.
    function DEFIFA_PROJECT_ID() external view returns (uint256);

    /// @notice The governor contract used for scorecard governance.
    /// @return The governor contract.
    function GOVERNOR() external view returns (IDefifaGovernor);

    /// @notice The code origin address used as an implementation for hook clones.
    /// @return The code origin address.
    function HOOK_CODE_ORIGIN() external view returns (address);

    /// @notice The 721 tiers hook store used by all games.
    /// @return The hook store contract.
    function HOOK_STORE() external view returns (IJB721TiersHookStore);

    /// @notice The address registry used for content-addressable deployment lookups.
    /// @return The address registry contract.
    function REGISTRY() external view returns (IJBAddressRegistry);

    /// @notice The split group ID used for distributing game pot funds.
    /// @return The split group.
    function SPLIT_GROUP() external view returns (uint256);

    /// @notice The token URI resolver used for game NFT metadata.
    /// @return The token URI resolver contract.
    function TOKEN_URI_RESOLVER() external view returns (IJB721TokenUriResolver);

    /// @notice Whether the next game phase needs to be queued.
    /// @param gameId The ID of the game.
    /// @return True if the next phase needs queueing.
    function nextPhaseNeedsQueueing(uint256 gameId) external view returns (bool);

    /// @notice The safety parameters for a game.
    /// @param gameId The ID of the game.
    /// @return minParticipation The minimum participation threshold.
    /// @return scorecardTimeout The scorecard timeout duration.
    function safetyParamsOf(uint256 gameId) external view returns (uint256 minParticipation, uint32 scorecardTimeout);

    /// @notice The timing parameters for a game.
    /// @param gameId The ID of the game.
    /// @return The mint duration, start time, and refund period.
    function timesFor(uint256 gameId) external view returns (uint48, uint24, uint24);

    /// @notice The token address for a game.
    /// @param gameId The ID of the game.
    /// @return The token address.
    function tokenOf(uint256 gameId) external view returns (address);

    /// @notice Fulfill the commitments of a game by distributing the pot.
    /// @param gameId The ID of the game.
    function fulfillCommitmentsOf(uint256 gameId) external;

    /// @notice Launch a new Defifa game.
    /// @param launchProjectData The configuration for launching the game.
    /// @return gameId The ID of the newly launched game.
    function launchGameWith(DefifaLaunchProjectData calldata launchProjectData) external returns (uint256 gameId);

    /// @notice Trigger a no-contest outcome for a game.
    /// @param gameId The ID of the game.
    function triggerNoContestFor(uint256 gameId) external;
}
