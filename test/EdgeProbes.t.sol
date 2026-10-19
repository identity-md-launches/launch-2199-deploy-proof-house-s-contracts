// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Fixture} from "./Fixture.sol";
import {ArtHouse} from "../src/ArtHouse.sol";
import {ArtifactsSource} from "../src/ArtifactsSource.sol";
import {BrokerPass} from "../src/BrokerPass.sol";
import {SubmissionReviews} from "../src/SubmissionReviews.sol";
import {TwoStepOwnable} from "../src/base/TwoStepOwnable.sol";
import {MockSeats} from "./mocks/MockSeats.sol";

/// @dev Boundary probes the earlier suites leave implicit: THE SOURCE's raise rule and anti-sniping extension at the
/// exact second, the void-after-grace path, BrokerPass's one-year start bound, SubmissionReviews' length limits and
/// voice range, and ArtHouse's per-piece byte cap. Each edge is pinned on both sides.
contract EdgeProbesTest is Fixture {
    MockSeats internal seats;
    BrokerPass internal pass;
    SubmissionReviews internal reviews;

    function setUp() public override {
        super.setUp();
        seats = new MockSeats();
        pass = new BrokerPass(address(seats), address(factory), address(source));
        reviews = new SubmissionReviews(address(house), address(seats), address(factory), address(source));
    }

    // ---------- THE SOURCE auction ----------

    function _lockSource() internal {
        vm.startPrank(curator);
        source.storeRendererChunk("<html>");
        source.lock(SEALED_SEED, SOURCE_COMMITMENT);
        vm.stopPrank();
    }

    function _openAuction(uint256 reserve, uint64 duration) internal returns (uint64 end) {
        _lockSource();
        end = uint64(block.timestamp) + duration;
        vm.prank(curator);
        source.setAuction(reserve, end);
    }

    function _minNext(uint256 h) internal pure returns (uint256) {
        return (h * 10_500 + 9_999) / 10_000;
    }

    function test_setAuction_failurePaths() public {
        vm.prank(curator);
        vm.expectRevert(ArtifactsSource.NotLocked.selector);
        source.setAuction(1, uint64(block.timestamp + 1));

        _lockSource();
        vm.startPrank(curator);
        vm.expectRevert(ArtifactsSource.BadEndTime.selector);
        source.setAuction(1, uint64(block.timestamp));
        vm.expectRevert(ArtifactsSource.BidTooLow.selector);
        source.setAuction(0, uint64(block.timestamp + 1));
        vm.stopPrank();

        vm.prank(alice);
        vm.expectRevert(TwoStepOwnable.NotOwner.selector);
        source.setAuction(1, uint64(block.timestamp + 1));

        // a module the house no longer records sales for cannot open an auction it could never settle
        vm.prank(curator);
        house.setSaleModule(address(source), false);
        vm.prank(curator);
        vm.expectRevert(ArtifactsSource.NotRegistered.selector);
        source.setAuction(1, uint64(block.timestamp + 1));
    }

    function test_bidBeforeOpen_andBelowReserve() public {
        vm.prank(alice);
        vm.expectRevert(ArtifactsSource.AuctionNotOpen.selector);
        source.bid{value: 1 ether}(address(0));

        _openAuction(1 ether, 1 days);
        vm.prank(alice);
        vm.expectRevert(ArtifactsSource.BidTooLow.selector);
        source.bid{value: 1 ether - 1}(address(0));
    }

    /// @dev The smallest reserve: the 5% raise rounds up, so 1 wei must be beaten by 2 wei, never matched.
    function test_dustRaise_oneWei() public {
        _openAuction(1, 1 days);
        vm.prank(alice);
        source.bid{value: 1}(address(0));
        vm.prank(bob);
        vm.expectRevert(ArtifactsSource.BidTooLow.selector);
        source.bid{value: 1}(address(0));
        vm.prank(bob);
        source.bid{value: 2}(address(0));
        assertEq(source.highBid(), 2);
        assertEq(source.refunds(alice), 1);
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_raiseRule_exactThreshold(uint256 reserve, uint256 first) public {
        reserve = bound(reserve, 1, 1e27);
        first = bound(first, reserve, 1e27);
        _openAuction(reserve, 1 days);
        vm.deal(alice, first);
        vm.prank(alice);
        source.bid{value: first}(address(0));

        uint256 need = _minNext(first);
        assertGt(need, first, "a raise must strictly beat the high bid");
        vm.deal(bob, need);
        vm.prank(bob);
        vm.expectRevert(ArtifactsSource.BidTooLow.selector);
        source.bid{value: need - 1}(address(0));
        vm.prank(bob);
        source.bid{value: need}(address(0));
        assertEq(source.highBidder(), bob);
        assertEq(source.refunds(alice), first);
        assertEq(address(source).balance, first + need);
    }

    function test_extension_atExactBoundaries() public {
        uint64 end = _openAuction(1 ether, 1 days);
        // exactly EXTENSION before the end: not "less than" EXTENSION left, so no extension
        vm.warp(end - 10 minutes);
        vm.prank(alice);
        source.bid{value: 1 ether}(address(0));
        assertEq(source.endTime(), end);

        // one second inside the window extends to now + EXTENSION
        vm.warp(end - 10 minutes + 1);
        vm.prank(bob);
        source.bid{value: 1.05 ether}(address(0));
        assertEq(source.endTime(), end + 1);

        // at the (new) end a bid is too late, and settling is allowed in the same second
        vm.warp(end + 1);
        vm.prank(carol);
        vm.expectRevert(ArtifactsSource.AuctionEnded.selector);
        source.bid{value: 2 ether}(address(0));
        source.settle();
        assertTrue(source.settled());
        assertEq(source.pieceContract() != address(0), true);
    }

    function test_settle_failurePaths() public {
        vm.expectRevert(ArtifactsSource.AuctionNotOpen.selector);
        source.settle();

        uint64 end = _openAuction(1 ether, 1 days);
        vm.warp(end);
        vm.expectRevert(ArtifactsSource.NoBids.selector);
        source.settle();

        // reopened with no bids: a bid lands, settle before the end fails, after it succeeds once
        vm.prank(curator);
        source.setAuction(1 ether, uint64(block.timestamp + 1 hours));
        vm.prank(alice);
        source.bid{value: 1 ether}(address(0));
        vm.expectRevert(ArtifactsSource.AuctionNotEnded.selector);
        source.settle();
        vm.warp(block.timestamp + 1 hours);
        source.settle();
        vm.expectRevert(ArtifactsSource.AuctionNotOpen.selector);
        source.settle();

        // after settlement nothing reopens it
        vm.prank(curator);
        vm.expectRevert(ArtifactsSource.AlreadySettled.selector);
        source.setAuction(1 ether, uint64(block.timestamp + 1 hours));
        vm.expectRevert(ArtifactsSource.AuctionNotOpen.selector);
        source.voidUnsettled();
    }

    function test_voidUnsettled_graceBoundary_thenReopen() public {
        uint64 end = _openAuction(1 ether, 1 days);
        vm.expectRevert(ArtifactsSource.NoBids.selector);
        source.voidUnsettled();

        vm.prank(alice);
        source.bid{value: 3 ether}(alice);
        // the ledger stops recording the module's sales: settling reverts and the bid would be stuck without the void
        vm.prank(curator);
        house.setSaleModule(address(source), false);
        vm.warp(end);
        vm.expectRevert(ArtHouse.NotSaleModule.selector);
        source.settle();

        vm.warp(uint256(end) + 7 days - 1);
        vm.expectRevert(ArtifactsSource.AuctionNotEnded.selector);
        source.voidUnsettled();
        vm.warp(uint256(end) + 7 days);
        vm.prank(carol); // anyone
        source.voidUnsettled();
        assertEq(source.highBidder(), address(0));
        assertEq(source.highBid(), 0);
        assertFalse(source.auctionOpen());
        assertEq(source.refunds(alice), 3 ether);

        vm.expectRevert(ArtifactsSource.AuctionNotOpen.selector);
        source.voidUnsettled();
        vm.expectRevert(ArtifactsSource.AuctionNotOpen.selector);
        source.settle();

        uint256 before = alice.balance;
        vm.prank(alice);
        source.withdrawRefund();
        assertEq(alice.balance, before + 3 ether);
        assertEq(address(source).balance, 0);
        vm.prank(alice);
        vm.expectRevert(ArtifactsSource.NothingToWithdraw.selector);
        source.withdrawRefund();

        // the curator may open it again once the module is restored
        vm.startPrank(curator);
        house.setSaleModule(address(source), true);
        source.setAuction(1 ether, uint64(block.timestamp + 1 days));
        vm.stopPrank();
        assertTrue(source.auctionOpen());
    }

    function test_setGate_lockedAfterFirstBid() public {
        _openAuction(1 ether, 1 days);
        vm.prank(alice);
        source.bid{value: 1 ether}(address(0));
        vm.startPrank(curator);
        vm.expectRevert(ArtifactsSource.AuctionLive.selector);
        source.setGate(address(seats), address(0), 0, 1 hours);
        vm.expectRevert(ArtifactsSource.AuctionLive.selector);
        source.setMemberGate(address(0), bytes4(0), 0);
        vm.expectRevert(ArtifactsSource.AuctionLive.selector);
        source.setAuction(1 ether, uint64(block.timestamp + 2 days));
        vm.stopPrank();
    }

    function test_deliverKey_beforeSettle_reverts() public {
        vm.prank(curator);
        vm.expectRevert(ArtifactsSource.NotSettled.selector);
        source.deliverKey(hex"01");
    }

    // ---------- BrokerPass start time ----------

    function test_setClaimsOpenAt_bounds() public {
        vm.warp(1_000_000);
        vm.prank(alice);
        vm.expectRevert(BrokerPass.NotCurator.selector);
        pass.setClaimsOpenAt(uint64(block.timestamp));

        vm.startPrank(curator);
        vm.expectRevert(BrokerPass.BadStart.selector);
        pass.setClaimsOpenAt(0);
        vm.expectRevert(BrokerPass.BadStart.selector);
        pass.setClaimsOpenAt(uint64(block.timestamp + 365 days + 1));
        pass.setClaimsOpenAt(uint64(block.timestamp + 365 days));
        vm.expectRevert(BrokerPass.StartAlreadySet.selector);
        pass.setClaimsOpenAt(uint64(block.timestamp));
        vm.stopPrank();

        uint256 at = block.timestamp + 365 days;
        seats.mint(alice, 7);
        vm.warp(at - 1);
        assertFalse(pass.claimsOpen());
        vm.prank(alice);
        vm.expectRevert(BrokerPass.ClaimsNotOpen.selector);
        pass.claimWithSeat(7);
        vm.warp(at);
        assertTrue(pass.claimsOpen());
        vm.prank(alice);
        assertEq(pass.claimWithSeat(7), 1);
    }

    /// @dev A start in the past opens claims at once.
    function test_setClaimsOpenAt_pastOpensNow() public {
        vm.warp(1_000_000);
        vm.prank(curator);
        pass.setClaimsOpenAt(1);
        assertTrue(pass.claimsOpen());
    }

    function test_claimWithPiece_idsOutsideTheCollection() public {
        vm.prank(curator);
        pass.setClaimsOpenAt(uint64(block.timestamp));
        uint256[4] memory ids = [uint256(0), 1, 256, 257];
        for (uint256 i; i < ids.length; ++i) {
            vm.prank(alice);
            vm.expectRevert(BrokerPass.NoSuchPiece.selector);
            pass.claimWithPiece(ids[i]);
        }
        // a seat nobody holds
        vm.prank(alice);
        vm.expectRevert(); // MockSeats reverts for an unminted seat
        pass.claimWithSeat(99);
        assertEq(pass.totalSupply(), 0);
        assertEq(pass.remaining(), 100);
    }

    /// @dev The curator's power to set the start follows the factory's two-step ownership.
    function test_setClaimsOpenAt_followsFactoryOwner() public {
        vm.prank(curator);
        factory.transferOwnership(bob);
        vm.prank(bob);
        vm.expectRevert(BrokerPass.NotCurator.selector); // pending, not yet owner
        pass.setClaimsOpenAt(uint64(block.timestamp));
        vm.prank(bob);
        factory.acceptOwnership();
        vm.prank(curator);
        vm.expectRevert(BrokerPass.NotCurator.selector);
        pass.setClaimsOpenAt(uint64(block.timestamp));
        vm.prank(bob);
        pass.setClaimsOpenAt(uint64(block.timestamp));
    }

    // ---------- SubmissionReviews ----------

    function _submission() internal returns (uint256 id) {
        vm.prank(carol);
        id = house.submit(keccak256("work"), "ipfs://preview");
        seats.mint(alice, 42);
    }

    function test_review_noteLength_boundary() public {
        uint256 id = _submission();
        vm.prank(alice);
        reviews.reviewAsSeat(id, 42, SubmissionReviews.Verdict.Back, string(new bytes(280)));
        vm.prank(alice);
        vm.expectRevert(SubmissionReviews.NoteTooLong.selector);
        reviews.reviewAsSeat(id, 42, SubmissionReviews.Verdict.Pass, string(new bytes(281)));
        // the refused update left the earlier review and tally untouched
        (uint256 b, uint256 n, uint256 p) = reviews.tally(id);
        assertEq(b, 1);
        assertEq(n + p, 0);
        assertEq(reviews.reviewCount(id), 1);
    }

    function test_review_failurePaths() public {
        uint256 id = _submission();
        vm.startPrank(alice);
        vm.expectRevert(SubmissionReviews.BadVerdict.selector);
        reviews.reviewAsSeat(id, 42, SubmissionReviews.Verdict.None, "");
        vm.expectRevert(SubmissionReviews.NoSuchSubmission.selector);
        reviews.reviewAsSeat(id + 1, 42, SubmissionReviews.Verdict.Back, "");
        // a seat id in the piece-voice range can never speak as a seat
        uint256 pv = reviews.PIECE_VOICE();
        vm.expectRevert(SubmissionReviews.NotHolder.selector);
        reviews.reviewAsSeat(id, pv, SubmissionReviews.Verdict.Back, "");
        vm.expectRevert(SubmissionReviews.NotHolder.selector);
        reviews.reviewAsSeat(id, 43, SubmissionReviews.Verdict.Back, ""); // unminted seat: ownerOf reverts
        vm.expectRevert(SubmissionReviews.NoSuchPiece.selector);
        reviews.reviewAsPiece(id, 0, SubmissionReviews.Verdict.Back, "");
        vm.expectRevert(SubmissionReviews.NoSuchPiece.selector);
        reviews.reviewAsPiece(id, 257, SubmissionReviews.Verdict.Back, "");
        vm.stopPrank();
        vm.prank(bob);
        vm.expectRevert(SubmissionReviews.NotHolder.selector);
        reviews.reviewAsSeat(id, 42, SubmissionReviews.Verdict.Back, "");
        assertEq(reviews.reviewCount(id), 0);
    }

    function test_thesis_lengthBounds_andDecline() public {
        uint256 id = _submission();
        vm.startPrank(bob);
        vm.expectRevert(SubmissionReviews.BadThesis.selector);
        reviews.postThesis(id, "");
        vm.expectRevert(SubmissionReviews.BadThesis.selector);
        reviews.postThesis(id, string(new bytes(4_001)));
        reviews.postThesis(id, string(new bytes(4_000)));
        reviews.postThesis(id, "again"); // same author: counted once
        vm.expectRevert(SubmissionReviews.BadThesis.selector);
        reviews.applyAsBroker(string(new bytes(4_001)));
        vm.expectRevert(SubmissionReviews.BadThesis.selector);
        reviews.applyAsBroker("");
        reviews.applyAsBroker(string(new bytes(4_000)));
        vm.stopPrank();
        assertEq(reviews.thesisAuthors(id), 1);
        assertEq(reviews.appliedAt(bob), block.timestamp);
        assertFalse(house.isEligibleBroker(bob), "an application grants nothing");

        vm.prank(curator);
        house.decideSubmission(id, false);
        vm.prank(bob);
        vm.expectRevert(SubmissionReviews.Declined.selector);
        reviews.postThesis(id, "after the decline");
        vm.prank(alice);
        vm.expectRevert(SubmissionReviews.NotPending.selector);
        reviews.reviewAsSeat(id, 42, SubmissionReviews.Verdict.Back, "");
        vm.prank(curator);
        vm.expectRevert(ArtHouse.NotPending.selector);
        house.decideSubmission(id, true);
    }

    function test_reviewsOf_pagination_edges() public {
        uint256 id = _submission();
        seats.mint(bob, 43);
        vm.prank(alice);
        reviews.reviewAsSeat(id, 42, SubmissionReviews.Verdict.Back, "a");
        vm.prank(bob);
        reviews.reviewAsSeat(id, 43, SubmissionReviews.Verdict.Pass, "b");
        (uint256[] memory v,) = reviews.reviewsOf(id, 5, 10); // start beyond the end
        assertEq(v.length, 0);
        (v,) = reviews.reviewsOf(id, 1, 0); // zero count
        assertEq(v.length, 0);
        (v,) = reviews.reviewsOf(id, 1, 100);
        assertEq(v.length, 1);
        assertEq(v[0], 43);
    }

    // ---------- ArtHouse plain collections ----------

    function _collection() internal returns (address c) {
        vm.prank(curator);
        c = house.createCollection("Plain", "PLN", artist);
        vm.prank(artist);
        house.registerPiece(c, 0, keccak256("x"), "t", "d");
    }

    /// @dev MAX_PIECE_BYTES is inclusive: exactly 100,000 bytes fit, one more byte does not.
    function test_pieceByteCap_exactBoundary() public {
        address c = _collection();
        vm.startPrank(artist);
        for (uint256 i; i < 4; ++i) {
            house.uploadChunk(c, 0, i, new bytes(24_000));
        }
        house.uploadChunk(c, 0, 4, new bytes(4_000));
        (,,,,, uint256 size) = house.pieces(c, 0);
        assertEq(size, 100_000);
        vm.expectRevert(ArtHouse.TooLarge.selector);
        house.uploadChunk(c, 0, 5, new bytes(1));
        vm.expectRevert(ArtHouse.BadIndex.selector);
        house.uploadChunk(c, 0, 4, new bytes(1));
        vm.stopPrank();
        assertEq(store.size(c, 0), 100_000);

        // the curator may wipe and start over; the artist may not
        vm.prank(artist);
        vm.expectRevert(TwoStepOwnable.NotOwner.selector);
        house.clearPiece(c, 0);
        vm.prank(curator);
        house.clearPiece(c, 0);
        assertEq(store.chunkCount(c, 0), 0);
        vm.prank(artist);
        house.uploadChunk(c, 0, 0, new bytes(1));
    }

    function test_plainCollection_curationFailurePaths() public {
        address c = _collection();
        vm.startPrank(artist);
        vm.expectRevert(ArtHouse.BadPieceId.selector);
        house.registerPiece(c, 2, keccak256("y"), "t", "d"); // ids are sequential
        vm.expectRevert(ArtHouse.BadPieceId.selector);
        house.uploadChunk(c, 1, 0, hex"00");
        vm.expectRevert(ArtHouse.HashMismatch.selector);
        house.finalizePiece(c, 0); // nothing uploaded
        vm.stopPrank();

        vm.startPrank(curator);
        vm.expectRevert(ArtHouse.NotSealed.selector);
        house.setSaleOpen(c, true);
        vm.expectRevert(ArtHouse.NotFinalized.selector);
        house.sealCollection(c);
        vm.expectRevert(ArtHouse.UnknownCollection.selector);
        house.setPrices(address(factory), 1, 1); // a module collection has no prices here
        vm.expectRevert(ArtHouse.UnknownCollection.selector);
        house.registerModuleCollection(address(factory), artist); // registered once
        vm.expectRevert(ArtHouse.BadSplit.selector);
        house.setSplit(c, 1500, 500, 7500, 499);
        vm.stopPrank();

        // a revoked artist loses curation rights at once
        vm.prank(curator);
        house.revokeArtist(artist);
        vm.prank(artist);
        vm.expectRevert(ArtHouse.NotCurator.selector);
        house.uploadChunk(c, 0, 0, hex"00");
        vm.prank(alice);
        vm.expectRevert(ArtHouse.NotCurator.selector);
        house.updatePiece(c, 0, keccak256("z"), "t", "d");
    }

    function test_mint_failurePaths_andOneMintPerPiece() public {
        address c = _collection();
        bytes memory svg = "<svg/>";
        vm.startPrank(artist);
        house.updatePiece(c, 0, keccak256(svg), "t", "d");
        house.uploadChunk(c, 0, 0, svg);
        house.finalizePiece(c, 0);
        vm.expectRevert(ArtHouse.Finalized.selector);
        house.uploadChunk(c, 0, 1, svg);
        vm.stopPrank();

        vm.prank(alice);
        vm.expectRevert(ArtHouse.SaleClosed.selector);
        house.mint{value: 1 ether}(c, 0, address(0));

        vm.startPrank(curator);
        house.sealCollection(c);
        house.setSaleOpen(c, true);
        vm.stopPrank();
        vm.prank(alice);
        vm.expectRevert(ArtHouse.WrongPrice.selector); // no ETH price set
        house.mint{value: 0}(c, 0, address(0));

        vm.prank(curator);
        house.setPrices(c, 1 ether, 0);
        vm.prank(alice);
        vm.expectRevert(ArtHouse.WrongPrice.selector);
        house.mint{value: 1 ether + 1}(c, 0, address(0));
        vm.prank(alice);
        vm.expectRevert(ArtHouse.WrongPrice.selector); // no IMD price set
        house.mintWithIMD(c, 0, address(0), 0);
        vm.prank(alice);
        vm.expectRevert(ArtHouse.BadPieceId.selector);
        house.mint{value: 1 ether}(c, 1, address(0));

        uint256 artistBefore = _artistEth();
        vm.prank(alice);
        house.mint{value: 1 ether}(c, 0, address(0));
        // no broker named: 75% to the artist, 5% house, the broker's 15% plus 5% to the buyback
        assertEq(_artistEth() - artistBefore, 0.75 ether);
        assertEq(house.balances(address(house), address(0)), 0.05 ether);
        assertEq(house.balances(house.BUYBACK(), address(0)), 0.2 ether);
        vm.prank(bob);
        vm.expectRevert(ArtHouse.AlreadyMinted.selector);
        house.mint{value: 1 ether}(c, 0, address(0));
    }

    function test_ledger_withdrawAndRelease_failurePaths() public {
        vm.prank(alice);
        vm.expectRevert(ArtHouse.NothingToWithdraw.selector);
        house.withdraw(address(0));
        vm.prank(alice);
        vm.expectRevert(TwoStepOwnable.NotOwner.selector);
        house.withdrawHouse(address(0));
        vm.prank(curator);
        vm.expectRevert(ArtHouse.NothingToWithdraw.selector);
        house.withdrawHouse(address(0));
        vm.expectRevert(ArtHouse.NoBuybackBurner.selector);
        house.releaseBuyback(address(0));
        vm.startPrank(curator);
        vm.expectRevert(TwoStepOwnable.ZeroAddress.selector);
        house.setBuybackBurner(address(0));
        house.setBuybackBurner(bob);
        vm.expectRevert(ArtHouse.BuybackBurnerAlreadySet.selector);
        house.setBuybackBurner(carol);
        vm.stopPrank();
        vm.expectRevert(ArtHouse.NothingToWithdraw.selector);
        house.releaseBuyback(address(0));
        // module sale entry points are for approved modules only, and never for nothing
        vm.prank(alice);
        vm.expectRevert(ArtHouse.NotSaleModule.selector);
        house.recordSale{value: 1}(address(factory), alice, address(0));
        vm.prank(address(factory));
        vm.expectRevert(ArtHouse.WrongPrice.selector);
        house.recordSale(address(factory), alice, address(0));
        vm.deal(address(factory), 1 ether);
        vm.prank(address(factory));
        vm.expectRevert(ArtHouse.NotModuleCollection.selector);
        house.recordSale{value: 1}(alice, alice, address(0));
    }
}

// ---------- invariant: THE SOURCE's escrow of bids across voids and re-openings ----------

/// @dev Bids at or above the raise rule (and below it, expecting the refusal), refunds, time jumps over the end and
/// the seven-day grace, voids, re-openings by the curator, and settlement. Ghost totals track every wei in and out.
contract SourceVoidHandler is Test {
    ArtifactsSource public source;
    address public curator;
    address[] public actors;

    uint256 public ghostIn;
    uint256 public ghostRefunded;
    uint256 public ghostSettled;
    uint256 public voids;
    uint256 public reopens;
    uint256 public settles;
    uint256 public roundHigh; // the high bid of the current round, which only rises within it

    constructor(ArtifactsSource s, address curator_, address[] memory actors_) {
        source = s;
        curator = curator_;
        actors = actors_;
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function bid(uint256 a, uint256 amount, bool belowMin) external {
        address actor = actors[a % actors.length];
        uint256 h = source.highBid();
        uint256 min = h == 0 ? source.reserve() : (h * 10_500 + 9_999) / 10_000;
        bool live = source.auctionOpen() && block.timestamp < source.endTime();
        if (belowMin && min > 1) amount = bound(amount, 0, min - 1);
        else amount = bound(amount, min, min * 2 + 1);
        vm.deal(actor, amount);
        bool ok = live && amount >= min && min > 0;
        vm.prank(actor);
        if (!ok) vm.expectRevert();
        source.bid{value: amount}(address(0));
        if (ok) {
            ghostIn += amount;
            assertGt(amount, roundHigh);
            roundHigh = amount;
        }
    }

    function withdrawRefund(uint256 a) external {
        address actor = actors[a % actors.length];
        uint256 owed = source.refunds(actor);
        uint256 before = actor.balance;
        vm.prank(actor);
        if (owed == 0) vm.expectRevert(ArtifactsSource.NothingToWithdraw.selector);
        source.withdrawRefund();
        if (owed > 0) {
            ghostRefunded += owed;
            assertEq(actor.balance, before + owed);
            assertEq(source.refunds(actor), 0);
        }
    }

    function warp(uint256 d) external {
        vm.warp(block.timestamp + bound(d, 1, 8 days));
    }

    function voidUnsettled() external {
        bool ok = source.auctionOpen() && !source.settled() && source.highBidder() != address(0)
            && block.timestamp >= uint256(source.endTime()) + 7 days;
        if (!ok) vm.expectRevert();
        source.voidUnsettled();
        if (ok) {
            voids++;
            roundHigh = 0;
        }
    }

    function reopen(uint256 reserve, uint256 dur) external {
        reserve = bound(reserve, 1, 10 ether);
        dur = bound(dur, 1, 3 days);
        bool ok = !source.settled() && source.highBidder() == address(0);
        vm.prank(curator);
        if (!ok) vm.expectRevert();
        source.setAuction(reserve, uint64(block.timestamp + dur));
        if (ok) {
            reopens++;
            roundHigh = 0;
        }
    }

    function settle() external {
        bool ok = source.auctionOpen() && block.timestamp >= source.endTime() && !source.settled()
            && source.highBidder() != address(0);
        uint256 h = source.highBid();
        if (!ok) vm.expectRevert();
        source.settle();
        if (ok) {
            settles++;
            ghostSettled += h;
        }
    }
}

contract SourceVoidInvariantTest is Fixture {
    SourceVoidHandler internal handler;
    address[] internal actors;

    function setUp() public override {
        super.setUp();
        vm.startPrank(curator);
        source.storeRendererChunk("<html>");
        source.lock(SEALED_SEED, SOURCE_COMMITMENT);
        source.setAuction(1, uint64(block.timestamp + 1 days));
        vm.stopPrank();
        actors.push(alice);
        actors.push(bob);
        actors.push(carol);
        actors.push(makeAddr("dave"));
        handler = new SourceVoidHandler(source, curator, actors);
        targetContract(address(handler));
        bytes4[] memory sel = new bytes4[](6);
        sel[0] = SourceVoidHandler.bid.selector;
        sel[1] = SourceVoidHandler.withdrawRefund.selector;
        sel[2] = SourceVoidHandler.warp.selector;
        sel[3] = SourceVoidHandler.voidUnsettled.selector;
        sel[4] = SourceVoidHandler.reopen.selector;
        sel[5] = SourceVoidHandler.settle.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sel}));
    }

    function _owed() internal view returns (uint256 total) {
        for (uint256 i; i < actors.length; ++i) {
            total += source.refunds(actors[i]);
        }
    }

    /// @dev What the auction holds is exactly every refund owed plus the live high bid (none once settled).
    /// forge-config: default.invariant.runs = 96
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_holdsExactlyWhatItOwes() public view {
        uint256 live = source.settled() ? 0 : source.highBid();
        assertEq(address(source).balance, _owed() + live);
        assertEq(address(source).balance, handler.ghostIn() - handler.ghostRefunded() - handler.ghostSettled());
    }

    /// forge-config: default.invariant.runs = 96
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_settlementIsFinalAndSingle() public view {
        assertLe(handler.settles(), 1);
        if (source.settled()) {
            assertFalse(source.auctionOpen());
            assertTrue(source.pieceContract() != address(0));
            assertEq(handler.ghostSettled(), source.highBid());
        } else {
            assertEq(source.pieceContract(), address(0));
            if (source.highBidder() == address(0)) assertEq(source.highBid(), 0);
        }
    }
}
