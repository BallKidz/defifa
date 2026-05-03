// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {JBRulesetMetadata} from "@bananapus/core-v6/src/structs/JBRulesetMetadata.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {mulDiv} from "@prb/math/src/Common.sol";

import {DefifaHook} from "./DefifaHook.sol";
import {DefifaGamePhase} from "./enums/DefifaGamePhase.sol";
import {DefifaScorecardState} from "./enums/DefifaScorecardState.sol";
import {IDefifaDeployer} from "./interfaces/IDefifaDeployer.sol";
import {IDefifaGovernor} from "./interfaces/IDefifaGovernor.sol";
import {IJB721TiersHookStore} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHookStore.sol";
import {JB721Tier} from "@bananapus/721-hook-v6/src/structs/JB721Tier.sol";
import {IDefifaHook} from "./interfaces/IDefifaHook.sol";
import {DefifaAttestations} from "./structs/DefifaAttestations.sol";
import {DefifaScorecard} from "./structs/DefifaScorecard.sol";
import {DefifaTierCashOutWeight} from "./structs/DefifaTierCashOutWeight.sol";
import {DefifaHookLib} from "./libraries/DefifaHookLib.sol";

/// @notice Manages the ratification of Defifa scorecards.
contract DefifaGovernor is Ownable, IDefifaGovernor {
    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    error DefifaGovernor_AlreadyAttested();
    error DefifaGovernor_AlreadyInitialized();
    error DefifaGovernor_AlreadyRatified();
    error DefifaGovernor_DuplicateScorecard();
    error DefifaGovernor_GameNotFound();
    error DefifaGovernor_GracePeriodTooShort();
    error DefifaGovernor_IncorrectTierOrder();
    error DefifaGovernor_NotAllowed();
    error DefifaGovernor_NotAttested();
    error DefifaGovernor_Uint48Overflow();
    error DefifaGovernor_UnknownProposal();
    error DefifaGovernor_UnownedProposedCashoutValue();

    //*********************************************************************//
    // ------------------------- public constants ------------------------ //
    //*********************************************************************//

    /// @notice The max attestation power each tier has if every token within the tier attestations.
    uint256 public constant override MAX_ATTESTATION_POWER_TIER = 1_000_000_000;

    /// @notice The minimum attestation grace period enforced during game initialization.
    uint256 public constant override MIN_ATTESTATION_GRACE_PERIOD = 1 days;

    //*********************************************************************//
    // --------------- public immutable stored properties ---------------- //
    //*********************************************************************//

    /// @notice The controller with which new projects should be deployed.
    IJBController public immutable override CONTROLLER;

    //*********************************************************************//
    // --------------------- public stored properties -------------------- //
    //*********************************************************************//

    /// @notice The latest proposal submitted by the default attestation delegate.
    /// @custom:param gameId The ID of the game of the default attestation delegate proposal.
    mapping(uint256 => uint256) public override defaultAttestationDelegateProposalOf;

    /// @notice The scorecard that has been ratified.
    /// @custom:param gameId The ID of the game of the ratified scorecard.
    mapping(uint256 => uint256) public override ratifiedScorecardIdOf;

    //*********************************************************************//
    // -------------------- internal stored properties ------------------- //
    //*********************************************************************//

    /// @notice The scorecard information, packed into a uint256.
    /// @dev Bits 0-47: attestationStartTime, bits 48-95: attestationGracePeriod, bits 96-143: timelockDuration.
    /// @custom:param gameId The ID of the game for which the scorecard info applies.
    mapping(uint256 => uint256) internal _packedScorecardInfoOf;

    /// @notice The scorecards.
    /// @custom:param gameId The ID of the game for which the scorecard affects.
    /// @custom:param scorecardId The ID of the scorecard to retrieve.
    mapping(uint256 => mapping(uint256 => DefifaScorecard)) internal _scorecardOf;

    /// @notice The attestations to a scorecard.
    /// @custom:param gameId The ID of the game for which the scorecard affects.
    /// @custom:param scorecardId The ID of the scorecard that has been attested to.
    mapping(uint256 => mapping(uint256 => DefifaAttestations)) internal _scorecardAttestationsOf;

    /// @notice Snapshot of pending reserves per tier at scorecard submission time.
    /// @dev Used to keep unminted reserve units in the BWA denominator.
    /// @custom:param gameId The ID of the game.
    /// @custom:param scorecardId The ID of the scorecard.
    /// @custom:param tierId The tier ID (1-indexed).
    mapping(uint256 => mapping(uint256 => mapping(uint256 => uint256))) internal _pendingReservesSnapshotOf;

    /// @notice Snapshot of each tier's minted attestation units at scorecard submission time.
    /// @dev Caps later checkpoint reads so reserve mints after submission can't increase the denominator
    /// before the pending-reserve snapshot is added back in.
    /// @custom:param gameId The ID of the game.
    /// @custom:param scorecardId The ID of the scorecard.
    /// @custom:param tierId The tier ID (1-indexed).
    mapping(uint256 => mapping(uint256 => mapping(uint256 => uint256))) internal _submittedTierAttestationUnitsOf;

    /// @notice Tier weights per scorecard for BWA computation.
    /// @custom:param gameId The ID of the game.
    /// @custom:param scorecardId The ID of the scorecard.
    /// @custom:param tierId The tier ID (0-indexed).
    mapping(uint256 => mapping(uint256 => mapping(uint256 => uint256))) internal _scorecardTierWeightsOf;

    /// @notice The timestamp when quorum was first reached for a scorecard.
    /// @dev Reset to 0 if attestations drop below quorum via revocation.
    /// @custom:param gameId The ID of the game.
    /// @custom:param scorecardId The ID of the scorecard.
    mapping(uint256 => mapping(uint256 => uint48)) internal _quorumReachedAtOf;

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    constructor(IJBController controller, address owner) Ownable(owner) {
        CONTROLLER = controller;
    }

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Attests to a scorecard.
    /// @param gameId The ID of the game to which the scorecard belongs.
    /// @param scorecardId The scorecard ID.
    /// @return weight The attestation weight that was applied.
    function attestToScorecardFrom(uint256 gameId, uint256 scorecardId) external override returns (uint256 weight) {
        // Get the game's current funding cycle along with its metadata.
        // slither-disable-next-line unused-return
        (, JBRulesetMetadata memory metadata) = CONTROLLER.currentRulesetOf(gameId);

        // Make sure the game is in its scoring phase.
        if (IDefifaHook(metadata.dataHook).gamePhaseReporter().currentGamePhaseOf(gameId) != DefifaGamePhase.SCORING) {
            revert DefifaGovernor_NotAllowed();
        }

        // Keep a reference to the scorecard being attested to.
        DefifaScorecard storage scorecard = _scorecardOf[gameId][scorecardId];

        // Keep a reference to the scorecard state.
        DefifaScorecardState state = stateOf({gameId: gameId, scorecardId: scorecardId});

        // Attestations are only allowed during ACTIVE, SUCCEEDED, or QUEUED states.
        if (
            state != DefifaScorecardState.ACTIVE && state != DefifaScorecardState.SUCCEEDED
                && state != DefifaScorecardState.QUEUED
        ) {
            revert DefifaGovernor_NotAllowed();
        }

        // Keep a reference to the attestations for the scorecard.
        DefifaAttestations storage attestations = _scorecardAttestationsOf[gameId][scorecardId];

        // Make sure the account isn't attesting to the same scorecard again.
        if (attestations.attestedWeightOf[msg.sender] != 0) revert DefifaGovernor_AlreadyAttested();

        // Get a reference to the BWA-adjusted attestation weight, snapshotted at one second before
        // `attestationsBegin`. Using `attestationsBegin - 1` ensures the checkpoint is from before the
        // attestation window opens, preventing same-block transfer/re-attest exploits.
        weight = getBWAAttestationWeight({
            gameId: gameId, scorecardId: scorecardId, account: msg.sender, timestamp: scorecard.attestationsBegin - 1
        });

        // Revert if BWA reduces this account's power to zero (e.g. 100% beneficiary of the scorecard).
        // Without this guard, zero-weight attestors could call repeatedly since attestedWeightOf stays 0.
        if (weight == 0) revert DefifaGovernor_NotAllowed();

        // Increase the attestation count.
        attestations.count += weight;

        // Record when quorum is first reached so the timelock anchors to this moment.
        if (_quorumReachedAtOf[gameId][scorecardId] == 0 && attestations.count >= scorecard.quorumSnapshot) {
            _quorumReachedAtOf[gameId][scorecardId] = uint48(block.timestamp);
        }

        // Store the BWA weight that was added (used for accurate subtraction on revoke).
        attestations.attestedWeightOf[msg.sender] = weight;

        emit ScorecardAttested(gameId, scorecardId, weight, msg.sender);
    }

    /// @notice Ratifies a scorecard that has been approved.
    /// @param gameId The ID of the game.
    /// @param tierWeights The weights of each tier in the approved scorecard.
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
        if (ratifiedScorecardIdOf[gameId] != 0) revert DefifaGovernor_AlreadyRatified();

        // Get the game's current funding cycle along with its metadata.
        // slither-disable-next-line unused-return
        (, JBRulesetMetadata memory metadata) = CONTROLLER.currentRulesetOf(gameId);

        // Build the calldata to the target.
        bytes memory scorecardCalldata = _buildScorecardCalldataFor(tierWeights);

        // Hash the scorecard to derive its ID.
        scorecardId = _hashScorecardOf({gameHook: metadata.dataHook, calldataBytes: scorecardCalldata});

        // Make sure the proposal being ratified has succeeded.
        if (stateOf({gameId: gameId, scorecardId: scorecardId}) != DefifaScorecardState.SUCCEEDED) {
            revert DefifaGovernor_NotAllowed();
        }

        // Set the ratified scorecard.
        ratifiedScorecardIdOf[gameId] = scorecardId;

        // Execute the scorecard via low-level call since the governor is the delegate's owner.
        (bool success, bytes memory returndata) = metadata.dataHook.call(scorecardCalldata);
        // slither-disable-next-line unused-return
        Address.verifyCallResult({success: success, returndata: returndata});

        // Fulfill any commitments for the game. The internal try-catch in fulfillCommitmentsOf
        // handles sendPayoutsOf failures, ensuring the final ruleset is always queued.
        IDefifaDeployer(CONTROLLER.PROJECTS().ownerOf(gameId)).fulfillCommitmentsOf(gameId);

        // slither-disable-next-line reentrancy-events
        emit ScorecardRatified(gameId, scorecardId, msg.sender);
    }

    /// @notice Revoke a previously submitted attestation. Only allowed during the ACTIVE phase.
    /// @dev Once a scorecard enters QUEUED (grace period ended + quorum met), revocations are disabled.
    /// This prevents the griefing loop (attest/revoke cycling) while allowing corrective action during debate.
    /// @param gameId The ID of the game.
    /// @param scorecardId The ID of the scorecard to revoke attestation from.
    function revokeAttestationFrom(uint256 gameId, uint256 scorecardId) external virtual override {
        // Only allow revocation during ACTIVE phase.
        if (stateOf({gameId: gameId, scorecardId: scorecardId}) != DefifaScorecardState.ACTIVE) {
            revert DefifaGovernor_NotAllowed();
        }

        DefifaAttestations storage attestations = _scorecardAttestationsOf[gameId][scorecardId];
        uint256 weight = attestations.attestedWeightOf[msg.sender];

        // Must have previously attested.
        if (weight == 0) revert DefifaGovernor_NotAttested();

        // Subtract the weight and clear the attestation.
        attestations.count -= weight;
        attestations.attestedWeightOf[msg.sender] = 0;

        // Reset quorum timestamp if attestations drop below quorum.
        DefifaScorecard storage scorecard = _scorecardOf[gameId][scorecardId];
        if (attestations.count < scorecard.quorumSnapshot) {
            _quorumReachedAtOf[gameId][scorecardId] = 0;
        }

        emit AttestationRevoked(gameId, scorecardId, msg.sender, weight);
    }

    /// @notice Submits a scorecard to be attested to.
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
        // Make sure a proposal hasn't yet been ratified.
        if (ratifiedScorecardIdOf[gameId] != 0) revert DefifaGovernor_AlreadyRatified();

        // Make sure the game has been initialized.
        // slither-disable-next-line incorrect-equality
        if (_packedScorecardInfoOf[gameId] == 0) revert DefifaGovernor_GameNotFound();

        // Keep a reference to the number of tier weights in the proposed scorecard.
        uint256 numberOfTierWeights = tierWeights.length;

        // Get the game's current funding cycle along with its metadata.
        // slither-disable-next-line unused-return
        (, JBRulesetMetadata memory metadata) = CONTROLLER.currentRulesetOf(gameId);

        // Make sure the game is in its scoring phase.
        if (IDefifaHook(metadata.dataHook).gamePhaseReporter().currentGamePhaseOf(gameId) != DefifaGamePhase.SCORING) {
            revert DefifaGovernor_NotAllowed();
        }

        // If there's a weight assigned to the tier, make sure there is a token backed by it.
        // slither-disable-next-line calls-loop
        for (uint256 i; i < numberOfTierWeights;) {
            // A nonzero cashout weight is only valid once that tier has live ownership.
            // slither-disable-next-line calls-loop
            uint256 currentTierSupply = IDefifaHook(metadata.dataHook).currentSupplyOfTier(tierWeights[i].id);
            if (tierWeights[i].cashOutWeight > 0 && currentTierSupply == 0) {
                revert DefifaGovernor_UnownedProposedCashoutValue();
            }
            unchecked {
                ++i;
            }
        }

        // Cache the hook store to avoid repeated external calls.
        IJB721TiersHookStore hookStore = IDefifaHook(metadata.dataHook).store();

        // Run the same structural validation the hook will apply at ratification time so malformed
        // scorecards fail on submission instead of reaching a misleading SUCCEEDED state first.
        // slither-disable-next-line unused-return
        DefifaHookLib.validateAndBuildWeights({tierWeights: tierWeights, hookStore: hookStore, hook: metadata.dataHook});

        // Hash the scorecard.
        scorecardId =
            _hashScorecardOf({gameHook: metadata.dataHook, calldataBytes: _buildScorecardCalldataFor(tierWeights)});

        // Store the scorecard.
        DefifaScorecard storage scorecard = _scorecardOf[gameId][scorecardId];
        if (scorecard.attestationsBegin != 0) revert DefifaGovernor_DuplicateScorecard();

        uint256 attestationStartTime = attestationStartTimeOf(gameId);

        // Game phase timing is timestamp-based by design.
        uint256 currentTimestamp = block.timestamp;
        uint256 timeUntilAttestationsBegin =
            currentTimestamp > attestationStartTime ? 0 : attestationStartTime - currentTimestamp;

        // Casting to uint48 is safe because block.timestamp fits in uint48 until year 8921556.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint48 attestationsBegin = uint48(currentTimestamp + timeUntilAttestationsBegin);
        scorecard.attestationsBegin = attestationsBegin;
        // Grace period extends from when attestations begin, not from submission time.
        // This prevents the grace period from expiring before attestations even start
        // when a scorecard is submitted early.
        uint256 gracePeriodEnds = uint256(attestationsBegin) + attestationGracePeriodOf(gameId);
        if (gracePeriodEnds > type(uint48).max) revert DefifaGovernor_Uint48Overflow();
        // Safe after the explicit max check above.
        // forge-lint: disable-next-line(unsafe-typecast)
        scorecard.gracePeriodEnds = uint48(gracePeriodEnds);

        // Store tier weights for BWA computation.
        for (uint256 i; i < numberOfTierWeights;) {
            _scorecardTierWeightsOf[gameId][scorecardId][tierWeights[i].id - 1] = tierWeights[i].cashOutWeight;
            unchecked {
                ++i;
            }
        }

        // Snapshot each tier's pending reserves and minted attestation units at submission time.
        // BWA later reads an account checkpoint at `attestationsBegin - 1`. If reserve mints happen
        // after submission but before that checkpoint, clamp the live total back down to the minted
        // units that existed at submission and only then add the snapshotted pending reserves.
        {
            // Cache the number of tiers to avoid re-reading from storage.
            uint256 numberOfTiers = hookStore.maxTierIdOf(metadata.dataHook);
            // slither-disable-next-line calls-loop
            for (uint256 i; i < numberOfTiers;) {
                uint256 tierId = i + 1;
                // slither-disable-next-line calls-loop
                JB721Tier memory tier =
                    hookStore.tierOf({hook: metadata.dataHook, id: tierId, includeResolvedUri: false});
                // Use adjusted pending reserves that account for refund-phase burns.
                // slither-disable-next-line calls-loop
                uint256 pendingReserves = IDefifaHook(metadata.dataHook).adjustedPendingReservesFor(tierId);
                // slither-disable-next-line calls-loop
                uint256 submittedTierAttestationUnits =
                    IDefifaHook(metadata.dataHook).currentSupplyOfTier(tierId) * tier.votingUnits;
                _pendingReservesSnapshotOf[gameId][scorecardId][tierId] = pendingReserves;
                _submittedTierAttestationUnitsOf[gameId][scorecardId][tierId] = submittedTierAttestationUnits;
                unchecked {
                    ++i;
                }
            }
        }

        // Concentration-adjusted quorum: penalty = headroom * maxShare².
        // Headroom = max achievable BWA - base quorum = (N-2) * MAX / 2.
        // This is the gap honest attestors can fill above base quorum.
        // maxShare² is nonlinear: gentle for moderate concentration, steep for extreme.
        // The penalty can never exceed headroom, so quorum is always reachable by non-beneficiaries.
        uint256 baseQuorum = quorum(gameId);
        uint256 adjustedQuorum = baseQuorum;

        if (baseQuorum >= MAX_ATTESTATION_POWER_TIER) {
            // headroom = maxBWA - baseQuorum = (N-1)*MAX - N*MAX/2 = (N-2)*MAX/2.
            uint256 headroom = baseQuorum - MAX_ATTESTATION_POWER_TIER;
            // Subtract numberOfTierWeights to account for per-tier mulDiv truncation in BWA.
            if (headroom > numberOfTierWeights) headroom -= numberOfTierWeights;

            // Find the largest tier weight.
            uint256 totalCashOutWeight = IDefifaHook(metadata.dataHook).TOTAL_CASHOUT_WEIGHT();
            uint256 maxWeight;
            for (uint256 i; i < numberOfTierWeights;) {
                if (tierWeights[i].cashOutWeight > maxWeight) maxWeight = tierWeights[i].cashOutWeight;
                unchecked {
                    ++i;
                }
            }

            // maxShare² in totalCashOutWeight scale (nonlinear: gentle for moderate, steep for extreme).
            uint256 maxShareSquared = mulDiv(maxWeight, maxWeight, totalCashOutWeight);

            // Penalty fills headroom proportional to concentration².
            adjustedQuorum += mulDiv(headroom, maxShareSquared, totalCashOutWeight);
        }

        scorecard.quorumSnapshot = adjustedQuorum;

        // Keep a reference to the default attestation delegate.
        address defaultAttestationDelegate = IDefifaHook(metadata.dataHook).defaultAttestationDelegate();

        // If the scorecard is being sent from the default attestation delegate, store it.
        if (msg.sender == defaultAttestationDelegate) {
            defaultAttestationDelegateProposalOf[gameId] = scorecardId;
        }

        emit ScorecardSubmitted(gameId, scorecardId, tierWeights, msg.sender == defaultAttestationDelegate, msg.sender);
    }

    //*********************************************************************//
    // ----------------------- external views ---------------------------- //
    //*********************************************************************//

    /// @notice The number of attestations the given scorecard has.
    /// @param gameId The ID of the game to which the scorecard belongs.
    /// @param scorecardId The ID of the scorecard to get attestations of.
    /// @return The number of attestations the given scorecard has.
    function attestationCountOf(uint256 gameId, uint256 scorecardId) external view returns (uint256) {
        return _scorecardAttestationsOf[gameId][scorecardId].count;
    }

    /// @notice A flag indicating if the given account has already attested to the scorecard.
    /// @param gameId The ID of the game to which the scorecard belongs.
    /// @param scorecardId The ID of the scorecard to query attestations from.
    /// @param account The address to check the attestation status of.
    /// @return A flag indicating if the given account has already attested to the scorecard.
    function hasAttestedTo(uint256 gameId, uint256 scorecardId, address account) external view returns (bool) {
        return _scorecardAttestationsOf[gameId][scorecardId].attestedWeightOf[account] != 0;
    }

    /// @notice The ID of a scorecard representing the provided tier weights.
    /// @param gameHook The address where the game is being played.
    /// @param tierWeights The weights of each tier in the scorecard.
    function scorecardIdOf(
        address gameHook,
        DefifaTierCashOutWeight[] calldata tierWeights
    )
        external
        pure
        virtual
        override
        returns (uint256)
    {
        return _hashScorecardOf({gameHook: gameHook, calldataBytes: _buildScorecardCalldataFor(tierWeights)});
    }

    //*********************************************************************//
    // ----------------------- public transactions ----------------------- //
    //*********************************************************************//

    /// @notice Initializes a game.
    /// @param gameId The ID of the game.
    /// @param attestationStartTime The amount of time between a scorecard being submitted and attestations to it being
    /// enabled, measured in seconds.
    /// @param attestationGracePeriod The amount of time that must go by before a scorecard can be ratified.
    /// @param timelockDuration The cooling period after quorum is met before a scorecard can be ratified.
    function initializeGame(
        uint256 gameId,
        uint256 attestationStartTime,
        uint256 attestationGracePeriod,
        uint256 timelockDuration
    )
        public
        virtual
        override
        onlyOwner
    {
        // Make sure the game hasn't already been initialized.
        if (_packedScorecardInfoOf[gameId] != 0) revert DefifaGovernor_AlreadyInitialized();

        // Set a default attestation start time if needed.
        if (attestationStartTime == 0) attestationStartTime = block.timestamp;

        // Enforce a minimum grace period to prevent instant ratification.
        if (attestationGracePeriod < MIN_ATTESTATION_GRACE_PERIOD) revert DefifaGovernor_GracePeriodTooShort();

        // Ensure values fit within their allocated 48-bit widths before packing.
        if (attestationStartTime > type(uint48).max) revert DefifaGovernor_Uint48Overflow();
        if (attestationGracePeriod > type(uint48).max) revert DefifaGovernor_Uint48Overflow();
        if (timelockDuration > type(uint48).max) revert DefifaGovernor_Uint48Overflow();

        // Pack the values.
        uint256 packed;
        // attestation start time in bits 0-47 (48 bits).
        packed |= attestationStartTime;
        // attestation grace period in bits 48-95 (48 bits).
        packed |= attestationGracePeriod << 48;
        // timelock duration in bits 96-143 (48 bits).
        packed |= timelockDuration << 96;

        // Store the packed value.
        _packedScorecardInfoOf[gameId] = packed;

        emit GameInitialized(gameId, attestationStartTime, attestationGracePeriod, timelockDuration, msg.sender);
    }

    //*********************************************************************//
    // -------------------------- public views --------------------------- //
    //*********************************************************************//

    /// @notice The amount of time that must go by before a scorecard can be ratified.
    /// @param gameId The ID of the game to get the attestation period of.
    /// @return The attestation period in number of blocks.
    function attestationGracePeriodOf(uint256 gameId) public view override returns (uint256) {
        // attestation grace period in bits 48-95 (48 bits).
        return uint256(uint48(_packedScorecardInfoOf[gameId] >> 48));
    }

    /// @notice The amount of time between a scorecard being submitted and attestations to it being enabled, measured in
    /// seconds.
    /// @dev This can be increased to leave time for users to acquire attestation power, or delegate it, before
    /// a scorecard becomes live.
    /// @param gameId The ID of the game to get the attestation delay of.
    /// @return The delay, in seconds.
    function attestationStartTimeOf(uint256 gameId) public view override returns (uint256) {
        // attestation start time in bits 0-47 (48 bits).
        return uint256(uint48(_packedScorecardInfoOf[gameId]));
    }

    /// @notice Gets an account's attestation power given a number of tiers to look through.
    /// @dev An account's power per tier = MAX_ATTESTATION_POWER_TIER * (account's units / tier's total units).
    /// This means within a tier, power is proportional to token holdings, but across tiers, each tier's
    /// total power is capped at MAX_ATTESTATION_POWER_TIER. A holder of 1-of-1 in a tier gets
    /// MAX_ATTESTATION_POWER_TIER; a holder of 1-of-100 gets MAX_ATTESTATION_POWER_TIER / 100.
    /// This ensures each game outcome (tier) has equal governance weight — the scorecard reflects
    /// consensus across outcomes, not dominance by whichever outcome sold the most tokens.
    /// @param gameId The ID of the game for which attestations are being counted.
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
        returns (uint256 attestationPower)
    {
        // Get the game's current funding cycle along with its metadata.
        // slither-disable-next-line unused-return
        (, JBRulesetMetadata memory metadata) = CONTROLLER.currentRulesetOf(gameId);

        // Get a reference to the hook and its store.
        IDefifaHook hook = IDefifaHook(metadata.dataHook);
        IJB721TiersHookStore store = hook.store();

        // Get a reference to the number of tiers.
        uint256 numberOfTiers = store.maxTierIdOf(metadata.dataHook);

        for (uint256 i; i < numberOfTiers;) {
            // Tiers are 1-indexed.
            uint256 tierId = i + 1;

            // Get this account's attestation units within the tier (snapshot at timestamp).
            // slither-disable-next-line calls-loop
            uint256 tierAttestationUnitsForAccount =
                hook.getPastTierAttestationUnitsOf({account: account, tier: tierId, timestamp: timestamp});

            // Get the total attestation units for this tier (snapshot at timestamp).
            // slither-disable-next-line calls-loop
            uint256 tierTotalAttestationUnits =
                hook.getPastTierTotalAttestationUnitsOf({tier: tierId, timestamp: timestamp});

            // Include unminted pending reserves in the total (denominator only). This ensures every
            // token holder's voting power already accounts for reserves that will eventually be minted.
            // When the reserve beneficiary later mints, their new NFTs add to the numerator while
            // pending reserves decrease by the same amount — so no one's voting power shifts.
            {
                // Use adjusted pending reserves that account for refund-phase burns.
                // slither-disable-next-line calls-loop
                uint256 pendingReserves = IDefifaHook(metadata.dataHook).adjustedPendingReservesFor(tierId);
                if (pendingReserves != 0) {
                    // slither-disable-next-line calls-loop
                    JB721Tier memory tier =
                        store.tierOf({hook: metadata.dataHook, id: tierId, includeResolvedUri: false});
                    tierTotalAttestationUnits += pendingReserves * tier.votingUnits;
                }
            }

            // Scale the account's share of the tier to MAX_ATTESTATION_POWER_TIER.
            // e.g. holding 3 of 10 tokens -> 3/10 * MAX_ATTESTATION_POWER_TIER attestation power from this tier.
            unchecked {
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
    /// while a tier with 0% weight retains full power. This prevents beneficiaries from self-attesting.
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
        // Get the game's current funding cycle along with its metadata.
        // slither-disable-next-line unused-return
        (, JBRulesetMetadata memory metadata) = CONTROLLER.currentRulesetOf(gameId);

        // Get a reference to the hook and its store.
        IDefifaHook hook = IDefifaHook(metadata.dataHook);
        IJB721TiersHookStore store = hook.store();

        // Get a reference to the number of tiers.
        uint256 numberOfTiers = store.maxTierIdOf(metadata.dataHook);

        // Cache the total cashout weight denominator from the hook.
        uint256 totalCashOutWeight = hook.TOTAL_CASHOUT_WEIGHT();

        for (uint256 i; i < numberOfTiers;) {
            // Tiers are 1-indexed.
            uint256 tierId = i + 1;

            // Get this account's attestation units within the tier (snapshot at timestamp).
            // slither-disable-next-line calls-loop
            uint256 tierAttestationUnitsForAccount =
                hook.getPastTierAttestationUnitsOf({account: account, tier: tierId, timestamp: timestamp});

            if (tierAttestationUnitsForAccount != 0) {
                // Start from the checkpointed tier total at the requested timestamp.
                // If reserve mints happened after submission, clamp them out before adding the
                // pending-reserve snapshot back in so each reserve unit is counted exactly once.
                // slither-disable-next-line calls-loop
                uint256 tierTotalAttestationUnits =
                    hook.getPastTierTotalAttestationUnitsOf({tier: tierId, timestamp: timestamp});
                uint256 submittedTierAttestationUnits = _submittedTierAttestationUnitsOf[gameId][scorecardId][tierId];
                // Clamp the total to the submitted snapshot to exclude post-submission reserve mints.
                if (tierTotalAttestationUnits > submittedTierAttestationUnits) {
                    tierTotalAttestationUnits = submittedTierAttestationUnits;
                }

                // Add back the snapshotted pending reserves.
                uint256 pendingReserves = _pendingReservesSnapshotOf[gameId][scorecardId][tierId];
                if (pendingReserves != 0) {
                    // slither-disable-next-line calls-loop
                    JB721Tier memory tier =
                        store.tierOf({hook: metadata.dataHook, id: tierId, includeResolvedUri: false});
                    tierTotalAttestationUnits += pendingReserves * tier.votingUnits;
                }

                // Raw power for this tier.
                uint256 rawPower = mulDiv({
                    x: MAX_ATTESTATION_POWER_TIER,
                    y: tierAttestationUnitsForAccount,
                    denominator: tierTotalAttestationUnits
                });

                // BWA reduction: power * (1 - tierWeight / totalCashOutWeight).
                uint256 tierWeight = _scorecardTierWeightsOf[gameId][scorecardId][i];
                uint256 bwaMultiplier = totalCashOutWeight - tierWeight;

                bwaAttestationPower += mulDiv({x: rawPower, y: bwaMultiplier, denominator: totalCashOutWeight});
            }

            unchecked {
                ++i;
            }
        }
    }

    /// @notice The number of attestation units that must have participated in a proposal for it to be ratified.
    /// @dev Each tier with participation contributes MAX_ATTESTATION_POWER_TIER to the total eligible weight.
    /// A tier counts as "participated" if it has circulating tokens OR unminted pending reserves — the latter
    /// means mints occurred (triggering reserve accrual) even if all paid tokens were later burned during REFUND.
    /// Quorum is 50% of this total. Because every tier has equal max attestation power regardless of supply,
    /// each tier's community has equal influence. This prevents high-supply tiers from dominating governance.
    /// @dev No snapshot needed: during SCORING, supply is frozen (no new paid mints, no burns). Reserve minting
    /// doesn't change which tiers are counted because tiers with pending reserves are already included.
    /// @return The quorum number of attestations.
    function quorum(uint256 gameId) public view override returns (uint256) {
        // Get the game's current funding cycle along with its metadata.
        // slither-disable-next-line unused-return
        (, JBRulesetMetadata memory metadata) = CONTROLLER.currentRulesetOf(gameId);

        // Get a reference to the hook and its store.
        IDefifaHook hook = IDefifaHook(metadata.dataHook);
        IJB721TiersHookStore store = hook.store();

        // Get a reference to the number of tiers.
        uint256 numberOfTiers = store.maxTierIdOf(metadata.dataHook);

        // Keep a reference to the total eligible tier weight.
        uint256 eligibleTierWeights;

        for (uint256 i; i < numberOfTiers;) {
            uint256 tierId = i + 1;

            // A tier contributes to quorum if it has circulating tokens OR unminted pending reserves.
            // Pending reserves still belong economically to the reserve beneficiary, even after the
            // last paid token in the tier is burned during REFUND, so excluding them would let a
            // burner erase another participant's quorum contribution without erasing their claim.
            // slither-disable-next-line calls-loop
            uint256 currentTierSupply = hook.currentSupplyOfTier(tierId);
            // Use adjusted pending reserves that account for refund-phase burns.
            // slither-disable-next-line calls-loop
            uint256 pendingReserves = hook.adjustedPendingReservesFor(tierId);
            if (currentTierSupply != 0 || pendingReserves != 0) {
                eligibleTierWeights += MAX_ATTESTATION_POWER_TIER;
            }

            unchecked {
                ++i;
            }
        }

        // Quorum = 50% of all participated tiers' attestation power.
        return eligibleTierWeights / 2;
    }

    /// @notice The state of a proposal.
    /// @param gameId The ID of the game to get a proposal state of.
    /// @param scorecardId The ID of the proposal to get the state of.
    /// @return The state.
    /// @dev Boundary semantics (inclusive):
    ///   - At exactly `attestationsBegin`, the state transitions from PENDING to ACTIVE (attestations are open).
    ///   - At exactly `gracePeriodEnds`, the grace period has elapsed and the state transitions from ACTIVE to
    ///     QUEUED (if quorum met + timelock > 0) or SUCCEEDED (if quorum met + no timelock).
    function stateOf(uint256 gameId, uint256 scorecardId) public view virtual override returns (DefifaScorecardState) {
        // Keep a reference to the ratified scorecard ID.
        uint256 ratifiedScorecardId = ratifiedScorecardIdOf[gameId];

        // If the game has already ratified a scorecard, return succeeded if the ratified proposal is being checked.
        // Else return defeated.
        if (ratifiedScorecardId != 0) {
            return ratifiedScorecardId == scorecardId ? DefifaScorecardState.RATIFIED : DefifaScorecardState.DEFEATED;
        }

        // Get a reference to the scorecard.
        DefifaScorecard memory scorecard = _scorecardOf[gameId][scorecardId];

        // Make sure the proposal is known.
        // slither-disable-next-line incorrect-equality
        if (scorecard.attestationsBegin == 0) {
            revert DefifaGovernor_UnknownProposal();
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

        // If quorum has been reached (using the concentration-adjusted snapshot), check timelock.
        if (scorecard.quorumSnapshot <= _scorecardAttestationsOf[gameId][scorecardId].count) {
            uint256 timelockDur = timelockDurationOf(gameId);
            if (timelockDur > 0) {
                // Anchor the timelock to the later of grace period end or when quorum was reached.
                uint256 quorumReachedAt = _quorumReachedAtOf[gameId][scorecardId];
                uint256 timelockAnchor =
                    quorumReachedAt > scorecard.gracePeriodEnds ? quorumReachedAt : uint256(scorecard.gracePeriodEnds);
                // Game phase timing is timestamp-based by design.
                // forge-lint: disable-next-line(block-timestamp)
                if (block.timestamp < timelockAnchor + timelockDur) {
                    return DefifaScorecardState.QUEUED;
                }
            }
            return DefifaScorecardState.SUCCEEDED;
        }

        // Scorecards that fail to reach quorum remain ACTIVE indefinitely — there is no DEFEATED
        // state transition for unratified scorecards. This is by design: new scorecards can always be
        // submitted and the game's no-contest timeout (scorecardTimeout) provides the ultimate backstop.
        return DefifaScorecardState.ACTIVE;
    }

    /// @notice The timelock duration for a game (cooling period after quorum + grace period before ratification).
    /// @param gameId The ID of the game.
    /// @return The timelock duration in seconds.
    function timelockDurationOf(uint256 gameId) public view override returns (uint256) {
        // timelock duration in bits 96-143 (48 bits).
        return uint256(uint48(_packedScorecardInfoOf[gameId] >> 96));
    }

    //*********************************************************************//
    // ----------------------- internal helpers -------------------------- //
    //*********************************************************************//

    /// @notice Build the normalized calldata for ratification.
    /// @param tierWeights The weights of each tier in the scorecard data.
    /// @return The calldata to send alongside the transactions.
    function _buildScorecardCalldataFor(DefifaTierCashOutWeight[] calldata tierWeights)
        internal
        pure
        returns (bytes memory)
    {
        // Build the calldata from the tier weights using the hook's selector.
        return abi.encodeWithSelector(DefifaHook.setTierCashOutWeightsTo.selector, (tierWeights));
    }

    /// @notice A value representing the contents of a scorecard.
    /// @param gameHook The address where the game is being played.
    /// @param calldataBytes The calldata that will be sent if the scorecard is ratified.
    function _hashScorecardOf(address gameHook, bytes memory calldataBytes) internal pure virtual returns (uint256) {
        return uint256(keccak256(abi.encode(gameHook, calldataBytes)));
    }
}
