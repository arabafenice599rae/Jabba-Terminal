// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {MockERC20} from "../../test/utils/Mocks.sol";

/// @dev Due istanze distinte di token conforme: Certora richiede un contratto per istanza.
contract TokenX is MockERC20 {
    constructor() MockERC20("X", "X", 18) {}
}

contract TokenY is MockERC20 {
    constructor() MockERC20("Y", "Y", 6) {}
}
