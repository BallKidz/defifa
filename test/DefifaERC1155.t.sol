// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {DefifaDeployer} from "../src/DefifaDeployer.sol";
import {DefifaGovernor} from "../src/DefifaGovernor.sol";
import {DefifaHook} from "../src/DefifaHook.sol";
import {DefifaTokenUriResolver} from "../src/DefifaTokenUriResolver.sol";
import {DefifaGamePhase} from "../src/enums/DefifaGamePhase.sol";
import {IDefifaHook} from "../src/interfaces/IDefifaHook.sol";
import {DefifaHookLib} from "../src/libraries/DefifaHookLib.sol";
import {DefifaLaunchProjectData} from "../src/structs/DefifaLaunchProjectData.sol";
import {DefifaTierParams} from "../src/structs/DefifaTierParams.sol";

import {JBAddressRegistry} from "@bananapus/address-registry-v6/src/JBAddressRegistry.sol";
import {JB721TiersHookStore} from "@bananapus/721-hook-v6/src/JB721TiersHookStore.sol";
import {IJB721TiersHookStore} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHookStore.sol";
import {IJB721TokenUriResolver} from "@bananapus/721-hook-v6/src/interfaces/IJB721TokenUriResolver.sol";
import {JB721TiersMintReservesConfig} from "@bananapus/721-hook-v6/src/structs/JB721TiersMintReservesConfig.sol";
import {JBMultiTerminal} from "@bananapus/core-v6/src/JBMultiTerminal.sol";
import {IJBCashOutHook} from "@bananapus/core-v6/src/interfaces/IJBCashOutHook.sol";
import {JBRulesetConfig, JBTerminalConfig} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBPayHook} from "@bananapus/core-v6/src/interfaces/IJBPayHook.sol";
import {IJBRulesetDataHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetDataHook.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesets.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBCurrencyIds} from "@bananapus/core-v6/src/libraries/JBCurrencyIds.sol";
import {JBRulesetMetadataResolver} from "@bananapus/core-v6/src/libraries/JBRulesetMetadataResolver.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBFundAccessLimitGroup} from "@bananapus/core-v6/src/structs/JBFundAccessLimitGroup.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JBRulesetMetadata} from "@bananapus/core-v6/src/structs/JBRulesetMetadata.sol";
import {JBSplit} from "@bananapus/core-v6/src/structs/JBSplit.sol";
import {JBSplitGroup} from "@bananapus/core-v6/src/structs/JBSplitGroup.sol";
import {JBTest} from "@bananapus/core-v6/test/helpers/JBTest.sol";
import {TestBaseWorkflow} from "@bananapus/core-v6/test/helpers/TestBaseWorkflow.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC1155MetadataURI} from "@openzeppelin/contracts/token/ERC1155/extensions/IERC1155MetadataURI.sol";
import {IERC1155Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice A launched game in its MINT phase with 8 tiers (tier 1 reserves one position per two paid), plus pay,
/// cash-out and metadata helpers.
abstract contract DefifaERC1155Harness is JBTest, TestBaseWorkflow {
    using JBRulesetMetadataResolver for JBRuleset;

    uint256 constant TIER_PRICE = 0.001 ether;
    uint8 constant N_TIERS = 8;
    uint256 constant OFFSET = 1 << 16;

    address projectOwner = makeAddr("projectOwner");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address reserveBeneficiary = makeAddr("reserveBeneficiary");

    DefifaHook hookImpl;
    DefifaHook nft;
    IJB721TiersHookStore store;
    uint256 gameId;
    DefifaLaunchProjectData launchData;
    uint256 launchedAt;

    function setUp() public virtual override {
        super.setUp();

        JBAccountingContext[] memory tokens = new JBAccountingContext[](1);
        tokens[0] = JBAccountingContext({token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: JBCurrencyIds.ETH});
        JBTerminalConfig[] memory terminals = new JBTerminalConfig[](1);
        terminals[0] = JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: tokens});
        JBRulesetConfig[] memory rulesets = new JBRulesetConfig[](1);
        rulesets[0] = JBRulesetConfig({
            mustStartAtOrAfter: 0,
            duration: 10 days,
            weight: 1e18,
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: JBRulesetMetadata({
                reservedPercent: 0,
                cashOutTaxRate: 0,
                baseCurrency: JBCurrencyIds.ETH,
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
                scopeCashOutsToLocalBalances: true,
                useDataHookForPay: true,
                useDataHookForCashOut: true,
                dataHook: address(0),
                metadata: 0
            }),
            splitGroups: new JBSplitGroup[](0),
            fundAccessLimitGroups: new JBFundAccessLimitGroup[](0)
        });

        uint256 protocolFeeProjectId = jbController().launchProjectFor(projectOwner, "", rulesets, terminals, "");
        vm.prank(projectOwner);
        address nanaToken =
            address(jbController().deployERC20For(protocolFeeProjectId, "Bananapus", "NANA", bytes32(0)));
        uint256 defifaProjectId = jbController().launchProjectFor(projectOwner, "", rulesets, terminals, "");
        vm.prank(projectOwner);
        address defifaToken = address(jbController().deployERC20For(defifaProjectId, "Defifa", "DEFIFA", bytes32(0)));

        hookImpl = new DefifaHook(jbDirectory(), IERC20(defifaToken), IERC20(nanaToken));
        DefifaGovernor governor = new DefifaGovernor(jbController(), address(this));
        DefifaDeployer deployer = new DefifaDeployer({
            hookCodeOrigin: address(hookImpl),
            tokenUriResolver: new DefifaTokenUriResolver(address(this)),
            governor: governor,
            controller: jbController(),
            registry: new JBAddressRegistry(),
            defifaProjectId: protocolFeeProjectId,
            baseProtocolProjectId: defifaProjectId,
            hookStore: new JB721TiersHookStore(),
            trustedForwarder: address(0)
        });
        hookImpl.transferOwnership(address(deployer));
        governor.transferOwnership(address(deployer));

        // Tier 1 reserves one position for every two paid ones.
        DefifaTierParams[] memory tiers = new DefifaTierParams[](N_TIERS);
        for (uint256 i; i < N_TIERS; i++) {
            tiers[i] = DefifaTierParams({
                reservedRate: i == 0 ? 2 : 0,
                reservedTokenBeneficiary: i == 0 ? reserveBeneficiary : address(0),
                encodedIpfsUri: bytes32(0),
                shouldUseReservedTokenBeneficiaryAsDefault: false,
                name: "TEAM"
            });
        }

        launchData = DefifaLaunchProjectData({
            name: "DEFIFA",
            projectUri: "",
            contractUri: "",
            baseUri: "",
            token: JBAccountingContext({token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: JBCurrencyIds.ETH}),
            mintPeriodDuration: 1 days,
            start: uint48(block.timestamp + 3 days),
            refundPeriodDuration: 1 days,
            splits: new JBSplit[](0),
            attestationStartTime: 0,
            attestationGracePeriod: 100_381,
            defaultAttestationDelegate: _defaultDelegate(),
            // forge-lint: disable-next-line(unsafe-typecast)
            tierPrice: uint104(TIER_PRICE),
            tiers: tiers,
            defaultTokenUriResolver: IJB721TokenUriResolver(address(0)),
            terminal: jbMultiTerminal(),
            minParticipation: 0,
            scorecardTimeout: type(uint32).max,
            timelockDuration: 0
        });

        launchedAt = block.timestamp;
        gameId = deployer.launchGameWith(launchData);
        JBRuleset memory ruleset = jbRulesets().currentOf(gameId);
        if (ruleset.dataHook() == address(0)) (ruleset,) = jbRulesets().latestQueuedOf(gameId);
        nft = DefifaHook(ruleset.dataHook());
        store = nft.store();

        // Enter the MINT phase.
        vm.warp(launchData.start - launchData.mintPeriodDuration - launchData.refundPeriodDuration);
        assertEq(uint256(nft.gamePhaseReporter().currentGamePhaseOf(gameId)), uint256(DefifaGamePhase.MINT));
    }

    //*********************************************************************//
    // ------------------------------ helpers ---------------------------- //
    //*********************************************************************//

    /// @notice The game's default attestation delegate. Subclasses override it.
    function _defaultDelegate() internal virtual returns (address) {
        return address(0);
    }

    function _pay(address payer, uint16[] memory tierIds, uint256[] memory counts) internal {
        uint256 total;
        for (uint256 i; i < counts.length; i++) {
            total += counts[i] * TIER_PRICE;
        }
        bytes memory metadata = _payMetadata(tierIds, counts);
        vm.deal(payer, payer.balance + total);
        vm.prank(payer);
        jbMultiTerminal().pay{value: total}(gameId, JBConstants.NATIVE_TOKEN, total, payer, 0, "", metadata);
    }

    function _measurePay(address payer, uint256[] memory counts) internal returns (uint256 gasUsed) {
        uint16[] memory tierIds = new uint16[](counts.length);
        uint256 total;
        for (uint256 i; i < counts.length; i++) {
            // forge-lint: disable-next-line(unsafe-typecast)
            tierIds[i] = uint16(i + 1);
            total += counts[i] * TIER_PRICE;
        }
        bytes memory metadata = _payMetadata(tierIds, counts);
        vm.deal(payer, total);
        vm.prank(payer);
        uint256 before = gasleft();
        jbMultiTerminal().pay{value: total}(gameId, JBConstants.NATIVE_TOKEN, total, payer, 0, "", metadata);
        gasUsed = before - gasleft();
    }

    function _expectPayRevert(address payer, uint16[] memory tierIds, uint256[] memory counts, uint256 value) internal {
        // Build the metadata first: cheatcodes apply to the next external call.
        bytes memory metadata = _payMetadata(tierIds, counts);
        vm.deal(payer, value);
        vm.prank(payer);
        vm.expectRevert();
        jbMultiTerminal().pay{value: value}(gameId, JBConstants.NATIVE_TOKEN, value, payer, 0, "", metadata);
    }

    /// @notice Cash out positions. Callers that expect a revert set `vm.expectRevert` before calling this; the
    /// metadata is built through `_cashOutMetadata` first so the cheatcode applies to the terminal call.
    function _cashOut(address holder, uint256[] memory ids, uint256[] memory amounts) internal {
        _cashOutWith(holder, _cashOutMetadata(ids, amounts));
    }

    function _cashOutMetadata(uint256[] memory ids, uint256[] memory amounts) internal view returns (bytes memory) {
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encode(ids, amounts);
        bytes4[] memory metadataIds = new bytes4[](1);
        metadataIds[0] = metadataHelper().getId("cashOut", address(hookImpl));
        return metadataHelper().createMetadata(metadataIds, data);
    }

    function _cashOutWith(address holder, bytes memory metadata) internal {
        vm.prank(holder);
        JBMultiTerminal(address(jbMultiTerminal()))
            .cashOutTokensOf({
            holder: holder,
            projectId: gameId,
            cashOutCount: 0,
            tokenToReclaim: JBConstants.NATIVE_TOKEN,
            minTokensReclaimed: 0,
            beneficiary: payable(holder),
            metadata: metadata
        });
    }

    function _payMetadata(uint16[] memory tierIds, uint256[] memory counts) internal view returns (bytes memory) {
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encode(address(0), tierIds, counts);
        bytes4[] memory ids = new bytes4[](1);
        ids[0] = metadataHelper().getId("pay", address(hookImpl));
        return metadataHelper().createMetadata(ids, data);
    }

    function _ids(uint16 a, uint16 b) internal pure returns (uint16[] memory ids) {
        ids = new uint16[](2);
        ids[0] = a;
        ids[1] = b;
    }

    function _counts(uint256 a, uint256 b) internal pure returns (uint256[] memory counts) {
        counts = new uint256[](2);
        counts[0] = a;
        counts[1] = b;
    }

    /// @notice Spread `total` positions as evenly as possible across the first `tiers` tiers.
    function _spread(uint256 tiers, uint256 total) internal pure returns (uint256[] memory counts) {
        counts = new uint256[](tiers);
        for (uint256 i; i < tiers; i++) {
            counts[i] = total / tiers + (i < total % tiers ? 1 : 0);
        }
    }
}

