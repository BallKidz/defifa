// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {DefifaGovernor} from "../src/DefifaGovernor.sol";
import {DefifaDeployer} from "../src/DefifaDeployer.sol";
import {DefifaHook} from "../src/DefifaHook.sol";
import {DefifaTokenUriResolver} from "../src/DefifaTokenUriResolver.sol";
import {JB721TiersHookStore} from "@bananapus/721-hook-v6/src/JB721TiersHookStore.sol";

import {TestBaseWorkflow} from "@bananapus/core-v6/test/helpers/TestBaseWorkflow.sol";
import {JBTest} from "@bananapus/core-v6/test/helpers/JBTest.sol";
import {JBRulesetMetadataResolver} from "@bananapus/core-v6/src/libraries/JBRulesetMetadataResolver.sol";
import {JBAddressRegistry} from "@bananapus/address-registry-v6/src/JBAddressRegistry.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ITypeface} from "lib/typeface/contracts/interfaces/ITypeface.sol";
import {IJB721TokenUriResolver} from "@bananapus/721-hook-v6/src/interfaces/IJB721TokenUriResolver.sol";
import {JB721Tier} from "@bananapus/721-hook-v6/src/structs/JB721Tier.sol";
import {DefifaDelegation} from "../src/structs/DefifaDelegation.sol";
import {DefifaLaunchProjectData} from "../src/structs/DefifaLaunchProjectData.sol";
import {DefifaTierParams} from "../src/structs/DefifaTierParams.sol";
import {DefifaTierCashOutWeight} from "../src/structs/DefifaTierCashOutWeight.sol";
import {DefifaGamePhase} from "../src/enums/DefifaGamePhase.sol";
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
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetApprovalHook.sol";
import {JBMultiTerminal} from "@bananapus/core-v6/src/JBMultiTerminal.sol";

