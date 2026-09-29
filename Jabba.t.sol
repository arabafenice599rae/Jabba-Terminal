// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Vm} from "forge-std/Vm.sol";
import {Base, IPermit2Extra} from "./utils/Base.sol";
import {Jabba} from "../src/Jabba.sol";
import {MockERC20, FeeOnTransferToken, PausableBlocklistToken, OverchargeToken, RejectingTreasury, ReentrantToken} from "./utils/Mocks.sol";

contract MatchTest is Base {
    // A vende 10 X per almeno 25 Y; B vende 25 Y per almeno 10 X
    function _pair(uint256 na, uint256 nb) internal view returns (Jabba.Side memory a, Jabba.Side memory b) {
        a = _side(aPk, address(x), 10e18, address(y), 25e6, na);
        b = _side(bPk, address(y), 25e6, address(x), 10e18, nb);
    }

    function test_match_exact() public {
        (Jabba.Side memory a, Jabba.Side memory b) = _pair(1, 1);
        uint256 ax = x.balanceOf(alice);
        _match(a, b);
        assertEq(y.balanceOf(alice), 25e6);
        assertEq(x.balanceOf(bob), 10e18);
        assertEq(ax - x.balanceOf(alice), 10e18);
        assertEq(treasury.balance, FEE);
        assertEq(x.balanceOf(address(swap)) + y.balanceOf(address(swap)), 0);
        assertEq(address(swap).balance, 0);
        assertTrue(_nonceUsed(alice, 1) && _nonceUsed(bob, 1));
    }

    function test_match_surplusGoesToCounterparty() public {
        // A vuole almeno 20 Y, B cede 25 Y; B vuole almeno 8 X, A cede 10 X
        Jabba.Side memory a = _side(aPk, address(x), 10e18, address(y), 20e6, 1);
        Jabba.Side memory b = _side(bPk, address(y), 25e6, address(x), 8e18, 1);
        _match(a, b);
        assertEq(y.balanceOf(alice), 25e6);
        assertEq(x.balanceOf(bob), 10e18);
    }

    function test_match_eventsAndHashes() public {
        (Jabba.Side memory a, Jabba.Side memory b) = _pair(7, 9);
        bytes32 ha = keccak256(abi.encode(alice, _structHash(a)));
        bytes32 hb = keccak256(abi.encode(bob, _structHash(b)));
        vm.expectEmit(address(swap));
        emit Jabba.Matched(ha, hb, submitter, FEE);
        _match(a, b);
    }

    function test_revert_replay() public {
        (Jabba.Side memory a, Jabba.Side memory b) = _pair(1, 1);
        _match(a, b);
        Jabba.Side memory b2 = _side(bPk, address(y), 25e6, address(x), 10e18, 2);
        vm.prank(submitter);
        vm.expectRevert();
        swap.matchOrders{value: FEE}(a, b2);
    }

    function test_revert_notCrossed() public {
        Jabba.Side memory a = _side(aPk, address(x), 10e18, address(y), 30e6, 1);
        Jabba.Side memory b = _side(bPk, address(y), 25e6, address(x), 10e18, 1);
        vm.prank(submitter);
        vm.expectRevert(Jabba.NotCrossed.selector);
        swap.matchOrders{value: FEE}(a, b);
    }

    function test_revert_sizeMismatch() public {
        // prezzi compatibili ma taglie no: B vuole 12 X, A ne cede 10
        Jabba.Side memory a = _side(aPk, address(x), 10e18, address(y), 25e6, 1);
        Jabba.Side memory b = _side(bPk, address(y), 30e6, address(x), 12e18, 1);
        vm.prank(submitter);
        vm.expectRevert(Jabba.NotCrossed.selector);
        swap.matchOrders{value: FEE}(a, b);
    }

    function test_revert_tokenMismatch() public {
        MockERC20 z = new MockERC20("Z", "Z", 18);
        Jabba.Side memory a = _side(aPk, address(x), 10e18, address(z), 25e6, 1);
        Jabba.Side memory b = _side(bPk, address(y), 25e6, address(x), 10e18, 1);
        vm.prank(submitter);
        vm.expectRevert(Jabba.TokenMismatch.selector);
        swap.matchOrders{value: FEE}(a, b);
    }

    function test_revert_sameToken() public {
        Jabba.Side memory a = _side(aPk, address(x), 10e18, address(x), 25e6, 1);
        Jabba.Side memory b = _side(bPk, address(x), 25e6, address(x), 10e18, 1);
        vm.prank(submitter);
        vm.expectRevert(Jabba.SameToken.selector);
        swap.matchOrders{value: FEE}(a, b);
    }

    function test_revert_selfMatch() public {
        Jabba.Side memory a = _side(aPk, address(x), 10e18, address(y), 25e6, 1);
        Jabba.Side memory b = _side(aPk, address(y), 25e6, address(x), 10e18, 2);
        vm.prank(submitter);
        vm.expectRevert(Jabba.SelfMatch.selector);
        swap.matchOrders{value: FEE}(a, b);
    }

    function test_revert_zeroMaker() public {
        (Jabba.Side memory a, Jabba.Side memory b) = _pair(1, 1);
        a.maker = address(0);
        vm.prank(submitter);
        vm.expectRevert(Jabba.ZeroMaker.selector);
        swap.matchOrders{value: FEE}(a, b);
    }

    function test_revert_zeroAmount() public {
        Jabba.Side memory a = _side(aPk, address(x), 10e18, address(y), 0, 1);
        Jabba.Side memory b = _side(bPk, address(y), 25e6, address(x), 10e18, 1);
        vm.prank(submitter);
        vm.expectRevert(Jabba.ZeroAmount.selector);
        swap.matchOrders{value: FEE}(a, b);
    }

    function test_revert_tamperedWitness() public {
        (Jabba.Side memory a, Jabba.Side memory b) = _pair(1, 1);
        a.order.buyAmount = 1; // firma non piu' valida
        vm.prank(submitter);
        vm.expectRevert();
        swap.matchOrders{value: FEE}(a, b);
    }

    function test_revert_expired() public {
        (Jabba.Side memory a, Jabba.Side memory b) = _pair(1, 1);
        vm.warp(block.timestamp + 2 hours);
        vm.prank(submitter);
        vm.expectRevert();
        swap.matchOrders{value: FEE}(a, b);
    }

    function test_revert_cancelledNonce() public {
        (Jabba.Side memory a, Jabba.Side memory b) = _pair(5, 1);
        vm.prank(alice);
        IPermit2Extra(P2).invalidateUnorderedNonces(0, 1 << 5);
        vm.prank(submitter);
        vm.expectRevert();
        swap.matchOrders{value: FEE}(a, b);
    }

    function test_compactSignature2098() public {
        (Jabba.Side memory a, Jabba.Side memory b) = _pair(1, 1);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(aPk, _digest(a));
        bytes32 vs = bytes32(uint256(v - 27) << 255 | uint256(s));
        a.sig = abi.encodePacked(r, vs);
        assertEq(a.sig.length, 64);
        _match(a, b);
        assertEq(x.balanceOf(bob), 10e18);
    }

    function test_thirdPartySubmitter_recipientsFixed() public {
        (Jabba.Side memory a, Jabba.Side memory b) = _pair(1, 1);
        address rnd = makeAddr("rnd");
        vm.deal(rnd, 1 ether);
        vm.prank(rnd);
        swap.matchOrders{value: FEE}(a, b);
        assertEq(x.balanceOf(rnd) + y.balanceOf(rnd), 0);
        assertEq(x.balanceOf(bob), 10e18);
        assertEq(y.balanceOf(alice), 25e6);
    }
}

