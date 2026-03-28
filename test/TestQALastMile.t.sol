// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {TestBaseWorkflow} from "@bananapus/core-v6/test/helpers/TestBaseWorkflow.sol";

import {DefifaGovernor} from "../src/DefifaGovernor.sol";
import {DefifaDeployer} from "../src/DefifaDeployer.sol";
import {DefifaHook} from "../src/DefifaHook.sol";
import {DefifaTokenUriResolver} from "../src/DefifaTokenUriResolver.sol";
import {DefifaGamePhase} from "../src/enums/DefifaGamePhase.sol";
import {IDefifaDeployer} from "../src/interfaces/IDefifaDeployer.sol";
import {JB721TiersHookStore} from "@bananapus/721-hook-v6/src/JB721TiersHookStore.sol";

import {JBTest} from "@bananapus/core-v6/test/helpers/JBTest.sol";
import {JBRulesetMetadataResolver} from "@bananapus/core-v6/src/libraries/JBRulesetMetadataResolver.sol";
import {JBAddressRegistry} from "@bananapus/address-registry-v6/src/JBAddressRegistry.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ITypeface} from "lib/typeface/contracts/interfaces/ITypeface.sol";
import {IJB721TokenUriResolver} from "@bananapus/721-hook-v6/src/interfaces/IJB721TokenUriResolver.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {DefifaDelegation} from "../src/structs/DefifaDelegation.sol";
import {DefifaLaunchProjectData} from "../src/structs/DefifaLaunchProjectData.sol";
import {DefifaTierParams} from "../src/structs/DefifaTierParams.sol";
import {DefifaTierCashOutWeight} from "../src/structs/DefifaTierCashOutWeight.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBTerminalConfig} from "@bananapus/core-v6/src/structs/JBTerminalConfig.sol";
import {JBRulesetConfig} from "@bananapus/core-v6/src/structs/JBRulesetConfig.sol";
import {JBRulesetMetadata} from "@bananapus/core-v6/src/structs/JBRulesetMetadata.sol";
import {JBSplitGroup} from "@bananapus/core-v6/src/structs/JBSplitGroup.sol";
import {JBFundAccessLimitGroup} from "@bananapus/core-v6/src/structs/JBFundAccessLimitGroup.sol";
import {JBSplit} from "@bananapus/core-v6/src/structs/JBSplit.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBCurrencyIds} from "@bananapus/core-v6/src/libraries/JBCurrencyIds.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesets.sol";
import {JBMultiTerminal} from "@bananapus/core-v6/src/JBMultiTerminal.sol";

/// @dev Helper to read block.timestamp via an external call, bypassing the via-ir optimizer's timestamp caching.
contract QATimestampReader {
    function timestamp() external view returns (uint256) {
        return block.timestamp;
    }
}

// =============================================================================
// QA LAST-MILE TEST 1: CASHOUT DoS WHEN FULFILLMENT FAILS DURING RATIFICATION
// =============================================================================

