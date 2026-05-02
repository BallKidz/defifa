// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {TestBaseWorkflow} from "@bananapus/core-v6/test/helpers/TestBaseWorkflow.sol";
import {JBTest} from "@bananapus/core-v6/test/helpers/JBTest.sol";

import {DefifaDeployer} from "../../src/DefifaDeployer.sol";
import {DefifaGovernor} from "../../src/DefifaGovernor.sol";
import {DefifaHook} from "../../src/DefifaHook.sol";
import {DefifaTokenUriResolver} from "../../src/DefifaTokenUriResolver.sol";
import {DefifaGamePhase} from "../../src/enums/DefifaGamePhase.sol";
import {DefifaLaunchProjectData} from "../../src/structs/DefifaLaunchProjectData.sol";
import {DefifaTierParams} from "../../src/structs/DefifaTierParams.sol";
import {JB721TiersHookStore} from "@bananapus/721-hook-v6/src/JB721TiersHookStore.sol";
import {JB721TiersMintReservesConfig} from "@bananapus/721-hook-v6/src/structs/JB721TiersMintReservesConfig.sol";
import {IJB721TokenUriResolver} from "@bananapus/721-hook-v6/src/interfaces/IJB721TokenUriResolver.sol";
import {JBAddressRegistry} from "@bananapus/address-registry-v6/src/JBAddressRegistry.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBCurrencyIds} from "@bananapus/core-v6/src/libraries/JBCurrencyIds.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBTerminalConfig} from "@bananapus/core-v6/src/structs/JBTerminalConfig.sol";
import {JBRulesetConfig} from "@bananapus/core-v6/src/structs/JBRulesetConfig.sol";
import {JBRulesetMetadata} from "@bananapus/core-v6/src/structs/JBRulesetMetadata.sol";
import {JBSplitGroup} from "@bananapus/core-v6/src/structs/JBSplitGroup.sol";
import {JBFundAccessLimitGroup} from "@bananapus/core-v6/src/structs/JBFundAccessLimitGroup.sol";
import {JBSplit} from "@bananapus/core-v6/src/structs/JBSplit.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetApprovalHook.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ITypeface} from "lib/typeface/contracts/interfaces/ITypeface.sol";

