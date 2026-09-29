// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {Jabba, ISignatureTransfer} from "../../src/Jabba.sol";
import {MockERC20, FeeOnTransferToken} from "../utils/Mocks.sol";
import {Permit2Model} from "./Permit2Model.sol";

/// @dev Test simbolici Halmos sugli invarianti I1–I8 (§12, passo 8). Eseguire con `halmos`;
///      `forge test` li compila ma non li esegue (prefisso check_).
///      Struttura: le proprietà di sicurezza valgono su input arbitrari ("se il match riesce,
///      allora ..."); i check live_ dimostrano che i percorsi di successo esistono, così le
///      proprietà di sicurezza non passano in modo vacuo. Nessun expectRevert: gli esiti si
///      leggono dal valore di ritorno di una call di basso livello.
contract JabbaHalmos is Test {
    address constant P2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    uint256 constant FEE = 50_000_000_000_000;

    // Hash ricostruiti qui, indipendenti dal contratto.
    bytes32 constant T_TOKEN_PERMISSIONS = keccak256("TokenPermissions(address token,uint256 amount)");
    bytes32 constant T_ORDER = keccak256("Order(address buyToken,uint256 buyAmount)");
    bytes32 constant T_PERMIT_WITNESS = keccak256(
        "PermitWitnessTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline,Order witness)Order(address buyToken,uint256 buyAmount)TokenPermissions(address token,uint256 amount)"
    );

    Jabba swap;
    MockERC20 x;
    MockERC20 y;
    FeeOnTransferToken fot;
    Permit2Model p2 = Permit2Model(P2);
    address payable treasury = payable(address(0x7EA5));
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function setUp() public {
        vm.etch(P2, type(Permit2Model).runtimeCode);
        swap = new Jabba(treasury, FEE);
        x = new MockERC20("X", "X", 18);
        y = new MockERC20("Y", "Y", 6);
        fot = new FeeOnTransferToken();
        _approveAll(alice);
        _approveAll(bob);
    }

    // ------------------------------------------------------------------ helper

    function _approveAll(address who) internal {
        vm.startPrank(who);
        x.approve(P2, type(uint256).max);
        y.approve(P2, type(uint256).max);
        fot.approve(P2, type(uint256).max);
        vm.stopPrank();
    }

    function _side(address maker, address sell, uint256 sellAmt, address buy, uint256 buyAmt, uint256 nonce)
        internal
        view
        returns (Jabba.Side memory s)
    {
        s.permit = ISignatureTransfer.PermitTransferFrom(
            ISignatureTransfer.TokenPermissions(sell, sellAmt), nonce, block.timestamp
        );
        s.maker = maker;
        s.order = Jabba.Order(buy, buyAmt);
        s.sig = "";
    }

    /// @dev A vende x e compra y; B vende y e compra x. Saldi iniziali arbitrari.
    function _pair(uint128 aSell, uint128 bSell, uint128 aBuy, uint128 bBuy, uint128[4] memory bal)
        internal
        returns (Jabba.Side memory a, Jabba.Side memory b)
    {
        x.mint(alice, bal[0]);
        y.mint(alice, bal[1]);
        x.mint(bob, bal[2]);
        y.mint(bob, bal[3]);
        a = _side(alice, address(x), aSell, address(y), aBuy, 1);
        b = _side(bob, address(y), bSell, address(x), bBuy, 1);
    }

    function _assumeSubmitter(address sub) internal view {
        vm.assume(sub != address(swap) && sub != P2 && sub != treasury);
        vm.assume(sub != address(x) && sub != address(y) && sub != address(fot));
    }

    function _match(address sub, uint256 value, Jabba.Side memory a, Jabba.Side memory b) internal returns (bool ok) {
        vm.deal(sub, value);
        vm.prank(sub);
        (ok,) = address(swap).call{value: value}(abi.encodeCall(Jabba.matchOrders, (a, b)));
    }

    function _crossed(uint128 aSell, uint128 bSell, uint128 aBuy, uint128 bBuy, uint128[4] memory bal)
        internal
        pure
    {
        vm.assume(aBuy > 0 && bBuy > 0);
        vm.assume(aSell >= bBuy && bSell >= aBuy);
        vm.assume(bal[0] >= aSell && bal[3] >= bSell);
    }

    // ------------------------------------------------------------------ vivacità (non vacuità)

    /// @notice Due ordini validi e incrociati, fee esatta: il match riesce sempre.
    function check_live_validMatchSucceeds(
        uint128 aSell,
        uint128 bSell,
        uint128 aBuy,
        uint128 bBuy,
        uint128[4] memory bal,
        address sub
    ) public {
        _assumeSubmitter(sub);
        _crossed(aSell, bSell, aBuy, bBuy, bal);
        (Jabba.Side memory a, Jabba.Side memory b) = _pair(aSell, bSell, aBuy, bBuy, bal);
        assert(_match(sub, FEE, a, b));
    }

    /// @notice setFee dal tesoriere riesce sempre; post valido riesce sempre.
    function check_live_setFeeAndPost(uint256 newFee, uint128 sellAmt, uint128 buyAmt, uint256 nonce) public {
        vm.prank(treasury);
        (bool ok,) = address(swap).call(abi.encodeCall(Jabba.setFee, (newFee)));
        assert(ok);
        vm.assume(sellAmt > 0 && buyAmt > 0);
        (ok,) = address(swap).call(
            abi.encodeCall(Jabba.post, (_side(alice, address(x), sellAmt, address(y), buyAmt, nonce)))
        );
        assert(ok);
    }

    // ------------------------------------------------------------------ I1

    /// @notice I1: se il match riesce, ogni maker riceve esattamente quanto la controparte cede
    ///         (token conformi) e almeno il proprio buyAmount.
    function check_I1_receipt(uint128 aSell, uint128 bSell, uint128 aBuy, uint128 bBuy, uint128[4] memory bal) public {
        (Jabba.Side memory a, Jabba.Side memory b) = _pair(aSell, bSell, aBuy, bBuy, bal);
        uint256 a0 = y.balanceOf(alice);
        uint256 b0 = x.balanceOf(bob);
        if (_match(address(0x5B), FEE, a, b)) {
            assert(y.balanceOf(alice) == a0 + bSell);
            assert(x.balanceOf(bob) == b0 + aSell);
            assert(y.balanceOf(alice) - a0 >= aBuy);
            assert(x.balanceOf(bob) - b0 >= bBuy);
        }
    }

    // ------------------------------------------------------------------ I2

    /// @notice I2 (conformi): se il match riesce, ogni maker cede esattamente il sellAmount firmato.
    function check_I2_exactGive(uint128 aSell, uint128 bSell, uint128 aBuy, uint128 bBuy, uint128[4] memory bal) public {
        (Jabba.Side memory a, Jabba.Side memory b) = _pair(aSell, bSell, aBuy, bBuy, bal);
        uint256 a0 = x.balanceOf(alice);
        uint256 b0 = y.balanceOf(bob);
        if (_match(address(0x5B), FEE, a, b)) {
            assert(a0 - x.balanceOf(alice) == aSell);
            assert(b0 - y.balanceOf(bob) == bSell);
        }
    }

    /// @notice I2 (non conformi): con un token fee-on-transfer, se il match riesce ogni maker ha
    ///         comunque ricevuto almeno quanto la controparte ha ceduto.
    function check_I2_nonConformingReceipt(uint128 aSell, uint128 bSell, uint128 aBuy, uint128 bBuy, uint128 balA)
        public
    {
        fot.mint(alice, balA);
        y.mint(bob, bSell);
        Jabba.Side memory a = _side(alice, address(fot), aSell, address(y), aBuy, 1);
        Jabba.Side memory b = _side(bob, address(y), bSell, address(fot), bBuy, 1);
        uint256 a0 = y.balanceOf(alice);
        uint256 b0 = fot.balanceOf(bob);
        if (_match(address(0x5B), FEE, a, b)) {
            assert(fot.balanceOf(bob) - b0 >= aSell);
            assert(y.balanceOf(alice) - a0 >= bSell);
        }
    }

    // ------------------------------------------------------------------ I3

    /// @notice I3: un match riuscito consuma entrambi i nonce, con un solo prelievo per intero;
    ///         lo stesso match ripetuto fallisce.
    function check_I3_onceAndWhole(uint128 aSell, uint128 bSell, uint128 aBuy, uint128 bBuy, uint128[4] memory bal)
        public
    {
        (Jabba.Side memory a, Jabba.Side memory b) = _pair(aSell, bSell, aBuy, bBuy, bal);
        if (_match(address(0x5B), FEE, a, b)) {
            assert(p2.nonceUsed(alice, 1) && p2.nonceUsed(bob, 1));
            assert(p2.pulls(alice) == 1 && p2.pulls(bob) == 1);
            assert(p2.lastRequested(alice) == aSell && p2.lastRequested(bob) == bSell);
            assert(!_match(address(0x5B), FEE, a, b));
        }
    }

    // ------------------------------------------------------------------ I4

    /// @notice I4: dopo un match lo storage persistente (slot 0 = fee) è invariato e il contratto
    ///         non trattiene token né ETH.
    function check_I4_noResidue(uint128 aSell, uint128 bSell, uint128 aBuy, uint128 bBuy, uint128[4] memory bal, address sub)
        public
    {
        _assumeSubmitter(sub);
        (Jabba.Side memory a, Jabba.Side memory b) = _pair(aSell, bSell, aBuy, bBuy, bal);
        bytes32 slot0 = vm.load(address(swap), 0);
        if (_match(sub, FEE, a, b)) {
            assert(vm.load(address(swap), 0) == slot0);
            assert(x.balanceOf(address(swap)) == 0 && y.balanceOf(address(swap)) == 0);
            assert(address(swap).balance == 0);
        }
    }

    /// @notice I4: solo TREASURY scrive la fee.
    function check_I4_onlyTreasurySetsFee(address caller, uint256 newFee) public {
        vm.prank(caller);
        (bool ok,) = address(swap).call(abi.encodeCall(Jabba.setFee, (newFee)));
        if (caller != treasury) {
            assert(!ok);
            assert(swap.fee() == FEE);
        } else {
            assert(ok && swap.fee() == newFee);
        }
    }

    // ------------------------------------------------------------------ I5

    /// @notice I5: se il match riesce, msg.value era la fee corrente ed è arrivato per intero a TREASURY.
    function check_I5_feeForwarded(
        uint128 aSell,
        uint128 bSell,
        uint128 aBuy,
        uint128 bBuy,
        uint128[4] memory bal,
        uint256 currentFee,
        uint256 value
    ) public {
        vm.prank(treasury);
        swap.setFee(currentFee);
        (Jabba.Side memory a, Jabba.Side memory b) = _pair(aSell, bSell, aBuy, bBuy, bal);
        uint256 t0 = treasury.balance;
        vm.assume(t0 < type(uint128).max && value < type(uint128).max);
        if (_match(address(0x5B), value, a, b)) {
            assert(value == currentFee);
            assert(treasury.balance == t0 + value);
            assert(address(swap).balance == 0);
        }
    }

    // ------------------------------------------------------------------ I6

    /// @notice I6: per i token conformi la somma dei saldi dei due maker è conservata per token.
    function check_I6_conservation(uint128 aSell, uint128 bSell, uint128 aBuy, uint128 bBuy, uint128[4] memory bal)
        public
    {
        (Jabba.Side memory a, Jabba.Side memory b) = _pair(aSell, bSell, aBuy, bBuy, bal);
        uint256 sx = x.balanceOf(alice) + x.balanceOf(bob);
        uint256 sy = y.balanceOf(alice) + y.balanceOf(bob);
        if (_match(address(0x5B), FEE, a, b)) {
            assert(x.balanceOf(alice) + x.balanceOf(bob) == sx);
            assert(y.balanceOf(alice) + y.balanceOf(bob) == sy);
        }
    }

    // ------------------------------------------------------------------ I7

    /// @notice I7: con submitter arbitrario, ogni gamba va alla controparte, lo spender è Jabba e
    ///         il witness passato a Permit2 è quello dell'ordine firmato.
    function check_I7_counterpartyRecipient(
        uint128 aSell,
        uint128 bSell,
        uint128 aBuy,
        uint128 bBuy,
        uint128[4] memory bal,
        address sub
    ) public {
        _assumeSubmitter(sub);
        (Jabba.Side memory a, Jabba.Side memory b) = _pair(aSell, bSell, aBuy, bBuy, bal);
        if (_match(sub, FEE, a, b)) {
            assert(p2.lastTo(alice) == bob && p2.lastTo(bob) == alice);
            assert(p2.lastSpender(alice) == address(swap) && p2.lastSpender(bob) == address(swap));
            assert(p2.lastWitness(alice) == keccak256(abi.encode(T_ORDER, address(y), uint256(aBuy))));
            assert(p2.lastWitness(bob) == keccak256(abi.encode(T_ORDER, address(x), uint256(bBuy))));
            assert(p2.lastTypeStringOk(alice) && p2.lastTypeStringOk(bob));
        }
    }

    // ------------------------------------------------------------------ I8

    /// @notice I8: post non modifica storage, saldi o nonce, da qualunque chiamante.
    function check_I8_postNoEffects(address caller, uint128 sellAmt, uint128 buyAmt, uint256 nonce, uint128 balA)
        public
    {
        x.mint(alice, balA);
        bytes32 slot0 = vm.load(address(swap), 0);
        uint256 ax = x.balanceOf(alice);
        uint256 eth = address(swap).balance;
        vm.prank(caller);
        (bool ok,) = address(swap).call(
            abi.encodeCall(Jabba.post, (_side(alice, address(x), sellAmt, address(y), buyAmt, nonce)))
        );
        ok; // riuscita o revert, nessun effetto
        assert(vm.load(address(swap), 0) == slot0);
        assert(x.balanceOf(alice) == ax && x.balanceOf(address(swap)) == 0);
        assert(address(swap).balance == eth);
        assert(!p2.nonceUsed(alice, nonce) && p2.pulls(alice) == 0);
    }

    // ------------------------------------------------------------------ hash (§3)

    /// @notice orderHash coincide con la ricostruzione indipendente: maker + struct hash EIP-712.
    function check_H_orderHash(address maker, uint256 sellAmt, uint256 buyAmt, uint256 nonce) public view {
        Jabba.Side memory s = _side(maker, address(x), sellAmt, address(y), buyAmt, nonce);
        bytes32 structHash = keccak256(
            abi.encode(
                T_PERMIT_WITNESS,
                keccak256(abi.encode(T_TOKEN_PERMISSIONS, address(x), sellAmt)),
                address(swap),
                nonce,
                block.timestamp,
                keccak256(abi.encode(T_ORDER, address(y), buyAmt))
            )
        );
        assert(swap.permitWitnessStructHash(s) == structHash);
        assert(swap.orderHash(s) == keccak256(abi.encode(maker, structHash)));
    }
}
