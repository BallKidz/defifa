// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJB721TiersHookStore} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHookStore.sol";

import {IDefifaTiersHookStore} from "../interfaces/IDefifaTiersHookStore.sol";
import {DefifaHookLib} from "./DefifaHookLib.sol";
import {ERC1155Utils} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Utils.sol";

/// @notice The token ID and amount helpers of `Defifa1155Hook`. Rules shared with `DefifaHook` (reserves, supply,
/// cash-out weights, claims) stay in `DefifaHookLib`.
/// @dev Public library functions are deployed separately and called via delegatecall, so their bytecode does not count
/// toward the calling contract's EIP-170 size limit.
library Defifa1155HookLib {
    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    /// @notice Thrown when a refund includes a reserve position.
    error Defifa1155Hook_CantRefundReserveMint(uint256 tokenId);

    /// @notice Thrown when parallel ID and amount arrays have different lengths.
    error Defifa1155Hook_LengthMismatch(uint256 idCount, uint256 amountCount);

    /// @notice Thrown when a token ID is outside both the paid and the reserve ID ranges.
    error Defifa1155Hook_InvalidTokenId(uint256 tokenId);

    /// @notice Thrown when a position count or amount is zero.
    error Defifa1155Hook_ZeroAmount(uint256 id);

    //*********************************************************************//
    // ----------------------- internal constants ------------------------ //
    //*********************************************************************//

    /// @notice The offset added to a tier ID to form the token ID of its reserve-minted positions.
    /// @dev Above every uint16 tier ID the store can hold.
    uint256 internal constant RESERVE_TOKEN_ID_OFFSET = 1 << 16;

    //*********************************************************************//
    // -------------------------- internal views ------------------------- //
    //*********************************************************************//

    /// @notice The tier a token ID belongs to.
    /// @dev Paid positions use the tier ID; reserve-minted positions use `tierId + RESERVE_TOKEN_ID_OFFSET`.
    /// @param tokenId The token ID.
    /// @return tierId The tier ID.
    function tierIdOf(uint256 tokenId) internal pure returns (uint256 tierId) {
        tierId = tokenId > RESERVE_TOKEN_ID_OFFSET ? tokenId - RESERVE_TOKEN_ID_OFFSET : tokenId;
        if (tierId == 0 || tierId >= RESERVE_TOKEN_ID_OFFSET) revert Defifa1155Hook_InvalidTokenId(tokenId);
    }

    //*********************************************************************//
    // -------------------------- public views --------------------------- //
    //*********************************************************************//

    /// @notice Runs the ERC-1155 receiver callback for a mint. Called by delegatecall, so the hook is the caller.
    /// @param operator The account that triggered the mint.
    /// @param to The address the positions were minted to.
    /// @param ids The token IDs minted.
    /// @param values The number of positions of each token ID.
    function checkMintAcceptance(address operator, address to, uint256[] memory ids, uint256[] memory values) public {
        if (ids.length == 1) {
            ERC1155Utils.checkOnERC1155Received({
                operator: operator, from: address(0), to: to, id: ids[0], value: values[0], data: ""
            });
        } else {
            ERC1155Utils.checkOnERC1155BatchReceived({
                operator: operator, from: address(0), to: to, ids: ids, values: values, data: ""
            });
        }
    }

    /// @notice Validates a payment's tier counts and computes the attestation units minted in each tier.
    /// @param tierIds The tier IDs to mint, in strictly ascending order.
    /// @param counts The number of positions to mint in each tier.
    /// @param hookStore The 721 tiers hook store.
    /// @param hook The hook address.
    /// @return attestationAmounts The attestation units minted in each tier, parallel to `tierIds`.
    function computeAttestationUnits(
        uint16[] memory tierIds,
        uint256[] memory counts,
        IJB721TiersHookStore hookStore,
        address hook
    )
        public
        view
        returns (uint256[] memory attestationAmounts)
    {
        uint256 numberOfTiers = tierIds.length;
        if (numberOfTiers != counts.length) revert Defifa1155Hook_LengthMismatch(numberOfTiers, counts.length);

        attestationAmounts = new uint256[](numberOfTiers);
        uint256 previousTierId;

        for (uint256 i; i < numberOfTiers; i++) {
            // Strict ascending order rules out duplicate tiers.
            if (tierIds[i] <= previousTierId) {
                revert DefifaHookLib.DefifaHook_BadTierOrder({previousTierId: previousTierId, tierId: tierIds[i]});
            }
            previousTierId = tierIds[i];
            if (counts[i] == 0) revert Defifa1155Hook_ZeroAmount(tierIds[i]);

            attestationAmounts[i] =
                counts[i] * hookStore.tierOf({hook: hook, id: tierIds[i], includeResolvedUri: false}).votingUnits;
        }
    }

    /// @notice Compute the cash-out weight of one position of a token ID.
    /// @param tokenId The token ID (paid or reserve ID).
    /// @param hookStore The 721 tiers hook store.
    /// @param hook The hook address.
    /// @param tierCashOutWeights The tier cash-out weights array.
    /// @param tokensRedeemedFrom The mapping of positions redeemed per tier.
    /// @return The cash-out weight.
    function computeCashOutWeight(
        uint256 tokenId,
        IJB721TiersHookStore hookStore,
        address hook,
        uint256[128] storage tierCashOutWeights,
        mapping(uint256 => uint256) storage tokensRedeemedFrom
    )
        public
        view
        returns (uint256)
    {
        return DefifaHookLib.computeTierCashOutWeight({
            tierId: tierIdOf(tokenId),
            hookStore: hookStore,
            hook: hook,
            tierCashOutWeights: tierCashOutWeights,
            tokensRedeemedFrom: tokensRedeemedFrom
        });
    }

    /// @notice Compute the cumulative cash-out weight of a set of positions.
    /// @param tokenIds The token IDs (paid or reserve IDs).
    /// @param amounts The number of positions of each token ID.
    /// @param hookStore The 721 tiers hook store.
    /// @param hook The hook address.
    /// @param tierCashOutWeights The tier cash-out weights array.
    /// @param tokensRedeemedFrom The mapping of positions redeemed per tier.
    /// @return cumulativeWeight The cumulative weight.
    function computeCashOutWeightBatch(
        uint256[] memory tokenIds,
        uint256[] memory amounts,
        IJB721TiersHookStore hookStore,
        address hook,
        uint256[128] storage tierCashOutWeights,
        mapping(uint256 => uint256) storage tokensRedeemedFrom
    )
        public
        view
        returns (uint256 cumulativeWeight)
    {
        uint256 numberOfIds = tokenIds.length;
        if (numberOfIds != amounts.length) revert Defifa1155Hook_LengthMismatch(numberOfIds, amounts.length);
        for (uint256 i; i < numberOfIds;) {
            cumulativeWeight += amounts[i]
            * DefifaHookLib.computeTierCashOutWeight({
                tierId: tierIdOf(tokenIds[i]),
                hookStore: hookStore,
                hook: hook,
                tierCashOutWeights: tierCashOutWeights,
                tokensRedeemedFrom: tokensRedeemedFrom
            });
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Compute the cumulative mint price of a set of positions.
    /// @param tokenIds The token IDs (paid or reserve IDs).
    /// @param amounts The number of positions of each token ID.
    /// @param hookStore The 721 tiers hook store.
    /// @param hook The hook address.
    /// @param excludeReserveMints Whether reserve-minted positions should be excluded.
    /// @return cumulativeMintPrice The total mint price.
    function computeCumulativeMintPriceForCashOut(
        uint256[] memory tokenIds,
        uint256[] memory amounts,
        IJB721TiersHookStore hookStore,
        address hook,
        bool excludeReserveMints
    )
        public
        view
        returns (uint256 cumulativeMintPrice)
    {
        uint256 numberOfIds = tokenIds.length;
        if (numberOfIds != amounts.length) revert Defifa1155Hook_LengthMismatch(numberOfIds, amounts.length);
        for (uint256 i; i < numberOfIds; i++) {
            // A refund pays nothing for a reserve position, so burning one would leave its cost in `totalMintCost`
            // and count it as a refunded paid position.
            if (excludeReserveMints && tokenIds[i] > RESERVE_TOKEN_ID_OFFSET) {
                revert Defifa1155Hook_CantRefundReserveMint(tokenIds[i]);
            }
            cumulativeMintPrice += amounts[i]
            * hookStore.tierOf({hook: hook, id: tierIdOf(tokenIds[i]), includeResolvedUri: false}).price;
        }
    }

    /// @notice Compute the claimable token amounts for a set of positions.
    /// @param tokenIds The token IDs (paid or reserve IDs).
    /// @param amounts The number of positions of each token ID.
    /// @param hookStore The 721 tiers hook store.
    /// @param hook The hook address.
    /// @param totalMintCost The cumulative mint cost.
    /// @param defifaBalance The current $DEFIFA balance.
    /// @param baseProtocolBalance The current $BASE_PROTOCOL balance.
    /// @return defifaTokenAmount The claimable $DEFIFA amount.
    /// @return baseProtocolTokenAmount The claimable $BASE_PROTOCOL amount.
    function computeTokensClaim(
        uint256[] memory tokenIds,
        uint256[] memory amounts,
        IJB721TiersHookStore hookStore,
        address hook,
        uint256 totalMintCost,
        uint256 defifaBalance,
        uint256 baseProtocolBalance
    )
        public
        view
        returns (uint256 defifaTokenAmount, uint256 baseProtocolTokenAmount)
    {
        // If nothing was paid to mint, no fee tokens can be claimed.
        if (totalMintCost == 0) return (0, 0);

        // Claims count the mint price of every burned position, reserve-minted ones included.
        return DefifaHookLib.tokensClaimFor({
            cumulativeMintPrice: computeCumulativeMintPriceForCashOut({
                tokenIds: tokenIds, amounts: amounts, hookStore: hookStore, hook: hook, excludeReserveMints: false
            }),
            totalMintCost: totalMintCost,
            defifaBalance: defifaBalance,
            baseProtocolBalance: baseProtocolBalance
        });
    }

    //*********************************************************************//
    // ----------------------- public transactions ----------------------- //
    //*********************************************************************//

    /// @notice Records burned positions in the store and in the hook's per-tier burn counters.
    /// @dev Executes via delegatecall, so the store records the burns for the calling hook.
    /// @param tokenIds The burned token IDs (paid or reserve IDs).
    /// @param amounts The number of positions burned of each token ID.
    /// @param hookStore The tiers hook store.
    /// @param isComplete Whether the game is in its COMPLETE phase.
    /// @param tokensRedeemedFrom The hook's COMPLETE-phase redemptions per tier.
    /// @param refundedBurnsFrom The hook's non-COMPLETE-phase burns per tier.
    function recordBurns(
        uint256[] memory tokenIds,
        uint256[] memory amounts,
        IDefifaTiersHookStore hookStore,
        bool isComplete,
        mapping(uint256 => uint256) storage tokensRedeemedFrom,
        mapping(uint256 => uint256) storage refundedBurnsFrom
    )
        public
    {
        uint256 numberOfIds = tokenIds.length;
        uint256[] memory tierIds = new uint256[](numberOfIds);
        for (uint256 i; i < numberOfIds; i++) {
            uint256 tierId = tierIdOf(tokenIds[i]);
            tierIds[i] = tierId;

            // Track COMPLETE-phase redemptions, or non-COMPLETE burns (refund/no-contest) so pending reserve counts
            // can be adjusted.
            if (isComplete) tokensRedeemedFrom[tierId] += amounts[i];
            else refundedBurnsFrom[tierId] += amounts[i];
        }

        hookStore.recordBurnCounts({tierIds: tierIds, counts: amounts});
    }
}