contract FeeTest is Base {
    function _pair() internal view returns (Jabba.Side memory a, Jabba.Side memory b) {
        a = _side(aPk, address(x), 10e18, address(y), 25e6, 1);
        b = _side(bPk, address(y), 25e6, address(x), 10e18, 1);
    }

    function test_initialFee() public view {
        assertEq(swap.fee(), 50_000_000_000_000);
    }

    function test_revert_wrongFee() public {
        (Jabba.Side memory a, Jabba.Side memory b) = _pair();
        uint256[3] memory vals = [uint256(0), FEE - 1, FEE + 1];
        for (uint256 i; i < 3; i++) {
            vm.prank(submitter);
            vm.expectRevert(Jabba.WrongFee.selector);
            swap.matchOrders{value: vals[i]}(a, b);
        }
    }

    function test_setFee_onlyTreasury() public {
        vm.expectRevert(Jabba.NotTreasury.selector);
        swap.setFee(1);
        vm.expectEmit(address(swap));
        emit Jabba.FeeChanged(FEE, 123);
        vm.prank(treasury);
        swap.setFee(123);
        assertEq(swap.fee(), 123);
    }

    function test_feeChangeInFlight_revertsWithoutCharge() public {
        (Jabba.Side memory a, Jabba.Side memory b) = _pair();
        vm.prank(treasury);
        swap.setFee(FEE * 2);
        uint256 before = submitter.balance;
        vm.prank(submitter);
        vm.expectRevert(Jabba.WrongFee.selector);
        swap.matchOrders{value: FEE}(a, b);
        assertEq(submitter.balance, before);
        assertFalse(_nonceUsed(alice, 1));
    }

    function test_zeroFee() public {
        vm.prank(treasury);
        swap.setFee(0);
        (Jabba.Side memory a, Jabba.Side memory b) = _pair();
        vm.prank(submitter);
        swap.matchOrders(a, b);
        assertEq(treasury.balance, 0);
    }

    function test_rejectingTreasury_revertsAll() public {
        RejectingTreasury rt = new RejectingTreasury();
        swap = new Jabba(payable(address(rt)), FEE);
        (Jabba.Side memory a, Jabba.Side memory b) = _pair();
        vm.prank(submitter);
        vm.expectRevert(Jabba.TreasuryTransferFailed.selector);
        swap.matchOrders{value: FEE}(a, b);
        assertFalse(_nonceUsed(alice, 1));
        assertEq(y.balanceOf(alice), 0);
    }

    function test_revert_zeroTreasury() public {
        vm.expectRevert(Jabba.ZeroAddress.selector);
        new Jabba(payable(address(0)), FEE);
    }
}