/// @notice Mock ERC-20 token with configurable decimals for testing.
contract AuditGapsMockToken is ERC20 {
    uint8 private _decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Helper to read block.timestamp via an external call, bypassing the via-ir optimizer's timestamp caching.
contract AuditGapsTimestampReader {
    function timestamp() external view returns (uint256) {
        return block.timestamp;
    }
}

// =============================================================================
// GAP 1: ERC-20 GAMES
// =============================================================================

/// @title TestAuditGapsERC20Games
/// @notice Tests Defifa game mechanics when using ERC-20 tokens instead of native ETH.
/// Exercises 18-decimal ERC-20 token flows: minting, refunding, scoring, fee fulfillment,
/// cash-out distribution, and no-contest mechanisms.
contract TestAuditGapsERC20Games is JBTest, TestBaseWorkflow {
    using JBRulesetMetadataResolver for JBRuleset;

    AuditGapsTimestampReader private _tsReader;
    AuditGapsMockToken token;

    address _protocolFeeProjectTokenAccount;
    address _defifaProjectTokenAccount;
    uint256 _protocolFeeProjectId;
    uint256 _defifaProjectId;
    uint256 _gameId = 3;

    DefifaDeployer deployer;
    DefifaHook hook;
    DefifaGovernor governor;
    address projectOwner = address(bytes20(keccak256("projectOwner")));

    // Shared test state.
    uint256 _pid;
    DefifaHook _nft;
    DefifaGovernor _gov;
    address[] _users;

    function setUp() public virtual override {
        super.setUp();

        _tsReader = new AuditGapsTimestampReader();
        token = new AuditGapsMockToken("Test Token", "TT", 18);

        // Terminal configurations using the ERC-20.
        JBAccountingContext[] memory _tokens = new JBAccountingContext[](1);
        _tokens[0] =
            JBAccountingContext({token: address(token), decimals: 18, currency: uint32(uint160(address(token)))});
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
                baseCurrency: uint32(uint160(address(token))),
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
            _defifaProjectId,
            _protocolFeeProjectId
        );

        hook.transferOwnership(address(deployer));
        governor.transferOwnership(address(deployer));
    }

    // =========================================================================
    // LAUNCH DATA HELPERS
    // =========================================================================

    function _launchData(uint8 n, uint104 tierPrice) internal returns (DefifaLaunchProjectData memory) {
        return _launchDataWith(n, tierPrice, 0, 0);
    }

    function _launchDataWith(
        uint8 n,
        uint104 tierPrice,
        uint256 minParticipation,
        uint32 scorecardTimeout
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
            name: "DEFIFA_ERC20",
            projectUri: "",
            contractUri: "",
            baseUri: "",
            token: JBAccountingContext({
                token: address(token), decimals: 18, currency: uint32(uint160(address(token)))
            }),
            mintPeriodDuration: 1 days,
            start: uint48(block.timestamp + 3 days),
            refundPeriodDuration: 1 days,
            store: new JB721TiersHookStore(),
            splits: new JBSplit[](0),
            attestationStartTime: 0,
            attestationGracePeriod: 100_381,
            defaultAttestationDelegate: address(0),
            tierPrice: tierPrice,
            tiers: tp,
            defaultTokenUriResolver: IJB721TokenUriResolver(address(0)),
            terminal: jbMultiTerminal(),
            minParticipation: minParticipation,
            scorecardTimeout: scorecardTimeout
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
        return address(bytes20(keccak256(abi.encode("erc20_user", i))));
    }

    function _mintErc20(address user, uint256 tid, uint104 amt) internal {
        token.mint(user, amt);
        uint16[] memory m = new uint16[](1);
        // forge-lint: disable-next-line(unsafe-typecast)
        m[0] = uint16(tid);
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encode(user, m);
        bytes4[] memory ids = new bytes4[](1);
        ids[0] = metadataHelper().getId("pay", address(hook));
        vm.startPrank(user);
        token.approve(address(jbMultiTerminal()), amt);
        jbMultiTerminal().pay(_pid, address(token), amt, user, 0, "", metadataHelper().createMetadata(ids, data));
        vm.stopPrank();
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
        uint256 assigned;
        for (uint256 i; i < n; i++) {
            if (i == n - 1) {
                sc[i].cashOutWeight = tw - assigned;
            } else {
                sc[i].cashOutWeight = tw / n;
            }
            assigned += sc[i].cashOutWeight;
        }
    }

    function _attestAndRatify(DefifaTierCashOutWeight[] memory sc) internal {
        uint256 pid = _gov.submitScorecardFor(_gameId, sc);
        uint256 attestStart = _gov.attestationStartTimeOf(_gameId);
        uint256 current = _tsReader.timestamp();
        vm.warp((attestStart > current ? attestStart : current) + 1);
        for (uint256 i; i < _users.length; i++) {
            vm.prank(_users[i]);
            _gov.attestToScorecardFrom(_gameId, pid);
        }
        vm.warp(_tsReader.timestamp() + _gov.attestationGracePeriodOf(_gameId) + 1);
        _gov.ratifyScorecardFrom(_gameId, sc);
        vm.warp(_tsReader.timestamp() + 1);
    }

    function _toScoring() internal {
        vm.warp(_tsReader.timestamp() + 3 days + 1);
    }

    function _setupGame(uint8 nTiers, uint104 tierPrice) internal {
        DefifaLaunchProjectData memory d = _launchData(nTiers, tierPrice);
        (_pid, _nft, _gov) = _launch(d);
        vm.warp(d.start - d.mintPeriodDuration - d.refundPeriodDuration);
        _users = new address[](nTiers);
        for (uint256 i; i < nTiers; i++) {
            _users[i] = _addr(i);
            _mintErc20(_users[i], i + 1, tierPrice);
            _delegateSelf(_users[i], i + 1);
            vm.warp(_tsReader.timestamp() + 1);
        }
    }

    function _balance() internal view returns (uint256) {
        return jbMultiTerminal().STORE().balanceOf(address(jbMultiTerminal()), _pid, address(token));
    }

    function _generateTokenId(uint256 tierId, uint256 tokenNumber) internal pure returns (uint256) {
        return (tierId * 1_000_000_000) + tokenNumber;
    }

    function _buildCashOutMetadata(bytes memory decodedData) internal view returns (bytes memory) {
        bytes4[] memory ids = new bytes4[](1);
        ids[0] = metadataHelper().getId("cashOut", address(hook));
        bytes[] memory datas = new bytes[](1);
        datas[0] = decodedData;
        return metadataHelper().createMetadata(ids, datas);
    }

    function _cashOut(address user, uint256 tid, uint256 tnum) internal {
        uint256[] memory cashOutIds = new uint256[](1);
        cashOutIds[0] = _generateTokenId(tid, tnum);
        bytes memory cashOutMetadata = _buildCashOutMetadata(abi.encode(cashOutIds));

        vm.prank(user);
        JBMultiTerminal(address(jbMultiTerminal()))
            .cashOutTokensOf({
                holder: user,
                projectId: _pid,
                cashOutCount: 0,
                tokenToReclaim: address(token),
                minTokensReclaimed: 0,
                beneficiary: payable(user),
                metadata: cashOutMetadata
            });
    }

    function _refund(address user, uint256 tid) internal {
        JB721Tier memory tier = _nft.store().tierOf(address(_nft), tid, false);
        uint256 nb = _nft.store().numberOfBurnedFor(address(_nft), tid);
        uint256 tnum = tier.initialSupply - tier.remainingSupply + nb;
        _cashOut(user, tid, tnum);
    }

    // =========================================================================
    // TESTS
    // =========================================================================

    /// @notice ERC-20: Mint and verify NFT ownership and terminal balance.
    function test_erc20_mintAndBalance() external {
        uint104 tierPrice = 1 ether;
        _setupGame(4, tierPrice);

        // Verify MINT phase.
        assertEq(uint256(deployer.currentGamePhaseOf(_pid)), uint256(DefifaGamePhase.MINT));

        // All 4 users should hold NFTs.
        for (uint256 i; i < 4; i++) {
            assertEq(_nft.balanceOf(_users[i]), 1, "each user holds 1 NFT");
        }

        // Terminal should hold 4 ether worth of tokens.
        assertEq(_balance(), 4 ether, "terminal balance = 4 tokens");
    }

    /// @notice ERC-20: Refund during MINT phase returns exact mint price in ERC-20 tokens.
    function test_erc20_refundReturnsMintPrice() external {
        uint104 tierPrice = 1 ether;
        _setupGame(4, tierPrice);

        // Refund user 0 during MINT phase.
        uint256 balBefore = token.balanceOf(_users[0]);
        _refund(_users[0], 1);
        assertEq(token.balanceOf(_users[0]) - balBefore, 1 ether, "refund = 1 token");
        assertEq(_nft.balanceOf(_users[0]), 0, "NFT burned on refund");

        // Remaining balance = 3 tokens.
        assertEq(_balance(), 3 ether, "terminal balance after refund");
    }

    /// @notice ERC-20: Full scoring lifecycle -- scorecard ratification and cash-out distribution.
    function test_erc20_scorecardAndDistribute() external {
        uint104 tierPrice = 1 ether;
        _setupGame(4, tierPrice);

        _toScoring();

        // Tier 1 = 100% weight (winner takes all).
        DefifaTierCashOutWeight[] memory sc = _buildScorecard(4);
        sc[0].cashOutWeight = _nft.TOTAL_CASHOUT_WEIGHT();
        _attestAndRatify(sc);

        assertEq(uint256(deployer.currentGamePhaseOf(_pid)), uint256(DefifaGamePhase.COMPLETE));

        // Winner cashes out and receives ERC-20 tokens.
        uint256 winnerBalBefore = token.balanceOf(_users[0]);
        _cashOut(_users[0], 1, 1);
        uint256 winnerReceived = token.balanceOf(_users[0]) - winnerBalBefore;
        assertGt(winnerReceived, 0, "winner received tokens");

        // Losers get 0 tokens.
        for (uint256 i = 1; i < 4; i++) {
            uint256 bb = token.balanceOf(_users[i]);
            _cashOut(_users[i], i + 1, 1);
            assertEq(token.balanceOf(_users[i]), bb, "loser gets 0 tokens");
        }
    }

    /// @notice ERC-20: Fee accounting -- 7.5% fee (2.5% NANA + 5% DEFIFA).
    function test_erc20_feeAccounting() external {
        uint104 tierPrice = 1 ether;
        _setupGame(4, tierPrice);

        uint256 potBefore = _balance();
        assertEq(potBefore, 4 ether, "pot = 4 tokens");

        // Expected fee: 7.5%.
        uint256 expectedFee = (potBefore * 75_000_000) / JBConstants.SPLITS_TOTAL_PERCENT;
        uint256 expectedSurplus = potBefore - expectedFee;

        _toScoring();
        _attestAndRatify(_evenScorecard(4));

        uint256 potAfter = _balance();
        assertEq(potAfter, expectedSurplus, "surplus after fees = pot - 7.5%");

        uint256 fulfilled = deployer.fulfilledCommitmentsOf(_pid);
        assertEq(fulfilled, expectedFee, "fulfilled = fee amount");
        assertEq(fulfilled + potAfter, potBefore, "fee + surplus = original pot exactly");
    }

    /// @notice ERC-20: Even scorecard distributes equally among tiers.
    function test_erc20_evenDistribution() external {
        uint104 tierPrice = 1 ether;
        _setupGame(4, tierPrice);

        _toScoring();
        _attestAndRatify(_evenScorecard(4));

        // All users should receive roughly equal amounts.
        uint256[] memory received = new uint256[](4);
        for (uint256 i; i < 4; i++) {
            uint256 bb = token.balanceOf(_users[i]);
            _cashOut(_users[i], i + 1, 1);
            received[i] = token.balanceOf(_users[i]) - bb;
            assertGt(received[i], 0, "each user receives tokens");
        }

        // All should be within 1% of each other.
        for (uint256 i = 1; i < 4; i++) {
            assertApproxEqRel(received[0], received[i], 0.01 ether, "all users get roughly equal share");
        }
    }

    /// @notice ERC-20: No-contest mechanism works with ERC-20 (minParticipation threshold).
    function test_erc20_noContestMinParticipation() external {
        uint104 tierPrice = 1 ether;
        // 10 ether threshold, but only mint 1 ether total.
        DefifaLaunchProjectData memory d = _launchDataWith(4, tierPrice, 10 ether, 0);
        (_pid, _nft, _gov) = _launch(d);
        vm.warp(d.start - d.mintPeriodDuration - d.refundPeriodDuration);

        // Mint only 1 token.
        _users = new address[](1);
        _users[0] = _addr(0);
        _mintErc20(_users[0], 1, tierPrice);

        _toScoring();

        // Balance = 1 token < 10 tokens threshold -> NO_CONTEST.
        assertEq(uint256(deployer.currentGamePhaseOf(_pid)), uint256(DefifaGamePhase.NO_CONTEST));
    }

    /// @notice ERC-20: No-contest with trigger and refund returns exact mint price in ERC-20.
    function test_erc20_noContestRefund() external {
        uint104 tierPrice = 1 ether;
        DefifaLaunchProjectData memory d = _launchDataWith(4, tierPrice, 10 ether, 0);
        (_pid, _nft, _gov) = _launch(d);
        vm.warp(d.start - d.mintPeriodDuration - d.refundPeriodDuration);

        _users = new address[](2);
        _users[0] = _addr(0);
        _users[1] = _addr(1);
        _mintErc20(_users[0], 1, tierPrice);
        _mintErc20(_users[1], 2, tierPrice);

        _toScoring();

        // Confirm NO_CONTEST.
        assertEq(uint256(deployer.currentGamePhaseOf(_pid)), uint256(DefifaGamePhase.NO_CONTEST));

        // Trigger no-contest to queue a ruleset without payout limits.
        deployer.triggerNoContestFor(_pid);

        // Cash out should return exactly 1 ether of ERC-20.
        uint256 balBefore = token.balanceOf(_users[0]);
        _refund(_users[0], 1);
        uint256 received = token.balanceOf(_users[0]) - balBefore;
        assertEq(received, 1 ether, "should receive exact mint price in ERC-20");
        assertEq(_nft.balanceOf(_users[0]), 0, "NFT should be burned");
    }

    /// @notice ERC-20: Pot reporting works correctly with ERC-20 tokens.
    function test_erc20_potCalculation() external {
        uint104 tierPrice = 1 ether;
        _setupGame(4, tierPrice);

        _toScoring();

        (uint256 potExcluding,,) = deployer.currentGamePotOf(_pid, false);
        (uint256 potIncluding,,) = deployer.currentGamePotOf(_pid, true);
        assertEq(potExcluding, 4 ether, "pot excluding = 4 tokens");
        assertEq(potIncluding, 4 ether, "pot including = 4 tokens (no fulfillment yet)");

        _attestAndRatify(_evenScorecard(4));

        uint256 fee = deployer.fulfilledCommitmentsOf(_pid);
        (potExcluding,,) = deployer.currentGamePotOf(_pid, false);
        (potIncluding,,) = deployer.currentGamePotOf(_pid, true);
        assertEq(potExcluding, 4 ether - fee, "pot excluding = surplus");
        assertEq(potIncluding, 4 ether, "pot including = original pot");
    }
}

