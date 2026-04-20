// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJB721TokenUriResolver} from "@bananapus/721-hook-v6/src/interfaces/IJB721TokenUriResolver.sol";
import {
    JB721TiersRulesetMetadata,
    JB721TiersRulesetMetadataResolver
} from "@bananapus/721-hook-v6/src/libraries/JB721TiersRulesetMetadataResolver.sol";
import {JB721TierConfig} from "@bananapus/721-hook-v6/src/structs/JB721TierConfig.sol";
import {JB721TierConfigFlags} from "@bananapus/721-hook-v6/src/structs/JB721TierConfigFlags.sol";
import {IJBAddressRegistry} from "@bananapus/address-registry-v6/src/interfaces/IJBAddressRegistry.sol";
import {IJBController, JBRulesetConfig, JBTerminalConfig} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBMultiTerminal} from "@bananapus/core-v6/src/interfaces/IJBMultiTerminal.sol";
import {IJBRulesetApprovalHook, JBRuleset} from "@bananapus/core-v6/src/interfaces/IJBRulesets.sol";
import {IJBSplitHook} from "@bananapus/core-v6/src/interfaces/IJBSplitHook.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBCurrencyAmount} from "@bananapus/core-v6/src/structs/JBCurrencyAmount.sol";
import {JBFundAccessLimitGroup} from "@bananapus/core-v6/src/structs/JBFundAccessLimitGroup.sol";
import {JBRulesetMetadata} from "@bananapus/core-v6/src/structs/JBRulesetMetadata.sol";
import {JBSplit} from "@bananapus/core-v6/src/structs/JBSplit.sol";
import {JBSplitGroup} from "@bananapus/core-v6/src/structs/JBSplitGroup.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {mulDiv} from "@prb/math/src/Common.sol";

import {DefifaHook} from "./DefifaHook.sol";
import {DefifaGamePhase} from "./enums/DefifaGamePhase.sol";
import {IDefifaDeployer} from "./interfaces/IDefifaDeployer.sol";
import {IDefifaGamePhaseReporter} from "./interfaces/IDefifaGamePhaseReporter.sol";
import {IDefifaGamePotReporter} from "./interfaces/IDefifaGamePotReporter.sol";
import {IDefifaGovernor} from "./interfaces/IDefifaGovernor.sol";
import {IDefifaHook} from "./interfaces/IDefifaHook.sol";
import {DefifaLaunchProjectData} from "./structs/DefifaLaunchProjectData.sol";
import {DefifaOpsData} from "./structs/DefifaOpsData.sol";
import {DefifaTierParams} from "./structs/DefifaTierParams.sol";

