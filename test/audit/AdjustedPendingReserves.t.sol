// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {TestBaseWorkflow} from "@bananapus/core-v6/test/helpers/TestBaseWorkflow.sol";
import {JBTest} from "@bananapus/core-v6/test/helpers/JBTest.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JBRulesetMetadataResolver} from "@bananapus/core-v6/src/libraries/JBRulesetMetadataResolver.sol";
import {JBAddressRegistry} from "@bananapus/address-registry-v6/src/JBAddressRegistry.sol";

import {DefifaDeployer} from "../../src/DefifaDeployer.sol";
import {DefifaGovernor} from "../../src/DefifaGovernor.sol";
import {DefifaHook} from "../../src/DefifaHook.sol";
import {DefifaTokenUriResolver} from "../../src/DefifaTokenUriResolver.sol";
import {JB721TiersHookStore} from "@bananapus/721-hook-v6/src/JB721TiersHookStore.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ITypeface} from "lib/typeface/contracts/interfaces/ITypeface.sol";
import {IJB721TokenUriResolver} from "@bananapus/721-hook-v6/src/interfaces/IJB721TokenUriResolver.sol";

import {DefifaDelegation} from "../../src/structs/DefifaDelegation.sol";
import {DefifaLaunchProjectData} from "../../src/structs/DefifaLaunchProjectData.sol";
import {DefifaTierParams} from "../../src/structs/DefifaTierParams.sol";
import {DefifaTierCashOutWeight} from "../../src/structs/DefifaTierCashOutWeight.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBTerminalConfig} from "@bananapus/core-v6/src/structs/JBTerminalConfig.sol";
import {JBRulesetConfig} from "@bananapus/core-v6/src/structs/JBRulesetConfig.sol";
import {JBRulesetMetadata} from "@bananapus/core-v6/src/structs/JBRulesetMetadata.sol";
import {JBSplitGroup} from "@bananapus/core-v6/src/structs/JBSplitGroup.sol";
import {JBFundAccessLimitGroup} from "@bananapus/core-v6/src/structs/JBFundAccessLimitGroup.sol";
import {JBSplit} from "@bananapus/core-v6/src/structs/JBSplit.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBCurrencyIds} from "@bananapus/core-v6/src/libraries/JBCurrencyIds.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetApprovalHook.sol";

/// @dev Helper to read block.timestamp via an external call, bypassing the via-ir optimizer's timestamp caching.
contract TimestampReader {
    function timestamp() external view returns (uint256) {
        return block.timestamp;
    }
}

