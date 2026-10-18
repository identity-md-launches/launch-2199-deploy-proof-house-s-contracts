// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Fixture} from "../Fixture.sol";
import {ArtHouse} from "src/ArtHouse.sol";
import {SubmissionReviews} from "src/SubmissionReviews.sol";
import {MockSeats} from "../mocks/MockSeats.sol";
import {TwoStepOwnable} from "src/base/TwoStepOwnable.sol";

/// @dev Model votes by credential, independently of its current holder. Submission zero stays pending so long
/// sequences keep exercising edits; the other two can reach either final decision and must then remain frozen.
contract ReviewHistoryHandler is Test {
    ArtHouse public immutable house;
    SubmissionReviews public immutable reviews;
    MockSeats public immutable seats;
    address[4] public actors;
    mapping(uint256 => uint8) public status;
    mapping(uint256 => mapping(uint256 => uint8)) public verdict;
    mapping(uint256 => mapping(uint256 => bytes32)) public recordHash;
    mapping(uint256 => uint256[]) private order;
    mapping(uint256 => mapping(address => uint64)) public thesisTimestamp;
    mapping(uint256 => uint256) public authors;

    constructor(ArtHouse house_, SubmissionReviews reviews_, MockSeats seats_, address[4] memory actors_) {
        house = house_;
        reviews = reviews_;
        seats = seats_;
        actors = actors_;
    }

    function voiceAt(uint256 submission, uint256 index) external view returns (uint256) {
        return order[submission][index];
    }

    function count(uint256 submission) external view returns (uint256) {
        return order[submission].length;
    }

    function review(uint256 submissionSeed, uint256 seatSeed, uint256 verdictSeed, bool asHolder) external {
        uint256 id = submissionSeed % 3;
        uint256 seat = 1 + seatSeed % 8;
        address owner = seats.ownerOf(seat);
        address actor = asHolder ? owner : actors[(seatSeed / 8) % 4];
        SubmissionReviews.Verdict vote = SubmissionReviews.Verdict(1 + verdictSeed % 3);
        string memory note = string(abi.encodePacked(bytes32(verdictSeed)));
        bytes4 error;
        if (actor != owner) error = SubmissionReviews.NotHolder.selector;
        else if (status[id] != 0) error = SubmissionReviews.NotPending.selector;
        vm.prank(actor);
        if (error != bytes4(0)) vm.expectRevert(error);
        reviews.reviewAsSeat(id, seat, vote, note);
        if (error == bytes4(0)) {
            if (verdict[id][seat] == 0) order[id].push(seat);
            verdict[id][seat] = uint8(vote);
            recordHash[id][seat] = keccak256(abi.encode(vote, uint64(block.timestamp), actor, note));
        }
    }

    function moveSeat(uint256 seatSeed, uint256 actorSeed) external {
        uint256 seat = 1 + seatSeed % 8;
        address owner = seats.ownerOf(seat);
        vm.prank(owner);
        seats.transferFrom(owner, actors[actorSeed % 4], seat);
    }

    function decide(uint256 seed, bool accept, bool authorized) external {
        uint256 id = 1 + seed % 2;
        address actor = authorized ? house.owner() : actors[seed % 4];
        bytes4 error;
        if (!authorized) error = TwoStepOwnable.NotOwner.selector;
        else if (status[id] != 0) error = ArtHouse.NotPending.selector;
        vm.prank(actor);
        if (error != bytes4(0)) vm.expectRevert(error);
        house.decideSubmission(id, accept);
        if (error == bytes4(0)) status[id] = accept ? 1 : 2;
    }

    function thesis(uint256 submissionSeed, uint256 actorSeed, uint256 lengthSeed) external {
        uint256 id = submissionSeed % 3;
        address actor = actors[actorSeed % 4];
        uint256[4] memory lengths = [uint256(0), 1, 4_000, 4_001];
        uint256 length = lengths[lengthSeed % 4];
        bytes4 error;
        if (length == 0 || length > 4_000) error = SubmissionReviews.BadThesis.selector;
        else if (status[id] == 2) error = SubmissionReviews.Declined.selector;
        vm.prank(actor);
        if (error != bytes4(0)) vm.expectRevert(error);
        reviews.postThesis(id, string(new bytes(length)));
        if (error == bytes4(0)) {
            if (thesisTimestamp[id][actor] == 0) ++authors[id];
            thesisTimestamp[id][actor] = uint64(block.timestamp);
        }
    }

    function invalidReview(uint256 seatSeed, uint256 modeSeed) external {
        uint256 seat = 1 + seatSeed % 8;
        address actor = seats.ownerOf(seat);
        uint256 mode = modeSeed % 3;
        vm.prank(actor);
        if (mode == 0) {
            vm.expectRevert(SubmissionReviews.BadVerdict.selector);
            reviews.reviewAsSeat(0, seat, SubmissionReviews.Verdict.None, "");
        } else if (mode == 1) {
            vm.expectRevert(SubmissionReviews.NoteTooLong.selector);
            reviews.reviewAsSeat(0, seat, SubmissionReviews.Verdict.Back, string(new bytes(281)));
        } else {
            vm.expectRevert(SubmissionReviews.NoSuchSubmission.selector);
            reviews.reviewAsSeat(3, seat, SubmissionReviews.Verdict.Back, "");
        }
    }

    function advanceTime(uint256 seed) external {
        vm.warp(block.timestamp + bound(seed, 1, 30 days));
    }
}

