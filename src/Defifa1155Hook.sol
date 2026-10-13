// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {Checkpoints} from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IJBCashOutHook} from "@bananapus/core-v6/src/interfaces/IJBCashOutHook.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPayHook} from "@bananapus/core-v6/src/interfaces/IJBPayHook.sol";
import {IJBRulesetDataHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetDataHook.sol";
import {IJBRulesets} from "@bananapus/core-v6/src/interfaces/IJBRulesets.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {JBRulesetMetadataResolver} from "@bananapus/core-v6/src/libraries/JBRulesetMetadataResolver.sol";
import {JBAfterCashOutRecordedContext} from "@bananapus/core-v6/src/structs/JBAfterCashOutRecordedContext.sol";
import {JBAfterPayRecordedContext} from "@bananapus/core-v6/src/structs/JBAfterPayRecordedContext.sol";
import {JBBeforeCashOutRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforeCashOutRecordedContext.sol";
import {JBBeforePayRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforePayRecordedContext.sol";
import {JBCashOutHookSpecification} from "@bananapus/core-v6/src/structs/JBCashOutHookSpecification.sol";
import {JBPayHookSpecification} from "@bananapus/core-v6/src/structs/JBPayHookSpecification.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {IJB721TiersHookStore} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHookStore.sol";
import {IJB721TokenUriResolver} from "@bananapus/721-hook-v6/src/interfaces/IJB721TokenUriResolver.sol";
import {
    JB721TiersRulesetMetadataResolver
} from "@bananapus/721-hook-v6/src/libraries/JB721TiersRulesetMetadataResolver.sol";
import {JB721Tier} from "@bananapus/721-hook-v6/src/structs/JB721Tier.sol";
import {JB721TierConfig} from "@bananapus/721-hook-v6/src/structs/JB721TierConfig.sol";
import {JB721TiersMintReservesConfig} from "@bananapus/721-hook-v6/src/structs/JB721TiersMintReservesConfig.sol";

import {JBMetadataResolver} from "@bananapus/core-v6/src/libraries/JBMetadataResolver.sol";
import {DefifaDelegation} from "./structs/DefifaDelegation.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IDefifa1155Hook} from "./interfaces/IDefifa1155Hook.sol";
import {IDefifaTiersHookStore} from "./interfaces/IDefifaTiersHookStore.sol";
import {IDefifaGamePhaseReporter} from "./interfaces/IDefifaGamePhaseReporter.sol";
import {IDefifaGamePotReporter} from "./interfaces/IDefifaGamePotReporter.sol";
import {DefifaTierCashOutWeight} from "./structs/DefifaTierCashOutWeight.sol";
import {DefifaGamePhase} from "./enums/DefifaGamePhase.sol";
import {Defifa1155HookLib} from "./libraries/Defifa1155HookLib.sol";
import {DefifaHookLib} from "./libraries/DefifaHookLib.sol";

/// @notice The ERC-1155 hook that powers Defifa games. Positions are balances: a payment mints a count per tier in one
/// transfer instead of one token per position. The hook enforces game phase rules on minting and cashing out, tracks
/// per-tier voting power via checkpoints, and applies scorecard-determined cash-out weights after ratification. Mints
/// are only allowed during the MINT phase, refunds during the REFUND phase, and cash-outs with scoring weights only
/// after a scorecard is ratified in the COMPLETE phase.
/// @dev Tier configuration, supply, reserve, burn and per-holder tier accounting stay in the tiers store, which must
/// be a `DefifaTiersHookStore` (the 721 store plus count-based records, called once per tier). Each tier has two token
/// IDs: the tier ID for paid positions and `tierId + RESERVE_TOKEN_ID_OFFSET` for reserve-minted positions, which
/// refunds exclude.
contract Defifa1155Hook is ERC1155, Ownable, IDefifa1155Hook {
    using Checkpoints for Checkpoints.Trace208;

    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    /// @notice Thrown when the Defifa token and base protocol token addresses are the same at construction.
    error Defifa1155Hook_IdenticalTokens(address defifaToken, address baseProtocolToken);

    /// @notice Thrown when a tier delegation specifies the zero address as the delegate.
    error Defifa1155Hook_DelegateAddressZero(uint256 tierId);

    /// @notice Thrown when attempting to change a tier delegation outside of the MINT phase.
    error Defifa1155Hook_DelegateChangesUnavailableInThisPhase(uint256 projectId, DefifaGamePhase phase);

    /// @notice Thrown when setting cash-out weights while the game is not yet in its SCORING phase.
    error Defifa1155Hook_GameIsntScoringYet(uint256 projectId, DefifaGamePhase phase);

    /// @notice Thrown when a cash-out is not called by one of the project's terminals for this project.
    error Defifa1155Hook_InvalidCashOut(address caller, uint256 contextProjectId, uint256 projectId, uint256 msgValue);

    /// @notice Thrown when a payment is not reported by one of the project's terminals for this project.
    error Defifa1155Hook_InvalidPay(address caller, uint256 contextProjectId, uint256 projectId);

    /// @notice Thrown when a payment would mint positions to the zero address.
    error Defifa1155Hook_InvalidBeneficiary();

    /// @notice Thrown when a cash-out reclaims nothing and the beneficiary received no fee tokens.
    error Defifa1155Hook_NothingToClaim(uint256 reclaimedAmount, bool beneficiaryReceivedTokens);

    /// @notice Thrown when a payment carries no mint metadata or specifies no tiers to mint.
    error Defifa1155Hook_NothingToMint(bool metadataFound, uint256 tierCount);

    /// @notice Thrown when a payment's currency does not match the game's pricing currency.
    error Defifa1155Hook_WrongCurrency(uint256 expectedCurrency, uint256 actualCurrency);

    /// @notice Thrown when a payment leaves an unspent amount after minting the requested tiers.
    error Defifa1155Hook_Overspending(uint256 leftoverAmount);

    /// @notice Thrown when setting cash-out weights for a game whose weights have already been set.
    error Defifa1155Hook_CashoutWeightsAlreadySet(uint256 projectId);

    /// @notice Thrown when minting reserved tokens while reserve minting is paused for the game.
    error Defifa1155Hook_ReservedTokenMintingPaused(uint256 projectId, uint256 tierId);

    /// @notice Thrown when minting reserved tokens while the game is in its NO_CONTEST phase.
    error Defifa1155Hook_ReservedTokenMintingBlockedInNoContest(uint256 projectId, uint256 tierId);

    /// @notice Thrown when fungible project tokens are cashed out alongside game positions.
    error Defifa1155Hook_UnexpectedTokenCashedOut(uint256 cashOutCount);

    /// @notice Thrown when transferring positions whose tier has transfers paused.
    error Defifa1155Hook_TransfersPaused(uint256 projectId, uint256 tokenId, address from, address to);

    /// @notice Thrown when cashing out more positions of a token ID than the cash-out holder owns.
    error Defifa1155Hook_Unauthorized(uint256 tokenId, uint256 amount, uint256 balance, address holder);

    //*********************************************************************//
    // --------------------- public constant properties ------------------ //
    //*********************************************************************//

    /// @notice The total cash-out weight that can be divided among tiers.
    uint256 public constant override TOTAL_CASHOUT_WEIGHT = 1_000_000_000_000_000_000;

    /// @notice The offset added to a tier ID to form the token ID of its reserve-minted positions.
    uint256 public constant override RESERVE_TOKEN_ID_OFFSET = Defifa1155HookLib.RESERVE_TOKEN_ID_OFFSET;

    //*********************************************************************//
    // -------------------- internal stored properties ------------------- //
    //*********************************************************************//

    /// @notice The cash-out weight for each tier.
    /// @dev Tiers are limited to ID 128.
    uint256[128] internal _tierCashOutWeights;

    /// @notice The delegation status for each address and for each tier.
    /// @custom:param account The delegator.
    /// @custom:param tierId The ID of the tier to delegate.
    mapping(address => mapping(uint256 => address)) internal _tierDelegation;

    /// @notice The delegation checkpoints for each address and for each tier.
    /// @custom:param account The delegator.
    /// @custom:param tierId The ID of the tier to check.
    mapping(address => mapping(uint256 => Checkpoints.Trace208)) internal _delegateTierCheckpoints;

    /// @notice The total delegation status for each tier.
    /// @custom:param tierId The ID of the tier to check.
    mapping(uint256 => Checkpoints.Trace208) internal _totalTierCheckpoints;

    /// @notice The name of the game-piece collection.
    string internal _name;

    /// @notice The symbol of the game-piece collection.
    string internal _symbol;

    /// @notice The names of each tier.
    /// @custom:param tierId The ID of the tier to get a name for.
    mapping(uint256 => string) internal _tierNameOf;

    //*********************************************************************//
    // ---------------- public immutable stored properties --------------- //
    //*********************************************************************//

    /// @notice The directory of terminals and controllers for projects.
    IJBDirectory public immutable override DIRECTORY;

    /// @notice The $DEFIFA token that is expected to be issued from paying fees.
    IERC20 public immutable override DEFIFA_TOKEN;

    /// @notice The $BASE_PROTOCOL token that is expected to be issued from paying fees.
    IERC20 public immutable override BASE_PROTOCOL_TOKEN;

    //*********************************************************************//
    // --------------------- public stored properties -------------------- //
    //*********************************************************************//

    /// @notice The cumulative mint price of all paid and reserved positions. Decremented on burns/refunds. Used as the
    /// participation metric — immune to `addToBalanceOf` inflation because only actual mints increment it.
    uint256 public override totalMintCost;

    /// @notice The amount redeemed from this game, excluding refunds.
    uint256 public override amountRedeemed;

    /// @notice The common base for token URIs.
    string public override baseURI;

    /// @notice Whether the cash-out weights have been set.
    bool public override cashOutWeightIsSet;

    /// @notice The original Defifa1155Hook implementation address used to distinguish clones during initialization.
    address public immutable override CODE_ORIGIN;

    /// @notice The contract-level metadata URI used by marketplaces to display collection information.
    string public override contractURI;

    /// @notice The address that will be set as the attestation delegate by default.
    address public override defaultAttestationDelegate;

    /// @notice The contract reporting game phases.
    IDefifaGamePhaseReporter public override gamePhaseReporter;

    /// @notice The contract reporting the game pot.
    IDefifaGamePotReporter public override gamePotReporter;

    /// @notice The currency that is accepted when minting tier positions.
    uint256 public override pricingCurrency;

    /// @notice The number of positions burned from a tier during non-COMPLETE phases (refund, no-contest).
    /// @dev Used to adjust pending reserve counts so reserves that correspond to refunded mints
    /// are excluded from the cash-out denominator.
    /// @custom:param tierId The ID of the tier whose non-COMPLETE-phase burn count is stored.
    mapping(uint256 => uint256) public refundedBurnsFrom;

    /// @notice The ID of the project (game) this hook belongs to.
    uint256 public override projectId;

    /// @notice The contract storing all funding cycle configurations.
    IJBRulesets public override rulesets;

    /// @notice The contract that stores tier configuration, supply, reserve and burn accounting.
    IJB721TiersHookStore public override store;

    /// @notice The number of positions redeemed from each tier, excluding refunds.
    /// @custom:param tierId The tier from which tokens have been redeemed.
    mapping(uint256 => uint256) public override tokensRedeemedFrom;

    //*********************************************************************//
    // ------------------------- external views -------------------------- //
    //*********************************************************************//

    /// @notice Returns the adjusted pending reserve count for a tier, accounting for refund-phase burns.
    /// @dev Recalculates reserves from (paidMints - burns) / reserveFrequency since the relationship
    /// between burns and reserves is not linear — it depends on the tier's reserve frequency.
    /// @param tierId The tier ID.
    /// @return The adjusted pending reserve count (floored at 0).
    function adjustedPendingReservesFor(uint256 tierId) public view returns (uint256) {
        return DefifaHookLib.adjustedPendingReservesFor({
            tierId: tierId, hookStore: store, hook: address(this), refundBurns: refundedBurnsFrom[tierId]
        });
    }

    /// @notice Returns the past attestation units of a specific address for a specific tier.
    /// @param account The address to check.
    /// @param tier The tier to check within.
    /// @param timestamp The timestamp to check the attestation power at.
    function getPastTierAttestationUnitsOf(
        address account,
        uint256 tier,
        uint48 timestamp
    )
        external
        view
        override
        returns (uint256)
    {
        return _delegateTierCheckpoints[account][tier].upperLookup(timestamp);
    }

    /// @notice Returns the total amount of attestation units that has existed for a tier.
    /// @param tier The tier to check.
    /// @param timestamp The timestamp to check the total attestation units at.
    function getPastTierTotalAttestationUnitsOf(
        uint256 tier,
        uint48 timestamp
    )
        external
        view
        override
        returns (uint256)
    {
        return _totalTierCheckpoints[tier].upperLookup(timestamp);
    }

    /// @notice Returns the current attestation power of an address for a specific tier.
    /// @param account The address to check.
    /// @param tier The tier to check within.
    function getTierAttestationUnitsOf(address account, uint256 tier) external view override returns (uint256) {
        return _delegateTierCheckpoints[account][tier].latest();
    }

    /// @notice Returns the delegate of an account for specific tier.
    /// @param account The account to check for a delegate of.
    /// @param tier The tier to check within.
    function getTierDelegateOf(address account, uint256 tier) external view override returns (address) {
        return _tierDelegation[account][tier];
    }

    /// @notice Returns the total amount of attestation units that exists for a tier.
    /// @param tier The tier to check.
    function getTierTotalAttestationUnitsOf(uint256 tier) external view override returns (uint256) {
        return _totalTierCheckpoints[tier].latest();
    }

    /// @notice The cashOut weight for each tier.
    /// @return The array of weights, indexed by tier.
    function tierCashOutWeights() external view override returns (uint256[128] memory) {
        return _tierCashOutWeights;
    }

    /// @notice The ID used when parsing pay and cash-out metadata. Clones share the implementation's ID.
    /// @return The address of the metadata ID target.
    function METADATA_ID_TARGET() external view override returns (address) {
        return CODE_ORIGIN;
    }

    /// @notice The name of the game-piece collection.
    function name() external view override returns (string memory) {
        return _name;
    }

    /// @notice The symbol of the game-piece collection.
    function symbol() external view override returns (string memory) {
        return _symbol;
    }

    /// @notice Required by the IJBRulesetDataHook interface. Return false to not leak any permissions.
    function hasMintPermissionFor(uint256, JBRuleset memory, address) external pure override returns (bool) {
        return false;
    }

    /// @notice The tier a token ID belongs to.
    /// @param tokenId The token ID (paid or reserve ID).
    /// @return The tier ID.
    function tierIdOf(uint256 tokenId) external pure override returns (uint256) {
        return Defifa1155HookLib.tierIdOf(tokenId);
    }

    /// @notice The name of the tier with the specified ID.
    /// @param tierId The ID of the tier.
    function tierNameOf(uint256 tierId) external view override returns (string memory) {
        return _tierNameOf[tierId];
    }

    //*********************************************************************//
    // -------------------------- public views --------------------------- //
    //*********************************************************************//

    /// @notice The data calculated before a cash-out is recorded in the terminal store. This data is provided to the
    /// terminal's `cashOutTokensOf(...)` transaction.
    /// @dev Sets this contract as the cash-out hook. Part of `IJBRulesetDataHook`.
    /// @dev This function is used for position cash-outs, and will only be called if the project's ruleset has
    /// `useDataHookForCashOut` set to `true`.
    /// @param context The cash-out context passed to this contract by the `cashOutTokensOf(...)` function.
    /// @return cashOutTaxRate The cash-out tax rate influencing the reclaim amount.
    /// @return cashOutCount The amount of tokens that should be considered cashed out.
    /// @return totalSupply The total amount of tokens that are considered to be existing.
    /// @return effectiveSurplusValue The effective surplus value to use for the cash-out.
    /// @return hookSpecifications The amount and data to send to cash-out hooks (this contract) instead of returning
    /// to the beneficiary.
    function beforeCashOutRecordedWith(JBBeforeCashOutRecordedContext calldata context)
        public
        view
        virtual
        override
        returns (
            uint256 cashOutTaxRate,
            uint256 cashOutCount,
            uint256 totalSupply,
            uint256 effectiveSurplusValue,
            JBCashOutHookSpecification[] memory hookSpecifications
        )
    {
        // Make sure (fungible) project tokens aren't also being cashed out.
        if (context.cashOutCount > 0) {
            revert Defifa1155Hook_UnexpectedTokenCashedOut({cashOutCount: context.cashOutCount});
        }

        // Fetch the cash-out hook metadata using the corresponding metadata ID.
        (bool metadataExists, bytes memory metadata) = JBMetadataResolver.getDataFor({
            id: JBMetadataResolver.getId({purpose: "cashOut", target: CODE_ORIGIN}), metadata: context.metadata
        });

        uint256[] memory decodedTokenIds;
        uint256[] memory decodedAmounts;

        // Decode the metadata: the token IDs and the number of positions of each to cash out.
        if (metadataExists) (decodedTokenIds, decodedAmounts) = abi.decode(metadata, (uint256[], uint256[]));

        // Get the current game phase.
        DefifaGamePhase gamePhase = gamePhaseReporter.currentGamePhaseOf(context.projectId);

        // Cache the store reference in a local variable to avoid repeated SLOAD.
        IJB721TiersHookStore hookStore = store;

        // During refund phases, reserve-minted positions were minted for free and have no paid amount to refund.
        uint256 cumulativeMintPrice = Defifa1155HookLib.computeCumulativeMintPriceForCashOut({
            tokenIds: decodedTokenIds,
            amounts: decodedAmounts,
            hookStore: hookStore,
            hook: address(this),
            excludeReserveMints: gamePhase == DefifaGamePhase.MINT || gamePhase == DefifaGamePhase.REFUND
                || gamePhase == DefifaGamePhase.NO_CONTEST
        });

        // Use this contract as the only cash-out hook.
        hookSpecifications = new JBCashOutHookSpecification[](1);
        hookSpecifications[0] =
            JBCashOutHookSpecification({hook: this, noop: false, amount: 0, metadata: abi.encode(cumulativeMintPrice)});

        // Compute the cash-out count based on the game phase.
        cashOutCount = DefifaHookLib.computeCashOutCount({
            gamePhase: gamePhase,
            cumulativeMintPrice: cumulativeMintPrice,
            surplusValue: context.surplus.value,
            totalAmountRedeemed: amountRedeemed,
            cumulativeCashOutWeight: cashOutWeightOf(decodedTokenIds, decodedAmounts)
        });

        // Use the surplus as the total supply.
        totalSupply = context.surplus.value;

        // Use the surplus as the effective surplus value.
        effectiveSurplusValue = context.surplus.value;

        // Use the cash-out tax rate from the context.
        cashOutTaxRate = context.cashOutTaxRate;
    }

    /// @notice The cumulative weight the given positions have in cash-outs compared to the `totalCashOutWeight`.
    /// @param tokenIds The token IDs (paid or reserve IDs).
    /// @param amounts The number of positions of each token ID.
    /// @return cumulativeWeight The weight.
    function cashOutWeightOf(
        uint256[] memory tokenIds,
        uint256[] memory amounts
    )
        public
        view
        virtual
        override
        returns (uint256 cumulativeWeight)
    {
        cumulativeWeight = Defifa1155HookLib.computeCashOutWeightBatch({
            tokenIds: tokenIds,
            amounts: amounts,
            hookStore: store,
            hook: address(this),
            tierCashOutWeights: _tierCashOutWeights,
            tokensRedeemedFrom: tokensRedeemedFrom
        });
    }

    /// @notice The weight one position of the given token ID has in cash-outs.
    /// @param tokenId The token ID (paid or reserve ID).
    /// @return The weight.
    function cashOutWeightOf(uint256 tokenId) public view override returns (uint256) {
        return Defifa1155HookLib.computeCashOutWeight({
            tokenId: tokenId,
            hookStore: store,
            hook: address(this),
            tierCashOutWeights: _tierCashOutWeights,
            tokensRedeemedFrom: tokensRedeemedFrom
        });
    }

    /// @notice The number of positions of a tier that are currently in circulation, paid and reserve-minted.
    /// @param tierId The ID of the tier to get the current supply of.
    /// @return The current supply count.
    function currentSupplyOfTier(uint256 tierId) public view returns (uint256) {
        return DefifaHookLib.computeCurrentSupply({hookStore: store, hook: address(this), tierId: tierId});
    }

    /// @notice Indicates if this contract adheres to the specified interface.
    /// @dev See {IERC165-supportsInterface}.
    /// @param interfaceId The ID of the interface to check for adherence to.
    function supportsInterface(bytes4 interfaceId) public view override(ERC1155, IERC165) returns (bool) {
        return interfaceId == type(IDefifa1155Hook).interfaceId || interfaceId == type(IJBRulesetDataHook).interfaceId
            || interfaceId == type(IJBPayHook).interfaceId || interfaceId == type(IJBCashOutHook).interfaceId
            || super.supportsInterface(interfaceId);
    }

    /// @notice The metadata URI of the provided token ID.
    /// @dev Defers to the token URI resolver.
    /// @param tokenId The token ID (paid or reserve ID).
    /// @return The token URI from the resolver.
    function uri(uint256 tokenId) public view virtual override returns (string memory) {
        return store.tokenUriResolverOf(address(this)).tokenUriOf({nft: address(this), tokenId: tokenId});
    }

    /// @notice The amount of $DEFIFA and $BASE_PROTOCOL tokens claimable for a set of positions.
    /// @param tokenIds The token IDs (paid or reserve IDs).
    /// @param amounts The number of positions of each token ID.
    /// @return defifaTokenAmount The amount of $DEFIFA that can be claimed.
    /// @return baseProtocolTokenAmount The amount of $BASE_PROTOCOL that can be claimed.
    function tokensClaimableFor(
        uint256[] memory tokenIds,
        uint256[] memory amounts
    )
        public
        view
        returns (uint256 defifaTokenAmount, uint256 baseProtocolTokenAmount)
    {
        // If the game isn't complete, we do not have any tokens to claim.
        if (_currentGamePhaseOf(projectId) != DefifaGamePhase.COMPLETE) return (0, 0);

        // Include unminted reserves in the denominator. Once reserves are pending, their future recipients are
        // entitled to fee-token claims as if the reserve positions had already been minted; otherwise paid holders
        // could claim too large a share before the reserve mint transaction lands.
        return Defifa1155HookLib.computeTokensClaim({
            tokenIds: tokenIds,
            amounts: amounts,
            hookStore: store,
            hook: address(this),
            totalMintCost: totalMintCost + _pendingReserveMintCost(),
            defifaBalance: DEFIFA_TOKEN.balanceOf(address(this)),
            baseProtocolBalance: BASE_PROTOCOL_TOKEN.balanceOf(address(this))
        });
    }

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    /// @dev The initial owner is msg.sender; ownership is transferred to the governor after initialization.
    constructor(IJBDirectory directory, IERC20 defifaToken, IERC20 baseProtocolToken) ERC1155("") Ownable(msg.sender) {
        if (address(defifaToken) == address(baseProtocolToken)) {
            revert Defifa1155Hook_IdenticalTokens({
                defifaToken: address(defifaToken), baseProtocolToken: address(baseProtocolToken)
            });
        }

        CODE_ORIGIN = address(this);
        DIRECTORY = directory;
        DEFIFA_TOKEN = defifaToken;
        BASE_PROTOCOL_TOKEN = baseProtocolToken;
    }

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Mints positions to the `context.beneficiary` upon payment if conditions are met.
    /// @dev Reverts if the calling contract is not one of the project's terminals.
    /// @param context The payment context passed in by the terminal.
    function afterPayRecordedWith(JBAfterPayRecordedContext calldata context) external payable virtual override {
        uint256 localProjectId = projectId;

        // Make sure the caller is a terminal of the project, and that the call is being made on behalf of an
        // interaction with the correct project.
        if (msg.value != 0 || !_isProjectTerminal(localProjectId) || context.projectId != localProjectId) {
            revert Defifa1155Hook_InvalidPay({
                caller: msg.sender, contextProjectId: context.projectId, projectId: localProjectId
            });
        }

        // Process the payment.
        _processPayment(context);
    }

    /// @notice The data calculated before a payment is recorded: forwards the ruleset weight and uses this contract as
    /// the only pay hook. Part of `IJBRulesetDataHook`.
    /// @param context The payment context passed to this contract by the `pay(...)` function.
    /// @return weight The weight to use, the ruleset's.
    /// @return hookSpecifications This contract, with nothing forwarded to it.
    function beforePayRecordedWith(JBBeforePayRecordedContext calldata context)
        external
        view
        override
        returns (uint256 weight, JBPayHookSpecification[] memory hookSpecifications)
    {
        weight = context.weight;
        hookSpecifications = new JBPayHookSpecification[](1);
        hookSpecifications[0] = JBPayHookSpecification({hook: this, noop: false, amount: 0, metadata: bytes("")});
    }

    //*********************************************************************//
    // ----------------------- public transactions ----------------------- //
    //*********************************************************************//

    /// @notice Initialize a clone of this contract.
    /// @param _gameId The ID of the project this contract's functionality applies to.
    /// @param _gameName The name of the game-piece collection.
    /// @param _gameSymbol The symbol of the game-piece collection.
    /// @param _rulesets A contract storing all ruleset configurations.
    /// @param _baseUri A URI to use as a base for full token URIs.
    /// @param _tokenUriResolver A contract responsible for resolving the token URI for each token ID.
    /// @param _contractUri A URI where contract metadata can be found.
    /// @param _tiers The tiers to set.
    /// @param _currency The currency that the tier contribution floors are denoted in.
    /// @param _store A contract that stores tier configuration and supply accounting.
    /// @param _gamePhaseReporter The contract that reports the game phase.
    /// @param _gamePotReporter The contract that reports the game's pot.
    /// @param _defaultAttestationDelegate The address that will be set as the attestation delegate by default.
    /// @param _tierNames The names of each tier.
    function initialize(
        uint256 _gameId,
        string memory _gameName,
        string memory _gameSymbol,
        IJBRulesets _rulesets,
        string memory _baseUri,
        IJB721TokenUriResolver _tokenUriResolver,
        string memory _contractUri,
        JB721TierConfig[] memory _tiers,
        uint48 _currency,
        IJB721TiersHookStore _store,
        IDefifaGamePhaseReporter _gamePhaseReporter,
        IDefifaGamePotReporter _gamePotReporter,
        address _defaultAttestationDelegate,
        string[] memory _tierNames
    )
        public
        override
    {
        // Make the original un-initializable.
        if (address(this) == CODE_ORIGIN) revert();

        // Stop re-initialization.
        if (address(store) != address(0)) revert();

        // Store the game and collection identity.
        projectId = _gameId;
        _name = _gameName;
        _symbol = _gameSymbol;

        // Store stuff.
        rulesets = _rulesets;
        store = _store;
        pricingCurrency = _currency;
        gamePhaseReporter = _gamePhaseReporter;
        gamePotReporter = _gamePotReporter;
        defaultAttestationDelegate = _defaultAttestationDelegate;

        // Store the base URI if provided.
        if (bytes(_baseUri).length != 0) baseURI = _baseUri;

        // Set the contract URI if provided.
        if (bytes(_contractUri).length != 0) contractURI = _contractUri;

        // Set the token URI resolver if provided.
        if (_tokenUriResolver != IJB721TokenUriResolver(address(0))) {
            _store.recordSetTokenUriResolver(_tokenUriResolver);
        }

        // Record the provided tiers.
        _store.recordAddTiers(_tiers);

        // Keep a reference to the number of tier names.
        uint256 numberOfTierNames = _tierNames.length;

        // Set the name for each tier.
        for (uint256 i; i < numberOfTierNames;) {
            // Set the tier name.
            _tierNameOf[i + 1] = _tierNames[i];

            unchecked {
                ++i;
            }
        }

        // Transfer ownership to the initializer.
        _transferOwnership(msg.sender);
    }

    /// @notice Mint reserved positions within a tier.
    /// @param tierId The ID of the tier to mint within.
    /// @param count The number of reserved positions to mint.
    function mintReservesFor(uint256 tierId, uint256 count) public override {
        // Minting reserves must not be paused.
        if (JB721TiersRulesetMetadataResolver.mintPendingReservesPaused(_rulesetMetadata())) {
            revert Defifa1155Hook_ReservedTokenMintingPaused({projectId: projectId, tierId: tierId});
        }

        // Block reserve minting while the game is in NO_CONTEST. Reserve mints inflate `totalMintCost` (so reserved
        // recipients can claim fee tokens), which would otherwise let a game that failed `minParticipation` revive
        // back to SCORING via free notional face value before `triggerNoContestFor` latches the failure.
        if (_currentGamePhaseOf(projectId) == DefifaGamePhase.NO_CONTEST) {
            revert Defifa1155Hook_ReservedTokenMintingBlockedInNoContest({projectId: projectId, tierId: tierId});
        }

        // Cache the store reference in a local variable to avoid repeated SLOAD.
        IJB721TiersHookStore hookStore = store;

        // Keep a reference to the reserved token beneficiary.
        address reservedTokenBeneficiary = hookStore.reserveBeneficiaryOf({hook: address(this), tierId: tierId});

        // Cap count by the refund-adjusted pending reserves to prevent inflating totalMintCost
        // from already-refunded mints whose reserve liability no longer exists.
        uint256 adjusted = adjustedPendingReservesFor(tierId);
        if (count > adjusted) count = adjusted;

        // Nothing to mint, or no one to mint to. Returning before any delegation write keeps a call with nothing to
        // mint from setting delegation state, including for the zero address.
        if (count == 0 || reservedTokenBeneficiary == address(0)) return;

        // Set the delegate as the beneficiary if the beneficiary hasn't already set a delegate.
        if (_tierDelegation[reservedTokenBeneficiary][tierId] == address(0)) {
            _delegateTier({
                account: reservedTokenBeneficiary,
                delegatee: defaultAttestationDelegate != address(0)
                    ? defaultAttestationDelegate
                    : reservedTokenBeneficiary,
                tierId: tierId
            });
        }

        // Record the minted reserves for the tier. The store's 721 token numbers are not used.
        hookStore.recordMintReservesFor({tierId: tierId, count: count});

        // Fetch the tier details (needed for votingUnits below).
        JB721Tier memory tier = hookStore.tierOf({hook: address(this), id: tierId, includeResolvedUri: false});

        // Increment totalMintCost so reserved recipients can claim their share of fee tokens ($DEFIFA/$NANA).
        // Note: reserved mints dilute existing fee token claimants because they increase the total mint cost
        // denominator without contributing new funds to the fee token balances. This is the intended design —
        // reserved recipients receive a proportional claim on fee tokens as if they had paid to mint.
        totalMintCost += tier.price * count;

        emit MintReservedToken({
            tierId: tierId, beneficiary: reservedTokenBeneficiary, count: count, caller: msg.sender
        });

        // Transfer the attestation units to the delegate.
        _transferTierAttestationUnits({
            from: address(0), to: reservedTokenBeneficiary, tierId: tierId, amount: tier.votingUnits * count
        });

        // Mint the reserve-ID positions so refunds can reject them. The receiver callback runs last, after every
        // state change.
        uint256[] memory ids = new uint256[](1);
        uint256[] memory values = new uint256[](1);
        ids[0] = tierId + RESERVE_TOKEN_ID_OFFSET;
        values[0] = count;
        _mintWithAcceptanceCheck({to: reservedTokenBeneficiary, ids: ids, values: values});
    }

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Burns the specified positions upon holder cash-out, reclaiming funds from the project's balance for
    /// `context.beneficiary`. Part of `IJBCashOutHook`.
    /// @dev Reverts if the calling contract is not one of the project's terminals.
    /// @param context The cash-out context passed in by the terminal.
    function afterCashOutRecordedWith(JBAfterCashOutRecordedContext calldata context)
        external
        payable
        virtual
        override
    {
        // Make sure the caller is a terminal of the project, and that the call is being made on behalf of an
        // interaction with the correct project.
        uint256 localProjectId = projectId;

        if (msg.value != 0 || !_isProjectTerminal(localProjectId) || context.projectId != localProjectId) {
            revert Defifa1155Hook_InvalidCashOut({
                caller: msg.sender, contextProjectId: context.projectId, projectId: localProjectId, msgValue: msg.value
            });
        }

        // Fetch the cash-out hook metadata using the corresponding metadata ID.
        (bool metadataExists, bytes memory metadata) = JBMetadataResolver.getDataFor({
            id: JBMetadataResolver.getId({purpose: "cashOut", target: CODE_ORIGIN}), metadata: context.cashOutMetadata
        });

        if (!metadataExists) {
            revert();
        }

        // Decode the cash-out metadata: the token IDs and the number of positions of each.
        (uint256[] memory decodedTokenIds, uint256[] memory decodedAmounts) =
            abi.decode(metadata, (uint256[], uint256[]));

        // Make sure the holder owns every position being cashed out. Duplicate IDs are checked cumulatively by the
        // burn below.
        for (uint256 i; i < decodedTokenIds.length; i++) {
            uint256 balance = balanceOf(context.holder, decodedTokenIds[i]);
            if (balance < decodedAmounts[i]) {
                revert Defifa1155Hook_Unauthorized({
                    tokenId: decodedTokenIds[i], amount: decodedAmounts[i], balance: balance, holder: context.holder
                });
            }
        }

        // Keep track of whether the cashOut is happening during the complete phase.
        bool isComplete = _currentGamePhaseOf(localProjectId) == DefifaGamePhase.COMPLETE;

        // Burn the positions. Attestation units move out through `_update`.
        _burnBatch({from: context.holder, ids: decodedTokenIds, values: decodedAmounts});

        // Record the burns in the store and the per-tier redemption or refund counters.
        Defifa1155HookLib.recordBurns({
            tokenIds: decodedTokenIds,
            amounts: decodedAmounts,
            hookStore: IDefifaTiersHookStore(address(store)),
            isComplete: isComplete,
            tokensRedeemedFrom: tokensRedeemedFrom,
            refundedBurnsFrom: refundedBurnsFrom
        });

        // Decode the metadata passed by the hook.
        (uint256 cumulativeMintPrice) = abi.decode(context.hookMetadata, (uint256));

        // Increment the amount redeemed if this is the complete phase.
        bool beneficiaryReceivedTokens;
        if (isComplete) {
            amountRedeemed += context.reclaimedAmount.value;

            // Claim the $DEFIFA and $NANA tokens for the user.
            // Include pending reserve mint cost in the denominator so that unminted reserves
            // are accounted for, preventing paid holders from claiming a disproportionate share.
            beneficiaryReceivedTokens = _claimTokensFor({
                beneficiary: context.beneficiary,
                shareToBeneficiary: cumulativeMintPrice,
                outOfTotal: totalMintCost + _pendingReserveMintCost()
            });
        }

        // If there's nothing being claimed and we did not distribute fee tokens, revert to prevent burning for nothing.
        // Tokens in 0-weight tiers (losing teams) cannot burn to reclaim fees if no fee tokens were
        // distributed. This is correct behavior — 0-weight means the tier has no claim on the pot. Burning would
        // return 0 value regardless.
        if (context.reclaimedAmount.value == 0 && !beneficiaryReceivedTokens) {
            revert Defifa1155Hook_NothingToClaim({
                reclaimedAmount: context.reclaimedAmount.value, beneficiaryReceivedTokens: beneficiaryReceivedTokens
            });
        }

        // Decrement the paid mint cost by the cumulative mint price of the tokens being burned.
        totalMintCost -= cumulativeMintPrice;
    }

    /// @notice Mint reserved positions for multiple tiers.
    /// @param mintReservesForTiersData Contains information about how many reserved tokens to mint for each tier.
    function mintReservesFor(JB721TiersMintReservesConfig[] calldata mintReservesForTiersData) external override {
        // Keep a reference to the number of tiers to mint reserves for.
        uint256 numberOfTiers = mintReservesForTiersData.length;

        for (uint256 i; i < numberOfTiers;) {
            // Get a reference to the data being iterated on.
            JB721TiersMintReservesConfig memory data = mintReservesForTiersData[i];

            // Mint for the tier.
            mintReservesFor({tierId: data.tierId, count: data.count});

            unchecked {
                ++i;
            }
        }
    }

    /// @notice Stores the cashOut weights that should be used in the end game phase.
    /// @dev Only this contract's owner can set tier cashOut weights.
    /// @param tierWeights The tier weights to set.
    function setTierCashOutWeightsTo(DefifaTierCashOutWeight[] memory tierWeights) external override onlyOwner {
        // Get a reference to the game phase.
        uint256 localProjectId = projectId;
        DefifaGamePhase gamePhase = _currentGamePhaseOf(localProjectId);

        // Make sure the game has ended.
        if (gamePhase != DefifaGamePhase.SCORING) {
            revert Defifa1155Hook_GameIsntScoringYet({projectId: localProjectId, phase: gamePhase});
        }

        // Make sure the cashOut weights haven't already been set.
        if (cashOutWeightIsSet) revert Defifa1155Hook_CashoutWeightsAlreadySet({projectId: localProjectId});

        // Validate weights and build the array. Reverts on invalid input.
        _tierCashOutWeights =
            DefifaHookLib.validateAndBuildWeights({tierWeights: tierWeights, hookStore: store, hook: address(this)});

        // Mark the cashOut weight as set.
        cashOutWeightIsSet = true;

        emit TierCashOutWeightsSet({tierWeights: tierWeights, caller: msg.sender});
    }

    /// @notice Delegate this account's voting power for a single tier to a specified delegate.
    /// @param delegatee The account to delegate tier attestation units to.
    /// @param tierId The ID of the tier to delegate attestation units for.
    function setTierDelegateTo(address delegatee, uint256 tierId) public virtual override {
        // Make sure a delegate is specified.
        if (delegatee == address(0)) revert Defifa1155Hook_DelegateAddressZero({tierId: tierId});

        // Make sure the current game phase is the minting phase.
        uint256 localProjectId = projectId;
        DefifaGamePhase gamePhase = _currentGamePhaseOf(localProjectId);
        if (gamePhase != DefifaGamePhase.MINT) {
            revert Defifa1155Hook_DelegateChangesUnavailableInThisPhase({projectId: localProjectId, phase: gamePhase});
        }

        _delegateTier({account: msg.sender, delegatee: delegatee, tierId: tierId});
    }

    /// @notice Delegate this account's voting power across multiple tiers to specified delegates.
    /// @param delegations An array of tiers to set delegates for.
    function setTierDelegatesTo(DefifaDelegation[] memory delegations) external virtual override {
        // Make sure the current game phase is the minting phase.
        uint256 localProjectId = projectId;
        DefifaGamePhase gamePhase = _currentGamePhaseOf(localProjectId);
        if (gamePhase != DefifaGamePhase.MINT) {
            revert Defifa1155Hook_DelegateChangesUnavailableInThisPhase({projectId: localProjectId, phase: gamePhase});
        }

        // Keep a reference to the number of tier delegates.
        uint256 numberOfTierDelegates = delegations.length;

        // Keep a reference to the data being iterated on.
        DefifaDelegation memory data;

        for (uint256 i; i < numberOfTierDelegates;) {
            // Reference the data being iterated on.
            data = delegations[i];

            // Make sure a delegate is specified.
            if (data.delegatee == address(0)) revert Defifa1155Hook_DelegateAddressZero({tierId: data.tierId});

            _delegateTier({account: msg.sender, delegatee: data.delegatee, tierId: data.tierId});

            unchecked {
                ++i;
            }
        }
    }

    //*********************************************************************//
    // ---------------------- internal transactions ---------------------- //
    //*********************************************************************//

    /// @notice Claims the defifa and base protocol tokens for a beneficiary.
    /// @param beneficiary The address to claim tokens for.
    /// @param shareToBeneficiary The share relative to the `outOfTotal` to send the user.
    /// @param outOfTotal The total share that the `shareToBeneficiary` is relative to.
    /// @return beneficiaryReceivedTokens A flag indicating if the beneficiary received any tokens.
    function _claimTokensFor(
        address beneficiary,
        uint256 shareToBeneficiary,
        uint256 outOfTotal
    )
        internal
        returns (bool beneficiaryReceivedTokens)
    {
        return DefifaHookLib.claimTokensFor({
            beneficiary: beneficiary,
            shareToBeneficiary: shareToBeneficiary,
            outOfTotal: outOfTotal,
            defifaToken: DEFIFA_TOKEN,
            baseProtocolToken: BASE_PROTOCOL_TOKEN
        });
    }

    /// @notice Delegate all attestation units for the specified tier.
    /// @param account The account delegating tier attestation units.
    /// @param delegatee The account to delegate tier attestation units to.
    /// @param tierId The ID of the tier to transfer attestation units for.
    function _delegateTier(address account, address delegatee, uint256 tierId) internal virtual {
        // Get the current delegatee
        address oldDelegate = _tierDelegation[account][tierId];

        // Store the new delegatee
        _tierDelegation[account][tierId] = delegatee;

        emit DelegateChanged({delegator: account, fromDelegate: oldDelegate, toDelegate: delegatee, caller: msg.sender});

        // Move the attestations.
        _moveTierDelegateAttestations({
            from: oldDelegate,
            to: delegatee,
            tierId: tierId,
            amount: _getTierAttestationUnits({account: account, tierId: tierId})
        });
    }

    /// @notice Mints positions in the provided tiers.
    /// @param amount The amount to base the mints on. All mints' prices must fit in this amount.
    /// @param tierIds The tier IDs to mint, in strictly ascending order.
    /// @param counts The number of positions to mint in each tier.
    /// @param beneficiary The address to mint for.
    /// @return leftoverAmount The amount leftover after the mint.
    function _mintAll(
        uint256 amount,
        uint16[] memory tierIds,
        uint256[] memory counts,
        address beneficiary
    )
        internal
        returns (uint256 leftoverAmount)
    {
        // Record the mint: price, supply and reserve checks, once per tier.
        leftoverAmount =
            IDefifaTiersHookStore(address(store)).recordMintCounts({amount: amount, tierIds: tierIds, counts: counts});

        // Increment the paid mint cost.
        totalMintCost += amount;

        // Mint one balance per tier.
        uint256 numberOfTiers = tierIds.length;
        uint256[] memory tokenIds = new uint256[](numberOfTiers);
        for (uint256 i; i < numberOfTiers;) {
            tokenIds[i] = tierIds[i];

            emit Mint({
                tierId: tierIds[i],
                beneficiary: beneficiary,
                count: counts[i],
                totalAmountContributed: amount,
                caller: msg.sender
            });

            unchecked {
                ++i;
            }
        }

        // The receiver callback runs last, after every state change.
        _mintWithAcceptanceCheck({to: beneficiary, ids: tokenIds, values: counts});
    }

    /// @notice Mints positions, then runs the ERC-1155 receiver callback.
    /// @param to The address to mint to.
    /// @param ids The token IDs.
    /// @param values The number of positions of each token ID.
    function _mintWithAcceptanceCheck(address to, uint256[] memory ids, uint256[] memory values) internal {
        _update({from: address(0), to: to, ids: ids, values: values});
        Defifa1155HookLib.checkMintAcceptance({operator: _msgSender(), to: to, ids: ids, values: values});
    }

    /// @notice Moves delegated tier attestations from one delegate to another.
    /// @param from The account to transfer tier attestation units from.
    /// @param to The account to transfer tier attestation units to.
    /// @param tierId The ID of the tier to transfer attestation units for.
    /// @param amount The amount of attestation units to delegate.
    function _moveTierDelegateAttestations(address from, address to, uint256 tierId, uint256 amount) internal {
        // Nothing to do if moving to the same account, or no amount is being moved.
        if (from == to || amount == 0) return;

        // If not moving from the zero address, update the checkpoints to subtract the amount.
        if (from != address(0)) {
            // Get the current amount for the sending delegate.
            uint208 current = _delegateTierCheckpoints[from][tierId].latest();
            // Set the new amount for the sending delegate.
            // uint208 is sufficient for attestation values: each tier's attestation units are bounded by the position
            // supply (max ~999_999_999 per tier * 128 tiers), well within uint208's ~4.1e62 range.
            // forge-lint: disable-next-line(unsafe-typecast)
            (uint256 oldValue, uint256 newValue) = _delegateTierCheckpoints[from][tierId].push({
                // forge-lint: disable-next-line(unsafe-typecast)
                key: uint48(block.timestamp),
                // forge-lint: disable-next-line(unsafe-typecast)
                value: current - uint208(amount)
            });
            emit TierDelegateAttestationsChanged({
                delegate: from, tierId: tierId, previousBalance: oldValue, newBalance: newValue, caller: msg.sender
            });
        }

        // If not moving to the zero address, update the checkpoints to add the amount.
        if (to != address(0)) {
            // Get the current amount for the receiving delegate.
            uint208 current = _delegateTierCheckpoints[to][tierId].latest();
            // Set the new amount for the receiving delegate.
            // forge-lint: disable-next-line(unsafe-typecast)
            (uint256 oldValue, uint256 newValue) = _delegateTierCheckpoints[to][tierId].push({
                // forge-lint: disable-next-line(unsafe-typecast)
                key: uint48(block.timestamp),
                // forge-lint: disable-next-line(unsafe-typecast)
                value: current + uint208(amount)
            });
            emit TierDelegateAttestationsChanged({
                delegate: to, tierId: tierId, previousBalance: oldValue, newBalance: newValue, caller: msg.sender
            });
        }
    }

    /// @notice Process an incoming payment.
    /// @param context The Juicebox standard project payment data.
    function _processPayment(JBAfterPayRecordedContext calldata context) internal {
        // Make sure the game is being played in the correct currency.
        if (context.amount.currency != pricingCurrency) {
            revert Defifa1155Hook_WrongCurrency({
                expectedCurrency: pricingCurrency, actualCurrency: context.amount.currency
            });
        }

        // Resolve the metadata.
        (bool found, bytes memory metadata) = JBMetadataResolver.getDataFor({
            id: JBMetadataResolver.getId({purpose: "pay", target: CODE_ORIGIN}), metadata: context.payerMetadata
        });

        if (!found) revert Defifa1155Hook_NothingToMint({metadataFound: found, tierCount: 0});

        // Decode the metadata: the attestation delegate, the tiers to mint in ascending order, and a count per tier.
        (address attestationDelegate, uint16[] memory tierIdsToMint, uint256[] memory counts) =
            abi.decode(metadata, (address, uint16[], uint256[]));

        // Positions can't be minted to the zero address.
        if (context.beneficiary == address(0)) revert Defifa1155Hook_InvalidBeneficiary();

        // Set the beneficiary as the attestation delegate by default.
        if (attestationDelegate == address(0)) {
            attestationDelegate =
                defaultAttestationDelegate != address(0) ? defaultAttestationDelegate : context.beneficiary;
        }

        // Make sure something is being minted.
        if (tierIdsToMint.length == 0) {
            revert Defifa1155Hook_NothingToMint({metadataFound: found, tierCount: tierIdsToMint.length});
        }

        // Validate the tiers and counts, and compute the attestation units per tier.
        uint256[] memory attestationAmounts = Defifa1155HookLib.computeAttestationUnits({
            tierIds: tierIdsToMint, counts: counts, hookStore: store, hook: address(this)
        });

        // Apply attestation units for each tier.
        for (uint256 i; i < tierIdsToMint.length;) {
            uint256 tierId = tierIdsToMint[i];

            // Get a reference to the old delegate.
            address oldDelegate = _tierDelegation[context.beneficiary][tierId];

            // If there's either a new delegate or old delegate, set delegation and transfer units.
            if (attestationDelegate != address(0) || oldDelegate != address(0)) {
                // Delegation is beneficiary-owned state. A third-party payer can fund this mint, but
                // cannot overwrite the beneficiary's long-lived delegate preference through metadata.
                if (
                    context.payer == context.beneficiary && attestationDelegate != address(0)
                        && attestationDelegate != oldDelegate
                ) {
                    _delegateTier({account: context.beneficiary, delegatee: attestationDelegate, tierId: tierId});
                }

                // Transfer the attestation units.
                _transferTierAttestationUnits({
                    from: address(0), to: context.beneficiary, tierId: tierId, amount: attestationAmounts[i]
                });
            }

            unchecked {
                ++i;
            }
        }

        // Mint the positions.
        uint256 leftoverAmount = _mintAll({
            amount: context.amount.value, tierIds: tierIdsToMint, counts: counts, beneficiary: context.beneficiary
        });

        // Make sure the buyer isn't overspending.
        if (leftoverAmount != 0) revert Defifa1155Hook_Overspending({leftoverAmount: leftoverAmount});
    }

    /// @notice Transfers, mints, or burns tier attestation units. To register a mint, `from` should be zero. To
    /// register a burn, `to` should be zero. Total supply of attestation units will be adjusted with mints and burns.
    /// @param from The account to transfer tier attestation units from.
    /// @param to The account to transfer tier attestation units to.
    /// @param tierId The ID of the tier to transfer attestation units for.
    /// @param amount The amount of attestation units to delegate.
    function _transferTierAttestationUnits(address from, address to, uint256 tierId, uint256 amount) internal virtual {
        if (from == address(0) || to == address(0)) {
            // Get the current total for the tier.
            uint208 current = _totalTierCheckpoints[tierId].latest();

            // If minting, add to the total tier checkpoints.
            if (from == address(0)) {
                // Casting to uint208/uint48 is safe because attestation unit amounts are bounded by supply counts.
                // forge-lint: disable-next-line(unsafe-typecast)
                uint208 newValue = current + uint208(amount);
                // forge-lint: disable-next-line(unsafe-typecast)
                _totalTierCheckpoints[tierId].push({key: uint48(block.timestamp), value: newValue});
            }

            // If burning, subtract from the total tier checkpoints.
            if (to == address(0)) {
                // Casting to uint208/uint48 is safe because attestation unit amounts are bounded by supply counts.
                // forge-lint: disable-next-line(unsafe-typecast)
                uint208 newValue = current - uint208(amount);
                // forge-lint: disable-next-line(unsafe-typecast)
                _totalTierCheckpoints[tierId].push({key: uint48(block.timestamp), value: newValue});
            }
        }

        // Resolve the recipient's delegate. If the recipient has no delegate set, auto-delegate to themselves to
        // prevent attestation units from being permanently lost.
        // Note: delegation persists after token transfers. If Alice delegates to Bob, then transfers her token
        // to Carol, Carol's attestation units auto-delegate to Carol (not Bob). However, Alice's delegation
        // to Bob persists — if Alice later receives another token, her units still go to Bob. This matches
        // ERC5805Votes behavior where delegation is an account-level setting, not a token-level one.
        // Mints have no source delegate and burns no destination delegate: the zero address never holds delegation.
        address toDelegate = to == address(0) ? address(0) : _tierDelegation[to][tierId];
        if (toDelegate == address(0) && to != address(0)) {
            toDelegate = to;
            _tierDelegation[to][tierId] = to;
            emit DelegateChanged({delegator: to, fromDelegate: address(0), toDelegate: to, caller: msg.sender});
        }

        // Move delegated attestations.
        _moveTierDelegateAttestations({
            from: from == address(0) ? address(0) : _tierDelegation[from][tierId],
            to: toDelegate,
            tierId: tierId,
            amount: amount
        });
    }

    /// @notice Moves positions and the attestation units they carry.
    /// @dev Mints add attestation units where they are minted (`_processPayment`, `mintReservesFor`), so only transfers
    /// and burns move units here. Burns bypass the transfer pause. Every move, mints and burns included, is recorded in
    /// the store's per-holder tier balances.
    /// @param from The address the positions come from (zero for mints).
    /// @param to The address the positions go to (zero for burns).
    /// @param ids The token IDs (paid or reserve IDs).
    /// @param values The number of positions of each token ID.
    function _update(
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory values
    )
        internal
        virtual
        override
    {
        super._update({from: from, to: to, ids: ids, values: values});

        // Cache the store reference in a local variable to avoid repeated SLOAD.
        IJB721TiersHookStore hookStore = store;

        uint256 numberOfIds = ids.length;
        for (uint256 i; i < numberOfIds;) {
            // Zero-amount transfers move no units, and must not auto-delegate a recipient who received nothing.
            if (values[i] == 0) {
                unchecked {
                    ++i;
                }
                continue;
            }

            uint256 tierId = Defifa1155HookLib.tierIdOf(ids[i]);

            // Mints add attestation units where they are minted; transfers and burns move them here.
            if (from != address(0)) {
                JB721Tier memory tier = hookStore.tierOf({hook: address(this), id: tierId, includeResolvedUri: false});

                // Transfers must not be paused (burns are allowed).
                if (
                    to != address(0) && tier.flags.transfersPausable
                        && JB721TiersRulesetMetadataResolver.transfersPaused(_rulesetMetadata())
                ) {
                    revert Defifa1155Hook_TransfersPaused({projectId: projectId, tokenId: ids[i], from: from, to: to});
                }

                _transferTierAttestationUnits({
                    from: from, to: to, tierId: tierId, amount: tier.votingUnits * values[i]
                });
            }

            // Record the move in the store's per-holder tier balances after local delegation state is final.
            IDefifaTiersHookStore(address(hookStore))
                .recordTransferForTier({tierId: tierId, from: from, to: to, count: values[i]});

            unchecked {
                ++i;
            }
        }
    }

    //*********************************************************************//
    // -------------------------- internal views ------------------------- //
    //*********************************************************************//

    /// @notice Returns the current phase for the project.
    /// @param gameId The project ID to check.
    /// @return The current game phase.
    function _currentGamePhaseOf(uint256 gameId) internal view returns (DefifaGamePhase) {
        return gamePhaseReporter.currentGamePhaseOf(gameId);
    }

    /// @notice Gets the amount of attestation units an address has for a particular tier.
    /// @param account The account to get attestation units for.
    /// @param tierId The ID of the tier to get attestation units for.
    /// @return The attestation units.
    function _getTierAttestationUnits(address account, uint256 tierId) internal view virtual returns (uint256) {
        // The store's tier balance counts paid and reserve-minted positions alike.
        return store.tierVotingUnitsOf({hook: address(this), account: account, tierId: tierId});
    }

    /// @notice Returns whether the caller is a terminal for the project.
    /// @param gameId The project ID to check.
    /// @return True if the caller is a terminal of the project.
    function _isProjectTerminal(uint256 gameId) internal view returns (bool) {
        return DIRECTORY.isTerminalOf({projectId: gameId, terminal: IJBTerminal(msg.sender)});
    }

    /// @notice Computes the total mint cost of all pending (unminted) reserve positions across all tiers.
    /// @dev Used to include pending reserves in the fee token claim denominator so that paid holders
    /// cannot claim a disproportionate share before reserves are minted.
    /// @return cost The total mint cost of pending reserves.
    function _pendingReserveMintCost() internal view returns (uint256 cost) {
        return DefifaHookLib.pendingReserveMintCost({hookStore: store, hook: address(this)});
    }

    /// @notice Returns the current ruleset metadata for this project.
    /// @return The packed ruleset metadata.
    function _rulesetMetadata() internal view returns (uint256) {
        return JBRulesetMetadataResolver.metadata(rulesets.currentOf(projectId));
    }
}
