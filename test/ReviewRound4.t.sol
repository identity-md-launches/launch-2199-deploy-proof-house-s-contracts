// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./Fixture.sol";
import {ArtifactsFactory} from "../src/ArtifactsFactory.sol";
import {ArtifactsSource} from "../src/ArtifactsSource.sol";
import {HolderGate} from "../src/base/HolderGate.sol";
import {MockSeats} from "./mocks/MockSeats.sol";
import {MockPoints, MockBlockHistory} from "./mocks/Mocks.sol";

/// @dev A seat contract whose ownerOf answers a word with bits above the address: not a holder, never a decoding revert.
contract DirtySeats {
    fallback() external {
        assembly {
            mstore(0, not(0))
            return(0, 32)
        }
    }
}

/// @dev Review round 4 (the launch's independent review): a fallback draw can never compete with a Chainlink answer
/// the buyer could still receive (07f1616add6c), a gate address with no code counts as not held instead of reverting
/// every gated buy or bid (20ca2ef1fdca), and a fallback draw nobody finished while its hash could be read no longer
/// strands the buyer's re-request (07bde3893de7).
contract ReviewRound4Test is Fixture {
    bytes4 internal constant POINTS_SEL = bytes4(keccak256("points(address)"));

    // ---------- 07f1616add6c: one draw at a time per purchase ----------

    /// @dev Re-requesting and starting the fallback in one block would give the buyer two draws: the fallback's result
    /// becomes public first and they keep whichever they like. A fallback waits until Chainlink can no longer answer
    /// the request (it has dropped it after VRF_RETRY_BLOCKS, or already answered it).
    function test_noFallbackOnARequestChainlinkMayStillAnswer() public {
        _publishAll();
        _openSale(1 ether);
        vm.prank(alice);
        uint256 id1 = factory.buy{value: 1 ether}(address(0));
        vm.roll(vm.getBlockNumber() + factory.FALLBACK_BLOCKS());
        vm.prank(alice);
        uint256 id2 = factory.rerequestRandomness(id1);
        vm.expectRevert(ArtifactsFactory.RequestTooRecent.selector);
        factory.startFallbackDraw(id2);
        vm.roll(vm.getBlockNumber() + factory.VRF_RETRY_BLOCKS() - 1);
        vm.expectRevert(ArtifactsFactory.RequestTooRecent.selector);
        factory.startFallbackDraw(id2);
        vm.roll(vm.getBlockNumber() + 1);
        factory.startFallbackDraw(id2);
        assertEq(factory.fallbackInFlight(), id2);
    }

    /// @dev Once a started draw's block is behind us its hash is public: a Chainlink answer for that request is refused
    /// and the draw finishes from the hash, whoever finishes it. Before the block, an answer still stands.
    function test_noChainlinkAnswerOnceTheFallbackHashIsPublic() public {
        _publishAll();
        _openSale(1 ether);
        vm.prank(alice);
        uint256 id = factory.buy{value: 1 ether}(address(0));
        vm.roll(vm.getBlockNumber() + factory.FALLBACK_BLOCKS());
        factory.startFallbackDraw(id);
        uint256 target = factory.fallbackBlock(id);
        vm.roll(target + 1);
        bytes32 h = keccak256("the target block's hash");
        vm.setBlockhash(target, h);
        uint256 known = uint256(keccak256(abi.encode(h, id))) % 255 + 1;
        vm.expectRevert(ArtifactsFactory.FallbackPending.selector);
        vrf.fulfill(id, known + 1); // a word drawing another edition
        assertEq(factory.requestEdition(id), 0, "nothing assigned by the refused answer");
        assertEq(factory.lastAnsweredBlock(), 0, "a refused answer is no answer");
        vm.prank(bob); // anyone
        factory.finishFallbackDraw(id);
        assertEq(factory.requestEdition(id), known, "the result everyone could read is the result");
        assertEq(factory.editionsOf(alice).length, 1);
    }

    /// @dev Fuzz: whichever word Chainlink would bring after the hash is public, the edition is the hash's.
    function testFuzz_theFallbackResultStandsAgainstAnyLateWord(uint256 word, bytes32 h) public {
        vm.assume(h != bytes32(0));
        _publishAll();
        _openSale(1 ether);
        vm.prank(alice);
        uint256 id = factory.buy{value: 1 ether}(address(0));
        vm.roll(vm.getBlockNumber() + factory.FALLBACK_BLOCKS());
        factory.startFallbackDraw(id);
        uint256 target = factory.fallbackBlock(id);
        vm.roll(target + 1 + (word % 200));
        vm.setBlockhash(target, h);
        vm.expectRevert(ArtifactsFactory.FallbackPending.selector);
        vrf.fulfill(id, word);
        factory.finishFallbackDraw(id);
        assertEq(factory.requestEdition(id), uint256(keccak256(abi.encode(h, id))) % 255 + 1);
    }

    // ---------- 07bde3893de7: a dead draw does not strand the purchase ----------

    /// @dev A draw nobody finished while its hash could be read is dead: finishing fails, and (as before) it may start
    /// again once Chainlink is silent; but while Chainlink answers others, the buyer or the curator may now simply ask
    /// it again instead of waiting for three silent days. The re-request clears the dead draw.
    function test_aDeadFallbackDrawCanBeRerequested() public {
        _publishAll();
        _openSale(1 ether);
        vm.prank(alice);
        uint256 id = factory.buy{value: 1 ether}(address(0));
        uint256 at = vm.getBlockNumber();
        vm.roll(at + factory.FALLBACK_BLOCKS());
        factory.startFallbackDraw(id);
        uint256 target = factory.fallbackBlock(id);
        vm.roll(target + 8_193); // gone from BLOCKHASH and the history alike (none in this test chain)
        vm.setBlockhash(target, bytes32(0));
        vm.expectRevert(ArtifactsFactory.FallbackMissed.selector);
        factory.finishFallbackDraw(id);
        // Chainlink is answering others
        vm.prank(bob);
        uint256 idBob = factory.buy{value: 1 ether}(address(0));
        vrf.fulfill(idBob, 5);
        vm.expectRevert(ArtifactsFactory.ChainlinkAnswering.selector);
        factory.startFallbackDraw(id);
        // alice (or the curator) asks again at once
        vm.prank(alice);
        uint256 fresh = factory.rerequestRandomness(id);
        assertEq(factory.fallbackBlock(id), 0, "the dead draw is cleared");
        assertEq(factory.fallbackInFlight(), 0);
        assertEq(factory.requestBuyer(id), address(0), "the old id is forgotten");
        assertEq(factory.purchaseBlock(fresh), at, "the fresh request still serves the original purchase");
        vrf.fulfill(fresh, 9);
        assertEq(factory.editionsOf(alice).length, 1, "exactly one edition for the purchase");
        assertEq(factory.assigned(), 2);
    }

    /// @dev A live draw (its hash still readable) still cannot be re-requested away, by anyone.
    function test_aLiveFallbackDrawStillCannotBeRerequested() public {
        _publishAll();
        _openSale(1 ether);
        vm.prank(alice);
        uint256 id = factory.buy{value: 1 ether}(address(0));
        vm.roll(vm.getBlockNumber() + factory.FALLBACK_BLOCKS());
        factory.startFallbackDraw(id);
        uint256 target = factory.fallbackBlock(id);
        vm.etch(factory.BLOCK_HISTORY(), address(new MockBlockHistory()).code);
        MockBlockHistory(factory.BLOCK_HISTORY()).set(target, keccak256("h"));
        vm.roll(target + 8_000);
        vm.setBlockhash(target, bytes32(0));
        vm.prank(alice);
        vm.expectRevert(ArtifactsFactory.FallbackPending.selector);
        factory.rerequestRandomness(id);
        vm.prank(curator);
        vm.expectRevert(ArtifactsFactory.FallbackPending.selector);
        factory.rerequestRandomness(id);
        factory.finishFallbackDraw(id);
        assertEq(factory.editionsOf(alice).length, 1);
    }

    // ---------- 20ca2ef1fdca: a gate address with no code counts as not held ----------

    function _openGatedSale(address seatsAddr, address tokenAddr, address memberAddr) internal {
        _publishAll();
        vm.startPrank(curator);
        factory.setGate(seatsAddr, tokenAddr, tokenAddr == address(0) ? 0 : 1, 7 days);
        if (memberAddr != address(0)) factory.setMemberGate(memberAddr, POINTS_SEL, 1);
        vm.stopPrank();
        _openSale(1 ether);
    }

    function test_gateToken_noCode_isNotHeld_andMembersStillBuy() public {
        address eoaToken = makeAddr("not-a-token");
        MockPoints points = new MockPoints();
        points.set(bob, 1);
        _openGatedSale(address(0), eoaToken, address(points));
        assertFalse(factory.holdsToken(alice));
        assertFalse(factory.holdsToken(bob));
        // a member buys inside the window
        vm.prank(bob);
        factory.buy{value: 1 ether}(address(0));
        assertEq(factory.sold(), 1);
        // a non-holder is refused for the right reason
        vm.prank(alice);
        vm.expectRevert(HolderGate.NotEligible.selector);
        factory.buy{value: 1 ether}(address(0));
        vm.prank(alice);
        vm.expectRevert(HolderGate.NotEligible.selector);
        factory.buyMany{value: 2 ether}(2, address(0));
        // after the window: anyone
        vm.warp(vm.getBlockTimestamp() + 7 days);
        vm.prank(alice);
        factory.buy{value: 1 ether}(address(0));
        assertEq(factory.sold(), 2);
    }

    function test_gateSeats_noCode_isNotHeld() public {
        address eoaSeats = makeAddr("not-seats");
        _openGatedSale(eoaSeats, address(imd), address(0));
        assertFalse(factory.holdsSeat(alice));
        vm.prank(alice);
        vm.expectRevert(HolderGate.NotEligible.selector);
        factory.buyWithSeat{value: 1 ether}(1, 1, address(0));
        // the token way in still works beside it
        imd.mint(alice, 1);
        vm.prank(alice);
        factory.buy{value: 1 ether}(address(0));
        assertEq(factory.sold(), 1);
    }

    /// @dev An answer with bits above the address is no owner (Solidity's decoder would have reverted in the caller).
    function test_gateSeats_dirtyOwnerWord_isNotHeld() public {
        _openGatedSale(address(new DirtySeats()), address(0), address(0));
        vm.prank(alice);
        vm.expectRevert(HolderGate.NotEligible.selector);
        factory.buyWithSeat{value: 1 ether}(1, 1, address(0));
        assertTrue(factory.holdsSeat(alice), "balanceOf answered one word: held");
    }

    /// @dev A real seat contract still answers as before: owners buy with their seat, others don't.
    function test_gateSeats_withCode_unchanged() public {
        MockSeats seats = new MockSeats();
        seats.mint(bob, 42);
        _openGatedSale(address(seats), address(0), address(0));
        assertTrue(factory.holdsSeat(bob));
        assertFalse(factory.holdsSeat(alice));
        vm.prank(bob);
        factory.buyWithSeat{value: 1 ether}(42, 1, address(0));
        vm.prank(alice);
        vm.expectRevert(HolderGate.NotEligible.selector);
        factory.buyWithSeat{value: 1 ether}(42, 1, address(0));
        vm.prank(alice);
        vm.expectRevert(HolderGate.NotEligible.selector);
        factory.buyWithSeat{value: 1 ether}(43, 1, address(0)); // no such seat: ownerOf reverts
    }

    /// @dev THE SOURCE's window: code-less seats and token refuse with NotEligible, and a member still bids.
    function test_source_gateNoCode_bidsRefusedNotReverted_membersBid() public {
        MockPoints points = new MockPoints();
        points.set(bob, 3);
        vm.startPrank(curator);
        source.storeRendererChunk("page");
        source.lock(SEALED_SEED, SOURCE_COMMITMENT);
        source.setGate(makeAddr("not-seats"), makeAddr("not-a-token"), 1, 1 days);
        source.setMemberGate(address(points), POINTS_SEL, 1);
        source.setAuction(1 ether, uint64(vm.getBlockTimestamp() + 2 days));
        vm.stopPrank();
        assertFalse(source.holdsSeat(alice));
        assertFalse(source.holdsToken(alice));
        vm.prank(alice);
        vm.expectRevert(HolderGate.NotEligible.selector);
        source.bid{value: 1 ether}(address(0));
        vm.prank(bob);
        source.bid{value: 1 ether}(address(0));
        assertEq(source.highBidder(), bob);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.prank(alice);
        source.bid{value: 1.1 ether}(address(0));
        assertEq(source.highBidder(), alice);
    }

    /// @dev Fuzz: any gate token or seats address, with or without code, never makes the views revert.
    function testFuzz_gateViewsNeverRevert(address tokenAddr, address seatsAddr, address who) public {
        vm.assume(tokenAddr != address(0) && seatsAddr != address(0));
        vm.assume(uint160(tokenAddr) > 0xff && uint160(seatsAddr) > 0xff); // not precompiles
        vm.prank(curator);
        factory.setGate(seatsAddr, tokenAddr, 1, 1 days);
        factory.holdsToken(who);
        factory.holdsSeat(who);
    }
}
