// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {ISignatureTransfer} from "../../src/Jabba.sol";

interface IERC20Like {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @dev Modello astratto di Permit2 per Halmos e Certora (§12, passo 8).
///      Conserva la semantica rilevante per Jabba: nonce monouso, scadenza, importo richiesto
///      non superiore al permesso, trasferimento owner -> to. La firma EIP-712 non è verificata:
///      al suo posto il modello registra spender, destinatario, witness e type string di ogni
///      chiamata, e le proprietà verificano che coincidano con quanto il maker ha firmato.
contract Permit2Model {
    bytes32 public constant T_ORDER = keccak256("Order(address buyToken,uint256 buyAmount)");
    /// @dev Type string attesa per il witness Order (formato Permit2), scritta qui in modo indipendente.
    string public constant WITNESS_STRING =
        "Order witness)Order(address buyToken,uint256 buyAmount)TokenPermissions(address token,uint256 amount)";

    mapping(address => mapping(uint256 => bool)) public nonceUsed;

    /// @dev Ultima chiamata per owner.
    mapping(address => address) public lastSpender;
    mapping(address => address) public lastTo;
    mapping(address => uint256) public lastRequested;
    mapping(address => bytes32) public lastWitness;
    mapping(address => bool) public lastTypeStringOk;
    mapping(address => uint256) public pulls;

    error SignatureExpired();
    error InvalidAmount();
    error InvalidNonce();
    error TransferFailed();

    /// @notice Witness atteso per un ordine, calcolato in modo indipendente da Jabba.
    function orderWitness(address buyToken, uint256 buyAmount) external pure returns (bytes32) {
        return keccak256(abi.encode(T_ORDER, buyToken, buyAmount));
    }

    /// @dev WITNESS_STRING in parole da 32 byte (l'ultima con padding a zero).
    bytes32 constant W0 = 0x4f72646572207769746e657373294f7264657228616464726573732062757954; // "Order witness)Order(address buyT"
    bytes32 constant W1 = 0x6f6b656e2c75696e7432353620627579416d6f756e7429546f6b656e5065726d; // "oken,uint256 buyAmount)TokenPerm"
    bytes32 constant W2 = 0x697373696f6e73286164647265737320746f6b656e2c75696e7432353620616d; // "issions(address token,uint256 am"
    bytes32 constant W3 = 0x6f756e7429000000000000000000000000000000000000000000000000000000; // "ount)"
    uint256 constant WITNESS_LEN = 101;

    /// @dev Confronto per parole, senza hash né assembly: i prover modellano keccak256 in modo
    ///      astratto, e l'assembly su calldata impedisce a Certora di risolvere le chiamate.
    function _isWitnessString(string calldata got) internal pure returns (bool) {
        bytes calldata b = bytes(got);
        if (b.length != WITNESS_LEN) return false;
        return bytes32(b[0:32]) == W0 && bytes32(b[32:64]) == W1 && bytes32(b[64:96]) == W2
            && bytes32(b[96:WITNESS_LEN]) == W3;
    }

    function permitWitnessTransferFrom(
        ISignatureTransfer.PermitTransferFrom calldata permit,
        ISignatureTransfer.SignatureTransferDetails calldata transferDetails,
        address owner,
        bytes32 witness,
        string calldata witnessTypeString,
        bytes calldata
    ) external {
        if (block.timestamp > permit.deadline) revert SignatureExpired();
        if (transferDetails.requestedAmount > permit.permitted.amount) revert InvalidAmount();
        if (nonceUsed[owner][permit.nonce]) revert InvalidNonce();
        nonceUsed[owner][permit.nonce] = true;

        lastSpender[owner] = msg.sender;
        lastTo[owner] = transferDetails.to;
        lastRequested[owner] = transferDetails.requestedAmount;
        lastWitness[owner] = witness;
        lastTypeStringOk[owner] = _isWitnessString(witnessTypeString);
        pulls[owner] += 1;

        if (!IERC20Like(permit.permitted.token).transferFrom(owner, transferDetails.to, transferDetails.requestedAmount)) {
            revert TransferFailed();
        }
    }
}
