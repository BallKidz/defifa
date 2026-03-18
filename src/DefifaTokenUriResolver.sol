// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {mulDiv} from "@prb/math/src/Common.sol";

import {ERC721} from "@bananapus/721-hook-v6/src/abstract/ERC721.sol";
import {IJB721TokenUriResolver} from "@bananapus/721-hook-v6/src/interfaces/IJB721TokenUriResolver.sol";
import {JB721Tier} from "@bananapus/721-hook-v6/src/structs/JB721Tier.sol";
import {JBIpfsDecoder} from "@bananapus/721-hook-v6/src/libraries/JBIpfsDecoder.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";

import {Base64} from "lib/base64/base64.sol";
import {ITypeface} from "lib/typeface/contracts/interfaces/ITypeface.sol";

import {DefifaFontImporter} from "./libraries/DefifaFontImporter.sol";
import {DefifaGamePhase} from "./enums/DefifaGamePhase.sol";
import {IDefifaHook} from "./interfaces/IDefifaHook.sol";
import {IDefifaTokenUriResolver} from "./interfaces/IDefifaTokenUriResolver.sol";

/// @notice Standard Token URIs for Defifa games.
contract DefifaTokenUriResolver is IDefifaTokenUriResolver, IJB721TokenUriResolver {
    using Strings for uint256;

    //*********************************************************************//
    // ----------------------- internal constants ------------------------ //
    //*********************************************************************//

    /// @notice The fidelity of the decimal returned in the NFT image.
    uint256 internal constant _IMG_DECIMAL_FIDELITY = 5;

    //*********************************************************************//
    // --------------- public immutable stored properties ---------------- //
    //*********************************************************************//

    /// @notice The typeface of the SVGs.
    ITypeface public immutable override TYPEFACE;

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    constructor(ITypeface typeface) {
        TYPEFACE = typeface;
    }

    //*********************************************************************//
    // ----------------------- external views ---------------------------- //
    //*********************************************************************//

    /// @notice The metadata URI of the provided token ID.
    /// @dev Defer to the token's tier IPFS URI if set.
    /// @param nft The address of the nft the token URI should be oriented to.
    /// @param tokenId The ID of the token to get the tier URI for.
    /// @return The token URI corresponding with the tier.
    function tokenUriOf(address nft, uint256 tokenId) external view override returns (string memory) {
        // Keep a reference to the hook.
        IDefifaHook hook = IDefifaHook(nft);

        // Get the game ID.
        uint256 gameId = hook.PROJECT_ID();

        // Keep a reference to the game phase text.
        string memory gamePhaseText;

        // Keep a reference to the rarity text;
        string memory rarityText;

        // Keep a reference to the rarity text;
        string memory valueText;

        // Keep a reference to the game's name.
        // TODO: Somehow make the `IDefifaHook` have the `name` function.
        string memory title = ERC721(address(hook)).name();

        // Keep a reference to the tier's name.
        string memory team;

        // Keep a reference to the SVG parts.
        string[] memory parts = new string[](4);

        // Keep a reference to the pot.
        string memory potText;

        {
            // Get a reference to the tier.
            JB721Tier memory tier =
                hook.store().tierOfTokenId({hook: address(hook), tokenId: tokenId, includeResolvedUri: false});

            // Set the tier's name.
            team = hook.tierNameOf(tier.id);

            // Check to see if the tier has a URI. Return it if it does.
            if (tier.encodedIPFSUri != bytes32(0)) {
                return JBIpfsDecoder.decode({baseUri: hook.baseURI(), hexString: tier.encodedIPFSUri});
            }

            parts[0] = string("data:application/json;base64,");

            parts[1] = string(
                abi.encodePacked(
                    '{"name":"',
                    team,
                    '", "id": "',
                    uint256(tier.id).toString(),
                    '","description":"Team: ',
                    team,
                    ", ID: ",
                    uint256(tier.id).toString(),
                    '.","image":"data:image/svg+xml;base64,'
                )
            );

            {
                // Get a reference to the game phase.
                DefifaGamePhase gamePhase = hook.gamePhaseReporter().currentGamePhaseOf(gameId);

                // Keep a reference to the game pot.
                (uint256 gamePot, address gamePotToken, uint256 gamePotDecimals) =
                    hook.gamePotReporter().currentGamePotOf({gameId: gameId, includeCommitments: false});

                // Include the amount redeemed.
                gamePot = gamePot + hook.amountRedeemed();

                // Set the pot text.
                potText = _formatBalance({
                    amount: gamePot, token: gamePotToken, decimals: gamePotDecimals, fidelity: _IMG_DECIMAL_FIDELITY
                });

                if (gamePhase == DefifaGamePhase.COUNTDOWN) {
                    gamePhaseText = "Minting starts soon.";
                } else if (gamePhase == DefifaGamePhase.MINT) {
                    gamePhaseText = "Minting and refunds are open.";
                } else if (gamePhase == DefifaGamePhase.REFUND) {
                    gamePhaseText = "Minting is over. Refunds are ending.";
                } else if (gamePhase == DefifaGamePhase.SCORING) {
                    gamePhaseText = "Awaiting scorecard approval.";
                } else if (gamePhase == DefifaGamePhase.COMPLETE) {
                    gamePhaseText = "Scorecard locked in. Burn to claim reward.";
                } else if (gamePhase == DefifaGamePhase.NO_CONTEST) {
                    gamePhaseText = "No contest. Refunds open.";
                }

                // Keep a reference to the number of tokens outstanding from this tier.
                uint256 totalMinted = hook.currentSupplyOfTier(tier.id);

                if (gamePhase == DefifaGamePhase.MINT) {
                    rarityText = string(
                        abi.encodePacked(totalMinted.toString(), totalMinted == 1 ? " card so far" : " cards so far")
                    );
                } else {
                    rarityText = string(
                        abi.encodePacked(
                            totalMinted.toString(), totalMinted == 1 ? " card in existence" : " cards in existence"
                        )
                    );
                }

                if (gamePhase == DefifaGamePhase.SCORING || gamePhase == DefifaGamePhase.COMPLETE) {
                    uint256 potPortion = mulDiv({
                        x: gamePot, y: hook.cashOutWeightOf(tokenId), denominator: hook.TOTAL_CASHOUT_WEIGHT()
                    });
                    valueText = !hook.cashOutWeightIsSet()
                        ? "Awaiting scorecard..."
                        : _formatBalance({
                            amount: potPortion,
                            token: gamePotToken,
                            decimals: gamePotDecimals,
                            fidelity: _IMG_DECIMAL_FIDELITY
                        });
                } else {
                    valueText = _formatBalance({
                        amount: tier.price,
                        token: gamePotToken,
                        decimals: gamePotDecimals,
                        fidelity: _IMG_DECIMAL_FIDELITY
                    });
                }
            }
        }
        parts[2] = Base64.encode(
            abi.encodePacked(
                '<svg viewBox="0 0 500 500" xmlns="http://www.w3.org/2000/svg">',
                '<style>@font-face{font-family:"Capsules-500";src:url(data:font/truetype;charset=utf-8;base64,',
                DefifaFontImporter.getSkinnyFontSource(TYPEFACE),
                ');format("opentype");}',
                '@font-face{font-family:"Capsules-700";src:url(data:font/truetype;charset=utf-8;base64,',
                DefifaFontImporter.getBeefyFontSource(TYPEFACE),
                ');format("opentype");}',
                "text{white-space:pre-wrap; width:100%; }</style>",
                '<rect width="100%" height="100%" fill="#181424"/>',
                '<text x="10" y="30" style="font-size:16px; font-family: Capsules-500; font-weight:500; fill: #c0b3f1;">GAME: ',
                gameId.toString(),
                " | POT: ",
                potText,
                " | CARDS: ",
                hook.store().totalSupplyOf(address(hook)).toString(),
                "</text>",
                '<text x="10" y="50" style="font-size:16px; font-family: Capsules-500; font-weight:500; fill: #ed017c;">',
                gamePhaseText,
                "</text>",
                '<text x="10" y="85" style="font-size:26px; font-family: Capsules-500; font-weight:500; fill: #c0b3f1;">',
                _getSubstring(title, 0, 30),
                "</text>",
                '<text x="10" y="120" style="font-size:26px; font-family: Capsules-500; font-weight:500; fill: #c0b3f1;">',
                _getSubstring(title, 30, 60),
                "</text>",
                '<text x="10" y="205" style="font-size:80px; font-family: Capsules-700; font-weight:700; fill: #fea282;">',
                bytes(_getSubstring(team, 20, 30)).length != 0 && bytes(_getSubstring(team, 10, 20)).length != 0
                    ? _getSubstring(team, 0, 10)
                    : "",
                "</text>",
                '<text x="10" y="295" style="font-size:80px; font-family: Capsules-700; font-weight:700; fill: #fea282;">',
                bytes(_getSubstring(team, 20, 30)).length != 0
                    ? _getSubstring(team, 10, 20)
                    : bytes(_getSubstring(team, 10, 20)).length != 0 ? _getSubstring(team, 0, 10) : "",
                "</text>",
                '<text x="10" y="385" style="font-size:80px; font-family: Capsules-700; font-weight:700; fill: #fea282;">',
                bytes(_getSubstring(team, 20, 30)).length != 0
                    ? _getSubstring(team, 20, 30)
                    : bytes(_getSubstring(team, 10, 20)).length != 0
                        ? _getSubstring(team, 10, 20)
                        : _getSubstring(team, 0, 10),
                "</text>",
                '<text x="10" y="430" style="font-size:16px; font-family: Capsules-500; font-weight:500; fill: #c0b3f1;">TOKEN ID: ',
                tokenId.toString(),
                "</text>",
                '<text x="10" y="455" style="font-size:16px; font-family: Capsules-500; font-weight:500; fill: #c0b3f1;">RARITY: ',
                rarityText,
                "</text>",
                '<text x="10" y="480" style="font-size:16px; font-family: Capsules-500; font-weight:500; fill: #c0b3f1;">BACKED BY: ',
                valueText,
                "</text>",
                "</svg>"
            )
        );
        parts[3] = string('"}');
        // slither-disable-next-line encode-packed-collision
        return string.concat(parts[0], Base64.encode(abi.encodePacked(parts[1], parts[2], parts[3])));
    }

    //*********************************************************************//
    // ----------------------- internal views ---------------------------- //
    //*********************************************************************//

    /// @notice Formats a balance from a fixed point number to a string.
    /// @param amount The fixed point amount.
    /// @param token The token the amount is in.
    /// @param decimals The number of decimals in the fixed point amount.
    /// @param fidelity The number of decimals that should be returned in the formatted string.
    /// @return The formatted balance.
    function _formatBalance(
        uint256 amount,
        address token,
        uint256 decimals,
        uint256 fidelity
    )
        internal
        view
        returns (string memory)
    {
        bool isEth = token == JBConstants.NATIVE_TOKEN;

        uint256 fixedPoint = 10 ** decimals;

        // Convert amount to a decimal format
        string memory integerPart = (amount / fixedPoint).toString();

        uint256 remainder = amount % fixedPoint;
        uint256 scaledRemainder = remainder * (10 ** fidelity);
        uint256 decimalPart = scaledRemainder / fixedPoint;

        // Pad with zeros if necessary
        string memory decimalPartStr = decimalPart.toString();
        while (bytes(decimalPartStr).length < fidelity) {
            decimalPartStr = string(abi.encodePacked("0", decimalPartStr));
        }

        // Concatenate the strings
        return isEth
            ? string(abi.encodePacked("\u039E", integerPart, ".", decimalPartStr))
            : string(abi.encodePacked(integerPart, ".", decimalPartStr, " ", IERC20Metadata(token).symbol()));
    }

    /// @notice Gets a substring.
    /// @dev If the first character is a space, it is not included.
    /// @param str The string to get a substring of.
    /// @param startIndex The first index of the substring from within the string.
    /// @param endIndex The last index of the string from within the string.
    /// @return substring The substring.
    function _getSubstring(
        string memory str,
        uint256 startIndex,
        uint256 endIndex
    )
        internal
        pure
        returns (string memory substring)
    {
        bytes memory strBytes = bytes(str);
        if (startIndex >= strBytes.length) return "";
        if (endIndex > strBytes.length) endIndex = strBytes.length;
        startIndex = strBytes[startIndex] == bytes1(0x20) ? startIndex + 1 : startIndex;
        if (startIndex >= endIndex) return "";
        bytes memory result = new bytes(endIndex - startIndex);
        for (uint256 i = startIndex; i < endIndex;) {
            result[i - startIndex] = strBytes[i];
            unchecked {
                ++i;
            }
        }
        return string(result);
    }
}
