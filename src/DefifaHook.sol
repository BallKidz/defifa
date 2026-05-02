// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

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
import {JBCashOutHookSpecification} from "@bananapus/core-v6/src/structs/JBCashOutHookSpecification.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JB721Hook} from "@bananapus/721-hook-v6/src/abstract/JB721Hook.sol";
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
import {IDefifaHook} from "./interfaces/IDefifaHook.sol";
import {IDefifaGamePhaseReporter} from "./interfaces/IDefifaGamePhaseReporter.sol";
import {IDefifaGamePotReporter} from "./interfaces/IDefifaGamePotReporter.sol";
import {DefifaTierCashOutWeight} from "./structs/DefifaTierCashOutWeight.sol";
import {DefifaGamePhase} from "./enums/DefifaGamePhase.sol";
import {DefifaHookLib} from "./libraries/DefifaHookLib.sol";

/// @notice A hook that transforms Juicebox treasury interactions into a Defifa game.
contract DefifaHook is JB721Hook, Ownable, IDefifaHook {
    using Checkpoints for Checkpoints.Trace208;

    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    error DefifaHook_BadTierOrder();
    error DefifaHook_IdenticalTokens();
    error DefifaHook_DelegateAddressZero();
    error DefifaHook_DelegateChangesUnavailableInThisPhase();
    error DefifaHook_GameIsntScoringYet();
    error DefifaHook_InvalidTierId();
    error DefifaHook_InvalidCashoutWeights();
    error DefifaHook_NothingToClaim();
    error DefifaHook_NothingToMint();
    error DefifaHook_WrongCurrency();
    error DefifaHook_Overspending();
    error DefifaHook_CashoutWeightsAlreadySet();
    error DefifaHook_ReservedTokenMintingPaused();
    error DefifaHook_TransfersPaused();
    error DefifaHook_Unauthorized(uint256 tokenId, address owner, address caller);

    event PricingCurrencySet(uint256 currency, address caller);

    //*********************************************************************//
    // --------------------- public constant properties ------------------ //
    //*********************************************************************//

    /// @notice The total cashOut weight that can be divided among tiers.
    uint256 public constant override TOTAL_CASHOUT_WEIGHT = 1_000_000_000_000_000_000;

    //*********************************************************************//
    // -------------------- internal stored properties ------------------- //
    //*********************************************************************//

    /// @notice The cashOut weight for each tier.
    /// @dev Tiers are limited to ID 128
    uint256[128] internal _tierCashOutWeights;

    /// @notice The delegation status for each address and for each tier.
    /// _delegator The delegator.
    /// _tierId The ID of the tier being delegated.
    mapping(address => mapping(uint256 => address)) internal _tierDelegation;

    /// @notice The delegation checkpoints for each address and for each tier.
    /// _delegator The delegator.
    /// _tierId The ID of the tier being checked.
    mapping(address => mapping(uint256 => Checkpoints.Trace208)) internal _delegateTierCheckpoints;

    /// @notice The total delegation status for each tier.
    /// _tierId The ID of the tier being checked.
    mapping(uint256 => Checkpoints.Trace208) internal _totalTierCheckpoints;

    /// @notice The first owner of each token ID, stored on first transfer out.
    /// _tokenId The ID of the token to get the stored first owner of.
    mapping(uint256 => address) internal _firstOwnerOf;

    /// @notice The names of each tier.
    /// @dev _tierId The ID of the tier to get a name for.
    mapping(uint256 => string) internal _tierNameOf;

    /// @notice The cumulative mint price of all tokens (paid and reserved). Used as the denominator for fee token
    /// ($DEFIFA/$NANA) distribution.
    uint256 internal _totalMintCost;

    //*********************************************************************//
    // ---------------- public immutable stored properties --------------- //
    //*********************************************************************//

    /// @notice The $DEFIFA token that is expected to be issued from paying fees.
    IERC20 public immutable override DEFIFA_TOKEN;

    /// @notice The $BASE_PROTOCOL token that is expected to be issued from paying fees.
    IERC20 public immutable override BASE_PROTOCOL_TOKEN;

    //*********************************************************************//
    // --------------------- public stored properties -------------------- //
    //*********************************************************************//

    /// @notice The amount that has been redeemed from this game, refunds are not counted.
    uint256 public override amountRedeemed;

    /// @notice The common base for the tokenUri's
    string public override baseURI;

    /// @notice A flag indicating if the cashout weights has been set.
    bool public override cashOutWeightIsSet;

    /// @notice The address of the origin 'DefifaHook', used to check in the init if the contract is the original or not
    address public immutable override CODE_ORIGIN;

    /// @notice Contract metadata uri.
    string public override contractURI;

    /// @notice The address that'll be set as the attestation delegate by default.
    address public override defaultAttestationDelegate;

    /// @notice The contract reporting game phases.
    IDefifaGamePhaseReporter public override gamePhaseReporter;

    /// @notice The contract reporting the game pot.
    IDefifaGamePotReporter public override gamePotReporter;

    /// @notice Whether a token was minted through reserves (free) rather than paid for.
    /// @dev Reserve-minted tokens are excluded from refund calculations since no funds were contributed for them.
    mapping(uint256 tokenId => bool) public override isReserveMint;

    /// @notice The currency that is accepted when minting tier NFTs.
    uint256 public override pricingCurrency;

    /// @notice The number of tokens burned from a tier during non-COMPLETE phases (refund, no-contest).
    /// @dev Used to adjust pending reserve counts so reserves that correspond to refunded mints
    /// are excluded from the cash-out denominator.
    mapping(uint256 => uint256) public refundedBurnsFrom;

    /// @notice The contract storing all funding cycle configurations.
    IJBRulesets public override rulesets;

    /// @notice The contract that stores and manages the NFT's data.
    IJB721TiersHookStore public override store;

    /// @notice The amount of tokens that have been redeemed from a tier, refunds are not counted.
    /// @custom:param The tier from which tokens have been redeemed.
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
        uint256 refundBurns = refundedBurnsFrom[tierId];

        // If no refund burns, return the store's value directly.
        if (refundBurns == 0) return store.numberOfPendingReservesFor({hook: address(this), tierId: tierId});

        // Get the tier to access reserveFrequency and supply data.
        JB721Tier memory tier = store.tierOf({hook: address(this), id: tierId, includeResolvedUri: false});

        // No reserves if no reserve frequency.
        if (tier.reserveFrequency == 0) return 0;

        // Calculate the number of reserves already minted.
        uint256 reservesMinted = store.numberOfReservesMintedFor({hook: address(this), tierId: tierId});

        // Calculate non-reserve mints: initialSupply - remainingSupply - reservesMinted.
        uint256 nonReserveMints = tier.initialSupply - tier.remainingSupply - reservesMinted;

        // Subtract refund burns from non-reserve mints (burns can't exceed non-reserve mints).
        uint256 adjustedMints = nonReserveMints > refundBurns ? nonReserveMints - refundBurns : 0;

        // Recalculate available reserves: ceil(adjustedMints / reserveFrequency).
        uint256 availableReserves = adjustedMints / tier.reserveFrequency;
        if (adjustedMints % tier.reserveFrequency > 0) ++availableReserves;

        // Return pending = available - already minted (floored at 0).
        return availableReserves > reservesMinted ? availableReserves - reservesMinted : 0;
    }

    /// @notice The first owner of each token ID, which corresponds to the address that originally contributed to the
    /// project to receive the NFT.
    /// @param tokenId The ID of the token to get the first owner of.
    /// @return The first owner of the token.
    function firstOwnerOf(uint256 tokenId) external view override returns (address) {
        // Get a reference to the first owner.
        address storedFirstOwner = _firstOwnerOf[tokenId];

        // If the stored first owner is set, return it.
        if (storedFirstOwner != address(0)) return storedFirstOwner;

        // Otherwise, the first owner must be the current owner.
        return _owners[tokenId];
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

    /// @notice The name of the tier with the specified ID.
    /// @param tierId The ID of the tier.
    function tierNameOf(uint256 tierId) external view override returns (string memory) {
        return _tierNameOf[tierId];
    }

    //*********************************************************************//
    // -------------------------- public views --------------------------- //
    //*********************************************************************//

    /// @notice The data calculated before a cash out is recorded in the terminal store. This data is provided to the
    /// terminal's `cashOutTokensOf(...)` transaction.
    /// @dev Sets this contract as the cash out hook. Part of `IJBRulesetDataHook`.
    /// @dev This function is used for NFT cash outs, and will only be called if the project's ruleset has
    /// `useDataHookForCashOut` set to `true`.
    /// @param context The cash out context passed to this contract by the `cashOutTokensOf(...)` function.
    /// @return cashOutTaxRate The cash out tax rate influencing the reclaim amount.
    /// @return cashOutCount The amount of tokens that should be considered cashed out.
    /// @return totalSupply The total amount of tokens that are considered to be existing.
    /// @return effectiveSurplusValue The effective surplus value to use for the cash out.
    /// @return hookSpecifications The amount and data to send to cash out hooks (this contract) instead of returning to
    /// the beneficiary.
    function beforeCashOutRecordedWith(JBBeforeCashOutRecordedContext calldata context)
        public
        view
        virtual
        override(IJBRulesetDataHook, JB721Hook)
        returns (
            uint256 cashOutTaxRate,
            uint256 cashOutCount,
            uint256 totalSupply,
            uint256 effectiveSurplusValue,
            JBCashOutHookSpecification[] memory hookSpecifications
        )
    {
        // Make sure (fungible) project tokens aren't also being cashed out.
        if (context.cashOutCount > 0) revert JB721Hook_UnexpectedTokenCashedOut();

        // Fetch the cash out hook metadata using the corresponding metadata ID.
        (bool metadataExists, bytes memory metadata) = JBMetadataResolver.getDataFor({
            id: JBMetadataResolver.getId({purpose: "cashOut", target: CODE_ORIGIN}), metadata: context.metadata
        });

        uint256[] memory decodedTokenIds;

        // Decode the metadata.
        if (metadataExists) decodedTokenIds = abi.decode(metadata, (uint256[]));

        // Get the current game phase.
        DefifaGamePhase gamePhase = gamePhaseReporter.currentGamePhaseOf(context.projectId);

        // Cache the store reference in a local variable to avoid repeated SLOAD.
        IJB721TiersHookStore hookStore = store;

        // Calculate the amount paid to mint the tokens that are being burned.
        uint256 cumulativeMintPrice = DefifaHookLib.computeCumulativeMintPrice({
            tokenIds: decodedTokenIds, hookStore: hookStore, hook: address(this)
        });

        // During refund phases, exclude reserve-minted tokens — they were minted for free and have no paid amount
        // to refund.
        if (
            gamePhase == DefifaGamePhase.MINT || gamePhase == DefifaGamePhase.REFUND
                || gamePhase == DefifaGamePhase.NO_CONTEST
        ) {
            for (uint256 i; i < decodedTokenIds.length;) {
                if (isReserveMint[decodedTokenIds[i]]) {
                    // slither-disable-next-line calls-loop
                    cumulativeMintPrice -= hookStore.tierOfTokenId({
                        hook: address(this), tokenId: decodedTokenIds[i], includeResolvedUri: false
                    }).price;
                }

                unchecked {
                    ++i;
                }
            }
        }

        // Use this contract as the only cash out hook.
        hookSpecifications = new JBCashOutHookSpecification[](1);
        hookSpecifications[0] =
            JBCashOutHookSpecification({hook: this, noop: false, amount: 0, metadata: abi.encode(cumulativeMintPrice)});

        // Compute the cash out count based on the game phase.
        cashOutCount = DefifaHookLib.computeCashOutCount({
            gamePhase: gamePhase,
            cumulativeMintPrice: cumulativeMintPrice,
            surplusValue: context.surplus.value,
            totalAmountRedeemed: amountRedeemed,
            cumulativeCashOutWeight: cashOutWeightOf(decodedTokenIds)
        });

        // Use the surplus as the total supply.
        totalSupply = context.surplus.value;

        // Use the surplus as the effective surplus value.
        effectiveSurplusValue = context.surplus.value;

        // Use the cash out tax rate from the context.
        cashOutTaxRate = context.cashOutTaxRate;
    }

    /// @notice The cumulative weight the given token IDs have in cashOuts compared to the `totalCashOutWeight`.
    /// @param tokenIds The IDs of the tokens to get the cumulative cashOut weight of.
    /// @return cumulativeWeight The weight.
    function cashOutWeightOf(uint256[] memory tokenIds)
        public
        view
        virtual
        override
        returns (uint256 cumulativeWeight)
    {
        // Cache the store in a local variable to avoid repeated SLOAD.
        cumulativeWeight = DefifaHookLib.computeCashOutWeightBatch({
            tokenIds: tokenIds,
            hookStore: store,
            hook: address(this),
            tierCashOutWeights: _tierCashOutWeights,
            tokensRedeemedFrom: tokensRedeemedFrom
        });
    }

    /// @notice The weight the given token ID has in cashOuts.
    /// @param tokenId The ID of the token to get the cashOut weight of.
    /// @return The weight.
    function cashOutWeightOf(uint256 tokenId) public view override returns (uint256) {
        return DefifaHookLib.computeCashOutWeight({
            tokenId: tokenId,
            hookStore: store,
            hook: address(this),
            tierCashOutWeights: _tierCashOutWeights,
            tokensRedeemedFrom: tokensRedeemedFrom
        });
    }

    /// @notice The amount of tokens of a tier that are currently in circulation.
    /// @param tierId The ID of the tier to get the current supply of.
    /// @return The current supply count.
    function currentSupplyOfTier(uint256 tierId) public view returns (uint256) {
        return DefifaHookLib.computeCurrentSupply({hookStore: store, hook: address(this), tierId: tierId});
    }

    /// @notice Indicates if this contract adheres to the specified interface.
    /// @dev See {IERC165-supportsInterface}.
    /// @param interfaceId The ID of the interface to check for adherence to.
    function supportsInterface(bytes4 interfaceId) public view override(JB721Hook, IERC165) returns (bool) {
        return interfaceId == type(IDefifaHook).interfaceId || super.supportsInterface(interfaceId);
    }

    /// @notice The amount of $DEFIFA and $BASE_PROTOCOL tokens this game was allocated from paying the network fee.
    /// @return defifaTokenAllocation The $DEFIFA token allocation.
    /// @return baseProtocolTokenAllocation The $BASE_PROTOCOL token allocation.
    function tokenAllocations()
        public
        view
        returns (uint256 defifaTokenAllocation, uint256 baseProtocolTokenAllocation)
    {
        defifaTokenAllocation = DEFIFA_TOKEN.balanceOf(address(this));
        baseProtocolTokenAllocation = BASE_PROTOCOL_TOKEN.balanceOf(address(this));
    }

    /// @notice The metadata URI of the provided token ID.
    /// @dev Defer to the tokenUriResolver if set, otherwise, use the tokenUri set with the token's tier.
    /// @param tokenId The ID of the token to get the tier URI for.
    /// @return The token URI corresponding with the tier or the tokenUriResolver URI.
    function tokenURI(uint256 tokenId) public view virtual override returns (string memory) {
        // Use the resolver.
        return store.tokenUriResolverOf(address(this)).tokenUriOf(address(this), tokenId);
    }

    /// @notice The amount of $DEFIFA and $BASE_PROTOCOL tokens claimable for a set of token IDs.
    /// @param tokenIds The IDs of the tokens that justify a $DEFIFA claim.
    /// @return defifaTokenAmount The amount of $DEFIFA that can be claimed.
    /// @return baseProtocolTokenAmount The amount of $BASE_PROTOCOL that can be claimed.
    function tokensClaimableFor(uint256[] memory tokenIds)
        public
        view
        returns (uint256 defifaTokenAmount, uint256 baseProtocolTokenAmount)
    {
        // If the game isn't complete, we do not have any tokens to claim.
        if (gamePhaseReporter.currentGamePhaseOf(PROJECT_ID) != DefifaGamePhase.COMPLETE) return (0, 0);

        // slither-disable-next-line unused-return
        return DefifaHookLib.computeTokensClaim({
            tokenIds: tokenIds,
            hookStore: store,
            hook: address(this),
            totalMintCost: _totalMintCost + _pendingReserveMintCost(),
            defifaBalance: DEFIFA_TOKEN.balanceOf(address(this)),
            baseProtocolBalance: BASE_PROTOCOL_TOKEN.balanceOf(address(this))
        });
    }

    /// @notice The combined cash out weight of all outstanding NFTs.
    /// @dev An NFT's cash out weight is its price.
    /// @return The total cash out weight.
    function totalCashOutWeight() public view virtual override returns (uint256) {
        return TOTAL_CASHOUT_WEIGHT;
    }

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    /// @dev The initial owner is msg.sender; ownership is transferred to the governor after initialization.
    constructor(
        IJBDirectory _directory,
        IERC20 _defifaToken,
        IERC20 _baseProtocolToken
    )
        JB721Hook(_directory)
        Ownable(msg.sender)
    {
        if (address(_defifaToken) == address(_baseProtocolToken)) revert DefifaHook_IdenticalTokens();

        CODE_ORIGIN = address(this);
        DEFIFA_TOKEN = _defifaToken;
        BASE_PROTOCOL_TOKEN = _baseProtocolToken;
    }

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Mints one or more NFTs to the `context.beneficiary` upon payment if conditions are met.
    /// @dev Reverts if the calling contract is not one of the project's terminals.
    /// @param context The payment context passed in by the terminal.
    // slither-disable-next-line locked-ether
    function afterPayRecordedWith(JBAfterPayRecordedContext calldata context)
        external
        payable
        virtual
        override(IJBPayHook, JB721Hook)
    {
        uint256 projectId = PROJECT_ID;

        // Make sure the caller is a terminal of the project, and that the call is being made on behalf of an
        // interaction with the correct project.
        if (
            msg.value != 0 || !DIRECTORY.isTerminalOf({projectId: projectId, terminal: IJBTerminal(msg.sender)})
                || context.projectId != projectId
        ) revert JB721Hook_InvalidPay();

        // Process the payment.
        _processPayment(context);
    }

    //*********************************************************************//
    // ----------------------- public transactions ----------------------- //
    //*********************************************************************//

    /// @notice Initialize a clone of this contract.
    /// @param _gameId The ID of the project this contract's functionality applies to.
    /// @param _name The name of the token.
    /// @param _symbol The symbol that the token should be represented by.
    /// @param _rulesets A contract storing all ruleset configurations.
    /// @param _baseUri A URI to use as a base for full token URIs.
    /// @param _tokenUriResolver A contract responsible for resolving the token URI for each token ID.
    /// @param _contractUri A URI where contract metadata can be found.
    /// @param _tiers The tiers to set.
    /// @param _currency The currency that the tier contribution floors are denoted in.
    /// @param _store A contract that stores the NFT's data.
    /// @param _gamePhaseReporter The contract that reports the game phase.
    /// @param _gamePotReporter The contract that reports the game's pot.
    /// @param _defaultAttestationDelegate The address that'll be set as the attestation delegate by default.
    /// @param _tierNames The names of each tier.
    function initialize(
        uint256 _gameId,
        string memory _name,
        string memory _symbol,
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

        // Initialize the superclass.
        _initialize({projectId: _gameId, name: _name, symbol: _symbol});

        // Store stuff.
        rulesets = _rulesets;
        store = _store;
        pricingCurrency = _currency;
        gamePhaseReporter = _gamePhaseReporter;
        gamePotReporter = _gamePotReporter;
        // slither-disable-next-line missing-zero-check
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
        // slither-disable-next-line unused-return
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

        emit PricingCurrencySet(_currency, msg.sender);
    }

    /// @notice Mint reserved tokens within the tier for the provided value.
    /// @param tierId The ID of the tier to mint within.
    /// @param count The number of reserved tokens to mint.
    function mintReservesFor(uint256 tierId, uint256 count) public override {
        // Minting reserves must not be paused.
        // slither-disable-next-line calls-loop
        if (JB721TiersRulesetMetadataResolver.mintPendingReservesPaused(
                (JBRulesetMetadataResolver.metadata(rulesets.currentOf(PROJECT_ID)))
            )) revert DefifaHook_ReservedTokenMintingPaused();

        // Cache the store reference in a local variable to avoid repeated SLOAD.
        IJB721TiersHookStore hookStore = store;

        // Keep a reference to the reserved token beneficiary.
        // slither-disable-next-line calls-loop
        address reservedTokenBeneficiary = hookStore.reserveBeneficiaryOf({hook: address(this), tierId: tierId});

        // Get a reference to the old delegate.
        address oldDelegate = _tierDelegation[reservedTokenBeneficiary][tierId];

        // Set the delegate as the beneficiary if the beneficiary hasn't already set a delegate.
        if (oldDelegate == address(0)) {
            _delegateTier({
                account: reservedTokenBeneficiary,
                delegatee: defaultAttestationDelegate != address(0)
                    ? defaultAttestationDelegate
                    : reservedTokenBeneficiary,
                tierId: tierId
            });
        }

        // Record the minted reserves for the tier.
        // slither-disable-next-line calls-loop
        uint256[] memory tokenIds = hookStore.recordMintReservesFor({tierId: tierId, count: count});

        // Keep a reference to the token ID being iterated on.
        uint256 tokenId;

        // Fetch the tier details (needed for votingUnits below).
        // slither-disable-next-line calls-loop
        JB721Tier memory tier = hookStore.tierOf({hook: address(this), id: tierId, includeResolvedUri: false});

        // Increment _totalMintCost so reserved recipients can claim their share of fee tokens ($DEFIFA/$NANA).
        // Note: reserved mints dilute existing fee token claimants because they increase the total mint cost
        // denominator without contributing new funds to the fee token balances. This is the intended design —
        // reserved recipients receive a proportional claim on fee tokens as if they had paid to mint.
        // slither-disable-next-line reentrancy-benign
        _totalMintCost += tier.price * count;

        for (uint256 i; i < count;) {
            // Set the token ID.
            tokenId = tokenIds[i];

            // Flag this token as reserve-minted so it is excluded from refund calculations.
            isReserveMint[tokenId] = true;

            // Mint the token to the reserve beneficiary.
            // slither-disable-next-line reentrancy-no-eth
            _mint({to: reservedTokenBeneficiary, tokenId: tokenId});

            emit MintReservedToken(tokenId, tierId, reservedTokenBeneficiary, msg.sender);

            unchecked {
                ++i;
            }
        }

        // Transfer the attestation units to the delegate.
        // slither-disable-next-line reentrancy-no-eth
        _transferTierAttestationUnits({
            from: address(0), to: reservedTokenBeneficiary, tierId: tierId, amount: tier.votingUnits * tokenIds.length
        });
    }

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Burns the specified NFTs upon token holder cash out, reclaiming funds from the project's balance for
    /// `context.beneficiary`. Part of `IJBCashOutHook`.
    /// @dev Reverts if the calling contract is not one of the project's terminals.
    /// @param context The cash out context passed in by the terminal.
    function afterCashOutRecordedWith(JBAfterCashOutRecordedContext calldata context)
        external
        payable
        virtual
        override(IJBCashOutHook, JB721Hook)
    {
        // Make sure the caller is a terminal of the project, and that the call is being made on behalf of an
        // interaction with the correct project.
        if (
            msg.value != 0 || !DIRECTORY.isTerminalOf({projectId: PROJECT_ID, terminal: IJBTerminal(msg.sender)})
                || context.projectId != PROJECT_ID
        ) revert JB721Hook_InvalidCashOut();

        // Fetch the cash out hook metadata using the corresponding metadata ID.
        (bool metadataExists, bytes memory metadata) = JBMetadataResolver.getDataFor({
            id: JBMetadataResolver.getId({purpose: "cashOut", target: METADATA_ID_TARGET}),
            metadata: context.cashOutMetadata
        });

        if (!metadataExists) {
            revert();
        }

        // Decode the CashOut metadata.
        (uint256[] memory decodedTokenIds) = abi.decode(metadata, (uint256[]));

        // Get a reference to the number of token IDs being checked.
        uint256 numberOfTokenIds = decodedTokenIds.length;

        // Keep a reference to the token ID being iterated on.
        uint256 tokenId;

        // Keep track of whether the cashOut is happening during the complete phase.
        bool isComplete = gamePhaseReporter.currentGamePhaseOf(PROJECT_ID) == DefifaGamePhase.COMPLETE;

        // Cache the store reference in a local variable to avoid repeated SLOAD in the loop.
        IJB721TiersHookStore hookStore = store;

        // Iterate through all tokens, burning them if the owner is correct.
        for (uint256 i; i < numberOfTokenIds;) {
            // Set the token's ID.
            tokenId = decodedTokenIds[i];

            // Make sure the token's owner is correct.
            address tokenOwner = _ownerOf(tokenId);
            if (tokenOwner != context.holder) {
                revert DefifaHook_Unauthorized({tokenId: tokenId, owner: tokenOwner, caller: context.holder});
            }

            // Burn the token.
            // slither-disable-next-line reentrancy-no-eth
            _burn(tokenId);

            // slither-disable-next-line calls-loop
            uint256 tierId = hookStore.tierIdOfToken(tokenId);
            if (isComplete) {
                // Track per-tier redemptions during the complete phase.
                unchecked {
                    ++tokensRedeemedFrom[tierId];
                }
            } else {
                // Track non-COMPLETE burns (refund/no-contest) so pending reserve counts can be adjusted.
                unchecked {
                    ++refundedBurnsFrom[tierId];
                }
            }

            unchecked {
                ++i;
            }
        }

        // Call the hook.
        _didBurn(decodedTokenIds);

        // Decode the metadata passed by the hook.
        (uint256 cumulativeMintPrice) = abi.decode(context.hookMetadata, (uint256));

        // Increment the amount redeemed if this is the complete phase.
        bool beneficiaryReceivedTokens;
        if (isComplete) {
            // slither-disable-next-line reentrancy-benign
            amountRedeemed += context.reclaimedAmount.value;

            // Claim the $DEFIFA and $NANA tokens for the user.
            // Include pending reserve mint cost in the denominator so that unminted reserves
            // are accounted for, preventing paid holders from claiming a disproportionate share.
            // slither-disable-next-line reentrancy-events
            beneficiaryReceivedTokens = _claimTokensFor({
                beneficiary: context.beneficiary,
                shareToBeneficiary: cumulativeMintPrice,
                outOfTotal: _totalMintCost + _pendingReserveMintCost()
            });
        }

        // If there's nothing being claimed and we did not distribute fee tokens, revert to prevent burning for nothing.
        // Tokens in 0-weight tiers (losing teams) cannot burn to reclaim fees if no fee tokens were
        // distributed. This is correct behavior — 0-weight means the tier has no claim on the pot. Burning would
        // return 0 value regardless.
        if (context.reclaimedAmount.value == 0 && !beneficiaryReceivedTokens) revert DefifaHook_NothingToClaim();

        // Decrement the paid mint cost by the cumulative mint price of the tokens being burned.
        // slither-disable-next-line reentrancy-benign
        _totalMintCost -= cumulativeMintPrice;
    }

    /// @notice Mint reserved tokens within the tier for the provided value.
    /// @param mintReservesForTiersData Contains information about how many reserved tokens to mint for each tier.
    function mintReservesFor(JB721TiersMintReservesConfig[] calldata mintReservesForTiersData) external override {
        // Keep a reference to the number of tiers there are to mint reserves for.
        uint256 numberOfTiers = mintReservesForTiersData.length;

        for (uint256 i; i < numberOfTiers;) {
            // Get a reference to the data being iterated on.
            JB721TiersMintReservesConfig memory data = mintReservesForTiersData[i];

            // Mint for the tier.
            mintReservesFor(data.tierId, data.count);

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
        DefifaGamePhase gamePhase = gamePhaseReporter.currentGamePhaseOf(PROJECT_ID);

        // Make sure the game has ended.
        if (gamePhase != DefifaGamePhase.SCORING) {
            revert DefifaHook_GameIsntScoringYet();
        }

        // Make sure the cashOut weights haven't already been set.
        if (cashOutWeightIsSet) revert DefifaHook_CashoutWeightsAlreadySet();

        // Validate weights and build the array. Reverts on invalid input.
        _tierCashOutWeights =
            DefifaHookLib.validateAndBuildWeights({tierWeights: tierWeights, hookStore: store, hook: address(this)});

        // Mark the cashOut weight as set.
        cashOutWeightIsSet = true;

        emit TierCashOutWeightsSet(tierWeights, msg.sender);
    }

    /// @notice Delegate attestations.
    /// @param delegatee The account to delegate tier attestation units to.
    /// @param tierId The ID of the tier to delegate attestation units for.
    function setTierDelegateTo(address delegatee, uint256 tierId) public virtual override {
        // Make sure a delegate is specified.
        if (delegatee == address(0)) revert DefifaHook_DelegateAddressZero();

        // Make sure the current game phase is the minting phase.
        if (gamePhaseReporter.currentGamePhaseOf(PROJECT_ID) != DefifaGamePhase.MINT) {
            revert DefifaHook_DelegateChangesUnavailableInThisPhase();
        }

        _delegateTier({account: msg.sender, delegatee: delegatee, tierId: tierId});
    }

    /// @notice Delegate attestations.
    /// @param delegations An array of tiers to set delegates for.
    function setTierDelegatesTo(DefifaDelegation[] memory delegations) external virtual override {
        // Make sure the current game phase is the minting phase.
        if (gamePhaseReporter.currentGamePhaseOf(PROJECT_ID) != DefifaGamePhase.MINT) {
            revert DefifaHook_DelegateChangesUnavailableInThisPhase();
        }

        // Keep a reference to the number of tier delegates.
        uint256 numberOfTierDelegates = delegations.length;

        // Keep a reference to the data being iterated on.
        DefifaDelegation memory data;

        for (uint256 i; i < numberOfTierDelegates;) {
            // Reference the data being iterated on.
            data = delegations[i];

            // Make sure a delegate is specified.
            if (data.delegatee == address(0)) revert DefifaHook_DelegateAddressZero();

            _delegateTier({account: msg.sender, delegatee: data.delegatee, tierId: data.tierId});

            unchecked {
                ++i;
            }
        }
    }

    //*********************************************************************//
    // ------------------------ internal functions ----------------------- //
    //*********************************************************************//

    /// @notice Computes the total mint cost of all pending (unminted) reserve NFTs across all tiers.
    /// @dev Used to include pending reserves in the fee token claim denominator so that paid holders
    /// cannot claim a disproportionate share before reserves are minted.
    /// @return cost The total mint cost of pending reserves.
    function _pendingReserveMintCost() internal view returns (uint256 cost) {
        IJB721TiersHookStore hookStore = store;
        uint256 numberOfTiers = hookStore.maxTierIdOf(address(this));

        for (uint256 i; i < numberOfTiers;) {
            uint256 tierId = i + 1;
            uint256 pendingReserves = adjustedPendingReservesFor(tierId);
            if (pendingReserves != 0) {
                // slither-disable-next-line calls-loop
                JB721Tier memory tier = hookStore.tierOf({hook: address(this), id: tierId, includeResolvedUri: false});
                cost += pendingReserves * tier.price;
            }
            unchecked {
                ++i;
            }
        }
    }

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
    /// @param tierId The ID of the tier for which attestation units are being transferred.
    function _delegateTier(address account, address delegatee, uint256 tierId) internal virtual {
        // Get the current delegatee
        address oldDelegate = _tierDelegation[account][tierId];

        // Store the new delegatee
        _tierDelegation[account][tierId] = delegatee;

        emit DelegateChanged(account, oldDelegate, delegatee);

        // Move the attestations.
        _moveTierDelegateAttestations({
            from: oldDelegate,
            to: delegatee,
            tierId: tierId,
            amount: _getTierAttestationUnits({account: account, tierId: tierId})
        });
    }

    /// @notice A function that will run when tokens are burned via cashOut.
    /// @param tokenIds The IDs of the tokens that were burned.
    function _didBurn(uint256[] memory tokenIds) internal virtual override {
        // Add to burned counter.
        store.recordBurn(tokenIds);
    }

    /// @notice Gets the amount of attestation units an address has for a particular tier.
    /// @param account The account to get attestation units for.
    /// @param tierId The ID of the tier to get attestation units for.
    /// @return The attestation units.
    function _getTierAttestationUnits(address account, uint256 tierId) internal view virtual returns (uint256) {
        // slither-disable-next-line calls-loop
        return store.tierVotingUnitsOf({hook: address(this), account: account, tierId: tierId});
    }

    /// @notice Mints a token in all provided tiers.
    /// @param amount The amount to base the mints on. All mints' price floors must fit in this amount.
    /// @param mintTierIds An array of tier IDs that are intended to be minted.
    /// @param beneficiary The address to mint for.
    /// @return leftoverAmount The amount leftover after the mint.
    function _mintAll(
        uint256 amount,
        uint16[] memory mintTierIds,
        address beneficiary
    )
        internal
        returns (uint256 leftoverAmount)
    {
        // Keep a reference to the token ID.
        uint256[] memory tokenIds;

        // Record the mint. The returned token IDs correspond to the tiers passed in.
        // slither-disable-next-line unused-return,reentrancy-benign
        (tokenIds, leftoverAmount,) = store.recordMint({
            amount: amount,
            tierIds: mintTierIds,
            isOwnerMint: false // Not a manual mint
        });

        // Get a reference to the number of mints.
        uint256 mintsLength = tokenIds.length;

        // Keep a reference to the token ID being iterated on.
        uint256 tokenId;

        // Increment the paid mint cost.
        _totalMintCost += amount;

        // Loop through each token ID and mint.
        for (uint256 i; i < mintsLength;) {
            // Get a reference to the tier being iterated on.
            tokenId = tokenIds[i];

            // Mint the tokens.
            _mint({to: beneficiary, tokenId: tokenId});

            emit Mint(tokenId, mintTierIds[i], beneficiary, amount, msg.sender);

            unchecked {
                ++i;
            }
        }
    }

    /// @notice Moves delegated tier attestations from one delegate to another.
    /// @param from The account to transfer tier attestation units from.
    /// @param to The account to transfer tier attestation units to.
    /// @param tierId The ID of the tier for which attestation units are being transferred.
    /// @param amount The amount of attestation units to delegate.
    function _moveTierDelegateAttestations(address from, address to, uint256 tierId, uint256 amount) internal {
        // Nothing to do if moving to the same account, or no amount is being moved.
        if (from == to || amount == 0) return;

        // If not moving from the zero address, update the checkpoints to subtract the amount.
        if (from != address(0)) {
            // Get the current amount for the sending delegate.
            uint208 current = _delegateTierCheckpoints[from][tierId].latest();
            // Set the new amount for the sending delegate.
            // uint208 is sufficient for attestation values: each tier's attestation units are bounded by the NFT
            // supply (max ~999_999_999 per tier * 128 tiers), well within uint208's ~4.1e62 range.
            // forge-lint: disable-next-line(unsafe-typecast)
            (uint256 oldValue, uint256 newValue) = _delegateTierCheckpoints[from][tierId].push({
                // forge-lint: disable-next-line(unsafe-typecast)
                key: uint48(block.timestamp),
                // forge-lint: disable-next-line(unsafe-typecast)
                value: current - uint208(amount)
            });
            emit TierDelegateAttestationsChanged(from, tierId, oldValue, newValue, msg.sender);
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
            emit TierDelegateAttestationsChanged(to, tierId, oldValue, newValue, msg.sender);
        }
    }

    /// @notice Process an incoming payment.
    /// @param context The Juicebox standard project payment data.
    function _processPayment(JBAfterPayRecordedContext calldata context) internal override {
        // Make sure the game is being played in the correct currency.
        if (context.amount.currency != pricingCurrency) revert DefifaHook_WrongCurrency();

        // Resolve the metadata.
        (bool found, bytes memory metadata) = JBMetadataResolver.getDataFor({
            id: JBMetadataResolver.getId({purpose: "pay", target: CODE_ORIGIN}), metadata: context.payerMetadata
        });

        if (!found) revert DefifaHook_NothingToMint();

        // Decode the metadata.
        (address attestationDelegate, uint16[] memory tierIdsToMint) = abi.decode(metadata, (address, uint16[]));

        // Set the beneficiary as the attestation delegate by default.
        if (attestationDelegate == address(0)) {
            attestationDelegate =
                defaultAttestationDelegate != address(0) ? defaultAttestationDelegate : context.beneficiary;
        }

        // Make sure something is being minted.
        if (tierIdsToMint.length == 0) revert DefifaHook_NothingToMint();

        // Compute attestation units per unique tier (validates ascending order, reverts on bad order).
        (uint256[] memory tierIds, uint256[] memory attestationAmounts, uint256 uniqueTierCount) =
            DefifaHookLib.computeAttestationUnits({tierIdsToMint: tierIdsToMint, hookStore: store, hook: address(this)});

        // Apply attestation units for each unique tier.
        for (uint256 i; i < uniqueTierCount;) {
            uint256 tierId = tierIds[i];

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

        // Mint tiers if they were specified.
        uint256 leftoverAmount =
            _mintAll({amount: context.amount.value, mintTierIds: tierIdsToMint, beneficiary: context.beneficiary});

        // Make sure the buyer isn't overspending.
        if (leftoverAmount != 0) revert DefifaHook_Overspending();
    }

    /// @notice Transfers, mints, or burns tier attestation units. To register a mint, `from` should be zero. To
    /// register a burn, `to` should be zero. Total supply of attestation units will be adjusted with mints and burns.
    /// @param from The account to transfer tier attestation units from.
    /// @param to The account to transfer tier attestation units to.
    /// @param tierId The ID of the tier for which attestation units are being transferred.
    /// @param amount The amount of attestation units to delegate.
    function _transferTierAttestationUnits(address from, address to, uint256 tierId, uint256 amount) internal virtual {
        if (from == address(0) || to == address(0)) {
            // Get the current total for the tier.
            uint208 current = _totalTierCheckpoints[tierId].latest();

            // If minting, add to the total tier checkpoints.
            if (from == address(0)) {
                // Casting to uint208/uint48 is safe because attestation unit amounts are bounded by NFT supply counts.
                // forge-lint: disable-next-line(unsafe-typecast)
                uint208 newValue = current + uint208(amount);
                // forge-lint: disable-next-line(unsafe-typecast)
                // slither-disable-next-line unused-return
                _totalTierCheckpoints[tierId].push({key: uint48(block.timestamp), value: newValue});
            }

            // If burning, subtract from the total tier checkpoints.
            if (to == address(0)) {
                // Casting to uint208/uint48 is safe because attestation unit amounts are bounded by NFT supply counts.
                // forge-lint: disable-next-line(unsafe-typecast)
                uint208 newValue = current - uint208(amount);
                // forge-lint: disable-next-line(unsafe-typecast)
                // slither-disable-next-line unused-return
                _totalTierCheckpoints[tierId].push({key: uint48(block.timestamp), value: newValue});
            }
        }

        // Resolve the recipient's delegate. If the recipient has no delegate set, auto-delegate to themselves to
        // prevent attestation units from being permanently lost.
        // Note: delegation persists after token transfers. If Alice delegates to Bob, then transfers her token
        // to Carol, Carol's attestation units auto-delegate to Carol (not Bob). However, Alice's delegation
        // to Bob persists — if Alice later receives another token, her units still go to Bob. This matches
        // ERC5805Votes behavior where delegation is an account-level setting, not a token-level one.
        address toDelegate = _tierDelegation[to][tierId];
        if (toDelegate == address(0) && to != address(0)) {
            toDelegate = to;
            _tierDelegation[to][tierId] = to;
            emit DelegateChanged(to, address(0), to);
        }

        // Move delegated attestations.
        _moveTierDelegateAttestations({
            from: _tierDelegation[from][tierId], to: toDelegate, tierId: tierId, amount: amount
        });
    }

    /// @notice Before transferring an NFT, register its first owner (if necessary).
    /// @param to The address the NFT is being transferred to.
    /// @param tokenId The token ID of the NFT being transferred.
    /// @param auth The address authorizing the transfer.
    /// @return from The address the token was transferred from.
    function _update(address to, uint256 tokenId, address auth) internal virtual override returns (address from) {
        // Cache the store reference in a local variable to avoid repeated SLOAD.
        IJB721TiersHookStore hookStore = store;

        // Get a reference to the tier.
        // slither-disable-next-line calls-loop
        JB721Tier memory tier =
            hookStore.tierOfTokenId({hook: address(this), tokenId: tokenId, includeResolvedUri: false});

        // Record the transfers and keep a reference to where the token is coming from.
        from = super._update(to, tokenId, auth);

        // Transfers must not be paused (when not minting or burning).
        if (from != address(0)) {
            // If transfers are pausable, check if they're paused.
            if (tier.flags.transfersPausable) {
                // Get a reference to the project's current ruleset.
                // slither-disable-next-line calls-loop
                JBRuleset memory ruleset = rulesets.currentOf(PROJECT_ID);

                // If transfers are paused and the NFT isn't being transferred to the zero address, revert.
                if (
                    to != address(0)
                        && JB721TiersRulesetMetadataResolver.transfersPaused(
                            (JBRulesetMetadataResolver.metadata(ruleset))
                        )
                ) revert DefifaHook_TransfersPaused();
            }

            // If the token isn't already associated with a first owner, store the sender as the first owner.
            // slither-disable-next-line calls-loop
            if (_firstOwnerOf[tokenId] == address(0)) _firstOwnerOf[tokenId] = from;
        }

        // Dont transfer on mint since the delegation will be transferred more efficiently in _processPayment.
        if (from != address(0)) {
            _transferTierAttestationUnits({from: from, to: to, tierId: tier.id, amount: tier.votingUnits});
        }

        // Record the transfer after local delegation state has been finalized.
        // slither-disable-next-line calls-loop
        hookStore.recordTransferForTier({tierId: tier.id, from: from, to: to});

        return from;
    }
}
