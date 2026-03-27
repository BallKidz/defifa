// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {TestBaseWorkflow} from "@bananapus/core-v6/test/helpers/TestBaseWorkflow.sol";

import {DefifaGovernor} from "../../src/DefifaGovernor.sol";
import {DefifaDeployer} from "../../src/DefifaDeployer.sol";
import {DefifaHook} from "../../src/DefifaHook.sol";
import {DefifaTokenUriResolver} from "../../src/DefifaTokenUriResolver.sol";
import {JB721TiersHookStore} from "@bananapus/721-hook-v6/src/JB721TiersHookStore.sol";
import {JB721TiersMintReservesConfig} from "@bananapus/721-hook-v6/src/structs/JB721TiersMintReservesConfig.sol";

import {JBTest} from "@bananapus/core-v6/test/helpers/JBTest.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JBRulesetMetadataResolver} from "@bananapus/core-v6/src/libraries/JBRulesetMetadataResolver.sol";
import {JBAddressRegistry} from "@bananapus/address-registry-v6/src/JBAddressRegistry.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ITypeface} from "lib/typeface/contracts/interfaces/ITypeface.sol";
import {IJB721TokenUriResolver} from "@bananapus/721-hook-v6/src/interfaces/IJB721TokenUriResolver.sol";
import {DefifaDelegation} from "../../src/structs/DefifaDelegation.sol";
import {DefifaLaunchProjectData} from "../../src/structs/DefifaLaunchProjectData.sol";
import {DefifaTierParams} from "../../src/structs/DefifaTierParams.sol";
import {DefifaTierCashOutWeight} from "../../src/structs/DefifaTierCashOutWeight.sol";
import {DefifaScorecardState} from "../../src/enums/DefifaScorecardState.sol";
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