// =============================================================================
// GAP 2: MULTI-GAME GOVERNOR ISOLATION
// =============================================================================

/// @title TestAuditGapsMultiGameIsolation
/// @notice Tests that multiple simultaneous Defifa games are properly isolated.
/// Ensures governor actions on one game (scorecard submission, attestation,
/// ratification) do not affect the other game.
contract TestAuditGapsMultiGameIsolation is JBTest, TestBaseWorkflow {
    using JBRulesetMetadataResolver for JBRuleset;

    AuditGapsTimestampReader private _tsReader;

    address _protocolFeeProjectTokenAccount;
    address _defifaProjectTokenAccount;
    uint256 _protocolFeeProjectId;
    uint256 _defifaProjectId;

    DefifaDeployer deployer;
    DefifaHook hook;
    DefifaGovernor governor;
    address projectOwner = address(bytes20(keccak256("projectOwner")));

    // Game A state.
    uint256 pidA;
    DefifaHook nftA;
    uint256 gameIdA;
    address[] usersA;

    // Game B state.
    uint256 pidB;
    DefifaHook nftB;
    uint256 gameIdB;
    address[] usersB;

    function setUp() public virtual override {
        super.setUp();

        _tsReader = new AuditGapsTimestampReader();

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
            _defifaProjectId,
            _protocolFeeProjectId
        );
        hook.transferOwnership(address(deployer));
        governor.transferOwnership(address(deployer));
    }

    // =========================================================================
    // HELPERS
    // =========================================================================

    function _launchData(uint8 n) internal returns (DefifaLaunchProjectData memory) {
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
            tierPrice: 1 ether,
            tiers: tp,
            defaultTokenUriResolver: IJB721TokenUriResolver(address(0)),
            terminal: jbMultiTerminal(),
            minParticipation: 0,
            scorecardTimeout: 0
        });
    }

    function _launchGame(DefifaLaunchProjectData memory d) internal returns (uint256 p, DefifaHook n) {
        p = deployer.launchGameWith(d);
        JBRuleset memory fc = jbRulesets().currentOf(p);
        if (fc.dataHook() == address(0)) (fc,) = jbRulesets().latestQueuedOf(p);
        n = DefifaHook(fc.dataHook());
    }

    function _addrA(uint256 i) internal pure returns (address) {
        return address(bytes20(keccak256(abi.encode("gameA_user", i))));
    }

    function _addrB(uint256 i) internal pure returns (address) {
        return address(bytes20(keccak256(abi.encode("gameB_user", i))));
    }

    function _mint(address user, uint256 pid, uint256 tid, uint256 amt) internal {
        vm.deal(user, amt);
        uint16[] memory m = new uint16[](1);
        // forge-lint: disable-next-line(unsafe-typecast)
        m[0] = uint16(tid);
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encode(user, m);
        bytes4[] memory ids = new bytes4[](1);
        ids[0] = metadataHelper().getId("pay", address(hook));
        vm.prank(user);
        jbMultiTerminal().pay{value: amt}(
            pid, JBConstants.NATIVE_TOKEN, amt, user, 0, "", metadataHelper().createMetadata(ids, data)
        );
    }

    function _delegateSelf(DefifaHook nft, address user, uint256 tid) internal {
        DefifaDelegation[] memory dd = new DefifaDelegation[](1);
        dd[0] = DefifaDelegation({delegatee: user, tierId: tid});
        vm.prank(user);
        nft.setTierDelegatesTo(dd);
    }

    function _buildScorecard(uint256 n) internal pure returns (DefifaTierCashOutWeight[] memory sc) {
        sc = new DefifaTierCashOutWeight[](n);
        for (uint256 i; i < n; i++) {
            sc[i].id = i + 1;
        }
    }

    function _evenScorecard(DefifaHook nft, uint256 n) internal view returns (DefifaTierCashOutWeight[] memory sc) {
        sc = _buildScorecard(n);
        uint256 tw = nft.TOTAL_CASHOUT_WEIGHT();
        uint256 assigned;
        for (uint256 i; i < n; i++) {
            if (i == n - 1) {
                sc[i].cashOutWeight = tw - assigned;
            } else {
                sc[i].cashOutWeight = tw / n;
            }
            assigned += sc[i].cashOutWeight;
        }
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

    function _cashOut(address user, uint256 pid, uint256 tid, uint256 tnum) internal {
        bytes memory meta = _cashOutMeta(tid, tnum);
        vm.prank(user);
        JBMultiTerminal(address(jbMultiTerminal()))
            .cashOutTokensOf({
                holder: user,
                projectId: pid,
                cashOutCount: 0,
                tokenToReclaim: JBConstants.NATIVE_TOKEN,
                minTokensReclaimed: 0,
                beneficiary: payable(user),
                metadata: meta
            });
    }

    /// @dev Deploy both games and mint NFTs for both. Game A has 4 tiers, Game B has 3 tiers.
    function _setupBothGames() internal {
        DefifaLaunchProjectData memory dA = _launchData(4);
        (pidA, nftA) = _launchGame(dA);
        gameIdA = pidA;

        DefifaLaunchProjectData memory dB = _launchData(3);
        (pidB, nftB) = _launchGame(dB);
        gameIdB = pidB;

        // Warp to the MINT phase for both games (they share the same start window).
        vm.warp(dA.start - dA.mintPeriodDuration - dA.refundPeriodDuration);

        // Mint for Game A: 4 users, 1 per tier.
        usersA = new address[](4);
        for (uint256 i; i < 4; i++) {
            usersA[i] = _addrA(i);
            _mint(usersA[i], pidA, i + 1, 1 ether);
            _delegateSelf(nftA, usersA[i], i + 1);
            vm.warp(_tsReader.timestamp() + 1);
        }

        // Mint for Game B: 3 users, 1 per tier.
        usersB = new address[](3);
        for (uint256 i; i < 3; i++) {
            usersB[i] = _addrB(i);
            _mint(usersB[i], pidB, i + 1, 1 ether);
            _delegateSelf(nftB, usersB[i], i + 1);
            vm.warp(_tsReader.timestamp() + 1);
        }
    }

    function _attestAndRatify(uint256 gameId, address[] memory users, DefifaTierCashOutWeight[] memory sc) internal {
        uint256 pid = governor.submitScorecardFor(gameId, sc);
        uint256 attestStart = governor.attestationStartTimeOf(gameId);
        uint256 current = _tsReader.timestamp();
        vm.warp((attestStart > current ? attestStart : current) + 1);
        for (uint256 i; i < users.length; i++) {
            vm.prank(users[i]);
            governor.attestToScorecardFrom(gameId, pid);
        }
        vm.warp(_tsReader.timestamp() + governor.attestationGracePeriodOf(gameId) + 1);
        governor.ratifyScorecardFrom(gameId, sc);
        vm.warp(_tsReader.timestamp() + 1);
    }

    // =========================================================================
    // TESTS
    // =========================================================================

    /// @notice Both games can be launched and are in independent project IDs.
    function test_multiGame_independentProjectIds() external {
        _setupBothGames();

        assertFalse(pidA == pidB, "game IDs should be different");
        assertEq(uint256(deployer.currentGamePhaseOf(pidA)), uint256(DefifaGamePhase.MINT), "Game A in MINT");
        assertEq(uint256(deployer.currentGamePhaseOf(pidB)), uint256(DefifaGamePhase.MINT), "Game B in MINT");
    }

    /// @notice Each game has independent treasury balances.
    function test_multiGame_independentBalances() external {
        _setupBothGames();

        uint256 balA = jbMultiTerminal().STORE().balanceOf(address(jbMultiTerminal()), pidA, JBConstants.NATIVE_TOKEN);
        uint256 balB = jbMultiTerminal().STORE().balanceOf(address(jbMultiTerminal()), pidB, JBConstants.NATIVE_TOKEN);

        assertEq(balA, 4 ether, "Game A balance = 4 ETH (4 minters)");
        assertEq(balB, 3 ether, "Game B balance = 3 ETH (3 minters)");
    }

    /// @notice Each game has independent NFT hooks.
    function test_multiGame_independentNFTHooks() external {
        _setupBothGames();

        // The hooks should be different contracts.
        assertFalse(address(nftA) == address(nftB), "hooks should be different contracts");

        // Game A has 4 tiers, Game B has 3 tiers.
        assertEq(nftA.store().maxTierIdOf(address(nftA)), 4, "Game A has 4 tiers");
        assertEq(nftB.store().maxTierIdOf(address(nftB)), 3, "Game B has 3 tiers");

        // Game A users should not own tokens in Game B and vice versa.
        for (uint256 i; i < 4; i++) {
            assertEq(nftA.balanceOf(usersA[i]), 1, "Game A user has 1 NFT in Game A");
            assertEq(nftB.balanceOf(usersA[i]), 0, "Game A user has 0 NFTs in Game B");
        }
        for (uint256 i; i < 3; i++) {
            assertEq(nftB.balanceOf(usersB[i]), 1, "Game B user has 1 NFT in Game B");
            assertEq(nftA.balanceOf(usersB[i]), 0, "Game B user has 0 NFTs in Game A");
        }
    }

    /// @notice Ratifying Game A's scorecard does not affect Game B's phase.
    function test_multiGame_ratifyOneDoesNotAffectOther() external {
        _setupBothGames();

        // Advance to scoring phase for both.
        vm.warp(_tsReader.timestamp() + 3 days + 1);

        assertEq(uint256(deployer.currentGamePhaseOf(pidA)), uint256(DefifaGamePhase.SCORING), "Game A SCORING");
        assertEq(uint256(deployer.currentGamePhaseOf(pidB)), uint256(DefifaGamePhase.SCORING), "Game B SCORING");

        // Ratify Game A's scorecard.
        _attestAndRatify(gameIdA, usersA, _evenScorecard(nftA, 4));

        // Game A should be COMPLETE.
        assertEq(uint256(deployer.currentGamePhaseOf(pidA)), uint256(DefifaGamePhase.COMPLETE), "Game A COMPLETE");

        // Game B should still be in SCORING -- not affected by Game A's ratification.
        assertEq(uint256(deployer.currentGamePhaseOf(pidB)), uint256(DefifaGamePhase.SCORING), "Game B still SCORING");

        // Game B's ratified scorecard should still be zero.
        assertEq(governor.ratifiedScorecardIdOf(gameIdB), 0, "Game B has no ratified scorecard");
    }

    /// @notice Both games can independently complete their full lifecycles.
    function test_multiGame_bothCompleteIndependently() external {
        _setupBothGames();

        // Advance to scoring.
        vm.warp(_tsReader.timestamp() + 3 days + 1);

        // Ratify Game A: tier 1 wins all.
        DefifaTierCashOutWeight[] memory scA = _buildScorecard(4);
        scA[0].cashOutWeight = nftA.TOTAL_CASHOUT_WEIGHT();
        _attestAndRatify(gameIdA, usersA, scA);

        assertEq(uint256(deployer.currentGamePhaseOf(pidA)), uint256(DefifaGamePhase.COMPLETE), "Game A COMPLETE");

        // Ratify Game B: even distribution.
        _attestAndRatify(gameIdB, usersB, _evenScorecard(nftB, 3));

        assertEq(uint256(deployer.currentGamePhaseOf(pidB)), uint256(DefifaGamePhase.COMPLETE), "Game B COMPLETE");

        // Cash out from Game A: winner gets tokens.
        uint256 bbA = usersA[0].balance;
        _cashOut(usersA[0], pidA, 1, 1);
        assertGt(usersA[0].balance - bbA, 0, "Game A winner received ETH");

        // Cash out from Game B: all get roughly equal share.
        uint256 bbB0 = usersB[0].balance;
        _cashOut(usersB[0], pidB, 1, 1);
        uint256 receivedB0 = usersB[0].balance - bbB0;
        assertGt(receivedB0, 0, "Game B user 0 received ETH");

        uint256 bbB1 = usersB[1].balance;
        _cashOut(usersB[1], pidB, 2, 1);
        uint256 receivedB1 = usersB[1].balance - bbB1;
        assertGt(receivedB1, 0, "Game B user 1 received ETH");
        assertApproxEqRel(receivedB0, receivedB1, 0.01 ether, "Game B users get roughly equal share");
    }

    /// @notice Game A's scorecard submission does not affect Game B, and vice versa.
    function test_multiGame_scorecardSubmissionIsolated() external {
        _setupBothGames();

        // Advance to scoring.
        vm.warp(_tsReader.timestamp() + 3 days + 1);

        // Submit a scorecard for Game A only.
        DefifaTierCashOutWeight[] memory scA = _evenScorecard(nftA, 4);
        uint256 scorecardIdA = governor.submitScorecardFor(gameIdA, scA);

        // The scorecard should be known for Game A.
        // stateOf should not revert for Game A's scorecard.
        governor.stateOf(gameIdA, scorecardIdA);

        // The same scorecardId should be unknown for Game B (different hooks produce different hashes).
        // Trying to query it on Game B should revert.
        vm.expectRevert(DefifaGovernor.DefifaGovernor_UnknownProposal.selector);
        governor.stateOf(gameIdB, scorecardIdA);
    }

    /// @notice Game A users' attestation power is zero in Game B (different hooks).
    function test_multiGame_attestationPowerIsolated() external {
        _setupBothGames();

        // Advance to scoring.
        vm.warp(_tsReader.timestamp() + 3 days + 1);

        // Game A user 0 has attestation power in Game A.
        uint256 powerA = governor.getAttestationWeight(gameIdA, usersA[0], uint48(_tsReader.timestamp()));
        assertGt(powerA, 0, "Game A user has power in Game A");

        // Game A user 0 has NO attestation power in Game B (they don't hold Game B NFTs).
        uint256 powerB = governor.getAttestationWeight(gameIdB, usersA[0], uint48(_tsReader.timestamp()));
        assertEq(powerB, 0, "Game A user has no power in Game B");

        // Game B user 0 has attestation power in Game B.
        uint256 powerB0 = governor.getAttestationWeight(gameIdB, usersB[0], uint48(_tsReader.timestamp()));
        assertGt(powerB0, 0, "Game B user has power in Game B");

        // Game B user 0 has NO attestation power in Game A.
        uint256 powerA0 = governor.getAttestationWeight(gameIdA, usersB[0], uint48(_tsReader.timestamp()));
        assertEq(powerA0, 0, "Game B user has no power in Game A");
    }

    /// @notice Each game tracks fulfilled commitments independently.
    function test_multiGame_fulfilledCommitmentsIsolated() external {
        _setupBothGames();

        // Advance to scoring.
        vm.warp(_tsReader.timestamp() + 3 days + 1);

        // Ratify and fulfill Game A only.
        _attestAndRatify(gameIdA, usersA, _evenScorecard(nftA, 4));
        assertGt(deployer.fulfilledCommitmentsOf(pidA), 0, "Game A has fulfilled commitments");
        assertEq(deployer.fulfilledCommitmentsOf(pidB), 0, "Game B has no fulfilled commitments yet");

        // Now ratify and fulfill Game B.
        _attestAndRatify(gameIdB, usersB, _evenScorecard(nftB, 3));
        assertGt(deployer.fulfilledCommitmentsOf(pidB), 0, "Game B has fulfilled commitments");

        // Both fulfilled but independently.
        assertFalse(
            deployer.fulfilledCommitmentsOf(pidA) == deployer.fulfilledCommitmentsOf(pidB),
            "fulfilled amounts differ because game pots differ"
        );
    }

    /// @notice Quorum values are independent for each game.
    function test_multiGame_quorumIsolated() external {
        _setupBothGames();

        // Advance to scoring.
        vm.warp(_tsReader.timestamp() + 3 days + 1);

        uint256 quorumA = governor.quorum(gameIdA);
        uint256 quorumB = governor.quorum(gameIdB);

        // Game A has 4 minted tiers, Game B has 3 minted tiers.
        // Quorum = 50% of minted tiers * MAX_ATTESTATION_POWER_TIER.
        assertGt(quorumA, quorumB, "Game A quorum > Game B quorum (more tiers)");
        assertEq(quorumA, 4 * governor.MAX_ATTESTATION_POWER_TIER() / 2, "Game A quorum = 4 tiers * 50%");
        assertEq(quorumB, 3 * governor.MAX_ATTESTATION_POWER_TIER() / 2, "Game B quorum = 3 tiers * 50%");
    }
}