/// @notice Tests for adjustedPendingReservesFor — recalculates pending reserves after
/// refund-phase burns, accounting for the non-linear relationship between burns and
/// reserve entitlements (ceil(adjustedMints / reserveFrequency) - reservesMinted).
contract AdjustedPendingReservesTest is JBTest, TestBaseWorkflow {
    using JBRulesetMetadataResolver for JBRuleset;

    TimestampReader private _tsReader = new TimestampReader();

    address projectOwner = address(bytes20(keccak256("projectOwner")));
    address reserveBeneficiary = address(bytes20(keccak256("reserveBeneficiary")));
    address player = address(bytes20(keccak256("player")));
    address disinterested1 = address(bytes20(keccak256("disinterested1")));
    address disinterested2 = address(bytes20(keccak256("disinterested2")));
    address disinterested3 = address(bytes20(keccak256("disinterested3")));

    uint256 _protocolFeeProjectId;
    uint256 _defifaProjectId;
    address _protocolFeeProjectTokenAccount;
    address _defifaProjectTokenAccount;
    uint256 _gameId = 3;

    DefifaDeployer deployer;
    DefifaHook hook;
    DefifaGovernor governor;

    uint256 _pid;
    DefifaHook _nft;
    DefifaGovernor _gov;

    function setUp() public virtual override {
        super.setUp();

        JBAccountingContext[] memory _tokens = new JBAccountingContext[](1);
        _tokens[0] = JBAccountingContext({token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: JBCurrencyIds.ETH});
        JBTerminalConfig[] memory tc = new JBTerminalConfig[](1);
        tc[0] = JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: _tokens});
        JBRulesetConfig[] memory rc = new JBRulesetConfig[](1);
        rc[0] = JBRulesetConfig({
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
                useTotalSurplusForCashOuts: false,
                useDataHookForPay: true,
                useDataHookForCashOut: true,
                dataHook: address(0),
                metadata: 0
            }),
            splitGroups: new JBSplitGroup[](0),
            fundAccessLimitGroups: new JBFundAccessLimitGroup[](0)
        });

        _protocolFeeProjectId = jbController().launchProjectFor(projectOwner, "", rc, tc, "");
        vm.prank(projectOwner);
        _protocolFeeProjectTokenAccount =
            address(jbController().deployERC20For(_protocolFeeProjectId, "Bananapus", "NANA", bytes32(0)));
        _defifaProjectId = jbController().launchProjectFor(projectOwner, "", rc, tc, "");
        vm.prank(projectOwner);
        _defifaProjectTokenAccount =
            address(jbController().deployERC20For(_defifaProjectId, "Defifa", "DEFIFA", bytes32(0)));

        hook =
            new DefifaHook(jbDirectory(), IERC20(_defifaProjectTokenAccount), IERC20(_protocolFeeProjectTokenAccount));
        governor = new DefifaGovernor(jbController(), address(this));
        deployer = new DefifaDeployer(
            address(hook),
            new DefifaTokenUriResolver(ITypeface(address(0))),
            governor,
            jbController(),
            new JBAddressRegistry(),
            _protocolFeeProjectId,
            _defifaProjectId,
            new JB721TiersHookStore()
        );
        hook.transferOwnership(address(deployer));
        governor.transferOwnership(address(deployer));
    }

    // ================================================================
    // Test 1: No burns — adjusted value matches the store directly
    // ================================================================
    function test_noBurns_matchesStoreValue() external {
        DefifaLaunchProjectData memory data = _launchData(5);
        (_pid, _nft, _gov) = _launch(data);

        // Enter MINT phase.
        vm.warp(data.start - data.mintPeriodDuration - data.refundPeriodDuration);
        for (uint256 i; i < 10; i++) {
            _mint(player, 1, 1 ether);
            vm.warp(_tsReader.timestamp() + 1);
        }

        // With 10 paid mints and freq=5: ceil(10/5) = 2 pending reserves.
        uint256 storeValue = _nft.store().numberOfPendingReservesFor(address(_nft), 1);
        uint256 adjusted = _nft.adjustedPendingReservesFor(1);

        assertEq(storeValue, 2, "store should show 2 pending reserves");
        assertEq(adjusted, storeValue, "with no burns, adjusted should equal store value");
    }

    // ================================================================
    // Test 2: Partial burns that don't cross a frequency boundary
    // ================================================================
    function test_partialBurns_noReserveReduction() external {
        DefifaLaunchProjectData memory data = _launchData(5);
        (_pid, _nft, _gov) = _launch(data);

        // Mint 10 tokens from tier 1 during MINT phase.
        vm.warp(data.start - data.mintPeriodDuration - data.refundPeriodDuration);
        for (uint256 i; i < 10; i++) {
            _mint(player, 1, 1 ether);
            vm.warp(_tsReader.timestamp() + 1);
        }

        // Advance to REFUND phase and cash out 4 tokens.
        vm.warp(data.start - data.refundPeriodDuration);
        for (uint256 i = 1; i <= 4; i++) {
            _cashOut(player, 1, i);
            vm.warp(_tsReader.timestamp() + 1);
        }

        // Store still shows 2 (doesn't know about refund burns).
        uint256 storeValue = _nft.store().numberOfPendingReservesFor(address(_nft), 1);
        assertEq(storeValue, 2, "store still shows 2 pending (unaware of burns)");

        // adjustedMints = 10 - 4 = 6, ceil(6/5) = 2. Same as before burns.
        assertEq(_nft.adjustedPendingReservesFor(1), 2, "4 burns don't cross frequency boundary");
    }

    // ================================================================
    // Test 3: Burns that cross a frequency boundary reduce reserves
    // ================================================================
    function test_burnsReduceReserves() external {
        DefifaLaunchProjectData memory data = _launchData(5);
        (_pid, _nft, _gov) = _launch(data);

        // Mint 10 tokens from tier 1 during MINT phase.
        vm.warp(data.start - data.mintPeriodDuration - data.refundPeriodDuration);
        for (uint256 i; i < 10; i++) {
            _mint(player, 1, 1 ether);
            vm.warp(_tsReader.timestamp() + 1);
        }

        // Advance to REFUND phase and cash out 5 tokens.
        vm.warp(data.start - data.refundPeriodDuration);
        for (uint256 i = 1; i <= 5; i++) {
            _cashOut(player, 1, i);
            vm.warp(_tsReader.timestamp() + 1);
        }

        // Store still shows 2 (unaware of burns).
        assertEq(
            _nft.store().numberOfPendingReservesFor(address(_nft), 1),
            2,
            "store still shows 2 pending (unaware of burns)"
        );

        // adjustedMints = 10 - 5 = 5, ceil(5/5) = 1. Reduced from 2 to 1.
        assertEq(_nft.adjustedPendingReservesFor(1), 1, "5 burns cross frequency boundary: 2 -> 1");
    }

    // ================================================================
    // Test 4: All tokens burned returns zero pending reserves
    // ================================================================
    function test_allBurned_returnsZero() external {
        DefifaLaunchProjectData memory data = _launchData(5);
        (_pid, _nft, _gov) = _launch(data);

        // Mint 10 tokens from tier 1 during MINT phase.
        vm.warp(data.start - data.mintPeriodDuration - data.refundPeriodDuration);
        for (uint256 i; i < 10; i++) {
            _mint(player, 1, 1 ether);
            vm.warp(_tsReader.timestamp() + 1);
        }

        // Advance to REFUND phase and cash out all 10 tokens.
        vm.warp(data.start - data.refundPeriodDuration);
        for (uint256 i = 1; i <= 10; i++) {
            _cashOut(player, 1, i);
            vm.warp(_tsReader.timestamp() + 1);
        }

        // Store still shows 2 (oblivious to all the burns).
        assertEq(
            _nft.store().numberOfPendingReservesFor(address(_nft), 1),
            2,
            "store still shows 2 pending (unaware of burns)"
        );

        // adjustedMints = 10 - 10 = 0, 0 pending reserves.
        assertEq(_nft.adjustedPendingReservesFor(1), 0, "all burned: 0 pending reserves");
    }

    // ================================================================
    // Test 5: Tier with reserveFrequency=0 returns 0 when burns exist
    // ================================================================
    function test_reserveFrequencyZero_returnsZero() external {
        DefifaLaunchProjectData memory data = _launchData(5);
        (_pid, _nft, _gov) = _launch(data);

        // Mint 3 tokens from tier 2 (reserveFrequency=0) during MINT phase.
        vm.warp(data.start - data.mintPeriodDuration - data.refundPeriodDuration);
        for (uint256 i; i < 3; i++) {
            _mint(player, 2, 1 ether);
            vm.warp(_tsReader.timestamp() + 1);
        }

        // Advance to REFUND phase and cash out 1 token from tier 2.
        vm.warp(data.start - data.refundPeriodDuration);
        _cashOut(player, 2, 1);

        // reserveFrequency=0 + refundBurns > 0 -> returns 0.
        assertEq(_nft.adjustedPendingReservesFor(2), 0, "freq=0 tier returns 0 pending reserves");
    }

    // ================================================================
    // Test 6: cashOutWeightOf uses adjusted reserves in its denominator
    // ================================================================
    function test_cashOutWeight_usesAdjustedReserves() external {
        // Use reserveFrequency=1 so each paid mint generates 1 pending reserve.
        DefifaLaunchProjectData memory data = _launchData(1);
        (_pid, _nft, _gov) = _launch(data);

        // MINT phase: player mints 3 tokens from tier 1, others mint disinterested tiers.
        vm.warp(data.start - data.mintPeriodDuration - data.refundPeriodDuration);
        for (uint256 i; i < 3; i++) {
            _mint(player, 1, 1 ether);
            vm.warp(_tsReader.timestamp() + 1);
        }
        _delegateSelf(player, 1);
        vm.warp(_tsReader.timestamp() + 1);
        _mint(disinterested1, 2, 1 ether);
        _delegateSelf(disinterested1, 2);
        vm.warp(_tsReader.timestamp() + 1);
        _mint(disinterested2, 3, 1 ether);
        _delegateSelf(disinterested2, 3);
        vm.warp(_tsReader.timestamp() + 1);
        _mint(disinterested3, 4, 1 ether);
        _delegateSelf(disinterested3, 4);
        vm.warp(_tsReader.timestamp() + 1);

        // Verify: 3 paid mints with freq=1 -> 3 pending reserves.
        assertEq(_nft.store().numberOfPendingReservesFor(address(_nft), 1), 3, "3 pending reserves before refund");

        // REFUND phase: player cashes out token 1.
        vm.warp(data.start - data.refundPeriodDuration);
        _cashOut(player, 1, 1);
        vm.warp(_tsReader.timestamp() + 1);

        // After 1 refund burn: adjustedMints=2, ceil(2/1)=2 pending reserves (down from 3).
        assertEq(_nft.adjustedPendingReservesFor(1), 2, "2 adjusted pending reserves after 1 refund burn");

        // Advance to SCORING phase.
        vm.warp(data.start);

        // Submit scorecard: tier 1 gets all weight, tiers 2-4 get 0.
        DefifaTierCashOutWeight[] memory sc = new DefifaTierCashOutWeight[](4);
        sc[0] = DefifaTierCashOutWeight({id: 1, cashOutWeight: _nft.TOTAL_CASHOUT_WEIGHT()});
        sc[1] = DefifaTierCashOutWeight({id: 2, cashOutWeight: 0});
        sc[2] = DefifaTierCashOutWeight({id: 3, cashOutWeight: 0});
        sc[3] = DefifaTierCashOutWeight({id: 4, cashOutWeight: 0});
        uint256 proposalId = _gov.submitScorecardFor(_gameId, sc);

        // Disinterested users attest.
        vm.prank(disinterested1);
        _gov.attestToScorecardFrom(_gameId, proposalId);
        vm.prank(disinterested2);
        _gov.attestToScorecardFrom(_gameId, proposalId);
        vm.prank(disinterested3);
        _gov.attestToScorecardFrom(_gameId, proposalId);

        vm.warp(_tsReader.timestamp() + _gov.attestationGracePeriodOf(_gameId) + 1);
        _gov.ratifyScorecardFrom(_gameId, sc);

        // COMPLETE phase: verify cashOutWeightOf for a single token.
        // Denominator = (3 minted - (1 burn - 0 redeemed)) + 2 adjusted pending = 4
        // Weight per token = TOTAL_CASHOUT_WEIGHT / 4
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 1_000_000_002; // player's second token (first was burned in refund)
        uint256 weight = _nft.cashOutWeightOf(tokenIds);

        uint256 expectedWeight = _nft.TOTAL_CASHOUT_WEIGHT() / 4;
        assertEq(weight, expectedWeight, "cashout weight denominator includes adjusted reserves");
    }

    // ---- helpers ----

    function _launchData(uint16 tier1Freq) internal view returns (DefifaLaunchProjectData memory) {
        DefifaTierParams[] memory tp = new DefifaTierParams[](4);
        tp[0] = DefifaTierParams({
            reservedRate: tier1Freq,
            reservedTokenBeneficiary: reserveBeneficiary,
            encodedIPFSUri: bytes32(0),
            shouldUseReservedTokenBeneficiaryAsDefault: false,
            name: "TEAM1"
        });
        // Tier 2: reserveFrequency=0 (for the freq=0 test)
        tp[1] = DefifaTierParams({
            reservedRate: 0,
            reservedTokenBeneficiary: address(0),
            encodedIPFSUri: bytes32(0),
            shouldUseReservedTokenBeneficiaryAsDefault: false,
            name: "TEAM2"
        });
        // Tiers 3-4: disinterested attestors
        tp[2] = DefifaTierParams({
            reservedRate: 1001,
            reservedTokenBeneficiary: address(0),
            encodedIPFSUri: bytes32(0),
            shouldUseReservedTokenBeneficiaryAsDefault: false,
            name: "TEAM3"
        });
        tp[3] = DefifaTierParams({
            reservedRate: 1001,
            reservedTokenBeneficiary: address(0),
            encodedIPFSUri: bytes32(0),
            shouldUseReservedTokenBeneficiaryAsDefault: false,
            name: "TEAM4"
        });

        return DefifaLaunchProjectData({
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
            defaultAttestationDelegate: address(0),
            tierPrice: 1 ether,
            tiers: tp,
            defaultTokenUriResolver: IJB721TokenUriResolver(address(0)),
            terminal: jbMultiTerminal(),
            minParticipation: 0,
            scorecardTimeout: 0,
            timelockDuration: 0
        });
    }

    function _launch(DefifaLaunchProjectData memory d) internal returns (uint256 p, DefifaHook n, DefifaGovernor g) {
        g = governor;
        p = deployer.launchGameWith(d);
        JBRuleset memory fc = jbRulesets().currentOf(p);
        if (fc.dataHook() == address(0)) (fc,) = jbRulesets().latestQueuedOf(p);
        n = DefifaHook(fc.dataHook());
    }

    function _mint(address user, uint256 tid, uint256 amt) internal {
        vm.deal(user, amt);
        uint16[] memory m = new uint16[](1);
        // forge-lint: disable-next-line(unsafe-typecast)
        m[0] = uint16(tid);
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encode(user, m);
        bytes4[] memory ids = new bytes4[](1);
        ids[0] = metadataHelper().getId("pay", address(hook));
        bytes memory metadata = metadataHelper().createMetadata(ids, data);
        vm.prank(user);
        jbMultiTerminal().pay{value: amt}(_pid, JBConstants.NATIVE_TOKEN, amt, user, 0, "", metadata);
    }

    function _delegateSelf(address user, uint256 tid) internal {
        DefifaDelegation[] memory dd = new DefifaDelegation[](1);
        dd[0] = DefifaDelegation({delegatee: user, tierId: tid});
        vm.prank(user);
        _nft.setTierDelegatesTo(dd);
    }

    function _cashOut(address user, uint256 tid, uint256 tnum) internal {
        bytes memory meta = _cashOutMeta(tid, tnum);
        vm.prank(user);
        jbMultiTerminal()
            .cashOutTokensOf({
                holder: user,
                projectId: _pid,
                cashOutCount: 0,
                tokenToReclaim: JBConstants.NATIVE_TOKEN,
                minTokensReclaimed: 0,
                beneficiary: payable(user),
                metadata: meta
            });
    }

    function _cashOutMeta(uint256 tid, uint256 tnum) internal view returns (bytes memory) {
        uint256[] memory cid = new uint256[](1);
        cid[0] = (tid * 1_000_000_000) + tnum;
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encode(cid);
        bytes4[] memory ids = new bytes4[](1);
        ids[0] = metadataHelper().getId("cashOut", address(hook));
        return metadataHelper().createMetadata(ids, data);
    }
}
