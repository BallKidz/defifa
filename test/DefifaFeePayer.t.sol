// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {DefifaGovernor} from "../src/DefifaGovernor.sol";
import {DefifaDeployer} from "../src/DefifaDeployer.sol";
import {DefifaHook} from "../src/DefifaHook.sol";
import {DefifaTokenUriResolver} from "../src/DefifaTokenUriResolver.sol";
import {JB721TiersHookStore} from "@bananapus/721-hook-v6/src/JB721TiersHookStore.sol";

import {TestBaseWorkflow} from "@bananapus/core-v6/test/helpers/TestBaseWorkflow.sol";
import {JBTest} from "@bananapus/core-v6/test/helpers/JBTest.sol";
import {JBAddressRegistry} from "@bananapus/address-registry-v6/src/JBAddressRegistry.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IJBPayerTracker} from "@bananapus/core-v6/src/interfaces/IJBPayerTracker.sol";
import {IJB721TokenUriResolver} from "@bananapus/721-hook-v6/src/interfaces/IJB721TokenUriResolver.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetApprovalHook.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBCurrencyIds} from "@bananapus/core-v6/src/libraries/JBCurrencyIds.sol";
import {JBFundAccessLimitGroup} from "@bananapus/core-v6/src/structs/JBFundAccessLimitGroup.sol";
import {JBRulesetConfig} from "@bananapus/core-v6/src/structs/JBRulesetConfig.sol";
import {JBRulesetMetadata} from "@bananapus/core-v6/src/structs/JBRulesetMetadata.sol";
import {JBSplit} from "@bananapus/core-v6/src/structs/JBSplit.sol";
import {JBSplitGroup} from "@bananapus/core-v6/src/structs/JBSplitGroup.sol";
import {JBTerminalConfig} from "@bananapus/core-v6/src/structs/JBTerminalConfig.sol";

import {DefifaLaunchProjectData} from "../src/structs/DefifaLaunchProjectData.sol";
import {DefifaTierParams} from "../src/structs/DefifaTierParams.sol";

/// @notice Stands in for a `pay`-routing creation-fee receiver. On receiving the forwarded fee it reads back the fee
/// payer that `JBProjects` advertised, exactly as a real fee terminal would to credit the originator.
contract PayerRecordingFeeReceiver {
    IJBPayerTracker public immutable PROJECTS;
    address public recordedPayer;

    constructor(IJBPayerTracker projects) {
        PROJECTS = projects;
    }

    receive() external payable {
        recordedPayer = PROJECTS.originalPayer();
    }
}

/// @title DefifaFeePayerTest
/// @notice Proves `DefifaDeployer` advertises the resolved creation-fee payer while forwarding a project-creation fee,
/// so a `pay`-routing fee receiver credits the end user instead of the deployer.
contract DefifaFeePayerTest is JBTest, TestBaseWorkflow {
    DefifaDeployer deployer;
    DefifaHook hook;
    DefifaGovernor governor;

    address projectOwner = address(bytes20(keccak256("projectOwner")));

    function setUp() public virtual override {
        super.setUp();

        uint256 protocolFeeProjectId =
            jbController().launchProjectFor(projectOwner, "", _emptyRulesets(), _terminals(), "");
        vm.prank(projectOwner);
        address protocolFeeToken =
            address(jbController().deployERC20For(protocolFeeProjectId, "Bananapus", "NANA", bytes32(0)));

        uint256 defifaProjectId = jbController().launchProjectFor(projectOwner, "", _emptyRulesets(), _terminals(), "");
        vm.prank(projectOwner);
        address defifaToken = address(jbController().deployERC20For(defifaProjectId, "Defifa", "DEFIFA", bytes32(0)));

        hook = new DefifaHook(jbDirectory(), IERC20(defifaToken), IERC20(protocolFeeToken));
        governor = new DefifaGovernor(jbController(), address(this));
        deployer = new DefifaDeployer({
            hookCodeOrigin: address(hook),
            tokenUriResolver: new DefifaTokenUriResolver(address(this)),
            governor: governor,
            controller: jbController(),
            registry: new JBAddressRegistry(),
            defifaProjectId: protocolFeeProjectId,
            baseProtocolProjectId: defifaProjectId,
            hookStore: new JB721TiersHookStore()
        });
        hook.transferOwnership(address(deployer));
        governor.transferOwnership(address(deployer));
    }

    /// @notice `DefifaDeployer` reports itself as an `IJBPayerTracker` and exposes a zero payer outside of a launch.
    function testSupportsPayerTracker() external view {
        assertTrue(type(IJBPayerTracker).interfaceId != bytes4(0));
        IJBPayerTracker(address(deployer)); // compile-time proof the contract implements the interface.
        assertEq(deployer.originalPayer(), address(0), "no launch in progress");
    }

    /// @notice Launching a game as an EOA advertises that EOA to the creation-fee receiver, not the deployer.
    function testAdvertisesResolvedFeePayerDuringLaunch() external {
        // Route the creation fee through a receiver that records the advertised payer.
        PayerRecordingFeeReceiver feeReceiver = new PayerRecordingFeeReceiver(IJBPayerTracker(address(jbProjects())));
        uint256 fee = jbProjects().MAX_CREATION_FEE();
        vm.prank(multisig());
        jbProjects().setCreationFee(fee, payable(address(feeReceiver)));

        // Launch as a plain EOA so the resolved payer is the EOA itself, not an upstream tracker.
        address player = address(bytes20(keccak256("player")));
        vm.deal(player, fee);
        vm.prank(player);
        deployer.launchGameWith{value: fee}(_launchData());

        // The receiver saw the EOA that paid the fee, and the deployer cleared its transient payer afterwards.
        assertEq(feeReceiver.recordedPayer(), player, "fee credited to deployer instead of payer");
        assertEq(deployer.originalPayer(), address(0), "transient payer not cleared");
    }

    function _launchData() internal view returns (DefifaLaunchProjectData memory) {
        DefifaTierParams[] memory tiers = new DefifaTierParams[](2);
        for (uint256 i; i < tiers.length; i++) {
            tiers[i] = DefifaTierParams({
                reservedRate: 0,
                reservedTokenBeneficiary: address(0),
                encodedIpfsUri: bytes32(0),
                shouldUseReservedTokenBeneficiaryAsDefault: false,
                name: "DEFIFA"
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
            tiers: tiers,
            defaultTokenUriResolver: IJB721TokenUriResolver(address(0)),
            terminal: jbMultiTerminal(),
            minParticipation: 0,
            scorecardTimeout: type(uint32).max,
            timelockDuration: 0
        });
    }

    function _terminals() internal view returns (JBTerminalConfig[] memory tc) {
        JBAccountingContext[] memory tokens = new JBAccountingContext[](1);
        tokens[0] = JBAccountingContext({token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: JBCurrencyIds.ETH});
        tc = new JBTerminalConfig[](1);
        tc[0] = JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: tokens});
    }

    function _emptyRulesets() internal pure returns (JBRulesetConfig[] memory rc) {
        rc = new JBRulesetConfig[](1);
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
                scopeCashOutsToLocalBalances: true,
                useDataHookForPay: true,
                useDataHookForCashOut: true,
                dataHook: address(0),
                metadata: 0
            }),
            splitGroups: new JBSplitGroup[](0),
            fundAccessLimitGroups: new JBFundAccessLimitGroup[](0)
        });
    }
}
