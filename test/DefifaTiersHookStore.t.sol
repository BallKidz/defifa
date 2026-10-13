// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {JB721TiersHookStore} from "@bananapus/721-hook-v6/src/JB721TiersHookStore.sol";
import {JB721Tier} from "@bananapus/721-hook-v6/src/structs/JB721Tier.sol";
import {JB721TierConfig} from "@bananapus/721-hook-v6/src/structs/JB721TierConfig.sol";
import {JB721TierConfigFlags} from "@bananapus/721-hook-v6/src/structs/JB721TierConfigFlags.sol";
import {JBSplit} from "@bananapus/core-v6/src/structs/JBSplit.sol";

import {DefifaTiersHookStore} from "../src/DefifaTiersHookStore.sol";

/// @notice Each count-based record matches its per-position counterpart in the unmodified 721 store. This test contract
/// acts as the hook for both stores.
contract DefifaTiersHookStoreTest is Test {
    JB721TiersHookStore perPosition;
    DefifaTiersHookStore counted;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint104 constant PRICE = 1 ether;

    function setUp() public {
        perPosition = new JB721TiersHookStore();
        counted = new DefifaTiersHookStore();

        // Tier 1 reserves one per three paid and is discounted; tier 2 is plain.
        JB721TierConfig[] memory tiers = new JB721TierConfig[](2);
        for (uint256 i; i < 2; i++) {
            tiers[i] = JB721TierConfig({
                price: PRICE,
                initialSupply: 1000,
                votingUnits: 0,
                reserveFrequency: i == 0 ? 3 : 0,
                reserveBeneficiary: i == 0 ? makeAddr("reserves") : address(0),
                encodedIpfsUri: bytes32(0),
                category: 0,
                discountPercent: i == 0 ? 20 : 0,
                flags: JB721TierConfigFlags({
                    allowOwnerMint: false,
                    useReserveBeneficiaryAsDefault: false,
                    transfersPausable: false,
                    useVotingUnits: false,
                    cantBeRemoved: true,
                    cantIncreaseDiscountPercent: false,
                    cantBuyWithCredits: false
                }),
                splitPercent: 0,
                splits: new JBSplit[](0)
            });
        }
        perPosition.recordAddTiers(tiers);
        counted.recordAddTiers(tiers);
    }

    function testFuzz_countRecordsMatchPerPositionRecords(uint8 rawA, uint8 rawB, uint8 rawBurn, uint8 rawMove) public {
        uint256 a = bound(rawA, 1, 200);
        uint256 b = bound(rawB, 1, 200);
        uint256 burned = bound(rawBurn, 0, a);
        uint256 moved = bound(rawMove, 0, b);

        uint16[] memory tierIds = new uint16[](2);
        tierIds[0] = 1;
        tierIds[1] = 2;
        uint256[] memory counts = new uint256[](2);
        counts[0] = a;
        counts[1] = b;

        // Pay one wei more than needed so the leftover is compared too.
        uint256 amount = _cost(1, a) + _cost(2, b) + 1;

        uint16[] memory expanded = new uint16[](a + b);
        for (uint256 i; i < a + b; i++) {
            expanded[i] = i < a ? 1 : 2;
        }
        (, uint256 leftoverPerPosition,) = perPosition.recordMint(amount, expanded, false);
        uint256 leftoverCounted = counted.recordMintCounts(amount, tierIds, counts);
        assertEq(leftoverCounted, leftoverPerPosition, "leftover");
        assertEq(leftoverCounted, 1, "exact cost");

        // Holder balances: alice receives everything, then sends `moved` of tier 2 to bob.
        for (uint256 i; i < a + b; i++) {
            perPosition.recordTransferForTier(expanded[i], address(0), alice);
        }
        counted.recordTransferForTier(1, address(0), alice, a);
        counted.recordTransferForTier(2, address(0), alice, b);
        for (uint256 i; i < moved; i++) {
            perPosition.recordTransferForTier(2, alice, bob);
        }
        counted.recordTransferForTier(2, alice, bob, moved);

        // Burns from tier 1.
        uint256[] memory burnedTokenIds = new uint256[](burned);
        for (uint256 i; i < burned; i++) {
            burnedTokenIds[i] = 1_000_000_000 + i + 1;
            perPosition.recordTransferForTier(1, alice, address(0));
        }
        perPosition.recordBurn(burnedTokenIds);
        uint256[] memory burnTiers = new uint256[](1);
        burnTiers[0] = 1;
        uint256[] memory burnCounts = new uint256[](1);
        burnCounts[0] = burned;
        counted.recordBurnCounts(burnTiers, burnCounts);
        counted.recordTransferForTier(1, alice, address(0), burned);

        for (uint256 tierId = 1; tierId <= 2; tierId++) {
            JB721Tier memory p = perPosition.tierOf(address(this), tierId, false);
            JB721Tier memory c = counted.tierOf(address(this), tierId, false);
            assertEq(c.remainingSupply, p.remainingSupply, "remaining supply");
            assertEq(
                counted.numberOfPendingReservesFor(address(this), tierId),
                perPosition.numberOfPendingReservesFor(address(this), tierId),
                "pending reserves"
            );
            assertEq(
                counted.numberOfBurnedFor(address(this), tierId),
                perPosition.numberOfBurnedFor(address(this), tierId),
                "burned"
            );
            for (uint256 h; h < 2; h++) {
                address holder = h == 0 ? alice : bob;
                assertEq(
                    counted.tierBalanceOf(address(this), holder, tierId),
                    perPosition.tierBalanceOf(address(this), holder, tierId),
                    "tier balance"
                );
                assertEq(
                    counted.tierVotingUnitsOf(address(this), holder, tierId),
                    perPosition.tierVotingUnitsOf(address(this), holder, tierId),
                    "voting units"
                );
            }
        }
        assertEq(counted.totalCashOutWeightOf(address(this)), perPosition.totalCashOutWeightOf(address(this)), "weight");
        assertEq(counted.totalSupplyOf(address(this)), perPosition.totalSupplyOf(address(this)), "total supply");
        assertEq(counted.balanceOf(address(this), alice), perPosition.balanceOf(address(this), alice), "alice balance");
        assertEq(counted.balanceOf(address(this), bob), perPosition.balanceOf(address(this), bob), "bob balance");
    }

    function test_mintCountsRejectsUnderpaymentAndOversupply() public {
        uint16[] memory tierIds = new uint16[](1);
        tierIds[0] = 2;
        uint256[] memory counts = new uint256[](1);
        counts[0] = 3;

        vm.expectRevert(
            abi.encodeWithSelector(
                JB721TiersHookStore.JB721TiersHookStore_PriceExceedsAmount.selector, 3 * PRICE, 3 * PRICE - 1
            )
        );
        counted.recordMintCounts(3 * PRICE - 1, tierIds, counts);

        counts[0] = 1001;
        vm.expectRevert(
            abi.encodeWithSelector(JB721TiersHookStore.JB721TiersHookStore_InsufficientSupplyRemaining.selector, 2)
        );
        counted.recordMintCounts(1001 * PRICE, tierIds, counts);
    }

    function _cost(uint256 tierId, uint256 count) internal view returns (uint256) {
        JB721Tier memory tier = counted.tierOf(address(this), tierId, false);
        uint256 price = tier.price;
        return (price - price * tier.discountPercent / 200) * count;
    }
}
