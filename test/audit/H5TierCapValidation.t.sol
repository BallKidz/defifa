// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {DefifaDeployer} from "../../src/DefifaDeployer.sol";
import {DefifaGovernor} from "../../src/DefifaGovernor.sol";
import {DefifaHook} from "../../src/DefifaHook.sol";
import {DefifaTokenUriResolver} from "../../src/DefifaTokenUriResolver.sol";
import {DefifaLaunchProjectData} from "../../src/structs/DefifaLaunchProjectData.sol";
import {DefifaTierParams} from "../../src/structs/DefifaTierParams.sol";

import {JB721TiersHookStore} from "@bananapus/721-hook-v6/src/JB721TiersHookStore.sol";
import {IJB721TokenUriResolver} from "@bananapus/721-hook-v6/src/interfaces/IJB721TokenUriResolver.sol";
import {JBAddressRegistry} from "@bananapus/address-registry-v6/src/JBAddressRegistry.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBCurrencyIds} from "@bananapus/core-v6/src/libraries/JBCurrencyIds.sol";
import {JBFundAccessLimitGroup} from "@bananapus/core-v6/src/structs/JBFundAccessLimitGroup.sol";
import {JBRulesetConfig, JBTerminalConfig} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {JBRulesetMetadata} from "@bananapus/core-v6/src/structs/JBRulesetMetadata.sol";
import {JBSplit} from "@bananapus/core-v6/src/structs/JBSplit.sol";
import {JBSplitGroup} from "@bananapus/core-v6/src/structs/JBSplitGroup.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesets.sol";
import {JBTest} from "@bananapus/core-v6/test/helpers/JBTest.sol";
import {TestBaseWorkflow} from "@bananapus/core-v6/test/helpers/TestBaseWorkflow.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ITypeface} from "lib/typeface/contracts/interfaces/ITypeface.sol";

/// @notice Tests for H-5 audit fix: tier cap of 128 enforced in launchGameWith().
contract H5TierCapValidationTest is JBTest, TestBaseWorkflow {
    DefifaDeployer internal deployer;
    DefifaGovernor internal governor;
    DefifaHook internal hookCodeOrigin;

    function setUp() public virtual override {
        super.setUp();

        JBAccountingContext[] memory tokens = new JBAccountingContext[](1);
        tokens[0] = JBAccountingContext({token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: JBCurrencyIds.ETH});

        JBTerminalConfig[] memory terminalConfigs = new JBTerminalConfig[](1);
        terminalConfigs[0] = JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: tokens});

        JBRulesetConfig[] memory rulesetConfigs = new JBRulesetConfig[](1);
        rulesetConfigs[0] = JBRulesetConfig({
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

        address projectOwner = address(bytes20(keccak256("projectOwner")));
        uint256 protocolFeeProjectId =
            jbController().launchProjectFor(projectOwner, "", rulesetConfigs, terminalConfigs, "");
        vm.prank(projectOwner);
        address nanaToken =
            address(jbController().deployERC20For(protocolFeeProjectId, "Bananapus", "NANA", bytes32(0)));

        uint256 defifaProjectId = jbController().launchProjectFor(projectOwner, "", rulesetConfigs, terminalConfigs, "");
        vm.prank(projectOwner);
        address defifaToken = address(jbController().deployERC20For(defifaProjectId, "Defifa", "DEFIFA", bytes32(0)));

        hookCodeOrigin = new DefifaHook(jbDirectory(), IERC20(defifaToken), IERC20(nanaToken));
        governor = new DefifaGovernor(jbController(), address(this));
        deployer = new DefifaDeployer(
            address(hookCodeOrigin),
            new DefifaTokenUriResolver(ITypeface(address(0))),
            governor,
            jbController(),
            new JBAddressRegistry(),
            defifaProjectId,
            protocolFeeProjectId
        );

        hookCodeOrigin.transferOwnership(address(deployer));
        governor.transferOwnership(address(deployer));
    }

    /// @notice Launching with exactly 128 tiers should succeed (boundary).
    function test_launch128TiersSucceeds() external {
        DefifaLaunchProjectData memory data = _launchData(128);
        uint256 gameId = deployer.launchGameWith(data);
        assertGt(gameId, 0, "game should be created with 128 tiers");
    }

    /// @notice Launching with 129 tiers must revert with DefifaDeployer_InvalidGameConfiguration.
    function test_launch129TiersReverts() external {
        DefifaLaunchProjectData memory data = _launchData(129);
        vm.expectRevert(DefifaDeployer.DefifaDeployer_InvalidGameConfiguration.selector);
        deployer.launchGameWith(data);
    }

    /// @notice Launching with 1 tier should succeed (minimum valid).
    function test_launch1TierSucceeds() external {
        DefifaLaunchProjectData memory data = _launchData(1);
        uint256 gameId = deployer.launchGameWith(data);
        assertGt(gameId, 0, "game should be created with 1 tier");
    }

    /// @notice Launching with 0 tiers does not revert at the tier cap check (no lower-bound validation exists).
    /// @dev This documents current behavior: the deployer only enforces the upper cap of 128.
    function test_launch0TiersDoesNotRevertAtTierCap() external {
        DefifaLaunchProjectData memory data = _launchData(0);
        uint256 gameId = deployer.launchGameWith(data);
        assertGt(gameId, 0, "0-tier game created (no lower-bound check)");
    }

    /// @notice Fuzz: any tier count above 128 reverts, any from 1-128 succeeds.
    function test_fuzz_tierCapBoundary(uint256 tierCount) external {
        tierCount = bound(tierCount, 1, 256);
        DefifaLaunchProjectData memory data = _launchData(tierCount);

        if (tierCount > 128) {
            vm.expectRevert(DefifaDeployer.DefifaDeployer_InvalidGameConfiguration.selector);
            deployer.launchGameWith(data);
        } else {
            uint256 gameId = deployer.launchGameWith(data);
            assertGt(gameId, 0, "game should be created within tier cap");
        }
    }

    // ─── Helpers ─────────────────────────────────────────────────────────────────

    function _launchData(uint256 tierCount) internal returns (DefifaLaunchProjectData memory) {
        DefifaTierParams[] memory tiers = new DefifaTierParams[](tierCount);
        for (uint256 i; i < tierCount; i++) {
            tiers[i] = DefifaTierParams({
                name: "TEAM",
                reservedRate: 0,
                reservedTokenBeneficiary: address(0),
                encodedIPFSUri: bytes32(0),
                shouldUseReservedTokenBeneficiaryAsDefault: false
            });
        }

        return DefifaLaunchProjectData({
            name: "DEFIFA",
            projectUri: "",
            contractUri: "",
            baseUri: "",
            tiers: tiers,
            tierPrice: 1 ether,
            token: JBAccountingContext({token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: JBCurrencyIds.ETH}),
            mintPeriodDuration: 1 days,
            refundPeriodDuration: 1 days,
            start: uint48(block.timestamp + 3 days),
            splits: new JBSplit[](0),
            attestationStartTime: 0,
            attestationGracePeriod: 100_381,
            defaultAttestationDelegate: address(0),
            defaultTokenUriResolver: IJB721TokenUriResolver(address(0)),
            terminal: jbMultiTerminal(),
            store: new JB721TiersHookStore(),
            minParticipation: 0,
            scorecardTimeout: 7 days,
            timelockDuration: 0
        });
    }
}
