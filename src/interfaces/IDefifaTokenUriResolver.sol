// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ITypeface} from "lib/typeface/contracts/interfaces/ITypeface.sol";

/// @notice Resolves on-chain SVG token URIs for Defifa game NFTs using an on-chain typeface.
interface IDefifaTokenUriResolver {
    /// @notice The on-chain typeface contract used for rendering text in token SVGs.
    /// @return The typeface contract.
    function TYPEFACE() external view returns (ITypeface);
}
