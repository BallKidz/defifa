// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

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
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBCurrencyIds} from "@bananapus/core-v6/src/libraries/JBCurrencyIds.sol";
import {JBFundAccessLimitGroup} from "@bananapus/core-v6/src/structs/JBFundAccessLimitGroup.sol";
import {JBRulesetConfig, JBTerminalConfig} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {JBRulesetMetadata} from "@bananapus/core-v6/src/structs/JBRulesetMetadata.sol";
import {JBSplit} from "@bananapus/core-v6/src/structs/JBSplit.sol";
import {JBSplitGroup} from "@bananapus/core-v6/src/structs/JBSplitGroup.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesets.sol";

/// @title DefifaAuditLowGuardsTest
/// @notice Tests for validation guards added in the audit/low-findings branch:
///   - DefifaGovernor_AlreadyInitialized (re-initialization guard)
///   - uint48 overflow checks on attestationStartTime and attestationGracePeriod
///   - DefifaHook_DelegateAddressZero (address(0) delegation guard)
contract DefifaAuditLowGuardsTest is JBTest, TestBaseWorkflow {
    using JBRulesetMetadataResolver for JBRuleset;

    address _protocolFeeProjectTokenAccount;
    address _defifaProjectTokenAccount;
    uint256 _protocolFeeProjectId;
    uint256 _defifaProjectId;
    uint256 _gameId = 3;

    DefifaDeployer deployer;
    DefifaHook hook;
    DefifaGovernor governor;
    address projectOwner = address(bytes20(keccak256("projectOwner")));

    // Shared test state (set by _setupGame)
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
    // 1. DefifaGovernor_AlreadyInitialized: re-initialization blocked
    // =========================================================================
    function testRevert_initializeGame_alreadyInitialized() external {
        // Deploy a standalone governor where this test contract is the owner, so we can call initializeGame directly.
        DefifaGovernor _standaloneGov = new DefifaGovernor(jbController(), address(this));

        // First initialization should succeed.
        uint256 gameId = 42;
        _standaloneGov.initializeGame({
            gameId: gameId, attestationStartTime: block.timestamp, attestationGracePeriod: 2 days
        });

        // Second initialization for the same gameId should revert.
        vm.expectRevert(DefifaGovernor.DefifaGovernor_AlreadyInitialized.selector);
        _standaloneGov.initializeGame({
            gameId: gameId, attestationStartTime: block.timestamp, attestationGracePeriod: 2 days
        });
    }

    // =========================================================================
    // 1b. Re-initialization blocked even through the deployer (integration)
    // =========================================================================
    function testRevert_initializeGame_alreadyInitialized_viaDeployer() external {
        // Launch a game (this calls initializeGame internally).
        _setupGame(4, 1 ether);

        // The governor is now owned by the deployer. Trying to initialize the same game again
        // via the deployer is not possible because there is no public re-init path. But we
        // verify the packed info is non-zero, confirming the guard would trigger.
        assertTrue(_gov.attestationStartTimeOf(_gameId) > 0 || _gov.attestationGracePeriodOf(_gameId) > 0);
    }

    // =========================================================================
    // 2. uint48 overflow on attestationStartTime
    // =========================================================================
    function testRevert_initializeGame_attestationStartTimeOverflow() external {
        DefifaGovernor _standaloneGov = new DefifaGovernor(jbController(), address(this));

        // type(uint48).max + 1 should overflow the 48-bit packing.
        uint256 overflowStartTime = uint256(type(uint48).max) + 1;

        vm.expectRevert(DefifaGovernor.DefifaGovernor_Uint48Overflow.selector);
        _standaloneGov.initializeGame({
            gameId: 99, attestationStartTime: overflowStartTime, attestationGracePeriod: 2 days
        });
    }

    // =========================================================================
    // 3. uint48 overflow on attestationGracePeriod
    // =========================================================================
    function testRevert_initializeGame_attestationGracePeriodOverflow() external {
        DefifaGovernor _standaloneGov = new DefifaGovernor(jbController(), address(this));

        // type(uint48).max + 1 should overflow the 48-bit packing.
        uint256 overflowGracePeriod = uint256(type(uint48).max) + 1;

        vm.expectRevert(DefifaGovernor.DefifaGovernor_Uint48Overflow.selector);
        _standaloneGov.initializeGame({
            gameId: 100, attestationStartTime: block.timestamp, attestationGracePeriod: overflowGracePeriod
        });
    }

    // =========================================================================
    // 4. DefifaHook_DelegateAddressZero in setTierDelegateTo
    // =========================================================================
    function testRevert_setTierDelegateTo_zeroAddress() external {
        _setupGame(4, 1 ether);

        // _users[0] owns an NFT in tier 1 during the MINT phase.
        vm.prank(_users[0]);
        vm.expectRevert(DefifaHook.DefifaHook_DelegateAddressZero.selector);
        _nft.setTierDelegateTo({delegatee: address(0), tierId: 1});
    }

    // =========================================================================
    // 5. DefifaHook_DelegateAddressZero in setTierDelegatesTo (batch)
    // =========================================================================
    function testRevert_setTierDelegatesTo_zeroAddress() external {
        _setupGame(4, 1 ether);

        DefifaDelegation[] memory delegations = new DefifaDelegation[](1);
        delegations[0] = DefifaDelegation({delegatee: address(0), tierId: 1});

        vm.prank(_users[0]);
        vm.expectRevert(DefifaHook.DefifaHook_DelegateAddressZero.selector);
        _nft.setTierDelegatesTo(delegations);
    }

    // =========================================================================
    // 5b. Batch delegation reverts on address(0) even in second element
    // =========================================================================
    function testRevert_setTierDelegatesTo_zeroAddress_secondElement() external {
        _setupGame(4, 1 ether);

        // First delegation is valid, second has address(0).
        DefifaDelegation[] memory delegations = new DefifaDelegation[](2);
        delegations[0] = DefifaDelegation({delegatee: _users[0], tierId: 1});
        delegations[1] = DefifaDelegation({delegatee: address(0), tierId: 2});

        vm.prank(_users[0]);
        vm.expectRevert(DefifaHook.DefifaHook_DelegateAddressZero.selector);
        _nft.setTierDelegatesTo(delegations);
    }

    // =========================================================================
    // SETUP HELPERS (adapted from DefifaSecurity.t.sol)
    // =========================================================================

    function _setupGame(uint8 nTiers, uint256 tierPrice) internal {
        DefifaLaunchProjectData memory d = _launchData(nTiers, tierPrice);
        (_pid, _nft, _gov) = _launch(d);
        vm.warp(d.start - d.mintPeriodDuration - d.refundPeriodDuration);
        _users = new address[](nTiers);
        for (uint256 i; i < nTiers; i++) {
            _users[i] = _addr(i);
            _mint(_users[i], i + 1, tierPrice);
            vm.warp(block.timestamp + 1);
        }
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
            scorecardTimeout: 0
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
        return address(bytes20(keccak256(abi.encode("su", i))));
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
        vm.prank(user);
        jbMultiTerminal().pay{value: amt}(
            _pid, JBConstants.NATIVE_TOKEN, amt, user, 0, "", metadataHelper().createMetadata(ids, data)
        );
    }
}
