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
import {JBTest} from "@bananapus/core-v6/test/helpers/JBTest.sol";
import {TestBaseWorkflow} from "@bananapus/core-v6/test/helpers/TestBaseWorkflow.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBCurrencyIds} from "@bananapus/core-v6/src/libraries/JBCurrencyIds.sol";
import {JBFundAccessLimitGroup} from "@bananapus/core-v6/src/structs/JBFundAccessLimitGroup.sol";
import {JBRulesetConfig} from "@bananapus/core-v6/src/structs/JBRulesetConfig.sol";
import {JBRulesetMetadata} from "@bananapus/core-v6/src/structs/JBRulesetMetadata.sol";
import {JBSplit} from "@bananapus/core-v6/src/structs/JBSplit.sol";
import {JBSplitGroup} from "@bananapus/core-v6/src/structs/JBSplitGroup.sol";
import {JBTerminalConfig} from "@bananapus/core-v6/src/structs/JBTerminalConfig.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesets.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ITypeface} from "lib/typeface/contracts/interfaces/ITypeface.sol";

contract RegistryMismatchTest is JBTest, TestBaseWorkflow {
    JBAddressRegistry internal registry;
    DefifaDeployer internal deployer;

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

        DefifaHook hookCodeOrigin = new DefifaHook(jbDirectory(), IERC20(defifaToken), IERC20(nanaToken));
        DefifaGovernor governor = new DefifaGovernor(jbController(), address(this));
        registry = new JBAddressRegistry();
        deployer = new DefifaDeployer(
            address(hookCodeOrigin),
            new DefifaTokenUriResolver(ITypeface(address(0))),
            governor,
            jbController(),
            registry,
            defifaProjectId,
            protocolFeeProjectId,
            new JB721TiersHookStore()
        );

        hookCodeOrigin.transferOwnership(address(deployer));
        governor.transferOwnership(address(deployer));
    }

    function test_launchRegistersActualHookAddressInRegistry() external {
        uint256 projectId = deployer.launchGameWith(_launchData());
        (, JBRulesetMetadata memory metadata,) = jbController().latestQueuedRulesetOf(projectId);
        address actualHook = metadata.dataHook;

        address expectedCreateAddress = _createAddress(address(deployer), 1);

        assertNotEq(actualHook, address(0), "queued ruleset should reference the deployed hook");
        assertNotEq(actualHook, expectedCreateAddress, "cloneDeterministic did not use CREATE");
        assertEq(registry.deployerOf(actualHook), address(deployer), "actual hook should be registered");
        assertEq(
            registry.deployerOf(expectedCreateAddress), address(0), "legacy CREATE address should stay unregistered"
        );
    }

    function _launchData() internal view returns (DefifaLaunchProjectData memory) {
        DefifaTierParams[] memory tiers = new DefifaTierParams[](1);
        tiers[0] = DefifaTierParams({
            name: "Team 1",
            reservedRate: 0,
            reservedTokenBeneficiary: address(0),
            encodedIPFSUri: bytes32(0),
            shouldUseReservedTokenBeneficiaryAsDefault: false
        });

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
            scorecardTimeout: 100_382,
            timelockDuration: 0
        });
    }

    function _createAddress(address origin, uint256 nonce) internal pure returns (address addr) {
        bytes memory data;
        if (nonce == 0x00) {
            data = abi.encodePacked(bytes1(0xd6), bytes1(0x94), origin, bytes1(0x80));
        } else if (nonce <= 0x7f) {
            // forge-lint: disable-next-line(unsafe-typecast)
            data = abi.encodePacked(bytes1(0xd6), bytes1(0x94), origin, uint8(nonce));
        } else if (nonce <= 0xff) {
            // forge-lint: disable-next-line(unsafe-typecast)
            data = abi.encodePacked(bytes1(0xd7), bytes1(0x94), origin, bytes1(0x81), uint8(nonce));
        } else if (nonce <= 0xffff) {
            // forge-lint: disable-next-line(unsafe-typecast)
            data = abi.encodePacked(bytes1(0xd8), bytes1(0x94), origin, bytes1(0x82), uint16(nonce));
        } else if (nonce <= 0xffffff) {
            // forge-lint: disable-next-line(unsafe-typecast)
            data = abi.encodePacked(bytes1(0xd9), bytes1(0x94), origin, bytes1(0x83), uint24(nonce));
        } else if (nonce <= 0xffffffff) {
            // forge-lint: disable-next-line(unsafe-typecast)
            data = abi.encodePacked(bytes1(0xda), bytes1(0x94), origin, bytes1(0x84), uint32(nonce));
        } else if (nonce <= 0xffffffffff) {
            // forge-lint: disable-next-line(unsafe-typecast)
            data = abi.encodePacked(bytes1(0xdb), bytes1(0x94), origin, bytes1(0x85), uint40(nonce));
        } else if (nonce <= 0xffffffffffff) {
            // forge-lint: disable-next-line(unsafe-typecast)
            data = abi.encodePacked(bytes1(0xdc), bytes1(0x94), origin, bytes1(0x86), uint48(nonce));
        } else if (nonce <= 0xffffffffffffff) {
            // forge-lint: disable-next-line(unsafe-typecast)
            data = abi.encodePacked(bytes1(0xdd), bytes1(0x94), origin, bytes1(0x87), uint56(nonce));
        } else {
            // forge-lint: disable-next-line(unsafe-typecast)
            data = abi.encodePacked(bytes1(0xde), bytes1(0x94), origin, bytes1(0x88), uint64(nonce));
        }

        bytes32 hash = keccak256(data);
        assembly {
            mstore(0, hash)
            addr := mload(0)
        }
    }
}
