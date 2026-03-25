// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {TestBaseWorkflow} from "@bananapus/core-v6/test/helpers/TestBaseWorkflow.sol";

import {DefifaGovernor} from "../../src/DefifaGovernor.sol";
import {DefifaDeployer} from "../../src/DefifaDeployer.sol";
import {DefifaHook} from "../../src/DefifaHook.sol";
import {DefifaTokenUriResolver} from "../../src/DefifaTokenUriResolver.sol";
import {JB721TiersHookStore} from "@bananapus/721-hook-v6/src/JB721TiersHookStore.sol";

import {JBTest} from "@bananapus/core-v6/test/helpers/JBTest.sol";
import {JBRulesetMetadataResolver} from "@bananapus/core-v6/src/libraries/JBRulesetMetadataResolver.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JBAddressRegistry} from "@bananapus/address-registry-v6/src/JBAddressRegistry.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ITypeface} from "lib/typeface/contracts/interfaces/ITypeface.sol";
import {IJB721TokenUriResolver} from "@bananapus/721-hook-v6/src/interfaces/IJB721TokenUriResolver.sol";
import {DefifaLaunchProjectData} from "../../src/structs/DefifaLaunchProjectData.sol";
import {DefifaTierParams} from "../../src/structs/DefifaTierParams.sol";
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

