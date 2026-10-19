// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./Fixture.sol";
import {ArtifactsFactory} from "../src/ArtifactsFactory.sol";
import {ArtifactsSource} from "../src/ArtifactsSource.sol";
import {SubmissionReviews} from "../src/SubmissionReviews.sol";
import {TwoStepOwnable} from "../src/base/TwoStepOwnable.sol";
import {MockSeats} from "./mocks/MockSeats.sol";

/// @notice Mainnet revision 2: the piece implementation set once after the launch (180a7e1d59e1), the sale refusing
/// to open before the ledger takes the factory's sales (5f41a376), reviewsOf's tail (7b2e2f48) and the VRF
/// callback minimum (2c64d841).
contract PieceImplementationTest is Fixture {
    function _published(ArtifactsFactory f) internal {
        vm.startPrank(curator);
        f.configureVRF(address(vrf), KEY_HASH, SUB_ID, false);
        for (uint256 i = 1; i <= 255; ++i) {
            f.setPiece(i, _traits(i), "c", keccak256(abi.encode(i)));
        }
        f.lock();
        f.setPrice(1 ether);
        vm.stopPrank();
    }

    function test_setPieceImplementationOnceAndOnlyByTheOwner() public {
        ArtifactsFactory f = new ArtifactsFactory(curator, address(house));
        ArtifactsSource s = new ArtifactsSource(curator, address(house));
        assertEq(f.pieceImplementation(), address(0));
        vm.prank(alice);
        vm.expectRevert(TwoStepOwnable.NotOwner.selector);
        f.setPieceImplementation(address(pieceImpl));
        vm.startPrank(curator);
        vm.expectRevert(ArtifactsFactory.NoPieceImplementation.selector);
        f.setPieceImplementation(makeAddr("no code"));
        vm.expectRevert(ArtifactsSource.NoPieceImplementation.selector);
        s.setPieceImplementation(address(0));
        vm.expectEmit(address(f));
        emit ArtifactsFactory.PieceImplementationSet(address(pieceImpl));
        f.setPieceImplementation(address(pieceImpl));
        s.setPieceImplementation(address(pieceImpl));
        vm.expectRevert(ArtifactsFactory.PieceImplementationAlreadySet.selector);
        f.setPieceImplementation(address(pieceImpl));
        vm.expectRevert(ArtifactsSource.PieceImplementationAlreadySet.selector);
        s.setPieceImplementation(address(this));
        vm.stopPrank();
        assertEq(f.pieceImplementation(), address(pieceImpl));
        assertEq(s.pieceImplementation(), address(pieceImpl));
    }

    function test_saleCannotOpenWithoutThePieceImplementation() public {
        ArtifactsFactory f = new ArtifactsFactory(curator, address(house));
        vm.startPrank(curator);
        house.setSaleModule(address(f), true);
        house.registerModuleCollection(address(f), artist);
        vm.stopPrank();
        _published(f);
        vm.startPrank(curator);
        vm.expectRevert(ArtifactsFactory.NoPieceImplementation.selector);
        f.setSaleOpen(true);
        assertEq(f.saleOpenedAt(), 0);
        f.setPieceImplementation(address(pieceImpl));
        f.setSaleOpen(true);
        vm.stopPrank();
        assertTrue(f.saleOpen());
    }

    /// @dev 5f41a376: opening before the ledger takes this factory's sales would start the holders window and the
    /// phases with nobody able to buy, and they never restart.
    function test_saleCannotOpenBeforeTheLedgerRegistersTheFactory() public {
        ArtifactsFactory f = new ArtifactsFactory(curator, address(house));
        _published(f);
        vm.startPrank(curator);
        f.setPieceImplementation(address(pieceImpl));
        f.setGate(address(0), address(imd), 100e18, 1 hours);
        vm.expectRevert(ArtifactsFactory.NotRegistered.selector);
        f.setSaleOpen(true);
        assertEq(f.saleOpenedAt(), 0);
        house.setSaleModule(address(f), true);
        vm.expectRevert(ArtifactsFactory.NotRegistered.selector);
        f.setSaleOpen(true);
        house.registerModuleCollection(address(f), artist);
        vm.warp(block.timestamp + 2 hours);
        f.setSaleOpen(true);
        vm.stopPrank();
        assertEq(f.saleOpenedAt(), block.timestamp);
        assertEq(f.gateEndsAt(), block.timestamp + 1 hours);
    }

    function test_auctionCannotOpenWithoutThePieceImplementation() public {
        ArtifactsSource s = new ArtifactsSource(curator, address(house));
        vm.startPrank(curator);
        house.setSaleModule(address(s), true);
        house.registerModuleCollection(address(s), artist);
        s.storeRendererChunk("x");
        s.lock(SEALED_SEED, SOURCE_COMMITMENT);
        vm.expectRevert(ArtifactsSource.NoPieceImplementation.selector);
        s.setAuction(1 ether, uint64(block.timestamp + 1 days));
        s.setPieceImplementation(address(pieceImpl));
        s.setAuction(1 ether, uint64(block.timestamp + 1 days));
        vm.stopPrank();
        assertTrue(s.auctionOpen());
    }

    function test_vrfCallbackMinimumIsAboveOneDraw() public {
        assertEq(factory.VRF_CALLBACK_GAS_MIN(), 250_000);
        vm.startPrank(curator);
        vm.expectRevert(ArtifactsFactory.BadCallbackGas.selector);
        factory.setVRFCallbackGas(249_999);
        factory.setVRFCallbackGas(250_000);
        vm.stopPrank();
        _publishAll();
        _openSale(1 ether);
        // a draw at the minimum: the coordinator gives the callback exactly that much
        vm.prank(alice);
        uint256 id = factory.buy{value: 1 ether}(address(0));
        uint256[] memory words = new uint256[](1);
        words[0] = 12345;
        vm.prank(address(vrf));
        factory.rawFulfillRandomWords{gas: 250_000}(id, words);
        assertEq(factory.assigned(), 1);
    }

    /// @dev 7b2e2f48: everything from `start` with count = type(uint256).max is the tail, not a panic.
    function test_reviewsOfReturnsTheTailForAHugeCount() public {
        MockSeats seats = new MockSeats();
        SubmissionReviews reviews =
            new SubmissionReviews(address(house), address(seats), address(factory), address(source));
        seats.mint(bob, 1);
        seats.mint(carol, 2);
        vm.prank(alice);
        house.submit(keccak256("a drop"), "ipfs://preview");
        vm.prank(bob);
        reviews.reviewAsSeat(0, 1, SubmissionReviews.Verdict.Back, "");
        vm.prank(carol);
        reviews.reviewAsSeat(0, 2, SubmissionReviews.Verdict.Pass, "");
        (uint256[] memory voices,) = reviews.reviewsOf(0, 1, type(uint256).max);
        assertEq(voices.length, 1);
        assertEq(voices[0], reviews.seatVoice(2));
        (voices,) = reviews.reviewsOf(0, 0, type(uint256).max);
        assertEq(voices.length, 2);
        (voices,) = reviews.reviewsOf(0, 2, type(uint256).max);
        assertEq(voices.length, 0);
        (voices,) = reviews.reviewsOf(0, type(uint256).max, type(uint256).max);
        assertEq(voices.length, 0);
    }
}