contract NoContestReserveDrainTest is JBTest, TestBaseWorkflow {
    uint256 internal _protocolFeeProjectId;
    uint256 internal _defifaProjectId;

    DefifaDeployer internal _deployer;
    DefifaHook internal _hookImpl;
    DefifaGovernor internal _governorImpl;

    address internal _projectOwner = address(bytes20(keccak256("projectOwner")));
    address internal _player = address(bytes20(keccak256("player")));
    address internal _reserveBeneficiary = address(bytes20(keccak256("reserveBeneficiary")));

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

        _protocolFeeProjectId =
            jbController().launchProjectFor(address(_projectOwner), "", rulesetConfigs, terminalConfigs, "");
        vm.prank(_projectOwner);
        address nanaToken =
            address(jbController().deployERC20For(_protocolFeeProjectId, "Bananapus", "NANA", bytes32(0)));

        _defifaProjectId =
            jbController().launchProjectFor(address(_projectOwner), "", rulesetConfigs, terminalConfigs, "");
        vm.prank(_projectOwner);
        address defifaToken = address(jbController().deployERC20For(_defifaProjectId, "Defifa", "DEFIFA", bytes32(0)));

        _hookImpl = new DefifaHook(jbDirectory(), IERC20(defifaToken), IERC20(nanaToken));
        _governorImpl = new DefifaGovernor(jbController(), address(this));
        _deployer = new DefifaDeployer(
            address(_hookImpl),
            new DefifaTokenUriResolver(ITypeface(address(0))),
            _governorImpl,
            jbController(),
            new JBAddressRegistry(),
            _defifaProjectId,
            _protocolFeeProjectId,
            new JB721TiersHookStore()
        );

        _hookImpl.transferOwnership(address(_deployer));
        _governorImpl.transferOwnership(address(_deployer));
    }

    function test_noContestReserveMintExcludedFromRefund() external {
        DefifaLaunchProjectData memory data = _launchData();
        uint256 projectId = _deployer.launchGameWith(data);

        vm.warp(data.start - data.mintPeriodDuration - data.refundPeriodDuration);
        vm.deal(_player, 1 ether);

        uint16[] memory tierIds = new uint16[](1);
        tierIds[0] = 1;
        vm.prank(_player);
        jbMultiTerminal().pay{value: 1 ether}(
            projectId,
            JBConstants.NATIVE_TOKEN,
            1 ether,
            _player,
            0,
            "",
            _buildPayMetadata(abi.encode(_player, tierIds))
        );

        vm.warp(data.start + 1);
        (, JBRulesetMetadata memory metadata) = jbController().currentRulesetOf(projectId);
        DefifaHook hook = DefifaHook(metadata.dataHook);
        assertEq(uint256(_deployer.currentGamePhaseOf(projectId)), uint256(DefifaGamePhase.NO_CONTEST));

        JB721TiersMintReservesConfig[] memory reserveConfigs = new JB721TiersMintReservesConfig[](1);
        reserveConfigs[0] = JB721TiersMintReservesConfig({tierId: 1, count: 1});
        hook.mintReservesFor(reserveConfigs);

        assertEq(hook.balanceOf(_reserveBeneficiary), 1, "reserve beneficiary received a free NFT");
        assertTrue(hook.isReserveMint(_generateTokenId(1, 2)), "token flagged as reserve mint");

        _deployer.triggerNoContestFor(projectId);

        // Build metadata for the reserve token cashout before calling expectRevert.
        uint256 reserveTokenId = _generateTokenId(1, 2);
        uint256[] memory reserveTokenIds = new uint256[](1);
        reserveTokenIds[0] = reserveTokenId;
        bytes memory reserveCashOutMetadata = _buildCashOutMetadata(reserveTokenIds);

        // The reserve beneficiary's cashout reverts — reserve-minted tokens are excluded from refund calculations.
        vm.prank(_reserveBeneficiary);
        vm.expectRevert();
        jbMultiTerminal()
            .cashOutTokensOf(
                _reserveBeneficiary,
                projectId,
                0,
                JBConstants.NATIVE_TOKEN,
                0,
                payable(_reserveBeneficiary),
                reserveCashOutMetadata
            );

        // The paid player can still get their full refund.
        uint256 playerTokenId = _generateTokenId(1, 1);
        uint256 balanceBefore = _player.balance;
        _cashOut(projectId, _player, playerTokenId);

        // Player gets full refund (1 ether minus fee).
        assertTrue(_player.balance > balanceBefore, "player received refund");
        assertEq(hook.balanceOf(_player), 0, "player NFT burned");
    }

    function _cashOut(uint256 projectId, address holder, uint256 tokenId) internal {
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = tokenId;
        bytes memory cashOutMetadata = _buildCashOutMetadata(tokenIds);

        vm.prank(holder);
        jbMultiTerminal()
            .cashOutTokensOf(holder, projectId, 0, JBConstants.NATIVE_TOKEN, 0, payable(holder), cashOutMetadata);
    }

    function _launchData() internal returns (DefifaLaunchProjectData memory) {
        DefifaTierParams[] memory tierParams = new DefifaTierParams[](1);
        tierParams[0] = DefifaTierParams({
            reservedRate: 1,
            reservedTokenBeneficiary: _reserveBeneficiary,
            encodedIPFSUri: bytes32(0),
            shouldUseReservedTokenBeneficiaryAsDefault: false,
            name: "SOLE"
        });

        return DefifaLaunchProjectData({
            name: "DEFIFA",
            projectUri: "",
            contractUri: "",
            baseUri: "",
            tiers: tierParams,
            tierPrice: 1 ether,
            token: JBAccountingContext({token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: JBCurrencyIds.ETH}),
            mintPeriodDuration: 1 days,
            refundPeriodDuration: 1 days,
            start: uint48(block.timestamp + 3 days),
            splits: new JBSplit[](0),
            attestationStartTime: 0,
            attestationGracePeriod: 1 days,
            defaultAttestationDelegate: address(0),
            defaultTokenUriResolver: IJB721TokenUriResolver(address(0)),
            terminal: jbMultiTerminal(),
            minParticipation: 2 ether,
            scorecardTimeout: 100_382,
            timelockDuration: 0
        });
    }

    function _buildPayMetadata(bytes memory decodedData) internal view returns (bytes memory) {
        bytes4[] memory ids = new bytes4[](1);
        ids[0] = metadataHelper().getId("pay", address(_hookImpl));
        bytes[] memory datas = new bytes[](1);
        datas[0] = decodedData;
        return metadataHelper().createMetadata(ids, datas);
    }

    function _buildCashOutMetadata(uint256[] memory tokenIds) internal view returns (bytes memory) {
        bytes4[] memory ids = new bytes4[](1);
        ids[0] = metadataHelper().getId("cashOut", address(_hookImpl));
        bytes[] memory datas = new bytes[](1);
        datas[0] = abi.encode(tokenIds);
        return metadataHelper().createMetadata(ids, datas);
    }

    function _generateTokenId(uint256 tierId, uint256 tokenNumber) internal pure returns (uint256) {
        return (tierId * 1_000_000_000) + tokenNumber;
    }
}
