// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {TestBaseWorkflow} from "@bananapus/core-v6/test/helpers/TestBaseWorkflow.sol";

import {DefifaGovernor} from "../src/DefifaGovernor.sol";
import {DefifaDeployer} from "../src/DefifaDeployer.sol";
import {DefifaHook} from "../src/DefifaHook.sol";
import {DefifaTokenUriResolver} from "../src/DefifaTokenUriResolver.sol";
import {JB721TiersHookStore} from "@bananapus/721-hook-v6/src/JB721TiersHookStore.sol";

import {JBTest} from "@bananapus/core-v6/test/helpers/JBTest.sol";
import {JBRulesetMetadataResolver} from "@bananapus/core-v6/src/libraries/JBRulesetMetadataResolver.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JBAddressRegistry} from "@bananapus/address-registry-v6/src/JBAddressRegistry.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ITypeface} from "lib/typeface/contracts/interfaces/ITypeface.sol";
import {IJB721TokenUriResolver} from "@bananapus/721-hook-v6/src/interfaces/IJB721TokenUriResolver.sol";
import {DefifaDelegation} from "../src/structs/DefifaDelegation.sol";
import {DefifaLaunchProjectData} from "../src/structs/DefifaLaunchProjectData.sol";
import {DefifaTierParams} from "../src/structs/DefifaTierParams.sol";
import {DefifaTierCashOutWeight} from "../src/structs/DefifaTierCashOutWeight.sol";
import {DefifaScorecardState} from "../src/enums/DefifaScorecardState.sol";
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
import {JBMultiTerminal} from "@bananapus/core-v6/src/JBMultiTerminal.sol";
import {mulDiv} from "@prb/math/src/Common.sol";

/// @dev Helper to read block.timestamp via an external call, bypassing the via-ir optimizer's timestamp caching.
contract GovHardenTSReader {
    function ts() external view returns (uint256) {
        return block.timestamp;
    }
}

