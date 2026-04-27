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
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JBRulesetConfig} from "@bananapus/core-v6/src/structs/JBRulesetConfig.sol";
import {JBRulesetMetadataResolver} from "@bananapus/core-v6/src/libraries/JBRulesetMetadataResolver.sol";
import {JBRulesetMetadata} from "@bananapus/core-v6/src/structs/JBRulesetMetadata.sol";
import {JBSplit} from "@bananapus/core-v6/src/structs/JBSplit.sol";
import {JBSplitGroup} from "@bananapus/core-v6/src/structs/JBSplitGroup.sol";
import {JBTerminalConfig} from "@bananapus/core-v6/src/structs/JBTerminalConfig.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesets.sol";
import {JBTest} from "@bananapus/core-v6/test/helpers/JBTest.sol";
import {TestBaseWorkflow} from "@bananapus/core-v6/test/helpers/TestBaseWorkflow.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ITypeface} from "lib/typeface/contracts/interfaces/ITypeface.sol";

contract TierCapMismatchTest is JBTest, TestBaseWorkflow {
    using JBRulesetMetadataResolver for JBRuleset;

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
            protocolFeeProjectId,
            new JB721TiersHookStore()
        );

        hookCodeOrigin.transferOwnership(address(deployer));
        governor.transferOwnership(address(deployer));
    }

    function test_launchRevertsFor129Tiers() external {
        DefifaLaunchProjectData memory data = _launchData(129);

        // H-5 fix: the deployer now caps tiers at 128, so launching with 129 reverts.
        vm.expectRevert(DefifaDeployer.DefifaDeployer_InvalidGameConfiguration.selector);
        deployer.launchGameWith(data);
    }

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
            minParticipation: 0,
            scorecardTimeout: 7 days,
            timelockDuration: 0
        });
    }

    function _mintTier(uint256 gameId, uint16 tierId, uint256 amount) internal {
        address buyer = address(bytes20(keccak256(abi.encodePacked("buyer", tierId))));
        vm.deal(buyer, amount);

        uint16[] memory tierIds = new uint16[](1);
        tierIds[0] = tierId;

        bytes[] memory payloads = new bytes[](1);
        payloads[0] = abi.encode(address(0), tierIds);

        bytes4[] memory ids = new bytes4[](1);
        ids[0] = metadataHelper().getId("pay", address(hookCodeOrigin));

        bytes memory metadata = metadataHelper().createMetadata(ids, payloads);

        vm.prank(buyer);
        jbMultiTerminal().pay{value: amount}(gameId, JBConstants.NATIVE_TOKEN, amount, buyer, 0, "", metadata);
    }
}
