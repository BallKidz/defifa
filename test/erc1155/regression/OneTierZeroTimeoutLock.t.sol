// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {DefifaDeployer} from "../../../src/DefifaDeployer.sol";
import {DefifaGamePhase} from "../../../src/enums/DefifaGamePhase.sol";
import {DefifaGovernor} from "../../../src/DefifaGovernor.sol";
import {DefifaVotingReferee} from "../../../src/referees/DefifaVotingReferee.sol";
import {Defifa1155Hook} from "../../../src/Defifa1155Hook.sol";
import {DefifaTokenUriResolver} from "../../../src/DefifaTokenUriResolver.sol";
import {DefifaLaunchProjectData} from "../../../src/structs/DefifaLaunchProjectData.sol";
import {DefifaTierCashOutWeight} from "../../../src/structs/DefifaTierCashOutWeight.sol";
import {DefifaTierParams} from "../../../src/structs/DefifaTierParams.sol";
import {DefifaTiersHookStore} from "../../../src/DefifaTiersHookStore.sol";
import {JBAddressRegistry} from "@bananapus/address-registry-v6/src/JBAddressRegistry.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBCurrencyIds} from "@bananapus/core-v6/src/libraries/JBCurrencyIds.sol";
import {JBFundAccessLimitGroup} from "@bananapus/core-v6/src/structs/JBFundAccessLimitGroup.sol";
import {JBMultiTerminal} from "@bananapus/core-v6/src/JBMultiTerminal.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JBRulesetConfig} from "@bananapus/core-v6/src/structs/JBRulesetConfig.sol";
import {JBRulesetMetadata} from "@bananapus/core-v6/src/structs/JBRulesetMetadata.sol";
import {JBRulesetMetadataResolver} from "@bananapus/core-v6/src/libraries/JBRulesetMetadataResolver.sol";
import {JBSplit} from "@bananapus/core-v6/src/structs/JBSplit.sol";
import {JBSplitGroup} from "@bananapus/core-v6/src/structs/JBSplitGroup.sol";
import {JBTerminalConfig} from "@bananapus/core-v6/src/structs/JBTerminalConfig.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetApprovalHook.sol";
import {JBTest} from "@bananapus/core-v6/test/helpers/JBTest.sol";
import {TestBaseWorkflow} from "@bananapus/core-v6/test/helpers/TestBaseWorkflow.sol";
import {IJB721TokenUriResolver} from "@bananapus/721-hook-v6/src/interfaces/IJB721TokenUriResolver.sol";
import {ITypeface} from "lib/typeface/contracts/interfaces/ITypeface.sol";

contract OneTierZeroTimeoutLockTest is JBTest, TestBaseWorkflow {
    using JBRulesetMetadataResolver for JBRuleset;

    uint256 internal constant GAME_ID = 3;

    DefifaDeployer internal deployer;
    DefifaGovernor internal governor;
    DefifaVotingReferee votingReferee;
    Defifa1155Hook internal hook;

    uint256 internal projectId;
    Defifa1155Hook internal gameHook;

    address internal projectOwner = address(bytes20(keccak256("projectOwner")));
    address internal player = address(bytes20(keccak256("player")));

    function setUp() public override {
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
                scopeCashOutsToLocalBalances: true,
                useDataHookForPay: true,
                useDataHookForCashOut: true,
                dataHook: address(0),
                metadata: 0
            }),
            splitGroups: new JBSplitGroup[](0),
            fundAccessLimitGroups: new JBFundAccessLimitGroup[](0)
        });

        uint256 protocolFeeProjectId =
            jbController().launchProjectFor(projectOwner, "", rulesetConfigs, terminalConfigs, "");
        vm.prank(projectOwner);
        jbController().deployERC20For(protocolFeeProjectId, "Bananapus", "NANA", bytes32(0));

        uint256 defifaProjectId = jbController().launchProjectFor(projectOwner, "", rulesetConfigs, terminalConfigs, "");
        vm.prank(projectOwner);
        jbController().deployERC20For(defifaProjectId, "Defifa", "DEFIFA", bytes32(0));

        hook = new Defifa1155Hook(jbDirectory(), jbTokens(), defifaProjectId, protocolFeeProjectId);
        governor = new DefifaGovernor(jbController(), address(this));
        votingReferee = new DefifaVotingReferee(jbController());
        deployer = new DefifaDeployer({
            hookCodeOrigin: address(hook),
            tokenUriResolver: new DefifaTokenUriResolver(address(this)),
            governor: governor,
            controller: jbController(),
            registry: new JBAddressRegistry(),
            defifaProjectId: defifaProjectId,
            baseProtocolProjectId: protocolFeeProjectId,
            hookStore: new DefifaTiersHookStore(),
            trustedForwarder: address(0)
        });

        hook.transferOwnership(address(deployer));
        governor.transferOwnership(address(deployer));
    }

    /// @notice One-tier games with `scorecardTimeout == 0` are rejected at launch. Quorum is unreachable for
    /// one- and two-tier games (BWA reduces beneficiary tier weight to zero, and two-tier games have zero
    /// rounding headroom), so without a timeout the game would be permanently locked.
    function test_oneTier_zeroTimeout_isRejectedAtLaunch() external {
        DefifaLaunchProjectData memory data = _launchData();
        vm.expectRevert(
            abi.encodeWithSelector(
                DefifaDeployer.DefifaDeployer_InvalidGameConfiguration.selector,
                data.start,
                data.mintPeriodDuration,
                data.refundPeriodDuration,
                data.tiers.length
            )
        );
        deployer.launchGameWith(data);
    }

    function _launchData() internal view returns (DefifaLaunchProjectData memory) {
        DefifaTierParams[] memory tiers = new DefifaTierParams[](1);
        tiers[0] = DefifaTierParams({
            reservedRate: 0,
            reservedTokenBeneficiary: address(0),
            encodedIpfsUri: bytes32(0),
            shouldUseReservedTokenBeneficiaryAsDefault: false,
            name: "ONLY_TEAM"
        });

        return DefifaLaunchProjectData({
            name: "ONE_TIER_LOCK",
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
            defaultAttestationDelegate: address(0),
            defaultTokenUriResolver: IJB721TokenUriResolver(address(0)),
            terminal: jbMultiTerminal(),
            minParticipation: 0,
            scorecardTimeout: 0,
            timelockDuration: 0,
            referee: address(votingReferee),
            refereeData: abi.encode(0, 100_381)
        });
    }
}
