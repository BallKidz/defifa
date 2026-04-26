// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJB721TiersHookStore} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHookStore.sol";
import {JB721Tier} from "@bananapus/721-hook-v6/src/structs/JB721Tier.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {mulDiv} from "@prb/math/src/Common.sol";

import {DefifaGamePhase} from "../enums/DefifaGamePhase.sol";
import {DefifaTierCashOutWeight} from "../structs/DefifaTierCashOutWeight.sol";

/// @notice Pure/view helper functions extracted from DefifaHook to reduce contract bytecode size.
/// @dev Public library functions are deployed separately and called via delegatecall, so their bytecode does not count
/// toward the calling contract's EIP-170 size limit.
library DefifaHookLib {
    using SafeERC20 for IERC20;

    error DefifaHook_BadTierOrder();
    error DefifaHook_InvalidTierId();
    error DefifaHook_InvalidCashoutWeights();

    event ClaimedTokens(
        address indexed beneficiary, uint256 defifaTokenAmount, uint256 baseProtocolTokenAmount, address caller
    );

    /// @notice The total cashOut weight that can be divided among tiers.
    uint256 internal constant TOTAL_CASHOUT_WEIGHT = 1_000_000_000_000_000_000;

    /// @notice Validates tier cash out weights and returns the weight array to store.
    /// @param tierWeights The tier weights to validate and set.
    /// @param hookStore The 721 tiers hook store.
    /// @param hook The hook address.
    /// @return weights The 128-element array of validated weights.
    function validateAndBuildWeights(
        DefifaTierCashOutWeight[] memory tierWeights,
        IJB721TiersHookStore hookStore,
        address hook
    )
        public
        view
        returns (uint256[128] memory weights)
    {
        // Keep a reference to the max tier ID.
        uint256 maxTierId = hookStore.maxTierIdOf(hook);

        // Keep a reference to the cumulative amounts.
        uint256 cumulativeCashOutWeight;

        // Keep a reference to the number of tier weights.
        uint256 numberOfTierWeights = tierWeights.length;

        // Keep a reference to the tier being iterated on.
        JB721Tier memory tier;

        // Keep a reference to the last tier ID to enforce ascending order (no duplicates).
        uint256 lastTierId;

        for (uint256 i; i < numberOfTierWeights;) {
            // Enforce strict ascending order to prevent duplicate tier IDs.
            if (tierWeights[i].id <= lastTierId && i != 0) revert DefifaHook_BadTierOrder();
            lastTierId = tierWeights[i].id;

            // Get the tier.
            // slither-disable-next-line calls-loop
            tier = hookStore.tierOf({hook: hook, id: tierWeights[i].id, includeResolvedUri: false});

            // Guard against uint32 truncation: if the caller passes a tier ID > type(uint32).max,
            // the store may silently truncate and return a different tier.
            if (tierWeights[i].id != tier.id) revert DefifaHook_InvalidTierId();

            // Can't set a cashOut weight for tiers not in category 0.
            if (tier.category != 0) revert DefifaHook_InvalidTierId();

            // Attempting to set the cashOut weight for a tier that does not exist (yet) reverts.
            if (tier.id > maxTierId) revert DefifaHook_InvalidTierId();

            // Save the tier weight. Tiers are 1 indexed and should be stored 0 indexed.
            weights[tier.id - 1] = tierWeights[i].cashOutWeight;

            // Increment the cumulative amount.
            cumulativeCashOutWeight += tierWeights[i].cashOutWeight;

            unchecked {
                ++i;
            }
        }

        // Make sure the cumulative amount is exactly the total cashOut weight.
        if (cumulativeCashOutWeight != TOTAL_CASHOUT_WEIGHT) revert DefifaHook_InvalidCashoutWeights();
    }

    /// @notice Compute the cash out weight for a single token.
    /// @param tokenId The token ID.
    /// @param hookStore The 721 tiers hook store.
    /// @param hook The hook address.
    /// @param tierCashOutWeights The tier cash out weights array.
    /// @param tokensRedeemedFrom The mapping of tokens redeemed per tier (passed as a function that returns the value).
    /// @return The cash out weight.
    function computeCashOutWeight(
        uint256 tokenId,
        IJB721TiersHookStore hookStore,
        address hook,
        uint256[128] storage tierCashOutWeights,
        mapping(uint256 => uint256) storage tokensRedeemedFrom,
        mapping(uint256 => uint256) storage refundedBurnsFrom
    )
        public
        view
        returns (uint256)
    {
        // Keep a reference to the token's tier ID.
        // slither-disable-next-line calls-loop
        uint256 tierId = hookStore.tierIdOfToken(tokenId);

        // Keep a reference to the tier.
        // slither-disable-next-line calls-loop
        JB721Tier memory tier = hookStore.tierOf({hook: hook, id: tierId, includeResolvedUri: false});

        // Get the tier's weight.
        uint256 weight = tierCashOutWeights[tierId - 1];

        // If there's no weight there's nothing to redeem.
        if (weight == 0) return 0;

        // Get the amount of tokens that have already been burned.
        // slither-disable-next-line calls-loop
        uint256 burnedTokens = hookStore.numberOfBurnedFor({hook: hook, tierId: tierId});

        // If no tiers were minted, nothing to redeem.
        if (tier.initialSupply - (tier.remainingSupply + burnedTokens) == 0) return 0;

        // Calculate the amount of tokens that existed at the start of the last phase.
        uint256 totalTokensForCashoutInTier =
            tier.initialSupply - tier.remainingSupply - (burnedTokens - tokensRedeemedFrom[tierId]);

        // Include pending (unminted) reserve NFTs in the denominator, adjusted for refund-phase burns.
        // Without this, paid holders could cash out before reserves are minted and extract value
        // that should be diluted across both paid and reserved holders.
        // Recalculate from (paidMints - burns) / reserveFrequency since the relationship is not linear.
        {
            uint256 refundBurns = refundedBurnsFrom[tierId];
            uint256 adjustedPending;
            if (tier.reserveFrequency > 0) {
                // slither-disable-next-line calls-loop
                uint256 reservesMinted = hookStore.numberOfReservesMintedFor({hook: hook, tierId: tierId});
                uint256 nonReserveMints = tier.initialSupply - tier.remainingSupply - reservesMinted;
                uint256 adjustedMints = nonReserveMints > refundBurns ? nonReserveMints - refundBurns : 0;
                uint256 availableReserves = adjustedMints / tier.reserveFrequency;
                if (adjustedMints % tier.reserveFrequency > 0) ++availableReserves;
                adjustedPending = availableReserves > reservesMinted ? availableReserves - reservesMinted : 0;
            }
            totalTokensForCashoutInTier += adjustedPending;
        }

        // Calculate the percentage of the tier cashOut amount a single token counts for.
        // Integer division rounding in cashOutWeight is unavoidable in Solidity. Rounding direction
        // (down) is consistent and conservative — it slightly favors the project over individual cash-out recipients.
        // The maximum error per operation is 1 wei per division.
        return weight / totalTokensForCashoutInTier;
    }

    /// @notice Compute the cumulative cash out weight for multiple tokens.
    /// @param tokenIds The token IDs.
    /// @param hookStore The 721 tiers hook store.
    /// @param hook The hook address.
    /// @param tierCashOutWeights The tier cash out weights array.
    /// @param tokensRedeemedFrom The mapping of tokens redeemed per tier.
    /// @return cumulativeWeight The cumulative weight.
    function computeCashOutWeightBatch(
        uint256[] memory tokenIds,
        IJB721TiersHookStore hookStore,
        address hook,
        uint256[128] storage tierCashOutWeights,
        mapping(uint256 => uint256) storage tokensRedeemedFrom,
        mapping(uint256 => uint256) storage refundedBurnsFrom
    )
        public
        view
        returns (uint256 cumulativeWeight)
    {
        uint256 tokenCount = tokenIds.length;
        for (uint256 i; i < tokenCount;) {
            cumulativeWeight += computeCashOutWeight({
                tokenId: tokenIds[i],
                hookStore: hookStore,
                hook: hook,
                tierCashOutWeights: tierCashOutWeights,
                tokensRedeemedFrom: tokensRedeemedFrom,
                refundedBurnsFrom: refundedBurnsFrom
            });
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Compute the claimable token amounts for a set of token IDs.
    /// @param tokenIds The token IDs.
    /// @param hookStore The 721 tiers hook store.
    /// @param hook The hook address.
    /// @param totalMintCost The cumulative mint cost.
    /// @param defifaBalance The current $DEFIFA balance.
    /// @param baseProtocolBalance The current $BASE_PROTOCOL balance.
    /// @return defifaTokenAmount The claimable $DEFIFA amount.
    /// @return baseProtocolTokenAmount The claimable $BASE_PROTOCOL amount.
    function computeTokensClaim(
        uint256[] memory tokenIds,
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

        // Keep a reference to the number of tokens being used for claims.
        uint256 numberOfTokens = tokenIds.length;

        // Calculate the amount paid to mint the tokens that are being burned.
        uint256 cumulativeMintPrice;
        for (uint256 i; i < numberOfTokens; i++) {
            // slither-disable-next-line calls-loop
            cumulativeMintPrice += hookStore.tierOfTokenId({
                hook: hook, tokenId: tokenIds[i], includeResolvedUri: false
            })
            .price;
        }

        // Calculate the user's claimable amount proportional to what they paid.
        defifaTokenAmount = mulDiv({x: defifaBalance, y: cumulativeMintPrice, denominator: totalMintCost});
        baseProtocolTokenAmount = mulDiv({x: baseProtocolBalance, y: cumulativeMintPrice, denominator: totalMintCost});
    }

    /// @notice Compute the cumulative mint price for a set of token IDs.
    /// @param tokenIds The token IDs.
    /// @param hookStore The 721 tiers hook store.
    /// @param hook The hook address.
    /// @return cumulativeMintPrice The total mint price.
    function computeCumulativeMintPrice(
        uint256[] memory tokenIds,
        IJB721TiersHookStore hookStore,
        address hook
    )
        public
        view
        returns (uint256 cumulativeMintPrice)
    {
        uint256 numberOfTokenIds = tokenIds.length;
        for (uint256 i; i < numberOfTokenIds; i++) {
            // slither-disable-next-line calls-loop
            cumulativeMintPrice += hookStore.tierOfTokenId({
                hook: hook, tokenId: tokenIds[i], includeResolvedUri: false
            })
            .price;
        }
    }

    /// @notice Compute the cash out count for the beforeCashOutRecorded hook.
    /// @param gamePhase The current game phase.
    /// @param cumulativeMintPrice The cumulative mint price of the tokens being cashed out.
    /// @param surplusValue The surplus value from the context.
    /// @param totalAmountRedeemed The amount already redeemed.
    /// @param cumulativeCashOutWeight The cumulative cash out weight of the tokens.
    /// @return cashOutCount The computed cash out count.
    function computeCashOutCount(
        DefifaGamePhase gamePhase,
        uint256 cumulativeMintPrice,
        uint256 surplusValue,
        uint256 totalAmountRedeemed,
        uint256 cumulativeCashOutWeight
    )
        public
        pure
        returns (uint256 cashOutCount)
    {
        // If the game is in its minting, refund, or no-contest phase, reclaim amount is the same as it cost to mint.
        if (
            gamePhase == DefifaGamePhase.MINT || gamePhase == DefifaGamePhase.REFUND
                || gamePhase == DefifaGamePhase.NO_CONTEST
        ) {
            cashOutCount = cumulativeMintPrice;
        } else {
            // If the game is in its scoring or complete phase, reclaim amount is based on the tier weights.
            cashOutCount = mulDiv({
                x: surplusValue + totalAmountRedeemed, y: cumulativeCashOutWeight, denominator: TOTAL_CASHOUT_WEIGHT
            });
        }
    }

    /// @notice Compute the current supply of a tier (minted - burned).
    /// @param hookStore The 721 tiers hook store.
    /// @param hook The hook address.
    /// @param tierId The ID of the tier.
    /// @return The current supply.
    function computeCurrentSupply(
        IJB721TiersHookStore hookStore,
        address hook,
        uint256 tierId
    )
        public
        view
        returns (uint256)
    {
        JB721Tier memory tier = hookStore.tierOf({hook: hook, id: tierId, includeResolvedUri: false});
        return tier.initialSupply - (tier.remainingSupply + hookStore.numberOfBurnedFor({hook: hook, tierId: tierId}));
    }

    /// @notice Computes the attestation units for tiers during payment processing.
    /// @dev Returns parallel arrays: tier IDs, cumulative attestation units per tier, and whether to switch delegate.
    /// @param tierIdsToMint The tier IDs being minted (must be in ascending order).
    /// @param hookStore The 721 tiers hook store.
    /// @param hook The hook address.
    /// @return tierIds The unique tier IDs.
    /// @return attestationAmounts The cumulative attestation units for each unique tier.
    /// @return count The number of unique tiers.
    function computeAttestationUnits(
        uint16[] memory tierIdsToMint,
        IJB721TiersHookStore hookStore,
        address hook
    )
        public
        view
        returns (uint256[] memory tierIds, uint256[] memory attestationAmounts, uint256 count)
    {
        uint256 numberOfTiers = tierIdsToMint.length;
        tierIds = new uint256[](numberOfTiers);
        attestationAmounts = new uint256[](numberOfTiers);

        if (numberOfTiers == 0) return (tierIds, attestationAmounts, 0);

        uint256 currentTierId;
        uint256 attestationUnits;
        uint256 accumulated;

        for (uint256 i; i < numberOfTiers;) {
            if (currentTierId != tierIdsToMint[i]) {
                // Flush accumulated units for previous tier.
                if (currentTierId != 0) {
                    tierIds[count] = currentTierId;
                    attestationAmounts[count] = accumulated;
                    count++;
                }
                if (tierIdsToMint[i] < currentTierId) revert DefifaHook_BadTierOrder();
                currentTierId = tierIdsToMint[i];
                // slither-disable-next-line calls-loop
                attestationUnits =
                hookStore.tierOf({hook: hook, id: currentTierId, includeResolvedUri: false}).votingUnits;
                accumulated = attestationUnits;
            } else {
                accumulated += attestationUnits;
            }
            unchecked {
                ++i;
            }
        }
        // Flush the last tier.
        if (currentTierId != 0) {
            tierIds[count] = currentTierId;
            attestationAmounts[count] = accumulated;
            count++;
        }
    }

    /// @notice Claims the defifa and base protocol tokens for a beneficiary.
    /// @dev Executes via delegatecall, so `address(this)` is the calling contract. Transfers are from the hook's
    /// balance.
    /// @param beneficiary The address to claim tokens for.
    /// @param shareToBeneficiary The share relative to the `outOfTotal` to send the user.
    /// @param outOfTotal The total share that the `shareToBeneficiary` is relative to.
    /// @param defifaToken The $DEFIFA token.
    /// @param baseProtocolToken The $BASE_PROTOCOL token.
    /// @return beneficiaryReceivedTokens A flag indicating if the beneficiary received any tokens.
    function claimTokensFor(
        address beneficiary,
        uint256 shareToBeneficiary,
        uint256 outOfTotal,
        IERC20 defifaToken,
        IERC20 baseProtocolToken
    )
        public
        returns (bool beneficiaryReceivedTokens)
    {
        // Calculate the share of $DEFIFA and $BASE_PROTOCOL tokens to send.
        // Rounding in fee token claims slightly favors later claimants because earlier claims round
        // down, leaving fractionally more for subsequent claimants. The error is bounded by 1 wei per claim and is
        // economically insignificant.
        uint256 baseProtocolAmount =
            mulDiv({x: baseProtocolToken.balanceOf(address(this)), y: shareToBeneficiary, denominator: outOfTotal});
        uint256 defifaAmount =
            mulDiv({x: defifaToken.balanceOf(address(this)), y: shareToBeneficiary, denominator: outOfTotal});

        // If there is an amount we should send, send it.
        if (defifaAmount != 0) defifaToken.safeTransfer({to: beneficiary, value: defifaAmount});
        if (baseProtocolAmount != 0) baseProtocolToken.safeTransfer({to: beneficiary, value: baseProtocolAmount});

        emit ClaimedTokens(beneficiary, defifaAmount, baseProtocolAmount, msg.sender);

        return (defifaAmount != 0 || baseProtocolAmount != 0);
    }
}
