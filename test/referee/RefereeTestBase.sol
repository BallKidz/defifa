// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {DefifaGovernor} from "../../src/DefifaGovernor.sol";
import {DefifaDeployer} from "../../src/DefifaDeployer.sol";
import {DefifaHook} from "../../src/DefifaHook.sol";
import {Defifa1155Hook} from "../../src/Defifa1155Hook.sol";
import {DefifaTokenUriResolver} from "../../src/DefifaTokenUriResolver.sol";
import {DefifaTiersHookStore} from "../../src/DefifaTiersHookStore.sol";
import {IDefifaHook} from "../../src/interfaces/IDefifaHook.sol";
import {JB721TiersHookStore} from "@bananapus/721-hook-v6/src/JB721TiersHookStore.sol";
import {IJB721TiersHookStore} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHookStore.sol";

import {TestBaseWorkflow} from "@bananapus/core-v6/test/helpers/TestBaseWorkflow.sol";
import {JBTest} from "@bananapus/core-v6/test/helpers/JBTest.sol";
import {JBRulesetMetadataResolver} from "@bananapus/core-v6/src/libraries/JBRulesetMetadataResolver.sol";
import {JBAddressRegistry} from "@bananapus/address-registry-v6/src/JBAddressRegistry.sol";

import {IJB721TokenUriResolver} from "@bananapus/721-hook-v6/src/interfaces/IJB721TokenUriResolver.sol";
import {DefifaDelegation} from "../../src/structs/DefifaDelegation.sol";
import {DefifaLaunchProjectData} from "../../src/structs/DefifaLaunchProjectData.sol";
import {DefifaTierParams} from "../../src/structs/DefifaTierParams.sol";
import {DefifaTierCashOutWeight} from "../../src/structs/DefifaTierCashOutWeight.sol";
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

