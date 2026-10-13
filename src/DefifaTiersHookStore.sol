// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {JB721TiersHookStore} from "@bananapus/721-hook-v6/src/JB721TiersHookStore.sol";
import {JB721Constants} from "@bananapus/721-hook-v6/src/libraries/JB721Constants.sol";
import {JBBitmapWord} from "@bananapus/721-hook-v6/src/structs/JBBitmapWord.sol";
import {JBStored721Tier} from "@bananapus/721-hook-v6/src/structs/JBStored721Tier.sol";
import {mulDiv} from "@prb/math/src/Common.sol";

import {IDefifaTiersHookStore} from "./interfaces/IDefifaTiersHookStore.sol";

/// @notice The 721 tiers hook store, unchanged, plus count-based records for ERC-1155 game positions. Each count
/// function applies the same checks and accounting as its per-position counterpart, once per tier.
contract DefifaTiersHookStore is JB721TiersHookStore, IDefifaTiersHookStore {
    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Record burned positions: the count version of `recordBurn`.
    /// @dev Trusts `msg.sender` (the hook) to call it only after burning the positions.
    /// @param tierIds The tier of each burn entry. Entries may repeat a tier.
    /// @param counts The number of positions burned in each entry.
    function recordBurnCounts(uint256[] calldata tierIds, uint256[] calldata counts) external override {
        for (uint256 i; i < tierIds.length;) {
            uint256 tierId = tierIds[i];
            uint256 count = counts[i];

            numberOfBurnedFor[msg.sender][tierId] += count;

            // A burn removes outstanding positions weighted by the tier's full price; pending reserves are unaffected.
            unchecked {
                totalCashOutWeightOf[msg.sender] -= _storedTierOf[msg.sender][tierId].price * count;
                ++i;
            }
        }
    }

    /// @notice Record paid mints: the count version of `recordMint` for non-owner mints.
    /// @dev Equivalent to `recordMint` with each tier ID repeated `counts[i]` times. Within a tier, pending reserves
    /// only grow and remaining supply only shrinks as positions mint, so checking supply against pending reserves
    /// after the whole count implies every intermediate check.
    /// @param amount The amount to spend. The total price must not exceed it.
    /// @param tierIds The tiers to mint from.
    /// @param counts The number of positions to mint in each tier.
    /// @return leftoverAmount The `amount` remaining after minting.
    function recordMintCounts(
        uint256 amount,
        uint16[] calldata tierIds,
        uint256[] calldata counts
    )
        external
        override
        returns (uint256 leftoverAmount)
    {
        leftoverAmount = amount;

        // Initialize a `JBBitmapWord` for checking whether tiers have been removed.
        JBBitmapWord memory bitmapWord;

        for (uint256 i; i < tierIds.length;) {
            uint256 tierId = tierIds[i];
            uint256 count = counts[i];

            // Make sure the tier hasn't been removed.
            if (_isTierRemovedWithRefresh({hook: msg.sender, tierId: tierId, bitmapWord: bitmapWord})) {
                revert JB721TiersHookStore_TierRemoved({tierId: tierId});
            }

            JBStored721Tier storage storedTier = _storedTierOf[msg.sender][tierId];

            // Make sure the provided tier exists (tiers cannot have a supply of 0).
            if (storedTier.initialSupply == 0) revert JB721TiersHookStore_UnrecognizedTier(tierId);

            // The discounted price of one position.
            uint256 price = storedTier.price;
            if (storedTier.discountPercent > 0) {
                price -= mulDiv({
                    x: price, y: storedTier.discountPercent, denominator: JB721Constants.DISCOUNT_DENOMINATOR
                });
            }

            // Make sure the `amount` covers every position.
            if (price * count > leftoverAmount) {
                revert JB721TiersHookStore_PriceExceedsAmount(price * count, leftoverAmount);
            }

            // Make sure enough positions remain to mint.
            if (count == 0 || storedTier.remainingSupply < count) {
                revert JB721TiersHookStore_InsufficientSupplyRemaining(tierId);
            }

            uint256 pendingReservesBefore =
                _numberOfPendingReservesFor({hook: msg.sender, tierId: tierId, storedTier: storedTier});

            unchecked {
                // forge-lint: disable-next-line(unsafe-typecast)
                storedTier.remainingSupply -= uint32(count);
                leftoverAmount -= price * count;
            }

            uint256 pendingReservesAfter =
                _numberOfPendingReservesFor({hook: msg.sender, tierId: tierId, storedTier: storedTier});

            // Make sure there are still enough positions remaining to satisfy pending reserves.
            if (storedTier.remainingSupply < pendingReservesAfter) {
                revert JB721TiersHookStore_InsufficientSupplyRemaining({tierId: tierId});
            }

            // The mint adds `count` outstanding positions plus any newly accrued pending reserves, each weighted by
            // the tier's full price.
            unchecked {
                totalCashOutWeightOf[msg.sender] += storedTier.price
                * (count + (pendingReservesAfter - pendingReservesBefore));
                ++i;
            }
        }
    }

    /// @notice Record positions moving between holders: the count version of `recordTransferForTier`.
    /// @param tierId The tier the positions belong to.
    /// @param from The holder sending (zero for mints).
    /// @param to The holder receiving (zero for burns).
    /// @param count The number of positions.
    function recordTransferForTier(uint256 tierId, address from, address to, uint256 count) external override {
        // Self-transfers and empty transfers leave balances and the held-tier bitmap unchanged.
        if (from == to || count == 0) return;

        if (from != address(0)) {
            uint256 fromTierBalance = tierBalanceOf[msg.sender][from][tierId] - count;
            tierBalanceOf[msg.sender][from][tierId] = fromTierBalance;

            // Remove the tier from the sender's held bitmap if this transfer consumed their last position in it.
            if (fromTierBalance == 0) _removeHeldTier({hook: msg.sender, owner: from, tierId: tierId});

            balanceOf[msg.sender][from] -= count;
        }

        if (to != address(0)) {
            uint256 toTierBalance = tierBalanceOf[msg.sender][to][tierId];

            // Add the tier to the receiver's held bitmap before their first position in it is recorded.
            if (toTierBalance == 0) _addHeldTier({hook: msg.sender, owner: to, tierId: tierId});

            tierBalanceOf[msg.sender][to][tierId] = toTierBalance + count;
            balanceOf[msg.sender][to] += count;
        }
    }
}
