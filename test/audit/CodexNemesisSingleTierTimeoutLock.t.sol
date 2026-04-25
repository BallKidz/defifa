// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {TestBaseWorkflow} from "@bananapus/core-v6/test/helpers/TestBaseWorkflow.sol";
import {JBTest} from "@bananapus/core-v6/test/helpers/JBTest.sol";

import {DefifaDeployer} from "../../src/DefifaDeployer.sol";
import {DefifaGovernor} from "../../src/DefifaGovernor.sol";
import {DefifaHook} from "../../src/DefifaHook.sol";
import {DefifaTokenUriResolver} from "../../src/DefifaTokenUriResolver.sol";
import {DefifaGamePhase} from "../../src/enums/DefifaGamePhase.sol";
import {DefifaTierCashOutWeight} from "../../src/structs/DefifaTierCashOutWeight.sol";
import {DefifaLaunchProjectData} from "../../src/structs/DefifaLaunchProjectData.sol";
import {DefifaTierParams} from "../../src/structs/DefifaTierParams.sol";
import {DefifaDelegation} from "../../src/structs/DefifaDelegation.sol";
import {JB721TiersHookStore} from "@bananapus/721-hook-v6/src/JB721TiersHookStore.sol";
import {IJB721TokenUriResolver} from "@bananapus/721-hook-v6/src/interfaces/IJB721TokenUriResolver.sol";
import {JBAddressRegistry} from "@bananapus/address-registry-v6/src/JBAddressRegistry.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBCurrencyIds} from "@bananapus/core-v6/src/libraries/JBCurrencyIds.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBTerminalConfig} from "@bananapus/core-v6/src/structs/JBTerminalConfig.sol";
import {JBRulesetConfig} from "@bananapus/core-v6/src/structs/JBRulesetConfig.sol";
import {JBRulesetMetadata} from "@bananapus/core-v6/src/structs/JBRulesetMetadata.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JBRulesetMetadataResolver} from "@bananapus/core-v6/src/libraries/JBRulesetMetadataResolver.sol";
import {JBSplitGroup} from "@bananapus/core-v6/src/structs/JBSplitGroup.sol";
import {JBSplit} from "@bananapus/core-v6/src/structs/JBSplit.sol";
import {JBFundAccessLimitGroup} from "@bananapus/core-v6/src/structs/JBFundAccessLimitGroup.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesets.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ITypeface} from "lib/typeface/contracts/interfaces/ITypeface.sol";

contract CodexNemesisSingleTierTimeoutLockTest is JBTest, TestBaseWorkflow {
    using JBRulesetMetadataResolver for JBRuleset;

    uint256 internal _protocolFeeProjectId;
    uint256 internal _defifaProjectId;
    uint256 internal _gameId = 3;

    DefifaDeployer internal _deployer;
    DefifaHook internal _hookImpl;
    DefifaGovernor internal _governorImpl;

    address internal _projectOwner = address(bytes20(keccak256("projectOwner")));
    address internal _player = address(bytes20(keccak256("player")));

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
            _protocolFeeProjectId
        );

        _hookImpl.transferOwnership(address(_deployer));
        _governorImpl.transferOwnership(address(_deployer));
    }

    function test_singleTierGameWithZeroTimeoutLocksFunds() external {
        DefifaLaunchProjectData memory data = _launchData();
        uint256 projectId = _deployer.launchGameWith(data);
        JBRuleset memory ruleset = jbRulesets().currentOf(projectId);
        if (ruleset.dataHook() == address(0)) {
            (ruleset,) = jbRulesets().latestQueuedOf(projectId);
        }
        DefifaHook hook = DefifaHook(ruleset.dataHook());

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

        DefifaDelegation[] memory delegations = new DefifaDelegation[](1);
        delegations[0] = DefifaDelegation({delegatee: _player, tierId: 1});
        vm.prank(_player);
        hook.setTierDelegatesTo(delegations);

        vm.warp(data.start + 1);
        assertEq(uint256(_deployer.currentGamePhaseOf(projectId)), uint256(DefifaGamePhase.SCORING));

        DefifaTierCashOutWeight[] memory scorecard = new DefifaTierCashOutWeight[](1);
        scorecard[0] = DefifaTierCashOutWeight({id: 1, cashOutWeight: hook.TOTAL_CASHOUT_WEIGHT()});
        uint256 scorecardId = _governorImpl.submitScorecardFor(_gameId, scorecard);

        assertEq(_governorImpl.quorum(_gameId), 500_000_000, "single tier quorum remains positive");
        assertEq(
            _governorImpl.getBWAAttestationWeight(_gameId, scorecardId, _player, uint48(block.timestamp)),
            0,
            "sole beneficiary has zero BWA power"
        );

        vm.prank(_player);
        vm.expectRevert(DefifaGovernor.DefifaGovernor_NotAllowed.selector);
        _governorImpl.attestToScorecardFrom(_gameId, scorecardId);

        vm.warp(block.timestamp + 365 days);
        assertEq(
            uint256(_deployer.currentGamePhaseOf(projectId)),
            uint256(DefifaGamePhase.SCORING),
            "timeout disabled keeps the game in scoring forever"
        );

        vm.expectRevert(DefifaDeployer.DefifaDeployer_NotNoContest.selector);
        _deployer.triggerNoContestFor(projectId);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = _generateTokenId(1, 1);
        bytes memory cashOutMetadata = _buildCashOutMetadata(tokenIds);

        vm.prank(_player);
        vm.expectRevert(DefifaHook.DefifaHook_NothingToClaim.selector);
        jbMultiTerminal().cashOutTokensOf(
            _player,
            projectId,
            0,
            JBConstants.NATIVE_TOKEN,
            0,
            payable(_player),
            cashOutMetadata
        );
    }

    function _launchData() internal returns (DefifaLaunchProjectData memory) {
        DefifaTierParams[] memory tierParams = new DefifaTierParams[](1);
        tierParams[0] = DefifaTierParams({
            reservedRate: 1001,
            reservedTokenBeneficiary: address(0),
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
            attestationGracePeriod: 100_381,
            defaultAttestationDelegate: address(0),
            defaultTokenUriResolver: IJB721TokenUriResolver(address(0)),
            terminal: jbMultiTerminal(),
            store: new JB721TiersHookStore(),
            minParticipation: 0,
            scorecardTimeout: 0,
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
