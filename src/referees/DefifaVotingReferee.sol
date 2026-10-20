// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJB721TiersHookStore} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHookStore.sol";
import {JB721Tier} from "@bananapus/721-hook-v6/src/structs/JB721Tier.sol";
import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {JBRulesetMetadata} from "@bananapus/core-v6/src/structs/JBRulesetMetadata.sol";
import {mulDiv} from "@prb/math/src/Common.sol";

import {DefifaHook} from "../DefifaHook.sol";

import {DefifaGamePhase} from "../enums/DefifaGamePhase.sol";
import {DefifaScorecardState} from "../enums/DefifaScorecardState.sol";

import {IDefifaDeployer} from "../interfaces/IDefifaDeployer.sol";
import {IDefifaGovernor} from "../interfaces/IDefifaGovernor.sol";
import {IDefifaHook} from "../interfaces/IDefifaHook.sol";
import {IDefifaVotingReferee} from "../interfaces/IDefifaVotingReferee.sol";

import {DefifaHookLib} from "../libraries/DefifaHookLib.sol";

import {DefifaAttestations} from "../structs/DefifaAttestations.sol";
import {DefifaScorecard} from "../structs/DefifaScorecard.sol";
import {DefifaTierCashOutWeight} from "../structs/DefifaTierCashOutWeight.sol";

