// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {DefifaFeeAccountingTest} from "../DefifaFeeAccounting.t.sol";
import {DefifaGovernor} from "../../src/DefifaGovernor.sol";
import {DefifaHook} from "../../src/DefifaHook.sol";
import {DefifaDelegation} from "../../src/structs/DefifaDelegation.sol";
import {DefifaLaunchProjectData} from "../../src/structs/DefifaLaunchProjectData.sol";
import {DefifaTierParams} from "../../src/structs/DefifaTierParams.sol";

import {IJB721TokenUriResolver} from "@bananapus/721-hook-v6/src/interfaces/IJB721TokenUriResolver.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBMultiTerminal} from "@bananapus/core-v6/src/JBMultiTerminal.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBCurrencyIds} from "@bananapus/core-v6/src/libraries/JBCurrencyIds.sol";
import {JBSplit} from "@bananapus/core-v6/src/structs/JBSplit.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract CodexNemesisBeneficiaryMismatchTest is DefifaFeeAccountingTest {
    function test_codexNemesis_cashOutFeeTokensGoToBeneficiary() external {
        DefifaLaunchProjectData memory defifaData = _getDefifaLaunchDataWithSplits(4, new JBSplit[](0));
        (uint256 projectId, DefifaHook nft, DefifaGovernor gov) = _createDefifaProject(defifaData);

        vm.warp(defifaData.start - defifaData.mintPeriodDuration - defifaData.refundPeriodDuration);
        address[] memory users = _mintAllTiers(nft, gov, projectId, 4);
        _ratifyEvenScorecard(users, nft, gov, projectId, 4);

        address holder = users[0];
        address payable beneficiary = payable(address(bytes20(keccak256("cashout beneficiary"))));

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = _generateTokenId(1, 1);
        bytes memory cashOutMetadata = _buildCashOutMetadata(abi.encode(tokenIds));

        (uint256 expectedDefifa, uint256 expectedNana) = nft.tokensClaimableFor(tokenIds);
        IERC20 defifaToken = IERC20(address(jbTokens().tokenOf(_defifaProjectId)));
        IERC20 nanaToken = IERC20(address(jbTokens().tokenOf(_protocolFeeProjectId)));

        uint256 holderDefifaBefore = defifaToken.balanceOf(holder);
        uint256 holderNanaBefore = nanaToken.balanceOf(holder);
        uint256 beneficiaryDefifaBefore = defifaToken.balanceOf(beneficiary);
        uint256 beneficiaryNanaBefore = nanaToken.balanceOf(beneficiary);
        uint256 beneficiaryEthBefore = beneficiary.balance;

        vm.prank(holder);
        JBMultiTerminal(address(jbMultiTerminal()))
            .cashOutTokensOf({
            holder: holder,
            projectId: projectId,
            cashOutCount: 0,
            tokenToReclaim: JBConstants.NATIVE_TOKEN,
            minTokensReclaimed: 0,
            beneficiary: beneficiary,
            metadata: cashOutMetadata
        });

        assertGt(beneficiary.balance, beneficiaryEthBefore, "terminal reclaim goes to beneficiary");
        assertEq(defifaToken.balanceOf(holder), holderDefifaBefore, "holder receives no DEFIFA fee tokens");
        assertEq(nanaToken.balanceOf(holder), holderNanaBefore, "holder receives no NANA fee tokens");
        assertEq(
            defifaToken.balanceOf(beneficiary),
            beneficiaryDefifaBefore + expectedDefifa,
            "beneficiary receives DEFIFA fee tokens"
        );
        assertEq(
            nanaToken.balanceOf(beneficiary),
            beneficiaryNanaBefore + expectedNana,
            "beneficiary receives NANA fee tokens"
        );
    }

    function test_codexNemesis_tokensClaimablePreviewIncludesPendingReserveCost() external {
        address reserveBeneficiary = address(bytes20(keccak256("reserve beneficiary")));
        DefifaLaunchProjectData memory defifaData = _launchDataWithTier1Reserves(reserveBeneficiary);
        (uint256 projectId, DefifaHook nft, DefifaGovernor gov) = _createDefifaProject(defifaData);

        address player = address(bytes20(keccak256("player")));
        address[] memory users = new address[](4);
        users[0] = player;
        users[1] = address(bytes20(keccak256("attestor 1")));
        users[2] = address(bytes20(keccak256("attestor 2")));
        users[3] = address(bytes20(keccak256("attestor 3")));

        vm.warp(defifaData.start - defifaData.mintPeriodDuration - defifaData.refundPeriodDuration);
        _mintTier(projectId, player, 1);
        _mintTier(projectId, player, 1);
        _mintTier(projectId, player, 1);
        _mintTier(projectId, users[1], 2);
        _mintTier(projectId, users[2], 3);
        _mintTier(projectId, users[3], 4);

        _delegateSelf(nft, player, 1);
        _delegateSelf(nft, users[1], 2);
        _delegateSelf(nft, users[2], 3);
        _delegateSelf(nft, users[3], 4);

        assertEq(nft.adjustedPendingReservesFor(1), 3, "tier 1 has three pending reserves");

        _ratifyEvenScorecard(users, nft, gov, projectId, 4);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = _generateTokenId(1, 2);

        IERC20 defifaToken = IERC20(address(jbTokens().tokenOf(_defifaProjectId)));
        IERC20 nanaToken = IERC20(address(jbTokens().tokenOf(_protocolFeeProjectId)));
        uint256 defifaBalance = defifaToken.balanceOf(address(nft));
        uint256 nanaBalance = nanaToken.balanceOf(address(nft));

        (uint256 previewDefifa, uint256 previewNana) = nft.tokensClaimableFor(tokenIds);

        assertEq(previewDefifa, defifaBalance / 9, "preview includes pending reserve cost");
        assertEq(previewNana, nanaBalance / 9, "preview includes pending reserve cost");
    }

    function _launchDataWithTier1Reserves(address reserveBeneficiary)
        internal
        view
        returns (DefifaLaunchProjectData memory)
    {
        DefifaTierParams[] memory tierParams = new DefifaTierParams[](4);
        tierParams[0] = DefifaTierParams({
            reservedRate: 1,
            reservedTokenBeneficiary: reserveBeneficiary,
            encodedIPFSUri: bytes32(0),
            shouldUseReservedTokenBeneficiaryAsDefault: false,
            name: "TEAM1"
        });
        for (uint256 i = 1; i < 4; i++) {
            tierParams[i] = DefifaTierParams({
                reservedRate: 0,
                reservedTokenBeneficiary: address(0),
                encodedIPFSUri: bytes32(0),
                shouldUseReservedTokenBeneficiaryAsDefault: false,
                name: "TEAM"
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
            tierPrice: uint104(1 ether),
            tiers: tierParams,
            defaultTokenUriResolver: IJB721TokenUriResolver(address(0)),
            terminal: jbMultiTerminal(),
            minParticipation: 0,
            scorecardTimeout: 0,
            timelockDuration: 0
        });
    }

    function _mintTier(uint256 projectId, address user, uint16 tierId) internal {
        vm.deal(user, user.balance + 1 ether);
        uint16[] memory rawMetadata = new uint16[](1);
        rawMetadata[0] = tierId;
        bytes memory metadata = _buildPayMetadata(abi.encode(user, rawMetadata));
        vm.prank(user);
        jbMultiTerminal().pay{value: 1 ether}(projectId, JBConstants.NATIVE_TOKEN, 1 ether, user, 0, "", metadata);
    }

    function _delegateSelf(DefifaHook nft, address user, uint256 tierId) internal {
        DefifaDelegation[] memory delegations = new DefifaDelegation[](1);
        delegations[0] = DefifaDelegation({delegatee: user, tierId: tierId});
        vm.prank(user);
        nft.setTierDelegatesTo(delegations);
    }
}
