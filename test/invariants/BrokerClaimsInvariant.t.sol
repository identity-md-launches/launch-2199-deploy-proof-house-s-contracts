// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Fixture} from "../Fixture.sol";
import {MockSeats} from "../mocks/MockSeats.sol";
import {BrokerPass} from "src/BrokerPass.sol";
import {ArtifactsPiece} from "src/ArtifactsPiece.sol";
import {ArtHouse} from "src/ArtHouse.sol";
import {ERC721Lite} from "src/base/ERC721Lite.sol";

/// @dev Independent claim history: transferring either credential or pass never resets an entitlement.
contract BrokerClaimsHandler is Test {
    BrokerPass public immutable pass;
    MockSeats public immutable seats;
    ArtHouse public immutable house;
    address[8] public actors;
    ArtifactsPiece[3] public pieces;
    uint256 public issued;
    mapping(address => bool) public claimedWallet;
    mapping(uint256 => bool) public claimedSeat;
    mapping(uint256 => bool) public claimedPiece;
    mapping(uint256 => address) public passOwner;
    mapping(uint256 => address) public originalClaimer;

    constructor(
        BrokerPass pass_,
        MockSeats seats_,
        ArtHouse house_,
        address[8] memory actors_,
        ArtifactsPiece[3] memory pieces_
    ) {
        pass = pass_;
        seats = seats_;
        house = house_;
        actors = actors_;
        pieces = pieces_;
    }

    function claimSeat(uint256 seatSeed, uint256 actorSeed, bool holder) external {
        uint256 id = 1 + seatSeed % 16;
        address actor = holder ? seats.ownerOf(id) : actors[actorSeed % 8];
        bytes4 error = _claimError(actor, claimedSeat[id]);
        if (error == bytes4(0) && seats.ownerOf(id) != actor) error = BrokerPass.NotHolder.selector;
        vm.prank(actor);
        if (error != bytes4(0)) vm.expectRevert(error);
        uint256 token = pass.claimWithSeat(id);
        if (error == bytes4(0)) {
            claimedSeat[id] = true;
            _record(actor, token);
        }
    }

    function claimPiece(uint256 pieceSeed, uint256 actorSeed, bool holder) external {
        ArtifactsPiece piece = pieces[pieceSeed % 3];
        uint256 id = piece.pieceId();
        address actor = holder ? piece.ownerOf(1) : actors[actorSeed % 8];
        bytes4 error = _claimError(actor, claimedPiece[id]);
        if (error == bytes4(0) && piece.ownerOf(1) != actor) error = BrokerPass.NotHolder.selector;
        vm.prank(actor);
        if (error != bytes4(0)) vm.expectRevert(error);
        uint256 token = pass.claimWithPiece(id);
        if (error == bytes4(0)) {
            claimedPiece[id] = true;
            _record(actor, token);
        }
    }

    function _claimError(address actor, bool credentialUsed) internal view returns (bytes4) {
        if (!pass.claimsOpen()) return BrokerPass.ClaimsNotOpen.selector;
        if (claimedWallet[actor]) return BrokerPass.WalletAlreadyClaimed.selector;
        if (credentialUsed) return BrokerPass.AlreadyClaimed.selector;
        return bytes4(0);
    }

    function _record(address actor, uint256 token) internal {
        assertEq(token, issued + 1, "claim ids are consecutive");
        ++issued;
        claimedWallet[actor] = true;
        passOwner[token] = actor;
        originalClaimer[token] = actor;
    }

    function moveSeat(uint256 seed, uint256 actorSeed) external {
        uint256 id = 1 + seed % 16;
        address owner = seats.ownerOf(id);
        vm.prank(owner);
        seats.transferFrom(owner, actors[actorSeed % 8], id);
    }

    function movePiece(uint256 seed, uint256 actorSeed) external {
        ArtifactsPiece piece = pieces[seed % 3];
        address owner = piece.ownerOf(1);
        vm.prank(owner);
        piece.transferFrom(owner, actors[actorSeed % 8], 1);
    }

    function movePass(uint256 seed, uint256 actorSeed, bool byApproved) external {
        if (issued == 0) return;
        uint256 id = 1 + seed % issued;
        address owner = passOwner[id];
        address to = actors[actorSeed % 8];
        address operator = actors[(actorSeed / 8) % 8];
        if (byApproved) {
            vm.prank(owner);
            pass.approve(operator, id);
        }
        vm.prank(byApproved ? operator : owner);
        pass.transferFrom(owner, to, id);
        passOwner[id] = to;
        assertEq(pass.getApproved(id), address(0), "approval cleared even on self transfer");
    }

    function rejectedTransfer(uint256 seed, uint256 actorSeed) external {
        if (issued == 0) return;
        uint256 id = 1 + seed % issued;
        address owner = passOwner[id];
        address outsider = makeAddr("pass transfer outsider");
        vm.prank(outsider);
        vm.expectRevert(ERC721Lite.NotAuthorized.selector);
        pass.transferFrom(owner, actors[actorSeed % 8], id);
        vm.prank(owner);
        vm.expectRevert(ERC721Lite.InvalidReceiver.selector);
        pass.transferFrom(owner, address(0), id);
        assertEq(pass.ownerOf(id), owner);
    }

    function advanceTime(uint256 seed) external {
        vm.warp(block.timestamp + bound(seed, 1, 2 days));
    }
}

