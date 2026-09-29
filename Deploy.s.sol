// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Script, console2} from "forge-std/Script.sol";
import {Jabba} from "../src/Jabba.sol";

/// @notice Deploy deterministico (CREATE2) di Jabba.
/// Variabili d'ambiente:
///   TREASURY  multisig che riceve la fee e puo' chiamare setFee (obbligatoria)
///   FEE_WEI   fee iniziale in wei (default 50000000000000 = 0,00005 ETH)
///   SALT      salt CREATE2 (default keccak256("Jabba v2.4"))
/// Esempio:
///   forge script script/Deploy.s.sol --rpc-url robinhood --broadcast --verify
contract Deploy is Script {
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    function run() external returns (Jabba swap) {
        address payable treasury = payable(vm.envAddress("TREASURY"));
        uint256 feeWei = vm.envOr("FEE_WEI", uint256(50_000_000_000_000));
        bytes32 salt = vm.envOr("SALT", keccak256("Jabba v2.4"));

        require(PERMIT2.code.length > 0, "Permit2 assente su questa chain");
        require(treasury.code.length > 0, "TREASURY deve essere un multisig (contratto)");

        vm.startBroadcast();
        swap = new Jabba{salt: salt}(treasury, feeWei);
        vm.stopBroadcast();

        console2.log("Jabba:", address(swap));
        console2.log("TREASURY:  ", treasury);
        console2.log("fee (wei): ", feeWei);
    }
}
