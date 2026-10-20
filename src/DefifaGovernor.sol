// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {JBRulesetMetadata} from "@bananapus/core-v6/src/structs/JBRulesetMetadata.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

import {DefifaHook} from "./DefifaHook.sol";

import {DefifaGamePhase} from "./enums/DefifaGamePhase.sol";
import {DefifaScorecardState} from "./enums/DefifaScorecardState.sol";

import {IDefifaDeployer} from "./interfaces/IDefifaDeployer.sol";
import {IDefifaGovernor} from "./interfaces/IDefifaGovernor.sol";
import {IDefifaHook} from "./interfaces/IDefifaHook.sol";

import {DefifaHookLib} from "./libraries/DefifaHookLib.sol";

import {DefifaTierCashOutWeight} from "./structs/DefifaTierCashOutWeight.sol";

/// @notice Ratifies each game's scorecard as submitted by the game's referee, after the game's timelock. The governor
/// counts no votes: a referee is any address, and a referee contract can run its own rule, such as a holder vote,
/// before it submits.
contract DefifaGovernor is Ownable, IDefifaGovernor {
    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    /// @notice Thrown when initializing a game that already has a referee, so a game's referee can't be replaced.
    error DefifaGovernor_AlreadyInitialized(uint256 gameId);

    /// @notice Thrown when submitting or ratifying a scorecard for a game that has already ratified one, since a
    /// ratified result is final.
    error DefifaGovernor_AlreadyRatified(uint256 gameId, uint256 scorecardId);

    /// @notice Thrown when the referee submits the scorecard that is already pending, which would only restart its
    /// timelock.
    error DefifaGovernor_DuplicateScorecard(uint256 gameId, uint256 scorecardId);

    /// @notice Thrown when submitting a scorecard for a game with no referee, since only a named referee may submit.
    error DefifaGovernor_GameNotFound(uint256 gameId);

    /// @notice Thrown when the action is not allowed: the game is not in its scoring phase, or the scorecard is not
    /// the pending one past its timelock. Results are only accepted while the game scores and only after holders
    /// have had the timelock to see them.
    error DefifaGovernor_NotAllowed(uint256 gameId, uint256 scorecardId, address caller);

    /// @notice Thrown when an address other than the game's referee submits a scorecard, since the referee alone
    /// decides the result.
    error DefifaGovernor_NotReferee(uint256 gameId, address caller);

    /// @notice Thrown when a timelock exceeds a uint48, keeping it within the range the deployer's timestamp checks
    /// use.
    error DefifaGovernor_Uint48Overflow(uint256 value, uint256 max);

    /// @notice Thrown when reading the state of a scorecard never submitted for the game, so an unknown ID can't be
    /// mistaken for one that lost or waits.
    error DefifaGovernor_UnknownProposal(uint256 gameId, uint256 scorecardId);

    /// @notice Thrown when a scorecard pays a tier with no live supply, since no token could redeem that weight.
    error DefifaGovernor_UnownedProposedCashoutValue(uint256 gameId, uint256 tierId, uint256 cashOutWeight);

    /// @notice Thrown when initializing a game without a referee, since no one could then submit its result.
    error DefifaGovernor_ZeroReferee(uint256 gameId);

    //*********************************************************************//
    // --------------- public immutable stored properties ---------------- //
    //*********************************************************************//

    /// @notice The controller used to find each game's hook, rulesets and project owner.
    IJBController public immutable override CONTROLLER;

    //*********************************************************************//
    // --------------------- public stored properties -------------------- //
    //*********************************************************************//

    /// @notice The scorecard waiting out its timelock for each game.
    /// @custom:param gameId The ID of the game.
    mapping(uint256 => uint256) public override pendingScorecardIdOf;

    /// @notice The scorecard that has been ratified.
    /// @custom:param gameId The ID of the game of the ratified scorecard.
    mapping(uint256 => uint256) public override ratifiedScorecardIdOf;

    /// @notice The referee of each game.
    /// @custom:param gameId The ID of the game.
    mapping(uint256 => address) public override refereeOf;

    /// @notice When each scorecard was last submitted. Zero if never.
    /// @custom:param gameId The ID of the game.
    /// @custom:param scorecardId The ID of the scorecard.
    mapping(uint256 => mapping(uint256 => uint256)) public override scorecardSubmittedAtOf;

    /// @notice The time each game's submitted scorecard waits before anyone can ratify it, in seconds.
    /// @custom:param gameId The ID of the game.
    mapping(uint256 => uint256) public override timelockDurationOf;

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    /// @notice Creates the governor for the given controller, owned by the deployer that initializes its games.
    /// @param controller The controller used to find each game's hook, rulesets and project owner.
    /// @param owner The address that can initialize games: the deployer.
    constructor(IJBController controller, address owner) Ownable(owner) {
        CONTROLLER = controller;
    }

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Set a game's referee and timelock. Called by the deployer at launch.
    /// @param gameId The ID of the game.
    /// @param referee The address that judges the game.
    /// @param timelockDuration The time a submitted scorecard waits before anyone can ratify it, in seconds.
    function initializeGame(uint256 gameId, address referee, uint256 timelockDuration) external override onlyOwner {
        // Make sure the game hasn't already been initialized.
        if (refereeOf[gameId] != address(0)) revert DefifaGovernor_AlreadyInitialized({gameId: gameId});

        // Every game needs a referee.
        if (referee == address(0)) revert DefifaGovernor_ZeroReferee({gameId: gameId});

        // Keep the timelock within the range the deployer's timestamp checks expect.
        if (timelockDuration > type(uint48).max) {
            revert DefifaGovernor_Uint48Overflow({value: timelockDuration, max: type(uint48).max});
        }

        // Store the game's referee and timelock, fixed for the game's life.
        refereeOf[gameId] = referee;
        timelockDurationOf[gameId] = timelockDuration;

        // Let indexers record who judges the game.
        emit GameInitialized({gameId: gameId, referee: referee, timelockDuration: timelockDuration, caller: msg.sender});
    }

    /// @notice Ratify a game's pending scorecard once its timelock has passed. Anyone can call this.
    /// @dev Records the result before calling the hook and the deployer, so a re-entrant call can't ratify twice. A
    /// failed payout doesn't block ratification: `fulfillCommitmentsOf` catches it and still queues the final ruleset.
    /// @param gameId The ID of the game.
    /// @param tierWeights The weights of each tier in the pending scorecard.
    /// @return scorecardId The scorecard ID that was ratified.
    function ratifyScorecardFrom(
        uint256 gameId,
        DefifaTierCashOutWeight[] calldata tierWeights
    )
        external
        override
        returns (uint256 scorecardId)
    {
        // Make sure a scorecard hasn't been ratified yet.
        if (ratifiedScorecardIdOf[gameId] != 0) {
            revert DefifaGovernor_AlreadyRatified({gameId: gameId, scorecardId: ratifiedScorecardIdOf[gameId]});
        }

        // Get the game's current ruleset metadata, which names its hook.
        (, JBRulesetMetadata memory metadata) = CONTROLLER.currentRulesetOf(gameId);

        // Build the calldata to the target.
        bytes memory scorecardCalldata = _buildScorecardCalldataFor(tierWeights);

        // Hash the scorecard to derive its ID.
        scorecardId = _hashScorecardOf({gameHook: metadata.dataHook, calldataBytes: scorecardCalldata});

        // Only the pending scorecard, past its timelock, can be ratified.
        if (stateOf({gameId: gameId, scorecardId: scorecardId}) != DefifaScorecardState.SUCCEEDED) {
            revert DefifaGovernor_NotAllowed({gameId: gameId, scorecardId: scorecardId, caller: msg.sender});
        }

        // Record the result before the external calls, so a re-entrant call can't ratify twice.
        ratifiedScorecardIdOf[gameId] = scorecardId;

        // Execute the scorecard via low-level call since the governor is the hook's owner.
        (bool success, bytes memory returndata) = metadata.dataHook.call(scorecardCalldata);

        // Bubble up the hook's revert so a failed weight update can't count as ratified.
        Address.verifyCallResult({success: success, returndata: returndata});

        // Fulfill any commitments for the game. The internal try-catch in fulfillCommitmentsOf
        // handles sendPayoutsOf failures, ensuring the final ruleset is always queued.
        IDefifaDeployer(CONTROLLER.PROJECTS().ownerOf(gameId)).fulfillCommitmentsOf(gameId);

        // Let indexers record the result.
        emit ScorecardRatified({gameId: gameId, scorecardId: scorecardId, caller: msg.sender});
    }

    /// @notice Submit a game's scorecard, replacing any pending one and starting the timelock. Only the game's
    /// referee can call this.
    /// @dev Runs the hook's structural validation now, so a malformed scorecard fails here instead of after the
    /// timelock. Resubmitting the pending scorecard reverts, since it would only restart its timelock.
    /// @param gameId The ID of the game.
    /// @param tierWeights The weights of each tier in the scorecard.
    /// @return scorecardId The scorecard's ID.
    function submitScorecardFor(
        uint256 gameId,
        DefifaTierCashOutWeight[] calldata tierWeights
    )
        external
        override
        returns (uint256 scorecardId)
    {
        // Make sure a scorecard hasn't yet been ratified.
        if (ratifiedScorecardIdOf[gameId] != 0) {
            revert DefifaGovernor_AlreadyRatified({gameId: gameId, scorecardId: ratifiedScorecardIdOf[gameId]});
        }

        // Make sure the game has been initialized: every initialized game has a referee.
        address referee = refereeOf[gameId];
        if (referee == address(0)) revert DefifaGovernor_GameNotFound({gameId: gameId});

        // Only the game's referee can submit.
        if (msg.sender != referee) revert DefifaGovernor_NotReferee({gameId: gameId, caller: msg.sender});

        // Get the game's current ruleset metadata, which names its hook.
        (, JBRulesetMetadata memory metadata) = CONTROLLER.currentRulesetOf(gameId);

        // Make sure the game is in its scoring phase.
        if (IDefifaHook(metadata.dataHook).gamePhaseReporter().currentGamePhaseOf(gameId) != DefifaGamePhase.SCORING) {
            revert DefifaGovernor_NotAllowed({gameId: gameId, scorecardId: 0, caller: msg.sender});
        }

        // Keep a reference to the number of tier weights in the scorecard.
        uint256 numberOfTierWeights = tierWeights.length;

        // If there's a weight assigned to the tier, make sure there is a token backed by it.
        for (uint256 i; i < numberOfTierWeights;) {
            // A nonzero cash-out weight is only valid once that tier has live ownership.
            uint256 currentTierSupply = IDefifaHook(metadata.dataHook).currentSupplyOfTier(tierWeights[i].id);

            // A weight on an empty tier could never be redeemed.
            if (tierWeights[i].cashOutWeight > 0 && currentTierSupply == 0) {
                revert DefifaGovernor_UnownedProposedCashoutValue({
                    gameId: gameId, tierId: tierWeights[i].id, cashOutWeight: tierWeights[i].cashOutWeight
                });
            }
            // Can't overflow: the index is bounded by the loop's length.
            unchecked {
                ++i;
            }
        }

        // Run the same structural validation the hook will apply at ratification time so malformed
        // scorecards fail on submission instead of after the timelock.
        DefifaHookLib.validateAndBuildWeights({
            tierWeights: tierWeights, hookStore: IDefifaHook(metadata.dataHook).store(), hook: metadata.dataHook
        });

        // Hash the scorecard to derive its ID.
        scorecardId =
            _hashScorecardOf({gameHook: metadata.dataHook, calldataBytes: _buildScorecardCalldataFor(tierWeights)});

        // Resubmitting the pending scorecard would only restart its timelock.
        if (scorecardId == pendingScorecardIdOf[gameId]) {
            revert DefifaGovernor_DuplicateScorecard({gameId: gameId, scorecardId: scorecardId});
        }

        // Replace the pending scorecard and start its timelock.
        pendingScorecardIdOf[gameId] = scorecardId;
        scorecardSubmittedAtOf[gameId][scorecardId] = block.timestamp;

        // Let indexers record the referee's scorecard and its weights.
        emit ScorecardSubmitted({
            gameId: gameId, scorecardId: scorecardId, tierWeights: tierWeights, caller: msg.sender
        });
    }

    //*********************************************************************//
    // ----------------------- external views ---------------------------- //
    //*********************************************************************//

    /// @notice The ID of a scorecard representing the provided tier weights.
    /// @param gameHook The address where the game is played.
    /// @param tierWeights The weights of each tier in the scorecard.
    /// @return scorecardId The scorecard's ID.
    function scorecardIdOf(
        address gameHook,
        DefifaTierCashOutWeight[] calldata tierWeights
    )
        external
        pure
        virtual
        override
        returns (uint256 scorecardId)
    {
        // Hash the hook with the calldata ratification would send it.
        return _hashScorecardOf({gameHook: gameHook, calldataBytes: _buildScorecardCalldataFor(tierWeights)});
    }

    //*********************************************************************//
    // -------------------------- public views --------------------------- //
    //*********************************************************************//

    /// @notice The state of a submitted scorecard.
    /// @param gameId The ID of the game.
    /// @param scorecardId The ID of the scorecard.
    /// @return state QUEUED while its timelock runs, SUCCEEDED once ratifiable, RATIFIED, or DEFEATED if the referee
    /// replaced it or another scorecard was ratified.
    function stateOf(uint256 gameId, uint256 scorecardId) public view override returns (DefifaScorecardState state) {
        // A ratified game has one winner; every other scorecard lost.
        uint256 ratifiedScorecardId = ratifiedScorecardIdOf[gameId];
        if (ratifiedScorecardId != 0) {
            return ratifiedScorecardId == scorecardId ? DefifaScorecardState.RATIFIED : DefifaScorecardState.DEFEATED;
        }

        // An unknown ID gets no state, so it can't be mistaken for a replaced or waiting scorecard.
        uint256 submittedAt = scorecardSubmittedAtOf[gameId][scorecardId];
        if (submittedAt == 0) revert DefifaGovernor_UnknownProposal({gameId: gameId, scorecardId: scorecardId});

        // A scorecard the referee replaced can't be ratified.
        if (pendingScorecardIdOf[gameId] != scorecardId) return DefifaScorecardState.DEFEATED;

        // The pending scorecard waits out its timelock.
        // Game phase timing is timestamp-based by design.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < submittedAt + timelockDurationOf[gameId]) return DefifaScorecardState.QUEUED;

        // Once the timelock has passed, anyone can ratify it.
        return DefifaScorecardState.SUCCEEDED;
    }

    //*********************************************************************//
    // ----------------------- internal helpers -------------------------- //
    //*********************************************************************//

    /// @notice Build the normalized calldata for ratification.
    /// @param tierWeights The weights of each tier in the scorecard data.
    /// @return calldataBytes The calldata ratification sends to the hook.
    function _buildScorecardCalldataFor(DefifaTierCashOutWeight[] calldata tierWeights)
        internal
        pure
        returns (bytes memory calldataBytes)
    {
        // Build the calldata from the tier weights using the hook's selector.
        return abi.encodeWithSelector(DefifaHook.setTierCashOutWeightsTo.selector, (tierWeights));
    }

    /// @notice A value representing the contents of a scorecard.
    /// @param gameHook The address where the game is played.
    /// @param calldataBytes The calldata that will be sent if the scorecard is ratified.
    /// @return scorecardId The scorecard's ID.
    function _hashScorecardOf(
        address gameHook,
        bytes memory calldataBytes
    )
        internal
        pure
        virtual
        returns (uint256 scorecardId)
    {
        // The hook and the calldata together identify the scorecard.
        return uint256(keccak256(abi.encode(gameHook, calldataBytes)));
    }
}