/// @notice Behavior that is specific to ERC-1155 positions: counts, reserve IDs, batch transfers, burn accounting,
/// interface surface, and the gas a large entry costs.
contract DefifaERC1155Test is DefifaERC1155Harness {
    //*********************************************************************//
    // ------------------------------ minting ---------------------------- //
    //*********************************************************************//

    function test_payMintsOneBalancePerTier() public {
        _pay(alice, _ids(2, 5), _counts(3, 7));

        assertEq(nft.balanceOf(alice, 2), 3, "tier 2 balance");
        assertEq(nft.balanceOf(alice, 5), 7, "tier 5 balance");
        assertEq(nft.currentSupplyOfTier(2), 3, "tier 2 supply");
        assertEq(nft.currentSupplyOfTier(5), 7, "tier 5 supply");
        assertEq(nft.totalMintCost(), 10 * TIER_PRICE, "total mint cost");

        // Voting units default to the tier price per position; the payer is their own delegate.
        assertEq(nft.getTierAttestationUnitsOf(alice, 2), 3 * TIER_PRICE, "tier 2 units");
        assertEq(nft.getTierAttestationUnitsOf(alice, 5), 7 * TIER_PRICE, "tier 5 units");
        assertEq(nft.getTierTotalAttestationUnitsOf(5), 7 * TIER_PRICE, "tier 5 total units");
    }

    function test_payRejectsDuplicateUnsortedEmptyAndMismatchedTiers() public {
        uint16[] memory duplicate = new uint16[](2);
        duplicate[0] = 3;
        duplicate[1] = 3;
        _expectPayRevert(alice, duplicate, _counts(1, 1), 2 * TIER_PRICE);

        _expectPayRevert(alice, _ids(4, 2), _counts(1, 1), 2 * TIER_PRICE);
        _expectPayRevert(alice, _ids(2, 4), _counts(1, 0), TIER_PRICE);

        uint256[] memory oneCount = new uint256[](1);
        oneCount[0] = 1;
        _expectPayRevert(alice, _ids(2, 4), oneCount, TIER_PRICE);
    }

    function test_payRejectsOverAndUnderpayment() public {
        // Paying for 3 positions with 4 positions' worth leaves an unspent amount.
        _expectPayRevert(alice, _ids(1, 2), _counts(1, 2), 4 * TIER_PRICE);
        // Paying less than the positions cost fails in the store's price check.
        _expectPayRevert(alice, _ids(1, 2), _counts(1, 2), 2 * TIER_PRICE);
    }

    //*********************************************************************//
    // ----------------------------- transfers --------------------------- //
    //*********************************************************************//

    function test_transfersMoveAttestationUnits() public {
        _pay(alice, _ids(2, 3), _counts(4, 6));

        vm.prank(alice);
        nft.safeTransferFrom(alice, bob, 2, 1, "");
        assertEq(nft.getTierAttestationUnitsOf(alice, 2), 3 * TIER_PRICE, "alice tier 2 after single");
        assertEq(nft.getTierAttestationUnitsOf(bob, 2), TIER_PRICE, "bob tier 2 after single");

        uint256[] memory ids = new uint256[](2);
        ids[0] = 2;
        ids[1] = 3;
        vm.prank(alice);
        nft.safeBatchTransferFrom(alice, bob, ids, _counts(3, 6), "");

        assertEq(nft.balanceOf(alice, 2) + nft.balanceOf(alice, 3), 0, "alice emptied");
        assertEq(nft.getTierAttestationUnitsOf(alice, 2) + nft.getTierAttestationUnitsOf(alice, 3), 0, "alice units");
        assertEq(nft.getTierAttestationUnitsOf(bob, 2), 4 * TIER_PRICE, "bob tier 2 units");
        assertEq(nft.getTierAttestationUnitsOf(bob, 3), 6 * TIER_PRICE, "bob tier 3 units");

        // Transfers neither mint nor burn attestation units.
        assertEq(nft.getTierTotalAttestationUnitsOf(2), 4 * TIER_PRICE, "tier 2 total conserved");
        assertEq(nft.getTierTotalAttestationUnitsOf(3), 6 * TIER_PRICE, "tier 3 total conserved");
    }

    function test_storePerHolderViewsAreNotMaintained() public {
        _pay(alice, _ids(2, 3), _counts(4, 6));

        // Holder balances live in the hook. The store keeps tier and supply accounting only.
        assertEq(store.balanceOf(address(nft), alice), 0, "store balanceOf");
        assertEq(store.tierBalanceOf(address(nft), alice, 2), 0, "store tierBalanceOf");
        assertEq(store.totalSupplyOf(address(nft)), 10, "store total supply still tracks mints");
    }

    //*********************************************************************//
    // ------------------------------ cash-outs -------------------------- //
    //*********************************************************************//

    function test_refundBurnsAmountsAndRecordsBurns() public {
        _pay(alice, _ids(2, 3), _counts(3, 2));
        uint256 balanceBefore = alice.balance;

        uint256[] memory ids = new uint256[](2);
        ids[0] = 2;
        ids[1] = 3;
        _cashOut(alice, ids, _counts(2, 2));

        assertEq(alice.balance - balanceBefore, 4 * TIER_PRICE, "refunded the mint price");
        assertEq(nft.balanceOf(alice, 2), 1, "tier 2 left");
        assertEq(nft.balanceOf(alice, 3), 0, "tier 3 left");
        assertEq(store.numberOfBurnedFor(address(nft), 2), 2, "store burns tier 2");
        assertEq(store.numberOfBurnedFor(address(nft), 3), 2, "store burns tier 3");
        assertEq(nft.refundedBurnsFrom(2), 2, "refund burns tier 2");
        assertEq(nft.tokensRedeemedFrom(2), 0, "no COMPLETE redemptions");
        assertEq(nft.currentSupplyOfTier(2), 1, "tier 2 supply");
        assertEq(nft.totalMintCost(), TIER_PRICE, "total mint cost");
        assertEq(nft.getTierAttestationUnitsOf(alice, 2), TIER_PRICE, "tier 2 units");
        assertEq(nft.getTierTotalAttestationUnitsOf(3), 0, "tier 3 total units");
    }

    function test_cashOutMoreThanHeldReverts() public {
        _pay(alice, _ids(2, 3), _counts(1, 1));
        _pay(bob, _ids(2, 3), _counts(1, 1));

        uint256[] memory ids = new uint256[](1);
        ids[0] = 2;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 2;

        bytes memory overdraw = _cashOutMetadata(ids, amounts);
        vm.expectRevert(abi.encodeWithSelector(DefifaHook.DefifaHook_Unauthorized.selector, 2, 2, 1, alice));
        _cashOutWith(alice, overdraw);

        // Duplicate IDs that together exceed the balance fail in the batch burn.
        uint256[] memory duplicateIds = new uint256[](2);
        duplicateIds[0] = 2;
        duplicateIds[1] = 2;
        bytes memory duplicates = _cashOutMetadata(duplicateIds, _counts(1, 1));
        vm.expectRevert(abi.encodeWithSelector(IERC1155Errors.ERC1155InsufficientBalance.selector, alice, 0, 1, 2));
        _cashOutWith(alice, duplicates);
    }

    //*********************************************************************//
    // ------------------------------ reserves --------------------------- //
    //*********************************************************************//

    function test_reservesUseTheReserveIdAndCountTowardTheTier() public {
        _pay(alice, _ids(1, 2), _counts(4, 1));

        // Reserve minting is paused until SCORING.
        vm.warp(launchData.start);
        assertEq(nft.adjustedPendingReservesFor(1), 2, "two pending reserves");

        JB721TiersMintReservesConfig[] memory configs = new JB721TiersMintReservesConfig[](1);
        configs[0] = JB721TiersMintReservesConfig({tierId: 1, count: 2});
        nft.mintReservesFor(configs);

        uint256 reserveId = 1 + OFFSET;
        assertEq(nft.balanceOf(reserveBeneficiary, reserveId), 2, "reserve balance");
        assertEq(nft.balanceOf(reserveBeneficiary, 1), 0, "no paid balance");
        assertEq(nft.tierIdOf(reserveId), 1, "reserve ID maps to its tier");
        assertEq(nft.currentSupplyOfTier(1), 6, "supply includes reserves");
        assertEq(nft.totalMintCost(), 7 * TIER_PRICE, "reserves count at tier price");
        assertEq(nft.getTierAttestationUnitsOf(reserveBeneficiary, 1), 2 * TIER_PRICE, "reserve units");

        // A refund prices reserve positions at zero; a fee-token claim prices them like paid ones.
        uint256[] memory ids = new uint256[](2);
        ids[0] = 1;
        ids[1] = reserveId;
        assertEq(
            DefifaHookLib.computeCumulativeMintPriceForCashOut({
                tokenIds: ids, amounts: _counts(1, 2), hookStore: store, hook: address(nft), excludeReserveMints: true
            }),
            TIER_PRICE,
            "refund excludes reserves"
        );
        assertEq(
            DefifaHookLib.computeCumulativeMintPriceForCashOut({
                tokenIds: ids, amounts: _counts(1, 2), hookStore: store, hook: address(nft), excludeReserveMints: false
            }),
            3 * TIER_PRICE,
            "claims include reserves"
        );
    }

    //*********************************************************************//
    // ------------------------- interface surface ----------------------- //
    //*********************************************************************//

    function test_tokenIdRanges() public view {
        assertEq(nft.RESERVE_TOKEN_ID_OFFSET(), OFFSET, "offset");
        assertEq(nft.tierIdOf(7), 7, "paid ID");
        assertEq(nft.tierIdOf(OFFSET + 7), 7, "reserve ID");
    }

    function test_tokenIdRangesRejectInvalidIds() public {
        uint256[3] memory invalid = [uint256(0), OFFSET, 2 * OFFSET];
        for (uint256 i; i < invalid.length; i++) {
            vm.expectRevert(abi.encodeWithSelector(DefifaHookLib.DefifaHook_InvalidTokenId.selector, invalid[i]));
            nft.tierIdOf(invalid[i]);
        }
    }

    function test_supportsInterfacesAndMetadata() public {
        assertTrue(nft.supportsInterface(type(IERC1155).interfaceId), "IERC1155");
        assertTrue(nft.supportsInterface(type(IERC1155MetadataURI).interfaceId), "IERC1155MetadataURI");
        assertTrue(nft.supportsInterface(type(IDefifaHook).interfaceId), "IDefifaHook");
        assertTrue(nft.supportsInterface(type(IJBRulesetDataHook).interfaceId), "IJBRulesetDataHook");
        assertTrue(nft.supportsInterface(type(IJBPayHook).interfaceId), "IJBPayHook");
        assertTrue(nft.supportsInterface(type(IJBCashOutHook).interfaceId), "IJBCashOutHook");
        assertEq(nft.name(), "DEFIFA", "name");
        // `uri` defers to the resolver with the 1155 ID; the renderer's font contract is not deployed here.
        address resolver = address(store.tokenUriResolverOf(address(nft)));
        for (uint256 id = 1; id <= OFFSET + 1; id += OFFSET) {
            vm.mockCall(
                resolver, abi.encodeCall(IJB721TokenUriResolver.tokenUriOf, (address(nft), id)), abi.encode("card")
            );
            assertEq(nft.uri(id), "card", "uri defers to the resolver");
        }
        assertEq(nft.METADATA_ID_TARGET(), address(hookImpl), "metadata target is the implementation");
    }

    //*********************************************************************//
    // -------------------------------- gas ------------------------------ //
    //*********************************************************************//

    /// @notice A large entry must fit Base's 2^24 per-transaction gas cap with the SDK's 2x estimate headroom.
    function test_gas_largeEntriesFitBaseTransactionCap() public {
        uint256 single = _measurePay(alice, _spread(1, 160));
        uint256 thousand = _measurePay(bob, _spread(8, 1000));
        emit log_named_uint("gas, 160 positions in 1 tier", single);
        emit log_named_uint("gas, 1000 positions in 8 tiers", thousand);
        assertLt(thousand * 2, 1 << 24, "1000 positions fit with 2x headroom");
    }
}