/// @notice A sample referee that keeps Defifa's holder attestation. Anyone submits a scorecard; holders attest with
/// benefit-weighted attestation (BWA) power read from the hook's delegation checkpoints; a scorecard that reaches its
/// 50% to 75% quorum after the grace period can be forwarded to the game's governor, whose timelock then applies.
/// @dev It also shows how to write a referee. Its rule can be captured: an outsider can buy the votes of thin tiers,
/// holders of more than half the tiers can vote to split the pot among themselves, and holders who lose nothing by a
/// result can be paid to sign it. See RISKS.md.
contract DefifaVotingReferee is IDefifaVotingReferee {
    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    /// @notice Thrown when an account attests to a scorecard it already attested to, so its weight counts once.
    error DefifaVotingReferee_AlreadyAttested(uint256 gameId, uint256 scorecardId, address account);

    /// @notice Thrown when forwarding a scorecard after the game's first approved scorecard was forwarded, so a
    /// competing approved scorecard can't replace it and restart the governor's timelock.
    error DefifaVotingReferee_AlreadyForwarded(uint256 gameId, uint256 scorecardId);

    /// @notice Thrown when initializing a game whose voting settings are already set, so its windows can't change.
    error DefifaVotingReferee_AlreadyInitialized(uint256 gameId);

    /// @notice Thrown when submitting a scorecard for a game whose governor already ratified one, since the result is
    /// final.
    error DefifaVotingReferee_AlreadyRatified(uint256 gameId, uint256 scorecardId);

    /// @notice Thrown when submitting a scorecard already submitted for the game, so its attestations and snapshot
    /// can't be reset.
    error DefifaVotingReferee_DuplicateScorecard(uint256 gameId, uint256 scorecardId);

    /// @notice Thrown when submitting a scorecard for a game this referee has no voting settings for, since its windows
    /// and grace period would be undefined.
    error DefifaVotingReferee_GameNotFound(uint256 gameId);

    /// @notice Thrown when a game's grace period is shorter than the minimum, so a scorecard can't pass before holders
    /// have time to see and contest it.
    error DefifaVotingReferee_GracePeriodTooShort(uint256 gracePeriod, uint256 minGracePeriod);

    /// @notice Thrown when the action is not allowed: the game is not in its scoring phase, the scorecard is not in a
    /// state that permits it, or the caller has no attestation weight for it. Votes only count while the game scores,
    /// in the window the scorecard's state allows, from holders with power.
    error DefifaVotingReferee_NotAllowed(uint256 gameId, uint256 scorecardId, address caller);

    /// @notice Thrown when revoking an attestation the account never made, so the count can't be reduced for free.
    error DefifaVotingReferee_NotAttested(uint256 gameId, uint256 scorecardId, address account);

    /// @notice Thrown when an address other than the game's project owner sets its voting settings, so only the
    /// deployer that launched the game can.
    error DefifaVotingReferee_NotProjectOwner(uint256 gameId, address caller);

    /// @notice Thrown when a timestamp or duration exceeds a uint48, since the referee packs them into 48-bit fields.
    error DefifaVotingReferee_Uint48Overflow(uint256 value, uint256 max);

    /// @notice Thrown when reading the state of a scorecard never submitted to this referee for the game, so an unknown
    /// ID can't be mistaken for one being voted on.
    error DefifaVotingReferee_UnknownProposal(uint256 gameId, uint256 scorecardId);

    /// @notice Thrown when a scorecard pays a tier with no live supply, since no token could redeem that weight.
    error DefifaVotingReferee_UnownedProposedCashoutValue(uint256 gameId, uint256 tierId, uint256 cashOutWeight);

    //*********************************************************************//
    // ------------------------- public constants ------------------------ //
    //*********************************************************************//

    /// @notice The max attestation power each tier has if every token within the tier attests.
    uint256 public constant override MAX_ATTESTATION_POWER_TIER = 1_000_000_000;

    /// @notice The minimum attestation grace period enforced during game initialization.
    uint256 public constant override MIN_ATTESTATION_GRACE_PERIOD = 1 days;

    /// @notice The baseline share of the attestation possible that a scorecard needs, in basis points: approached by a
    /// scorecard spread thinly over many tiers.
    uint256 public constant override QUORUM_EVEN_BPS = 5000;

    /// @notice The share of the attestation possible that a winner-take-all scorecard needs, in basis points.
    /// @dev Kept below 100% so a quarter of a losing side can be silent. BWA rounding loses under 2 units per attesting
    /// delegate and tier, so unanimous attestation reaches quorum while each tier has fewer than 100,000,000 attesting
    /// delegates.
    uint256 public constant override QUORUM_WINNER_TAKE_ALL_BPS = 7500;

    //*********************************************************************//
    // --------------- public immutable stored properties ---------------- //
    //*********************************************************************//

    /// @notice The controller used to find each game's hook, rulesets and project owner.
    IJBController public immutable override CONTROLLER;

    //*********************************************************************//
    // --------------------- public stored properties -------------------- //
    //*********************************************************************//

    /// @notice The scorecard forwarded to each game's governor. Zero if none.
    /// @dev The first approved scorecard forwarded is final, so a competing approved scorecard can't replace it just
    /// before it becomes ratifiable and push the game past its timeout.
    /// @custom:param gameId The ID of the game.
    mapping(uint256 => uint256) public override forwardedScorecardIdOf;

    //*********************************************************************//
    // -------------------- internal stored properties ------------------- //
    //*********************************************************************//

    /// @notice The scorecard information, packed into a uint256.
    /// @dev Bits 0-47: attestationStartTime, bits 48-95: attestationGracePeriod.
    /// @custom:param gameId The ID of the game for which the scorecard info applies.
    mapping(uint256 => uint256) internal _packedScorecardInfoOf;

    /// @notice Snapshot of pending reserves per tier at scorecard submission time.
    /// @dev Used to keep unminted reserve units in the BWA denominator.
    /// @custom:param gameId The ID of the game.
    /// @custom:param scorecardId The ID of the scorecard.
    /// @custom:param tierId The tier ID (1-indexed).
    mapping(uint256 => mapping(uint256 => mapping(uint256 => uint256))) internal _pendingReservesSnapshotOf;

    /// @notice The attestations to a scorecard.
    /// @custom:param gameId The ID of the game the scorecard affects.
    /// @custom:param scorecardId The ID of the scorecard that has been attested to.
    mapping(uint256 => mapping(uint256 => DefifaAttestations)) internal _scorecardAttestationsOf;

    /// @notice The scorecards.
    /// @custom:param gameId The ID of the game the scorecard affects.
    /// @custom:param scorecardId The ID of the scorecard to retrieve.
    mapping(uint256 => mapping(uint256 => DefifaScorecard)) internal _scorecardOf;

    /// @notice Tier weights per scorecard for BWA computation.
    /// @custom:param gameId The ID of the game.
    /// @custom:param scorecardId The ID of the scorecard.
    /// @custom:param tierId The tier ID (0-indexed).
    mapping(uint256 => mapping(uint256 => mapping(uint256 => uint256))) internal _scorecardTierWeightsOf;

    /// @notice Snapshot of each tier's minted attestation units at scorecard submission time.
    /// @dev Caps later checkpoint reads so reserve mints after submission can't increase the denominator
    /// before the pending-reserve snapshot is added back in.
    /// @custom:param gameId The ID of the game.
    /// @custom:param scorecardId The ID of the scorecard.
    /// @custom:param tierId The tier ID (1-indexed).
    mapping(uint256 => mapping(uint256 => mapping(uint256 => uint256))) internal _submittedTierAttestationUnitsOf;

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    /// @notice Creates the referee for games launched through the given controller.
    /// @param controller The controller used to find each game's hook, rulesets and project owner.
    constructor(IJBController controller) {
        CONTROLLER = controller;
    }

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Cast an attestation supporting a proposed scorecard, weighted by the caller's tier voting power.
    /// @dev Power is read at the scorecard's frozen snapshot, one second before submission, so tokens moved in or after
    /// the submission block can't add power. Zero-weight attestations revert, so they can't be repeated for free.
    /// @param gameId The ID of the game to which the scorecard belongs.
    /// @param scorecardId The scorecard ID.
    /// @return weight The attestation weight that was applied.
    function attestToScorecardFrom(uint256 gameId, uint256 scorecardId) external override returns (uint256 weight) {
        // Get the game's current ruleset metadata, which names its hook.
        (, JBRulesetMetadata memory metadata) = CONTROLLER.currentRulesetOf(gameId);

        // Make sure the game is in its scoring phase.
        if (IDefifaHook(metadata.dataHook).gamePhaseReporter().currentGamePhaseOf(gameId) != DefifaGamePhase.SCORING) {
            revert DefifaVotingReferee_NotAllowed({gameId: gameId, scorecardId: scorecardId, caller: msg.sender});
        }

        // Keep a reference to the scorecard being attested to.
        DefifaScorecard storage scorecard = _scorecardOf[gameId][scorecardId];

        // Keep a reference to the scorecard state.
        DefifaScorecardState state = stateOf({gameId: gameId, scorecardId: scorecardId});

        // Attestations are only allowed during ACTIVE or SUCCEEDED states.
        if (state != DefifaScorecardState.ACTIVE && state != DefifaScorecardState.SUCCEEDED) {
            revert DefifaVotingReferee_NotAllowed({gameId: gameId, scorecardId: scorecardId, caller: msg.sender});
        }

        // Keep a reference to the attestations for the scorecard.
        DefifaAttestations storage attestations = _scorecardAttestationsOf[gameId][scorecardId];

        // Make sure the account isn't attesting to the same scorecard again.
        if (attestations.attestedWeightOf[msg.sender] != 0) {
            revert DefifaVotingReferee_AlreadyAttested({gameId: gameId, scorecardId: scorecardId, account: msg.sender});
        }

        // Get a reference to the BWA-adjusted attestation weight, read at the scorecard's frozen snapshot
        // timestamp (one second before submission). This excludes the entire submission block, so a mint or
        // transfer sharing that block cannot grant or move attestation power for this scorecard.
        weight = getBWAAttestationWeight({
            gameId: gameId, scorecardId: scorecardId, account: msg.sender, timestamp: scorecard.snapshotTimestamp
        });

        // Revert if BWA reduces this account's power to zero (e.g. 100% beneficiary of the scorecard).
        // Without this guard, zero-weight attestors could call repeatedly since attestedWeightOf stays 0.
        if (weight == 0) {
            revert DefifaVotingReferee_NotAllowed({gameId: gameId, scorecardId: scorecardId, caller: msg.sender});
        }

        // Add the weight to the scorecard's running total, which `stateOf` compares to its quorum.
        attestations.count += weight;

        // Store the BWA weight that was added (used for accurate subtraction on revoke).
        attestations.attestedWeightOf[msg.sender] = weight;

        // Let indexers track each attestation and its weight.
        emit ScorecardAttested({gameId: gameId, scorecardId: scorecardId, weight: weight, caller: msg.sender});
    }

    /// @notice Send a scorecard that holders approved to the game's governor, starting the governor's timelock.
    /// @dev Only the first approved scorecard forwarded counts; later ones revert.
    /// @param gameId The ID of the game.
    /// @param tierWeights The weights of each tier in the approved scorecard.
    /// @return scorecardId The scorecard's ID.
    function forwardScorecardFor(
        uint256 gameId,
        DefifaTierCashOutWeight[] calldata tierWeights
    )
        external
        override
        returns (uint256 scorecardId)
    {
        // Get the game's current ruleset metadata, which names its hook.
        (, JBRulesetMetadata memory metadata) = CONTROLLER.currentRulesetOf(gameId);

        // Hash the scorecard to derive its ID.
        scorecardId =
            _hashScorecardOf({gameHook: metadata.dataHook, calldataBytes: _buildScorecardCalldataFor(tierWeights)});

        // Only an approved scorecard can be forwarded.
        if (stateOf({gameId: gameId, scorecardId: scorecardId}) != DefifaScorecardState.SUCCEEDED) {
            revert DefifaVotingReferee_NotAllowed({gameId: gameId, scorecardId: scorecardId, caller: msg.sender});
        }

        // Only the first approved scorecard is forwarded, so no competing one can restart the governor's timelock.
        uint256 forwardedScorecardId = forwardedScorecardIdOf[gameId];
        if (forwardedScorecardId != 0) {
            revert DefifaVotingReferee_AlreadyForwarded({gameId: gameId, scorecardId: forwardedScorecardId});
        }

        // Record the forward before the external call, so a re-entrant call can't forward a second scorecard.
        forwardedScorecardIdOf[gameId] = scorecardId;

        // Submit it as the game's referee, which starts the governor's timelock.
        _governorOf(gameId).submitScorecardFor({gameId: gameId, tierWeights: tierWeights});

        // Let indexers see which scorecard reached the governor.
        emit ScorecardForwarded({gameId: gameId, scorecardId: scorecardId, caller: msg.sender});
    }

    /// @notice Set a game's voting windows. Called by the deployer at launch.
    /// @dev Only the game's project owner (the deployer) can call this, once.
    /// @param gameId The ID of the game.
    /// @param data `abi.encode(uint256 attestationStartTime, uint256 attestationGracePeriod)`. A zero start time means
    /// attestations open as soon as a scorecard is submitted.
    function initializeGameFor(uint256 gameId, bytes calldata data) external override {
        // Only the game's project owner can set its voting windows.
        if (msg.sender != CONTROLLER.PROJECTS().ownerOf(gameId)) {
            revert DefifaVotingReferee_NotProjectOwner({gameId: gameId, caller: msg.sender});
        }

        // Make sure the game hasn't already been initialized.
        if (_packedScorecardInfoOf[gameId] != 0) revert DefifaVotingReferee_AlreadyInitialized({gameId: gameId});

        // Read the game's attestation start time and grace period, as the deployer passed them.
        (uint256 attestationStartTime, uint256 attestationGracePeriod) = abi.decode(data, (uint256, uint256));

        // Set a default attestation start time if needed.
        if (attestationStartTime == 0) attestationStartTime = block.timestamp;

        // Enforce a minimum grace period to prevent instant ratification.
        if (attestationGracePeriod < MIN_ATTESTATION_GRACE_PERIOD) {
            revert DefifaVotingReferee_GracePeriodTooShort({
                gracePeriod: attestationGracePeriod, minGracePeriod: MIN_ATTESTATION_GRACE_PERIOD
            });
        }

        // Ensure values fit within their allocated 48-bit widths before packing.
        if (attestationStartTime > type(uint48).max) {
            revert DefifaVotingReferee_Uint48Overflow({value: attestationStartTime, max: type(uint48).max});
        }
        if (attestationGracePeriod > type(uint48).max) {
            revert DefifaVotingReferee_Uint48Overflow({value: attestationGracePeriod, max: type(uint48).max});
        }

        // Pack both into one slot: attestation start time in bits 0-47, attestation grace period in bits 48-95.
        _packedScorecardInfoOf[gameId] = attestationStartTime | (attestationGracePeriod << 48);

        // Let indexers record the game's voting windows.
        emit GameInitialized({
            gameId: gameId,
            attestationStartTime: attestationStartTime,
            attestationGracePeriod: attestationGracePeriod,
            caller: msg.sender
        });
    }

    /// @notice Revoke a previously submitted attestation. Only allowed during the ACTIVE phase.
    /// @dev Once a scorecard is SUCCEEDED (grace period ended + quorum met), revocations are disabled.
    /// This prevents the griefing loop (attest/revoke cycling) while allowing corrective action during debate.
    /// @param gameId The ID of the game.
    /// @param scorecardId The ID of the scorecard to revoke attestation from.
    function revokeAttestationFrom(uint256 gameId, uint256 scorecardId) external virtual override {
        // Only allow revocation during ACTIVE phase.
        if (stateOf({gameId: gameId, scorecardId: scorecardId}) != DefifaScorecardState.ACTIVE) {
            revert DefifaVotingReferee_NotAllowed({gameId: gameId, scorecardId: scorecardId, caller: msg.sender});
        }

        // Keep a reference to the scorecard's attestations.
        DefifaAttestations storage attestations = _scorecardAttestationsOf[gameId][scorecardId];

        // Read the weight this account added, so exactly that amount is removed.
        uint256 weight = attestations.attestedWeightOf[msg.sender];

        // Must have previously attested.
        if (weight == 0) {
            revert DefifaVotingReferee_NotAttested({gameId: gameId, scorecardId: scorecardId, account: msg.sender});
        }

        // Subtract the weight and clear the attestation, so the account can attest again later.
        attestations.count -= weight;
        attestations.attestedWeightOf[msg.sender] = 0;

        // Let indexers track the revocation.
        emit AttestationRevoked({
            gameId: gameId, scorecardId: scorecardId, account: msg.sender, weight: weight, caller: msg.sender
        });
    }

    /// @notice Submits a scorecard to be attested to.
    /// @dev Freezes everything the vote depends on: account power is read one second before submission, each tier's
    /// total units and pending reserves are snapshotted now, and the quorum is fixed by the scorecard's concentration.
    /// Attestations open at the game's start time, or one second after submission, never in the submission block.
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
        // Make sure the game's governor hasn't ratified a scorecard yet.
        uint256 ratifiedScorecardId = _governorOf(gameId).ratifiedScorecardIdOf(gameId);
        if (ratifiedScorecardId != 0) {
            revert DefifaVotingReferee_AlreadyRatified({gameId: gameId, scorecardId: ratifiedScorecardId});
        }

        // Make sure the game has been initialized.
        if (_packedScorecardInfoOf[gameId] == 0) revert DefifaVotingReferee_GameNotFound({gameId: gameId});

        // Keep a reference to the number of tier weights in the proposed scorecard.
        uint256 numberOfTierWeights = tierWeights.length;

        // Get the game's current ruleset metadata, which names its hook.
        (, JBRulesetMetadata memory metadata) = CONTROLLER.currentRulesetOf(gameId);

        // Make sure the game is in its scoring phase.
        if (IDefifaHook(metadata.dataHook).gamePhaseReporter().currentGamePhaseOf(gameId) != DefifaGamePhase.SCORING) {
            revert DefifaVotingReferee_NotAllowed({gameId: gameId, scorecardId: 0, caller: msg.sender});
        }

        // If there's a weight assigned to the tier, make sure there is a token backed by it.
        for (uint256 i; i < numberOfTierWeights;) {
            // A nonzero cash-out weight is only valid once that tier has live ownership.
            uint256 currentTierSupply = IDefifaHook(metadata.dataHook).currentSupplyOfTier(tierWeights[i].id);
            if (tierWeights[i].cashOutWeight > 0 && currentTierSupply == 0) {
                revert DefifaVotingReferee_UnownedProposedCashoutValue({
                    gameId: gameId, tierId: tierWeights[i].id, cashOutWeight: tierWeights[i].cashOutWeight
                });
            }
            // Can't overflow: the index is bounded by the loop's length.
            unchecked {
                ++i;
            }
        }

        // Cache the hook store to avoid repeated external calls.
        IJB721TiersHookStore hookStore = IDefifaHook(metadata.dataHook).store();

        // Run the same structural validation the hook will apply at ratification time so malformed
        // scorecards fail on submission instead of reaching a misleading SUCCEEDED state first.
        DefifaHookLib.validateAndBuildWeights({tierWeights: tierWeights, hookStore: hookStore, hook: metadata.dataHook});

        // Hash the scorecard.
        scorecardId =
            _hashScorecardOf({gameHook: metadata.dataHook, calldataBytes: _buildScorecardCalldataFor(tierWeights)});

        // Keep a reference to the scorecard's storage. A nonzero start means it was already submitted.
        DefifaScorecard storage scorecard = _scorecardOf[gameId][scorecardId];
        if (scorecard.attestationsBegin != 0) {
            revert DefifaVotingReferee_DuplicateScorecard({gameId: gameId, scorecardId: scorecardId});
        }

        // Read the game's earliest attestation time.
        uint256 attestationStartTime = attestationStartTimeOf(gameId);

        // Game phase timing is timestamp-based by design. If attestations would otherwise open immediately,
        // wait until the next timestamp so the attestation window opens in a later block than submission,
        // preventing same-block attestation. The BWA snapshot is taken separately, one second before submission.
        uint256 currentTimestamp = block.timestamp;
        // Attestations open at the game's start time, or one second after submission if that start has passed.
        uint256 attestationsBeginTimestamp = attestationStartTime;
        if (currentTimestamp >= attestationStartTime) attestationsBeginTimestamp = currentTimestamp + 1;

        // The start is stored in 48 bits.
        if (attestationsBeginTimestamp > type(uint48).max) {
            revert DefifaVotingReferee_Uint48Overflow({value: attestationsBeginTimestamp, max: type(uint48).max});
        }

        // Safe after the explicit max check above.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint48 attestationsBegin = uint48(attestationsBeginTimestamp);

        // Record when attestations open, which also marks the scorecard as submitted.
        scorecard.attestationsBegin = attestationsBegin;

        // The grace period runs from when attestations begin, so it can't expire before holders can attest to a
        // scorecard submitted early.
        uint256 gracePeriodEnds = uint256(attestationsBegin) + attestationGracePeriodOf(gameId);

        // The end is stored in 48 bits.
        if (gracePeriodEnds > type(uint48).max) {
            revert DefifaVotingReferee_Uint48Overflow({value: gracePeriodEnds, max: type(uint48).max});
        }
        // Safe after the explicit max check above.
        // forge-lint: disable-next-line(unsafe-typecast)
        scorecard.gracePeriodEnds = uint48(gracePeriodEnds);

        // Freeze the BWA snapshot one second before submission. `getPastTier*AttestationUnitsOf` reads checkpoints
        // keyed by `block.timestamp`, and same-timestamp checkpoint writes overwrite in place — so reading at the
        // submission timestamp would let a mint or transfer in the submission block (in either order relative to
        // submission) change this scorecard's attestation power. Reading one second earlier excludes the entire
        // submission block.
        // Safe: `currentTimestamp - 1 < attestationsBeginTimestamp <= type(uint48).max` per the check above.
        // forge-lint: disable-next-line(unsafe-typecast)
        scorecard.snapshotTimestamp = uint48(currentTimestamp - 1);

        // Store tier weights for BWA computation.
        for (uint256 i; i < numberOfTierWeights;) {
            // Tier IDs are 1-indexed; the weights are stored 0-indexed to match the tier loop in BWA.
            _scorecardTierWeightsOf[gameId][scorecardId][tierWeights[i].id - 1] = tierWeights[i].cashOutWeight;
            // Can't overflow: the index is bounded by the loop's length.
            unchecked {
                ++i;
            }
        }

        // Snapshot each tier's pending reserves and minted attestation units at submission time.
        // BWA reads account checkpoints at `snapshotTimestamp` (one second before submission), so each tier's total is
        // frozen here too: the units minted at submission plus the pending reserves snapshotted now. Reserves minted
        // after this point can't change the total.
        {
            // Cache the number of tiers to avoid re-reading from storage.
            uint256 numberOfTiers = hookStore.maxTierIdOf(metadata.dataHook);
            // Snapshot every tier, since any tier's holders can attest.
            for (uint256 i; i < numberOfTiers;) {
                // Tiers are 1-indexed.
                uint256 tierId = i + 1;

                // Read the tier for its voting units per token.
                JB721Tier memory tier =
                    hookStore.tierOf({hook: metadata.dataHook, id: tierId, includeResolvedUri: false});

                // Use adjusted pending reserves that account for refund-phase burns.
                uint256 pendingReserves = IDefifaHook(metadata.dataHook).adjustedPendingReservesFor(tierId);

                // The tier's minted attestation units right now.
                uint256 submittedTierAttestationUnits =
                    IDefifaHook(metadata.dataHook).currentSupplyOfTier(tierId) * tier.votingUnits;

                // Freeze both, so this scorecard's denominators can't move after submission.
                _pendingReservesSnapshotOf[gameId][scorecardId][tierId] = pendingReserves;
                _submittedTierAttestationUnitsOf[gameId][scorecardId][tierId] = submittedTierAttestationUnits;
                // Can't overflow: the index is bounded by the loop's length.
                unchecked {
                    ++i;
                }
            }
        }

        // Quorum rises from QUORUM_EVEN_BPS to QUORUM_WINNER_TAKE_ALL_BPS of the most attestation possible as the
        // largest share grows, by that share squared: gentle for moderate concentration, steepest for winner-take-all.
        {
            // The weight every scorecard's tier weights add up to.
            uint256 totalCashOutWeight = IDefifaHook(metadata.dataHook).TOTAL_CASHOUT_WEIGHT();

            // Find the largest tier weight, which sets how concentrated the scorecard is.
            uint256 maxWeight;
            // Scan every proposed weight.
            for (uint256 i; i < numberOfTierWeights;) {
                // Keep the larger weight.
                if (tierWeights[i].cashOutWeight > maxWeight) maxWeight = tierWeights[i].cashOutWeight;
                // Can't overflow: the index is bounded by the loop's length.
                unchecked {
                    ++i;
                }
            }

            // maxShare² in totalCashOutWeight scale.
            uint256 maxShareSquared = mulDiv({x: maxWeight, y: maxWeight, denominator: totalCashOutWeight});

            // Interpolate the required share between the even and winner-take-all levels.
            uint256 bps = QUORUM_EVEN_BPS
                + mulDiv({
                    x: QUORUM_WINNER_TAKE_ALL_BPS - QUORUM_EVEN_BPS, y: maxShareSquared, denominator: totalCashOutWeight
                });

            // Freeze the scorecard's quorum at submission.
            scorecard.quorumSnapshot = _quorumOf({maxAttestationWeight: _maxAttestationWeightOf(gameId), bps: bps});
        }

        // Let indexers record the scorecard and its weights.
        emit ScorecardSubmitted({
            gameId: gameId, scorecardId: scorecardId, tierWeights: tierWeights, caller: msg.sender
        });
    }

    //*********************************************************************//
    // ----------------------- external views ---------------------------- //
    //*********************************************************************//

    /// @notice The attestation weight a scorecard has collected.
    /// @param gameId The ID of the game to which the scorecard belongs.
    /// @param scorecardId The ID of the scorecard to get attestations of.
    /// @return count The total attestation weight.
    function attestationCountOf(uint256 gameId, uint256 scorecardId) external view override returns (uint256 count) {
        // The running total kept by attest and revoke.
        return _scorecardAttestationsOf[gameId][scorecardId].count;
    }

    /// @notice A flag indicating if the given account has already attested to the scorecard.
    /// @param gameId The ID of the game to which the scorecard belongs.
    /// @param scorecardId The ID of the scorecard to query attestations from.
    /// @param account The address to check the attestation status of.
    /// @return attested True if the account has attested to the scorecard.
    function hasAttestedTo(
        uint256 gameId,
        uint256 scorecardId,
        address account
    )
        external
        view
        override
        returns (bool attested)
    {
        // An attestation always records a nonzero weight.
        return _scorecardAttestationsOf[gameId][scorecardId].attestedWeightOf[account] != 0;
    }

    /// @notice The baseline quorum: 50% of the attestation possible, which a scorecard spread thinly over many tiers
    /// approaches.
    /// @dev The attestation possible is `(N - 1) * MAX_ATTESTATION_POWER_TIER` for N quorum-eligible tiers, because a
    /// tier never attests to its own payout. Scorecards need `QUORUM_EVEN_BPS` of it plus more as they concentrate, up
    /// to `QUORUM_WINNER_TAKE_ALL_BPS` (see `submitScorecardFor`), so integrations checking a specific scorecard should
    /// use `quorumOf`. Every tier has the same power regardless of supply, so each outcome's community has equal
    /// influence.
    /// @param gameId The ID of the game.
    /// @return quorumWeight The baseline quorum.
    function quorum(uint256 gameId) external view override returns (uint256 quorumWeight) {
        // Apply the baseline share to the attestation possible right now.
        return _quorumOf({maxAttestationWeight: _maxAttestationWeightOf(gameId), bps: QUORUM_EVEN_BPS});
    }

    /// @notice The attestation a submitted scorecard needs to pass, fixed at its submission by its concentration.
    /// @param gameId The ID of the game.
    /// @param scorecardId The ID of the scorecard.
    /// @return quorumWeight The quorum threshold, or 0 if the scorecard was never submitted.
    function quorumOf(uint256 gameId, uint256 scorecardId) external view override returns (uint256 quorumWeight) {
        // The quorum frozen when the scorecard was submitted.
        return _scorecardOf[gameId][scorecardId].quorumSnapshot;
    }

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

    /// @notice The time after attestations open during which a scorecard can't pass, even at quorum.
    /// @param gameId The ID of the game to get the attestation period of.
    /// @return gracePeriod The attestation grace period, in seconds.
    function attestationGracePeriodOf(uint256 gameId) public view override returns (uint256 gracePeriod) {
        // attestation grace period in bits 48-95 (48 bits).
        return uint256(uint48(_packedScorecardInfoOf[gameId] >> 48));
    }

    /// @notice The earliest timestamp a game's scorecards accept attestations.
    /// @dev A scorecard submitted after this opens to attestations one second after submission. Attestation power is
    /// read one second before submission, so tokens acquired or delegated after a scorecard is submitted don't count
    /// toward it.
    /// @param gameId The ID of the game.
    /// @return startTime The attestation start timestamp.
    function attestationStartTimeOf(uint256 gameId) public view override returns (uint256 startTime) {
        // attestation start time in bits 0-47 (48 bits).
        return uint256(uint48(_packedScorecardInfoOf[gameId]));
    }

    /// @notice An account's attestation power at a timestamp, before any scorecard's benefit discount.
    /// @dev An account's power per tier = MAX_ATTESTATION_POWER_TIER * (account's units / tier's total units).
    /// This means within a tier, power is proportional to token holdings, but across tiers, each tier's
    /// total power is capped at MAX_ATTESTATION_POWER_TIER. A holder of 1-of-1 in a tier gets
    /// MAX_ATTESTATION_POWER_TIER; a holder of 1-of-100 gets MAX_ATTESTATION_POWER_TIER / 100.
    /// This ensures each game outcome (tier) has equal governance weight — the scorecard reflects
    /// consensus across outcomes, not dominance by whichever outcome sold the most tokens.
    /// @param gameId The ID of the game to count attestations for.
    /// @param account The account to get attestations for.
    /// @param timestamp The timestamp to measure attestations from.
    /// @return attestationPower The amount of attestation power of an account.
    function getAttestationWeight(
        uint256 gameId,
        address account,
        uint48 timestamp
    )
        public
        view
        virtual
        override
        returns (uint256 attestationPower)
    {
        // Get the game's current ruleset metadata, which names its hook.
        (, JBRulesetMetadata memory metadata) = CONTROLLER.currentRulesetOf(gameId);

        // Get a reference to the hook and its store.
        IDefifaHook hook = IDefifaHook(metadata.dataHook);
        // Get a reference to the hook's store, which holds each tier's voting units.
        IJB721TiersHookStore store = hook.store();

        // Get a reference to the number of tiers.
        uint256 numberOfTiers = store.maxTierIdOf(metadata.dataHook);

        // Add up the account's share of each tier.
        for (uint256 i; i < numberOfTiers;) {
            // Tiers are 1-indexed.
            uint256 tierId = i + 1;

            // Get this account's attestation units within the tier (snapshot at timestamp).
            uint256 tierAttestationUnitsForAccount =
                hook.getPastTierAttestationUnitsOf({account: account, tier: tierId, timestamp: timestamp});

            // Get the total attestation units for this tier (snapshot at timestamp).
            uint256 tierTotalAttestationUnits =
                hook.getPastTierTotalAttestationUnitsOf({tier: tierId, timestamp: timestamp});

            // Include unminted pending reserves in the total (denominator only). This ensures every
            // token holder's voting power already accounts for reserves that will eventually be minted.
            // When the reserve beneficiary later mints, their new NFTs add to the numerator while
            // pending reserves decrease by the same amount — so no one's voting power shifts.
            {
                // Use adjusted pending reserves that account for refund-phase burns.
                uint256 pendingReserves = IDefifaHook(metadata.dataHook).adjustedPendingReservesFor(tierId);
                // Only tiers with pending reserves need them added.
                if (pendingReserves != 0) {
                    // Read the tier for its voting units per token.
                    JB721Tier memory tier =
                        store.tierOf({hook: metadata.dataHook, id: tierId, includeResolvedUri: false});

                    // Each pending reserve will carry the tier's voting units once minted.
                    tierTotalAttestationUnits += pendingReserves * tier.votingUnits;
                }
            }

            // Scale the account's share of the tier to MAX_ATTESTATION_POWER_TIER.
            // e.g. holding 3 of 10 tokens -> 3/10 * MAX_ATTESTATION_POWER_TIER attestation power from this tier.
            // Can't overflow: each tier adds at most MAX_ATTESTATION_POWER_TIER, over at most 128 tiers, and the index
            // is bounded by the tier count.
            unchecked {
                // Tiers the account holds no units in add nothing, so skip the division.
                if (tierAttestationUnitsForAccount != 0) {
                    attestationPower += mulDiv({
                        x: MAX_ATTESTATION_POWER_TIER,
                        y: tierAttestationUnitsForAccount,
                        denominator: tierTotalAttestationUnits
                    });
                }
                ++i;
            }
        }
    }

    /// @notice Gets an account's BWA-adjusted attestation power relative to a specific scorecard.
    /// @dev BWA (Benefit-Weighted Attestation) reduces a tier's attestation power by how much
    /// that tier benefits from the scorecard. Power is reduced by `(tierWeight / totalCashOutWeight)`.
    /// This means a tier with 100% of the scorecard weight gets 0 attestation power for that scorecard,
    /// while a tier with 0% weight retains full power. Tiers that split a payout keep the unpaid share of their power.
    /// @param gameId The ID of the game.
    /// @param scorecardId The ID of the scorecard (determines tier weight lookup).
    /// @param account The account to compute BWA power for.
    /// @param timestamp The snapshot timestamp.
    /// @return bwaAttestationPower The BWA-adjusted attestation power.
    // forge-lint: disable-next-line(mixed-case-function)
    function getBWAAttestationWeight(
        uint256 gameId,
        uint256 scorecardId,
        address account,
        uint48 timestamp
    )
        public
        view
        virtual
        override
        returns (uint256 bwaAttestationPower)
    {
        // Get the game's current ruleset metadata, which names its hook.
        (, JBRulesetMetadata memory metadata) = CONTROLLER.currentRulesetOf(gameId);

        // Get a reference to the hook.
        IDefifaHook hook = IDefifaHook(metadata.dataHook);

        // Get a reference to the hook's store.
        IJB721TiersHookStore store = hook.store();

        // Get a reference to the number of tiers.
        uint256 numberOfTiers = store.maxTierIdOf(metadata.dataHook);

        // Cache the total cash-out weight denominator from the hook.
        uint256 totalCashOutWeight = hook.TOTAL_CASHOUT_WEIGHT();

        // Add up the account's discounted share of each tier.
        for (uint256 i; i < numberOfTiers;) {
            // Tiers are 1-indexed.
            uint256 tierId = i + 1;

            // Get this account's attestation units within the tier (snapshot at timestamp).
            uint256 tierAttestationUnitsForAccount =
                hook.getPastTierAttestationUnitsOf({account: account, tier: tierId, timestamp: timestamp});

            // Only tiers the account holds units in add power.
            if (tierAttestationUnitsForAccount != 0) {
                // The tier's attestation units frozen at the scorecard's submission.
                uint256 tierTotalAttestationUnits =
                    _tierAttestationUnitsAt({gameId: gameId, scorecardId: scorecardId, hook: hook, tierId: tierId});

                // The account's share of the tier, scaled to the tier's power.
                uint256 rawPower = mulDiv({
                    x: MAX_ATTESTATION_POWER_TIER,
                    y: tierAttestationUnitsForAccount,
                    denominator: tierTotalAttestationUnits
                });

                // BWA reduction: power * (1 - tierWeight / totalCashOutWeight).
                uint256 tierWeight = _scorecardTierWeightsOf[gameId][scorecardId][i];
                // The unpaid share of the total weight is the tier's remaining power.
                uint256 bwaMultiplier = totalCashOutWeight - tierWeight;

                // Add the tier's discounted power.
                bwaAttestationPower += mulDiv({x: rawPower, y: bwaMultiplier, denominator: totalCashOutWeight});
            }

            // Can't overflow: the index is bounded by the loop's length.

            unchecked {
                ++i;
            }
        }
    }

    /// @notice The voting state of a submitted scorecard.
    /// @dev Boundary semantics (inclusive):
    ///   - At exactly `attestationsBegin`, the state transitions from PENDING to ACTIVE (attestations are open).
    ///   - At exactly `gracePeriodEnds`, the grace period has elapsed and the state transitions from ACTIVE to
    ///     SUCCEEDED if quorum is met.
    /// @param gameId The ID of the game to get a proposal state of.
    /// @param scorecardId The ID of the proposal to get the state of.
    /// @return state PENDING, ACTIVE or SUCCEEDED, then RATIFIED or DEFEATED once the game's governor ratifies.
    function stateOf(
        uint256 gameId,
        uint256 scorecardId
    )
        public
        view
        virtual
        override
        returns (DefifaScorecardState state)
    {
        // Keep a reference to the scorecard the game's governor ratified.
        uint256 ratifiedScorecardId = _governorOf(gameId).ratifiedScorecardIdOf(gameId);

        // Once the governor ratifies a scorecard, that one is RATIFIED and every other is DEFEATED.
        if (ratifiedScorecardId != 0) {
            return ratifiedScorecardId == scorecardId ? DefifaScorecardState.RATIFIED : DefifaScorecardState.DEFEATED;
        }

        // Get a reference to the scorecard.
        DefifaScorecard memory scorecard = _scorecardOf[gameId][scorecardId];

        // An unknown ID gets no state, so it can't be mistaken for a scorecard being voted on.
        if (scorecard.attestationsBegin == 0) {
            revert DefifaVotingReferee_UnknownProposal({gameId: gameId, scorecardId: scorecardId});
        }

        // If the scorecard has attestations beginning in the future, the state is PENDING.
        // At exactly `attestationsBegin`, attestations are open so the state is ACTIVE.
        // Game phase timing is timestamp-based by design.
        // forge-lint: disable-next-line(block-timestamp)
        if (scorecard.attestationsBegin > block.timestamp) {
            return DefifaScorecardState.PENDING;
        }

        // If the scorecard's grace period has not yet ended, the state is ACTIVE.
        // At exactly `gracePeriodEnds`, the grace period has elapsed so we fall through to the quorum check.
        // Game phase timing is timestamp-based by design.
        // forge-lint: disable-next-line(block-timestamp)
        if (scorecard.gracePeriodEnds > block.timestamp) {
            return DefifaScorecardState.ACTIVE;
        }

        // Once the grace period is over, a scorecard at quorum (using its concentration-adjusted snapshot) can be
        // forwarded to the governor, whose timelock then applies.
        if (scorecard.quorumSnapshot <= _scorecardAttestationsOf[gameId][scorecardId].count) {
            return DefifaScorecardState.SUCCEEDED;
        }

        // Scorecards that fail to reach quorum remain ACTIVE indefinitely — there is no DEFEATED
        // state transition for unratified scorecards. This is by design: new scorecards can always be
        // submitted and the game's no-contest timeout (scorecardTimeout) provides the ultimate backstop.
        return DefifaScorecardState.ACTIVE;
    }

    //*********************************************************************//
    // ----------------------- internal helpers -------------------------- //
    //*********************************************************************//

    /// @notice Build the normalized calldata for ratification.
    /// @param tierWeights The weights of each tier in the scorecard data.
    /// @return calldataBytes The calldata ratification would send to the hook.
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

    /// @notice A share of the most attestation possible.
    /// @dev Never below 1, so a game with no possible attestation (a single eligible tier) can never ratify and falls
    /// through to NO_CONTEST.
    /// @param maxAttestationWeight The most attestation possible.
    /// @param bps The share, in basis points.
    /// @return quorumWeight The attestation needed.
    function _quorumOf(uint256 maxAttestationWeight, uint256 bps) internal pure returns (uint256 quorumWeight) {
        // Take the share of the attestation possible, rounding down; the floor below covers the zero case.
        quorumWeight = mulDiv({x: maxAttestationWeight, y: bps, denominator: 10_000});

        // Never below 1, so a scorecard with no possible attestation can't pass with zero attestations.
        if (quorumWeight == 0) quorumWeight = 1;
    }

    //*********************************************************************//
    // ------------------------- internal views -------------------------- //
    //*********************************************************************//

    /// @notice The governor of a game, read from the deployer that owns the game's project.
    /// @param gameId The ID of the game.
    /// @return governor The game's governor.
    function _governorOf(uint256 gameId) internal view returns (IDefifaGovernor governor) {
        // The deployer that launched the game owns its project and knows its governor.
        return IDefifaDeployer(CONTROLLER.PROJECTS().ownerOf(gameId)).GOVERNOR();
    }

    /// @notice The most attestation any scorecard of a game can collect: `(N - 1) * MAX_ATTESTATION_POWER_TIER` for N
    /// quorum-eligible tiers.
    /// @dev A tier is quorum-eligible if it has circulating tokens or pending reserves net of refund-phase burns
    /// (`adjustedPendingReservesFor`), so a reserve beneficiary still owed reserves keeps the tier counted. No snapshot
    /// is needed: during SCORING, paid supply is frozen, and reserve mints never change which tiers count.
    /// @param gameId The ID of the game.
    /// @return maxAttestationWeight The most attestation possible.
    function _maxAttestationWeightOf(uint256 gameId) internal view returns (uint256 maxAttestationWeight) {
        // Get the game's current ruleset metadata, which names its hook.
        (, JBRulesetMetadata memory metadata) = CONTROLLER.currentRulesetOf(gameId);

        // Get a reference to the hook.
        IDefifaHook hook = IDefifaHook(metadata.dataHook);

        // Get a reference to the number of tiers.
        uint256 numberOfTiers = hook.store().maxTierIdOf(metadata.dataHook);

        // Count the quorum-eligible tiers.
        uint256 eligibleTiers;
        // Check every tier.
        for (uint256 i; i < numberOfTiers;) {
            // Tiers are 1-indexed.
            uint256 tierId = i + 1;

            // Use adjusted pending reserves that account for refund-phase burns.
            if (hook.currentSupplyOfTier(tierId) != 0 || hook.adjustedPendingReservesFor(tierId) != 0) {
                ++eligibleTiers;
            }

            // Can't overflow: the index is bounded by the loop's length.

            unchecked {
                ++i;
            }
        }

        // A tier never attests to its own payout, so the most any scorecard can collect is every other tier's power.
        if (eligibleTiers != 0) maxAttestationWeight = (eligibleTiers - 1) * MAX_ATTESTATION_POWER_TIER;
    }

    /// @notice A tier's attestation units for a scorecard, frozen at its submission.
    /// @dev The units minted when the scorecard was submitted plus the pending reserves snapshotted then. Account
    /// numerators are read one second before submission, so reserves minted in the submission block (before or after
    /// the submission) must stay in this total, or an account would attest with a larger share of its tier than it
    /// holds. Each reserve unit is counted exactly once: minted reserves are in the submitted units, pending ones in
    /// the snapshot.
    /// @param gameId The ID of the game.
    /// @param scorecardId The ID of the scorecard whose snapshot to use.
    /// @param hook The game's hook.
    /// @param tierId The ID of the tier.
    /// @return units The tier's attestation units.
    function _tierAttestationUnitsAt(
        uint256 gameId,
        uint256 scorecardId,
        IDefifaHook hook,
        uint256 tierId
    )
        internal
        view
        returns (uint256 units)
    {
        // Start from the units minted when the scorecard was submitted.
        units = _submittedTierAttestationUnitsOf[gameId][scorecardId][tierId];

        // Add the pending reserves snapshotted at submission.
        uint256 pendingReserves = _pendingReservesSnapshotOf[gameId][scorecardId][tierId];
        // Only tiers with pending reserves need them added.
        if (pendingReserves != 0) {
            // Read the tier for its voting units per token.
            JB721Tier memory tier = hook.store().tierOf({hook: address(hook), id: tierId, includeResolvedUri: false});

            // Each pending reserve will carry the tier's voting units once minted.
            units += pendingReserves * tier.votingUnits;
        }
    }
}
