// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {TestBaseWorkflow} from "@bananapus/core-v6/test/helpers/TestBaseWorkflow.sol";

import {DefifaGovernor} from "../../src/DefifaGovernor.sol";
import {DefifaDeployer} from "../../src/DefifaDeployer.sol";
import {DefifaHook} from "../../src/DefifaHook.sol";
import {DefifaTokenUriResolver} from "../../src/DefifaTokenUriResolver.sol";
import {JB721TiersHookStore} from "@bananapus/721-hook-v6/src/JB721TiersHookStore.sol";
import {JB721TiersMintReservesConfig} from "@bananapus/721-hook-v6/src/structs/JB721TiersMintReservesConfig.sol";

import {JBTest} from "@bananapus/core-v6/test/helpers/JBTest.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JBRulesetMetadataResolver} from "@bananapus/core-v6/src/libraries/JBRulesetMetadataResolver.sol";
import {JBAddressRegistry} from "@bananapus/address-registry-v6/src/JBAddressRegistry.sol";

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

/// @notice Verifies the fix for H-2: Pending reserve NFTs are now included in the cash-out weight
/// denominator. Before the fix, paid holders could cash out before reserves were minted and extract
/// more than their fair share.
///
/// With BWA + HHI-adjusted quorum, a single-tier winner-take-all scorecard gives the sole beneficiary
/// 0 attestation power (BWA multiplier = 1 - 1 = 0). To allow ratification, we add 3 disinterested
/// tiers (weight = 0) whose attestors provide governance power to meet the adjusted quorum.
contract FixPendingReserveDilutionTest is JBTest, TestBaseWorkflow {
    using JBRulesetMetadataResolver for JBRuleset;

    address _protocolFeeProjectTokenAccount;
    address _defifaProjectTokenAccount;
    uint256 _protocolFeeProjectId;
    uint256 _defifaProjectId;
    uint256 _gameId = 3;

    DefifaDeployer deployer;
    DefifaHook hook;
    DefifaGovernor governor;

    address projectOwner = address(bytes20(keccak256("projectOwner")));
    address reserveBeneficiary = address(bytes20(keccak256("reserveBeneficiary")));
    address player = address(bytes20(keccak256("player")));
    address disinterested1 = address(bytes20(keccak256("disinterested1")));
    address disinterested2 = address(bytes20(keccak256("disinterested2")));
    address disinterested3 = address(bytes20(keccak256("disinterested3")));

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

    /// @notice With the fix, a paid holder's cash-out share is diluted by pending reserves.
    /// The paid holder should NOT be able to reclaim the full post-fee surplus when pending
    /// reserves exist -- the reserve holder's share must be protected.
    function test_paidHolderCashOutDilutedByPendingReserves() external {
        (_pid, _nft, _gov) = _launch(_launchData());

        // Mint phase: player mints 1 NFT into tier 1, disinterested users mint tiers 2-4.
        vm.warp(block.timestamp + 1 days + 1);
        _mint(player, 1, 1 ether);
        _delegateSelf(player, 1);
        vm.warp(block.timestamp + 1);
        _mint(disinterested1, 2, 1 ether);
        _delegateSelf(disinterested1, 2);
        vm.warp(block.timestamp + 1);
        _mint(disinterested2, 3, 1 ether);
        _delegateSelf(disinterested2, 3);
        vm.warp(block.timestamp + 1);
        _mint(disinterested3, 4, 1 ether);
        _delegateSelf(disinterested3, 4);

        // Verify there is a pending reserve for tier 1.
        assertEq(_nft.store().numberOfPendingReservesFor(address(_nft), 1), 1, "one reserve should be pending");

        // Advance to scoring phase.
        vm.warp(block.timestamp + 2 days + 1);

        // Submit scorecard giving all weight to tier 1; tiers 2-4 get 0 (disinterested attestors).
        DefifaTierCashOutWeight[] memory sc = new DefifaTierCashOutWeight[](4);
        sc[0] = DefifaTierCashOutWeight({id: 1, cashOutWeight: _nft.TOTAL_CASHOUT_WEIGHT()});
        sc[1] = DefifaTierCashOutWeight({id: 2, cashOutWeight: 0});
        sc[2] = DefifaTierCashOutWeight({id: 3, cashOutWeight: 0});
        sc[3] = DefifaTierCashOutWeight({id: 4, cashOutWeight: 0});
        uint256 proposalId = _gov.submitScorecardFor(_gameId, sc);

        // Disinterested users attest (they have full BWA power since their tiers get 0 weight).
        // The player (tier 1, 100% weight) has 0 BWA power and cannot meaningfully attest.
        vm.prank(disinterested1);
        _gov.attestToScorecardFrom(_gameId, proposalId);
        vm.prank(disinterested2);
        _gov.attestToScorecardFrom(_gameId, proposalId);
        vm.prank(disinterested3);
        _gov.attestToScorecardFrom(_gameId, proposalId);

        vm.warp(block.timestamp + _gov.attestationGracePeriodOf(_gameId) + 1);
        _gov.ratifyScorecardFrom(_gameId, sc);

        // The player should only reclaim HALF of their tier's share of the post-fee surplus
        // (1 of 2 tokens in tier 1, since the pending reserve counts in the denominator).
        // Note: total pot includes 4 ETH from all minters but tier 1 gets 100% of weight.
        // Fees are taken from the terminal surplus. Post-fee surplus is available for cash-out.
        uint256 postFeeSurplus = 4 ether - (4 ether / 20) - (4 ether / 40);
        // Tier 1 gets 100% weight. Player holds 1 of 2 units (1 paid + 1 pending reserve).
        uint256 expectedPlayerReclaim = postFeeSurplus / 2;

        uint256 beforePlayerBalance = player.balance;
        _cashOut(player, 1, 1);
        uint256 playerReclaim = player.balance - beforePlayerBalance;

        // The player should receive approximately half the surplus, not the full amount.
        assertApproxEqAbs(
            playerReclaim,
            expectedPlayerReclaim,
            1, // 1 wei tolerance for rounding
            "paid holder should only reclaim half due to pending reserve dilution"
        );

        // Specifically, the player should NOT get the full pot.
        assertLt(playerReclaim, postFeeSurplus, "paid holder should NOT reclaim full surplus with pending reserves");
    }

    /// @notice After reserves are minted, the reserve holder should be able to cash out their share.
    function test_reserveHolderCanCashOutAfterMinting() external {
        (_pid, _nft, _gov) = _launch(_launchData());

        // Mint phase: player mints 1 NFT into tier 1, disinterested users mint tiers 2-4.
        vm.warp(block.timestamp + 1 days + 1);
        _mint(player, 1, 1 ether);
        _delegateSelf(player, 1);
        vm.warp(block.timestamp + 1);
        _mint(disinterested1, 2, 1 ether);
        _delegateSelf(disinterested1, 2);
        vm.warp(block.timestamp + 1);
        _mint(disinterested2, 3, 1 ether);
        _delegateSelf(disinterested2, 3);
        vm.warp(block.timestamp + 1);
        _mint(disinterested3, 4, 1 ether);
        _delegateSelf(disinterested3, 4);

        // Advance to scoring phase.
        vm.warp(block.timestamp + 2 days + 1);

        // Submit scorecard: tier 1 gets all weight; tiers 2-4 are disinterested.
        DefifaTierCashOutWeight[] memory sc = new DefifaTierCashOutWeight[](4);
        sc[0] = DefifaTierCashOutWeight({id: 1, cashOutWeight: _nft.TOTAL_CASHOUT_WEIGHT()});
        sc[1] = DefifaTierCashOutWeight({id: 2, cashOutWeight: 0});
        sc[2] = DefifaTierCashOutWeight({id: 3, cashOutWeight: 0});
        sc[3] = DefifaTierCashOutWeight({id: 4, cashOutWeight: 0});
        uint256 proposalId = _gov.submitScorecardFor(_gameId, sc);

        // Disinterested users attest (full BWA power since 0 weight tiers).
        vm.prank(disinterested1);
        _gov.attestToScorecardFrom(_gameId, proposalId);
        vm.prank(disinterested2);
        _gov.attestToScorecardFrom(_gameId, proposalId);
        vm.prank(disinterested3);
        _gov.attestToScorecardFrom(_gameId, proposalId);

        vm.warp(block.timestamp + _gov.attestationGracePeriodOf(_gameId) + 1);
        _gov.ratifyScorecardFrom(_gameId, sc);

        // Mint the reserve NFTs for tier 1.
        JB721TiersMintReservesConfig[] memory reserveConfigs = new JB721TiersMintReservesConfig[](1);
        reserveConfigs[0] = JB721TiersMintReservesConfig({tierId: 1, count: 1});
        _nft.mintReservesFor(reserveConfigs);
        assertEq(_nft.balanceOf(reserveBeneficiary), 1, "reserve NFT should be minted");

        // Now player cashes out.
        uint256 beforePlayerBalance = player.balance;
        _cashOut(player, 1, 1);
        uint256 playerReclaim = player.balance - beforePlayerBalance;

        // Reserve holder cashes out (token ID for tier 1, token number 2).
        uint256 beforeReserveBalance = reserveBeneficiary.balance;
        _cashOut(reserveBeneficiary, 1, 2);
        uint256 reserveReclaim = reserveBeneficiary.balance - beforeReserveBalance;

        // Both should get approximately equal shares.
        assertApproxEqAbs(
            playerReclaim,
            reserveReclaim,
            1, // 1 wei tolerance
            "paid and reserve holders should get equal shares"
        );
    }

    // ---- helpers ----

    function _launchData() internal returns (DefifaLaunchProjectData memory) {
        DefifaTierParams[] memory tp = new DefifaTierParams[](4);
        // Tier 1: has reserves (the tier under test)
        tp[0] = DefifaTierParams({
            reservedRate: 1, // 1 reserve per mint
            reservedTokenBeneficiary: reserveBeneficiary,
            encodedIPFSUri: bytes32(0),
            shouldUseReservedTokenBeneficiaryAsDefault: false,
            name: "TEAM"
        });
        // Tiers 2-4: disinterested attestors (no reserves, standard rate)
        for (uint256 i = 1; i < 4; i++) {
            tp[i] = DefifaTierParams({
                reservedRate: 1001,
                reservedTokenBeneficiary: address(0),
                encodedIPFSUri: bytes32(0),
                shouldUseReservedTokenBeneficiaryAsDefault: false,
                name: "TEAM"
            });
        }

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