/// forge-config: default.invariant.runs = 96
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract BrokerClaimsInvariantTest is Fixture {
    BrokerClaimsHandler internal handler;
    BrokerPass internal pass;
    MockSeats internal seats;
    uint64 internal start;

    function setUp() public override {
        super.setUp();
        _publishAll();
        _openSale(1 ether);
        ArtifactsPiece[3] memory pieces;
        pieces[0] = _claim(alice, _buyAndAssign(alice, address(0), 7));
        pieces[1] = _claim(bob, _buyAndAssign(bob, address(0), 11));
        vm.startPrank(curator);
        source.storeRendererChunk("invariant payload");
        source.lock(SEALED_SEED, SOURCE_COMMITMENT);
        source.setAuction(1 ether, uint64(block.timestamp + 1 days));
        vm.stopPrank();
        vm.prank(carol);
        source.bid{value: 1 ether}(address(0));
        vm.warp(block.timestamp + 1 days);
        pieces[2] = ArtifactsPiece(source.settle());
        seats = new MockSeats();
        pass = new BrokerPass(address(seats), address(factory), address(source));
        start = uint64(block.timestamp + 1 days);
        vm.startPrank(curator);
        house.setBrokerPass(address(pass));
        pass.setClaimsOpenAt(start);
        vm.stopPrank();
        address[8] memory actors;
        for (uint256 i; i < 8; ++i) {
            actors[i] = makeAddr(string.concat("claim actor", vm.toString(i)));
            seats.mint(actors[i], i + 1);
            seats.mint(actors[i], i + 9);
        }
        for (uint256 i; i < 3; ++i) {
            address owner = pieces[i].ownerOf(1);
            vm.prank(owner);
            pieces[i].transferFrom(owner, actors[i], 1);
        }
        handler = new BrokerClaimsHandler(pass, seats, house, actors, pieces);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = handler.claimSeat.selector;
        selectors[1] = handler.claimPiece.selector;
        selectors[2] = handler.moveSeat.selector;
        selectors[3] = handler.movePiece.selector;
        selectors[4] = handler.movePass.selector;
        selectors[5] = handler.rejectedTransfer.selector;
        selectors[6] = handler.advanceTime.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function test_seatAndPassTransfersDoNotResetEitherClaimLimit() public {
        vm.warp(start);
        handler.claimSeat(0, 0, true);
        handler.moveSeat(0, 1);
        handler.claimSeat(0, 1, true); // new holder, credential already used
        handler.movePass(0, 1, true);
        handler.claimSeat(8, 0, true); // original wallet has another seat, but already claimed
        assertEq(handler.issued(), 1);
        assertFalse(house.isEligibleBroker(handler.actors(0)));
        assertTrue(house.isEligibleBroker(handler.actors(1)));
        invariant_claimHistorySurvivesTransfers();
        invariant_ownershipBalancesAndBrokerRightsAgree();
    }

    function test_sourceClaimAlsoConsumesTheWalletsSeatEntitlement() public {
        vm.warp(start);
        handler.claimPiece(2, 2, true);
        handler.claimSeat(2, 2, true);
        handler.movePiece(2, 3);
        handler.claimPiece(2, 3, true);
        assertEq(handler.issued(), 1);
        assertTrue(pass.pieceClaimed(256));
        assertFalse(pass.seatClaimed(3), "failed claim leaves the unused seat available");
        invariant_claimHistorySurvivesTransfers();
    }

    function test_startIsInclusiveAndClosedClaimsLeaveNoHistory() public {
        vm.warp(start - 1);
        handler.claimSeat(0, 0, true);
        handler.claimPiece(2, 2, true);
        assertEq(handler.issued(), 0);
        invariant_claimHistorySurvivesTransfers();
        vm.warp(start);
        handler.claimSeat(0, 0, true);
        handler.claimPiece(2, 2, true);
        assertEq(handler.issued(), 2);
        invariant_claimHistorySurvivesTransfers();
    }

    function invariant_claimHistorySurvivesTransfers() public view {
        uint256 walletClaims;
        for (uint256 i; i < 8; ++i) {
            address actor = handler.actors(i);
            bool claimed = handler.claimedWallet(actor);
            assertEq(pass.walletClaimed(actor), claimed);
            if (claimed) ++walletClaims;
        }
        uint256 credentials;
        for (uint256 i = 1; i <= 16; ++i) {
            assertEq(pass.seatClaimed(i), handler.claimedSeat(i));
            if (handler.claimedSeat(i)) ++credentials;
        }
        for (uint256 i; i < 3; ++i) {
            uint256 id = handler.pieces(i).pieceId();
            assertEq(pass.pieceClaimed(id), handler.claimedPiece(id));
            if (handler.claimedPiece(id)) ++credentials;
        }
        assertEq(credentials, handler.issued());
        assertEq(walletClaims, handler.issued(), "exactly one original wallet per pass");
        assertEq(pass.totalSupply(), handler.issued());
        assertEq(pass.totalSupply() + pass.remaining(), 100);
    }

    function invariant_ownershipBalancesAndBrokerRightsAgree() public view {
        uint256[8] memory balances;
        for (uint256 id = 1; id <= handler.issued(); ++id) {
            address owner = handler.passOwner(id);
            assertEq(pass.ownerOf(id), owner);
            for (uint256 i; i < 8; ++i) {
                if (owner == handler.actors(i)) ++balances[i];
            }
            for (uint256 other = id + 1; other <= handler.issued(); ++other) {
                assertTrue(handler.originalClaimer(id) != handler.originalClaimer(other));
            }
        }
        uint256 sum;
        for (uint256 i; i < 8; ++i) {
            address actor = handler.actors(i);
            assertEq(pass.balanceOf(actor), balances[i]);
            assertEq(house.isEligibleBroker(actor), balances[i] > 0, "broker right follows the pass");
            sum += balances[i];
        }
        assertEq(sum, pass.totalSupply());
        assertEq(pass.claimsOpenAt(), start, "start never changes");
        assertEq(pass.claimsOpen(), block.timestamp >= start);
    }
}
