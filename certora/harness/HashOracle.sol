// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/// @dev Ricostruzione indipendente della struttura degli hash di §3, per confronto con Jabba.
///      Il typehash PermitWitnessTransferFrom è un parametro: Certora non conosce il contenuto delle
///      stringhe lunghe copiate dal bytecode, quindi il suo valore è verificato da Halmos
///      (check_H_orderHash) e dai test Foundry (HashTest), che calcolano keccak256 in modo concreto.
contract HashOracle {
    bytes32 constant T_TOKEN_PERMISSIONS = keccak256("TokenPermissions(address token,uint256 amount)");
    bytes32 constant T_ORDER = keccak256("Order(address buyToken,uint256 buyAmount)");

    function orderHash(
        address maker,
        address sellToken,
        uint256 sellAmount,
        uint256 nonce,
        uint256 deadline,
        address buyToken,
        uint256 buyAmount,
        address spender,
        bytes32 permitWitnessTypehash
    ) external pure returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                permitWitnessTypehash,
                keccak256(abi.encode(T_TOKEN_PERMISSIONS, sellToken, sellAmount)),
                spender,
                nonce,
                deadline,
                keccak256(abi.encode(T_ORDER, buyToken, buyAmount))
            )
        );
        return keccak256(abi.encode(maker, structHash));
    }
}
