// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./Fixture.sol";
import {Vm} from "forge-std/Vm.sol";
import {ArtCollection} from "../src/ArtCollection.sol";
import {ArtifactsPiece} from "../src/ArtifactsPiece.sol";
import {ArtHouse} from "../src/ArtHouse.sol";
import {ArtifactsFactory} from "../src/ArtifactsFactory.sol";
import {HolderGate} from "../src/base/HolderGate.sol";
import {Clones} from "../src/libs/Clones.sol";

/// @dev Deliberately malformed external answers, including a nonzero ABI head on oversized replies.
contract LaunchBadAnswer {
    uint256 public size;
    uint256 public word;
    bool public fails;

    function configure(uint256 size_, uint256 word_, bool fails_) external {
        size = size_;
        word = word_;
        fails = fails_;
    }

    fallback() external {
        require(!fails, "broken dependency");
        uint256 s = size;
        uint256 w = word;
        assembly ("memory-safe") {
            let p := mload(0x40)
            mstore(p, w)
            return(p, s)
        }
    }
}

/// @dev Regression tests for b0f3f99d54ac, 76d2a83f2f13, ab923af3c52f and b93e09f36b44.
contract LaunchAuditTest is Fixture {
    function _postAndCheckEvent(uint256 edition, bytes memory wrapped) internal {
        vm.recordLogs();
        vm.prank(curator);
        factory.postWrappedKey(edition, wrapped);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 count;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(factory) && logs[i].topics[0] == keccak256("WrappedKeyPosted(uint256)")) {
                ++count;
                assertEq(logs[i].topics.length, 2);
                assertEq(logs[i].topics[1], bytes32(edition));
                assertEq(logs[i].data.length, 0);
            }
        }
        assertEq(count, 1);
    }

    function test_keyPostEventUnchangedBeforeAndAfterClaim() public {
        _publishAll();
        _openSale(1 ether);
        uint256 edition = _buyAndAssign(alice, address(0), 1);
        vm.prank(alice);
        factory.registerViewingKey(_vk("alice"));
        _postAndCheckEvent(edition, bytes("first key"));
        assertEq(factory.wrappedKeyOf(edition), bytes("first key"));
        vm.prank(alice);
        ArtifactsPiece piece = ArtifactsPiece(factory.claim(edition));
        assertEq(piece.wrappedKey(), bytes("first key"));
        vm.prank(alice);
        piece.transferFrom(alice, bob, 1);
        vm.prank(bob);
        piece.registerViewingKey(_vk("bob"));
        _postAndCheckEvent(edition, bytes("next key"));
        assertEq(piece.wrappedKey(), bytes("next key"));
        assertEq(piece.ownerOf(1), bob);
    }

    function _scan(address target) internal view {
        bytes memory code = target.code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        // Same scan as the protected floor: do not skip the constant-data tail.
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden application opcode");
        }
    }

    function test_plainCollectionIsIndependentRuntime() public {
        vm.prank(curator);
        ArtCollection col = ArtCollection(house.createCollection("Plain", "PLN", artist));
        _scan(address(col));
        assertEq(address(col).code, house.collectionImplementation().code);
        assertEq(address(col.house()), address(house));
        assertEq(col.name(), "Plain");
        assertEq(col.symbol(), "PLN");
    }

    function test_claimedEditionsAreIndependentRuntimesAndStorage() public {
        _publishAll();
        _openSale(1 ether);
        uint256 a = _buyAndAssign(alice, broker, 1);
        uint256 b = _buyAndAssign(bob, broker, 2);
        ArtifactsPiece first = _claim(alice, a);
        ArtifactsPiece second = _claim(bob, b);
        _scan(address(first));
        _scan(address(second));
        assertEq(address(first).code, address(pieceImpl).code);
        assertEq(address(second).code, address(pieceImpl).code);
        assertEq(address(first.keyProof()), address(keyProof));
        assertEq(first.controller(), address(factory));
        assertEq(first.ownerOf(1), alice);
        assertEq(second.ownerOf(1), bob);
        vm.prank(alice);
        first.transferFrom(alice, carol, 1);
        assertEq(second.ownerOf(1), bob);
        assertEq(pieceImpl.controller(), address(pieceImpl));
        assertTrue(factory.isPiece(address(first)));
        vm.expectRevert(ArtifactsPiece.AlreadyInitialized.selector);
        first.initialize(
            address(factory), address(house), a, alice, _traits(a), address(0), bytes32(0), "", false, bytes32(0)
        );
    }

    function test_attackerCannotInitializePieceAsRealFactory() public {
        ArtifactsPiece fake = ArtifactsPiece(Clones.copyCode(address(pieceImpl)));
        vm.prank(alice);
        vm.expectRevert();
        fake.initialize(
            address(factory), address(house), 1, alice, _traits(1), address(0), keccak256("K"), "", false, bytes32(0)
        );
        assertEq(fake.controller(), address(0));
        assertFalse(factory.isPiece(address(fake)));
    }

    function test_attackerCannotInitializePieceAsRealSource() public {
        ArtifactsPiece fake = ArtifactsPiece(Clones.copyCode(address(pieceImpl)));
        vm.prank(alice);
        vm.expectRevert();
        fake.initialize(
            address(source),
            address(house),
            256,
            alice,
            _traits(256),
            address(0),
            SOURCE_COMMITMENT,
            "",
            true,
            bytes32(0)
        );
        assertEq(fake.controller(), address(0));
    }

    function test_attackerCannotInitializeCollectionAsRealHouse() public {
        ArtCollection fake = ArtCollection(Clones.copyCode(house.collectionImplementation()));
        vm.prank(alice);
        vm.expectRevert();
        fake.initialize(address(house), "Fake", "FAKE");
        assertEq(address(fake.house()), address(0));
    }

    function test_initializerRejectsEOAController() public {
        ArtifactsPiece fake = ArtifactsPiece(Clones.copyCode(address(pieceImpl)));
        vm.prank(alice);
        vm.expectRevert();
        fake.initialize(alice, address(house), 1, alice, _traits(1), address(0), keccak256("K"), "", false, bytes32(0));
        ArtCollection col = ArtCollection(Clones.copyCode(house.collectionImplementation()));
        vm.prank(alice);
        vm.expectRevert();
        col.initialize(alice, "Fake", "FAKE");
    }

    function test_brokenBrokerPassDoesNotBlockEditionPurchase() public {
        vm.prank(curator);
        house.setBrokerPass(alice); // a code-less address, not a production configuration
        _publishAll();
        _openSale(1 ether);
        uint256 edition = _buyAndAssign(alice, bob, 1);
        assertEq(factory.editionBuyer(edition), alice);
        assertFalse(house.isEligibleBroker(bob));
        assertTrue(house.isEligibleBroker(broker));
        assertFalse(house.isEligibleBroker(address(0)));
        assertEq(house.balances(house.BUYBACK(), address(0)), 0.2 ether);
        vm.prank(curator);
        vm.expectRevert(ArtHouse.BrokerPassAlreadySet.selector);
        house.setBrokerPass(address(this));
    }

    function test_brokenBrokerPassDoesNotBlockSourceSettlement() public {
        vm.startPrank(curator);
        house.setBrokerPass(alice);
        source.storeRendererChunk("page");
        source.lock(SEALED_SEED, SOURCE_COMMITMENT);
        source.setAuction(1 ether, uint64(block.timestamp + 1 days));
        vm.stopPrank();
        vm.prank(alice);
        source.bid{value: 1 ether}(bob);
        vm.warp(source.endTime());
        ArtifactsPiece p = ArtifactsPiece(source.settle());
        assertEq(p.ownerOf(1), alice);
        assertEq(p.controller(), address(source));
        assertEq(address(p).code, address(pieceImpl).code);
        _scan(address(p));
        assertEq(house.balances(house.BUYBACK(), address(0)), 0.2 ether);
    }

    function test_brokerPassMalformedRepliesCountAsIneligible() public {
        LaunchBadAnswer bad = new LaunchBadAnswer();
        vm.prank(curator);
        house.setBrokerPass(address(bad));
        bad.configure(32, 1, true);
        assertFalse(house.isEligibleBroker(bob));
        bad.configure(0, 1, false);
        assertFalse(house.isEligibleBroker(bob));
        bad.configure(31, 1, false);
        assertFalse(house.isEligibleBroker(bob));
        bad.configure(64, 32, false);
        assertFalse(house.isEligibleBroker(bob));
        bad.configure(200_000, 32, false);
        assertFalse(house.isEligibleBroker(bob));
        bad.configure(type(uint256).max, 1, false); // exhausts the stipend; must not exhaust the sale
        assertFalse(house.isEligibleBroker(bob));
        bad.configure(32, 0, false);
        assertFalse(house.isEligibleBroker(bob));
        bad.configure(32, 1, false);
        assertTrue(house.isEligibleBroker(bob));
    }

    function test_brokenPassDoesNotBlockPlainMintsInEitherCurrency() public {
        vm.startPrank(curator);
        house.setBrokerPass(alice);
        address col = house.createCollection("Plain", "PLN", artist);
        bytes memory svg = bytes("<svg/>");
        for (uint256 i; i < 2; ++i) {
            house.registerPiece(col, i, keccak256(svg), "T", "D");
            house.uploadChunk(col, i, 0, svg);
            house.finalizePiece(col, i);
        }
        house.sealCollection(col);
        house.setPrices(col, 1 ether, 1 ether);
        house.setSaleOpen(col, true);
        vm.stopPrank();
        vm.prank(alice);
        house.mint{value: 1 ether}(col, 0, bob);
        imd.mint(alice, 1 ether);
        vm.startPrank(alice);
        imd.approve(address(house), 1 ether);
        house.mintWithIMD(col, 1, bob, 1 ether);
        vm.stopPrank();
        assertEq(ArtCollection(col).ownerOf(0), alice);
        assertEq(ArtCollection(col).ownerOf(1), alice);
        assertEq(house.balances(house.BUYBACK(), address(0)), 0.2 ether);
        assertEq(house.balances(house.BUYBACK(), address(imd)), 0.2 ether);
    }

    /// @dev 015b0e5b53ba: curator powers are retained intentionally; they do not freeze existing NFTs.
    function test_ownerCanClosePrimarySaleAndChangePendingAuctionSplit() public {
        _publishAll();
        _openSale(1 ether);
        uint256 edition = _buyAndAssign(alice, address(0), 1);
        vm.prank(curator);
        factory.setSaleOpen(false);
        vm.prank(bob);
        vm.expectRevert(ArtifactsFactory.SaleClosed.selector);
        factory.buy{value: 1 ether}(address(0));
        ArtifactsPiece piece = _claim(alice, edition); // paid buyers can still claim and transfer
        vm.prank(alice);
        piece.transferFrom(alice, bob, 1);
        assertEq(piece.ownerOf(1), bob);

        vm.startPrank(curator);
        house.setSplit(address(source), 1500, 0, 8500, 0);
        source.storeRendererChunk("page");
        source.lock(SEALED_SEED, SOURCE_COMMITMENT);
        source.setAuction(1 ether, uint64(block.timestamp + 1 days));
        vm.stopPrank();
        vm.prank(alice);
        source.bid{value: 10 ether}(broker);
        vm.warp(source.endTime());
        vm.prank(curator);
        house.setSplit(address(source), 1500, 8500, 0, 0);
        uint256 houseBefore = house.balances(address(house), address(0));
        uint256 artistBefore = _artistEth();
        source.settle();
        assertEq(house.balances(address(house), address(0)) - houseBefore, 8.5 ether);
        assertEq(_artistEth(), artistBefore);
        assertEq(house.balances(broker, address(0)), 1.5 ether);
    }

    function test_dynamicMemberReplyCannotBypassEditionWindow() public {
        _publishAll();
        vm.startPrank(curator);
        factory.setGate(address(0), address(imd), 1 ether, 1 days);
        factory.setMemberGate(address(imd), bytes4(keccak256("name()")), 1);
        vm.stopPrank();
        _openSale(1 ether);
        assertFalse(factory.isMember(alice));
        vm.prank(alice);
        vm.expectRevert(HolderGate.NotEligible.selector);
        factory.buy{value: 1 ether}(address(0));
        imd.mint(alice, 1 ether);
        vm.prank(alice);
        factory.buy{value: 1 ether}(address(0));
    }

    function test_dynamicMemberReplyCannotBypassSourceWindow() public {
        vm.startPrank(curator);
        source.storeRendererChunk("page");
        source.lock(SEALED_SEED, SOURCE_COMMITMENT);
        source.setGate(address(0), address(imd), 1 ether, 1 days);
        source.setMemberGate(address(imd), bytes4(keccak256("name()")), 1);
        source.setAuction(1 ether, uint64(block.timestamp + 2 days));
        vm.stopPrank();
        assertFalse(source.isMember(alice));
        vm.prank(alice);
        vm.expectRevert(HolderGate.NotEligible.selector);
        source.bid{value: 1 ether}(address(0));
        vm.warp(block.timestamp + 1 days);
        vm.prank(alice);
        source.bid{value: 1 ether}(address(0));
    }

    function testFuzz_memberReplyMustBeExactlyOneWord(uint16 size, uint256 score, uint256 minimum) public {
        LaunchBadAnswer bad = new LaunchBadAnswer();
        minimum = bound(minimum, 1, type(uint256).max);
        bad.configure(size, score, false);
        vm.startPrank(curator);
        factory.setMemberGate(address(bad), bytes4(keccak256("points(address)")), minimum);
        source.setMemberGate(address(bad), bytes4(keccak256("points(address)")), minimum);
        vm.stopPrank();
        bool eligible = size == 32 && score >= minimum;
        assertEq(factory.isMember(alice), eligible);
        assertEq(source.isMember(alice), eligible);
    }
}