/// @notice Deploys and manages Defifa games.
contract DefifaDeployer is IDefifaDeployer, IDefifaGamePhaseReporter, IDefifaGamePotReporter, IERC721Receiver {
    using Strings for uint256;
    using SafeERC20 for IERC20;

    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    error DefifaDeployer_CantFulfillYet();
    error DefifaDeployer_GameOver();
    error DefifaDeployer_InvalidFeePercent();
    error DefifaDeployer_InvalidGameConfiguration();
    error DefifaDeployer_IncorrectDecimalAmount();
    error DefifaDeployer_NotNoContest();
    error DefifaDeployer_NoContestAlreadyTriggered();
    error DefifaDeployer_TerminalNotFound();
    error DefifaDeployer_PhaseAlreadyQueued();
    error DefifaDeployer_SplitsDontAddUp();
    error DefifaDeployer_UnexpectedTerminalCurrency();

    //*********************************************************************//
    // ----------------------- internal properties ----------------------- //
    //*********************************************************************//

    /// @notice The game's ops.
    mapping(uint256 => DefifaOpsData) internal _opsOf;

    /// @notice This contract current nonce, used for the registry initialized at 1 since the first contract deployed is
    /// the hook
    uint256 internal _nonce;

    //*********************************************************************//
    // ------------------ public immutable properties -------------------- //
    //*********************************************************************//

    /// @notice The group relative to which splits are stored.
    /// @dev This could be any fixed number.
    uint256 public immutable override SPLIT_GROUP;

    /// @notice The project ID that'll receive game fees, and relative to which splits are stored.
    /// @dev The owner of this project ID must give this contract operator permissions over the SET_SPLITS operation.
    uint256 public immutable override DEFIFA_PROJECT_ID;

    /// @notice The project ID that'll receive protocol fees as commitments are fulfilled.
    uint256 public immutable override BASE_PROTOCOL_PROJECT_ID;

    /// @notice The original code for the Defifa hook to base subsequent instances on.
    address public immutable override HOOK_CODE_ORIGIN;

    /// @notice The default Defifa token URI resolver.
    IJB721TokenUriResolver public immutable override TOKEN_URI_RESOLVER;

    /// @notice The Defifa governor.
    IDefifaGovernor public immutable override GOVERNOR;

    /// @notice The controller with which new projects should be deployed.
    IJBController public immutable override CONTROLLER;

    /// @notice The hooks registry.
    IJBAddressRegistry public immutable REGISTRY;

    /// @notice The divisor that describes the protocol fee that should be taken.
    /// @dev This is equal to 100 divided by the fee percent (e.g. 40 = 2.5% fee).
    uint256 public constant override BASE_PROTOCOL_FEE_DIVISOR = 40;

    /// @notice The divisor that describes the Defifa fee that should be taken.
    /// @dev This is equal to 100 divided by the fee percent (e.g. 20 = 5% fee).
    uint256 public constant override DEFIFA_FEE_DIVISOR = 20;

    //*********************************************************************//
    // --------------------- public stored properties -------------------- //
    //*********************************************************************//

    /// @notice The amount of commitments a game has fulfilled.
    /// @dev The ID of the game to check.
    mapping(uint256 => uint256) public override fulfilledCommitmentsOf;

    /// @notice The total absolute split percent for each game (out of SPLITS_TOTAL_PERCENT).
    mapping(uint256 => uint256) internal _commitmentPercentOf;

    /// @notice Whether the no-contest refund ruleset has been triggered for a game.
    /// @dev Once triggered, the game stays in NO_CONTEST and refunds are enabled.
    mapping(uint256 => bool) public noContestTriggeredFor;

    //*********************************************************************//
    // ------------------------- external views -------------------------- //
    //*********************************************************************//

    /// @notice The current pot the game is being played with.
    /// @param gameId The ID of the game for which the pot applies.
    /// @param includeCommitments A flag indicating if the portion of the pot committed to fulfill preprogrammed
    /// obligations should be included.
    /// @return The game's pot amount, as a fixed point number.
    /// @return The token address the game's pot is measured in.
    /// @return The number of decimals included in the amount.
    function currentGamePotOf(
        uint256 gameId,
        bool includeCommitments
    )
        external
        view
        returns (uint256, address, uint256)
    {
        // Get a reference to the token being used by the project.
        address token = _opsOf[gameId].token;

        // Get a reference to the terminal via the directory.
        IJBTerminal terminal = CONTROLLER.DIRECTORY().primaryTerminalOf({projectId: gameId, token: token});

        // Get the accounting context for the project.
        JBAccountingContext memory context = terminal.accountingContextForTokenOf({projectId: gameId, token: token});

        // Get the current balance from the terminal's store.
        uint256 pot = IJBMultiTerminal(address(terminal)).STORE()
            .balanceOf({terminal: address(terminal), projectId: gameId, token: token});

        // Add any fulfilled commitments.
        if (includeCommitments) pot += fulfilledCommitmentsOf[gameId];

        return (pot, token, context.decimals);
    }

    /// @notice Whether or not the next phase still needs queuing.
    /// @param gameId The ID of the game to get the queue status of.
    /// @return Whether or not the next phase still needs queuing.
    function nextPhaseNeedsQueueing(uint256 gameId) external view override returns (bool) {
        // Get the game's current funding cycle along with its metadata.
        JBRuleset memory currentRuleset = CONTROLLER.RULESETS().currentOf(gameId);
        // Get the game's queued funding cycle along with its metadata.
        // slither-disable-next-line unused-return
        (JBRuleset memory queuedRuleset,) = CONTROLLER.RULESETS().latestQueuedOf(gameId);

        // If the configurations are the same and the game hasn't ended, queueing is still needed.
        return currentRuleset.duration != 0 && currentRuleset.id == queuedRuleset.id;
    }

    /// @notice The safety mechanism parameters of a game.
    /// @param gameId The ID of the game to get the safety params of.
    /// @return minParticipation The minimum treasury balance for the game to proceed to scoring.
    /// @return scorecardTimeout The maximum time after scoring begins for a scorecard to be ratified.
    function safetyParamsOf(uint256 gameId)
        external
        view
        override
        returns (uint256 minParticipation, uint32 scorecardTimeout)
    {
        DefifaOpsData memory ops = _opsOf[gameId];
        return (ops.minParticipation, ops.scorecardTimeout);
    }

    /// @notice The game times.
    /// @param gameId The ID of the game for which the game times apply.
    /// @return The game's start time, as a unix timestamp.
    /// @return The game's minting period duration, in seconds.
    /// @return The game's refund period duration, in seconds.
    function timesFor(uint256 gameId) external view override returns (uint48, uint24, uint24) {
        DefifaOpsData memory ops = _opsOf[gameId];
        return (ops.start, ops.mintPeriodDuration, ops.refundPeriodDuration);
    }

    /// @notice The token of a game.
    /// @param gameId The ID of the game to get the token of.
    /// @return The game's token.
    function tokenOf(uint256 gameId) external view override returns (address) {
        return _opsOf[gameId].token;
    }

    //*********************************************************************//
    // -------------------------- public views --------------------------- //
    //*********************************************************************//

    /// @notice Returns the number of the game phase.
    /// @dev The game phase corresponds to the game's current funding cycle number.
    /// @dev NO_CONTEST is returned if the minimum participation threshold is not met, or if the scorecard timeout has
    /// elapsed without ratification.
    /// @param gameId The ID of the game to get the phase number of.
    /// @return The game phase.
    function currentGamePhaseOf(uint256 gameId) public view override returns (DefifaGamePhase) {
        // Get the game's current funding cycle along with its metadata.
        (JBRuleset memory currentRuleset, JBRulesetMetadata memory metadata) = CONTROLLER.currentRulesetOf(gameId);

        // Cache the cycle number to avoid repeated memory reads.
        uint256 cycleNumber = currentRuleset.cycleNumber;

        // Return early for the first three phases based on cycle number.
        if (cycleNumber == 0) return DefifaGamePhase.COUNTDOWN;
        if (cycleNumber == 1) return DefifaGamePhase.MINT;
        if (cycleNumber == 2 && _opsOf[gameId].refundPeriodDuration != 0) {
            return DefifaGamePhase.REFUND;
        }

        // Check if the scorecard has been ratified (game is COMPLETE).
        // This takes priority over all NO_CONTEST checks — a ratified scorecard is final.
        if (IDefifaHook(metadata.dataHook).cashOutWeightIsSet()) return DefifaGamePhase.COMPLETE;

        // If no-contest has already been triggered, stay in NO_CONTEST.
        if (noContestTriggeredFor[gameId]) return DefifaGamePhase.NO_CONTEST;

        // Get the game's ops data for the safety mechanism checks. Cache to avoid repeated SLOAD.
        DefifaOpsData memory ops = _opsOf[gameId];

        // Check minimum participation threshold: if the treasury balance is below the threshold, the game is
        // NO_CONTEST.
        if (ops.minParticipation > 0) {
            IJBTerminal terminal = CONTROLLER.DIRECTORY().primaryTerminalOf({projectId: gameId, token: ops.token});
            uint256 balance = IJBMultiTerminal(address(terminal)).STORE()
                .balanceOf({terminal: address(terminal), projectId: gameId, token: ops.token});
            if (balance < ops.minParticipation) return DefifaGamePhase.NO_CONTEST;
        }

        // Check scorecard ratification timeout: if enough time has passed without a ratified scorecard, the game is
        // NO_CONTEST.
        if (ops.scorecardTimeout > 0 && block.timestamp > currentRuleset.start + ops.scorecardTimeout) {
            return DefifaGamePhase.NO_CONTEST;
        }

        return DefifaGamePhase.SCORING;
    }

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    /// @param _hookCodeOrigin The code of the Defifa hook.
    /// @param _tokenUriResolver The standard default token URI resolver.
    /// @param _governor The Defifa governor.
    /// @param _controller The controller to use to launch the game from.
    /// @param _registry The contract storing references to the deployer of each hook.
    /// @param _defifaProjectId The ID of the project that should take the fee from the games.
    /// @param _baseProtocolProjectId The ID of the protocol project that'll receive fees from fulfilling commitments.
    constructor(
        address _hookCodeOrigin,
        IJB721TokenUriResolver _tokenUriResolver,
        IDefifaGovernor _governor,
        IJBController _controller,
        IJBAddressRegistry _registry,
        uint256 _defifaProjectId,
        uint256 _baseProtocolProjectId
    ) {
        // slither-disable-next-line missing-zero-check
        HOOK_CODE_ORIGIN = _hookCodeOrigin;
        TOKEN_URI_RESOLVER = _tokenUriResolver;
        GOVERNOR = _governor;
        CONTROLLER = _controller;
        REGISTRY = _registry;
        DEFIFA_PROJECT_ID = _defifaProjectId;
        BASE_PROTOCOL_PROJECT_ID = _baseProtocolProjectId;
        /// @dev Uses the deployer address as group ID. Game scoring rulesets use uint160(token) as group ID.
        SPLIT_GROUP = uint256(uint160(address(this)));
    }

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Fulfill split amounts between all splits for a game.
    /// @param gameId The ID of the game to fulfill splits for.
    function fulfillCommitmentsOf(uint256 gameId) external virtual override {
        // Make sure commitments haven't already been fulfilled.
        if (fulfilledCommitmentsOf[gameId] != 0) return;

        // Get the game's current funding cycle along with its metadata.
        // slither-disable-next-line unused-return
        (, JBRulesetMetadata memory metadata) = CONTROLLER.currentRulesetOf(gameId);

        // Make sure the game's commitments can be fulfilled.
        if (!IDefifaHook(metadata.dataHook).cashOutWeightIsSet()) {
            revert DefifaDeployer_CantFulfillYet();
        }

        // Get the game token and the terminal.
        address token = _opsOf[gameId].token;
        IJBMultiTerminal terminal =
            IJBMultiTerminal(address(CONTROLLER.DIRECTORY().primaryTerminalOf({projectId: gameId, token: token})));

        // Get the current pot and store it. This also prevents re-entrance since the check above will return early.
        uint256 pot = terminal.STORE().balanceOf({terminal: address(terminal), projectId: gameId, token: token});

        // If the pot is empty, set the sentinel and queue the final ruleset without attempting payouts.
        // slither-disable-next-line incorrect-equality
        if (pot == 0) {
            fulfilledCommitmentsOf[gameId] = 1;
            _queueFinalRuleset({gameId: gameId, metadata: metadata});
            // slither-disable-next-line reentrancy-events
            emit FulfilledCommitments({gameId: gameId, pot: 0, caller: msg.sender});
            return;
        }

        // Compute the fee amount based on the total absolute split percent stored at game creation.
        uint256 feeAmount =
            mulDiv({x: pot, y: _commitmentPercentOf[gameId], denominator: JBConstants.SPLITS_TOTAL_PERCENT});

        // Store the actual fee amount for accurate currentGamePotOf reporting.
        // Use max(feeAmount, 1) to preserve the reentrancy guard when pot is 0.
        fulfilledCommitmentsOf[gameId] = feeAmount > 0 ? feeAmount : 1;

        // Send only the fee portion as payouts. The remaining balance stays as surplus for cash-outs.
        // Wrapped in try-catch so the final ruleset is always queued even if payout fails.
        // slither-disable-next-line unused-return,reentrancy-no-eth
        try terminal.sendPayoutsOf({
            projectId: gameId,
            token: token,
            amount: feeAmount,
            // Casting address to uint32 via uint160 is the standard Juicebox token-to-currency conversion.
            // forge-lint: disable-next-line(unsafe-typecast)
            currency: token == JBConstants.NATIVE_TOKEN ? metadata.baseCurrency : uint32(uint160(token)),
            minTokensPaidOut: 0
        }) {}
        catch (bytes memory reason) {
            // Payout failed — fee stays in pot. Reset to sentinel (1) so currentGamePotOf
            // doesn't double-count the fee, while preserving the reentrancy guard.
            fulfilledCommitmentsOf[gameId] = 1;
            // slither-disable-next-line reentrancy-events
            emit CommitmentPayoutFailed({gameId: gameId, amount: feeAmount, reason: reason});
        }

        // Queue the final ruleset and emit.
        _queueFinalRuleset({gameId: gameId, metadata: metadata});

        // slither-disable-next-line reentrancy-events
        emit FulfilledCommitments({gameId: gameId, pot: pot, caller: msg.sender});
    }

    /// @notice Launches a new game owned by this contract with a DefifaHook attached.
    /// @param launchProjectData Data necessary to fulfill the transaction to launch a game.
    /// @return gameId The ID of the newly configured game.
    function launchGameWith(DefifaLaunchProjectData memory launchProjectData)
        external
        override
        returns (uint256 gameId)
    {
        // Start the game right after the mint and refund durations if it isnt provided.
        if (launchProjectData.start == 0) {
            launchProjectData.start =
                uint48(block.timestamp + launchProjectData.mintPeriodDuration + launchProjectData.refundPeriodDuration);
        }
        // Start minting right away if a start time isn't provided.
        // slither-disable-next-line incorrect-equality
        else if (
            launchProjectData.mintPeriodDuration == 0
                && launchProjectData.start > block.timestamp + launchProjectData.refundPeriodDuration
        ) {
            launchProjectData.mintPeriodDuration =
                uint24(launchProjectData.start - (block.timestamp + launchProjectData.refundPeriodDuration));
        }

        // Make sure the provided gameplay timestamps are sequential and that there is a mint duration.
        if (
            // slither-disable-next-line incorrect-equality
            launchProjectData.mintPeriodDuration == 0
                || launchProjectData.start
                    < block.timestamp + launchProjectData.refundPeriodDuration + launchProjectData.mintPeriodDuration
        ) revert DefifaDeployer_InvalidGameConfiguration();

        // The hook and governor hardcode uint256[128] tier-weight tables, so reject games with more than 128 tiers.
        if (launchProjectData.tiers.length > 128) revert DefifaDeployer_InvalidGameConfiguration();

        // Get the game ID, optimistically knowing it will be one greater than the current count.
        // Note: this prediction can race with other concurrent project deployments. If another project is
        // created between reading count() and launchProjectFor(), the actual ID will differ. This is
        // caught by the equality check after launch (gameId != actualGameId reverts).
        gameId = CONTROLLER.PROJECTS().count() + 1;

        {
            // Store the timestamps that'll define the game phases.
            _opsOf[gameId] = DefifaOpsData({
                token: launchProjectData.token.token,
                mintPeriodDuration: launchProjectData.mintPeriodDuration,
                refundPeriodDuration: launchProjectData.refundPeriodDuration,
                start: launchProjectData.start,
                minParticipation: launchProjectData.minParticipation,
                scorecardTimeout: launchProjectData.scorecardTimeout
            });

            // Keep a reference to the number of splits.
            uint256 numberOfSplits = launchProjectData.splits.length;

            // If there are splits being added, store the fee alongside. The fee will otherwise be added later.
            if (numberOfSplits != 0) {
                // Make a new splits where fees will be added to.
                JBSplit[] memory splits = new JBSplit[](launchProjectData.splits.length + 1);

                // Copy the splits over.
                for (uint256 i; i < numberOfSplits;) {
                    // Copy the split over.
                    splits[i] = launchProjectData.splits[i];
                    unchecked {
                        ++i;
                    }
                }

                // Add a split for the fee.
                splits[numberOfSplits] = JBSplit({
                    preferAddToBalance: false,
                    // forge-lint: disable-next-line(unsafe-typecast)
                    percent: uint32(JBConstants.SPLITS_TOTAL_PERCENT / DEFIFA_FEE_DIVISOR),
                    // forge-lint: disable-next-line(unsafe-typecast)
                    projectId: uint64(DEFIFA_PROJECT_ID),
                    beneficiary: payable(address(this)),
                    lockedUntil: 0,
                    hook: IJBSplitHook(address(0))
                });

                // Store the splits.
                JBSplitGroup[] memory groupedSplits = new JBSplitGroup[](1);
                groupedSplits[0] = JBSplitGroup({groupId: SPLIT_GROUP, splits: splits});

                // This contract must have SET_SPLIT_GROUPS permission from the defifa project owner.
                CONTROLLER.setSplitGroupsOf({
                    projectId: DEFIFA_PROJECT_ID, rulesetId: gameId, splitGroups: groupedSplits
                });
            }
        }

        // Keep track of the number of tiers.
        uint256 numberOfTiers = launchProjectData.tiers.length;

        // Create the standard tiers struct that will be populated from the defifa tiers.
        JB721TierConfig[] memory hookTiers = new JB721TierConfig[](launchProjectData.tiers.length);

        // Group all the tier names together.
        string[] memory tierNames = new string[](launchProjectData.tiers.length);

        // Keep a reference to the tier being iterated on.
        DefifaTierParams memory defifaTier;

        // Create the hook tiers from the Defifa tiers.
        for (uint256 i; i < numberOfTiers;) {
            defifaTier = launchProjectData.tiers[i];

            // Set the tier. All tiers use the same price so that price-based voting power is equal.
            hookTiers[i] = JB721TierConfig({
                price: launchProjectData.tierPrice,
                initialSupply: 999_999_999, // Uncapped minting — max value allowed by the 721 store.
                votingUnits: 0,
                reserveFrequency: defifaTier.reservedRate,
                reserveBeneficiary: defifaTier.reservedTokenBeneficiary,
                encodedIPFSUri: defifaTier.encodedIPFSUri,
                category: 0,
                discountPercent: 0,
                flags: JB721TierConfigFlags({
                    allowOwnerMint: false,
                    useReserveBeneficiaryAsDefault: defifaTier.shouldUseReservedTokenBeneficiaryAsDefault,
                    transfersPausable: false,
                    useVotingUnits: false,
                    cantBeRemoved: true,
                    cantIncreaseDiscountPercent: true,
                    cantBuyWithCredits: false
                }),
                splitPercent: 0,
                splits: new JBSplit[](0)
            });

            // Set the name.
            tierNames[i] = defifaTier.name;

            unchecked {
                ++i;
            }
        }

        // Increment the nonce for this deployment.
        // slither-disable-next-line reentrancy-benign
        uint256 currentNonce = ++_nonce;

        // Clone deterministically using sender and nonce to prevent front-running.
        // Clones.clone() creates the proxy before initialize() is called, allowing an
        // attacker to front-run initialization and DOS the game deployment. Using
        // cloneDeterministic with msg.sender in the salt prevents this since a different
        // caller produces a different address.
        DefifaHook hook = DefifaHook(
            Clones.cloneDeterministic({
                implementation: HOOK_CODE_ORIGIN, salt: keccak256(abi.encodePacked(msg.sender, currentNonce))
            })
        );

        // Use the default uri resolver if provided, else use the hardcoded generic default.
        IJB721TokenUriResolver uriResolver = launchProjectData.defaultTokenUriResolver
            != IJB721TokenUriResolver(address(0))
            ? launchProjectData.defaultTokenUriResolver
            : TOKEN_URI_RESOLVER;

        hook.initialize({
            _gameId: gameId,
            _name: launchProjectData.name,
            _symbol: string.concat("DEFIFA #", gameId.toString()),
            _rulesets: CONTROLLER.RULESETS(),
            _baseUri: launchProjectData.baseUri,
            _tokenUriResolver: uriResolver,
            _contractUri: launchProjectData.contractUri,
            _tiers: hookTiers,
            _currency: launchProjectData.token.currency,
            _store: launchProjectData.store,
            _gamePhaseReporter: this,
            _gamePotReporter: this,
            _defaultAttestationDelegate: launchProjectData.defaultAttestationDelegate,
            _tierNames: tierNames
        });

        // Launch the Juicebox project.
        uint256 actualGameId =
            _launchGame({launchProjectData: launchProjectData, gameId: gameId, dataHook: address(hook)});

        // Revert if the game ID does not match (e.g. front-run by another project creation).
        if (gameId != actualGameId) revert DefifaDeployer_InvalidGameConfiguration();

        // Clone and initialize the new governor.
        GOVERNOR.initializeGame({
            gameId: gameId,
            attestationStartTime: uint256(launchProjectData.attestationStartTime),
            attestationGracePeriod: uint256(launchProjectData.attestationGracePeriod),
            timelockDuration: launchProjectData.timelockDuration
        });

        // Transfer ownership to the specified owner.
        hook.transferOwnership(address(GOVERNOR));

        // Register the actual CREATE2 clone address using the same salt and minimal-proxy init code
        // that produced the deployed hook.
        REGISTRY.registerAddress({
            deployer: address(this),
            salt: keccak256(abi.encodePacked(msg.sender, currentNonce)),
            bytecode: _cloneCreationCodeFor(address(HOOK_CODE_ORIGIN))
        });

        // slither-disable-next-line reentrancy-events
        emit LaunchGame(gameId, hook, GOVERNOR, uriResolver, msg.sender);
    }

    /// @notice Allows this contract to receive 721s.
    function onERC721Received(address, address, uint256, bytes calldata) external pure override returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    /// @notice Triggers the no-contest refund mechanism for a game.
    /// @dev Anyone can call this once the game is in the NO_CONTEST phase. This queues a new ruleset without
    /// payout limits, making the surplus equal to the balance so users can cash out at their mint price.
    /// @dev Analogous to fulfillCommitmentsOf for COMPLETE — must be called before NO_CONTEST cash-outs work.
    /// @param gameId The ID of the game to trigger no-contest for.
    function triggerNoContestFor(uint256 gameId) external override {
        // Make sure the game is currently in NO_CONTEST phase.
        if (currentGamePhaseOf(gameId) != DefifaGamePhase.NO_CONTEST) {
            revert DefifaDeployer_NotNoContest();
        }

        // Make sure no-contest hasn't already been triggered.
        if (noContestTriggeredFor[gameId]) revert DefifaDeployer_NoContestAlreadyTriggered();

        // Mark as triggered.
        // Note: the queued ruleset does not take effect until the current ruleset's cycle ends (or immediately
        // if duration is 0). During this gap, the game reports NO_CONTEST but the on-chain ruleset still has
        // payout limits, so cash-out reclaim values may differ from the full-refund expectation. Callers
        // should verify the active ruleset before cashing out.
        noContestTriggeredFor[gameId] = true;

        // Get the game's current ruleset metadata for the data hook address.
        // slither-disable-next-line unused-return
        (, JBRulesetMetadata memory metadata) = CONTROLLER.currentRulesetOf(gameId);

        // Queue a new ruleset without payout limits so surplus = balance, enabling refunds.
        JBRulesetConfig[] memory rulesetConfigs = new JBRulesetConfig[](1);
        rulesetConfigs[0] = JBRulesetConfig({
            mustStartAtOrAfter: 0,
            duration: 0,
            weight: 0,
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: JBRulesetMetadata({
                reservedPercent: 0,
                cashOutTaxRate: 0,
                baseCurrency: metadata.baseCurrency,
                pausePay: true,
                pauseCreditTransfers: false,
                allowOwnerMinting: false,
                allowSetCustomToken: false,
                allowTerminalMigration: false,
                allowSetTerminals: false,
                allowSetController: false,
                allowAddAccountingContext: false,
                allowAddPriceFeed: false,
                ownerMustSendPayouts: true,
                holdFees: false,
                useTotalSurplusForCashOuts: false,
                useDataHookForPay: true,
                useDataHookForCashOut: true,
                dataHook: metadata.dataHook,
                metadata: uint16(
                    JB721TiersRulesetMetadataResolver.pack721TiersRulesetMetadata(
                        JB721TiersRulesetMetadata({pauseTransfers: false, pauseMintPendingReserves: false})
                    )
                )
            }),
            splitGroups: new JBSplitGroup[](0),
            fundAccessLimitGroups: new JBFundAccessLimitGroup[](0)
        });

        // Queue the no-contest refund ruleset.
        // slither-disable-next-line unused-return
        CONTROLLER.queueRulesetsOf({
            projectId: gameId, rulesetConfigurations: rulesetConfigs, memo: "Defifa game: no contest."
        });

        // slither-disable-next-line reentrancy-events
        emit QueuedNoContest(gameId, msg.sender);
    }

    //*********************************************************************//
    // ------------------------ internal functions ----------------------- //
    //*********************************************************************//

    function _buildSplits(
        uint256 gameId,
        address dataHook,
        address token,
        JBSplit[] memory initialSplits
    )
        internal
        returns (JBSplitGroup[] memory)
    {
        uint256 numberOfUserSplits = initialSplits.length;

        // Compute absolute percents for protocol fees.
        uint256 nanaAbsolutePercent = JBConstants.SPLITS_TOTAL_PERCENT / BASE_PROTOCOL_FEE_DIVISOR;
        uint256 defifaAbsolutePercent = JBConstants.SPLITS_TOTAL_PERCENT / DEFIFA_FEE_DIVISOR;

        // Sum all absolute percents.
        uint256 totalAbsolutePercent = nanaAbsolutePercent + defifaAbsolutePercent;
        for (uint256 i; i < numberOfUserSplits;) {
            totalAbsolutePercent += initialSplits[i].percent;
            unchecked {
                ++i;
            }
        }

        // Validate that total fee splits don't exceed 100%.
        if (totalAbsolutePercent > JBConstants.SPLITS_TOTAL_PERCENT) revert DefifaDeployer_SplitsDontAddUp();

        // Store the total absolute percent for use in fulfillCommitmentsOf.
        // slither-disable-next-line reentrancy-benign
        _commitmentPercentOf[gameId] = totalAbsolutePercent;

        // Build the splits array: user splits + Defifa + NANA (NANA last to absorb rounding).
        uint256 splitCount = numberOfUserSplits + 2;
        JBSplit[] memory splits = new JBSplit[](splitCount);

        // Normalize user splits and copy them over.
        uint256 normalizedTotal;
        for (uint256 i; i < numberOfUserSplits;) {
            splits[i] = initialSplits[i];
            splits[i].percent = uint32(
                mulDiv({
                    x: initialSplits[i].percent, y: JBConstants.SPLITS_TOTAL_PERCENT, denominator: totalAbsolutePercent
                })
            );
            normalizedTotal += splits[i].percent;
            unchecked {
                ++i;
            }
        }

        // Add Defifa fee split (normalized).
        uint256 defifaNormalized =
            mulDiv({x: defifaAbsolutePercent, y: JBConstants.SPLITS_TOTAL_PERCENT, denominator: totalAbsolutePercent});
        splits[numberOfUserSplits] = JBSplit({
            preferAddToBalance: false,
            // forge-lint: disable-next-line(unsafe-typecast)
            percent: uint32(defifaNormalized),
            // forge-lint: disable-next-line(unsafe-typecast)
            projectId: uint64(DEFIFA_PROJECT_ID),
            beneficiary: payable(address(dataHook)),
            lockedUntil: 0,
            hook: IJBSplitHook(address(0))
        });
        normalizedTotal += defifaNormalized;

        // Add NANA protocol fee split last — absorbs rounding remainder from normalization.
        // Because mulDiv rounds down, the sum of normalized percents can be slightly less than SPLITS_TOTAL_PERCENT.
        // The NANA split receives the difference, so its effective percent may be a few basis points above its
        // proportional share. This is economically negligible (< 1 bps at typical split counts).
        // Beneficiary is the data hook so the hook receives NANA tokens for distribution during cash-outs.
        splits[splitCount - 1] = JBSplit({
            preferAddToBalance: false,
            // forge-lint: disable-next-line(unsafe-typecast)
            percent: uint32(JBConstants.SPLITS_TOTAL_PERCENT - normalizedTotal),
            // forge-lint: disable-next-line(unsafe-typecast)
            projectId: uint64(BASE_PROTOCOL_PROJECT_ID),
            beneficiary: payable(address(dataHook)),
            lockedUntil: 0,
            hook: IJBSplitHook(address(0))
        });

        // Build the grouped split for the payment of the game token.
        JBSplitGroup[] memory groupedSplits = new JBSplitGroup[](1);
        groupedSplits[0] = JBSplitGroup({groupId: uint256(uint160(token)), splits: splits});

        return groupedSplits;
    }

    function _launchGame(
        DefifaLaunchProjectData memory launchProjectData,
        uint256 gameId,
        address dataHook
    )
        internal
        returns (uint256 projectId)
    {
        //
        JBAccountingContext[] memory accountingContexts = new JBAccountingContext[](1);
        accountingContexts[0] = launchProjectData.token;

        // Build the terminal configuration for the Defifa project.
        JBTerminalConfig[] memory terminalConfigurations = new JBTerminalConfig[](1);
        terminalConfigurations[0] =
            JBTerminalConfig({terminal: launchProjectData.terminal, accountingContextsToAccept: accountingContexts});

        // Build the rulesets that this Defifa game will go through.
        bool hasRefundPhase = launchProjectData.refundPeriodDuration != 0;
        JBRulesetConfig[] memory rulesetConfigs = new JBRulesetConfig[](hasRefundPhase ? 3 : 2);

        // `MINT` cycle.
        rulesetConfigs[0] = JBRulesetConfig({
            mustStartAtOrAfter: launchProjectData.start - launchProjectData.mintPeriodDuration
                - launchProjectData.refundPeriodDuration,
            duration: launchProjectData.mintPeriodDuration,
            weight: 0,
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: JBRulesetMetadata({
                reservedPercent: 0,
                cashOutTaxRate: 0,
                baseCurrency: launchProjectData.token.currency,
                pausePay: false,
                pauseCreditTransfers: false,
                allowOwnerMinting: false,
                allowSetCustomToken: false,
                allowTerminalMigration: false,
                allowSetTerminals: false,
                allowSetController: false,
                allowAddAccountingContext: false,
                allowAddPriceFeed: false,
                ownerMustSendPayouts: false,
                holdFees: false,
                useTotalSurplusForCashOuts: false,
                useDataHookForPay: true,
                useDataHookForCashOut: true,
                dataHook: dataHook,
                metadata: uint16(
                    JB721TiersRulesetMetadataResolver.pack721TiersRulesetMetadata(
                        JB721TiersRulesetMetadata({
                            pauseTransfers: false,
                            // Reserved tokens can't be minted during this funding cycle.
                            pauseMintPendingReserves: true
                        })
                    )
                )
            }),
            splitGroups: new JBSplitGroup[](0),
            fundAccessLimitGroups: new JBFundAccessLimitGroup[](0)
        });

        uint256 cycleNumber = 1;
        if (hasRefundPhase) {
            // `REFUND` cycle.
            rulesetConfigs[cycleNumber++] = JBRulesetConfig({
                mustStartAtOrAfter: launchProjectData.start - launchProjectData.refundPeriodDuration,
                duration: launchProjectData.refundPeriodDuration,
                weight: 0,
                weightCutPercent: 0,
                approvalHook: IJBRulesetApprovalHook(address(0)),
                metadata: JBRulesetMetadata({
                    reservedPercent: 0,
                    cashOutTaxRate: 0,
                    baseCurrency: launchProjectData.token.currency,
                    // Refund phase does not allow new payments.
                    pausePay: true,
                    pauseCreditTransfers: false,
                    allowOwnerMinting: false,
                    allowSetCustomToken: false,
                    allowTerminalMigration: false,
                    allowSetTerminals: false,
                    allowSetController: false,
                    allowAddAccountingContext: false,
                    allowAddPriceFeed: false,
                    ownerMustSendPayouts: false,
                    holdFees: false,
                    useTotalSurplusForCashOuts: false,
                    useDataHookForPay: true,
                    useDataHookForCashOut: true,
                    dataHook: dataHook,
                    metadata: uint16(
                        JB721TiersRulesetMetadataResolver.pack721TiersRulesetMetadata(
                            JB721TiersRulesetMetadata({
                                pauseTransfers: false,
                                // Reserved tokens can't be minted during this funding cycle.
                                pauseMintPendingReserves: true
                            })
                        )
                    )
                }),
                splitGroups: new JBSplitGroup[](0),
                fundAccessLimitGroups: new JBFundAccessLimitGroup[](0)
            });
        }

        // Set fund access constraints.
        JBCurrencyAmount[] memory payoutAmounts = new JBCurrencyAmount[](1);
        payoutAmounts[0] = JBCurrencyAmount({
            // We allow a payout of the full amount, this will then mostly be added back to the balance of the project.
            amount: type(uint224).max,
            currency: launchProjectData.token.currency
        });

        JBFundAccessLimitGroup[] memory fundAccessConstraints = new JBFundAccessLimitGroup[](1);
        fundAccessConstraints[0] = JBFundAccessLimitGroup({
            terminal: address(launchProjectData.terminal),
            token: launchProjectData.token.token,
            payoutLimits: payoutAmounts,
            surplusAllowances: new JBCurrencyAmount[](0)
        });

        // `SCORING` cycle.
        rulesetConfigs[cycleNumber++] = JBRulesetConfig({
            mustStartAtOrAfter: launchProjectData.start,
            duration: 0,
            weight: 0,
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: JBRulesetMetadata({
                reservedPercent: 0,
                cashOutTaxRate: 0,
                baseCurrency: launchProjectData.token.currency,
                pausePay: true,
                pauseCreditTransfers: false,
                allowOwnerMinting: false,
                allowSetCustomToken: false,
                allowTerminalMigration: false,
                allowSetTerminals: false,
                allowSetController: false,
                allowAddAccountingContext: false,
                allowAddPriceFeed: false,
                // Set this to true so only the deployer can fulfill the commitments.
                ownerMustSendPayouts: true,
                holdFees: false,
                useTotalSurplusForCashOuts: false,
                useDataHookForPay: true,
                useDataHookForCashOut: true,
                dataHook: dataHook,
                metadata: uint16(
                    JB721TiersRulesetMetadataResolver.pack721TiersRulesetMetadata(
                        JB721TiersRulesetMetadata({pauseTransfers: false, pauseMintPendingReserves: false})
                    )
                )
            }),
            splitGroups: _buildSplits({
                gameId: gameId,
                dataHook: dataHook,
                token: launchProjectData.token.token,
                initialSplits: launchProjectData.splits
            }),
            fundAccessLimitGroups: fundAccessConstraints
        });

        // launch the project.
        return CONTROLLER.launchProjectFor({
            owner: address(this),
            projectUri: launchProjectData.projectUri,
            rulesetConfigurations: rulesetConfigs,
            terminalConfigurations: terminalConfigurations,
            memo: "Launching Defifa game."
        });
    }

    /// @notice Queues the final ruleset for a game: no payouts, no fund access limits, surplus = entire balance.
    /// @param gameId The ID of the game.
    /// @param metadata The current ruleset metadata (used to carry forward baseCurrency and dataHook).
    function _queueFinalRuleset(uint256 gameId, JBRulesetMetadata memory metadata) internal {
        JBRulesetConfig[] memory rulesetConfigs = new JBRulesetConfig[](1);
        rulesetConfigs[0] = JBRulesetConfig({
            mustStartAtOrAfter: 0,
            duration: 0,
            weight: 0,
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: JBRulesetMetadata({
                reservedPercent: 0,
                cashOutTaxRate: 0,
                baseCurrency: metadata.baseCurrency,
                pausePay: true,
                pauseCreditTransfers: false,
                allowOwnerMinting: false,
                allowSetCustomToken: false,
                allowTerminalMigration: false,
                allowSetTerminals: false,
                allowSetController: false,
                allowAddAccountingContext: false,
                allowAddPriceFeed: false,
                ownerMustSendPayouts: false,
                holdFees: false,
                useTotalSurplusForCashOuts: false,
                useDataHookForPay: true,
                useDataHookForCashOut: true,
                dataHook: metadata.dataHook,
                metadata: uint16(
                    JB721TiersRulesetMetadataResolver.pack721TiersRulesetMetadata(
                        JB721TiersRulesetMetadata({pauseTransfers: false, pauseMintPendingReserves: false})
                    )
                )
            }),
            // No more payouts.
            splitGroups: new JBSplitGroup[](0),
            fundAccessLimitGroups: new JBFundAccessLimitGroup[](0)
        });

        // slither-disable-next-line unused-return
        CONTROLLER.queueRulesetsOf({
            projectId: gameId, rulesetConfigurations: rulesetConfigs, memo: "Defifa game has finished."
        });
    }

    /// @notice Returns the minimal-proxy init code used to deploy a clone for the provided implementation.
    /// @dev Defifa deploys hooks with `Clones.cloneDeterministic`, which uses `CREATE2`.
    /// The address registry's CREATE2 path must be given the exact init code hash that was used at deployment time,
    /// not the runtime bytecode and not a CREATE nonce. This helper reconstructs the standard EIP-1167 creation code
    /// by inserting the implementation address into OpenZeppelin's minimal-proxy init-code template.
    /// @param implementation The contract address the clone will delegate all calls to.
    /// @return bytecode The full EIP-1167 creation bytecode hashed by CREATE2 to derive the clone address.
    function _cloneCreationCodeFor(address implementation) internal pure returns (bytes memory bytecode) {
        // EIP-1167 minimal proxy init code, mirroring OpenZeppelin's Clones.sol layout:
        // [prefix (20 bytes)] [implementation address (20 bytes)] [suffix (15 bytes)]
        bytecode = abi.encodePacked(
            hex"3d602d80600a3d3981f3363d3d373d3d3d363d73", bytes20(implementation), hex"5af43d82803e903d91602b57fd5bf3"
        );
    }
}
