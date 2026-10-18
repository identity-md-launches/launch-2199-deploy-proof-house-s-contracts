// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./Fixture.sol";
import {ArtifactsFactory} from "../src/ArtifactsFactory.sol";
import {ArtifactsPiece} from "../src/ArtifactsPiece.sol";
import {ArtifactsSource} from "../src/ArtifactsSource.sol";
import {KeyProof} from "../src/KeyProof.sol";
import {MockBlockHistory} from "./mocks/Mocks.sol";

/// @dev Nothing paid for waits on one person forever: a draw Chainlink never answers falls back to a future block's
/// hash; an edition whose key never arrives can still be claimed; a key that doesn't open in a resale is proven fake and
/// costs the seller their deposit, while a key that opens can never be; an auction nobody can close gives the bid back.
contract NothingStuckTest is Fixture {
    function _resale(ArtifactsPiece piece, address seller, address buyer, uint256 price) internal {
        vm.prank(seller);
        piece.list(price);
        vm.prank(buyer);
        piece.buy{value: price}(_vk(string(abi.encodePacked("vk", buyer))), address(0));
    }

    // ---------- draws ----------

    function test_fallbackDraw_onlyAfterThreeDays_fromABlockNobodyKnew() public {
        _publishAll();
        _openSale(1 ether);
        vm.prank(alice);
        uint256 id = factory.buy{value: 1 ether}(address(0));
        uint256 at = vm.getBlockNumber();

        vm.roll(at + factory.FALLBACK_BLOCKS() - 1);
        vm.expectRevert(ArtifactsFactory.RequestTooRecent.selector);
        factory.startFallbackDraw(id);
        vm.expectRevert(ArtifactsFactory.NoFallback.selector);
        factory.finishFallbackDraw(id);

        vm.roll(at + factory.FALLBACK_BLOCKS());
        vm.prank(carol); // anyone
        factory.startFallbackDraw(id);
        uint256 target = factory.fallbackBlock(id);
        assertEq(target, vm.getBlockNumber() + factory.FALLBACK_DELAY());
        vm.expectRevert(ArtifactsFactory.FallbackPending.selector);
        factory.startFallbackDraw(id);
        vm.roll(target);
        vm.expectRevert(ArtifactsFactory.FallbackNotReady.selector);
        factory.finishFallbackDraw(id);

        vm.roll(target + 1);
        bytes32 h = keccak256("the target block's hash");
        vm.setBlockhash(target, h);
        vm.prank(bob); // anyone
        factory.finishFallbackDraw(id);
        uint256 edition = factory.requestEdition(id);
        assertEq(edition, uint256(keccak256(abi.encode(h, id))) % 255 + 1, "drawn from the hash, as a Chainlink word");
        assertEq(factory.editionBuyer(edition), alice);
        assertEq(factory.fallbackBlock(id), 0);
        assertEq(factory.assigned(), 1);
        // a late Chainlink answer can't draw a second edition
        vm.expectRevert(ArtifactsFactory.AlreadyFulfilled.selector);
        vrf.fulfill(id, 3);
        vm.expectRevert(ArtifactsFactory.AlreadyFulfilled.selector);
        factory.startFallbackDraw(id);
    }

    /// @dev Once its block exists, a started draw's result is fixed: nobody can re-request it away, nor restart it
    /// while its hash can be read, and after BLOCKHASH's 256 blocks it finishes from the EIP-2935 history.
    function test_fallbackDraw_aStartedDrawsResultStands_finishedFromTheHistory() public {
        _publishAll();
        _openSale(1 ether);
        vm.prank(alice);
        uint256 id = factory.buy{value: 1 ether}(address(0));
        vm.roll(vm.getBlockNumber() + factory.FALLBACK_BLOCKS());
        factory.startFallbackDraw(id);
        uint256 target = factory.fallbackBlock(id);
        vm.etch(factory.BLOCK_HISTORY(), address(new MockBlockHistory()).code);
        bytes32 h = keccak256("the target block's hash");
        MockBlockHistory(factory.BLOCK_HISTORY()).set(target, h);
        vm.roll(target + 5_000); // long past BLOCKHASH's reach
        vm.setBlockhash(target, bytes32(0));
        vm.prank(alice); // the buyer saw the result and dislikes it
        vm.expectRevert(ArtifactsFactory.FallbackPending.selector);
        factory.rerequestRandomness(id);
        vm.prank(curator);
        vm.expectRevert(ArtifactsFactory.FallbackPending.selector);
        factory.rerequestRandomness(id);
        vm.expectRevert(ArtifactsFactory.FallbackPending.selector);
        factory.startFallbackDraw(id);
        factory.finishFallbackDraw(id);
        assertEq(
            factory.requestEdition(id),
            uint256(keccak256(abi.encode(h, id))) % 255 + 1,
            "the same result, whenever finished"
        );
    }

    function test_fallbackDraw_startsAgainOnlyOnceItsHashIsGone() public {
        _publishAll();
        _openSale(1 ether);
        vm.prank(alice);
        uint256 id = factory.buy{value: 1 ether}(address(0));
        vm.roll(vm.getBlockNumber() + factory.FALLBACK_BLOCKS());
        factory.startFallbackDraw(id);
        uint256 target = factory.fallbackBlock(id);
        vm.roll(target + 257); // nobody finished, and no history holds it (none in this test chain)
        vm.setBlockhash(target, bytes32(0));
        vm.expectRevert(ArtifactsFactory.FallbackMissed.selector);
        factory.finishFallbackDraw(id);
        factory.startFallbackDraw(id);
        uint256 again = factory.fallbackBlock(id);
        assertGt(again, target);
        vm.roll(again + 1);
        vm.setBlockhash(again, keccak256("later"));
        factory.finishFallbackDraw(id);
        assertEq(factory.editionsOf(alice).length, 1);
    }

    /// @dev One fallback draw at a time, so nobody can choose the order editions are drawn in once hashes are known:
    /// a second waits until the first is finished, answered by Chainlink, or gone from the history.
    function test_fallbackDraw_oneAtATime() public {
        _publishAll();
        _openSale(1 ether);
        vm.prank(alice);
        uint256 a = factory.buy{value: 1 ether}(address(0));
        vm.prank(bob);
        uint256 b = factory.buy{value: 1 ether}(address(0));
        vm.prank(carol);
        uint256 c = factory.buy{value: 1 ether}(address(0));
        vm.roll(vm.getBlockNumber() + factory.FALLBACK_BLOCKS());
        factory.startFallbackDraw(a);
        assertEq(factory.fallbackInFlight(), a);
        vm.expectRevert(ArtifactsFactory.FallbackBusy.selector);
        factory.startFallbackDraw(b);
        vm.expectRevert(ArtifactsFactory.FallbackPending.selector);
        factory.startFallbackDraw(a);
        uint256 target = factory.fallbackBlock(a);
        vm.roll(target + 1);
        vm.setBlockhash(target, keccak256("a"));
        vm.expectRevert(ArtifactsFactory.FallbackBusy.selector); // ready but unfinished: still a's turn
        factory.startFallbackDraw(b);
        factory.finishFallbackDraw(a);
        assertEq(factory.fallbackInFlight(), 0);
        // b's turn: while it is under way nobody can ask Chainlink again (no answer may land mid-draw)
        factory.startFallbackDraw(b);
        vm.prank(carol);
        vm.expectRevert(ArtifactsFactory.FallbackBusy.selector);
        factory.rerequestRandomness(c);
        // Chainlink answers b meanwhile: that frees the way, but a fallback waits until Chainlink has been silent as long
        vrf.fulfill(b, 7);
        vm.expectRevert(ArtifactsFactory.ChainlinkAnswering.selector);
        factory.startFallbackDraw(c);
        vm.roll(vm.getBlockNumber() + factory.FALLBACK_BLOCKS());
        factory.startFallbackDraw(c);
        assertEq(factory.fallbackInFlight(), c);
        // c's draw is left until its hash is gone: then it is no longer in the way (and may itself start again)
        uint256 tc = factory.fallbackBlock(c);
        vm.roll(tc + 257);
        vm.setBlockhash(tc, bytes32(0));
        factory.startFallbackDraw(c);
        assertGt(factory.fallbackBlock(c), tc);
        assertEq(factory.editionsOf(alice).length + factory.editionsOf(bob).length, 2);
    }

    /// @dev Re-requests never push the fallback back: it counts from the purchase. But a fallback never starts on a
    /// request the coordinator still holds and may yet answer (younger than VRF_RETRY_BLOCKS): the buyer would hold two
    /// draws and pick (review round 4, finding 07f1616add6c). Once Chainlink has dropped it, or answered it without the
    /// callback landing, the fallback may start.
    function test_fallbackDraw_countsFromThePurchase() public {
        _publishAll();
        _openSale(1 ether);
        vm.prank(alice);
        uint256 id = factory.buy{value: 1 ether}(address(0));
        uint256 at = vm.getBlockNumber();
        for (uint256 i; i < 2; ++i) {
            vm.roll(vm.getBlockNumber() + factory.VRF_RETRY_BLOCKS());
            vm.prank(curator);
            id = factory.rerequestRandomness(id);
            assertEq(factory.purchaseBlock(id), at);
        }
        uint256 lastRequested = factory.requestBlock(id);
        vm.roll(at + factory.FALLBACK_BLOCKS());
        // three days after paying, but the last request is under a day old and Chainlink still holds it
        vm.expectRevert(ArtifactsFactory.RequestTooRecent.selector);
        factory.startFallbackDraw(id);
        vm.roll(lastRequested + factory.VRF_RETRY_BLOCKS());
        factory.startFallbackDraw(id); // Chainlink has dropped it by now
        assertGt(factory.fallbackBlock(id), 0);
    }

    /// @dev The same purchase, when the coordinator answered the young request but its callback failed: it no longer
    /// holds the request, so nothing can answer it and the fallback may start at once.
    function test_fallbackDraw_startsOnAYoungRequestTheCoordinatorNoLongerHolds() public {
        _publishAll();
        _openSale(1 ether);
        vm.prank(alice);
        uint256 id = factory.buy{value: 1 ether}(address(0));
        uint256 at = vm.getBlockNumber();
        vm.roll(at + factory.FALLBACK_BLOCKS());
        vm.prank(alice);
        id = factory.rerequestRandomness(id);
        vm.expectRevert(ArtifactsFactory.RequestTooRecent.selector);
        factory.startFallbackDraw(id);
        vrf.answerWithFailedCallback(id);
        factory.startFallbackDraw(id);
        assertEq(factory.fallbackInFlight(), id);
    }

    function test_callbackGasCanOnlyGoUpOnceTheSaleOpens() public {
        vm.startPrank(curator);
        factory.setVRFCallbackGas(400_000);
        factory.setVRFCallbackGas(300_000); // before the sale, either way
        vm.stopPrank();
        _publishAll();
        _openSale(1 ether);
        vm.startPrank(curator);
        vm.expectRevert(ArtifactsFactory.BadCallbackGas.selector);
        factory.setVRFCallbackGas(299_999);
        factory.setVRFCallbackGas(350_000);
        vm.stopPrank();
    }

    function test_fallbackDraw_chainlinkStillWinsIfItAnswersFirst() public {
        _publishAll();
        _openSale(1 ether);
        vm.prank(alice);
        uint256 id = factory.buy{value: 1 ether}(address(0));
        vm.roll(vm.getBlockNumber() + factory.FALLBACK_BLOCKS());
        factory.startFallbackDraw(id);
        vrf.fulfill(id, 41); // a late answer arrives first: it stands
        assertEq(factory.requestEdition(id), 41 % 255 + 1);
        vm.roll(factory.fallbackBlock(id) + 1);
        vm.expectRevert(ArtifactsFactory.AlreadyFulfilled.selector);
        factory.finishFallbackDraw(id);
        assertEq(factory.editionsOf(alice).length, 1);
    }

    // ---------- edition keys ----------

    function test_claimWithoutAKey_after30Days_thenTheKeyGoesIntoThePiece() public {
        _publishAll();
        _openSale(1 ether);
        uint256 edition = _buyAndAssign(alice, address(0), 7);
        bytes32 vk = keccak256("alice vk");
        vm.prank(alice);
        factory.registerViewingKey(vk);
        vm.prank(alice);
        vm.expectRevert(ArtifactsFactory.KeyNotPosted.selector);
        factory.claim(edition);
        vm.warp(vm.getBlockTimestamp() + factory.KEY_WAIT());
        vm.prank(alice);
        ArtifactsPiece piece = ArtifactsPiece(factory.claim(edition));
        assertEq(piece.ownerOf(1), alice, "the buyer holds the token");
        assertEq(piece.wrappedKey().length, 0, "no key yet");
        assertEq(piece.viewingKeyOf(alice), vk, "the viewing key came with the claim");
        // the curator's key still arrives, into the piece itself, once
        vm.prank(curator);
        factory.postWrappedKey(edition, "late key");
        assertEq(piece.wrappedKey(), bytes("late key"));
        vm.prank(curator);
        vm.expectRevert(ArtifactsPiece.KeyAlreadyPosted.selector);
        factory.postWrappedKey(edition, "another");
        vm.prank(bob);
        vm.expectRevert();
        piece.rewrapFor("bob's");
    }

    function test_curatorReKeysAPieceItsPreviousOwnerNeverDid() public {
        _publishAll();
        _openSale(1 ether);
        uint256 edition = _buyAndAssign(alice, address(0), 9);
        ArtifactsPiece piece = _claim(alice, edition);
        vm.prank(alice);
        piece.transferFrom(alice, bob, 1); // sold elsewhere; alice never re-keys
        assertEq(piece.wrappedKey().length, 0);
        vm.prank(bob);
        piece.registerViewingKey(keccak256("bob vk"));
        vm.prank(curator);
        factory.postWrappedKey(edition, "for bob");
        assertEq(piece.wrappedKey(), bytes("for bob"));
        assertEq(piece.previousOwner(), address(0));
    }

    // ---------- the market's escrow ----------

    function _sold() internal returns (ArtifactsPiece piece) {
        _publishAll();
        _openSale(1 ether);
        piece = _claim(alice, _buyAndAssign(alice, address(0), 5));
        _resale(piece, alice, bob, 2 ether);
    }

    KeyProof.Proof internal noProof;
    string internal bobVk = string(abi.encodePacked("vk", makeAddr("bob")));

    function test_the72HoursCountFromTheKey() public {
        ArtifactsPiece piece = _sold();
        vm.warp(vm.getBlockTimestamp() + 60 hours); // the seller is slow
        _postKey(piece, alice, 0.2 ether);
        uint256 keyAt = vm.getBlockTimestamp();
        vm.warp(keyAt + 71 hours); // 131 hours after paying: still the buyer's time to check
        vm.prank(carol);
        vm.expectRevert(ArtifactsPiece.TooEarly.selector);
        piece.release();
        vm.warp(keyAt + 72 hours);
        vm.prank(carol);
        piece.release();
        assertEq(piece.ownerOf(1), bob);
        assertEq(piece.pendingWithdrawals(alice), 2 ether - 0.15 ether + 0.2 ether, "proceeds and the deposit back");
    }

    function test_theDepositIsExactly10Percent() public {
        ArtifactsPiece piece = _sold();
        assertEq(piece.depositFor(2 ether), 0.2 ether);
        _postKeyReverts(piece, alice, 0.1 ether, ArtifactsPiece.WrongPrice.selector);
        _postKeyReverts(piece, alice, 0, ArtifactsPiece.WrongPrice.selector);
        _postKey(piece, alice, 0.2 ether);
        (,,,,,,,, bytes32 vk, uint256 deposit) = piece.escrow();
        assertEq(deposit, 0.2 ether);
        assertEq(vk, _vk(string(abi.encodePacked("vk", bob))), "the buyer's key for this purchase, fixed in the escrow");
    }

    function test_aJunkKeyIsProvenFake_paymentAndDepositToTheBuyer() public {
        ArtifactsPiece piece = _sold();
        bytes memory sellersKey = piece.wrappedKey();
        _postKey(piece, alice, 0.2 ether); // well formed, with the seller's proof, but its key is junk
        KeyProof.Proof memory proof = _fakeProof(address(piece), bob, bobVk, "key");
        vm.prank(carol);
        vm.expectRevert(ArtifactsPiece.NotEscrowBuyer.selector);
        piece.proveFakeKey(proof);
        vm.warp(vm.getBlockTimestamp() + 100 hours); // until the payment is released, the proof stands
        uint256 before = bob.balance;
        vm.prank(bob);
        piece.proveFakeKey(proof);
        vm.prank(bob);
        piece.withdraw();
        assertEq(bob.balance - before, 2.2 ether, "the payment and the seller's deposit");
        assertEq(piece.ownerOf(1), alice, "the seller keeps the piece");
        assertEq(piece.wrappedKey(), sellersKey, "and its own key");
        (, address seller, address buyer,,,,,,,) = piece.escrow();
        assertEq(seller, address(0), "the listing ended");
        assertEq(buyer, address(0));
        assertEq(address(piece).balance, 0);
    }

    function test_noProofBeforeAKey_andTheSellerCantDodgeOne() public {
        ArtifactsPiece piece = _sold();
        vm.prank(bob);
        vm.expectRevert(ArtifactsPiece.KeyNotPosted.selector);
        piece.proveFakeKey(noProof);
        _postKey(piece, alice, 0.2 ether);
        vm.prank(alice);
        vm.expectRevert(ArtifactsPiece.KeyAlreadyPosted.selector);
        piece.refundBuyer(); // once the key is sent, only release or a proof ends the sale
        vm.prank(bob);
        piece.proveFakeKey(_fakeProof(address(piece), bob, bobVk, "key"));
    }

    /// @dev Only a key its sender made can be posted: malformed bytes, a key without the proof, one built from someone
    /// else's E (its e unknown), and a proof made for another buyer or viewing key are all refused.
    function test_onlyAKeyTheSellerMadeCanBePosted() public {
        ArtifactsPiece piece = _sold();
        (bytes memory wrapped, address r, uint256 z) = _sellerKey(piece, "key");
        vm.startPrank(alice);
        vm.expectRevert(ArtifactsPiece.BadWrappedKey.selector);
        piece.postEscrowKey{value: 0.2 ether}("not a key", r, z);
        vm.expectRevert(ArtifactsPiece.BadWrappedKey.selector);
        piece.postEscrowKey{value: 0.2 ether}(abi.encodePacked(wrapped, uint8(0)), r, z); // 66 bytes
        vm.expectRevert(ArtifactsPiece.BadWrappedKey.selector);
        piece.postEscrowKey{value: 0.2 ether}(wrapped, r, z + 1);
        vm.expectRevert(ArtifactsPiece.BadWrappedKey.selector);
        piece.postEscrowKey{value: 0.2 ether}(wrapped, address(uint160(r) ^ 1), z);
        vm.stopPrank();
        // the same E with another masked key: the proof binds the whole wrapped key
        bytes memory other = wrapped;
        other[64] = other[64] ^ 0x01;
        vm.prank(alice);
        vm.expectRevert(ArtifactsPiece.BadWrappedKey.selector);
        piece.postEscrowKey{value: 0.2 ether}(other, r, z);
        // a proof made for a different viewing key (the buyer changed theirs after the seller read it)
        (r, z) = _wrapProof(address(piece), bob, _vk("another key"), wrapped, _eOf("key"));
        vm.prank(alice);
        vm.expectRevert(ArtifactsPiece.BadWrappedKey.selector);
        piece.postEscrowKey{value: 0.2 ether}(wrapped, r, z);
        _postKey(piece, alice, 0.2 ether);
    }

    /// @dev A key in a pending postEscrowKey is readable: the buyer can't take it and cancel ahead of it, because only
    /// the seller can end the sale for 24 hours after paying.
    function test_theBuyerCantCancelUnderAPendingKey() public {
        ArtifactsPiece piece = _sold();
        vm.prank(bob);
        vm.expectRevert(ArtifactsPiece.TooEarly.selector);
        piece.cancel();
        _postKey(piece, alice, 0.2 ether); // lands; the buyer's cancel never could have
        vm.prank(bob);
        vm.expectRevert(ArtifactsPiece.KeyAlreadyPosted.selector);
        piece.cancel();
    }

    function test_aSilentSellerLetsTheBuyerCancelAfter24Hours() public {
        ArtifactsPiece piece = _sold();
        vm.warp(vm.getBlockTimestamp() + 24 hours - 1);
        vm.prank(bob);
        vm.expectRevert(ArtifactsPiece.TooEarly.selector);
        piece.cancel();
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.prank(bob);
        piece.cancel();
        assertEq(piece.pendingWithdrawals(bob), 2 ether);
    }

    function test_theSellerCanRefundBeforeSendingAKey() public {
        ArtifactsPiece piece = _sold();
        bytes memory sellersKey = piece.wrappedKey();
        vm.prank(carol);
        vm.expectRevert(ArtifactsPiece.NotSeller.selector);
        piece.refundBuyer();
        vm.prank(alice);
        piece.refundBuyer();
        assertEq(piece.pendingWithdrawals(bob), 2 ether);
        assertEq(piece.ownerOf(1), alice);
        assertEq(piece.wrappedKey(), sellersKey, "the seller's key never left");
        vm.prank(alice);
        vm.expectRevert(ArtifactsPiece.NotSeller.selector);
        piece.refundBuyer(); // the listing ended with it
    }

    function test_aBuyerNeedsAViewingKeyAProofCanUse() public {
        _publishAll();
        _openSale(1 ether);
        ArtifactsPiece piece = _claim(alice, _buyAndAssign(alice, address(0), 5));
        vm.prank(alice);
        piece.list(1 ether);
        vm.prank(bob);
        vm.expectRevert(ArtifactsPiece.NoViewingKey.selector);
        piece.buy{value: 1 ether}(bytes32(uint256(5)), address(0)); // not on the curve: no key could reach it
    }

    // ---------- the real cryptography: keys and proofs made by site/sealcrypto.js ----------

    /// @dev A piece runtime copy at the address the fixture proofs were made for, with
    /// the fixture's id and key commitment, held by alice; bob is the fixture's buyer, bought in with its viewing key.
    function _realPiece() internal returns (ArtifactsPiece piece, string memory json, address buyer) {
        json = vm.readFile("test/fixtures/keyproof.json");
        address at = vm.parseJsonAddress(json, ".ctx.piece");
        buyer = vm.parseJsonAddress(json, ".ctx.buyer");
        vm.chainId(vm.parseJsonUint(json, ".ctx.chainId"));
        vm.etch(at, address(pieceImpl).code);
        piece = ArtifactsPiece(at);
        vm.prank(address(factory));
        piece.initialize(
            address(factory),
            address(house),
            vm.parseJsonUint(json, ".pieceId"),
            alice,
            _traits(1),
            address(0),
            vm.parseJsonBytes32(json, ".commitment"),
            "alice's own key",
            false,
            bytes32(0)
        );
        vm.prank(alice);
        piece.list(1 ether);
        vm.deal(buyer, 10 ether);
        vm.prank(buyer);
        piece.buy{value: 1 ether}(vm.parseJsonBytes32(json, ".viewingKey"), address(0));
    }

    /// @dev alice posts a fixture's wrapped key, with the seller's proof sealcrypto.js made for it.
    function _postReal(ArtifactsPiece piece, string memory json, string memory name) internal {
        string[] memory sp = vm.parseJsonStringArray(json, string.concat(".", name, ".seller"));
        bytes memory wrapped = vm.parseJsonBytes(json, string.concat(".", name, ".wrapped"));
        vm.prank(alice);
        piece.postEscrowKey{value: 0.1 ether}(wrapped, vm.parseAddress(sp[0]), vm.parseUint(sp[1]));
    }

    function _proofOf(string memory json, string memory name) internal pure returns (KeyProof.Proof memory) {
        string[] memory a = vm.parseJsonStringArray(json, string.concat(".", name, ".proof"));
        return KeyProof.Proof(
            vm.parseUint(a[0]),
            vm.parseUint(a[1]),
            vm.parseUint(a[2]),
            vm.parseUint(a[3]),
            vm.parseUint(a[4]),
            vm.parseUint(a[5]),
            vm.parseUint(a[6]),
            vm.parseUint(a[7]),
            vm.parseUint(a[8])
        );
    }

    function test_realKeys_anHonestKeyCanNeverBeProvenFake() public {
        (ArtifactsPiece piece, string memory json, address buyer) = _realPiece();
        _postReal(piece, json, "honest");
        vm.prank(buyer);
        vm.expectRevert(ArtifactsPiece.KeyOpens.selector);
        piece.proveFakeKey(_proofOf(json, "honest"));
        // nor with another key's proof
        vm.prank(buyer);
        vm.expectRevert(KeyProof.BadProof.selector);
        piece.proveFakeKey(_proofOf(json, "junkKey"));
        vm.prank(buyer);
        piece.release();
        assertEq(piece.ownerOf(1), buyer);
        assertEq(
            piece.pendingWithdrawals(alice),
            1 ether - 0.075 ether + 0.1 ether,
            "the honest seller is paid, deposit back"
        );
    }

    function test_realKeys_aJunkKeyIsProvenFake() public {
        (ArtifactsPiece piece, string memory json, address buyer) = _realPiece();
        _postReal(piece, json, "junkKey");
        uint256 g = gasleft();
        vm.prank(buyer);
        piece.proveFakeKey(_proofOf(json, "junkKey"));
        emit log_named_uint("gas for the buyer's proveFakeKey", g - gasleft());
        assertEq(piece.pendingWithdrawals(buyer), 1.1 ether);
        assertEq(piece.ownerOf(1), alice);
    }

    function test_realKeys_theRightKeyWrappedToAnotherKeyIsFake() public {
        (ArtifactsPiece piece, string memory json, address buyer) = _realPiece();
        _postReal(piece, json, "wrongRecipient");
        vm.prank(buyer);
        piece.proveFakeKey(_proofOf(json, "wrongRecipient"));
        assertEq(piece.pendingWithdrawals(buyer), 1.1 ether);
    }

    function test_realKeys_theBuyerCantSwapViewingKeysToFrameTheSeller() public {
        (ArtifactsPiece piece, string memory json, address buyer) = _realPiece();
        _postReal(piece, json, "honest");
        vm.prank(buyer);
        piece.registerViewingKey(_vk("a different key")); // the escrow keeps the key it was bought with
        vm.prank(buyer);
        vm.expectRevert(ArtifactsPiece.KeyOpens.selector);
        piece.proveFakeKey(_proofOf(json, "honest"));
    }

    // ---------- THE SOURCE's auction ----------

    function test_anAuctionNobodyCanCloseGivesTheBidBack() public {
        vm.startPrank(curator);
        source.storeRendererChunk("page");
        source.lock(SEALED_SEED, SOURCE_COMMITMENT);
        source.setAuction(1 ether, uint64(vm.getBlockTimestamp() + 1 days));
        vm.stopPrank();
        vm.prank(alice);
        source.bid{value: 1.5 ether}(address(0));
        uint256 end = source.endTime();
        // closing fails: the house stops accepting this sale
        vm.prank(curator);
        house.setSaleModule(address(source), false);
        vm.warp(end);
        vm.expectRevert();
        source.settle();
        vm.warp(end + source.SETTLE_GRACE() - 1);
        vm.expectRevert(ArtifactsSource.AuctionNotEnded.selector);
        source.voidUnsettled();
        vm.warp(end + source.SETTLE_GRACE());
        vm.prank(carol); // anyone
        source.voidUnsettled();
        assertEq(source.refunds(alice), 1.5 ether);
        assertFalse(source.auctionOpen());
        uint256 before = alice.balance;
        vm.prank(alice);
        source.withdrawRefund();
        assertEq(alice.balance - before, 1.5 ether);
        vm.expectRevert(ArtifactsSource.AuctionNotOpen.selector);
        source.settle();
        // the curator can fix it and open the auction again
        vm.prank(curator);
        house.setSaleModule(address(source), true);
        vm.prank(curator);
        source.setAuction(1 ether, uint64(vm.getBlockTimestamp() + 1 days));
        assertTrue(source.auctionOpen());
    }

    function test_anAuctionClosedInTimeCannotBeVoided() public {
        vm.startPrank(curator);
        source.storeRendererChunk("page");
        source.lock(SEALED_SEED, SOURCE_COMMITMENT);
        source.setAuction(1 ether, uint64(vm.getBlockTimestamp() + 1 days));
        vm.stopPrank();
        vm.prank(alice);
        source.bid{value: 1 ether}(address(0));
        vm.warp(source.endTime());
        source.settle();
        vm.warp(vm.getBlockTimestamp() + 30 days);
        vm.expectRevert(ArtifactsSource.AuctionNotOpen.selector);
        source.voidUnsettled();
    }
}
