// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/// @dev Sottoinsieme di ISignatureTransfer di Permit2, firme identiche all'originale.
interface ISignatureTransfer {
    struct TokenPermissions {
        address token;
        uint256 amount;
    }

    struct PermitTransferFrom {
        TokenPermissions permitted;
        uint256 nonce;
        uint256 deadline;
    }

    struct SignatureTransferDetails {
        address to;
        uint256 requestedAmount;
    }

    function permitWitnessTransferFrom(
        PermitTransferFrom calldata permit,
        SignatureTransferDetails calldata transferDetails,
        address owner,
        bytes32 witness,
        string calldata witnessTypeString,
        bytes calldata signature
    ) external;
}

interface IERC20Balance {
    function balanceOf(address account) external view returns (uint256);
}

/// @title Jabba v2.4
/// @notice Exchange P2P maker-contro-maker regolato da Permit2. Ogni scambio incrocia due ordini
///         firmati, tutto-o-niente. Nessuna custodia, nessun owner; l'unico storage persistente e' la fee.
/// @dev Specifica: docs/SPEC.md. Invarianti I1-I8 richiamati nei commenti.
contract Jabba {
    // ------------------------------------------------------------------ tipi

    /// @notice Witness Permit2 dell'ordine: cosa il maker vuole ricevere, come minimo.
    struct Order {
        address buyToken;
        uint256 buyAmount;
    }

    /// @notice Un lato di uno scambio: permit Permit2 firmato dal maker, ordine e firma.
    struct Side {
        ISignatureTransfer.PermitTransferFrom permit;
        address maker;
        Order order;
        bytes sig;
    }

    // ------------------------------------------------------------------ costanti

    ISignatureTransfer public constant PERMIT2 = ISignatureTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3);

    bytes32 public constant ORDER_TYPEHASH = keccak256("Order(address buyToken,uint256 buyAmount)");
    bytes32 public constant TOKEN_PERMISSIONS_TYPEHASH = keccak256("TokenPermissions(address token,uint256 amount)");

    /// @dev Formato Permit2: "<Tipo> witness)" seguito dalle definizioni in ordine alfabetico.
    string public constant WITNESS_TYPE_STRING =
        "Order witness)Order(address buyToken,uint256 buyAmount)TokenPermissions(address token,uint256 amount)";

    bytes32 public constant PERMIT_WITNESS_TYPEHASH = keccak256(
        abi.encodePacked(
            "PermitWitnessTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline,",
            WITNESS_TYPE_STRING
        )
    );

    // ------------------------------------------------------------------ stato

    /// @notice Destinatario della fee e unico autorizzato a cambiarla.
    address payable public immutable TREASURY;

    /// @notice Fee in wei per ogni match. Unico storage persistente (I4).
    uint256 public fee;

    /// @dev Lock di rientro in transient storage (EIP-1153): non persistente.
    bool private transient _locked;

    // ------------------------------------------------------------------ eventi

    event OrderPosted(
        bytes32 orderHash,
        address indexed maker,
        address indexed sellToken,
        address indexed buyToken,
        uint256 sellAmount,
        uint256 buyAmount,
        uint256 nonce,
        uint256 deadline,
        bytes sig
    );
    event Matched(bytes32 orderHashA, bytes32 orderHashB, address indexed submitter, uint256 fee);
    event FeeChanged(uint256 oldFee, uint256 newFee);

    // ------------------------------------------------------------------ errori

    error ZeroAddress();
    error ZeroMaker();
    error SelfMatch();
    error SameToken();
    error TokenMismatch();
    error ZeroAmount();
    error NotCrossed();
    error WrongFee();
    error Reentrancy();
    error ShortReceipt();
    error TreasuryTransferFailed();
    error NotTreasury();

    // ------------------------------------------------------------------ costruttore

    constructor(address payable treasury, uint256 initialFee) {
        if (treasury == address(0)) revert ZeroAddress();
        TREASURY = treasury;
        fee = initialFee;
        emit FeeChanged(0, initialFee);
    }

    // ------------------------------------------------------------------ matchOrders (§4)

    /// @notice Esegue per intero due ordini opposti. msg.sender e' il submitter e paga `fee` in msg.value.
    function matchOrders(Side calldata a, Side calldata b) external payable {
        if (_locked) revert Reentrancy();
        _locked = true;

        // Precondizioni
        if (a.maker == address(0) || b.maker == address(0)) revert ZeroMaker();
        if (a.maker == b.maker) revert SelfMatch();
        address aSell = a.permit.permitted.token;
        address bSell = b.permit.permitted.token;
        if (aSell == a.order.buyToken) revert SameToken();
        if (aSell != b.order.buyToken || bSell != a.order.buyToken) revert TokenMismatch();
        uint256 aSellAmt = a.permit.permitted.amount;
        uint256 bSellAmt = b.permit.permitted.amount;
        if (aSellAmt == 0 || bSellAmt == 0 || a.order.buyAmount == 0 || b.order.buyAmount == 0) revert ZeroAmount();
        if (aSellAmt < b.order.buyAmount || bSellAmt < a.order.buyAmount) revert NotCrossed();
        if (msg.value != fee) revert WrongFee();

        // Saldi di partenza (bSell == a.order.buyToken, aSell == b.order.buyToken)
        uint256 a0 = IERC20Balance(bSell).balanceOf(a.maker);
        uint256 b0 = IERC20Balance(aSell).balanceOf(b.maker);

        // Gambe: destinatario sempre la controparte (I7)
        _pull(a, b.maker);
        _pull(b, a.maker);

        // Ricezione (I1, I2): ognuno riceve almeno cio' che la controparte cede
        if (IERC20Balance(bSell).balanceOf(a.maker) - a0 < bSellAmt) revert ShortReceipt();
        if (IERC20Balance(aSell).balanceOf(b.maker) - b0 < aSellAmt) revert ShortReceipt();

        // Fee (I5)
        if (msg.value != 0) {
            (bool ok,) = TREASURY.call{value: msg.value}("");
            if (!ok) revert TreasuryTransferFailed();
        }

        emit Matched(orderHash(a), orderHash(b), msg.sender, msg.value);
        _locked = false;
    }

    // ------------------------------------------------------------------ post (§5)

    /// @notice Pubblica un ordine nel libro on-chain. Solo evento: nessuno storage, nessun trasferimento (I8).
    function post(Side calldata s) external {
        if (s.maker == address(0)) revert ZeroMaker();
        if (s.permit.permitted.token == s.order.buyToken) revert SameToken();
        if (s.permit.permitted.amount == 0 || s.order.buyAmount == 0) revert ZeroAmount();
        emit OrderPosted(
            orderHash(s),
            s.maker,
            s.permit.permitted.token,
            s.order.buyToken,
            s.permit.permitted.amount,
            s.order.buyAmount,
            s.permit.nonce,
            s.permit.deadline,
            s.sig
        );
    }

    // ------------------------------------------------------------------ setFee (§6)

    /// @notice Unica funzione amministrativa. Qualsiasi valore, zero compreso.
    function setFee(uint256 newFee) external {
        if (msg.sender != TREASURY) revert NotTreasury();
        emit FeeChanged(fee, newFee);
        fee = newFee;
    }

    // ------------------------------------------------------------------ hash (§3)

    function orderWitnessHash(Order calldata o) public pure returns (bytes32) {
        return keccak256(abi.encode(ORDER_TYPEHASH, o.buyToken, o.buyAmount));
    }

    /// @notice Struct hash EIP-712 che Permit2 verifica per questa firma (spender = questo contratto).
    function permitWitnessStructHash(Side calldata s) public view returns (bytes32) {
        return keccak256(
            abi.encode(
                PERMIT_WITNESS_TYPEHASH,
                keccak256(abi.encode(TOKEN_PERMISSIONS_TYPEHASH, s.permit.permitted.token, s.permit.permitted.amount)),
                address(this),
                s.permit.nonce,
                s.permit.deadline,
                orderWitnessHash(s.order)
            )
        );
    }

    /// @notice Identificatore dell'ordine: include il maker, assente dal typed data di Permit2.
    function orderHash(Side calldata s) public view returns (bytes32) {
        return keccak256(abi.encode(s.maker, permitWitnessStructHash(s)));
    }

    // ------------------------------------------------------------------ interno

    function _pull(Side calldata s, address to) private {
        PERMIT2.permitWitnessTransferFrom(
            s.permit,
            ISignatureTransfer.SignatureTransferDetails({to: to, requestedAmount: s.permit.permitted.amount}),
            s.maker,
            orderWitnessHash(s.order),
            WITNESS_TYPE_STRING,
            s.sig
        );
    }
}