/// @notice Launches Defifa games of either hook type for the referee suites.
abstract contract RefereeTestBase is JBTest, TestBaseWorkflow {
    using JBRulesetMetadataResolver for JBRuleset;

    DefifaDeployer deployer;
    DefifaGovernor governor;
    address hookOrigin;
    address projectOwner = address(bytes20(keccak256("projectOwner")));

    uint256 gameId;
    IDefifaHook game;

    /// @notice Whether the suite runs the 1155 game.
    function _is1155() internal pure virtual returns (bool);

    function setUp() public virtual override {
        super.setUp();

        JBAccountingContext[] memory tokens = new JBAccountingContext[](1);
        tokens[0] = JBAccountingContext({token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: JBCurrencyIds.ETH});
        JBTerminalConfig[] memory tc = new JBTerminalConfig[](1);
        tc[0] = JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: tokens});
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

        uint256 feeProjectId = jbController().launchProjectFor(projectOwner, "", rc, tc, "");
        vm.prank(projectOwner);
        jbController().deployERC20For(feeProjectId, "Bananapus", "NANA", bytes32(0));
        uint256 defifaProjectId = jbController().launchProjectFor(projectOwner, "", rc, tc, "");
        vm.prank(projectOwner);
        jbController().deployERC20For(defifaProjectId, "Defifa", "DEFIFA", bytes32(0));

        IJB721TiersHookStore store;
        if (_is1155()) {
            Defifa1155Hook h = new Defifa1155Hook(jbDirectory(), jbTokens(), defifaProjectId, feeProjectId);
            hookOrigin = address(h);
            store = IJB721TiersHookStore(address(new DefifaTiersHookStore()));
        } else {
            DefifaHook h = new DefifaHook(jbDirectory(), jbTokens(), defifaProjectId, feeProjectId);
            hookOrigin = address(h);
            store = IJB721TiersHookStore(address(new JB721TiersHookStore()));
        }

        governor = new DefifaGovernor(jbController(), address(this));
        deployer = new DefifaDeployer({
            hookCodeOrigin: hookOrigin,
            tokenUriResolver: new DefifaTokenUriResolver(address(this)),
            governor: governor,
            controller: jbController(),
            registry: new JBAddressRegistry(),
            defifaProjectId: defifaProjectId,
            baseProtocolProjectId: feeProjectId,
            hookStore: store,
            trustedForwarder: address(0)
        });
        // forge-lint: disable-next-line(unsafe-typecast)
        DefifaHook(hookOrigin).transferOwnership(address(deployer));
        governor.transferOwnership(address(deployer));
    }

    /// @notice Launch data for an `n`-tier game at 1 ETH a token, judged by `referee`.
    function _launchData(
        uint8 n,
        address referee,
        bytes memory refereeData,
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
            defaultAttestationDelegate: address(0),
            tierPrice: 1 ether,
            tiers: tp,
            defaultTokenUriResolver: IJB721TokenUriResolver(address(0)),
            terminal: jbMultiTerminal(),
            minParticipation: 0,
            scorecardTimeout: 30 days,
            timelockDuration: timelockDuration,
            referee: referee,
            refereeData: refereeData
        });
    }

    /// @notice Launch a game and move to its mint phase.
    function _launch(DefifaLaunchProjectData memory d) internal {
        gameId = deployer.launchGameWith(d);
        JBRuleset memory fc = jbRulesets().currentOf(gameId);
        if (fc.dataHook() == address(0)) (fc,) = jbRulesets().latestQueuedOf(gameId);
        game = IDefifaHook(fc.dataHook());
        vm.warp(d.start - d.mintPeriodDuration - d.refundPeriodDuration);
    }

    /// @notice A deterministic test address.
    function _addr(uint256 i) internal pure returns (address) {
        return address(bytes20(keccak256(abi.encode("referee-user", i))));
    }

    /// @notice Mint one token of a tier to `user` and delegate its attestation to `user`.
    function _mint(address user, uint256 tierId) internal {
        vm.deal(user, 1 ether);
        uint16[] memory m = new uint16[](1);
        // forge-lint: disable-next-line(unsafe-typecast)
        m[0] = uint16(tierId);
        bytes[] memory data = new bytes[](1);
        if (_is1155()) {
            uint256[] memory counts = new uint256[](1);
            counts[0] = 1;
            data[0] = abi.encode(user, m, counts);
        } else {
            data[0] = abi.encode(user, m);
        }
        bytes4[] memory ids = new bytes4[](1);
        ids[0] = metadataHelper().getId("pay", hookOrigin);
        vm.prank(user);
        jbMultiTerminal().pay{value: 1 ether}(
            gameId, JBConstants.NATIVE_TOKEN, 1 ether, user, 0, "", metadataHelper().createMetadata(ids, data)
        );

        DefifaDelegation[] memory dd = new DefifaDelegation[](1);
        dd[0] = DefifaDelegation({delegatee: user, tierId: tierId});
        vm.prank(user);
        game.setTierDelegatesTo(dd);
    }

    /// @notice Warp from the mint phase into scoring.
    function _toScoring() internal {
        vm.warp(block.timestamp + 3 days + 1);
    }

    /// @notice A scorecard giving every cash-out weight to `winner` among `n` tiers.
    function _winnerTakeAll(uint256 n, uint256 winner) internal view returns (DefifaTierCashOutWeight[] memory sc) {
        sc = new DefifaTierCashOutWeight[](n);
        for (uint256 i; i < n; i++) {
            sc[i].id = i + 1;
            if (i + 1 == winner) sc[i].cashOutWeight = game.TOTAL_CASHOUT_WEIGHT();
        }
    }

    /// @notice A scorecard splitting the cash-out weight evenly across `n` tiers.
    function _even(uint256 n) internal view returns (DefifaTierCashOutWeight[] memory sc) {
        sc = new DefifaTierCashOutWeight[](n);
        uint256 total = game.TOTAL_CASHOUT_WEIGHT();
        for (uint256 i; i < n; i++) {
            sc[i].id = i + 1;
            sc[i].cashOutWeight = total / n;
        }
        sc[n - 1].cashOutWeight += total - (total / n) * n;
    }
}