contract PostTest is Base {
    function test_post_emitsSameHashAsMatch() public {
        Jabba.Side memory a = _side(aPk, address(x), 10e18, address(y), 25e6, 42);
        bytes32 h = keccak256(abi.encode(alice, _structHash(a)));
        vm.expectEmit(address(swap));
        emit Jabba.OrderPosted(h, alice, address(x), address(y), 10e18, 25e6, 42, a.permit.deadline, a.sig);
        swap.post(a);
        assertEq(swap.orderHash(a), h);
    }

    function test_post_writesNoStorage_I8() public {
        Jabba.Side memory a = _side(aPk, address(x), 10e18, address(y), 25e6, 1);
        vm.record();
        swap.post(a);
        (, bytes32[] memory writes) = vm.accesses(address(swap));
        assertEq(writes.length, 0);
        assertEq(x.balanceOf(address(swap)), 0);
    }

    function test_post_anyoneCanPost_noRights() public {
        Jabba.Side memory a = _side(aPk, address(x), 10e18, address(y), 25e6, 1);
        a.sig = hex"1234"; // firma falsa: si pubblica, ma non e' eseguibile
        vm.prank(makeAddr("spammer"));
        swap.post(a);
        Jabba.Side memory b = _side(bPk, address(y), 25e6, address(x), 10e18, 1);
        vm.prank(submitter);
        vm.expectRevert();
        swap.matchOrders{value: FEE}(a, b);
    }

    function test_post_reverts() public {
        Jabba.Side memory a = _side(aPk, address(x), 10e18, address(y), 25e6, 1);
        a.maker = address(0);
        vm.expectRevert(Jabba.ZeroMaker.selector);
        swap.post(a);
        a = _side(aPk, address(x), 10e18, address(x), 25e6, 1);
        vm.expectRevert(Jabba.SameToken.selector);
        swap.post(a);
        a = _side(aPk, address(x), 0, address(y), 25e6, 1);
        vm.expectRevert(Jabba.ZeroAmount.selector);
        swap.post(a);
    }
}

