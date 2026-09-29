// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/// @dev ERC-20 minimale conforme, per i test.
contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public immutable decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(string memory n, string memory s, uint8 d) {
        name = n;
        symbol = s;
        decimals = d;
    }

    function mint(address to, uint256 v) external {
        totalSupply += v;
        balanceOf[to] += v;
        emit Transfer(address(0), to, v);
    }

    function approve(address s, uint256 v) external returns (bool) {
        allowance[msg.sender][s] = v;
        emit Approval(msg.sender, s, v);
        return true;
    }

    function transfer(address to, uint256 v) external returns (bool) {
        _move(msg.sender, to, v);
        return true;
    }

    function transferFrom(address f, address to, uint256 v) external virtual returns (bool) {
        uint256 a = allowance[f][msg.sender];
        if (a != type(uint256).max) allowance[f][msg.sender] = a - v;
        _move(f, to, v);
        return true;
    }

    function _move(address f, address to, uint256 v) internal virtual {
        balanceOf[f] -= v;
        balanceOf[to] += v;
        emit Transfer(f, to, v);
    }
}

/// @dev Token fee-on-transfer: il destinatario riceve l'1% in meno.
contract FeeOnTransferToken is MockERC20 {
    constructor() MockERC20("Fee", "FOT", 18) {}

    function _move(address f, address to, uint256 v) internal override {
        uint256 cut = v / 100;
        balanceOf[f] -= v;
        balanceOf[to] += v - cut;
        balanceOf[address(0xdead)] += cut;
        emit Transfer(f, to, v - cut);
    }
}

/// @dev Token con pausa e blocklist, come gli stock token di Robinhood Chain.
contract PausableBlocklistToken is MockERC20 {
    bool public paused;
    mapping(address => bool) public isBlocked;

    constructor() MockERC20("Stock", "STK", 18) {}

    function setPaused(bool p) external {
        paused = p;
    }

    function setBlocked(address a, bool b) external {
        isBlocked[a] = b;
    }

    function _move(address f, address to, uint256 v) internal override {
        require(!paused, "PAUSED");
        require(!isBlocked[f] && !isBlocked[to], "BLOCKED");
        super._move(f, to, v);
    }
}

/// @dev Token malevolo: addebita al mittente il doppio, accredita il dovuto (viola I2 fuori perimetro).
contract OverchargeToken is MockERC20 {
    constructor() MockERC20("Over", "OVR", 18) {}

    function _move(address f, address to, uint256 v) internal override {
        balanceOf[f] -= 2 * v;
        balanceOf[to] += v;
        balanceOf[address(0xdead)] += v;
        emit Transfer(f, to, v);
    }
}

/// @dev Tesoriere che rifiuta ETH.
contract RejectingTreasury {
    receive() external payable {
        revert("NO_ETH");
    }

    function callSetFee(address swap, uint256 f) external {
        (bool ok,) = swap.call(abi.encodeWithSignature("setFee(uint256)", f));
        require(ok);
    }
}

/// @dev Token che durante il trasferimento tenta di rientrare in matchOrders e registra l'esito.
contract ReentrantToken is MockERC20 {
    address public target;
    bytes public payload;
    bool public attempted;
    bytes public lastError;

    constructor() MockERC20("Re", "RE", 18) {}

    function arm(address t, bytes calldata p) external {
        target = t;
        payload = p;
    }

    function _move(address f, address to, uint256 v) internal override {
        super._move(f, to, v);
        if (target != address(0) && !attempted) {
            attempted = true;
            (bool ok, bytes memory ret) = target.call(payload);
            if (!ok) lastError = ret;
        }
    }
}