contract PendingReserveQuorumGriefTest is JBTest, TestBaseWorkflow {
    using JBRulesetMetadataResolver for JBRuleset;

    uint256 internal _protocolFeeProjectId;
    uint256 internal _defifaProjectId;
    uint256 internal _gameId = 3;

    DefifaDeployer internal _deployer;
    DefifaHook internal _hookImpl;
    DefifaGovernor internal _governorImpl;

    address internal _projectOwner = address(bytes20(keccak256("projectOwner")));
    address internal _reserveBeneficiary = address(bytes20(keccak256("reserveBeneficiary")));
    address internal _player0 = address(bytes20(keccak256("player0")));
    address internal _player1 = address(bytes20(keccak256("player1")));
    address internal _player2 = address(bytes20(keccak256("player2")));
    address internal _player3 = address(bytes20(keccak256("player3")));

    DefifaHook internal _nft;
    DefifaGovernor internal _gov;
    uint256 internal _pid;

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

    /// @notice RPT-H-2 FIX VERIFICATION: Quorum snapshot prevents reserve mints from reopening a succeeded scorecard.
    ///
    /// 1. Four players mint into tiers 1-4 (each creates 1 pending reserve due to reserveRate=1)
    /// 2. Pending reserves dilute each player's attestation power to 50% of MAX_POWER per tier
    /// 3. All 4 players attest → total = 4 * 0.5 * MAX_POWER = 2 * MAX_POWER, meeting quorum
    /// 4. Minting reserves after submission doesn't change the snapshotted quorum
    function test_quorumSnapshotPreventsReserveMintFromReopeningSucceededScorecard() external {
        (_pid, _nft, _gov) = _launch(_launchData());

        // --- MINT phase --- players mint 1 NFT each into tiers 1-4
        vm.warp(86_402);
        _mint(_player0, 1);
        _mint(_player1, 2);
        _mint(_player2, 3);
        _mint(_player3, 4);
        _delegateSelf(_player0, 1);
        _delegateSelf(_player1, 2);
        _delegateSelf(_player2, 3);
        _delegateSelf(_player3, 4);

        // --- Skip REFUND phase (no cash-outs) ---
        vm.warp(172_802);

        // --- SCORING phase --- submit scorecard
        vm.warp(259_202);
        DefifaTierCashOutWeight[] memory scorecard = _buildScorecard();
        uint256 proposalId = _gov.submitScorecardFor(_gameId, scorecard);

        // Quorum = 4 tiers * MAX_POWER / 2 = 2 * MAX_POWER
        uint256 snapshotQuorum = _gov.quorum(_gameId);
        assertEq(snapshotQuorum, _gov.MAX_ATTESTATION_POWER_TIER() * 2, "4 tiers, quorum = 2 * MAX_POWER");

        // Each player's attestation power is diluted by pending reserves (1 pending per tier).
        // Per-tier power: 1/(1+1) * MAX_POWER = 0.5 * MAX_POWER. All 4 players needed.
        vm.prank(_player0);
        _gov.attestToScorecardFrom(_gameId, proposalId);
        vm.prank(_player1);
        _gov.attestToScorecardFrom(_gameId, proposalId);
        vm.prank(_player2);
        _gov.attestToScorecardFrom(_gameId, proposalId);
        vm.prank(_player3);
        _gov.attestToScorecardFrom(_gameId, proposalId);

        vm.warp(block.timestamp + _gov.attestationGracePeriodOf(_gameId) + 1);

        assertEq(
            uint256(_gov.stateOf(_gameId, proposalId)),
            uint256(DefifaScorecardState.SUCCEEDED),
            "scorecard succeeds with all 4 diluted attestors"
        );

        // --- ATTEMPTED ATTACK --- anyone mints pending reserves
        JB721TiersMintReservesConfig[] memory reserveConfigs = new JB721TiersMintReservesConfig[](1);
        reserveConfigs[0] = JB721TiersMintReservesConfig({tierId: 3, count: 1});
        _nft.mintReservesFor(reserveConfigs);

        // Scorecard STILL SUCCEEDED — snapshotted quorum is immutable
        assertEq(
            uint256(_gov.stateOf(_gameId, proposalId)),
            uint256(DefifaScorecardState.SUCCEEDED),
            "snapshot holds after reserve mint"
        );
    }

    /// @notice RPT-H-2 FIX VERIFICATION: Ratification succeeds after reserve mint because snapshot holds.
    function test_ratificationSucceedsAfterReserveMintWithQuorumSnapshot() external {
        (_pid, _nft, _gov) = _launch(_launchData());

        // MINT phase
        vm.warp(86_402);
        _mint(_player0, 1);
        _mint(_player1, 2);
        _mint(_player2, 3);
        _mint(_player3, 4);
        _delegateSelf(_player0, 1);
        _delegateSelf(_player1, 2);
        _delegateSelf(_player2, 3);
        _delegateSelf(_player3, 4);

        // Skip REFUND phase
        vm.warp(172_802);

        // SCORING phase — submit, all 4 attest (each diluted to 50% by pending reserves)
        vm.warp(259_202);
        DefifaTierCashOutWeight[] memory scorecard = _buildScorecard();
        uint256 proposalId = _gov.submitScorecardFor(_gameId, scorecard);
        vm.prank(_player0);
        _gov.attestToScorecardFrom(_gameId, proposalId);
        vm.prank(_player1);
        _gov.attestToScorecardFrom(_gameId, proposalId);
        vm.prank(_player2);
        _gov.attestToScorecardFrom(_gameId, proposalId);
        vm.prank(_player3);
        _gov.attestToScorecardFrom(_gameId, proposalId);
        vm.warp(block.timestamp + _gov.attestationGracePeriodOf(_gameId) + 1);

        assertEq(
            uint256(_gov.stateOf(_gameId, proposalId)),
            uint256(DefifaScorecardState.SUCCEEDED),
            "scorecard should be succeeded"
        );

        // Mint reserves — shouldn't affect ratification
        JB721TiersMintReservesConfig[] memory reserveConfigs = new JB721TiersMintReservesConfig[](1);
        reserveConfigs[0] = JB721TiersMintReservesConfig({tierId: 3, count: 1});
        _nft.mintReservesFor(reserveConfigs);

        // Ratification succeeds because stateOf uses snapshotted quorum
        uint256 ratifiedId = _gov.ratifyScorecardFrom(_gameId, scorecard);
        assertEq(ratifiedId, proposalId, "ratification succeeds with snapshotted quorum");
    }

    function _buildScorecard() internal view returns (DefifaTierCashOutWeight[] memory scorecard) {
        scorecard = new DefifaTierCashOutWeight[](4);
        uint256 totalWeight = _nft.TOTAL_CASHOUT_WEIGHT();
        scorecard[0] = DefifaTierCashOutWeight({id: 1, cashOutWeight: totalWeight / 2});
        scorecard[1] = DefifaTierCashOutWeight({id: 2, cashOutWeight: totalWeight / 2});
        scorecard[2] = DefifaTierCashOutWeight({id: 3, cashOutWeight: 0});
        scorecard[3] = DefifaTierCashOutWeight({id: 4, cashOutWeight: 0});
    }

    function _launchData() internal returns (DefifaLaunchProjectData memory data) {
        DefifaTierParams[] memory tiers = new DefifaTierParams[](4);
        for (uint256 i; i < 4; i++) {
            tiers[i] = DefifaTierParams({
                reservedRate: 1,
                reservedTokenBeneficiary: _reserveBeneficiary,
                encodedIPFSUri: bytes32(0),
                shouldUseReservedTokenBeneficiaryAsDefault: false,
                name: "TEAM"
            });
        }

        data = DefifaLaunchProjectData({
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
            scorecardTimeout: 0
        });
    }

    function _launch(DefifaLaunchProjectData memory data)
        internal
        returns (uint256 projectId, DefifaHook nft, DefifaGovernor gov)
    {
        gov = _governorImpl;
        projectId = _deployer.launchGameWith(data);
        JBRuleset memory ruleset = jbRulesets().currentOf(projectId);
        if (ruleset.dataHook() == address(0)) (ruleset,) = jbRulesets().latestQueuedOf(projectId);
        nft = DefifaHook(ruleset.dataHook());
    }

    function _mint(address user, uint256 tierId) internal {
        vm.deal(user, 1 ether);
        uint16[] memory tiers = new uint16[](1);
        tiers[0] = uint16(tierId);
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encode(user, tiers);
        bytes4[] memory ids = new bytes4[](1);
        ids[0] = metadataHelper().getId("pay", address(_hookImpl));
        bytes memory metadata = metadataHelper().createMetadata(ids, data);

        vm.prank(user);
        jbMultiTerminal().pay{value: 1 ether}(_pid, JBConstants.NATIVE_TOKEN, 1 ether, user, 0, "", metadata);
    }

    function _delegateSelf(address user, uint256 tierId) internal {
        DefifaDelegation[] memory delegations = new DefifaDelegation[](1);
        delegations[0] = DefifaDelegation({delegatee: user, tierId: tierId});
        vm.prank(user);
        _nft.setTierDelegatesTo(delegations);
    }

    function _cashOut(address user, uint256 tierId, uint256 tokenNumber) internal {
        bytes memory metadata = _cashOutMetadata(tierId, tokenNumber);
        vm.prank(user);
        jbMultiTerminal()
            .cashOutTokensOf({
                holder: user,
                projectId: _pid,
                cashOutCount: 0,
                tokenToReclaim: JBConstants.NATIVE_TOKEN,
                minTokensReclaimed: 0,
                beneficiary: payable(user),
                metadata: metadata
            });
    }

    function _cashOutMetadata(uint256 tierId, uint256 tokenNumber) internal view returns (bytes memory) {
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = (tierId * 1_000_000_000) + tokenNumber;
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encode(tokenIds);
        bytes4[] memory ids = new bytes4[](1);
        ids[0] = metadataHelper().getId("cashOut", address(_hookImpl));
        return metadataHelper().createMetadata(ids, data);
    }
}