contract HashTest is Base {
    function test_structHashMatchesPermit2() public view {
        Jabba.Side memory a = _side(aPk, address(x), 10e18, address(y), 25e6, 3);
        assertEq(swap.permitWitnessStructHash(a), _structHash(a));
    }

    function test_differentMakerDifferentOrderHash() public view {
        Jabba.Side memory a = _side(aPk, address(x), 10e18, address(y), 25e6, 3);
        Jabba.Side memory a2 = _side(bPk, address(x), 10e18, address(y), 25e6, 3);
        assertEq(swap.permitWitnessStructHash(a), swap.permitWitnessStructHash(a2));
        assertTrue(swap.orderHash(a) != swap.orderHash(a2));
    }

    function test_writesOnlyTransientDuringMatch_I4() public {
        Jabba.Side memory a = _side(aPk, address(x), 10e18, address(y), 25e6, 1);
        Jabba.Side memory b = _side(bPk, address(y), 25e6, address(x), 10e18, 1);
        vm.record();
        _match(a, b);
        (, bytes32[] memory writes) = vm.accesses(address(swap));
        assertEq(writes.length, 0);
    }
}

contract TokenPerimeterTest is Base {
    function test_feeOnTransfer_reverts() public {
        FeeOnTransferToken f = new FeeOnTransferToken();
        _fund(MockERC20(address(f)), bob, 1e30);
        Jabba.Side memory a = _side(aPk, address(x), 10e18, address(f), 25e18, 1);
        Jabba.Side memory b = _side(bPk, address(f), 25e18, address(x), 10e18, 1);
        vm.prank(submitter);
        vm.expectRevert(Jabba.ShortReceipt.selector);
        swap.matchOrders{value: FEE}(a, b);
    }

    function test_pausedToken_revertsNoNonceConsumed() public {
        PausableBlocklistToken s = new PausableBlocklistToken();
        _fund(MockERC20(address(s)), bob, 1e30);
        s.setPaused(true);
        Jabba.Side memory a = _side(aPk, address(x), 10e18, address(s), 5e18, 1);
        Jabba.Side memory b = _side(bPk, address(s), 5e18, address(x), 10e18, 1);
        vm.prank(submitter);
        vm.expectRevert();
        swap.matchOrders{value: FEE}(a, b);
        assertFalse(_nonceUsed(alice, 1) || _nonceUsed(bob, 1));
        s.setPaused(false);
        _match(a, b);
        assertEq(s.balanceOf(alice), 5e18);
    }

    function test_blockedMaker_reverts() public {
        PausableBlocklistToken s = new PausableBlocklistToken();
        _fund(MockERC20(address(s)), bob, 1e30);
        s.setBlocked(alice, true);
        Jabba.Side memory a = _side(aPk, address(x), 10e18, address(s), 5e18, 1);
        Jabba.Side memory b = _side(bPk, address(s), 5e18, address(x), 10e18, 1);
        vm.prank(submitter);
        vm.expectRevert();
        swap.matchOrders{value: FEE}(a, b);
        assertFalse(_nonceUsed(bob, 1));
    }

    function test_reentrancy_blocked() public {
        ReentrantToken r = new ReentrantToken();
        _fund(MockERC20(address(r)), bob, 1e30);
        Jabba.Side memory a = _side(aPk, address(x), 10e18, address(r), 5e18, 1);
        Jabba.Side memory b = _side(bPk, address(r), 5e18, address(x), 10e18, 1);
        Jabba.Side memory a2 = _side(aPk, address(x), 1e18, address(r), 1e18, 2);
        Jabba.Side memory b2 = _side(bPk, address(r), 1e18, address(x), 1e18, 2);
        r.arm(address(swap), abi.encodeCall(Jabba.matchOrders, (a2, b2)));
        _match(a, b);
        assertTrue(r.attempted());
        assertEq(bytes4(r.lastError()), Jabba.Reentrancy.selector); // il rientro e' stato respinto
        assertFalse(_nonceUsed(alice, 2) || _nonceUsed(bob, 2));
    }

    /// @dev Documenta il limite dichiarato in I2: token non conforme che addebita di piu'.
    function test_nonConformingOvercharge_isOutsidePerimeter() public {
        OverchargeToken o = new OverchargeToken();
        _fund(MockERC20(address(o)), bob, 100e18);
        Jabba.Side memory a = _side(aPk, address(x), 10e18, address(o), 5e18, 1);
        Jabba.Side memory b = _side(bPk, address(o), 5e18, address(x), 10e18, 1);
        _match(a, b);
        assertEq(o.balanceOf(alice), 5e18); // pavimento di ricezione rispettato (I1)
        assertEq(o.balanceOf(bob), 90e18); // B ha ceduto 10, non 5: I2 non garantita fuori perimetro
    }
}

