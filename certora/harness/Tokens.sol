// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {MockERC20} from "../../test/utils/Mocks.sol";

/// @dev Istanze distinte di token conforme: Certora richiede un contratto per istanza.
contract TokenX is MockERC20 {
    constructor() MockERC20("X", "X", 18) {}
}

contract TokenY is MockERC20 {
    constructor() MockERC20("Y", "Y", 6) {}
}

contract TokenZ is MockERC20 {
    constructor() MockERC20("Z", "Z", 18) {}
}