/// @title DefifaGovernanceHardeningTest
/// @notice Tests for the four governance hardening features:
///         1. BWA (Benefit-Weighted Attestation) -- tier power reduced by benefit from scorecard.
///         2. HHI graduated quorum -- concentrated scorecards need higher quorum.
///         3. Post-quorum timelock -- QUEUED state between quorum met + grace period done and SUCCEEDED.
///         4. Attestation withdrawal -- revokeAttestationFrom during ACTIVE phase.
contract DefifaGovernanceHardeningTest is JBTest, TestBaseWorkflow {
    using JBRulesetMetadataResolver for JBRuleset;

    GovHardenTSReader private _tsReader = new GovHardenTSReader();

    address _protocolFeeProjectTokenAccount;
    address _defifaProjectTokenAccount;
    uint256 _protocolFeeProjectId;
    uint256 _defifaProjectId;
    uint256 _gameId = 3;

    DefifaDeployer deployer;
    DefifaHook hook;
    DefifaGovernor governor;
    address projectOwner = address(bytes20(keccak256("projectOwner")));

    uint256 _pid;
    DefifaHook _nft;
    DefifaGovernor _gov;
    address[] _users;

    function setUp() public virtual override {
        super.setUp();

        JBAccountingContext[] memory _tokens = new JBAccountingContext[](1);
        _tokens[0] = JBAccountingContext({token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: JBCurrencyIds.ETH});
        JBTerminalConfig[] memory tc = new JBTerminalConfig[](1);
        tc[0] = JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: _tokens});
        JBRulesetConfig[] memory rc = new JBRulesetConfig[](1);
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
                useTotalSurplusForCashOuts: false,
                useDataHookForPay: true,
                useDataHookForCashOut: true,
                dataHook: address(0),
                metadata: 0
            }),
            splitGroups: new JBSplitGroup[](0),
            fundAccessLimitGroups: new JBFundAccessLimitGroup[](0)
        });

        _protocolFeeProjectId = jbController().launchProjectFor(projectOwner, "", rc, tc, "");
        vm.prank(projectOwner);
        _protocolFeeProjectTokenAccount =
            address(jbController().deployERC20For(_protocolFeeProjectId, "Bananapus", "NANA", bytes32(0)));
        _defifaProjectId = jbController().launchProjectFor(projectOwner, "", rc, tc, "");
        vm.prank(projectOwner);
        _defifaProjectTokenAccount =
            address(jbController().deployERC20For(_defifaProjectId, "Defifa", "DEFIFA", bytes32(0)));

        hook =
            new DefifaHook(jbDirectory(), IERC20(_defifaProjectTokenAccount), IERC20(_protocolFeeProjectTokenAccount));
        governor = new DefifaGovernor(jbController(), address(this));
        deployer = new DefifaDeployer(
            address(hook),
            new DefifaTokenUriResolver(ITypeface(address(0))),
            governor,
            jbController(),
            new JBAddressRegistry(),
            _protocolFeeProjectId,
            _defifaProjectId
        );
        hook.transferOwnership(address(deployer));
        governor.transferOwnership(address(deployer));
    }

    // =========================================================================
    // BWA TESTS
    // =========================================================================

    /// @notice Test 1: A tier that receives 100% of the scorecard weight has 0 BWA attestation power.
    function test_bwa_beneficiaryZeroPower() external {
        _setupGame(4, 1 ether);
        _toScoring();

        // Submit scorecard: tier 1 gets 100% weight, tiers 2-4 get 0%.
        uint256 tw = _nft.TOTAL_CASHOUT_WEIGHT();
        DefifaTierCashOutWeight[] memory sc = _buildScorecard(4);
        sc[0].cashOutWeight = tw; // tier 1 = 100%
        // sc[1..3].cashOutWeight = 0 (default)

        uint256 scorecardId = _gov.submitScorecardFor(_gameId, sc);

        // Wait for attestation to begin.
        vm.warp(_tsReader.ts() + _gov.attestationStartTimeOf(_gameId) + 1);

        // Get the scorecard's snapshot time (attestationsBegin).
        // User 0 holds tier 1 (100% beneficiary) -- should have 0 BWA power for this scorecard.
        uint256 bwaPowerUser0 = _gov.getBWAAttestationWeight(_gameId, scorecardId, _users[0], uint48(_tsReader.ts()));
        assertEq(bwaPowerUser0, 0, "tier 1 holder (100% beneficiary) should have 0 BWA power");

        // Users 1-3 hold tiers 2-4 (0% beneficiary) -- should have full MAX_ATTESTATION_POWER_TIER.
        uint256 maxPower = _gov.MAX_ATTESTATION_POWER_TIER();
        for (uint256 i = 1; i < 4; i++) {
            uint256 bwaPower = _gov.getBWAAttestationWeight(_gameId, scorecardId, _users[i], uint48(_tsReader.ts()));
            assertEq(bwaPower, maxPower, "non-beneficiary tier holder should have full BWA power");
        }
    }

    /// @notice Test 2: Tiers with 0% weight retain full attestation power (mirrors getAttestationWeight).
    function test_bwa_nonBeneficiaryFullPower() external {
        _setupGame(4, 1 ether);
        _toScoring();

        // Submit scorecard: tier 1 gets 100%, rest get 0%.
        uint256 tw = _nft.TOTAL_CASHOUT_WEIGHT();
        DefifaTierCashOutWeight[] memory sc = _buildScorecard(4);
        sc[0].cashOutWeight = tw;

        uint256 scorecardId = _gov.submitScorecardFor(_gameId, sc);
        vm.warp(_tsReader.ts() + _gov.attestationStartTimeOf(_gameId) + 1);

        uint48 snapshotTime = uint48(_tsReader.ts());

        // For each non-beneficiary tier, BWA power should equal raw attestation power.
        for (uint256 i = 1; i < 4; i++) {
            uint256 rawPower = _gov.getAttestationWeight(_gameId, _users[i], snapshotTime);
            uint256 bwaPower = _gov.getBWAAttestationWeight(_gameId, scorecardId, _users[i], snapshotTime);
            assertEq(bwaPower, rawPower, "BWA power for 0%-weight tier should equal raw power");
        }
    }

    /// @notice Test 3: Partial BWA weight. Tier 1 gets 40%, tier 2 gets 60%.
    ///         Tier 1 holder should have 60% of MAX power, tier 2 holder should have 40% of MAX power.
    function test_bwa_partialWeight() external {
        _setupGame(2, 1 ether);
        _toScoring();

        uint256 tw = _nft.TOTAL_CASHOUT_WEIGHT(); // 1e18
        DefifaTierCashOutWeight[] memory sc = _buildScorecard(2);
        sc[0].cashOutWeight = (tw * 40) / 100; // tier 1 = 40% = 4e17
        sc[1].cashOutWeight = (tw * 60) / 100; // tier 2 = 60% = 6e17

        uint256 scorecardId = _gov.submitScorecardFor(_gameId, sc);
        vm.warp(_tsReader.ts() + _gov.attestationStartTimeOf(_gameId) + 1);

        uint48 snapshotTime = uint48(_tsReader.ts());
        uint256 maxPower = _gov.MAX_ATTESTATION_POWER_TIER();

        // Tier 1 holder: BWA multiplier = 1 - 0.4 = 0.6, so power = maxPower * 60%.
        uint256 bwaPowerTier1 = _gov.getBWAAttestationWeight(_gameId, scorecardId, _users[0], snapshotTime);
        uint256 expectedTier1 = mulDiv(maxPower, 6e17, 1e18); // 60% of max
        assertEq(bwaPowerTier1, expectedTier1, "tier 1 holder should have 60% of MAX power (1 - 0.4)");

        // Tier 2 holder: BWA multiplier = 1 - 0.6 = 0.4, so power = maxPower * 40%.
        uint256 bwaPowerTier2 = _gov.getBWAAttestationWeight(_gameId, scorecardId, _users[1], snapshotTime);
        uint256 expectedTier2 = mulDiv(maxPower, 4e17, 1e18); // 40% of max
        assertEq(bwaPowerTier2, expectedTier2, "tier 2 holder should have 40% of MAX power (1 - 0.6)");
    }

    // =========================================================================
    // HHI GRADUATED QUORUM TESTS
    // =========================================================================

    /// @notice Test 4: Equal 4-tier distribution yields minimal HHI penalty.
    ///         HHI = 4 * (0.25^2) = 0.25 = 25e16.
    ///         adjustmentFactor = 0.5 * 0.25 = 0.125 = 125e15.
    ///         adjustedQuorum = baseQuorum + baseQuorum * 125e15 / 1e18 = baseQuorum * 1.125.
    function test_hhi_equalDistribution_minimalPenalty() external {
        _setupGame(4, 1 ether);
        _toScoring();

        uint256 baseQuorum = _gov.quorum(_gameId);

        // Submit equal-weight scorecard.
        DefifaTierCashOutWeight[] memory sc = _evenScorecard(4);
        uint256 scorecardId = _gov.submitScorecardFor(_gameId, sc);

        // Compute expected HHI-adjusted quorum.
        // HHI = 4 * mulDiv(25e16, 25e16, 1e18) = 4 * 62_500_000_000_000_000 = 250_000_000_000_000_000 = 25e16
        uint256 hhi = 4 * mulDiv(25e16, 25e16, 1e18);
        assertEq(hhi, 25e16, "HHI for equal 4-tier should be 0.25 * 1e18");

        // adjustmentFactor = mulDiv(5e17, 25e16, 1e18) = 125e15
        uint256 adjustmentFactor = mulDiv(5e17, hhi, 1e18);
        assertEq(adjustmentFactor, 125e15, "adjustment factor should be 0.125 * 1e18");

        // adjustedQuorum = baseQuorum + mulDiv(baseQuorum, 125e15, 1e18)
        uint256 expectedAdjustedQuorum = baseQuorum + mulDiv(baseQuorum, adjustmentFactor, 1e18);

        // Read the quorumSnapshot stored in the scorecard (via attestationCountOf side-effect or state check).
        // We verify by checking that the right number of attestors is needed.
        // With BWA for equal scorecard, each tier holder gets 75% of MAX_ATTESTATION_POWER_TIER.
        // So 4 attestors provide: 4 * 0.75 * MAX = 3 * MAX = 3e9.
        // Base quorum = 4 * MAX / 2 = 2e9.
        // Expected adjusted quorum = 2e9 + 2e9 * 125e15 / 1e18 = 2e9 + 250_000_000 = 2_250_000_000.
        uint256 maxPower = _gov.MAX_ATTESTATION_POWER_TIER();
        assertEq(expectedAdjustedQuorum, (4 * maxPower) / 2 + mulDiv((4 * maxPower) / 2, 125e15, 1e18));

        // Verify quorum is 12.5% higher than base quorum.
        // expectedAdjustedQuorum / baseQuorum = 1.125, which means 12.5% increase.
        assertGt(expectedAdjustedQuorum, baseQuorum, "adjusted quorum must be greater than base quorum");
        // Verify approximately 12.5% increase.
        assertEq(
            expectedAdjustedQuorum - baseQuorum,
            mulDiv(baseQuorum, 125e15, 1e18),
            "penalty should be exactly 12.5% of base quorum"
        );

        // With 2 out of 4 users attesting (each contributing 75% of MAX via BWA):
        // totalWeight = 2 * 0.75 * MAX = 1.5 * MAX = 1_500_000_000
        // Since expectedAdjustedQuorum = 2_250_000_000, 2 attestors should NOT be enough.
        vm.warp(_tsReader.ts() + _gov.attestationStartTimeOf(_gameId) + 1);

        vm.prank(_users[0]);
        _gov.attestToScorecardFrom(_gameId, scorecardId);
        vm.prank(_users[1]);
        _gov.attestToScorecardFrom(_gameId, scorecardId);

        vm.warp(_tsReader.ts() + _gov.attestationGracePeriodOf(_gameId) + 1);

        DefifaScorecardState state = _gov.stateOf(_gameId, scorecardId);
        assertEq(
            uint256(state),
            uint256(DefifaScorecardState.ACTIVE),
            "2 attestors should NOT meet HHI-adjusted quorum for equal scorecard"
        );

        // With 3 out of 4 users attesting: totalWeight = 3 * 0.75 * MAX = 2.25 * MAX = 2_250_000_000.
        // This exactly meets the adjusted quorum.
        vm.prank(_users[2]);
        _gov.attestToScorecardFrom(_gameId, scorecardId);

        state = _gov.stateOf(_gameId, scorecardId);
        assertEq(
            uint256(state),
            uint256(DefifaScorecardState.SUCCEEDED),
            "3 attestors should meet HHI-adjusted quorum for equal scorecard"
        );
    }

    /// @notice Test 5: Winner-take-all scorecard has maximum HHI penalty.
    ///         HHI = 1 * (1.0^2) = 1.0 = 1e18.
    ///         adjustmentFactor = 0.5 * 1.0 = 0.5 = 5e17.
    ///         adjustedQuorum = baseQuorum + baseQuorum * 0.5 = baseQuorum * 1.5.
    function test_hhi_winnerTakeAll_maxPenalty() external {
        _setupGame(4, 1 ether);
        _toScoring();

        uint256 baseQuorum = _gov.quorum(_gameId);
        uint256 maxPower = _gov.MAX_ATTESTATION_POWER_TIER();

        // Submit winner-take-all scorecard: tier 1 gets 100%.
        uint256 tw = _nft.TOTAL_CASHOUT_WEIGHT();
        DefifaTierCashOutWeight[] memory sc = _buildScorecard(4);
        sc[0].cashOutWeight = tw; // tier 1 = 100%

        uint256 scorecardId = _gov.submitScorecardFor(_gameId, sc);

        // HHI = mulDiv(1e18, 1e18, 1e18) = 1e18.
        uint256 hhi = 1e18;
        uint256 adjustmentFactor = mulDiv(5e17, hhi, 1e18); // = 5e17
        uint256 expectedAdjustedQuorum = baseQuorum + mulDiv(baseQuorum, adjustmentFactor, 1e18);

        // baseQuorum = 2e9, adjustment = 2e9 * 0.5 = 1e9, adjusted = 3e9.
        assertEq(expectedAdjustedQuorum, (4 * maxPower) / 2 + (4 * maxPower) / 2 / 2);

        // Verify it is 50% higher than base quorum.
        assertEq(
            expectedAdjustedQuorum - baseQuorum,
            mulDiv(baseQuorum, 5e17, 1e18),
            "penalty should be exactly 50% of base quorum"
        );

        // With BWA for this scorecard:
        // - User 0 (tier 1, 100% weight): BWA power = 0.
        // - Users 1-3 (tiers 2-4, 0% weight): BWA power = MAX_ATTESTATION_POWER_TIER each.
        // So max possible attestation = 3 * MAX = 3e9 = exactly the adjusted quorum.
        vm.warp(_tsReader.ts() + _gov.attestationStartTimeOf(_gameId) + 1);

        // User 0 attests but contributes 0 due to BWA.
        vm.prank(_users[0]);
        _gov.attestToScorecardFrom(_gameId, scorecardId);

        // Users 1 and 2 attest (2 * MAX = 2e9 < 3e9).
        vm.prank(_users[1]);
        _gov.attestToScorecardFrom(_gameId, scorecardId);
        vm.prank(_users[2]);
        _gov.attestToScorecardFrom(_gameId, scorecardId);

        vm.warp(_tsReader.ts() + _gov.attestationGracePeriodOf(_gameId) + 1);

        DefifaScorecardState state = _gov.stateOf(_gameId, scorecardId);
        assertEq(
            uint256(state),
            uint256(DefifaScorecardState.ACTIVE),
            "2 non-beneficiary attestors should not meet 50%-penalized quorum"
        );

        // User 3 attests (3 * MAX = 3e9 = exactly adjusted quorum).
        vm.prank(_users[3]);
        _gov.attestToScorecardFrom(_gameId, scorecardId);

        state = _gov.stateOf(_gameId, scorecardId);
        assertEq(
            uint256(state),
            uint256(DefifaScorecardState.SUCCEEDED),
            "3 non-beneficiary attestors should meet 50%-penalized quorum"
        );
    }

    // =========================================================================
    // TIMELOCK TESTS
    // =========================================================================

    /// @notice Test 6: After quorum + grace period with timelock, state should be QUEUED.
    function test_timelock_queuedState() external {
        uint256 timelockDuration = 1 days;
        _setupGameWithTimelock(4, 1 ether, timelockDuration);
        _toScoring();

        // Submit even scorecard.
        DefifaTierCashOutWeight[] memory sc = _evenScorecard(4);
        uint256 scorecardId = _gov.submitScorecardFor(_gameId, sc);

        // All 4 users attest.
        vm.warp(_tsReader.ts() + _gov.attestationStartTimeOf(_gameId) + 1);
        for (uint256 i; i < 4; i++) {
            vm.prank(_users[i]);
            _gov.attestToScorecardFrom(_gameId, scorecardId);
        }

        // After grace period ends, state should be QUEUED (not SUCCEEDED) due to timelock.
        vm.warp(_tsReader.ts() + _gov.attestationGracePeriodOf(_gameId) + 1);

        DefifaScorecardState state = _gov.stateOf(_gameId, scorecardId);
        assertEq(uint256(state), uint256(DefifaScorecardState.QUEUED), "should be QUEUED when timelock is active");
    }

    /// @notice Test 7: Cannot ratify while in QUEUED state.
    function test_timelock_cannotRatifyDuringQueue() external {
        uint256 timelockDuration = 1 days;
        _setupGameWithTimelock(4, 1 ether, timelockDuration);
        _toScoring();

        DefifaTierCashOutWeight[] memory sc = _evenScorecard(4);
        uint256 scorecardId = _gov.submitScorecardFor(_gameId, sc);

        vm.warp(_tsReader.ts() + _gov.attestationStartTimeOf(_gameId) + 1);
        for (uint256 i; i < 4; i++) {
            vm.prank(_users[i]);
            _gov.attestToScorecardFrom(_gameId, scorecardId);
        }

        vm.warp(_tsReader.ts() + _gov.attestationGracePeriodOf(_gameId) + 1);

        // Verify we are in QUEUED state.
        assertEq(uint256(_gov.stateOf(_gameId, scorecardId)), uint256(DefifaScorecardState.QUEUED));

        // Attempting to ratify should revert because state is QUEUED, not SUCCEEDED.
        vm.expectRevert(DefifaGovernor.DefifaGovernor_NotAllowed.selector);
        _gov.ratifyScorecardFrom(_gameId, sc);
    }

    /// @notice Test 8: After timelock expires, state transitions to SUCCEEDED and ratification works.
    function test_timelock_succeededAfterExpiry() external {
        uint256 timelockDuration = 1 days;
        _setupGameWithTimelock(4, 1 ether, timelockDuration);
        _toScoring();

        DefifaTierCashOutWeight[] memory sc = _evenScorecard(4);
        uint256 scorecardId = _gov.submitScorecardFor(_gameId, sc);

        vm.warp(_tsReader.ts() + _gov.attestationStartTimeOf(_gameId) + 1);
        for (uint256 i; i < 4; i++) {
            vm.prank(_users[i]);
            _gov.attestToScorecardFrom(_gameId, scorecardId);
        }

        // Warp past grace period.
        vm.warp(_tsReader.ts() + _gov.attestationGracePeriodOf(_gameId) + 1);
        assertEq(
            uint256(_gov.stateOf(_gameId, scorecardId)),
            uint256(DefifaScorecardState.QUEUED),
            "should be QUEUED initially"
        );

        // Warp past timelock.
        vm.warp(_tsReader.ts() + timelockDuration + 1);

        DefifaScorecardState state = _gov.stateOf(_gameId, scorecardId);
        assertEq(uint256(state), uint256(DefifaScorecardState.SUCCEEDED), "should be SUCCEEDED after timelock expires");

        // Ratification should work.
        _gov.ratifyScorecardFrom(_gameId, sc);
        assertTrue(_nft.cashOutWeightIsSet(), "weights should be set after ratification");
    }

    /// @notice Test 9: With 0 timelock, state goes directly to SUCCEEDED (no QUEUED phase).
    function test_timelock_zeroTimelock_noQueue() external {
        _setupGame(4, 1 ether); // default timelockDuration = 0
        _toScoring();

        DefifaTierCashOutWeight[] memory sc = _evenScorecard(4);
        uint256 scorecardId = _gov.submitScorecardFor(_gameId, sc);

        // All 4 users attest.
        vm.warp(_tsReader.ts() + _gov.attestationStartTimeOf(_gameId) + 1);
        for (uint256 i; i < 4; i++) {
            vm.prank(_users[i]);
            _gov.attestToScorecardFrom(_gameId, scorecardId);
        }

        // After grace period, state should be SUCCEEDED (not QUEUED).
        vm.warp(_tsReader.ts() + _gov.attestationGracePeriodOf(_gameId) + 1);

        DefifaScorecardState state = _gov.stateOf(_gameId, scorecardId);
        assertEq(
            uint256(state), uint256(DefifaScorecardState.SUCCEEDED), "should go directly to SUCCEEDED with 0 timelock"
        );

        // Ratification should work immediately.
        _gov.ratifyScorecardFrom(_gameId, sc);
        assertTrue(_nft.cashOutWeightIsSet(), "weights should be set after ratification");
    }

    /// @notice Test 10: Two scorecards both reach SUCCEEDED after timelock. First ratified wins.
    function test_timelock_competingScorecards_firstRatifiedWins() external {
        uint256 timelockDuration = 1 days;
        _setupGameWithTimelock(4, 1 ether, timelockDuration);
        _toScoring();

        uint256 tw = _nft.TOTAL_CASHOUT_WEIGHT();

        // Scorecard A: tier 1 gets 50%, tier 2 gets 50%.
        DefifaTierCashOutWeight[] memory scA = _buildScorecard(4);
        scA[0].cashOutWeight = tw / 2;
        scA[1].cashOutWeight = tw / 2;

        // Scorecard B: equal distribution (25% each).
        DefifaTierCashOutWeight[] memory scB = _evenScorecard(4);

        uint256 proposalA = _gov.submitScorecardFor(_gameId, scA);
        uint256 proposalB = _gov.submitScorecardFor(_gameId, scB);

        vm.warp(_tsReader.ts() + _gov.attestationStartTimeOf(_gameId) + 1);

        // All 4 users attest to both scorecards.
        for (uint256 i; i < 4; i++) {
            vm.prank(_users[i]);
            _gov.attestToScorecardFrom(_gameId, proposalA);
        }
        for (uint256 i; i < 4; i++) {
            vm.prank(_users[i]);
            _gov.attestToScorecardFrom(_gameId, proposalB);
        }

        // Warp past grace period + timelock.
        vm.warp(_tsReader.ts() + _gov.attestationGracePeriodOf(_gameId) + timelockDuration + 2);

        // Both should be SUCCEEDED.
        assertEq(
            uint256(_gov.stateOf(_gameId, proposalA)), uint256(DefifaScorecardState.SUCCEEDED), "A should be SUCCEEDED"
        );
        assertEq(
            uint256(_gov.stateOf(_gameId, proposalB)), uint256(DefifaScorecardState.SUCCEEDED), "B should be SUCCEEDED"
        );

        // Ratify scorecard A first.
        _gov.ratifyScorecardFrom(_gameId, scA);

        // After ratification, A is RATIFIED, B is DEFEATED.
        assertEq(
            uint256(_gov.stateOf(_gameId, proposalA)), uint256(DefifaScorecardState.RATIFIED), "A should be RATIFIED"
        );
        assertEq(
            uint256(_gov.stateOf(_gameId, proposalB)), uint256(DefifaScorecardState.DEFEATED), "B should be DEFEATED"
        );
    }

    // =========================================================================
    // ATTESTATION WITHDRAWAL TESTS
    // =========================================================================

    /// @notice Test 11: Revoke attestation during ACTIVE phase succeeds.
    function test_revoke_duringActive_succeeds() external {
        _setupGame(4, 1 ether);
        _toScoring();

        DefifaTierCashOutWeight[] memory sc = _evenScorecard(4);
        uint256 scorecardId = _gov.submitScorecardFor(_gameId, sc);

        vm.warp(_tsReader.ts() + _gov.attestationStartTimeOf(_gameId) + 1);

        // User 0 attests.
        vm.prank(_users[0]);
        _gov.attestToScorecardFrom(_gameId, scorecardId);
        assertTrue(_gov.hasAttestedTo(_gameId, scorecardId, _users[0]), "should be attested after attestation");

        // User 0 revokes during ACTIVE phase.
        vm.prank(_users[0]);
        _gov.revokeAttestationFrom(_gameId, scorecardId);

        // hasAttestedTo should return false after revocation.
        assertFalse(_gov.hasAttestedTo(_gameId, scorecardId, _users[0]), "should not be attested after revocation");
    }

    /// @notice Test 12: Revoke during QUEUED state reverts.
    function test_revoke_duringQueued_reverts() external {
        uint256 timelockDuration = 1 days;
        _setupGameWithTimelock(4, 1 ether, timelockDuration);
        _toScoring();

        DefifaTierCashOutWeight[] memory sc = _evenScorecard(4);
        uint256 scorecardId = _gov.submitScorecardFor(_gameId, sc);

        vm.warp(_tsReader.ts() + _gov.attestationStartTimeOf(_gameId) + 1);

        // All 4 users attest to reach quorum.
        for (uint256 i; i < 4; i++) {
            vm.prank(_users[i]);
            _gov.attestToScorecardFrom(_gameId, scorecardId);
        }

        // Warp past grace period to enter QUEUED state.
        vm.warp(_tsReader.ts() + _gov.attestationGracePeriodOf(_gameId) + 1);
        assertEq(uint256(_gov.stateOf(_gameId, scorecardId)), uint256(DefifaScorecardState.QUEUED), "should be QUEUED");

        // Try to revoke -- should revert because not in ACTIVE state.
        vm.prank(_users[0]);
        vm.expectRevert(DefifaGovernor.DefifaGovernor_NotAllowed.selector);
        _gov.revokeAttestationFrom(_gameId, scorecardId);
    }

    /// @notice Test 13: Revoke without having attested reverts.
    function test_revoke_notAttested_reverts() external {
        _setupGame(4, 1 ether);
        _toScoring();

        DefifaTierCashOutWeight[] memory sc = _evenScorecard(4);
        uint256 scorecardId = _gov.submitScorecardFor(_gameId, sc);

        vm.warp(_tsReader.ts() + _gov.attestationStartTimeOf(_gameId) + 1);

        // User 0 has NOT attested. Try to revoke.
        vm.prank(_users[0]);
        vm.expectRevert(DefifaGovernor.DefifaGovernor_NotAttested.selector);
        _gov.revokeAttestationFrom(_gameId, scorecardId);
    }

    /// @notice Test 14: Revoke subtracts the correct BWA-adjusted weight.
    function test_revoke_subtractsCorrectWeight() external {
        _setupGame(4, 1 ether);
        _toScoring();

        DefifaTierCashOutWeight[] memory sc = _evenScorecard(4);
        uint256 scorecardId = _gov.submitScorecardFor(_gameId, sc);

        vm.warp(_tsReader.ts() + _gov.attestationStartTimeOf(_gameId) + 1);

        // Record count before attestation.
        uint256 countBefore = _gov.attestationCountOf(_gameId, scorecardId);

        // User 0 attests.
        vm.prank(_users[0]);
        uint256 weight = _gov.attestToScorecardFrom(_gameId, scorecardId);
        assertGt(weight, 0, "attestation weight should be positive");

        // Verify count increased by weight.
        uint256 countAfter = _gov.attestationCountOf(_gameId, scorecardId);
        assertEq(countAfter, countBefore + weight, "count should increase by weight after attestation");

        // User 0 revokes.
        vm.prank(_users[0]);
        _gov.revokeAttestationFrom(_gameId, scorecardId);

        // Verify count decreased back to original.
        uint256 countAfterRevoke = _gov.attestationCountOf(_gameId, scorecardId);
        assertEq(countAfterRevoke, countBefore, "count should return to original after revocation");
    }

    /// @notice Test 15: Revocation drops below quorum, causing state to remain ACTIVE after grace period.
    function test_revoke_dropsBelow_quorum_backToActive() external {
        _setupGame(4, 1 ether);
        _toScoring();

        DefifaTierCashOutWeight[] memory sc = _evenScorecard(4);
        uint256 scorecardId = _gov.submitScorecardFor(_gameId, sc);

        vm.warp(_tsReader.ts() + _gov.attestationStartTimeOf(_gameId) + 1);

        // All 4 users attest (this reaches quorum).
        for (uint256 i; i < 4; i++) {
            vm.prank(_users[i]);
            _gov.attestToScorecardFrom(_gameId, scorecardId);
        }

        // Before grace period ends, user 3 revokes.
        // The scorecard is still in ACTIVE state (grace period not done yet).
        assertEq(
            uint256(_gov.stateOf(_gameId, scorecardId)),
            uint256(DefifaScorecardState.ACTIVE),
            "should be ACTIVE during grace period"
        );

        vm.prank(_users[3]);
        _gov.revokeAttestationFrom(_gameId, scorecardId);

        // Also revoke user 2 so we drop well below quorum.
        vm.prank(_users[2]);
        _gov.revokeAttestationFrom(_gameId, scorecardId);

        // After grace period, quorum should NOT be met because 2 users revoked.
        vm.warp(_tsReader.ts() + _gov.attestationGracePeriodOf(_gameId) + 1);

        DefifaScorecardState state = _gov.stateOf(_gameId, scorecardId);
        assertEq(
            uint256(state),
            uint256(DefifaScorecardState.ACTIVE),
            "should remain ACTIVE after revocations drop below quorum"
        );
    }

    // =========================================================================
    // INTEGRATION TEST
    // =========================================================================

    /// @notice Test 16: Full flow exercising all four hardening features.
    ///         Submit scorecard -> BWA attestation -> HHI quorum adjustment -> timelock QUEUED -> ratification.
    function test_fullFlow_allFeatures() external {
        uint256 timelockDuration = 2 hours;
        _setupGameWithTimelock(4, 1 ether, timelockDuration);
        _toScoring();

        uint256 tw = _nft.TOTAL_CASHOUT_WEIGHT();
        uint256 maxPower = _gov.MAX_ATTESTATION_POWER_TIER();
        uint256 baseQuorum = _gov.quorum(_gameId);

        // --- Submit a somewhat concentrated scorecard ---
        // tier 1: 50%, tier 2: 30%, tier 3: 15%, tier 4: 5%.
        DefifaTierCashOutWeight[] memory sc = _buildScorecard(4);
        sc[0].cashOutWeight = (tw * 50) / 100;
        sc[1].cashOutWeight = (tw * 30) / 100;
        sc[2].cashOutWeight = (tw * 15) / 100;
        sc[3].cashOutWeight = (tw * 5) / 100;

        uint256 scorecardId = _gov.submitScorecardFor(_gameId, sc);

        // --- Verify HHI adjusted quorum is higher than base ---
        // HHI = mulDiv(5e17,5e17,1e18) + mulDiv(3e17,3e17,1e18) + mulDiv(15e16,15e16,1e18) + mulDiv(5e16,5e16,1e18)
        //      = 25e16 + 9e16 + 225e14 + 25e14 = 25e16 + 9e16 + 2.25e16 + 0.25e16 = 365e15
        uint256 hhi =
            mulDiv(5e17, 5e17, 1e18) + mulDiv(3e17, 3e17, 1e18) + mulDiv(15e16, 15e16, 1e18) + mulDiv(5e16, 5e16, 1e18);
        uint256 adjustmentFactor = mulDiv(5e17, hhi, 1e18);
        uint256 expectedQuorum = baseQuorum + mulDiv(baseQuorum, adjustmentFactor, 1e18);
        assertGt(expectedQuorum, baseQuorum, "HHI-adjusted quorum should be higher than base");

        // --- Verify BWA reduces beneficiary power ---
        vm.warp(_tsReader.ts() + _gov.attestationStartTimeOf(_gameId) + 1);
        uint48 snapshotTime = uint48(_tsReader.ts());

        // User 0 (tier 1, 50% weight) should have reduced BWA power.
        uint256 rawPowerUser0 = _gov.getAttestationWeight(_gameId, _users[0], snapshotTime);
        uint256 bwaPowerUser0 = _gov.getBWAAttestationWeight(_gameId, scorecardId, _users[0], snapshotTime);
        assertLt(bwaPowerUser0, rawPowerUser0, "BWA should reduce beneficiary's attestation power");

        // User 0's expected BWA: rawPower * (1 - 0.5) = rawPower * 0.5.
        uint256 expectedBwaPowerUser0 = mulDiv(rawPowerUser0, 5e17, 1e18);
        assertEq(bwaPowerUser0, expectedBwaPowerUser0, "tier 1 holder BWA should be 50% of raw power");

        // --- Attest: all 4 users ---
        for (uint256 i; i < 4; i++) {
            vm.prank(_users[i]);
            _gov.attestToScorecardFrom(_gameId, scorecardId);
        }

        // --- Verify attestation withdrawal ---
        // User 3 revokes during ACTIVE, then re-attests.
        vm.prank(_users[3]);
        _gov.revokeAttestationFrom(_gameId, scorecardId);
        assertFalse(_gov.hasAttestedTo(_gameId, scorecardId, _users[3]), "user 3 should be un-attested after revoke");

        // Re-attest.
        vm.prank(_users[3]);
        _gov.attestToScorecardFrom(_gameId, scorecardId);
        assertTrue(_gov.hasAttestedTo(_gameId, scorecardId, _users[3]), "user 3 should be attested after re-attest");

        // --- After grace period: QUEUED (timelock active) ---
        vm.warp(_tsReader.ts() + _gov.attestationGracePeriodOf(_gameId) + 1);

        DefifaScorecardState state = _gov.stateOf(_gameId, scorecardId);
        assertEq(
            uint256(state), uint256(DefifaScorecardState.QUEUED), "should be QUEUED after grace period with timelock"
        );

        // --- Cannot ratify during QUEUED ---
        vm.expectRevert(DefifaGovernor.DefifaGovernor_NotAllowed.selector);
        _gov.ratifyScorecardFrom(_gameId, sc);

        // --- After timelock expires: SUCCEEDED ---
        vm.warp(_tsReader.ts() + timelockDuration + 1);

        state = _gov.stateOf(_gameId, scorecardId);
        assertEq(uint256(state), uint256(DefifaScorecardState.SUCCEEDED), "should be SUCCEEDED after timelock expires");

        // --- Ratify ---
        _gov.ratifyScorecardFrom(_gameId, sc);
        assertTrue(_nft.cashOutWeightIsSet(), "weights should be set after ratification");
        assertEq(
            uint256(_gov.stateOf(_gameId, scorecardId)), uint256(DefifaScorecardState.RATIFIED), "should be RATIFIED"
        );
    }

    // =========================================================================
    // SETUP + PRIMITIVE HELPERS
    // =========================================================================

    function _setupGame(uint8 nTiers, uint256 tierPrice) internal {
        DefifaLaunchProjectData memory d = _launchData(nTiers, tierPrice);
        (_pid, _nft, _gov) = _launch(d);
        vm.warp(d.start - d.mintPeriodDuration - d.refundPeriodDuration);
        _users = new address[](nTiers);
        for (uint256 i; i < nTiers; i++) {
            _users[i] = _addr(i);
            _mint(_users[i], i + 1, tierPrice);
            _delegateSelf(_users[i], i + 1);
            vm.warp(block.timestamp + 1);
        }
    }

    function _setupGameWithTimelock(uint8 nTiers, uint256 tierPrice, uint256 timelockDuration) internal {
        DefifaLaunchProjectData memory d = _launchDataWithTimelock(nTiers, tierPrice, timelockDuration);
        (_pid, _nft, _gov) = _launch(d);
        vm.warp(d.start - d.mintPeriodDuration - d.refundPeriodDuration);
        _users = new address[](nTiers);
        for (uint256 i; i < nTiers; i++) {
            _users[i] = _addr(i);
            _mint(_users[i], i + 1, tierPrice);
            _delegateSelf(_users[i], i + 1);
            vm.warp(block.timestamp + 1);
        }
    }

    function _toScoring() internal {
        vm.warp(_tsReader.ts() + 3 days + 1);
    }

    function _launchData(uint8 n, uint256 tierPrice) internal returns (DefifaLaunchProjectData memory) {
        return _launchDataWithTimelock(n, tierPrice, 0);
    }

    function _launchDataWithTimelock(
        uint8 n,
        uint256 tierPrice,
        uint256 timelockDuration
    )
        internal
        returns (DefifaLaunchProjectData memory)
    {
        DefifaTierParams[] memory tp = new DefifaTierParams[](n);
        for (uint256 i; i < n; i++) {
            tp[i] = DefifaTierParams({
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
            token: JBAccountingContext({token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: JBCurrencyIds.ETH}),
            mintPeriodDuration: 1 days,
            start: uint48(block.timestamp + 3 days),
            refundPeriodDuration: 1 days,
            store: new JB721TiersHookStore(),
            splits: new JBSplit[](0),
            attestationStartTime: 0,
            attestationGracePeriod: 100_381,
            defaultAttestationDelegate: address(0),
            // forge-lint: disable-next-line(unsafe-typecast)
            tierPrice: uint104(tierPrice),
            tiers: tp,
            defaultTokenUriResolver: IJB721TokenUriResolver(address(0)),
            terminal: jbMultiTerminal(),
            minParticipation: 0,
            scorecardTimeout: 0,
            timelockDuration: timelockDuration
        });
    }

    function _launch(DefifaLaunchProjectData memory d) internal returns (uint256 p, DefifaHook n, DefifaGovernor g) {
        g = governor;
        p = deployer.launchGameWith(d);
        JBRuleset memory fc = jbRulesets().currentOf(p);
        if (fc.dataHook() == address(0)) (fc,) = jbRulesets().latestQueuedOf(p);
        n = DefifaHook(fc.dataHook());
    }

    function _addr(uint256 i) internal pure returns (address) {
        return address(bytes20(keccak256(abi.encode("govharden", i))));
    }

    function _mint(address user, uint256 tid, uint256 amt) internal {
        vm.deal(user, amt);
        uint16[] memory m = new uint16[](1);
        // forge-lint: disable-next-line(unsafe-typecast)
        m[0] = uint16(tid);
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encode(user, m);
        bytes4[] memory ids = new bytes4[](1);
        ids[0] = metadataHelper().getId("pay", address(hook));
        // Build metadata before vm.prank so the external call to createMetadata doesn't consume the prank.
        bytes memory metadata = metadataHelper().createMetadata(ids, data);
        vm.prank(user);
        jbMultiTerminal().pay{value: amt}(_pid, JBConstants.NATIVE_TOKEN, amt, user, 0, "", metadata);
    }

    function _delegateSelf(address user, uint256 tid) internal {
        DefifaDelegation[] memory dd = new DefifaDelegation[](1);
        dd[0] = DefifaDelegation({delegatee: user, tierId: tid});
        vm.prank(user);
        _nft.setTierDelegatesTo(dd);
    }

    function _buildScorecard(uint256 n) internal pure returns (DefifaTierCashOutWeight[] memory sc) {
        sc = new DefifaTierCashOutWeight[](n);
        for (uint256 i; i < n; i++) {
            sc[i].id = i + 1;
        }
    }

    function _evenScorecard(uint256 n) internal view returns (DefifaTierCashOutWeight[] memory sc) {
        sc = _buildScorecard(n);
        uint256 tw = _nft.TOTAL_CASHOUT_WEIGHT();
        for (uint256 i; i < n; i++) {
            sc[i].cashOutWeight = tw / n;
        }
    }
}