/// @title TestQACashOutDoSDuringFulfillmentWindow
/// @notice Documents the cashout denial-of-service window when fulfillCommitmentsOf reverts during ratification.
/// @dev When fulfillCommitmentsOf reverts during ratification (try-catch), the game enters COMPLETE phase
///      (scorecard is set) but the final ruleset — which has empty fundAccessLimitGroups (surplus = balance) —
///      is never queued. The SCORING ruleset remains active with payoutLimits = type(uint224).max, making
///      surplus = 0, which causes cashOutCount = 0 in the hook's computeCashOutCount.
///      Players cannot cash out until fulfillCommitmentsOf is successfully retried.
///      This is a known, accepted behavior: the DoS is temporary and funds are safe.
contract TestQACashOutDoSDuringFulfillmentWindow is JBTest, TestBaseWorkflow {
    using JBRulesetMetadataResolver for JBRuleset;

    QATimestampReader private _tsReader = new QATimestampReader();

    address _protocolFeeProjectTokenAccount;
    address _defifaProjectTokenAccount;
    uint256 _protocolFeeProjectId;
    uint256 _defifaProjectId;
    uint256 _gameId = 3;

    DefifaDeployer deployer;
    DefifaHook hook;
    DefifaGovernor governor;

    address projectOwner = address(bytes20(keccak256("projectOwner")));

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
        _protocolFeeProjectTokenAccount =
            address(jbController().deployERC20For(_protocolFeeProjectId, "Bananapus", "NANA", bytes32(0)));

        _defifaProjectId =
            jbController().launchProjectFor(address(projectOwner), "", rulesetConfigs, terminalConfigs, "");
        vm.prank(projectOwner);
        _defifaProjectTokenAccount =
            address(jbController().deployERC20For(_defifaProjectId, "Defifa", "DEFIFA", bytes32(0)));

        hook = new DefifaHook(
            jbDirectory(), IERC20(address(_defifaProjectTokenAccount)), IERC20(_protocolFeeProjectTokenAccount)
        );
        governor = new DefifaGovernor(jbController(), address(this));
        JBAddressRegistry _registry = new JBAddressRegistry();
        DefifaTokenUriResolver _tokenUriResolver = new DefifaTokenUriResolver(ITypeface(address(0)));
        deployer = new DefifaDeployer(
            address(hook),
            _tokenUriResolver,
            governor,
            jbController(),
            _registry,
            _defifaProjectId,
            _protocolFeeProjectId
        );

        hook.transferOwnership(address(deployer));
        governor.transferOwnership(address(deployer));
    }

    /// @notice Proves the fix: when sendPayoutsOf reverts during fulfillCommitmentsOf,
    ///         the internal try-catch handles it gracefully. The final ruleset is still queued,
    ///         and players can cash out immediately (no DoS).
    function test_cashOutDoSDuringFulfillmentWindow() public {
        uint8 nTiers = 4;
        address[] memory _users = new address[](nTiers);
        DefifaLaunchProjectData memory defifaData = _getBasicLaunchData(nTiers);
        (uint256 _projectId, DefifaHook _nft, DefifaGovernor _governor) = _createProject(defifaData);

        // --- Phase 1: Mint NFTs (1 ETH per user, 4 users = 4 ETH pot) ---
        vm.warp(defifaData.start - defifaData.mintPeriodDuration - defifaData.refundPeriodDuration);
        for (uint256 i = 0; i < nTiers; i++) {
            _users[i] = address(bytes20(keccak256(abi.encode("qa_user", Strings.toString(i)))));
            vm.deal(_users[i], 1 ether);
            uint16[] memory rawMetadata = new uint16[](1);
            // forge-lint: disable-next-line(unsafe-typecast)
            rawMetadata[0] = uint16(i + 1);
            bytes memory metadata = _buildPayMetadata(abi.encode(_users[i], rawMetadata));

            vm.prank(_users[i]);
            jbMultiTerminal().pay{value: 1 ether}(
                _projectId, JBConstants.NATIVE_TOKEN, 1 ether, _users[i], 0, "", metadata
            );

            DefifaDelegation[] memory dd = new DefifaDelegation[](1);
            dd[0] = DefifaDelegation({delegatee: _users[i], tierId: i + 1});
            vm.prank(_users[i]);
            _nft.setTierDelegatesTo(dd);

            vm.warp(_tsReader.timestamp() + 1);
        }

        // Verify the pot is 4 ETH.
        uint256 potBefore =
            jbMultiTerminal().STORE().balanceOf(address(jbMultiTerminal()), _projectId, JBConstants.NATIVE_TOKEN);
        assertEq(potBefore, 4 ether, "pot should be 4 ETH");

        // --- Advance to SCORING phase ---
        vm.warp(defifaData.start + 1);
        assertEq(uint256(deployer.currentGamePhaseOf(_projectId)), uint256(DefifaGamePhase.SCORING));

        // --- Build and ratify scorecard with tier 1 getting all weight ---
        DefifaTierCashOutWeight[] memory scorecards = new DefifaTierCashOutWeight[](nTiers);
        scorecards[0] = DefifaTierCashOutWeight({id: 1, cashOutWeight: _nft.TOTAL_CASHOUT_WEIGHT()});
        for (uint256 i = 1; i < nTiers; i++) {
            scorecards[i] = DefifaTierCashOutWeight({id: i + 1, cashOutWeight: 0});
        }

        uint256 _proposalId = _governor.submitScorecardFor(_gameId, scorecards);
        vm.warp(_tsReader.timestamp() + _governor.attestationStartTimeOf(_gameId) + 1);
        for (uint256 i = 0; i < _users.length; i++) {
            // Skip users whose BWA power is 0 (100% beneficiaries) — they cannot attest.
            vm.prank(_users[i]);
            try _governor.attestToScorecardFrom(_gameId, _proposalId) {} catch {}
        }
        vm.warp(_tsReader.timestamp() + _governor.attestationGracePeriodOf(_gameId) + 1);

        // --- Mock sendPayoutsOf on the terminal to revert (the actual failure point) ---
        vm.mockCallRevert(
            address(jbMultiTerminal()),
            abi.encodeWithSelector(JBMultiTerminal.sendPayoutsOf.selector),
            abi.encodeWithSignature("Error(string)", "simulated payout failure")
        );

        // Ratify — sendPayoutsOf fails but fulfillCommitmentsOf handles it gracefully.
        // CommitmentPayoutFailed is emitted and the final ruleset is still queued.
        vm.expectEmit(true, false, false, false);
        emit IDefifaDeployer.CommitmentPayoutFailed(_gameId, 0, "");
        _governor.ratifyScorecardFrom(_gameId, scorecards);

        // Clear mock so subsequent calls work.
        vm.clearMockedCalls();

        // Verify game is in COMPLETE phase (scorecard is set).
        assertEq(uint256(deployer.currentGamePhaseOf(_projectId)), uint256(DefifaGamePhase.COMPLETE));

        // Verify fulfilledCommitmentsOf returns 1 (sentinel).
        assertEq(deployer.fulfilledCommitmentsOf(_projectId), 1, "should be sentinel value 1");

        // --- Players CAN cash out immediately (no DoS) ---
        uint256 user0BalBefore = _users[0].balance;
        {
            uint256[] memory cashOutIds = new uint256[](1);
            cashOutIds[0] = _generateTokenId(1, 1);
            bytes memory cashOutMetadata = _buildCashOutMetadata(abi.encode(cashOutIds));

            vm.prank(_users[0]);
            JBMultiTerminal(address(jbMultiTerminal()))
                .cashOutTokensOf({
                    holder: _users[0],
                    projectId: _projectId,
                    cashOutCount: 0,
                    tokenToReclaim: JBConstants.NATIVE_TOKEN,
                    minTokensReclaimed: 0,
                    beneficiary: payable(_users[0]),
                    metadata: cashOutMetadata
                });
        }
        uint256 reclaimed = _users[0].balance - user0BalBefore;
        assertGt(reclaimed, 0, "winner should reclaim ETH immediately (no DoS)");

        // --- Calling fulfillCommitmentsOf again is a no-op (idempotent) ---
        deployer.fulfillCommitmentsOf(_projectId);
        assertEq(deployer.fulfilledCommitmentsOf(_projectId), 1, "should still be sentinel value 1");
    }

    // ----- Internal helpers ------

    function _getBasicLaunchData(uint8 nTiers) internal returns (DefifaLaunchProjectData memory) {
        DefifaTierParams[] memory tierParams = new DefifaTierParams[](nTiers);
        for (uint256 i = 0; i < nTiers; i++) {
            tierParams[i] = DefifaTierParams({
                reservedRate: 1001,
                reservedTokenBeneficiary: address(0),
                encodedIPFSUri: bytes32(0),
                shouldUseReservedTokenBeneficiaryAsDefault: false,
                name: "DEFIFA"
            });
        }

        return DefifaLaunchProjectData({
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
            scorecardTimeout: 0,
            timelockDuration: 0
        });
    }

    function _createProject(DefifaLaunchProjectData memory defifaLaunchData)
        internal
        returns (uint256 projectId, DefifaHook nft, DefifaGovernor _governor)
    {
        _governor = governor;
        (projectId) = deployer.launchGameWith(defifaLaunchData);
        JBRuleset memory _fc = jbRulesets().currentOf(projectId);
        if (_fc.dataHook() == address(0)) {
            (_fc,) = jbRulesets().latestQueuedOf(projectId);
        }
        nft = DefifaHook(_fc.dataHook());
    }

    function _generateTokenId(uint256 _tierId, uint256 _tokenNumber) internal pure returns (uint256) {
        return (_tierId * 1_000_000_000) + _tokenNumber;
    }

    function _buildPayMetadata(bytes memory metadata) internal view returns (bytes memory) {
        bytes[] memory data = new bytes[](1);
        data[0] = metadata;
        bytes4[] memory ids = new bytes4[](1);
        ids[0] = metadataHelper().getId("pay", address(hook));
        return metadataHelper().createMetadata(ids, data);
    }

    function _buildCashOutMetadata(bytes memory decodedData) internal view returns (bytes memory) {
        bytes4[] memory ids = new bytes4[](1);
        ids[0] = metadataHelper().getId("cashOut", address(hook));
        bytes[] memory datas = new bytes[](1);
        datas[0] = decodedData;
        return metadataHelper().createMetadata(ids, datas);
    }
}

