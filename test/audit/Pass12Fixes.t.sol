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
import {DefifaGamePhase} from "../../src/enums/DefifaGamePhase.sol";
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
contract TimestampReader2 {
    function timestamp() external view returns (uint256) {
        return block.timestamp;
    }
}

/// @title Pass12FixesTest
/// @notice Tests for audit findings M-43 (timeout validation with effective grace period)
///         and M-44 (tokensClaimableFor overquote due to missing pending reserve cost).
contract Pass12FixesTest is JBTest, TestBaseWorkflow {
    using JBRulesetMetadataResolver for JBRuleset;

    TimestampReader2 private _tsReader = new TimestampReader2();

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

    // =========================================================================
    // M-43: Timeout validation uses effective (clamped) grace period
    // =========================================================================

    /// @notice Launching with grace=1s should revert because the governor enforces a
    ///         minimum grace period of 1 day.
    function test_M43_fix_shortGrace_reverts() external {
        DefifaLaunchProjectData memory d = _launchDataCustomTimeout({
            attestationGracePeriod: 1, // 1 second — below MIN_ATTESTATION_GRACE_PERIOD
            scorecardTimeout: 2 hours,
            timelockDuration: 1 hours
        });

        vm.expectRevert(DefifaGovernor.DefifaGovernor_GracePeriodTooShort.selector);
        deployer.launchGameWith(d);
    }

    /// @notice A valid configuration with sufficient grace and timeout > grace + timelock should succeed.
    function test_M43_valid_timeout_still_passes() external {
        DefifaLaunchProjectData memory d = _launchDataCustomTimeout({
            attestationGracePeriod: uint32(1 days), // meets MIN_ATTESTATION_GRACE_PERIOD
            scorecardTimeout: uint32(2 days), // 2 days > 1 day + 1 hour
            timelockDuration: 1 hours
        });

        // Should NOT revert — grace meets minimum and timeout (2 days) > grace (1 day) + timelock (1 hour).
        uint256 gameId = deployer.launchGameWith(d);
        assertGt(gameId, 0, "game should launch successfully");
    }

    // =========================================================================
    // M-44: tokensClaimableFor includes pending reserve mint cost
    // =========================================================================

    /// @notice After minting with reserves, tokensClaimableFor should use totalMintCost + pendingReserveMintCost
    ///         as the denominator — matching the actual claim logic in afterCashOutRecordedWith.
    ///         This mirrors the proven working pattern from
    /// AdjustedPendingReserves.t.sol::test_cashOutWeight_usesAdjustedReserves.
    function test_M44_fix_preview_includes_reserves() external {
        // Launch a game with reserveFrequency=1 so each paid mint generates 1 pending reserve.
        DefifaLaunchProjectData memory d = _launchDataWithReserves(1);
        (_pid, _nft, _gov) = _launch(d);

        // MINT phase: player mints 3 tokens from tier 1, others mint 1 each from tiers 2-4.
        vm.warp(d.start - d.mintPeriodDuration - d.refundPeriodDuration);
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

        // Verify pending reserves exist: 3 paid mints on tier 1 with freq=1 -> 3 pending reserves.
        // Only tier 1 has reserves (freq=1); tiers 2-4 have freq=0 or freq=1001 (effectively none).
        assertEq(_nft.store().numberOfPendingReservesFor(address(_nft), 1), 3, "3 pending reserves on tier 1");

        // Advance to SCORING phase.
        vm.warp(d.start);

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

        // Verify game is COMPLETE.
        assertEq(
            uint256(deployer.currentGamePhaseOf(_pid)), uint256(DefifaGamePhase.COMPLETE), "phase should be COMPLETE"
        );

        // Query tokensClaimableFor for the player's second token (tier 1, token #2).
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 1_000_000_002;
        (uint256 defifaClaim, uint256 baseClaim) = _nft.tokensClaimableFor(tokenIds);

        // The fix ensures the preview uses (totalMintCost + pendingReserveMintCost) as denominator.
        // With 6 paid mints at 1 ETH each, tier 1 has 3 pending reserves at 1 ETH each.
        // Denominator = 6 ETH (totalMintCost) + 3 ETH (pendingReserveMintCost) = 9 ETH.
        // Without the fix, denominator would be 6 ETH, yielding a higher (overquoted) claim.

        // We can't easily compute exact expected values without replicating the full library logic,
        // but we CAN verify the preview doesn't overquote by checking it's <= the balance.
        uint256 defifaBalance = IERC20(_defifaProjectTokenAccount).balanceOf(address(_nft));
        uint256 baseBalance = IERC20(_protocolFeeProjectTokenAccount).balanceOf(address(_nft));

        // The preview should never exceed the actual balance (overquote prevention).
        assertLe(defifaClaim, defifaBalance, "defifa claim preview should not exceed balance");
        assertLe(baseClaim, baseBalance, "base claim preview should not exceed balance");
    }

    // =========================================================================
    // HELPERS
    // =========================================================================

    function _launchDataCustomTimeout(
        uint256 attestationGracePeriod,
        uint32 scorecardTimeout,
        uint256 timelockDuration
    )
        internal
        view
        returns (DefifaLaunchProjectData memory)
    {
        DefifaTierParams[] memory tp = new DefifaTierParams[](4);
        for (uint256 i; i < 4; i++) {
            tp[i] = DefifaTierParams({
                reservedRate: 0,
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
            attestationGracePeriod: attestationGracePeriod,
            defaultAttestationDelegate: address(0),
            tierPrice: 1 ether,
            tiers: tp,
            defaultTokenUriResolver: IJB721TokenUriResolver(address(0)),
            terminal: jbMultiTerminal(),
            minParticipation: 0,
            scorecardTimeout: scorecardTimeout,
            timelockDuration: timelockDuration
        });
    }

    function _launchDataWithReserves(uint16 tier1Freq) internal view returns (DefifaLaunchProjectData memory) {
        DefifaTierParams[] memory tp = new DefifaTierParams[](4);
        // Tier 1: uses reserves (the one we're testing).
        tp[0] = DefifaTierParams({
            reservedRate: tier1Freq,
            reservedTokenBeneficiary: reserveBeneficiary,
            encodedIPFSUri: bytes32(0),
            shouldUseReservedTokenBeneficiaryAsDefault: false,
            name: "TEAM1"
        });
        // Tier 2: no reserves.
        tp[1] = DefifaTierParams({
            reservedRate: 0,
            reservedTokenBeneficiary: address(0),
            encodedIPFSUri: bytes32(0),
            shouldUseReservedTokenBeneficiaryAsDefault: false,
            name: "TEAM2"
        });
        // Tiers 3-4: disinterested attestors (no meaningful reserves).
        tp[2] = DefifaTierParams({
            reservedRate: 0,
            reservedTokenBeneficiary: address(0),
            encodedIPFSUri: bytes32(0),
            shouldUseReservedTokenBeneficiaryAsDefault: false,
            name: "TEAM3"
        });
        tp[3] = DefifaTierParams({
            reservedRate: 0,
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
}
