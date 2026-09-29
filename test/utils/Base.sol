// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";
import {Jabba, ISignatureTransfer} from "../../src/Jabba.sol";
import {MockERC20} from "./Mocks.sol";

interface IPermit2Extra {
    function DOMAIN_SEPARATOR() external view returns (bytes32);
    function nonceBitmap(address owner, uint256 wordPos) external view returns (uint256);
    function invalidateUnorderedNonces(uint256 wordPos, uint256 mask) external;
}

/// @dev Base comune: Permit2 reale all'indirizzo canonico, due maker, due token, firma indipendente dal contratto.
abstract contract Base is Test, DeployPermit2 {
    address constant P2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    uint256 constant FEE = 50_000_000_000_000; // 0,00005 ETH

    // Tipi ricostruiti qui, in modo indipendente dal contratto (test di coerenza, §12.6).
    bytes32 constant T_TOKEN_PERMISSIONS = keccak256("TokenPermissions(address token,uint256 amount)");
    bytes32 constant T_ORDER = keccak256("Order(address buyToken,uint256 buyAmount)");
    bytes32 constant T_PERMIT_WITNESS = keccak256(
        "PermitWitnessTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline,Order witness)Order(address buyToken,uint256 buyAmount)TokenPermissions(address token,uint256 amount)"
    );

    Jabba swap;
    MockERC20 x;
    MockERC20 y;
    address payable treasury = payable(makeAddr("treasury"));
    uint256 aPk = 0xA11CE;
    uint256 bPk = 0xB0B;
    address alice;
    address bob;
    address submitter = makeAddr("submitter");

    function setUp() public virtual {
        deployPermit2();
        swap = new Jabba(treasury, FEE);
        x = new MockERC20("X", "X", 18);
        y = new MockERC20("Y", "Y", 6);
        alice = vm.addr(aPk);
        bob = vm.addr(bPk);
        _fund(x, alice, type(uint128).max);
        _fund(y, bob, type(uint128).max);
        vm.deal(submitter, 100 ether);
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
    }

    function _fund(MockERC20 t, address who, uint256 amt) internal {
        t.mint(who, amt);
        vm.prank(who);
        t.approve(P2, type(uint256).max);
    }

    function _structHash(Jabba.Side memory s) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                T_PERMIT_WITNESS,
                keccak256(abi.encode(T_TOKEN_PERMISSIONS, s.permit.permitted.token, s.permit.permitted.amount)),
                address(swap),
                s.permit.nonce,
                s.permit.deadline,
                keccak256(abi.encode(T_ORDER, s.order.buyToken, s.order.buyAmount))
            )
        );
    }

    function _digest(Jabba.Side memory s) internal view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", IPermit2Extra(P2).DOMAIN_SEPARATOR(), _structHash(s)));
    }

    function _side(uint256 pk, address sell, uint256 sellAmt, address buy, uint256 buyAmt, uint256 nonce)
        internal
        view
        returns (Jabba.Side memory s)
    {
        s.permit = ISignatureTransfer.PermitTransferFrom(
            ISignatureTransfer.TokenPermissions(sell, sellAmt), nonce, block.timestamp + 1 hours
        );
        s.maker = vm.addr(pk);
        s.order = Jabba.Order(buy, buyAmt);
        (uint8 v, bytes32 r, bytes32 ss) = vm.sign(pk, _digest(s));
        s.sig = abi.encodePacked(r, ss, v);
    }

    function _resign(Jabba.Side memory s, uint256 pk) internal view {
        (uint8 v, bytes32 r, bytes32 ss) = vm.sign(pk, _digest(s));
        s.sig = abi.encodePacked(r, ss, v);
    }

    function _nonceUsed(address owner, uint256 nonce) internal view returns (bool) {
        uint256 word = IPermit2Extra(P2).nonceBitmap(owner, nonce >> 8);
        return (word >> (nonce & 0xff)) & 1 == 1;
    }

    function _match(Jabba.Side memory a, Jabba.Side memory b) internal {
        vm.prank(submitter);
        swap.matchOrders{value: FEE}(a, b);
    }
}
