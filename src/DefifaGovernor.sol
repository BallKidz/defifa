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
import {IDefifaHook} from "./interfaces/IDefifaHook.sol";
import {DefifaAttestations} from "./structs/DefifaAttestations.sol";
import {DefifaScorecard} from "./structs/DefifaScorecard.sol";
import {DefifaTierCashOutWeight} from "./structs/DefifaTierCashOutWeight.sol";

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
    error DefifaGovernor_IncorrectTierOrder();
    error DefifaGovernor_NotAllowed();
    error DefifaGovernor_Uint48Overflow();
    error DefifaGovernor_UnknownProposal();
    error DefifaGovernor_UnownedProposedCashoutValue();

    //*********************************************************************//
    // ------------------------- public constants ------------------------ //
    //*********************************************************************//

    /// @notice The max attestation power each tier has if every token within the tier attestations.
    uint256 public constant override MAX_ATTESTATION_POWER_TIER = 1_000_000_000;

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
        (, JBRulesetMetadata memory _metadata) = CONTROLLER.currentRulesetOf(gameId);

        // Make sure the game is in its scoring phase.
        if (IDefifaHook(_metadata.dataHook).gamePhaseReporter().currentGamePhaseOf(gameId) != DefifaGamePhase.SCORING) {
            revert DefifaGovernor_NotAllowed();
        }

        // Keep a reference to the scorecard being attested to.
        DefifaScorecard storage _scorecard = _scorecardOf[gameId][scorecardId];

        // Keep a reference to the scorecard state.
        DefifaScorecardState _state = stateOf({gameId: gameId, scorecardId: scorecardId});

        if (_state != DefifaScorecardState.ACTIVE && _state != DefifaScorecardState.SUCCEEDED) {
            revert DefifaGovernor_NotAllowed();
        }

        // Keep a reference to the attestations for the scorecard.
        DefifaAttestations storage _attestations = _scorecardAttestationsOf[gameId][scorecardId];

        // Make sure the account isn't attesting to the same scorecard again.
        if (_attestations.hasAttested[msg.sender]) revert DefifaGovernor_AlreadyAttested();

        // Get a reference to the attestation weight, snapshotted at `attestationsBegin`.
        // Using `attestationsBegin` is intentional — it is always a past timestamp set during `submitScorecardFor`,
        // so same-block transfer manipulation cannot inflate attestation power. A fixed snapshot also ensures every
        // attestor's weight is measured at the same point in time, which is fairer for gameplay.
        weight = getAttestationWeight({gameId: gameId, account: msg.sender, timestamp: _scorecard.attestationsBegin});

        // Increase the attestation count.
        _attestations.count += weight;

        // Store the fact that the account has attested to the scorecard.
        _attestations.hasAttested[msg.sender] = true;

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
        (, JBRulesetMetadata memory _metadata) = CONTROLLER.currentRulesetOf(gameId);

        // Build the calldata to the target
        bytes memory _calldata = _buildScorecardCalldataFor(tierWeights);

        // Attempt to execute the proposal.
        scorecardId = _hashScorecardOf({gameHook: _metadata.dataHook, calldataBytes: _calldata});

        // Make sure the proposal being ratified has succeeded.
        if (stateOf({gameId: gameId, scorecardId: scorecardId}) != DefifaScorecardState.SUCCEEDED) {
            revert DefifaGovernor_NotAllowed();
        }

        // Set the ratified scorecard.
        ratifiedScorecardIdOf[gameId] = scorecardId;

        // Execute the scorecard via low-level call since the governor is the delegate's owner.
        (bool success, bytes memory returndata) = _metadata.dataHook.call(_calldata);
        // slither-disable-next-line unused-return
        Address.verifyCallResult({success: success, returndata: returndata});

        // Fulfill any commitments for the game. The internal try-catch in fulfillCommitmentsOf
        // handles sendPayoutsOf failures, ensuring the final ruleset is always queued.
        IDefifaDeployer(CONTROLLER.PROJECTS().ownerOf(gameId)).fulfillCommitmentsOf(gameId);

        // slither-disable-next-line reentrancy-events
        emit ScorecardRatified(gameId, scorecardId, msg.sender);
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

        // Make sure no weight is assigned to an unowned tier.
        uint256 _numberOfTierWeights = tierWeights.length;

        // Get the game's current funding cycle along with its metadata.
        // slither-disable-next-line unused-return
        (, JBRulesetMetadata memory _metadata) = CONTROLLER.currentRulesetOf(gameId);

        // Make sure the game is in its scoring phase.
        if (IDefifaHook(_metadata.dataHook).gamePhaseReporter().currentGamePhaseOf(gameId) != DefifaGamePhase.SCORING) {
            revert DefifaGovernor_NotAllowed();
        }

        // If there's a weight assigned to the tier, make sure there is a token backed by it.
        for (uint256 _i; _i < _numberOfTierWeights; _i++) {
            if (
                tierWeights[_i].cashOutWeight > 0
                    && IDefifaHook(_metadata.dataHook).currentSupplyOfTier(tierWeights[_i].id) == 0
            ) {
                revert DefifaGovernor_UnownedProposedCashoutValue();
            }
        }

        // Hash the scorecard.
        scorecardId =
            _hashScorecardOf({gameHook: _metadata.dataHook, calldataBytes: _buildScorecardCalldataFor(tierWeights)});

        // Store the scorecard
        DefifaScorecard storage _scorecard = _scorecardOf[gameId][scorecardId];
        if (_scorecard.attestationsBegin != 0) revert DefifaGovernor_DuplicateScorecard();

        uint256 _attestationStartTime = attestationStartTimeOf(gameId);
        uint256 _timeUntilAttestationsBegin =
            block.timestamp > _attestationStartTime ? 0 : _attestationStartTime - block.timestamp;

        // Casting to uint48 is safe because block.timestamp fits in uint48 until year 8921556.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint48 _attestationsBegin = uint48(block.timestamp + _timeUntilAttestationsBegin);
        _scorecard.attestationsBegin = _attestationsBegin;
        // Grace period extends from when attestations begin, not from submission time.
        // This prevents the grace period from expiring before attestations even start
        // when a scorecard is submitted early.
        _scorecard.gracePeriodEnds = uint48(_attestationsBegin + attestationGracePeriodOf(gameId));

        // Keep a reference to the default attestation delegate.
        address _defaultAttestationDelegate = IDefifaHook(_metadata.dataHook).defaultAttestationDelegate();

        // If the scorecard is being sent from the default attestation delegate, store it.
        if (msg.sender == _defaultAttestationDelegate) {
            defaultAttestationDelegateProposalOf[gameId] = scorecardId;
        }

        emit ScorecardSubmitted(gameId, scorecardId, tierWeights, msg.sender == _defaultAttestationDelegate, msg.sender);
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
        return _scorecardAttestationsOf[gameId][scorecardId].hasAttested[account];
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
    function initializeGame(
        uint256 gameId,
        uint256 attestationStartTime,
        uint256 attestationGracePeriod
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

        // Enforce a minimum grace period of 1 day to prevent instant ratification.
        if (attestationGracePeriod < 1 days) attestationGracePeriod = 1 days;

        // Ensure values fit within their allocated 48-bit widths before packing.
        if (attestationStartTime > type(uint48).max) revert DefifaGovernor_Uint48Overflow();
        if (attestationGracePeriod > type(uint48).max) revert DefifaGovernor_Uint48Overflow();

        // Pack the values.
        uint256 _packed;
        // attestation start time in bits 0-47 (48 bits).
        _packed |= attestationStartTime;
        // attestation grace period in bits 48-95 (48 bits).
        _packed |= attestationGracePeriod << 48;

        // Store the packed value.
        _packedScorecardInfoOf[gameId] = _packed;

        emit GameInitialized(gameId, attestationStartTime, attestationGracePeriod, msg.sender);
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
        (, JBRulesetMetadata memory _metadata) = CONTROLLER.currentRulesetOf(gameId);

        // Get a reference to the number of tiers.
        uint256 _numberOfTiers = IDefifaHook(_metadata.dataHook).store().maxTierIdOf(_metadata.dataHook);

        // slither-disable-next-line calls-inside-a-loop
        for (uint256 _i; _i < _numberOfTiers; _i++) {
            // Tiers are 1-indexed.
            uint256 _tierId = _i + 1;

            // Get this account's attestation units within the tier (snapshot at timestamp).
            uint256 _tierAttestationUnitsForAccount = IDefifaHook(_metadata.dataHook)
                .getPastTierAttestationUnitsOf({account: account, tier: _tierId, timestamp: timestamp});

            // Scale the account's share of the tier to MAX_ATTESTATION_POWER_TIER.
            // e.g. holding 3 of 10 tokens → 3/10 * MAX_ATTESTATION_POWER_TIER attestation power from this tier.
            unchecked {
                if (_tierAttestationUnitsForAccount != 0) {
                    attestationPower += mulDiv({
                        x: MAX_ATTESTATION_POWER_TIER,
                        y: _tierAttestationUnitsForAccount,
                        denominator: IDefifaHook(_metadata.dataHook)
                            .getPastTierTotalAttestationUnitsOf({tier: _tierId, timestamp: timestamp})
                    });
                }
            }
        }
    }

    /// @notice The number of attestation units that must have participated in a proposal for it to be ratified.
    /// @dev Each tier with at least one minted token contributes MAX_ATTESTATION_POWER_TIER to the total
    /// eligible weight. Quorum is 50% of this total. Because every tier has equal max attestation power
    /// regardless of supply, each tier's community has equal influence — a tier with 1 token and a tier
    /// with 100 tokens both cap at MAX_ATTESTATION_POWER_TIER when fully attested. This prevents
    /// high-supply tiers from dominating governance, keeping the game fair across all outcomes.
    /// @dev Note: quorum is computed from the live supply (currentSupplyOfTier) rather than a snapshot. This means
    /// the quorum threshold can shift between when a scorecard is submitted and when it is evaluated, e.g. if
    /// tokens are burned after attestation. In practice this is acceptable because attestation weights are
    /// snapshotted and quorum only increases (new mints) or decreases (burns) — the latter makes ratification
    /// easier, not harder.
    /// @return The quorum number of attestations.
    function quorum(uint256 gameId) public view override returns (uint256) {
        // Get the game's current funding cycle along with its metadata.
        // slither-disable-next-line unused-return
        (, JBRulesetMetadata memory _metadata) = CONTROLLER.currentRulesetOf(gameId);

        // Get a reference to the number of tiers.
        uint256 _numberOfTiers = IDefifaHook(_metadata.dataHook).store().maxTierIdOf(_metadata.dataHook);

        // Keep a reference to the total eligible tier weight.
        uint256 _eligibleTierWeights;

        // slither-disable-next-line calls-inside-a-loop
        for (uint256 _i; _i < _numberOfTiers; _i++) {
            // Each minted tier contributes MAX_ATTESTATION_POWER_TIER to the quorum denominator.
            if (IDefifaHook(_metadata.dataHook).currentSupplyOfTier(_i + 1) != 0) {
                _eligibleTierWeights += MAX_ATTESTATION_POWER_TIER;
            }
        }

        // Quorum = 50% of all minted tiers' attestation power.
        return _eligibleTierWeights / 2;
    }

    /// @notice The state of a proposal.
    /// @param gameId The ID of the game to get a proposal state of.
    /// @param scorecardId The ID of the proposal to get the state of.
    /// @return The state.
    /// @dev Boundary semantics (inclusive):
    ///   - At exactly `attestationsBegin`, the state transitions from PENDING to ACTIVE (attestations are open).
    ///   - At exactly `gracePeriodEnds`, the grace period has elapsed and the state transitions from ACTIVE to
    ///     SUCCEEDED (if quorum is met) or remains ACTIVE (if not).
    function stateOf(uint256 gameId, uint256 scorecardId) public view virtual override returns (DefifaScorecardState) {
        // Keep a reference to the ratified scorecard ID.
        uint256 _ratifiedScorecardId = ratifiedScorecardIdOf[gameId];

        // If the game has already ratified a scorecard, return succeeded if the ratified proposal is being checked.
        // Else return defeated.
        if (_ratifiedScorecardId != 0) {
            return _ratifiedScorecardId == scorecardId ? DefifaScorecardState.RATIFIED : DefifaScorecardState.DEFEATED;
        }

        // Get a reference to the scorecard.
        DefifaScorecard memory _scorecard = _scorecardOf[gameId][scorecardId];

        // Make sure the proposal is known.
        // slither-disable-next-line incorrect-equality
        if (_scorecard.attestationsBegin == 0) {
            revert DefifaGovernor_UnknownProposal();
        }

        // If the scorecard has attestations beginning in the future, the state is PENDING.
        // At exactly `attestationsBegin`, attestations are open so the state is ACTIVE.
        if (_scorecard.attestationsBegin > block.timestamp) {
            return DefifaScorecardState.PENDING;
        }

        // If the scorecard's grace period has not yet ended, the state is ACTIVE.
        // At exactly `gracePeriodEnds`, the grace period has elapsed so we fall through to the quorum check.
        if (_scorecard.gracePeriodEnds > block.timestamp) {
            return DefifaScorecardState.ACTIVE;
        }

        // If quorum has been reached, the state is SUCCEEDED, otherwise it is ACTIVE.
        // Note: scorecards that fail to reach quorum remain ACTIVE indefinitely — there is no DEFEATED
        // state transition for unratified scorecards. This is by design: new scorecards can always be
        // submitted and the game's no-contest timeout (scorecardTimeout) provides the ultimate backstop.
        return quorum(gameId) <= _scorecardAttestationsOf[gameId][scorecardId].count
            ? DefifaScorecardState.SUCCEEDED
            : DefifaScorecardState.ACTIVE;
    }

    //*********************************************************************//
    // ----------------------- internal helpers -------------------------- //
    //*********************************************************************//

    /// @notice Build the normalized calldata.
    /// @param tierWeights The weights of each tier in the scorecard data.
    /// @return The calldata to send alongside the transactions.
    function _buildScorecardCalldataFor(DefifaTierCashOutWeight[] calldata tierWeights)
        internal
        pure
        returns (bytes memory)
    {
        // Build the calldata from the tier weights.
        return abi.encodeWithSelector(DefifaHook.setTierCashOutWeightsTo.selector, (tierWeights));
    }

    /// @notice A value representing the contents of a scorecard.
    /// @param gameHook The address where the game is being played.
    /// @param calldataBytes The calldata that will be sent if the scorecard is ratified.
    function _hashScorecardOf(address gameHook, bytes memory calldataBytes) internal pure virtual returns (uint256) {
        return uint256(keccak256(abi.encode(gameHook, calldataBytes)));
    }
}
