// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ITypeface, Font} from "lib/typeface/contracts/interfaces/ITypeface.sol";

/// @notice Helpers for loading on-chain Capsules typeface font sources used in Defifa SVG rendering.
library DefifaFontImporter {
    /// @notice Gets the Base64 encoded Capsules-500.otf typeface.
    /// @param typeface The typeface contract to query.
    /// @return The Base64 encoded font file.
    function getSkinnyFontSource(ITypeface typeface) internal view returns (bytes memory) {
        return typeface.sourceOf(Font({weight: 500, style: "normal"})); // Capsules font source
    }

    /// @notice Gets the Base64 encoded Capsules-700.otf typeface.
    /// @param typeface The typeface contract to query.
    /// @return The Base64 encoded font file.
    function getBeefyFontSource(ITypeface typeface) internal view returns (bytes memory) {
        return typeface.sourceOf(Font({weight: 700, style: "normal"})); // Capsules font source
    }
}
