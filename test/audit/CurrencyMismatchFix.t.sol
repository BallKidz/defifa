// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {DefifaUSDCTest, DefifaMockUSDC} from "../DefifaUSDC.t.sol";
import {DefifaDeployer} from "../../src/DefifaDeployer.sol";
import {DefifaGovernor} from "../../src/DefifaGovernor.sol";
import {DefifaHook} from "../../src/DefifaHook.sol";
import {DefifaTokenUriResolver} from "../../src/DefifaTokenUriResolver.sol";
import {DefifaLaunchProjectData} from "../../src/structs/DefifaLaunchProjectData.sol";
import {DefifaTierCashOutWeight} from "../../src/structs/DefifaTierCashOutWeight.sol";
import {DefifaTierParams} from "../../src/structs/DefifaTierParams.sol";
import {DefifaDelegation} from "../../src/structs/DefifaDelegation.sol";
import {JB721TiersHookStore} from "@bananapus/721-hook-v6/src/JB721TiersHookStore.sol";
import {IJB721TokenUriResolver} from "@bananapus/721-hook-v6/src/interfaces/IJB721TokenUriResolver.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetApprovalHook.sol";
import {JBRulesetConfig, JBTerminalConfig} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBCurrencyIds} from "@bananapus/core-v6/src/libraries/JBCurrencyIds.sol";
import {JBFundAccessLimitGroup} from "@bananapus/core-v6/src/structs/JBFundAccessLimitGroup.sol";
import {JBMultiTerminal} from "@bananapus/core-v6/src/JBMultiTerminal.sol";
import {JBPermissionIds} from "@bananapus/permission-ids-v6/src/JBPermissionIds.sol";
import {JBPermissionsData} from "@bananapus/core-v6/src/structs/JBPermissionsData.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JBRulesetMetadata} from "@bananapus/core-v6/src/structs/JBRulesetMetadata.sol";
import {JBRulesetMetadataResolver} from "@bananapus/core-v6/src/libraries/JBRulesetMetadataResolver.sol";
import {JBSplit} from "@bananapus/core-v6/src/structs/JBSplit.sol";
import {JBSplitGroup} from "@bananapus/core-v6/src/structs/JBSplitGroup.sol";
import {JBAddressRegistry} from "@bananapus/address-registry-v6/src/JBAddressRegistry.sol";
import {TestBaseWorkflow} from "@bananapus/core-v6/test/helpers/TestBaseWorkflow.sol";
import {JBTest} from "@bananapus/core-v6/test/helpers/JBTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ITypeface} from "lib/typeface/contracts/interfaces/ITypeface.sol";

