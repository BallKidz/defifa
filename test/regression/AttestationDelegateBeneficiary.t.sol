// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

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

/// @title AttestationDelegateBeneficiary
/// @notice Regression test for H-6: when payer != beneficiary and no explicit delegate is set,
///         attestation delegation should default to the beneficiary (NFT recipient), not the payer.
contract AttestationDelegateBeneficiary is JBTest, TestBaseWorkflow {
    using JBRulesetMetadataResolver for JBRuleset;

    uint256 _protocolFeeProjectId;
    uint256 _defifaProjectId;
    address projectOwner = address(bytes20(keccak256("projectOwner")));

    DefifaDeployer deployer;
    DefifaHook hook;
    DefifaGovernor governor;

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
            _protocolFeeProjectId,
            new JB721TiersHookStore()
        );

        hook.transferOwnership(address(deployer));
        governor.transferOwnership(address(deployer));
    }

    /// @notice H-6: Default attestation delegate should be the beneficiary, not the payer.
    function test_defaultDelegateIsBeneficiaryNotPayer() public {
        address payer = address(bytes20(keccak256("payer")));
        address beneficiary = address(bytes20(keccak256("beneficiary")));

        // Launch game with no default attestation delegate.
        (uint256 _projectId, DefifaHook _nft) = _launchGame();

        // Warp to MINT phase.
        vm.warp(_mintPhaseStart);

        // Payer pays on behalf of beneficiary, no explicit delegate (address(0)).
        vm.deal(payer, 1 ether);
        uint16[] memory tierIds = new uint16[](1);
        tierIds[0] = 1;
        bytes memory payMetadata = abi.encode(address(0), tierIds); // attestationDelegate = address(0)
        bytes memory metadata = _buildPayMetadata(payMetadata);

        vm.prank(payer);
        jbMultiTerminal().pay{value: 1 ether}({
            projectId: _projectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: 1 ether,
            beneficiary: beneficiary, // NFT goes to beneficiary, NOT payer
            minReturnedTokens: 0,
            memo: "",
            metadata: metadata
        });

        // H-6 fix: delegation should be on the beneficiary's account, not the payer's.
        // The beneficiary's delegate is themselves (default when no explicit delegate is set).
        address beneficiaryDelegate = _nft.getTierDelegateOf(beneficiary, 1);
        assertEq(beneficiaryDelegate, beneficiary, "H-6: default delegate should be beneficiary, not payer");
        // The payer should have no delegation since they didn't receive attestation units.
        address payerDelegate = _nft.getTierDelegateOf(payer, 1);
        assertEq(payerDelegate, address(0), "H-6: payer should have no delegation when payer != beneficiary");
    }

    /// @notice When payer == beneficiary, the default delegate should be that same address.
    function test_defaultDelegateIsSelfWhenPayerEqualsBeneficiary() public {
        address user = address(bytes20(keccak256("user")));

        (uint256 _projectId, DefifaHook _nft) = _launchGame();
        vm.warp(_mintPhaseStart);

        vm.deal(user, 1 ether);
        uint16[] memory tierIds = new uint16[](1);
        tierIds[0] = 1;
        bytes memory payMetadata = abi.encode(address(0), tierIds);
        bytes memory metadata = _buildPayMetadata(payMetadata);

        vm.prank(user);
        jbMultiTerminal().pay{value: 1 ether}({
            projectId: _projectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: 1 ether,
            beneficiary: user, // payer == beneficiary
            minReturnedTokens: 0,
            memo: "",
            metadata: metadata
        });

        address delegate = _nft.getTierDelegateOf(user, 1);
        assertEq(delegate, user, "Default delegate should be self when payer == beneficiary");
    }

    /// @notice A third-party payer cannot override the beneficiary's delegate.
    function test_explicitDelegateFromThirdPartyDoesNotOverrideBeneficiaryDefault() public {
        address payer = address(bytes20(keccak256("payer2")));
        address beneficiary = address(bytes20(keccak256("beneficiary2")));
        address explicitDelegate = address(bytes20(keccak256("explicitDelegate")));

        (uint256 _projectId, DefifaHook _nft) = _launchGame();
        vm.warp(_mintPhaseStart);

        vm.deal(payer, 1 ether);
        uint16[] memory tierIds = new uint16[](1);
        tierIds[0] = 1;
        bytes memory payMetadata = abi.encode(explicitDelegate, tierIds);
        bytes memory metadata = _buildPayMetadata(payMetadata);

        vm.prank(payer);
        jbMultiTerminal().pay{value: 1 ether}({
            projectId: _projectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: 1 ether,
            beneficiary: beneficiary,
            minReturnedTokens: 0,
            memo: "",
            metadata: metadata
        });

        address beneficiaryDelegate = _nft.getTierDelegateOf(beneficiary, 1);
        assertEq(beneficiaryDelegate, beneficiary, "third-party payer cannot overwrite beneficiary delegation");
        address payerDelegate = _nft.getTierDelegateOf(payer, 1);
        assertEq(payerDelegate, address(0), "Payer should have no delegation when payer != beneficiary");
    }

    // ----- Internal helpers ------

    /// @dev MINT phase starts at `start - mintPeriodDuration - refundPeriodDuration`.
    uint256 internal _mintPhaseStart;

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
            splits: new JBSplit[](0),
            attestationStartTime: 0,
            attestationGracePeriod: 100_381,
            defaultAttestationDelegate: address(0), // No default delegate -- should fall back to beneficiary
            tiers: tierParams,
            defaultTokenUriResolver: IJB721TokenUriResolver(address(0)),
            terminal: jbMultiTerminal(),
            minParticipation: 0,
            scorecardTimeout: 0,
            timelockDuration: 0
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
