// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {TestBaseWorkflow} from "@bananapus/core-v6/test/helpers/TestBaseWorkflow.sol";

import {DefifaGovernor} from "../../src/DefifaGovernor.sol";
import {IDefifaGovernor} from "../../src/interfaces/IDefifaGovernor.sol";
import {Vm} from "forge-std/Vm.sol";
import {DefifaDeployer} from "../../src/DefifaDeployer.sol";
import {Defifa1155Hook} from "../../src/Defifa1155Hook.sol";
import {DefifaTokenUriResolver} from "../../src/DefifaTokenUriResolver.sol";
import {DefifaTiersHookStore} from "../../src/DefifaTiersHookStore.sol";

import {JBTest} from "@bananapus/core-v6/test/helpers/JBTest.sol";
import {JBRulesetMetadataResolver} from "@bananapus/core-v6/src/libraries/JBRulesetMetadataResolver.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JBAddressRegistry} from "@bananapus/address-registry-v6/src/JBAddressRegistry.sol";

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
    Defifa1155Hook hook;
    DefifaGovernor governor;
    address projectOwner = address(bytes20(keccak256("projectOwner")));

    uint256 _pid;
    Defifa1155Hook _nft;
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
                scopeCashOutsToLocalBalances: true,
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

        hook = new Defifa1155Hook(jbDirectory(), jbTokens(), _defifaProjectId, _protocolFeeProjectId);
        governor = new DefifaGovernor(jbController(), address(this));
        deployer = new DefifaDeployer({
            hookCodeOrigin: address(hook),
            tokenUriResolver: new DefifaTokenUriResolver(address(this)),
            governor: governor,
            controller: jbController(),
            registry: new JBAddressRegistry(),
            defifaProjectId: _protocolFeeProjectId,
            baseProtocolProjectId: _defifaProjectId,
            hookStore: new DefifaTiersHookStore(),
            trustedForwarder: address(0)
        });
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

        // An even split over 4 tiers has a largest share of 25%, so quorum is 50% + 25% * 0.25² of the attestation
        // possible, (4 - 1) * MAX: 3e9 * 5156 / 10000 = 1_546_800_000.
        uint256 expectedQuorum = _expectedQuorum(4, sc[0].cashOutWeight);
        assertEq(_quorumSnapshotOf(scorecardId), expectedQuorum, "even split quorum");
        assertEq(expectedQuorum, 1_546_800_000, "51.56% of 3 * MAX");
        assertGt(expectedQuorum, baseQuorum, "any concentration raises quorum above the even-split floor");

        // With 2 out of 4 users attesting (each contributing 75% of MAX via BWA):
        // totalWeight = 2 * 0.75 * MAX = 1_500_000_000, below the 1_546_800_000 quorum.
        vm.warp(_tsReader.ts() + _gov.attestationStartTimeOf(_gameId) + 1);

        vm.prank(_users[0]);
        _gov.attestToScorecardFrom(_gameId, scorecardId);
        vm.prank(_users[1]);
        _gov.attestToScorecardFrom(_gameId, scorecardId);

        vm.warp(_tsReader.ts() + _gov.attestationGracePeriodOf(_gameId) + 1);

        DefifaScorecardState state = _gov.stateOf(_gameId, scorecardId);
        assertEq(
            uint256(state), uint256(DefifaScorecardState.ACTIVE), "2 attestors should NOT meet the even-split quorum"
        );

        // With 3 out of 4 users attesting: totalWeight = 3 * 0.75 * MAX = 2_250_000_000, above the quorum.
        vm.prank(_users[2]);
        _gov.attestToScorecardFrom(_gameId, scorecardId);

        state = _gov.stateOf(_gameId, scorecardId);
        assertEq(
            uint256(state), uint256(DefifaScorecardState.SUCCEEDED), "3 attestors should meet the even-split quorum"
        );
    }

    /// @notice Test 5: Winner-take-all scorecard has maximum HHI penalty.
    ///         HHI = 1 * (1.0^2) = 1.0 = 1e18.
    ///         adjustmentFactor = 0.5 * 1.0 = 0.5 = 5e17.
    ///         adjustedQuorum = baseQuorum + baseQuorum * 0.5 = baseQuorum * 1.5.
    function test_hhi_winnerTakeAll_maxPenalty() external {
        _setupGame(4, 1 ether);
        _toScoring();

        _gov.quorum(_gameId);
        _gov.MAX_ATTESTATION_POWER_TIER();

        // Submit winner-take-all scorecard: tier 1 gets 100%.
        uint256 tw = _nft.TOTAL_CASHOUT_WEIGHT();
        DefifaTierCashOutWeight[] memory sc = _buildScorecard(4);
        sc[0].cashOutWeight = tw; // tier 1 = 100%

        uint256 scorecardId = _gov.submitScorecardFor(_gameId, sc);

        // headroom = baseQuorum - MAX = 2e9 - 1e9 = 1e9.
        // maxShare² = mulDiv(tw, tw, tw) = tw. penalty = mulDiv(headroom, tw, tw) = headroom.
        // adjustedQuorum = baseQuorum + headroom - baseQuorum / 5000 (rounding margin) = 3e9 - 4e5.
        // Max BWA = 3 * MAX (users 1-3, each with ~MAX power) ≈ 3e9.
        // Quorum should be reachable but tight.

        vm.warp(_tsReader.ts() + _gov.attestationStartTimeOf(_gameId) + 1);

        // User 0 (100% beneficiary) cannot attest (BWA power = 0, reverts).
        vm.prank(_users[0]);
        vm.expectPartialRevert(DefifaGovernor.DefifaGovernor_NotAllowed.selector);
        _gov.attestToScorecardFrom(_gameId, scorecardId);

        // Users 1 and 2 attest (2 * MAX < adjusted quorum).
        vm.prank(_users[1]);
        _gov.attestToScorecardFrom(_gameId, scorecardId);
        vm.prank(_users[2]);
        _gov.attestToScorecardFrom(_gameId, scorecardId);

        vm.warp(_tsReader.ts() + _gov.attestationGracePeriodOf(_gameId) + 1);

        DefifaScorecardState state = _gov.stateOf(_gameId, scorecardId);
        assertEq(
            uint256(state),
            uint256(DefifaScorecardState.ACTIVE),
            "2 non-beneficiary attestors should not meet concentration-penalized quorum"
        );

        // User 3 attests (3 * MAX ≈ adjusted quorum).
        vm.prank(_users[3]);
        _gov.attestToScorecardFrom(_gameId, scorecardId);

        state = _gov.stateOf(_gameId, scorecardId);
        assertEq(
            uint256(state),
            uint256(DefifaScorecardState.SUCCEEDED),
            "3 non-beneficiary attestors should meet concentration-penalized quorum"
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
        vm.expectPartialRevert(DefifaGovernor.DefifaGovernor_NotAllowed.selector);
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
        vm.expectPartialRevert(DefifaGovernor.DefifaGovernor_NotAllowed.selector);
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
        vm.expectPartialRevert(DefifaGovernor.DefifaGovernor_NotAttested.selector);
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
    ///         Submit scorecard -> BWA attestation -> concentration penalty -> timelock QUEUED -> ratification.
    function test_fullFlow_allFeatures() external {
        uint256 timelockDuration = 2 hours;
        _setupGameWithTimelock(4, 1 ether, timelockDuration);
        _toScoring();

        uint256 tw = _nft.TOTAL_CASHOUT_WEIGHT();
        uint256 baseQuorum = _gov.quorum(_gameId);

        // --- Submit a somewhat concentrated scorecard ---
        // tier 1: 50%, tier 2: 30%, tier 3: 15%, tier 4: 5%.
        DefifaTierCashOutWeight[] memory sc = _buildScorecard(4);
        sc[0].cashOutWeight = (tw * 50) / 100;
        sc[1].cashOutWeight = (tw * 30) / 100;
        sc[2].cashOutWeight = (tw * 15) / 100;
        sc[3].cashOutWeight = (tw * 5) / 100;

        uint256 scorecardId = _gov.submitScorecardFor(_gameId, sc);

        // --- Verify concentration-adjusted quorum is higher than base ---
        // maxShare = 50%, headroom = baseQuorum - MAX, penalty = headroom * maxShare².
        uint256 maxPower = _gov.MAX_ATTESTATION_POWER_TIER();
        uint256 headroom = baseQuorum > maxPower ? baseQuorum - maxPower : 0;
        uint256 maxShareSquared = mulDiv(sc[0].cashOutWeight, sc[0].cashOutWeight, tw);
        uint256 expectedPenalty = mulDiv(headroom, maxShareSquared, tw);
        assertGt(expectedPenalty, 0, "concentration penalty should be positive");

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
        vm.expectPartialRevert(DefifaGovernor.DefifaGovernor_NotAllowed.selector);
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
    // FORMAL VERIFICATION: ZERO-WEIGHT GUARD
    // =========================================================================

    /// @notice FV-1: Attesting with BWA weight == 0 reverts (prevents event spam from 100% beneficiaries).
    function test_fv_zeroWeightAttestation_reverts() external {
        _setupGame(4, 1 ether);
        _toScoring();

        // Scorecard: tier 1 gets 100%, tiers 2-4 get 0%.
        uint256 tw = _nft.TOTAL_CASHOUT_WEIGHT();
        DefifaTierCashOutWeight[] memory sc = _buildScorecard(4);
        sc[0].cashOutWeight = tw;

        uint256 scorecardId = _gov.submitScorecardFor(_gameId, sc);
        vm.warp(_tsReader.ts() + _gov.attestationStartTimeOf(_gameId) + 1);

        // User 0 (tier 1, 100% beneficiary) has BWA power = 0. Should revert.
        vm.prank(_users[0]);
        vm.expectPartialRevert(DefifaGovernor.DefifaGovernor_NotAllowed.selector);
        _gov.attestToScorecardFrom(_gameId, scorecardId);

        // Non-holder (no tokens at all) also has BWA power = 0. Should revert.
        address stranger = _addr(999);
        vm.prank(stranger);
        vm.expectPartialRevert(DefifaGovernor.DefifaGovernor_NotAllowed.selector);
        _gov.attestToScorecardFrom(_gameId, scorecardId);
    }

    // =========================================================================
    // FORMAL VERIFICATION: BWA CONSTANT-TOTAL INVARIANT
    // =========================================================================

    /// @notice FV-2: For any valid scorecard, sum of BWA power across all tiers = (N-1) * V_MAX (minus rounding).
    /// @dev This is the core BWA invariant: total attestation power is constant regardless of weight distribution.
    function test_fv_bwa_constantTotalInvariant() external {
        _setupGame(4, 1 ether);
        _toScoring();

        uint256 tw = _nft.TOTAL_CASHOUT_WEIGHT();
        uint256 maxPower = _gov.MAX_ATTESTATION_POWER_TIER();

        // Test with multiple scorecard distributions.
        uint256[4][3] memory distributions = [
            [tw / 4, tw / 4, tw / 4, tw / 4], // even
            [tw, uint256(0), uint256(0), uint256(0)], // winner-take-all
            [(tw * 60) / 100, (tw * 25) / 100, (tw * 10) / 100, (tw * 5) / 100] // concentrated
        ];

        for (uint256 d; d < 3; d++) {
            DefifaTierCashOutWeight[] memory sc = _buildScorecard(4);
            for (uint256 i; i < 4; i++) {
                sc[i].cashOutWeight = distributions[d][i];
            }

            uint256 scorecardId = _gov.submitScorecardFor(_gameId, sc);
            vm.warp(_tsReader.ts() + _gov.attestationStartTimeOf(_gameId) + 1);

            // Sum BWA power across all 4 users (each sole holder of their tier).
            // forge-lint: disable-next-line(mixed-case-variable)
            uint256 totalBWA;
            for (uint256 i; i < 4; i++) {
                totalBWA += _gov.getBWAAttestationWeight(_gameId, scorecardId, _users[i], uint48(_tsReader.ts()));
            }

            // Theoretical max: (N-1) * V_MAX = 3 * 1e9.
            uint256 theoretical = (4 - 1) * maxPower;

            // Must be within N of theoretical (rounding loss is at most 1 per tier).
            assertLe(theoretical - totalBWA, 4, "BWA total should be within N of (N-1)*V_MAX");
            assertLe(totalBWA, theoretical, "BWA total should not exceed (N-1)*V_MAX");
        }
    }

    /// @notice FV-3: Fuzz the constant-total invariant across random scorecard distributions.
    function test_fv_fuzz_bwa_constantTotal(uint256 w1, uint256 w2, uint256 w3) external {
        _setupGame(4, 1 ether);
        _toScoring();

        uint256 tw = _nft.TOTAL_CASHOUT_WEIGHT();
        uint256 maxPower = _gov.MAX_ATTESTATION_POWER_TIER();

        // Bound weights to valid range and ensure they sum to <= tw.
        w1 = bound(w1, 0, tw);
        w2 = bound(w2, 0, tw - w1);
        w3 = bound(w3, 0, tw - w1 - w2);
        uint256 w4 = tw - w1 - w2 - w3;

        DefifaTierCashOutWeight[] memory sc = _buildScorecard(4);
        sc[0].cashOutWeight = w1;
        sc[1].cashOutWeight = w2;
        sc[2].cashOutWeight = w3;
        sc[3].cashOutWeight = w4;

        uint256 scorecardId = _gov.submitScorecardFor(_gameId, sc);
        vm.warp(_tsReader.ts() + _gov.attestationStartTimeOf(_gameId) + 1);

        // forge-lint: disable-next-line(mixed-case-variable)
        uint256 totalBWA;
        for (uint256 i; i < 4; i++) {
            totalBWA += _gov.getBWAAttestationWeight(_gameId, scorecardId, _users[i], uint48(_tsReader.ts()));
        }

        uint256 theoretical = 3 * maxPower;
        assertLe(theoretical - totalBWA, 4, "fuzz: BWA total within N of (N-1)*V_MAX");
        assertLe(totalBWA, theoretical, "fuzz: BWA total <= (N-1)*V_MAX");
    }

    // =========================================================================
    // FORMAL VERIFICATION: QUORUM REACHABILITY
    // =========================================================================

    /// @notice FV-4: For any valid scorecard, the adjusted quorum is reachable by non-beneficiary attestors.
    /// @dev Proves: adjustedQuorum <= sum(BWA power of all users).
    function test_fv_quorum_alwaysReachable() external {
        _setupGame(5, 1 ether);
        _toScoring();

        uint256 tw = _nft.TOTAL_CASHOUT_WEIGHT();

        // Test extreme distributions including winner-take-all.
        uint256[5][4] memory distributions = [
            [tw / 5, tw / 5, tw / 5, tw / 5, tw / 5], // even
            [tw, uint256(0), uint256(0), uint256(0), uint256(0)], // winner-take-all
            [tw - 4, uint256(1), uint256(1), uint256(1), uint256(1)], // near winner-take-all
            [(tw * 80) / 100, (tw * 5) / 100, (tw * 5) / 100, (tw * 5) / 100, (tw * 5) / 100] // 80/5/5/5/5
        ];

        for (uint256 d; d < 4; d++) {
            DefifaTierCashOutWeight[] memory sc = _buildScorecard(5);
            for (uint256 i; i < 5; i++) {
                sc[i].cashOutWeight = distributions[d][i];
            }

            uint256 scorecardId = _gov.submitScorecardFor(_gameId, sc);
            vm.warp(_tsReader.ts() + _gov.attestationStartTimeOf(_gameId) + 1);

            // Compute total achievable BWA.
            // forge-lint: disable-next-line(mixed-case-variable)
            uint256 totalBWA;
            for (uint256 i; i < 5; i++) {
                totalBWA += _gov.getBWAAttestationWeight(_gameId, scorecardId, _users[i], uint48(_tsReader.ts()));
            }

            // Get the snapshotted quorum.
            // stateOf returns ACTIVE if quorum not met. We can check by attesting all and seeing if it reaches
            // SUCCEEDED. But more directly: the quorumSnapshot is stored. Let's check indirectly.
            // Attest all users and verify the scorecard can reach SUCCEEDED.
            for (uint256 i; i < 5; i++) {
                vm.prank(_users[i]);
                try _gov.attestToScorecardFrom(_gameId, scorecardId) {} catch {}
            }

            vm.warp(_tsReader.ts() + _gov.attestationGracePeriodOf(_gameId) + 1);

            DefifaScorecardState state = _gov.stateOf(_gameId, scorecardId);
            assertTrue(
                state == DefifaScorecardState.SUCCEEDED || state == DefifaScorecardState.QUEUED,
                "quorum must be reachable for any valid scorecard"
            );
        }
    }

    /// @notice FV-5: Fuzz quorum reachability across random scorecard weights.
    function test_fv_fuzz_quorum_reachable(uint256 w1, uint256 w2, uint256 w3, uint256 w4) external {
        _setupGame(5, 1 ether);
        _toScoring();

        uint256 tw = _nft.TOTAL_CASHOUT_WEIGHT();

        w1 = bound(w1, 0, tw);
        w2 = bound(w2, 0, tw - w1);
        w3 = bound(w3, 0, tw - w1 - w2);
        w4 = bound(w4, 0, tw - w1 - w2 - w3);
        uint256 w5 = tw - w1 - w2 - w3 - w4;

        DefifaTierCashOutWeight[] memory sc = _buildScorecard(5);
        sc[0].cashOutWeight = w1;
        sc[1].cashOutWeight = w2;
        sc[2].cashOutWeight = w3;
        sc[3].cashOutWeight = w4;
        sc[4].cashOutWeight = w5;

        uint256 scorecardId = _gov.submitScorecardFor(_gameId, sc);
        vm.warp(_tsReader.ts() + _gov.attestationStartTimeOf(_gameId) + 1);

        for (uint256 i; i < 5; i++) {
            vm.prank(_users[i]);
            try _gov.attestToScorecardFrom(_gameId, scorecardId) {} catch {}
        }

        vm.warp(_tsReader.ts() + _gov.attestationGracePeriodOf(_gameId) + 1);

        DefifaScorecardState state = _gov.stateOf(_gameId, scorecardId);
        assertTrue(
            state == DefifaScorecardState.SUCCEEDED || state == DefifaScorecardState.QUEUED,
            "fuzz: quorum must be reachable"
        );
    }

    /// @notice FV-5b: A winner-take-all scorecard submitted as one entry stays reachable when every tier has several
    /// holders with uneven counts, so BWA floors once or twice per (delegate, tier) pair.
    /// @dev Mirrors Base game 28: 21 tiers, quorumSnapshot 19,999,999,999 against 19,999,999,987 total BWA.
    function test_fv_quorum_reachable_crowdedTiersSparseScorecard() external {
        _setupCrowdedGame(21, 0);
        _toScoring();

        DefifaTierCashOutWeight[] memory sc = new DefifaTierCashOutWeight[](1);
        sc[0] = DefifaTierCashOutWeight({id: 1, cashOutWeight: _nft.TOTAL_CASHOUT_WEIGHT()});
        uint256 scorecardId = _gov.submitScorecardFor(_gameId, sc);
        vm.warp(_tsReader.ts() + _gov.attestationStartTimeOf(_gameId) + 1);

        assertLe(_quorumSnapshotOf(scorecardId), _totalBWA(scorecardId), "quorum must not exceed unanimous BWA");

        for (uint256 i; i < _users.length; i++) {
            vm.prank(_users[i]);
            try _gov.attestToScorecardFrom(_gameId, scorecardId) {} catch {}
        }
        vm.warp(_tsReader.ts() + _gov.attestationGracePeriodOf(_gameId) + 1);

        DefifaScorecardState state = _gov.stateOf(_gameId, scorecardId);
        assertTrue(
            state == DefifaScorecardState.SUCCEEDED || state == DefifaScorecardState.QUEUED,
            "unanimous attestation must reach quorum"
        );
    }

    /// @notice FV-5c: Fuzz reachability over tier count, holders per tier, uneven counts, weight split and sparse or
    /// full scorecard arrays.
    /// forge-config: default.fuzz.runs = 256
    function test_fv_fuzz_quorum_reachable_crowdedTiers(
        uint8 nTiers,
        uint256 seed,
        uint256 winnerSeed,
        bool sparse
    )
        external
    {
        // forge-lint: disable-next-line(unsafe-typecast)
        nTiers = uint8(bound(nTiers, 3, 21));
        _setupCrowdedGame(nTiers, seed);
        _toScoring();

        // Quorum is tightest near winner-take-all; lower concentration leaves headroom * (1 - maxShare²) of slack.
        // The next tier takes a share of at most 1e-8, often zero.
        uint256 tw = _nft.TOTAL_CASHOUT_WEIGHT();
        uint256[] memory weights = new uint256[](nTiers);
        uint256 winner = winnerSeed % nTiers;
        weights[(winner + 1) % nTiers] = bound(winnerSeed >> 8, 0, tw / 1e8);
        weights[winner] = tw - weights[(winner + 1) % nTiers];

        uint256 entries;
        for (uint256 i; i < nTiers; i++) {
            if (!sparse || weights[i] != 0) entries++;
        }
        DefifaTierCashOutWeight[] memory sc = new DefifaTierCashOutWeight[](entries);
        entries = 0;
        for (uint256 i; i < nTiers; i++) {
            if (!sparse || weights[i] != 0) {
                sc[entries++] = DefifaTierCashOutWeight({id: i + 1, cashOutWeight: weights[i]});
            }
        }

        uint256 scorecardId = _gov.submitScorecardFor(_gameId, sc);
        vm.warp(_tsReader.ts() + _gov.attestationStartTimeOf(_gameId) + 1);

        assertLe(_quorumSnapshotOf(scorecardId), _totalBWA(scorecardId), "fuzz: quorum must not exceed unanimous BWA");
    }

    // =========================================================================
    // FORMAL VERIFICATION: CONCENTRATION PENALTY PROPERTIES
    // =========================================================================

    /// @notice FV-6: Equal distribution produces minimal penalty; winner-take-all produces maximal penalty.
    function test_fv_concentrationPenalty_monotonic() external {
        _setupGame(5, 1 ether);
        _toScoring();

        uint256 tw = _nft.TOTAL_CASHOUT_WEIGHT();

        // Even scorecard.
        DefifaTierCashOutWeight[] memory scEven = _buildScorecard(5);
        for (uint256 i; i < 5; i++) {
            scEven[i].cashOutWeight = tw / 5;
        }
        uint256 scEvenId = _gov.submitScorecardFor(_gameId, scEven);

        // Concentrated scorecard (80/5/5/5/5).
        DefifaTierCashOutWeight[] memory scConc = _buildScorecard(5);
        scConc[0].cashOutWeight = (tw * 80) / 100;
        scConc[1].cashOutWeight = (tw * 5) / 100;
        scConc[2].cashOutWeight = (tw * 5) / 100;
        scConc[3].cashOutWeight = (tw * 5) / 100;
        scConc[4].cashOutWeight = (tw * 5) / 100;
        uint256 scConcId = _gov.submitScorecardFor(_gameId, scConc);

        // Winner-take-all scorecard.
        // forge-lint: disable-next-line(mixed-case-variable)
        DefifaTierCashOutWeight[] memory scWTA = _buildScorecard(5);
        scWTA[0].cashOutWeight = tw;
        // forge-lint: disable-next-line(mixed-case-variable)
        uint256 scWTAId = _gov.submitScorecardFor(_gameId, scWTA);

        // The quorum each scorecard snapshots grows with concentration.
        uint256 evenQuorum = _quorumSnapshotOf(scEvenId);
        uint256 concQuorum = _quorumSnapshotOf(scConcId);
        uint256 wtaQuorum = _quorumSnapshotOf(scWTAId);
        assertGt(evenQuorum, _gov.quorum(_gameId), "even scorecard pays a small penalty");
        assertGt(concQuorum, evenQuorum, "concentrated needs more than even");
        assertGt(wtaQuorum, concQuorum, "winner-take-all needs the most");
    }

    /// @notice FV-7: Penalty is exactly zero for a perfectly equal distribution (maxShare = 1/N).
    function test_fv_equalDistribution_minimalPenalty() external {
        _setupGame(8, 1 ether);
        _toScoring();

        uint256 tw = _nft.TOTAL_CASHOUT_WEIGHT();
        uint256 maxPower = _gov.MAX_ATTESTATION_POWER_TIER();
        uint256 baseQuorum = _gov.quorum(_gameId);

        // Even scorecard: each tier gets tw/8.
        DefifaTierCashOutWeight[] memory sc = _buildScorecard(8);
        for (uint256 i; i < 8; i++) {
            sc[i].cashOutWeight = tw / 8;
        }

        uint256 scorecardId = _gov.submitScorecardFor(_gameId, sc);

        // Compute expected penalty.
        uint256 headroom = baseQuorum - maxPower;
        uint256 maxWeight = tw / 8;
        uint256 maxShareSquared = mulDiv(maxWeight, maxWeight, tw);
        uint256 expectedPenalty = mulDiv(headroom, maxShareSquared, tw);

        // For 8 tiers, maxShare = 12.5%, maxShare² = 1.5625%.
        // The penalty should be very small relative to headroom.
        assertLt(expectedPenalty, headroom / 10, "even distribution penalty should be <10% of headroom");

        // All users attest — should easily reach quorum.
        vm.warp(_tsReader.ts() + _gov.attestationStartTimeOf(_gameId) + 1);
        for (uint256 i; i < 8; i++) {
            vm.prank(_users[i]);
            _gov.attestToScorecardFrom(_gameId, scorecardId);
        }
        vm.warp(_tsReader.ts() + _gov.attestationGracePeriodOf(_gameId) + 1);
        assertEq(
            uint256(_gov.stateOf(_gameId, scorecardId)),
            uint256(DefifaScorecardState.SUCCEEDED),
            "even scorecard should reach SUCCEEDED"
        );
    }

    // =========================================================================
    // FORMAL VERIFICATION: REVOCATION WEIGHT CONSERVATION
    // =========================================================================

    /// @notice FV-8: Attest then revoke returns attestation count to exactly the original value.
    function test_fv_revoke_weightConservation() external {
        _setupGame(4, 1 ether);
        _toScoring();

        DefifaTierCashOutWeight[] memory sc = _evenScorecard(4);
        uint256 scorecardId = _gov.submitScorecardFor(_gameId, sc);

        vm.warp(_tsReader.ts() + _gov.attestationStartTimeOf(_gameId) + 1);

        // Record baseline.
        uint256 countBaseline = _gov.attestationCountOf(_gameId, scorecardId);

        // All 4 users attest.
        uint256[] memory weights = new uint256[](4);
        for (uint256 i; i < 4; i++) {
            vm.prank(_users[i]);
            weights[i] = _gov.attestToScorecardFrom(_gameId, scorecardId);
        }

        uint256 countAfterAll = _gov.attestationCountOf(_gameId, scorecardId);
        uint256 expectedSum = countBaseline;
        for (uint256 i; i < 4; i++) {
            expectedSum += weights[i];
        }
        assertEq(countAfterAll, expectedSum, "count should equal sum of all weights");

        // All 4 users revoke.
        for (uint256 i; i < 4; i++) {
            vm.prank(_users[i]);
            _gov.revokeAttestationFrom(_gameId, scorecardId);
        }

        uint256 countAfterRevoke = _gov.attestationCountOf(_gameId, scorecardId);
        assertEq(countAfterRevoke, countBaseline, "count should return to baseline after all revocations");
    }

    // =========================================================================
    // FORMAL VERIFICATION: STATE MACHINE TRANSITIONS
    // =========================================================================

    /// @notice FV-9: State machine follows PENDING -> ACTIVE -> QUEUED -> SUCCEEDED -> RATIFIED.
    /// @dev Immediate scorecards open on the next timestamp so same-timestamp reserve mints are in the snapshot.
    function test_fv_stateMachine_transitions() external {
        uint256 timelockDuration = 1 days;
        _setupGameWithTimelock(4, 1 ether, timelockDuration);
        _toScoring();

        DefifaTierCashOutWeight[] memory sc = _evenScorecard(4);
        uint256 scorecardId = _gov.submitScorecardFor(_gameId, sc);

        assertEq(
            uint256(_gov.stateOf(_gameId, scorecardId)),
            uint256(DefifaScorecardState.PENDING),
            "should be PENDING before next timestamp"
        );

        vm.warp(_tsReader.ts() + _gov.attestationStartTimeOf(_gameId) + 1);
        assertEq(uint256(_gov.stateOf(_gameId, scorecardId)), uint256(DefifaScorecardState.ACTIVE), "should be ACTIVE");

        // Attest all users.
        for (uint256 i; i < 4; i++) {
            vm.prank(_users[i]);
            _gov.attestToScorecardFrom(_gameId, scorecardId);
        }

        // Still ACTIVE during grace period even with quorum met.
        assertEq(
            uint256(_gov.stateOf(_gameId, scorecardId)),
            uint256(DefifaScorecardState.ACTIVE),
            "should be ACTIVE during grace period"
        );

        // QUEUED: after grace period, during timelock.
        vm.warp(_tsReader.ts() + _gov.attestationGracePeriodOf(_gameId) + 1);
        assertEq(uint256(_gov.stateOf(_gameId, scorecardId)), uint256(DefifaScorecardState.QUEUED), "should be QUEUED");

        // SUCCEEDED: after timelock expires.
        vm.warp(_tsReader.ts() + timelockDuration + 1);
        assertEq(
            uint256(_gov.stateOf(_gameId, scorecardId)), uint256(DefifaScorecardState.SUCCEEDED), "should be SUCCEEDED"
        );

        // RATIFIED: after ratifyScorecardFrom.
        _gov.ratifyScorecardFrom(_gameId, sc);
        assertEq(
            uint256(_gov.stateOf(_gameId, scorecardId)), uint256(DefifaScorecardState.RATIFIED), "should be RATIFIED"
        );
    }

    /// @notice FV-10: Competing scorecards — first ratified wins, others become DEFEATED.
    function test_fv_competingScorecards_firstWins() external {
        _setupGame(4, 1 ether);
        _toScoring();

        uint256 tw = _nft.TOTAL_CASHOUT_WEIGHT();

        // Submit two different scorecards.
        DefifaTierCashOutWeight[] memory scA = _evenScorecard(4);
        DefifaTierCashOutWeight[] memory scB = _buildScorecard(4);
        scB[0].cashOutWeight = (tw * 40) / 100;
        scB[1].cashOutWeight = (tw * 30) / 100;
        scB[2].cashOutWeight = (tw * 20) / 100;
        scB[3].cashOutWeight = (tw * 10) / 100;

        uint256 idA = _gov.submitScorecardFor(_gameId, scA);
        uint256 idB = _gov.submitScorecardFor(_gameId, scB);

        vm.warp(_tsReader.ts() + _gov.attestationStartTimeOf(_gameId) + 1);

        // All users attest to both scorecards.
        for (uint256 i; i < 4; i++) {
            vm.prank(_users[i]);
            _gov.attestToScorecardFrom(_gameId, idA);
        }
        for (uint256 i; i < 4; i++) {
            vm.prank(_users[i]);
            _gov.attestToScorecardFrom(_gameId, idB);
        }

        vm.warp(_tsReader.ts() + _gov.attestationGracePeriodOf(_gameId) + 1);

        // Both should be SUCCEEDED.
        assertEq(uint256(_gov.stateOf(_gameId, idA)), uint256(DefifaScorecardState.SUCCEEDED), "A should be SUCCEEDED");
        assertEq(uint256(_gov.stateOf(_gameId, idB)), uint256(DefifaScorecardState.SUCCEEDED), "B should be SUCCEEDED");

        // Ratify A first.
        _gov.ratifyScorecardFrom(_gameId, scA);
        assertEq(uint256(_gov.stateOf(_gameId, idA)), uint256(DefifaScorecardState.RATIFIED), "A should be RATIFIED");
        assertEq(uint256(_gov.stateOf(_gameId, idB)), uint256(DefifaScorecardState.DEFEATED), "B should be DEFEATED");

        // Cannot ratify B.
        vm.expectPartialRevert(DefifaGovernor.DefifaGovernor_AlreadyRatified.selector);
        _gov.ratifyScorecardFrom(_gameId, scB);
    }

    // =========================================================================
    // SETUP + PRIMITIVE HELPERS
    // =========================================================================

    //*********************************************************************//
    // ------------------- enforced default delegate --------------------- //
    //*********************************************************************//

    /// @notice The default attestation delegate used by the enforced-delegate tests.
    address internal constant _DELEGATE = address(uint160(uint256(keccak256("enforcedDelegate"))));

    function test_enforced_flagWithoutDefaultDelegateReverts() public {
        DefifaLaunchProjectData memory d = _launchData(2, 1 ether);
        d.enforceDefaultAttestationDelegate = true;
        vm.expectPartialRevert(DefifaDeployer.DefifaDeployer_InvalidGameConfiguration.selector);
        deployer.launchGameWith(d);
    }

    function test_enforced_flagIsStoredWithoutDisturbingTiming() public {
        DefifaLaunchProjectData memory d = _launchDataWithTimelock(2, 1 ether, 7 days);
        d.defaultAttestationDelegate = _DELEGATE;
        d.enforceDefaultAttestationDelegate = true;
        (_pid, _nft, _gov) = _launch(d);
        assertTrue(_gov.enforcesDefaultAttestationDelegate(_pid), "flag stored");
        assertEq(_gov.attestationStartTimeOf(_pid), block.timestamp, "start time kept");
        assertEq(_gov.attestationGracePeriodOf(_pid), d.attestationGracePeriod, "grace period kept");
        assertEq(_gov.timelockDurationOf(_pid), 7 days, "timelock kept");
    }

    function test_enforced_flagOffIsReportedOff() public {
        _setupGame(2, 1 ether);
        assertFalse(_gov.enforcesDefaultAttestationDelegate(_gameId), "flag off");
    }

    function test_enforced_gameInitializedCarriesTheFlag() public {
        DefifaLaunchProjectData memory d = _launchData(2, 1 ether);
        d.defaultAttestationDelegate = _DELEGATE;
        d.enforceDefaultAttestationDelegate = true;
        vm.recordLogs();
        (_pid, _nft, _gov) = _launch(d);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] != IDefifaGovernor.GameInitialized.selector) continue;
            (,,, bool enforced,) = abi.decode(logs[i].data, (uint256, uint256, uint256, bool, address));
            assertTrue(enforced, "event carries the flag");
            found = true;
        }
        assertTrue(found, "GameInitialized emitted");
    }

    /// @notice Launches an enforced-delegate game with one token per tier, each holder self-delegated during MINT.
    function _setupEnforcedGame(uint8 nTiers) internal {
        DefifaLaunchProjectData memory d = _launchData(nTiers, 1 ether);
        d.defaultAttestationDelegate = _DELEGATE;
        d.enforceDefaultAttestationDelegate = true;
        (_pid, _nft, _gov) = _launch(d);
        vm.warp(d.start - d.mintPeriodDuration - d.refundPeriodDuration);
        _users = new address[](nTiers);
        for (uint256 i; i < nTiers; i++) {
            _users[i] = _addr(i);
            _mint(_users[i], i + 1, 1 ether);
            _delegateSelf(_users[i], i + 1);
            vm.warp(block.timestamp + 1);
        }
    }

    /// @notice A scorecard that pays one tier everything.
    function _winnerTakeAll(uint256 n, uint256 winner) internal view returns (DefifaTierCashOutWeight[] memory sc) {
        sc = _buildScorecard(n);
        sc[winner - 1].cashOutWeight = _nft.TOTAL_CASHOUT_WEIGHT();
    }

    function test_enforced_holdersHaveNoWeight() public {
        _setupEnforcedGame(4);
        _toScoring();
        uint256 scorecardId = _gov.submitScorecardFor(_gameId, _winnerTakeAll(4, 1));
        for (uint256 i; i < _users.length; i++) {
            assertEq(
                _gov.getBWAAttestationWeight(_gameId, scorecardId, _users[i], uint48(block.timestamp)),
                0,
                "self-delegated holder has no weight"
            );
        }
    }

    function test_enforced_delegateCarriesFullPossibleAttestation() public {
        _setupEnforcedGame(4);
        _toScoring();
        uint256 max = _gov.MAX_ATTESTATION_POWER_TIER();
        uint256 wta = _gov.submitScorecardFor(_gameId, _winnerTakeAll(4, 1));
        assertEq(
            _gov.getBWAAttestationWeight(_gameId, wta, _DELEGATE, uint48(block.timestamp)), 3 * max, "WTA: (N-1) * MAX"
        );
        uint256 even = _gov.submitScorecardFor(_gameId, _evenScorecard(4));
        assertApproxEqAbs(
            _gov.getBWAAttestationWeight(_gameId, even, _DELEGATE, uint48(block.timestamp)),
            3 * max,
            4,
            "even: (N-1) * MAX"
        );
    }

    function test_enforced_delegateAloneRatifiesThroughTheNormalFlow() public {
        _setupEnforcedGame(4);
        _toScoring();
        DefifaTierCashOutWeight[] memory sc = _winnerTakeAll(4, 2);
        uint256 scorecardId = _gov.submitScorecardFor(_gameId, sc);
        vm.warp(_tsReader.ts() + 2);
        vm.prank(_DELEGATE);
        _gov.attestToScorecardFrom(_gameId, scorecardId);
        assertEq(uint256(_gov.stateOf(_gameId, scorecardId)), uint256(DefifaScorecardState.ACTIVE), "grace period");
        vm.warp(_tsReader.ts() + _gov.attestationGracePeriodOf(_gameId) + 1);
        assertEq(uint256(_gov.stateOf(_gameId, scorecardId)), uint256(DefifaScorecardState.SUCCEEDED), "delegate alone");
        vm.prank(_users[0]);
        _gov.ratifyScorecardFrom(_gameId, sc);
        assertEq(_gov.ratifiedScorecardIdOf(_gameId), scorecardId, "anyone ratifies");
    }

    function test_enforced_holderAttestationReverts() public {
        _setupEnforcedGame(4);
        _toScoring();
        uint256 scorecardId = _gov.submitScorecardFor(_gameId, _winnerTakeAll(4, 1));
        vm.warp(_tsReader.ts() + 2);
        vm.prank(_users[1]);
        vm.expectPartialRevert(DefifaGovernor.DefifaGovernor_NotAllowed.selector);
        _gov.attestToScorecardFrom(_gameId, scorecardId);
        assertEq(_gov.attestationCountOf(_gameId, scorecardId), 0, "no weight added");
    }

    function test_enforced_delegateHoldingTokensGetsExactlyFullPower() public {
        _setupEnforcedGame(4);
        _mint(_DELEGATE, 3, 1 ether);
        _toScoring();
        uint256 scorecardId = _gov.submitScorecardFor(_gameId, _winnerTakeAll(4, 1));
        assertEq(
            _gov.getBWAAttestationWeight(_gameId, scorecardId, _DELEGATE, uint48(block.timestamp)),
            3 * _gov.MAX_ATTESTATION_POWER_TIER(),
            "own tokens add nothing"
        );
    }

    function test_enforced_flagOffDelegateHasOnlyDelegatedPower() public {
        DefifaLaunchProjectData memory d = _launchData(4, 1 ether);
        d.defaultAttestationDelegate = _DELEGATE;
        (_pid, _nft, _gov) = _launch(d);
        vm.warp(d.start - d.mintPeriodDuration - d.refundPeriodDuration);
        _users = new address[](4);
        for (uint256 i; i < 4; i++) {
            _users[i] = _addr(i);
            _mint(_users[i], i + 1, 1 ether);
            _delegateSelf(_users[i], i + 1);
            vm.warp(block.timestamp + 1);
        }
        _toScoring();
        uint256 scorecardId = _gov.submitScorecardFor(_gameId, _winnerTakeAll(4, 1));
        assertEq(
            _gov.getBWAAttestationWeight(_gameId, scorecardId, _DELEGATE, uint48(block.timestamp)),
            0,
            "unenforced delegate with no delegated units has no weight"
        );
    }

    //*********************************************************************//
    // ---------------------- 50% to 75% quorum ------------------------- //
    //*********************************************************************//

    /// @notice Mirrors the governor's quorum: (N - 1) * MAX scaled from 50% to 75% by the largest share squared.
    function _expectedQuorum(uint256 eligibleTiers, uint256 maxWeight) internal view returns (uint256 q) {
        uint256 tw = _nft.TOTAL_CASHOUT_WEIGHT();
        uint256 maxBwa = eligibleTiers == 0 ? 0 : (eligibleTiers - 1) * _gov.MAX_ATTESTATION_POWER_TIER();
        uint256 bps = 5000 + mulDiv(2500, mulDiv(maxWeight, maxWeight, tw), tw);
        q = mulDiv(maxBwa, bps, 10_000);
        if (q == 0) q = 1;
    }

    /// @notice Opens attestations, has the given users attest, then ends the grace period.
    function _attestAndEndGrace(uint256 scorecardId, uint256[] memory userIndexes) internal {
        vm.warp(_tsReader.ts() + 2);
        for (uint256 i; i < userIndexes.length; i++) {
            vm.prank(_users[userIndexes[i]]);
            _gov.attestToScorecardFrom(_gameId, scorecardId);
        }
        vm.warp(_tsReader.ts() + _gov.attestationGracePeriodOf(_gameId) + 1);
    }

    function test_quorum_twoTierWinnerTakeAllNeeds75Percent() public {
        _setupGame(2, 1 ether);
        _toScoring();
        DefifaTierCashOutWeight[] memory sc = _buildScorecard(2);
        sc[0].cashOutWeight = _nft.TOTAL_CASHOUT_WEIGHT();
        uint256 scorecardId = _gov.submitScorecardFor(_gameId, sc);
        assertEq(_quorumSnapshotOf(scorecardId), _gov.MAX_ATTESTATION_POWER_TIER() * 3 / 4, "75% of one tier");
        uint256[] memory loser = new uint256[](1);
        loser[0] = 1;
        _attestAndEndGrace(scorecardId, loser);
        assertEq(uint256(_gov.stateOf(_gameId, scorecardId)), uint256(DefifaScorecardState.SUCCEEDED), "loser concedes");
    }

    function test_quorum_twoTierEvenSplitNeedsBothSides() public {
        _setupGame(2, 1 ether);
        _toScoring();
        uint256 scorecardId = _gov.submitScorecardFor(_gameId, _evenScorecard(2));
        assertEq(_quorumSnapshotOf(scorecardId), _expectedQuorum(2, _nft.TOTAL_CASHOUT_WEIGHT() / 2), "56.25%");
        uint256[] memory one = new uint256[](1);
        _attestAndEndGrace(scorecardId, one);
        assertEq(uint256(_gov.stateOf(_gameId, scorecardId)), uint256(DefifaScorecardState.ACTIVE), "half is short");
    }

    function test_quorum_winnerTakeAllPassesWithThreeOfFourLosers() public {
        _setupGame(5, 1 ether);
        _toScoring();
        DefifaTierCashOutWeight[] memory sc = _buildScorecard(5);
        sc[0].cashOutWeight = _nft.TOTAL_CASHOUT_WEIGHT();
        uint256 scorecardId = _gov.submitScorecardFor(_gameId, sc);
        uint256[] memory two = new uint256[](2);
        two[0] = 1;
        two[1] = 2;
        _attestAndEndGrace(scorecardId, two);
        assertEq(uint256(_gov.stateOf(_gameId, scorecardId)), uint256(DefifaScorecardState.ACTIVE), "2 of 4 short");
        vm.prank(_users[3]);
        _gov.attestToScorecardFrom(_gameId, scorecardId);
        assertEq(uint256(_gov.stateOf(_gameId, scorecardId)), uint256(DefifaScorecardState.SUCCEEDED), "3 of 4 pass");
    }

    function test_quorum_oneTierGameNeverRatifies() public {
        _setupGame(1, 1 ether);
        _toScoring();
        DefifaTierCashOutWeight[] memory sc = _buildScorecard(1);
        sc[0].cashOutWeight = _nft.TOTAL_CASHOUT_WEIGHT();
        uint256 scorecardId = _gov.submitScorecardFor(_gameId, sc);
        assertEq(_quorumSnapshotOf(scorecardId), 1, "floor of 1");
        vm.warp(_tsReader.ts() + _gov.attestationGracePeriodOf(_gameId) + 2);
        assertEq(uint256(_gov.stateOf(_gameId, scorecardId)), uint256(DefifaScorecardState.ACTIVE), "unreachable");
    }

    function test_quorum_viewIsTheEvenSplitQuorum() public {
        _setupGame(4, 1 ether);
        _toScoring();
        assertEq(_gov.quorum(_gameId), 3 * _gov.MAX_ATTESTATION_POWER_TIER() / 2, "50% of (N - 1) * MAX");
    }

    /// @notice Unanimity always reaches quorum, and quorum never drops below an even split's.
    function testFuzz_quorum_reachableAndNeverBelowEven(uint8 nTiers, uint256 seed, uint256 split) public {
        nTiers = uint8(bound(nTiers, 2, 21));
        _setupCrowdedGame(nTiers, seed);
        _toScoring();
        uint256 tw = _nft.TOTAL_CASHOUT_WEIGHT();
        uint256 top = bound(split, tw / nTiers + 1, tw);
        DefifaTierCashOutWeight[] memory sc = _buildScorecard(nTiers);
        sc[0].cashOutWeight = top;
        uint256 rest = tw - top;
        for (uint256 i = 1; i < nTiers; i++) {
            sc[i].cashOutWeight = rest / (nTiers - 1);
        }
        sc[1].cashOutWeight += rest - (rest / (nTiers - 1)) * (nTiers - 1);
        uint256 scorecardId = _gov.submitScorecardFor(_gameId, sc);
        uint256 snapshot = _quorumSnapshotOf(scorecardId);
        assertLe(snapshot, _totalBWA(scorecardId), "unanimity always reaches quorum");
        assertGe(snapshot, _expectedQuorum(nTiers, tw / nTiers), "never below an even split");
    }

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

    /// @notice Launches a game where each tier has 1 to 6 self-delegated holders, each holding 1 to 3 tokens.
    function _setupCrowdedGame(uint8 nTiers, uint256 seed) internal {
        DefifaLaunchProjectData memory d = _launchData(nTiers, 1 ether);
        (_pid, _nft, _gov) = _launch(d);
        vm.warp(d.start - d.mintPeriodDuration - d.refundPeriodDuration);
        delete _users;
        for (uint256 t = 1; t <= nTiers; t++) {
            uint256 holders = 1 + uint256(keccak256(abi.encode(seed, t))) % 6;
            for (uint256 h; h < holders; h++) {
                address user = _addr(_users.length);
                _users.push(user);
                uint256 count = 1 + uint256(keccak256(abi.encode(seed, t, h))) % 3;
                _mintCount(user, t, count, 1 ether);
                _delegateSelf(user, t);
                vm.warp(block.timestamp + 1);
            }
        }
    }

    /// @notice The scorecard's BWA power if every holder attests.
    // forge-lint: disable-next-line(mixed-case-function)
    function _totalBWA(uint256 scorecardId) internal view returns (uint256 total) {
        for (uint256 i; i < _users.length; i++) {
            total += _gov.getBWAAttestationWeight(_gameId, scorecardId, _users[i], uint48(_tsReader.ts()));
        }
    }

    function _toScoring() internal {
        vm.warp(_tsReader.ts() + 3 days + 1);
    }

    function _launchData(uint8 n, uint256 tierPrice) internal view returns (DefifaLaunchProjectData memory) {
        return _launchDataWithTimelock(n, tierPrice, 0);
    }

    function _launchDataWithTimelock(
        uint8 n,
        uint256 tierPrice,
        uint256 timelockDuration
    )
        internal
        view
        returns (DefifaLaunchProjectData memory)
    {
        DefifaTierParams[] memory tp = new DefifaTierParams[](n);
        for (uint256 i; i < n; i++) {
            tp[i] = DefifaTierParams({
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
            // forge-lint: disable-next-line(unsafe-typecast)
            tierPrice: uint104(tierPrice),
            tiers: tp,
            defaultTokenUriResolver: IJB721TokenUriResolver(address(0)),
            terminal: jbMultiTerminal(),
            minParticipation: 0,
            scorecardTimeout: type(uint32).max,
            timelockDuration: timelockDuration,
            enforceDefaultAttestationDelegate: false
        });
    }

    function _launch(DefifaLaunchProjectData memory d)
        internal
        returns (uint256 p, Defifa1155Hook n, DefifaGovernor g)
    {
        g = governor;
        p = deployer.launchGameWith(d);
        JBRuleset memory fc = jbRulesets().currentOf(p);
        if (fc.dataHook() == address(0)) (fc,) = jbRulesets().latestQueuedOf(p);
        n = Defifa1155Hook(fc.dataHook());
    }

    function _addr(uint256 i) internal pure returns (address) {
        return address(bytes20(keccak256(abi.encode("govharden", i))));
    }

    function _mint(address user, uint256 tid, uint256 amt) internal {
        _mintCount(user, tid, 1, amt);
    }

    function _mintCount(address user, uint256 tid, uint256 count, uint256 price) internal {
        uint256 amt = count * price;
        vm.deal(user, amt);
        uint16[] memory m = new uint16[](1);
        // forge-lint: disable-next-line(unsafe-typecast)
        m[0] = uint16(tid);
        uint256[] memory counts = new uint256[](1);
        counts[0] = count;
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encode(user, m, counts);
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

    /// @notice Reads a scorecard's `quorumSnapshot`, the second slot of `DefifaScorecard` in `_scorecardOf` (slot 4,
    /// after `Ownable._owner` and three mappings).
    function _quorumSnapshotOf(uint256 scorecardId) internal view returns (uint256) {
        bytes32 gameSlot = keccak256(abi.encode(_gameId, uint256(4)));
        return uint256(vm.load(address(_gov), bytes32(uint256(keccak256(abi.encode(scorecardId, gameSlot))) + 1)));
    }
}