// =============================================================================
// QA LAST-MILE TEST 2: GAME-ID PREDICTION RACE — STALE STORAGE ON REVERT
// =============================================================================

/// @title TestQAGameIdPredictionRace
/// @notice Tests the gameId prediction race condition in DefifaDeployer.launchGameWith.
/// @dev The deployer predicts gameId = PROJECTS().count() + 1, then clones and initializes a hook with that ID.
///      If another project is created between the count() read and launchProjectFor(), the actual ID differs and
///      the transaction reverts with DefifaDeployer_InvalidGameConfiguration. Because the clone uses
///      cloneDeterministic with msg.sender in the salt, a retry from the same caller succeeds with a new nonce.
///      No orphaned state remains after the revert.
contract TestQAGameIdPredictionRace is JBTest, TestBaseWorkflow {
    using JBRulesetMetadataResolver for JBRuleset;

    QATimestampReader private _tsReader = new QATimestampReader();

    address _protocolFeeProjectTokenAccount;
    address _defifaProjectTokenAccount;
    uint256 _protocolFeeProjectId;
    uint256 _defifaProjectId;

    DefifaDeployer deployer;
    DefifaHook hook;
    DefifaGovernor governor;

    address projectOwner = address(bytes20(keccak256("projectOwner")));

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
        _protocolFeeProjectTokenAccount =
            address(jbController().deployERC20For(_protocolFeeProjectId, "Bananapus", "NANA", bytes32(0)));

        _defifaProjectId =
            jbController().launchProjectFor(address(projectOwner), "", rulesetConfigs, terminalConfigs, "");
        vm.prank(projectOwner);
        _defifaProjectTokenAccount =
            address(jbController().deployERC20For(_defifaProjectId, "Defifa", "DEFIFA", bytes32(0)));

        hook = new DefifaHook(
            jbDirectory(), IERC20(address(_defifaProjectTokenAccount)), IERC20(_protocolFeeProjectTokenAccount)
        );
        governor = new DefifaGovernor(jbController(), address(this));
        JBAddressRegistry _registry = new JBAddressRegistry();
        DefifaTokenUriResolver _tokenUriResolver = new DefifaTokenUriResolver(ITypeface(address(0)));
        deployer = new DefifaDeployer(
            address(hook),
            _tokenUriResolver,
            governor,
            jbController(),
            _registry,
            _defifaProjectId,
            _protocolFeeProjectId
        );

        hook.transferOwnership(address(deployer));
        governor.transferOwnership(address(deployer));
    }

    /// @notice Proves the gameId prediction race: when count() returns a stale value (simulating a front-run
    ///         where another project is created between the deployer's count() read and launchProjectFor()),
    ///         the deployment reverts. The revert is caught by JBDirectory's own project ID validation
    ///         (JBDirectory_InvalidProjectIdInDirectory) before reaching the deployer's explicit check,
    ///         providing defense-in-depth. The caller can retry successfully with a fresh count.
    function test_gameIdPredictionRaceRevertsAndRetrySucceeds() public {
        // Record the current project count before the race.
        uint256 countBefore = jbController().PROJECTS().count();
        address projectsAddr = address(jbController().PROJECTS());

        // Build a valid game launch payload.
        DefifaLaunchProjectData memory defifaData = _getBasicLaunchData(4);

        // --- Simulate the front-run via mock: make count() return a stale (lower) value ---
        vm.mockCall(projectsAddr, abi.encodeWithSignature("count()"), abi.encode(countBefore - 1));

        // The deployer's launch reverts due to ID mismatch.
        vm.expectRevert();
        deployer.launchGameWith(defifaData);

        // Clear the mock so future calls get the real count.
        vm.clearMockedCalls();

        // --- Verify no orphaned state exists after the revert ---
        uint256 staleGameId = countBefore;

        assertEq(governor.attestationStartTimeOf(staleGameId), 0, "governor should not be initialized for stale gameId");
        assertEq(
            governor.attestationGracePeriodOf(staleGameId), 0, "governor grace period should be 0 for stale gameId"
        );
        assertEq(deployer.tokenOf(staleGameId), address(0), "no ops stored for stale gameId");
        assertEq(deployer.fulfilledCommitmentsOf(staleGameId), 0, "no commitments for stale gameId");

        // --- Retry: the caller can successfully launch with the correct gameId ---
        DefifaLaunchProjectData memory retryData = _getBasicLaunchData(4);

        uint256 countNow = jbController().PROJECTS().count();
        assertEq(countNow, countBefore, "count unchanged after reverted launch");

        uint256 retryGameId = deployer.launchGameWith(retryData);

        assertEq(retryGameId, countNow + 1, "retry should get the correct gameId");
        assertEq(
            uint256(deployer.currentGamePhaseOf(retryGameId)),
            uint256(DefifaGamePhase.COUNTDOWN),
            "game should be in COUNTDOWN phase"
        );
        assertGt(governor.attestationGracePeriodOf(retryGameId), 0, "governor should be initialized for retry gameId");
        assertEq(deployer.tokenOf(retryGameId), JBConstants.NATIVE_TOKEN, "ops stored correctly for retry gameId");
    }

    // ----- Internal helpers ------

    function _getBasicLaunchData(uint8 nTiers) internal returns (DefifaLaunchProjectData memory) {
        DefifaTierParams[] memory tierParams = new DefifaTierParams[](nTiers);
        for (uint256 i = 0; i < nTiers; i++) {
            tierParams[i] = DefifaTierParams({
                reservedRate: 1001,
                reservedTokenBeneficiary: address(0),
                encodedIPFSUri: bytes32(0),
                shouldUseReservedTokenBeneficiaryAsDefault: false,
                name: "DEFIFA"
            });
        }

        return DefifaLaunchProjectData({
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
            scorecardTimeout: 0,
            timelockDuration: 0
        });
    }
}
