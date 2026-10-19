// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./Fixture.sol";
import {ArtifactsFactory} from "../src/ArtifactsFactory.sol";
import {ArtifactsPiece} from "../src/ArtifactsPiece.sol";
import {ERC721Lite} from "../src/base/ERC721Lite.sol";
import {TwoStepOwnable} from "../src/base/TwoStepOwnable.sol";
import {Traits} from "../src/interfaces/Interfaces.sol";
import {Reenterer, MockVRFCoordinator} from "./mocks/Mocks.sol";
import {Base64Decode} from "./utils/Base64Decode.sol";
import {Seal} from "../src/libs/Seal.sol";

contract ArtifactsFactoryTest is Fixture {
    function test_publishAndLock_accessAndFailures() public {
        vm.prank(alice);
        vm.expectRevert(TwoStepOwnable.NotOwner.selector);
        factory.setPiece(1, _traits(1), "c", keccak256("k"));
        vm.startPrank(curator);
        vm.expectRevert(ArtifactsFactory.BadPieceId.selector);
        factory.setPiece(0, _traits(0), "c", keccak256("k"));
        vm.expectRevert(ArtifactsFactory.BadPieceId.selector);
        factory.setPiece(256, _traits(0), "c", keccak256("k"));
        vm.expectRevert(ArtifactsFactory.NotAllSet.selector);
        factory.lock();
        vm.stopPrank();
        _publishAll();
        assertTrue(factory.locked());
        assertEq(factory.piecesSet(), 255);
        assertEq(factory.ciphertextOf(7), abi.encodePacked("ciphertext", uint256(7)));
        assertEq(factory.commitmentOf(7), keccak256(abi.encodePacked("K", uint256(7))));
        assertEq(factory.traitsOf(7).title, "FLUX");
        vm.prank(curator);
        vm.expectRevert(ArtifactsFactory.IsLocked.selector);
        factory.setPiece(7, _traits(7), "c", keccak256("k"));
    }

    function test_saleControl() public {
        vm.startPrank(curator);
        vm.expectRevert(ArtifactsFactory.NotLocked.selector);
        factory.setSaleOpen(true);
        vm.stopPrank();
        _publishAll();
        vm.startPrank(curator);
        vm.expectRevert(ArtifactsFactory.WrongPrice.selector);
        factory.setSaleOpen(true);
        vm.expectRevert(ArtifactsFactory.WrongPrice.selector);
        factory.setPrice(0);
        factory.setPrice(1 ether);
        factory.setSaleOpen(true);
        vm.expectRevert(ArtifactsFactory.SaleIsOpen.selector);
        factory.setPrice(2 ether);
        factory.setSaleOpen(false);
        factory.setPrice(2 ether);
        vm.stopPrank();
        assertEq(factory.price(), 2 ether);
        assertEq(factory.remaining(), 255);
    }

    /// @dev A purchase whose VRF request is never answered can be re-requested by the curator or the buyer after the
    /// retry window; the old id is forgotten and the buyer still gets exactly one edition.
    function test_rerequestRandomnessAfterDroppedRequest() public {
        _publishAll();
        _openSale(1 ether);
        vm.prank(alice);
        uint256 id = factory.buy{value: 1 ether}(address(0));
        assertEq(factory.requestEdition(id), 0);
        assertEq(factory.sold(), 1);
        vm.prank(curator);
        vm.expectRevert(ArtifactsFactory.RequestTooRecent.selector);
        factory.rerequestRandomness(id);
        vm.prank(alice);
        vm.expectRevert(ArtifactsFactory.RequestTooRecent.selector);
        factory.rerequestRandomness(id);
        vm.roll(vm.getBlockNumber() + factory.VRF_RETRY_BLOCKS());
        vm.prank(bob);
        vm.expectRevert(ArtifactsFactory.NotBuyer.selector);
        factory.rerequestRandomness(id);
        vm.prank(curator);
        vm.expectRevert(ArtifactsFactory.UnknownRequest.selector);
        factory.rerequestRandomness(id + 99);
        vm.prank(alice); // the buyer can ask again themselves
        uint256 newId = factory.rerequestRandomness(id);
        assertTrue(newId != id);
        assertEq(factory.requestBuyer(id), address(0));
        assertEq(factory.requestBuyer(newId), alice);
        // a late answer to the forgotten request is rejected
        vm.expectRevert(ArtifactsFactory.UnknownRequest.selector);
        vrf.fulfill(id, 5);
        vrf.fulfill(newId, 5);
        uint256 edition = factory.requestEdition(newId);
        assertTrue(edition >= 1 && edition <= 255);
        assertEq(factory.editionBuyer(edition), alice);
        assertEq(factory.editionsOf(alice).length, 1);
        assertEq(factory.sold(), 1);
        assertEq(factory.assigned(), 1);
        // a fulfilled request cannot be re-requested
        vm.roll(vm.getBlockNumber() + factory.VRF_RETRY_BLOCKS());
        vm.prank(curator);
        vm.expectRevert(ArtifactsFactory.AlreadyFulfilled.selector);
        factory.rerequestRandomness(newId);
    }

    /// @dev Chainlink answered but the callback failed (the coordinator deleted the commitment): that request will
    /// never answer, so it can be asked again at once; while the coordinator still holds a request, nobody can.
    function test_rerequestAtOnceWhenTheCoordinatorAnsweredButTheCallbackFailed() public {
        _publishAll();
        _openSale(1 ether);
        vm.prank(alice);
        uint256 id = factory.buy{value: 1 ether}(address(0));
        vm.prank(curator);
        vm.expectRevert(ArtifactsFactory.RequestTooRecent.selector);
        factory.rerequestRandomness(id);
        vrf.answerWithFailedCallback(id);
        vm.prank(bob);
        vm.expectRevert(ArtifactsFactory.NotBuyer.selector);
        factory.rerequestRandomness(id);
        vm.prank(alice);
        uint256 newId = factory.rerequestRandomness(id);
        assertEq(factory.requestBuyer(newId), alice);
        // the new request is held by the coordinator, so it waits its own window
        vm.prank(alice);
        vm.expectRevert(ArtifactsFactory.RequestTooRecent.selector);
        factory.rerequestRandomness(newId);
        vrf.fulfill(newId, 9);
        assertEq(factory.editionsOf(alice).length, 1);
        assertEq(factory.sold(), 1);
    }

    function test_vrfCorrectableUntilTheSaleOpens_thenLockedForever() public {
        // before the sale opens: a mistake can be corrected, and the new settings are the ones used
        MockVRFCoordinator other = new MockVRFCoordinator();
        vm.prank(alice);
        vm.expectRevert(TwoStepOwnable.NotOwner.selector);
        factory.configureVRF(address(other), KEY_HASH, SUB_ID, false);
        vm.expectEmit(address(factory));
        emit ArtifactsFactory.VRFConfigured(address(other), keccak256("lane 2"), 42, true);
        vm.prank(curator);
        factory.configureVRF(address(other), keccak256("lane 2"), 42, true);
        assertEq(address(factory.vrfCoordinator()), address(other));
        assertEq(factory.vrfKeyHash(), keccak256("lane 2"));
        assertEq(factory.vrfSubscriptionId(), 42);
        assertTrue(factory.vrfNativePayment());

        // once the sale opens: locked, and it stays locked after closing
        _publishAll();
        _openSale(1 ether);
        vm.prank(alice);
        uint256 id = factory.buy{value: 1 ether}(address(0));
        (bytes32 lane, uint256 sub,,,,) = other.lastRequest();
        assertEq(lane, keccak256("lane 2"));
        assertEq(sub, 42);
        uint256[] memory words = new uint256[](1);
        words[0] = 1;
        vm.prank(address(vrf)); // the first coordinator has no say any more
        vm.expectRevert(ArtifactsFactory.NotCoordinator.selector);
        factory.rawFulfillRandomWords(id, words);
        other.fulfill(id, 1);
        assertGt(factory.requestEdition(id), 0);
        vm.startPrank(curator);
        vm.expectRevert(ArtifactsFactory.VRFLocked.selector);
        factory.configureVRF(address(vrf), KEY_HASH, SUB_ID, false);
        factory.setSaleOpen(false);
        vm.expectRevert(ArtifactsFactory.VRFLocked.selector);
        factory.configureVRF(address(vrf), KEY_HASH, SUB_ID, false);
        vm.stopPrank();
    }

    function test_vrfMustBeConfiguredBeforeSelling() public {
        // a fresh factory without VRF cannot open or sell
        ArtifactsFactory fresh = new ArtifactsFactory(curator, address(house));
        vm.startPrank(curator);
        fresh.setPieceImplementation(address(pieceImpl));
        vm.expectRevert(ArtifactsFactory.VRFNotConfigured.selector);
        fresh.configureVRF(address(0), KEY_HASH, SUB_ID, false);
        vm.stopPrank();
        assertFalse(fresh.vrfConfigured());
    }

    function test_buyFailures() public {
        _publishAll();
        vm.prank(alice);
        vm.expectRevert(ArtifactsFactory.SaleClosed.selector);
        factory.buy{value: 1 ether}(address(0));
        _openSale(1 ether);
        vm.prank(alice);
        vm.expectRevert(ArtifactsFactory.WrongPrice.selector);
        factory.buy{value: 0.9 ether}(address(0));
        vm.prank(alice);
        vm.expectRevert(ArtifactsFactory.NotCoordinator.selector);
        factory.rawFulfillRandomWords(1, new uint256[](1));
    }

    function test_postWrappedKeysInOneBatch() public {
        _publishAll();
        _openSale(1 ether);
        uint256 a = _buyAndAssign(alice, address(0), 1);
        uint256 b = _buyAndAssign(bob, address(0), 2);
        uint256[] memory eds = new uint256[](2);
        bytes[] memory keys = new bytes[](2);
        (eds[0], eds[1]) = (a, b);
        (keys[0], keys[1]) = (bytes("wrapped-a"), bytes("wrapped-b"));
        // every buyer in the batch needs a viewing key, or the whole batch fails
        vm.prank(alice);
        factory.registerViewingKey(keccak256("alice vk"));
        vm.prank(curator);
        vm.expectRevert(ArtifactsFactory.NoViewingKey.selector);
        factory.postWrappedKeys(eds, keys);
        assertEq(factory.wrappedKeyOf(a).length, 0, "nothing half-posted");
        vm.prank(bob);
        factory.registerViewingKey(keccak256("bob vk"));
        // only the curator, with matching lists
        vm.prank(alice);
        vm.expectRevert(TwoStepOwnable.NotOwner.selector);
        factory.postWrappedKeys(eds, keys);
        vm.startPrank(curator);
        vm.expectRevert(ArtifactsFactory.LengthMismatch.selector);
        factory.postWrappedKeys(eds, new bytes[](1));
        vm.expectRevert(ArtifactsFactory.LengthMismatch.selector);
        factory.postWrappedKeys(new uint256[](0), new bytes[](0));
        factory.postWrappedKeys(eds, keys);
        vm.stopPrank();
        assertEq(factory.wrappedKeyOf(a), bytes("wrapped-a"));
        assertEq(factory.wrappedKeyOf(b), bytes("wrapped-b"));
        // and each buyer can claim with their key
        vm.prank(bob);
        ArtifactsPiece piece = ArtifactsPiece(factory.claim(b));
        assertEq(piece.wrappedKey(), bytes("wrapped-b"));
        assertEq(piece.ownerOf(1), bob);
    }

    function test_vrfCallbackGasIsTheCuratorsToTune() public {
        assertEq(factory.vrfCallbackGas(), 1_000_000);
        vm.prank(alice);
        vm.expectRevert(TwoStepOwnable.NotOwner.selector);
        factory.setVRFCallbackGas(500_000);
        vm.startPrank(curator);
        vm.expectRevert(ArtifactsFactory.BadCallbackGas.selector);
        factory.setVRFCallbackGas(149_999);
        vm.expectRevert(ArtifactsFactory.BadCallbackGas.selector);
        factory.setVRFCallbackGas(2_500_001);
        factory.setVRFCallbackGas(700_000);
        vm.stopPrank();
        _publishAll();
        _openSale(1 ether);
        vm.prank(alice);
        factory.buy{value: 1 ether}(address(0));
        (,,, uint32 gas,,) = vrf.lastRequest();
        assertEq(gas, 700_000, "requests carry the curator's setting");
    }

    function test_buyMany_fivePerWallet() public {
        _publishAll();
        _openSale(1 ether);
        assertEq(factory.allowanceOf(alice), 5);
        // quantity must be 1..5 and paid exactly
        vm.startPrank(alice);
        vm.expectRevert(ArtifactsFactory.BadQuantity.selector);
        factory.buyMany{value: 0}(0, address(0));
        vm.expectRevert(ArtifactsFactory.BadQuantity.selector);
        factory.buyMany{value: 6 ether}(6, address(0));
        vm.expectRevert(ArtifactsFactory.WrongPrice.selector);
        factory.buyMany{value: 2 ether}(3, address(0));
        // three at once: three independent draws, one ledger sale with the broker's 15% of the total
        uint256[] memory ids = factory.buyMany{value: 3 ether}(3, broker);
        vm.stopPrank();
        assertEq(ids.length, 3);
        assertEq(factory.sold(), 3);
        assertEq(factory.mintedBy(alice), 3);
        assertEq(factory.allowanceOf(alice), 2);
        assertEq(house.balances(broker, address(0)), 0.45 ether);
        assertEq(_artistEth(), 2.25 ether);
        for (uint256 i; i < 3; ++i) {
            assertEq(factory.requestBuyer(ids[i]), alice);
            vrf.fulfill(ids[i], i);
        }
        assertEq(factory.editionsOf(alice).length, 3);
        // the limit counts every purchase: 3 + 3 is refused, 3 + 1 + 1 reaches it, then nothing more
        vm.startPrank(alice);
        vm.expectRevert(ArtifactsFactory.WalletLimit.selector);
        factory.buyMany{value: 3 ether}(3, address(0));
        factory.buy{value: 1 ether}(address(0));
        factory.buyMany{value: 1 ether}(1, address(0));
        assertEq(factory.allowanceOf(alice), 0);
        vm.expectRevert(ArtifactsFactory.WalletLimit.selector);
        factory.buy{value: 1 ether}(address(0));
        vm.stopPrank();
        // other wallets are unaffected
        vm.prank(bob);
        factory.buyMany{value: 5 ether}(5, address(0));
        assertEq(factory.mintedBy(bob), 5);
        assertEq(factory.sold(), 10);
    }

    function test_buyMany_cannotPassSupply() public {
        _publishAll();
        _openSale(1 ether);
        for (uint256 i; i < 51; ++i) {
            address buyer = makeAddr(string(abi.encodePacked("w", vm.toString(i))));
            vm.deal(buyer, 5 ether);
            vm.prank(buyer);
            if (i < 50) factory.buyMany{value: 5 ether}(5, address(0));
            else factory.buyMany{value: 4 ether}(4, address(0)); // 254 sold
        }
        assertEq(factory.remaining(), 1);
        assertEq(factory.allowanceOf(alice), 1);
        vm.prank(alice);
        vm.expectRevert(ArtifactsFactory.SoldOut.selector);
        factory.buyMany{value: 2 ether}(2, address(0));
        vm.prank(alice);
        factory.buyMany{value: 1 ether}(1, address(0));
        assertEq(factory.remaining(), 0);
        assertEq(factory.allowanceOf(bob), 0);
    }

    function test_buyRecordsSaleAndAssignsEveryEditionOnce() public {
        _publishAll();
        _openSale(1 ether);
        bool[256] memory seen;
        for (uint256 i; i < 255; ++i) {
            // five per wallet: alice takes the first five, then a new wallet every five editions
            address buyer = i < 5 ? alice : makeAddr(string(abi.encodePacked("buyer", vm.toString(i / 5))));
            if (buyer != alice) vm.deal(buyer, 1 ether);
            uint256 edition = _buyAndAssign(buyer, i % 3 == 0 ? broker : address(0), uint256(keccak256(abi.encode(i))));
            assertTrue(edition >= 1 && edition <= 255, "range");
            assertFalse(seen[edition], "assigned twice");
            seen[edition] = true;
            assertEq(factory.editionBuyer(edition), buyer);
        }
        for (uint256 e = 1; e <= 255; ++e) {
            assertTrue(seen[e], "edition skipped");
        }
        assertEq(factory.assigned(), 255);
        assertEq(factory.remaining(), 0);
        assertEq(factory.editionsOf(alice).length, 5);
        vm.prank(alice);
        vm.expectRevert(ArtifactsFactory.SoldOut.selector);
        factory.buy{value: 1 ether}(address(0));
        // ledger holds exactly the proceeds, split per sale
        assertEq(address(house).balance + artist.balance, 255 ether, "the ledger, and the artist paid directly");
        uint256 total = _artistEth() + house.balances(broker, address(0)) + house.balances(address(house), address(0))
            + house.balances(house.BUYBACK(), address(0));
        assertEq(total, 255 ether);
        assertEq(_artistEth(), 255 ether * 7500 / 10_000);
        assertEq(house.balances(broker, address(0)), 85 * 0.15 ether);
    }

    function test_vrfCallbackCannotBeReplayed() public {
        _publishAll();
        _openSale(1 ether);
        vm.prank(alice);
        uint256 id = factory.buy{value: 1 ether}(address(0));
        (bytes32 keyHash, uint256 subId,, uint32 gas, uint32 numWords,) = vrf.lastRequest();
        assertEq(keyHash, KEY_HASH);
        assertEq(subId, SUB_ID);
        assertEq(gas, factory.vrfCallbackGas());
        assertEq(numWords, 1);
        vrf.fulfill(id, 5);
        assertEq(factory.requestEdition(id), 6);
        vm.expectRevert(ArtifactsFactory.AlreadyFulfilled.selector);
        vrf.fulfill(id, 9);
        uint256[] memory words = new uint256[](1);
        vm.prank(address(vrf));
        vm.expectRevert(ArtifactsFactory.UnknownRequest.selector);
        factory.rawFulfillRandomWords(99, words);
    }

    function test_claimFlow_andFailures() public {
        _publishAll();
        _openSale(1 ether);
        uint256 edition = _buyAndAssign(alice, address(0), 41);
        vm.prank(curator);
        vm.expectRevert(ArtifactsFactory.NoViewingKey.selector);
        factory.postWrappedKey(edition, "w");
        vm.prank(alice);
        vm.expectRevert(ArtifactsFactory.NotAssigned.selector);
        factory.claim(edition == 1 ? 2 : 1);
        vm.prank(alice);
        factory.registerViewingKey(keccak256("vk"));
        vm.prank(alice);
        vm.expectRevert(ArtifactsFactory.KeyNotPosted.selector);
        factory.claim(edition);
        vm.prank(bob);
        vm.expectRevert(TwoStepOwnable.NotOwner.selector);
        factory.postWrappedKey(edition, "w");
        vm.prank(curator);
        factory.postWrappedKey(edition, "wrapped-to-alice");
        vm.prank(bob);
        vm.expectRevert(ArtifactsFactory.NotBuyer.selector);
        factory.claim(edition);
        vm.prank(alice);
        ArtifactsPiece piece = ArtifactsPiece(factory.claim(edition));
        assertEq(factory.pieceContract(edition), address(piece));
        assertEq(piece.ownerOf(1), alice);
        assertEq(piece.balanceOf(alice), 1);
        assertEq(piece.symbol(), "ARTIFACTS");
        assertEq(
            piece.name(),
            string.concat("ARTIFACTS #", edition < 10 ? "00" : edition < 100 ? "0" : "", vm.toString(edition))
        );
        assertEq(piece.wrappedKey(), "wrapped-to-alice");
        assertEq(piece.commitment(), keccak256(abi.encodePacked("K", edition)));
        assertEq(piece.ciphertext(), abi.encodePacked("ciphertext", edition));
        assertEq(piece.traits().palette, "PRISM");
        (address rTo, uint256 rAmt) = piece.royaltyInfo(1, 1 ether);
        assertEq(rTo, artist);
        assertEq(rAmt, 0.075 ether);
        vm.prank(alice);
        vm.expectRevert(ArtifactsFactory.AlreadyClaimed.selector);
        factory.claim(edition);
        // implementation is locked and clone cannot be re-initialised
        vm.expectRevert(ArtifactsPiece.AlreadyInitialized.selector);
        pieceImpl.initialize(alice, alice, 1, alice, _traits(1), address(0), bytes32(0), "", false, bytes32(0));
        vm.expectRevert(ArtifactsPiece.AlreadyInitialized.selector);
        piece.initialize(alice, alice, 1, alice, _traits(1), address(0), bytes32(0), "", false, bytes32(0));
        // no mint path outside claim: the only token is #1
        vm.expectRevert(ERC721Lite.NonexistentToken.selector);
        piece.ownerOf(2);
    }

    function test_sealTokenURIMatchesR8Frame() public {
        _publishAll();
        _openSale(1 ether);
        // find the edition number 3 by buying until it comes up with a deterministic word
        uint256 edition = _buyAndAssign(alice, address(0), 2); // pool index 2 => edition 3
        assertEq(edition, 3);
        ArtifactsPiece piece = _claim(alice, edition);
        string memory uri = piece.tokenURI(1);
        bytes memory b = bytes(uri);
        bytes memory json = Base64Decode.decode(Base64Decode.slice(b, 29, b.length));
        uint256 at = Base64Decode.indexOf(json, bytes("data:image/svg+xml;base64,"), 0) + 26;
        uint256 end = Base64Decode.indexOf(json, bytes('"}'), at);
        bytes memory svg = Base64Decode.decode(Base64Decode.slice(json, at, end));
        // expected: the framed reference piece 003 with its dots removed (traits: DRIFT / PRISM 3C HORIZONTAL), its
        // number in place of the study's SEED 003 (R8), marked SEALED in the middle
        bytes memory framed = bytes(vm.readFile("reference/framed/framed-003.svg"));
        uint256 frameAt = Base64Decode.indexOf(framed, bytes('<g fill="#1a1a1a"'), 0);
        uint256 dotsAt = Base64Decode.indexOf(framed, bytes("<circle"), 0);
        uint256 seedAt = Base64Decode.indexOf(framed, bytes(">SEED 003<"), 0) + 1;
        bytes memory expected = Base64Decode.withMark(
            bytes.concat(
                Base64Decode.slice(framed, 0, dotsAt),
                Base64Decode.slice(framed, frameAt, seedAt),
                bytes("No. 003"),
                Base64Decode.slice(framed, seedAt + 8, framed.length)
            ),
            Seal.SEALED_MARK
        );
        assertEq(svg, expected, "seal differs from R8 frame");
        assertTrue(Base64Decode.indexOf(svg, bytes(">SEALED<"), 0) > 0);
        assertEq(Base64Decode.indexOf(json, bytes('"name":"ARTIFACTS #003"'), 0), 1);
    }

    function test_viewingKeyZeroRejected() public {
        vm.prank(alice);
        vm.expectRevert(ArtifactsFactory.NoViewingKey.selector);
        factory.registerViewingKey(bytes32(0));
    }
}

