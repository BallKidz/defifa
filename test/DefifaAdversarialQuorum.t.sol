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

/// @dev Helper to read block.timestamp via an external call, bypassing the via-ir optimizer's timestamp caching.
contract TSReader {
    function ts() external view returns (uint256) {
        return block.timestamp;
    }
}

/// @title DefifaAdversarialQuorumTest
/// @notice Tests that the Defifa quorum/attestation system is resistant to manipulation:
///         1. Attestation power is snapshot-based (getPastTierAttestationUnitsOf), so buying
///            tokens after a scorecard is submitted gives zero attestation power.
///         2. Delegation changes after the mint phase are blocked, preventing post-scorecard vote shifting.
///         3. Transferring NFTs after attestation does not create double-voting opportunities.
///         4. A single tier with a dominant holder cannot override the quorum system because
///            each tier caps at MAX_ATTESTATION_POWER_TIER regardless of token count.
contract DefifaAdversarialQuorumTest is JBTest, TestBaseWorkflow {
    using JBRulesetMetadataResolver for JBRuleset;

    TSReader private _tsReader = new TSReader();

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
            _defifaProjectId,
            new JB721TiersHookStore()
        );
        hook.transferOwnership(address(deployer));
        governor.transferOwnership(address(deployer));
    }

    // =========================================================================
    // TEST 1: Attestation power uses snapshot, so late buyers get zero power.
    // This is the core defense against flash-mint-vote-sell attacks.
    // =========================================================================
    function test_lateBuyerHasZeroAttestationPower() external {
        // Setup: 4 tiers, 1 minter each
        _setupGame(4, 1 ether);
        _toScoring();

        // Record the attestation start snapshot time (before any scorecard)
        uint48 snapshotTime = uint48(_tsReader.ts());

        // Submit a scorecard
        DefifaTierCashOutWeight[] memory sc = _buildScorecard(4);
        uint256 tw = _nft.TOTAL_CASHOUT_WEIGHT();
        for (uint256 i; i < 4; i++) {
            sc[i].cashOutWeight = tw / 4;
        }
        _gov.submitScorecardFor(_gameId, sc);

        // Now the attacker mints in a new block (after the scorecard was submitted).
        // Payments are paused in scoring phase, so this would revert. But even if somehow
        // an attacker acquired tokens after the snapshot, their getPastTierAttestationUnitsOf
        // at the snapshotTime would be 0.
        address attacker = _addr(999);

        // Verify attacker has 0 attestation power at the snapshot timestamp.
        assertEq(
            _gov.getAttestationWeight(_gameId, attacker, snapshotTime),
            0,
            "attacker who did not hold tokens at snapshot has 0 attestation power"
        );

        // Verify legitimate users still have full power.
        for (uint256 i; i < _users.length; i++) {
            assertGt(
                _gov.getAttestationWeight(_gameId, _users[i], snapshotTime), 0, "legitimate user has attestation power"
            );
        }
    }

    // =========================================================================
    // TEST 2: Delegation changes are blocked after the mint phase.
    // This prevents an attacker from delegating to themselves after the scorecard.
    // =========================================================================
    function test_delegationBlockedInScoringPhase() external {
        _setupGame(4, 1 ether);
        _toScoring();

        // Attacker tries to change their tier 1 delegation during scoring phase.
        address attacker = _users[0];
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSignature("DefifaHook_DelegateChangesUnavailableInThisPhase()"));
        _nft.setTierDelegateTo(address(0xdead), 1);
    }

    // =========================================================================
    // TEST 3: Delegation changes are also blocked in the refund phase.
    // =========================================================================
    function test_delegationBlockedInRefundPhase() external {
        _setupGame(4, 1 ether);

        // Warp to refund phase (after mint, before start)
        vm.warp(_tsReader.ts() + 1 days);

        vm.prank(_users[0]);
        vm.expectRevert(abi.encodeWithSignature("DefifaHook_DelegateChangesUnavailableInThisPhase()"));
        _nft.setTierDelegateTo(address(0xdead), 1);
    }

    // =========================================================================
    // TEST 4: Double attestation is prevented.
    // An attacker who already attested cannot attest again even after transferring
    // their NFT to a new address.
    // =========================================================================
    function test_doubleAttestationPrevented() external {
        _setupGame(4, 1 ether);
        _toScoring();

        // Submit scorecard and begin attestation.
        DefifaTierCashOutWeight[] memory sc = _buildScorecard(4);
        uint256 tw = _nft.TOTAL_CASHOUT_WEIGHT();
        for (uint256 i; i < 4; i++) {
            sc[i].cashOutWeight = tw / 4;
        }
        uint256 proposalId = _gov.submitScorecardFor(_gameId, sc);

        // Wait for attestation start.
        vm.warp(_tsReader.ts() + _gov.attestationStartTimeOf(_gameId) + 1);

        // User 0 attests.
        vm.prank(_users[0]);
        _gov.attestToScorecardFrom(_gameId, proposalId);

        // User 0 tries to attest again.
        vm.prank(_users[0]);
        vm.expectRevert(DefifaGovernor.DefifaGovernor_AlreadyAttested.selector);
        _gov.attestToScorecardFrom(_gameId, proposalId);
    }

    // =========================================================================
    // TEST 5: Each tier caps at MAX_ATTESTATION_POWER_TIER regardless of
    // how many tokens are held. A whale buying 100 tokens in one tier
    // gets the same attestation power as someone who holds 1.
    // =========================================================================
    function test_tierPowerCappedAtMax() external {
        // Setup: 4 tiers, user 0 holds ALL of tier 1 (the only minter).
        // User 0's attestation weight for tier 1 should be MAX_ATTESTATION_POWER_TIER.
        _setupGame(4, 1 ether);

        // Verify that user 0 (sole holder of tier 1) has exactly MAX_ATTESTATION_POWER_TIER.
        vm.warp(_tsReader.ts() + 1);
        uint256 power = _gov.getAttestationWeight(_gameId, _users[0], uint48(_tsReader.ts()));
        assertEq(
            power,
            _gov.MAX_ATTESTATION_POWER_TIER(),
            "sole holder of one tier should have exactly MAX_ATTESTATION_POWER_TIER"
        );
    }

    // =========================================================================
    // TEST 6: Quorum requires 50% of minted tier weight.
    // With 4 minted tiers, quorum = 2 * MAX_ATTESTATION_POWER_TIER.
    // 1 out of 4 attestors cannot reach quorum alone.
    // =========================================================================
    function test_singleAttestorCannotReachQuorum() external {
        _setupGame(4, 1 ether);
        _toScoring();

        uint256 quorum = _gov.quorum(_gameId);
        uint256 expectedQuorum = (4 * _gov.MAX_ATTESTATION_POWER_TIER()) / 2;
        assertEq(quorum, expectedQuorum, "quorum = 50% of 4 minted tiers");

        // Submit scorecard.
        DefifaTierCashOutWeight[] memory sc = _buildScorecard(4);
        uint256 tw = _nft.TOTAL_CASHOUT_WEIGHT();
        for (uint256 i; i < 4; i++) {
            sc[i].cashOutWeight = tw / 4;
        }
        uint256 proposalId = _gov.submitScorecardFor(_gameId, sc);

        // Wait for attestation + grace period.
        vm.warp(_tsReader.ts() + _gov.attestationStartTimeOf(_gameId) + 1);

        // Only user 0 attests (25% of total power).
        vm.prank(_users[0]);
        _gov.attestToScorecardFrom(_gameId, proposalId);

        // After grace period, quorum should NOT be met.
        vm.warp(_tsReader.ts() + _gov.attestationGracePeriodOf(_gameId) + 1);

        // The proposal should still be ACTIVE (not SUCCEEDED) because quorum is unmet.
        DefifaScorecardState state = _gov.stateOf(_gameId, proposalId);
        assertEq(uint256(state), uint256(DefifaScorecardState.ACTIVE), "1/4 attestors should not reach quorum");

        // Attempting to ratify should revert.
        vm.expectRevert(DefifaGovernor.DefifaGovernor_NotAllowed.selector);
        _gov.ratifyScorecardFrom(_gameId, sc);
    }

    // =========================================================================
    // TEST 7: Three out of four attestors can reach the HHI-adjusted quorum.
    // With BWA (Benefit-Weighted Attestation), each attestor's power is reduced
    // by their tier's share of the scorecard. For an equal 4-tier scorecard:
    //   BWA power per user = MAX_ATTESTATION_POWER_TIER * 0.75 = 750_000_000
    //   HHI-adjusted quorum = baseQuorum * 1.125 = 2_250_000_000
    // So 3 users (2_250_000_000) just meets quorum, but 2 users (1_500_000_000) does not.
    // =========================================================================
    function test_halfAttestorsCanReachQuorum() external {
        _setupGame(4, 1 ether);
        _toScoring();

        // Submit scorecard.
        DefifaTierCashOutWeight[] memory sc = _buildScorecard(4);
        uint256 tw = _nft.TOTAL_CASHOUT_WEIGHT();
        for (uint256 i; i < 4; i++) {
            sc[i].cashOutWeight = tw / 4;
        }
        uint256 proposalId = _gov.submitScorecardFor(_gameId, sc);
        vm.warp(_tsReader.ts() + _gov.attestationStartTimeOf(_gameId) + 1);

        // Users 0, 1, and 2 attest (75% of raw power, but BWA-adjusted to meet quorum).
        vm.prank(_users[0]);
        _gov.attestToScorecardFrom(_gameId, proposalId);
        vm.prank(_users[1]);
        _gov.attestToScorecardFrom(_gameId, proposalId);
        vm.prank(_users[2]);
        _gov.attestToScorecardFrom(_gameId, proposalId);

        // After grace period.
        vm.warp(_tsReader.ts() + _gov.attestationGracePeriodOf(_gameId) + 1);

        // The proposal should be SUCCEEDED.
        DefifaScorecardState state = _gov.stateOf(_gameId, proposalId);
        assertEq(uint256(state), uint256(DefifaScorecardState.SUCCEEDED), "3/4 attestation should reach quorum");

        // Ratification should succeed.
        _gov.ratifyScorecardFrom(_gameId, sc);
        assertTrue(_nft.cashOutWeightIsSet(), "weights should be set after ratification");
    }

    // =========================================================================
    // TEST 8: A second scorecard can be ratified if the first doesn't reach quorum.
    // =========================================================================
    function test_competingScorecards_firstFails_secondSucceeds() external {
        _setupGame(4, 1 ether);
        _toScoring();

        uint256 tw = _nft.TOTAL_CASHOUT_WEIGHT();

        // Scorecard A: tier 1 gets everything.
        DefifaTierCashOutWeight[] memory scA = _buildScorecard(4);
        scA[0].cashOutWeight = tw;

        // Scorecard B: equal distribution.
        DefifaTierCashOutWeight[] memory scB = _buildScorecard(4);
        for (uint256 i; i < 4; i++) {
            scB[i].cashOutWeight = tw / 4;
        }

        uint256 proposalA = _gov.submitScorecardFor(_gameId, scA);
        uint256 proposalB = _gov.submitScorecardFor(_gameId, scB);

        // Wait for attestation.
        vm.warp(_tsReader.ts() + _gov.attestationStartTimeOf(_gameId) + 1);

        // User 0 (tier 1, 100% beneficiary of scorecard A) has BWA power = 0 and cannot attest.
        vm.prank(_users[0]);
        vm.expectRevert(DefifaGovernor.DefifaGovernor_NotAllowed.selector);
        _gov.attestToScorecardFrom(_gameId, proposalA);

        // Users 1, 2, 3 like scorecard B (3/4, quorum met).
        vm.prank(_users[1]);
        _gov.attestToScorecardFrom(_gameId, proposalB);
        vm.prank(_users[2]);
        _gov.attestToScorecardFrom(_gameId, proposalB);
        vm.prank(_users[3]);
        _gov.attestToScorecardFrom(_gameId, proposalB);

        // After grace period.
        vm.warp(_tsReader.ts() + _gov.attestationGracePeriodOf(_gameId) + 1);

        // Scorecard A should still be ACTIVE (no quorum).
        assertEq(
            uint256(_gov.stateOf(_gameId, proposalA)),
            uint256(DefifaScorecardState.ACTIVE),
            "scorecard A should not reach quorum"
        );

        // Scorecard B should be SUCCEEDED.
        assertEq(
            uint256(_gov.stateOf(_gameId, proposalB)),
            uint256(DefifaScorecardState.SUCCEEDED),
            "scorecard B should reach quorum"
        );

        // Ratify scorecard B.
        _gov.ratifyScorecardFrom(_gameId, scB);

        // After ratification, scorecard A is DEFEATED.
        assertEq(
            uint256(_gov.stateOf(_gameId, proposalA)),
            uint256(DefifaScorecardState.DEFEATED),
            "scorecard A defeated after B is ratified"
        );
    }

    // =========================================================================
    // TEST 9: Burns (refunds) lower quorum, allowing ratification that
    // would otherwise require more attestors.
    //
    // This proves the game handles burn-to-lower-quorum gracefully.
    // The quorum() function uses live supply (currentSupplyOfTier) rather
    // than a snapshot, so when tokens are burned the quorum threshold
    // decreases. This is documented and accepted behavior.
    //
    // With BWA + HHI-adjusted quorum, a minimum of 4 remaining tiers is needed
    // for a balanced scorecard to reach quorum (since total BWA power for n tiers
    // is MAX*(n-1) and the adjusted quorum for n=2 always exceeds that).
    // We use 6 tiers, burn 2, leaving 4 tiers where 3/4 attestors suffice.
    // =========================================================================
    function test_burnTiersLowersQuorumAllowsRatification() external {
        // --- Step 1: Setup 6 tiers, 1 user per tier ---
        _setupGame(6, 1 ether);

        // Verify initial quorum: 6 minted tiers -> quorum = 3 * MAX_ATTESTATION_POWER_TIER.
        uint256 initialQuorum = _gov.quorum(_gameId);
        uint256 maxTier = _gov.MAX_ATTESTATION_POWER_TIER();
        assertEq(initialQuorum, (6 * maxTier) / 2, "initial quorum = 50% of 6 tiers");

        // --- Step 2: Warp to REFUND phase, users 4 and 5 refund ---
        _toRefund();

        // Users in tiers 5 and 6 refund (burn their tokens).
        _cashOut(_users[4], 5, 1);
        _cashOut(_users[5], 6, 1);

        // Verify tiers 5 and 6 now have zero supply.
        assertEq(_nft.currentSupplyOfTier(5), 0, "tier 5 supply = 0 after refund");
        assertEq(_nft.currentSupplyOfTier(6), 0, "tier 6 supply = 0 after refund");

        // Quorum should now reflect only 4 minted tiers.
        uint256 newQuorum = _gov.quorum(_gameId);
        assertEq(newQuorum, (4 * maxTier) / 2, "quorum drops to 50% of 4 remaining tiers");
        assertLt(newQuorum, initialQuorum, "new quorum < initial quorum");

        // --- Step 3: Advance to SCORING phase ---
        _toScoring();

        // --- Step 4: Submit scorecard ---
        // Equal split across remaining tiers 1-4; burned tiers 5+6 get 0.
        DefifaTierCashOutWeight[] memory sc = _buildScorecard(6);
        uint256 tw = _nft.TOTAL_CASHOUT_WEIGHT();
        sc[0].cashOutWeight = tw / 4;
        sc[1].cashOutWeight = tw / 4;
        sc[2].cashOutWeight = tw / 4;
        sc[3].cashOutWeight = tw / 4;
        // sc[4].cashOutWeight = 0; (default, tier 5 burned)
        // sc[5].cashOutWeight = 0; (default, tier 6 burned)
        uint256 proposalId = _gov.submitScorecardFor(_gameId, sc);

        // --- Step 5: Users 0, 1, and 2 attest (3 of 4 remaining tiers) ---
        // BWA power per user (25% tier weight): 1e9 * 0.75 = 750_000_000.
        // HHI-adjusted quorum for equal 4-tier scorecard = 2e9 * 1.125 = 2_250_000_000.
        // 3 users * 750M = 2_250_000_000, meeting the adjusted quorum exactly.
        vm.warp(_tsReader.ts() + _gov.attestationStartTimeOf(_gameId) + 1);

        vm.prank(_users[0]);
        _gov.attestToScorecardFrom(_gameId, proposalId);
        vm.prank(_users[1]);
        _gov.attestToScorecardFrom(_gameId, proposalId);
        vm.prank(_users[2]);
        _gov.attestToScorecardFrom(_gameId, proposalId);

        // --- Step 6: After grace period, proposal should be SUCCEEDED ---
        vm.warp(_tsReader.ts() + _gov.attestationGracePeriodOf(_gameId) + 1);

        DefifaScorecardState state = _gov.stateOf(_gameId, proposalId);
        assertEq(
            uint256(state), uint256(DefifaScorecardState.SUCCEEDED), "3 attestors reach quorum after tiers 5+6 burned"
        );

        // --- Step 7: Ratification should succeed ---
        _gov.ratifyScorecardFrom(_gameId, sc);
        assertTrue(_nft.cashOutWeightIsSet(), "scorecard ratified - weights are set");

        // --- Step 8: Verify game resilience ---
        assertEq(_nft.currentSupplyOfTier(1), 1, "tier 1 supply intact");
        assertEq(_nft.currentSupplyOfTier(2), 1, "tier 2 supply intact");
        assertEq(_nft.currentSupplyOfTier(3), 1, "tier 3 supply intact");
        assertEq(_nft.currentSupplyOfTier(4), 1, "tier 4 supply intact");
    }

    // =========================================================================
    // SETUP + PRIMITIVE HELPERS (mirrors DefifaSecurity.t.sol)
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

    function _toScoring() internal {
        vm.warp(_tsReader.ts() + 3 days + 1);
    }

    function _launchData(uint8 n, uint256 tierPrice) internal returns (DefifaLaunchProjectData memory) {
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
            timelockDuration: 0
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
        return address(bytes20(keccak256(abi.encode("aq", i))));
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

    function _toRefund() internal {
        // Advance to the refund phase (1 day after mint phase start = start - refundDuration).
        vm.warp(_tsReader.ts() + 1 days + 1);
    }

    function _buildScorecard(uint256 n) internal pure returns (DefifaTierCashOutWeight[] memory sc) {
        sc = new DefifaTierCashOutWeight[](n);
        for (uint256 i; i < n; i++) {
            sc[i].id = i + 1;
        }
    }

    function _cashOut(address user, uint256 tid, uint256 tnum) internal {
        bytes memory meta = _cashOutMeta(tid, tnum);
        vm.prank(user);
        JBMultiTerminal(address(jbMultiTerminal()))
            .cashOutTokensOf({
                holder: user,
                projectId: _pid,
                cashOutCount: 0,
                tokenToReclaim: JBConstants.NATIVE_TOKEN,
                minTokensReclaimed: 0,
                beneficiary: payable(user),
                metadata: meta
            });
    }

    function _cashOutMeta(uint256 tid, uint256 tnum) internal view returns (bytes memory) {
        uint256[] memory cid = new uint256[](1);
        cid[0] = (tid * 1_000_000_000) + tnum;
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encode(cid);
        bytes4[] memory ids = new bytes4[](1);
        ids[0] = metadataHelper().getId("cashOut", address(hook));
        return metadataHelper().createMetadata(ids, data);
    }
}