contract FuzzTest is Base {
    /// @dev I1, I2, I4, I5, I6, I7 su importi arbitrari incrociati.
    function testFuzz_conservation(uint96 aSell, uint96 bSell, uint96 aMinSeed, uint96 bMinSeed, address sub) public {
        vm.assume(aSell > 0 && bSell > 0 && sub != address(0) && sub.code.length == 0 && uint160(sub) > 0x100);
        vm.assume(sub != alice && sub != bob && sub != treasury && sub != address(swap) && sub != P2);
        uint256 aMin = bound(aMinSeed, 1, bSell); // A vuole <= cio' che B cede
        uint256 bMin = bound(bMinSeed, 1, aSell); // B vuole <= cio' che A cede
        Jabba.Side memory a = _side(aPk, address(x), aSell, address(y), aMin, 11);
        Jabba.Side memory b = _side(bPk, address(y), bSell, address(x), bMin, 22);
        uint256 xs = x.balanceOf(alice) + x.balanceOf(bob);
        uint256 ys = y.balanceOf(alice) + y.balanceOf(bob);
        uint256 ax = x.balanceOf(alice);
        uint256 by = y.balanceOf(bob);
        vm.deal(sub, FEE);
        vm.prank(sub);
        swap.matchOrders{value: FEE}(a, b);
        assertEq(y.balanceOf(alice), bSell); // I1
        assertEq(x.balanceOf(bob), aSell);
        assertEq(ax - x.balanceOf(alice), aSell); // I2
        assertEq(by - y.balanceOf(bob), bSell);
        assertEq(x.balanceOf(alice) + x.balanceOf(bob), xs); // I6
        assertEq(y.balanceOf(alice) + y.balanceOf(bob), ys);
        assertEq(x.balanceOf(sub) + y.balanceOf(sub), 0); // I7
        assertEq(treasury.balance, FEE); // I5
        assertEq(address(swap).balance + x.balanceOf(address(swap)) + y.balanceOf(address(swap)), 0); // I4
    }

    function testFuzz_uncrossedAlwaysReverts(uint96 aSell, uint96 bSell, uint96 aMin, uint96 bMin) public {
        vm.assume(aSell > 0 && bSell > 0 && aMin > 0 && bMin > 0);
        vm.assume(aSell < bMin || bSell < aMin);
        Jabba.Side memory a = _side(aPk, address(x), aSell, address(y), aMin, 1);
        Jabba.Side memory b = _side(bPk, address(y), bSell, address(x), bMin, 1);
        vm.prank(submitter);
        vm.expectRevert(Jabba.NotCrossed.selector);
        swap.matchOrders{value: FEE}(a, b);
    }
}