contract ArtifactsPieceEscrowTest is Fixture {
    ArtifactsPiece internal piece;
    uint256 internal edition;

    function setUp() public override {
        super.setUp();
        _publishAll();
        _openSale(1 ether);
        edition = _buyAndAssign(alice, address(0), 10);
        piece = _claim(alice, edition);
    }

    function test_escrowHappyPath_buyerConfirms() public {
        vm.prank(bob);
        vm.expectRevert(ArtifactsPiece.NotTokenOwner.selector);
        piece.list(2 ether);
        vm.prank(alice);
        piece.list(2 ether);
        vm.prank(bob);
        vm.expectRevert(ArtifactsPiece.WrongPrice.selector);
        piece.buy{value: 1 ether}(_vk("bobvk"), address(0));
        vm.prank(bob);
        piece.buy{value: 2 ether}(_vk("bobvk"), address(0));
        assertEq(piece.viewingKeyOf(bob), _vk("bobvk"));
        // token locked while in escrow
        vm.prank(alice);
        vm.expectRevert(ArtifactsPiece.EscrowActive.selector);
        piece.transferFrom(alice, carol, 1);
        vm.prank(bob);
        vm.expectRevert(ArtifactsPiece.KeyNotPosted.selector);
        piece.release();
        _postKeyReverts(piece, carol, (2 ether) / 10, ArtifactsPiece.NotSeller.selector);
        _postKey(piece, alice, (2 ether) / 10);
        vm.prank(bob);
        vm.expectRevert(ArtifactsPiece.KeyAlreadyPosted.selector);
        piece.cancel();
        vm.prank(carol);
        vm.expectRevert(ArtifactsPiece.TooEarly.selector);
        piece.release();
        uint256 artistBefore = _artistEth();
        vm.prank(bob);
        piece.release();
        assertEq(piece.ownerOf(1), bob);
        assertEq(piece.wrappedKey(), _wrappedOf("key"), "the key the seller sent, now the buyer's");
        assertEq(piece.pendingWithdrawals(alice), 2 ether - 0.15 ether + 0.2 ether, "proceeds, and the deposit back");
        // the 7.5% royalty is credited in the ledger, where the artist withdraws everything at once
        assertEq(piece.pendingWithdrawals(artist), 0);
        assertEq(_artistEth() - artistBefore, 0.15 ether);
        uint256 before = alice.balance;
        vm.prank(alice);
        piece.withdraw();
        assertEq(alice.balance - before, 2.05 ether);
        assertEq(address(piece).balance, 0);
    }

    function test_escrowTimeoutRelease() public {
        vm.prank(alice);
        piece.list(1 ether);
        vm.prank(bob);
        piece.buy{value: 1 ether}(_vk("bobvk"), address(0));
        _postKey(piece, alice, (1 ether) / 10);
        vm.warp(vm.getBlockTimestamp() + 72 hours - 1);
        vm.prank(alice);
        vm.expectRevert(ArtifactsPiece.TooEarly.selector);
        piece.release();
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.prank(alice);
        piece.release();
        assertEq(piece.ownerOf(1), bob);
    }

    function test_escrowCancelBeforeKey_andDelist() public {
        vm.prank(alice);
        piece.list(1 ether);
        vm.prank(bob);
        piece.buy{value: 1 ether}(_vk("bobvk"), address(0));
        vm.prank(alice);
        vm.expectRevert(ArtifactsPiece.EscrowActive.selector);
        piece.delist();
        vm.prank(carol);
        vm.expectRevert(ArtifactsPiece.NotEscrowBuyer.selector);
        piece.cancel();
        vm.warp(vm.getBlockTimestamp() + 24 hours); // the seller's window
        vm.prank(bob);
        piece.cancel();
        assertEq(piece.pendingWithdrawals(bob), 1 ether);
        vm.prank(bob);
        piece.withdraw();
        assertEq(bob.balance, 1000 ether);
        // listing is still live for another buyer; seller may delist
        vm.prank(alice);
        piece.delist();
        vm.prank(carol);
        vm.expectRevert(ArtifactsPiece.NotListed.selector);
        piece.buy{value: 1 ether}(_vk("c"), address(0));
    }

    function test_plainTransferClearsKey_previousOwnerRekeys() public {
        vm.prank(alice);
        piece.transferFrom(alice, bob, 1);
        assertEq(piece.ownerOf(1), bob);
        assertEq(piece.wrappedKey(), "");
        assertEq(piece.previousOwner(), alice);
        vm.prank(alice);
        vm.expectRevert(ArtifactsPiece.NoViewingKey.selector);
        piece.rewrapFor("k-for-bob");
        vm.prank(bob);
        piece.registerViewingKey(keccak256("bobvk"));
        vm.prank(carol);
        vm.expectRevert(ArtifactsPiece.NotPreviousOwner.selector);
        piece.rewrapFor("k-for-bob");
        vm.prank(alice);
        piece.rewrapFor("k-for-bob");
        assertEq(piece.wrappedKey(), "k-for-bob");
        // a listing without a buyer is dropped by a plain transfer
        vm.prank(bob);
        piece.list(1 ether);
        vm.prank(bob);
        piece.transferFrom(bob, carol, 1);
        (, address seller,,,,,,,,) = piece.escrow();
        assertEq(seller, address(0));
    }

    /// @dev After release the paid seller keeps no re-key right: the delivered key cannot be overwritten.
    function test_sellerCannotOverwriteKeyAfterRelease() public {
        vm.prank(alice);
        piece.list(2 ether);
        vm.prank(bob);
        piece.buy{value: 2 ether}(_vk("bobvk"), address(0));
        _postKey(piece, alice, (2 ether) / 10);
        vm.prank(bob);
        piece.release();
        assertEq(piece.ownerOf(1), bob);
        assertEq(piece.previousOwner(), address(0));
        vm.prank(alice);
        vm.expectRevert(ArtifactsPiece.NotPreviousOwner.selector);
        piece.rewrapFor("garbage");
        vm.prank(alice);
        vm.expectRevert(ArtifactsPiece.NotPreviousOwner.selector);
        piece.rewrapFor("");
        assertEq(piece.wrappedKey(), _wrappedOf("key"));
        // a later plain transfer by bob gives bob (not alice) the one-shot re-key right
        vm.prank(bob);
        piece.transferFrom(bob, carol, 1);
        assertEq(piece.previousOwner(), bob);
        vm.prank(alice);
        vm.expectRevert(ArtifactsPiece.NotPreviousOwner.selector);
        piece.rewrapFor("garbage");
    }

    /// @dev Re-keying after a plain transfer is one shot and never empty.
    function test_rewrapIsOneShotAndNonEmpty() public {
        vm.prank(alice);
        piece.transferFrom(alice, bob, 1);
        vm.prank(bob);
        piece.registerViewingKey(keccak256("bobvk"));
        vm.prank(alice);
        vm.expectRevert(ArtifactsPiece.KeyNotPosted.selector);
        piece.rewrapFor("");
        vm.prank(alice);
        piece.rewrapFor("k-for-bob");
        assertEq(piece.previousOwner(), address(0));
        vm.prank(alice);
        vm.expectRevert(ArtifactsPiece.NotPreviousOwner.selector);
        piece.rewrapFor("k2");
        assertEq(piece.wrappedKey(), "k-for-bob");
    }

    function test_escrowKeyMustNotBeEmpty() public {
        vm.prank(alice);
        piece.list(1 ether);
        vm.prank(bob);
        piece.buy{value: 1 ether}(_vk("bobvk"), address(0));
        vm.prank(alice);
        vm.expectRevert(ArtifactsPiece.BadWrappedKey.selector);
        piece.postEscrowKey{value: (1 ether) / 10}("", address(1), 1);
        // the buyer's cancel right is intact, after the seller's window
        vm.warp(vm.getBlockTimestamp() + 24 hours);
        vm.prank(bob);
        piece.cancel();
        assertEq(piece.pendingWithdrawals(bob), 1 ether);
    }

    function test_pieceViewingKeyZeroRejected() public {
        vm.prank(bob);
        vm.expectRevert(ArtifactsPiece.NoViewingKey.selector);
        piece.registerViewingKey(bytes32(0));
        vm.prank(alice);
        piece.list(1 ether);
        vm.prank(bob);
        vm.expectRevert(ArtifactsPiece.NoViewingKey.selector);
        piece.buy{value: 1 ether}(bytes32(0), address(0));
    }

    function test_reentrancyOnEscrowWithdrawBlocked() public {
        Reenterer r = new Reenterer();
        vm.deal(address(r), 5 ether);
        vm.prank(alice);
        piece.list(1 ether);
        r.call(address(piece), 1 ether, abi.encodeWithSelector(ArtifactsPiece.buy.selector, _vk("r"), address(0)));
        vm.warp(vm.getBlockTimestamp() + 24 hours); // the seller's window
        r.call(address(piece), 0, abi.encodeWithSelector(ArtifactsPiece.cancel.selector));
        r.set(address(piece), abi.encodeWithSelector(ArtifactsPiece.withdraw.selector));
        r.call(address(piece), 0, abi.encodeWithSelector(ArtifactsPiece.withdraw.selector));
        assertTrue(r.reentryFailed());
        assertEq(address(r).balance, 5 ether);
    }

    function test_sourceOnlyReveal() public {
        vm.prank(alice);
        vm.expectRevert(ArtifactsPiece.NotSource.selector);
        piece.reveal(SOURCE_KEY);
    }
}