contract CodexAttestationDoubleCount is JBTest, TestBaseWorkflow {
    using JBRulesetMetadataResolver for JBRuleset;

    uint256 internal _protocolFeeProjectId;
    uint256 internal _defifaProjectId;

    DefifaDeployer internal deployer;
    DefifaHook internal hook;
    DefifaGovernor internal governor;

    uint256 internal _mintPhaseStart;

    function setUp() public virtual override {
        super.setUp();

        JBAccountingContext[] memory _tokens = new JBAccountingContext[](1);
        _tokens[0] = JBAccountingContext({token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: JBCurrencyIds.ETH});

        JBTerminalConfig[] memory terminalConfigs = new JBTerminalConfig[](1);
        terminalConfigs[0] = JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: _tokens});

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

        _protocolFeeProjectId =
            jbController().launchProjectFor(address(projectOwner), "", rulesetConfigs, terminalConfigs, "");
        vm.prank(projectOwner);
        address _nanaToken =
            address(jbController().deployERC20For(_protocolFeeProjectId, "Bananapus", "NANA", bytes32(0)));

        _defifaProjectId =
            jbController().launchProjectFor(address(projectOwner), "", rulesetConfigs, terminalConfigs, "");
        vm.prank(projectOwner);
        address _defifaToken = address(jbController().deployERC20For(_defifaProjectId, "Defifa", "DEFIFA", bytes32(0)));

        hook = new DefifaHook(jbDirectory(), IERC20(_defifaToken), IERC20(_nanaToken));
        governor = new DefifaGovernor(jbController(), address(this));
        deployer = new DefifaDeployer(
            address(hook),
            new DefifaTokenUriResolver(ITypeface(address(0))),
            governor,
            jbController(),
            new JBAddressRegistry(),
            _defifaProjectId,
            _protocolFeeProjectId
        );

        hook.transferOwnership(address(deployer));
        governor.transferOwnership(address(deployer));
    }

    function test_attestationUnitsDuplicateAfterBeneficiaryTransfer() external {
        address payer = address(bytes20(keccak256("payer")));
        address beneficiary = address(bytes20(keccak256("beneficiary")));
        address recipient = address(bytes20(keccak256("recipient")));

        (uint256 projectId, DefifaHook nft) = _launchGame();
        vm.warp(_mintPhaseStart);

        vm.deal(payer, 1 ether);
        uint16[] memory tierIds = new uint16[](1);
        tierIds[0] = 1;
        bytes memory metadata = _buildPayMetadata(abi.encode(address(0), tierIds));

        vm.prank(payer);
        jbMultiTerminal().pay{value: 1 ether}({
            projectId: projectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: 1 ether,
            beneficiary: beneficiary,
            minReturnedTokens: 0,
            memo: "",
            metadata: metadata
        });

        uint256 totalUnitsBefore = nft.getTierTotalAttestationUnitsOf(1);
        uint256 beneficiaryUnitsBefore = nft.getTierAttestationUnitsOf(beneficiary, 1);
        assertGt(totalUnitsBefore, 0, "tier should have nonzero attestation units");
        assertEq(beneficiaryUnitsBefore, totalUnitsBefore, "beneficiary receives delegated units after mint");

        uint256 tokenId = 1_000_000_001;
        vm.prank(beneficiary);
        nft.transferFrom(beneficiary, recipient, tokenId);

        uint256 beneficiaryUnitsAfter = nft.getTierAttestationUnitsOf(beneficiary, 1);
        uint256 recipientUnitsAfter = nft.getTierAttestationUnitsOf(recipient, 1);
        uint256 totalUnitsAfter = nft.getTierTotalAttestationUnitsOf(1);

        // After the fix: attestation units go to beneficiary on mint, then move to recipient on transfer.
        // Total units stay constant, beneficiary loses units, recipient gains them.
        assertEq(totalUnitsAfter, totalUnitsBefore, "total tier units stay constant");
        assertEq(beneficiaryUnitsAfter, 0, "beneficiary loses attestation units after transferring NFT");
        assertEq(recipientUnitsAfter, totalUnitsAfter, "recipient receives full attestation units from transfer");
        // No double-counting: sum of individual units equals total.
        assertEq(
            beneficiaryUnitsAfter + recipientUnitsAfter,
            totalUnitsAfter,
            "no double-counting: sum of individual units equals total"
        );
    }

    function _launchGame() internal returns (uint256 projectId, DefifaHook nft) {
        DefifaTierParams[] memory tierParams = new DefifaTierParams[](2);
        for (uint256 i = 0; i < 2; i++) {
            tierParams[i] = DefifaTierParams({
                reservedRate: 1001,
                reservedTokenBeneficiary: address(0),
                encodedIPFSUri: bytes32(0),
                shouldUseReservedTokenBeneficiaryAsDefault: false,
                name: "DEFIFA"
            });
        }

        DefifaLaunchProjectData memory d = DefifaLaunchProjectData({
            name: "DEFIFA",
            projectUri: "",
            contractUri: "",
            baseUri: "",
            tierPrice: 1 ether,
            token: JBAccountingContext({token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: JBCurrencyIds.ETH}),
            mintPeriodDuration: 1 days,
            start: uint48(block.timestamp + 3 days),
            refundPeriodDuration: 1 days,
            store: new JB721TiersHookStore(),
            splits: new JBSplit[](0),
            attestationStartTime: 0,
            attestationGracePeriod: 100_381,
            defaultAttestationDelegate: address(0),
            tiers: tierParams,
            defaultTokenUriResolver: IJB721TokenUriResolver(address(0)),
            terminal: jbMultiTerminal(),
            minParticipation: 0,
            scorecardTimeout: 0
        });

        _mintPhaseStart = d.start - d.mintPeriodDuration - d.refundPeriodDuration;

        projectId = deployer.launchGameWith(d);

        JBRuleset memory fc = jbRulesets().currentOf(projectId);
        if (fc.dataHook() == address(0)) {
            (fc,) = jbRulesets().latestQueuedOf(projectId);
        }
        nft = DefifaHook(fc.dataHook());
    }

    function _buildPayMetadata(bytes memory metadata) internal view returns (bytes memory) {
        bytes[] memory data = new bytes[](1);
        data[0] = metadata;
        bytes4[] memory ids = new bytes4[](1);
        ids[0] = metadataHelper().getId("pay", address(hook));
        return metadataHelper().createMetadata(ids, data);
    }
}
