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
import {JBRulesetMetadataResolver} from "@bananapus/core-v6/src/libraries/JBRulesetMetadataResolver.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBCurrencyIds} from "@bananapus/core-v6/src/libraries/JBCurrencyIds.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetApprovalHook.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";

/// @notice Verifies that the pending-reserve snapshot fix prevents reserve minting from inflating
/// attestation power after scorecard submission.
contract PendingReserveSnapshotBypassTest is JBTest, TestBaseWorkflow {
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
            _protocolFeeProjectId,
            new JB721TiersHookStore()
        );

        _hookImpl.transferOwnership(address(_deployer));
        _governorImpl.transferOwnership(address(_deployer));
    }

    /// @notice Confirms the snapshot fix: minting pending reserves after scorecard submission does NOT
    /// inflate the submitter's BWA attestation weight. The snapshot locks pending-reserve counts at
    /// submission time so that post-submission reserve minting cannot remove the dilution.
    function test_mintingPendingReserveAfterSnapshotInflatesVotingPowerAndFlipsOutcome() external {
        (_pid, _nft, _gov) = _launch(_launchData());

        vm.warp(block.timestamp + 1 days + 1);
        _mint(_player0, 1);
        _mint(_player1, 2);
        _mint(_player2, 3);
        _mint(_player3, 4);
        _delegateSelf(_player0, 1);
        _delegateSelf(_player1, 2);
        _delegateSelf(_player2, 3);
        _delegateSelf(_player3, 4);

        assertEq(_nft.store().numberOfPendingReservesFor(address(_nft), 1), 1, "tier 1 starts with pending reserve");

        vm.warp(block.timestamp + 2 days + 1);

        DefifaTierCashOutWeight[] memory scorecard = _evenScorecard();
        uint256 scorecardId = _gov.submitScorecardFor(_gameId, scorecard);
        uint48 snapshotTime = uint48(block.timestamp);

        uint256 preBwa0 = _gov.getBWAAttestationWeight(_gameId, scorecardId, _player0, snapshotTime);
        uint256 preBwa1 = _gov.getBWAAttestationWeight(_gameId, scorecardId, _player1, snapshotTime);

        assertEq(preBwa0, 375_000_000, "pending reserve should dilute tier 1 holder at snapshot");
        assertEq(preBwa1, 750_000_000, "non-reserve tier holder keeps full post-BWA weight");
        assertEq(preBwa0 + preBwa1 + preBwa1, 1_875_000_000, "three attestors start below adjusted quorum");

        vm.warp(block.timestamp + 1);

        JB721TiersMintReservesConfig[] memory reserveConfigs = new JB721TiersMintReservesConfig[](1);
        reserveConfigs[0] = JB721TiersMintReservesConfig({tierId: 1, count: 1});
        _nft.mintReservesFor(reserveConfigs);

        uint256 postRaw0 = _gov.getAttestationWeight(_gameId, _player0, snapshotTime);
        uint256 postBwa0 = _gov.getBWAAttestationWeight(_gameId, scorecardId, _player0, snapshotTime);

        // After fix: getAttestationWeight reads live state (reserves are now minted), so raw weight goes up.
        assertEq(postRaw0, 1_000_000_000, "minting reserves removes pending-reserve dilution in live view");

        // After fix: getBWAAttestationWeight uses the snapshot, so pending-reserve dilution is preserved.
        // The BWA weight does NOT double -- the snapshot prevents inflation.
        assertEq(postBwa0, 375_000_000, "snapshot prevents reserve minting from inflating BWA power");

        vm.startPrank(_player0);
        _gov.attestToScorecardFrom(_gameId, scorecardId);
        vm.stopPrank();
        vm.startPrank(_player1);
        _gov.attestToScorecardFrom(_gameId, scorecardId);
        vm.stopPrank();
        vm.startPrank(_player2);
        _gov.attestToScorecardFrom(_gameId, scorecardId);
        vm.stopPrank();

        vm.warp(block.timestamp + _gov.attestationGracePeriodOf(_gameId) + 1);

        // After fix: three attestors cannot reach quorum because the snapshot preserves the dilution.
        // Their combined weight: 375M + 750M + 750M = 1,875M < quorum (2,000M base).
        assertEq(
            uint256(_gov.stateOf(_gameId, scorecardId)),
            uint256(DefifaScorecardState.ACTIVE),
            "reserve mint after snapshot does NOT let three attestors reach quorum"
        );
    }

    /// @notice Pending reserve mints in the delayed-attestation window must not change BWA power.
    function test_mintingPendingReserveBeforeDelayedAttestationDoesNotChangeBWA() external {
        DefifaLaunchProjectData memory data = _launchData();
        data.attestationStartTime = uint48(block.timestamp + 5 days);

        (_pid, _nft, _gov) = _launch(data);

        vm.warp(block.timestamp + 1 days + 1);
        _mint(_player0, 1);
        _mint(_player1, 2);
        _mint(_player2, 3);
        _mint(_player3, 4);
        _delegateSelf(_player0, 1);
        _delegateSelf(_player1, 2);
        _delegateSelf(_player2, 3);
        _delegateSelf(_player3, 4);

        vm.warp(block.timestamp + 2 days);

        DefifaTierCashOutWeight[] memory scorecard = _evenScorecard();
        uint256 scorecardId = _gov.submitScorecardFor(_gameId, scorecard);
        uint48 futureSnapshotTime = uint48(_gov.attestationStartTimeOf(_gameId) - 1);

        uint256 preRaw = _gov.getAttestationWeight(_gameId, _player0, futureSnapshotTime);
        uint256 preBwa = _gov.getBWAAttestationWeight(_gameId, scorecardId, _player0, futureSnapshotTime);

        JB721TiersMintReservesConfig[] memory reserveConfigs = new JB721TiersMintReservesConfig[](1);
        reserveConfigs[0] = JB721TiersMintReservesConfig({tierId: 1, count: 1});
        _nft.mintReservesFor(reserveConfigs);

        uint256 postRaw = _gov.getAttestationWeight(_gameId, _player0, futureSnapshotTime);
        uint256 postBwa = _gov.getBWAAttestationWeight(_gameId, scorecardId, _player0, futureSnapshotTime);

        assertEq(preRaw, 500_000_000, "future raw snapshot includes the pending reserve exactly once");
        assertEq(preBwa, 375_000_000, "future BWA starts from the reserve-adjusted submission denominator");
        assertEq(postRaw, preRaw, "future raw power stays frozen before attestation begins");
        assertEq(postBwa, preBwa, "reserve mint in delayed window must not change BWA power");
    }

    function _evenScorecard() internal view returns (DefifaTierCashOutWeight[] memory scorecard) {
        scorecard = new DefifaTierCashOutWeight[](4);
        uint256 totalWeight = _nft.TOTAL_CASHOUT_WEIGHT();
        uint256 perTier = totalWeight / 4;
        for (uint256 i; i < 4; i++) {
            scorecard[i] = DefifaTierCashOutWeight({id: i + 1, cashOutWeight: perTier});
        }
    }

    function _launchData() internal returns (DefifaLaunchProjectData memory data) {
        DefifaTierParams[] memory tiers = new DefifaTierParams[](4);
        tiers[0] = DefifaTierParams({
            reservedRate: 1,
            reservedTokenBeneficiary: _reserveBeneficiary,
            encodedIPFSUri: bytes32(0),
            shouldUseReservedTokenBeneficiaryAsDefault: false,
            name: "TEAM"
        });
        for (uint256 i = 1; i < 4; i++) {
            tiers[i] = DefifaTierParams({
                reservedRate: 1001,
                reservedTokenBeneficiary: address(0),
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
            minParticipation: 0,
            scorecardTimeout: 0,
            timelockDuration: 0
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
        // forge-lint: disable-next-line(unsafe-typecast)
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
}
