// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ITypeface} from "lib/typeface/contracts/interfaces/ITypeface.sol";

interface IDefifaTokenUriResolver {
    function TYPEFACE() external view returns (ITypeface);
}
