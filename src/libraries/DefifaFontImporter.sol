// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ITypeface, Font} from "lib/typeface/contracts/interfaces/ITypeface.sol";

/// @notice Summon fonts.
library DefifaFontImporter {
    // @notice Gets the Base64 encoded Capsules-500.otf typeface
    /// @return The Base64 encoded font file
    function getSkinnyFontSource(ITypeface _typeface) internal view returns (bytes memory) {
        return _typeface.sourceOf(Font({weight: 500, style: "normal"})); // Capsules font source
    }

    // @notice Gets the Base64 encoded Capsules-500.otf typeface
    /// @return The Base64 encoded font file
    function getBeefyFontSource(ITypeface _typeface) internal view returns (bytes memory) {
        return _typeface.sourceOf(Font({weight: 700, style: "normal"})); // Capsules font source
    }
}