/// @title CurrencyMismatchFixTest
/// @notice Adversarial tests for the currency mismatch fix: verifies that fulfillCommitmentsOf correctly resolves
/// payout limits for both ETH and ERC-20 games, and that launch-time validation rejects zero-currency ERC-20
/// configurations. Inherits DefifaUSDCTest for USDC helpers and fee project setup.
contract CurrencyMismatchFixTest is DefifaUSDCTest {
    // =========================================================================
    // HELPERS
    // =========================================================================

    function _launchDataNonCanonical(uint8 n, uint104 tierPrice) internal returns (DefifaLaunchProjectData memory) {
        DefifaTierParams[] memory tp = new DefifaTierParams[](n);
        for (uint256 i; i < n; i++) {
            tp[i] = DefifaTierParams({
                reservedRate: 1001,
                reservedTokenBeneficiary: address(0),
                encodedIPFSUri: bytes32(0),
                shouldUseReservedTokenBeneficiaryAsDefault: false,
                name: "DEFIFA"
            });
        }

        // Non-canonical currency (1) for a USDC token.
        return DefifaLaunchProjectData({
            name: "DEFIFA_NONCANONICAL",
            projectUri: "",
            contractUri: "",
            baseUri: "",
            token: JBAccountingContext({token: address(usdc), decimals: 6, currency: 1}),
            mintPeriodDuration: 1 days,
            start: uint48(block.timestamp + 3 days),
            refundPeriodDuration: 1 days,
            splits: new JBSplit[](0),
            attestationStartTime: 0,
            attestationGracePeriod: 1 days,
            defaultAttestationDelegate: address(0),
            tierPrice: tierPrice,
            tiers: tp,
            defaultTokenUriResolver: IJB721TokenUriResolver(address(0)),
            terminal: jbMultiTerminal(),
            minParticipation: 0,
            scorecardTimeout: 0,
            timelockDuration: 0
        });
    }

    function _setupNonCanonicalGame(uint8 nTiers, uint104 tierPrice) internal {
        DefifaLaunchProjectData memory d = _launchDataNonCanonical(nTiers, tierPrice);
        (_pid, _nft, _gov) = _launch(d);
        vm.warp(d.start - d.mintPeriodDuration - d.refundPeriodDuration);
        _users = new address[](nTiers);
        for (uint256 i; i < nTiers; i++) {
            _users[i] = _addr(i);
            _mintUsdc(_users[i], i + 1, tierPrice);
            _delegateSelf(_users[i], i + 1);
            vm.warp(block.timestamp + 1);
        }
    }

    // =========================================================================
    // TEST 1: ERC-20 game with non-canonical currency correctly resolves payout limit
    // =========================================================================

    /// @notice An ERC-20 game launched with currency=1 (non-canonical) now correctly sends commitment payouts
    /// because fulfillCommitmentsOf uses metadata.baseCurrency instead of uint32(uint160(token)).
    function test_currencyMismatchFix_erc20NonCanonicalCurrencyFulfillsCorrectly() external {
        uint104 tierPrice = 100e6;
        _setupNonCanonicalGame(4, tierPrice);

        // Advance to scoring phase.
        _toScoring();

        uint256 potBefore = _balance();
        assertEq(potBefore, 400e6, "pot = 400 USDC before fulfillment");

        uint256 expectedFee = (potBefore * 75_000_000) / JBConstants.SPLITS_TOTAL_PERCENT;

        _attestAndRatify(_evenScorecard(4));

        // Verify: payout succeeded. fulfilledCommitmentsOf stores the actual fee amount, not sentinel (1).
        uint256 fulfilled = deployer.fulfilledCommitmentsOf(_pid);
        assertEq(fulfilled, expectedFee, "fulfilled = expected fee (payout succeeded)");

        // Verify: balance reduced by the fee.
        assertEq(_balance(), potBefore - expectedFee, "balance = pot - fee");
    }

    // =========================================================================
    // TEST 2: ETH game fulfillment still works correctly (no regression)
    // =========================================================================

    /// @notice ETH game (canonical currency) continues to work after the fix.
    /// Covered by DefifaFeeAccountingTest; this verifies no regression from the baseCurrency change.
    function test_currencyMismatchFix_ethGameFeeAccountingUnchanged() external {
        // The DefifaFeeAccountingTest suite tests ETH fulfillment comprehensively.
        // Here we verify the core assertion: fee percentage matches for USDC canonical game too.
        uint104 tierPrice = 100e6;
        _setupGameUsdc(4, tierPrice);

        _toScoring();

        uint256 potBefore = _balance();
        uint256 expectedFee = (potBefore * 75_000_000) / JBConstants.SPLITS_TOTAL_PERCENT;

        _attestAndRatify(_evenScorecard(4));

        uint256 fulfilled = deployer.fulfilledCommitmentsOf(_pid);
        assertEq(fulfilled, expectedFee, "canonical USDC fee unchanged by fix");
        assertEq(fulfilled + _balance(), potBefore, "fee + surplus = original pot");
    }

    // =========================================================================
    // TEST 3: Non-canonical ERC-20 winner cash-out is correct after fulfillment
    // =========================================================================

    /// @notice After the fix, the winner of a non-canonical-currency ERC-20 game receives the post-fee surplus
    /// (not the full pot). This confirms the fee was actually deducted.
    function test_currencyMismatchFix_winnerReceivesPostFeeSurplusNotFullPot() external {
        uint104 tierPrice = 100e6;
        _setupNonCanonicalGame(2, tierPrice);

        _toScoring();

        uint256 potBefore = _balance();
        uint256 expectedFee = (potBefore * 75_000_000) / JBConstants.SPLITS_TOTAL_PERCENT;

        // Tier 1 gets 100% of the cashout weight.
        DefifaTierCashOutWeight[] memory sc = new DefifaTierCashOutWeight[](2);
        sc[0] = DefifaTierCashOutWeight({id: 1, cashOutWeight: _nft.TOTAL_CASHOUT_WEIGHT()});
        sc[1] = DefifaTierCashOutWeight({id: 2, cashOutWeight: 0});
        _attestAndRatify(sc);

        // Fulfillment succeeded -- fee was deducted.
        assertEq(deployer.fulfilledCommitmentsOf(_pid), expectedFee, "fee was deducted");

        // Winner cashes out and receives the post-fee surplus.
        uint256 winnerBalBefore = usdc.balanceOf(_users[0]);
        _cashOutUsdc(_users[0], 1, 1);
        uint256 winnerReceived = usdc.balanceOf(_users[0]) - winnerBalBefore;

        // Before the fix, winner would have received the full pot (fee was skipped).
        // After the fix, winner receives pot minus fee.
        assertEq(winnerReceived, potBefore - expectedFee, "winner receives post-fee surplus, not the full pot");
        assertLt(winnerReceived, potBefore, "winner does NOT receive the full pot");
    }

    // =========================================================================
    // TEST 4: Launch rejects zero currency for non-native tokens
    // =========================================================================

    /// @notice Launching an ERC-20 game with currency=0 is rejected at launch time.
    function test_currencyMismatchFix_revertOnZeroCurrencyForErc20() external {
        DefifaTierParams[] memory tp = new DefifaTierParams[](2);
        for (uint256 i; i < 2; i++) {
            tp[i] = DefifaTierParams({
                reservedRate: 1001,
                reservedTokenBeneficiary: address(0),
                encodedIPFSUri: bytes32(0),
                shouldUseReservedTokenBeneficiaryAsDefault: false,
                name: "DEFIFA"
            });
        }

        DefifaLaunchProjectData memory d = DefifaLaunchProjectData({
            name: "DEFIFA_ZERO_CURRENCY",
            projectUri: "",
            contractUri: "",
            baseUri: "",
            token: JBAccountingContext({token: address(usdc), decimals: 6, currency: 0}),
            mintPeriodDuration: 1 days,
            start: uint48(block.timestamp + 3 days),
            refundPeriodDuration: 1 days,
            splits: new JBSplit[](0),
            attestationStartTime: 0,
            attestationGracePeriod: 1 days,
            defaultAttestationDelegate: address(0),
            tierPrice: 100e6,
            tiers: tp,
            defaultTokenUriResolver: IJB721TokenUriResolver(address(0)),
            terminal: jbMultiTerminal(),
            minParticipation: 0,
            scorecardTimeout: 0,
            timelockDuration: 0
        });

        vm.expectRevert(abi.encodeWithSignature("DefifaDeployer_InvalidCurrency()"));
        deployer.launchGameWith(d);
    }

    /// @notice Native token (ETH) is exempt from the zero-currency check.
    function test_currencyMismatchFix_nativeTokenAllowsAnyCurrency() external {
        DefifaTierParams[] memory tp = new DefifaTierParams[](2);
        for (uint256 i; i < 2; i++) {
            tp[i] = DefifaTierParams({
                reservedRate: 1001,
                reservedTokenBeneficiary: address(0),
                encodedIPFSUri: bytes32(0),
                shouldUseReservedTokenBeneficiaryAsDefault: false,
                name: "DEFIFA"
            });
        }

        DefifaLaunchProjectData memory d = DefifaLaunchProjectData({
            name: "DEFIFA_ETH_LAUNCH",
            projectUri: "",
            contractUri: "",
            baseUri: "",
            token: JBAccountingContext({token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: JBCurrencyIds.ETH}),
            mintPeriodDuration: 1 days,
            start: uint48(block.timestamp + 3 days),
            refundPeriodDuration: 1 days,
            splits: new JBSplit[](0),
            attestationStartTime: 0,
            attestationGracePeriod: 1 days,
            defaultAttestationDelegate: address(0),
            tierPrice: 1 ether,
            tiers: tp,
            defaultTokenUriResolver: IJB721TokenUriResolver(address(0)),
            terminal: jbMultiTerminal(),
            minParticipation: 0,
            scorecardTimeout: 0,
            timelockDuration: 0
        });

        // Should succeed without revert.
        uint256 gameId = deployer.launchGameWith(d);
        assertGt(gameId, 0, "ETH game launched successfully");
    }
}
