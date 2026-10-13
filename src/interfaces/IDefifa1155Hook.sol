// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IJB721TiersHookStore} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHookStore.sol";
import {IJB721TokenUriResolver} from "@bananapus/721-hook-v6/src/interfaces/IJB721TokenUriResolver.sol";
import {JB721TierConfig} from "@bananapus/721-hook-v6/src/structs/JB721TierConfig.sol";
import {JB721TiersMintReservesConfig} from "@bananapus/721-hook-v6/src/structs/JB721TiersMintReservesConfig.sol";
import {IJBCashOutHook} from "@bananapus/core-v6/src/interfaces/IJBCashOutHook.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPayHook} from "@bananapus/core-v6/src/interfaces/IJBPayHook.sol";
import {IJBRulesetDataHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetDataHook.sol";
import {IJBRulesets} from "@bananapus/core-v6/src/interfaces/IJBRulesets.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {DefifaDelegation} from "../structs/DefifaDelegation.sol";
import {DefifaTierCashOutWeight} from "../structs/DefifaTierCashOutWeight.sol";
import {IDefifaGamePhaseReporter} from "./IDefifaGamePhaseReporter.sol";
import {IDefifaGamePotReporter} from "./IDefifaGamePotReporter.sol";

/// @notice The hook interface for Defifa games: an ERC-1155 game-piece hook with game-specific attestation
/// delegation, scorecard-based cash-out weights, and token claiming.
/// @dev Each tier has two ERC-1155 token IDs. Paid positions use the tier ID itself. Reserve-minted positions use
/// `tierId + RESERVE_TOKEN_ID_OFFSET`, so refunds can exclude them after transfers. Both IDs count toward the tier's
/// supply, attestation power, and cash-out weight.
interface IDefifa1155Hook is IJBRulesetDataHook, IJBPayHook, IJBCashOutHook {
    /// @notice Emitted when positions are minted from a contribution.
    /// @param tierId The tier the positions were minted from.
    /// @param beneficiary The address that received the positions.
    /// @param count The number of positions minted in the tier.
    /// @param totalAmountContributed The total amount contributed in the minting transaction.
    /// @param caller The address that triggered the mint.
    event Mint(
        uint256 indexed tierId,
        address indexed beneficiary,
        uint256 count,
        uint256 totalAmountContributed,
        address caller
    );

    /// @notice Emitted when reserved positions are minted.
    /// @param tierId The tier the reserved positions were minted from.
    /// @param beneficiary The address that received the reserved positions.
    /// @param count The number of reserved positions minted.
    /// @param caller The address that triggered the mint.
    event MintReservedToken(uint256 indexed tierId, address indexed beneficiary, uint256 count, address caller);

    /// @notice Emitted when a delegate's attestation balance changes for a tier.
    /// @param delegate The delegate whose attestation balance changed.
    /// @param tierId The tier whose attestation balance changed.
    /// @param previousBalance The prior attestation balance.
    /// @param newBalance The updated attestation balance.
    /// @param caller The address that triggered the change.
    event TierDelegateAttestationsChanged(
        address indexed delegate, uint256 indexed tierId, uint256 previousBalance, uint256 newBalance, address caller
    );

    /// @notice Emitted when a delegator changes delegates for a tier.
    /// @param delegator The address changing its delegate.
    /// @param fromDelegate The previous delegate.
    /// @param toDelegate The new delegate.
    /// @param caller The address that triggered the delegate change.
    event DelegateChanged(
        address indexed delegator, address indexed fromDelegate, address indexed toDelegate, address caller
    );

    /// @notice Emitted when claimable game tokens are claimed.
    /// @param beneficiary The address receiving the claimed tokens.
    /// @param defifaTokenAmount The amount of Defifa tokens claimed.
    /// @param baseProtocolTokenAmount The amount of base protocol tokens claimed.
    /// @param caller The address that triggered the claim.
    event ClaimedTokens(
        address indexed beneficiary, uint256 defifaTokenAmount, uint256 baseProtocolTokenAmount, address caller
    );

    /// @notice Emitted when tier cash-out weights are set.
    /// @param tierWeights The cash-out weights that were set for each tier.
    /// @param caller The address that set the tier weights.
    event TierCashOutWeightsSet(DefifaTierCashOutWeight[] tierWeights, address caller);

    /// @notice Returns the adjusted pending reserve count for a tier, subtracting refund-phase burns.
    /// @param tierId The tier ID.
    /// @return The adjusted pending reserve count.
    function adjustedPendingReservesFor(uint256 tierId) external view returns (uint256);

    /// @notice The total amount redeemed from this game (refunds not counted).
    /// @return The total redeemed amount.
    function amountRedeemed() external view returns (uint256);

    /// @notice The base protocol token used for token allocations.
    /// @return The base protocol ERC-20 token.
    function BASE_PROTOCOL_TOKEN() external view returns (IERC20);

    /// @notice The base URI for token metadata.
    /// @return The base URI string.
    function baseURI() external view returns (string memory);

    /// @notice Whether the cash-out weights have been set by the game's governor.
    /// @return True if cash-out weights are set.
    function cashOutWeightIsSet() external view returns (bool);

    /// @notice The cash-out weight of one position of a token ID, based on its tier's scorecard weight.
    /// @param tokenId The token ID to look up (paid or reserve ID).
    /// @return The cash-out weight of a single position.
    function cashOutWeightOf(uint256 tokenId) external view returns (uint256);

    /// @notice The cumulative cash-out weight of the given positions.
    /// @param tokenIds The token IDs (paid or reserve IDs).
    /// @param amounts The number of positions of each token ID.
    /// @return The cumulative cash-out weight.
    function cashOutWeightOf(uint256[] memory tokenIds, uint256[] memory amounts) external view returns (uint256);

    /// @notice The address of the code origin contract used as an implementation for clones.
    /// @return The code origin address.
    function CODE_ORIGIN() external view returns (address);

    /// @notice The contract-level metadata URI (used by marketplaces for collection-level info).
    /// @return The contract URI string.
    function contractURI() external view returns (string memory);

    /// @notice The directory of terminals and controllers for projects.
    /// @return The directory contract.
    function DIRECTORY() external view returns (IJBDirectory);

    /// @notice The current supply of a specific tier.
    /// @param tierId The ID of the tier.
    /// @return The current supply.
    function currentSupplyOfTier(uint256 tierId) external view returns (uint256);

    /// @notice The default attestation delegate for new token holders.
    /// @return The default delegate address.
    function defaultAttestationDelegate() external view returns (address);

    /// @notice The Defifa project token used for token allocations.
    /// @return The Defifa ERC-20 token.
    function DEFIFA_TOKEN() external view returns (IERC20);

    /// @notice The cumulative mint price of all paid and reserved positions. Decremented on burns/refunds. Used as the
    /// participation metric — immune to `addToBalanceOf` inflation because only actual mints increment it.
    /// @return The total mint cost in the game's payment token.
    function totalMintCost() external view returns (uint256);

    /// @notice The game phase reporter for this hook.
    /// @return The game phase reporter contract.
    function gamePhaseReporter() external view returns (IDefifaGamePhaseReporter);

    /// @notice The game pot reporter for this hook.
    /// @return The game pot reporter contract.
    function gamePotReporter() external view returns (IDefifaGamePotReporter);

    /// @notice Get the attestation units for a specific account and tier at a past timestamp.
    /// @param account The account to look up.
    /// @param tier The tier ID.
    /// @param timestamp The historical timestamp.
    /// @return The number of attestation units at that time.
    function getPastTierAttestationUnitsOf(
        address account,
        uint256 tier,
        uint48 timestamp
    )
        external
        view
        returns (uint256);

    /// @notice Get the total attestation units for a tier at a past timestamp.
    /// @param tier The tier ID.
    /// @param timestamp The historical timestamp.
    /// @return The total attestation units at that time.
    function getPastTierTotalAttestationUnitsOf(uint256 tier, uint48 timestamp) external view returns (uint256);

    /// @notice Get the attestation units for a specific account and tier.
    /// @param account The account to look up.
    /// @param tier The tier ID.
    /// @return The number of attestation units.
    function getTierAttestationUnitsOf(address account, uint256 tier) external view returns (uint256);

    /// @notice Get the delegate for a specific account and tier.
    /// @param account The account to look up.
    /// @param tier The tier ID.
    /// @return The delegate address.
    function getTierDelegateOf(address account, uint256 tier) external view returns (address);

    /// @notice Get the total attestation units for a specific tier.
    /// @param tier The tier ID.
    /// @return The total attestation units.
    function getTierTotalAttestationUnitsOf(uint256 tier) external view returns (uint256);

    /// @notice The ID used when parsing pay and cash-out metadata.
    /// @return The address of the metadata ID target.
    function METADATA_ID_TARGET() external view returns (address);

    /// @notice The name of the game-piece collection.
    /// @return The name.
    function name() external view returns (string memory);

    /// @notice The pricing currency used by this hook.
    /// @return The currency identifier.
    function pricingCurrency() external view returns (uint256);

    /// @notice The ID of the project (game) this hook belongs to.
    /// @return The project ID.
    function projectId() external view returns (uint256);

    /// @notice The offset added to a tier ID to form the token ID of its reserve-minted positions.
    /// @return The offset.
    function RESERVE_TOKEN_ID_OFFSET() external view returns (uint256);

    /// @notice The rulesets contract used by this hook.
    /// @return The rulesets contract.
    function rulesets() external view returns (IJBRulesets);

    /// @notice The 721 tiers hook store used by this hook.
    /// @return The store contract.
    function store() external view returns (IJB721TiersHookStore);

    /// @notice The symbol of the game-piece collection.
    /// @return The symbol.
    function symbol() external view returns (string memory);

    /// @notice The cash-out weights for all tiers (up to 128).
    /// @return The array of tier cash-out weights.
    function tierCashOutWeights() external view returns (uint256[128] memory);

    /// @notice The name of a specific tier.
    /// @param tierId The ID of the tier.
    /// @return The tier name.
    function tierNameOf(uint256 tierId) external view returns (string memory);

    /// @notice The tier a token ID belongs to.
    /// @dev Reverts for token IDs outside both the paid and reserve ranges.
    /// @param tokenId The token ID (paid or reserve ID).
    /// @return The tier ID.
    function tierIdOf(uint256 tokenId) external pure returns (uint256);

    /// @notice Get the claimable Defifa and base protocol tokens for a set of positions.
    /// @param tokenIds The token IDs to check (paid or reserve IDs).
    /// @param amounts The number of positions of each token ID.
    /// @return The claimable Defifa token amount and base protocol token amount.
    function tokensClaimableFor(
        uint256[] memory tokenIds,
        uint256[] memory amounts
    )
        external
        view
        returns (uint256, uint256);

    /// @notice The number of positions redeemed from a specific tier.
    /// @param tierId The tier ID.
    /// @return The number of tokens redeemed.
    function tokensRedeemedFrom(uint256 tierId) external view returns (uint256);

    /// @notice The total cash-out weight used to normalize tier cash-out weights.
    /// @return The total cash-out weight.
    function TOTAL_CASHOUT_WEIGHT() external view returns (uint256);

    /// @notice Initialize the hook with game-specific configuration.
    /// @param gameId The ID of the game.
    /// @param name The name of the game-piece collection.
    /// @param symbol The symbol of the game-piece collection.
    /// @param rulesets The rulesets contract.
    /// @param baseUri The base URI for token metadata.
    /// @param tokenUriResolver The token URI resolver.
    /// @param contractUri The contract-level metadata URI.
    /// @param tiers The initial tier configurations.
    /// @param currency The pricing currency.
    /// @param store The 721 tiers hook store.
    /// @param gamePhaseReporter The game phase reporter.
    /// @param gamePotReporter The game pot reporter.
    /// @param defaultAttestationDelegate The default attestation delegate.
    /// @param tierNames The names for each tier.
    function initialize(
        uint256 gameId,
        string memory name,
        string memory symbol,
        IJBRulesets rulesets,
        string memory baseUri,
        IJB721TokenUriResolver tokenUriResolver,
        string memory contractUri,
        JB721TierConfig[] memory tiers,
        uint48 currency,
        IJB721TiersHookStore store,
        IDefifaGamePhaseReporter gamePhaseReporter,
        IDefifaGamePotReporter gamePotReporter,
        address defaultAttestationDelegate,
        string[] memory tierNames
    )
        external;

    /// @notice Mint reserved positions for multiple tiers.
    /// @param mintReservesForTiersData The configuration for which tiers to mint reserves for.
    function mintReservesFor(JB721TiersMintReservesConfig[] memory mintReservesForTiersData) external;

    /// @notice Mint reserved positions for a specific tier.
    /// @param tierId The tier ID to mint reserves for.
    /// @param count The number of reserved positions to mint.
    function mintReservesFor(uint256 tierId, uint256 count) external;

    /// @notice Set the cash-out weights for tiers. Only callable by the game's governor (owner).
    /// @param tierWeights The tier cash-out weights to set.
    function setTierCashOutWeightsTo(DefifaTierCashOutWeight[] memory tierWeights) external;

    /// @notice Delegate your attestation voting power for a specific tier to another address.
    /// @param delegatee The address to delegate to.
    /// @param tierId The tier ID.
    function setTierDelegateTo(address delegatee, uint256 tierId) external;

    /// @notice Delegate your attestation voting power for multiple tiers to other addresses in a single call.
    /// @param delegations The delegation assignments.
    function setTierDelegatesTo(DefifaDelegation[] memory delegations) external;
}