/// forge-config: default.invariant.runs = 96
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract ReviewHistoryInvariantTest is Fixture {
    ReviewHistoryHandler internal handler;
    SubmissionReviews internal reviews;

    function setUp() public override {
        super.setUp();
        MockSeats seats = new MockSeats();
        reviews = new SubmissionReviews(address(house), address(seats), address(factory), address(source));
        address[4] memory actors;
        for (uint256 i; i < 4; ++i) {
            actors[i] = makeAddr(string.concat("review actor", vm.toString(i)));
            seats.mint(actors[i], i + 1);
            seats.mint(actors[i], i + 5);
        }
        for (uint256 id; id < 3; ++id) {
            vm.prank(actors[id]);
            house.submit(keccak256(abi.encode("submission", id)), "ipfs://review-invariant");
        }
        handler = new ReviewHistoryHandler(house, reviews, seats, actors);
        // Reach non-empty records before random sequences, including both future final-decision branches.
        for (uint256 id; id < 3; ++id) {
            handler.review(id, id, id, true);
            handler.thesis(id, id, 1);
        }
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = handler.review.selector;
        selectors[1] = handler.moveSeat.selector;
        selectors[2] = handler.decide.selector;
        selectors[3] = handler.thesis.selector;
        selectors[4] = handler.invalidReview.selector;
        selectors[5] = handler.advanceTime.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function test_finalDecisionsFreezeOldAndNewHolderReviews() public {
        handler.decide(0, true, true); // submission 1 accepted
        handler.decide(1, false, true); // submission 2 rejected
        handler.review(1, 1, 2, true);
        handler.moveSeat(1, 3);
        handler.review(1, 1, 0, true);
        handler.review(2, 2, 1, true);
        handler.moveSeat(2, 0);
        handler.review(2, 2, 2, true);
        handler.thesis(1, 3, 2); // accepted submissions remain open to theses
        handler.thesis(2, 3, 2); // rejected submissions do not
        assertEq(reviews.thesisAuthors(1), 2);
        assertEq(reviews.thesisAuthors(2), 1);
        invariant_votesArePerCredentialAndFinalDecisionsFreezeRecords();
        invariant_pagesKeepFirstReviewOrderAndLatestContents();
        invariant_thesisCountsDistinctAuthorsWithoutGrantingBrokerPowers();
    }

    function test_transferredSeatEditsOneExistingVoiceInPlace() public {
        handler.review(0, 0, 2, true);
        handler.moveSeat(0, 3);
        handler.advanceTime(1);
        handler.review(0, 0, 1, true);
        assertEq(reviews.reviewCount(0), 1);
        assertEq(reviews.reviewOf(0, 1).reviewer, handler.actors(3));
        (uint256 backs, uint256 neutrals, uint256 passes) = reviews.tally(0);
        assertEq(backs, 0);
        assertEq(neutrals, 1);
        assertEq(passes, 0);
        invariant_votesArePerCredentialAndFinalDecisionsFreezeRecords();
        invariant_pagesKeepFirstReviewOrderAndLatestContents();
    }

    function invariant_votesArePerCredentialAndFinalDecisionsFreezeRecords() public view {
        for (uint256 id; id < 3; ++id) {
            uint256[4] memory expectedTally;
            uint256 total;
            for (uint256 seat = 1; seat <= 8; ++seat) {
                uint8 vote = handler.verdict(id, seat);
                SubmissionReviews.Review memory r = reviews.reviewOf(id, seat);
                assertEq(uint8(r.verdict), vote);
                if (vote == 0) {
                    assertEq(r.reviewer, address(0));
                    continue;
                }
                ++total;
                ++expectedTally[vote];
                assertEq(keccak256(abi.encode(r.verdict, r.at, r.reviewer, r.note)), handler.recordHash(id, seat));
            }
            (uint256 backs, uint256 neutrals, uint256 passes) = reviews.tally(id);
            assertEq(backs, expectedTally[1]);
            assertEq(neutrals, expectedTally[2]);
            assertEq(passes, expectedTally[3]);
            assertEq(reviews.reviewCount(id), total);
            assertEq(handler.count(id), total);
            (,,, ArtHouse.SubmissionStatus actual) = house.submissions(id);
            assertEq(uint8(actual), handler.status(id));
        }
    }

    function invariant_pagesKeepFirstReviewOrderAndLatestContents() public view {
        for (uint256 id; id < 3; ++id) {
            // Reassemble from two-item pages, including an empty page past the last review.
            uint256 total = handler.count(id);
            for (uint256 offset; offset <= total; offset += 2) {
                (uint256[] memory voices, SubmissionReviews.Review[] memory list) = reviews.reviewsOf(id, offset, 2);
                uint256 expectedLength = offset >= total ? 0 : total - offset < 2 ? total - offset : 2;
                assertEq(voices.length, expectedLength);
                assertEq(list.length, expectedLength);
                for (uint256 i; i < voices.length; ++i) {
                    uint256 voice = handler.voiceAt(id, offset + i);
                    assertEq(voices[i], voice);
                    SubmissionReviews.Review memory r = list[i];
                    assertEq(keccak256(abi.encode(r.verdict, r.at, r.reviewer, r.note)), handler.recordHash(id, voice));
                }
            }
        }
    }

    function invariant_thesisCountsDistinctAuthorsWithoutGrantingBrokerPowers() public view {
        for (uint256 id; id < 3; ++id) {
            assertEq(reviews.thesisAuthors(id), handler.authors(id));
            for (uint256 i; i < 4; ++i) {
                address actor = handler.actors(i);
                assertEq(reviews.thesisAt(id, actor), handler.thesisTimestamp(id, actor));
                assertFalse(house.isEligibleBroker(actor));
            }
        }
    }
}
