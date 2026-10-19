// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./Fixture.sol";
import {ArtStorage} from "../src/ArtStorage.sol";
import {ArtHouse} from "../src/ArtHouse.sol";
import {ArtCollection} from "../src/ArtCollection.sol";
import {ArtifactsFactory} from "../src/ArtifactsFactory.sol";
import {ArtifactsPiece} from "../src/ArtifactsPiece.sol";
import {ArtifactsSource} from "../src/ArtifactsSource.sol";
import {ERC721Lite} from "../src/base/ERC721Lite.sol";
import {TwoStepOwnable} from "../src/base/TwoStepOwnable.sol";
import {SSTORE2} from "../src/libs/SSTORE2.sol";
import {Clones} from "../src/libs/Clones.sol";
import {Traits} from "../src/interfaces/Interfaces.sol";
import {Base64Decode} from "./utils/Base64Decode.sol";
import {Seal} from "../src/libs/Seal.sol";
import {
    FeeOnTransferToken,
    FalseReturningToken,
    DuplicateIdCoordinator,
    RevertingCoordinator,
    TogglingCoordinator,
    RejectingReceiver,
    ReenteringReceiver,
    StubController
} from "./mocks/AdversarialMocks.sol";

/// @dev Edge inputs for the ledger: zero, the maximum, the same call twice, the wrong caller, tokens that lie.
contract ArtHouseEdgeTest is Fixture {
    ArtCollection internal col;
    bytes internal svg = bytes('<svg xmlns="http://www.w3.org/2000/svg"><rect width="1" height="1"/></svg>');

    function setUp() public override {
        super.setUp();
        vm.prank(curator);
        col = ArtCollection(house.createCollection("Plain", "PLN", artist));
    }

    function _finalize(uint256 id) internal {
        vm.startPrank(artist);
        house.registerPiece(address(col), id, keccak256(svg), "Piece", "Desc");
        house.uploadChunk(address(col), id, 0, svg);
        house.finalizePiece(address(col), id);
        vm.stopPrank();
    }

    function _open(uint256 eth, uint256 imdPrice) internal {
        _finalize(0);
        _finalize(1);
        vm.startPrank(curator);
        house.sealCollection(address(col));
        house.setPrices(address(col), eth, imdPrice);
        house.setSaleOpen(address(col), true);
        vm.stopPrank();
    }

    // ---------- constructors ----------

    function test_constructorsRejectZeroDependencies() public {
        vm.expectRevert(TwoStepOwnable.ZeroAddress.selector);
        new ArtStorage(address(0));
        vm.expectRevert(TwoStepOwnable.ZeroAddress.selector);
        new ArtHouse(curator, address(0), address(imd));
        vm.expectRevert(TwoStepOwnable.ZeroAddress.selector);
        new ArtHouse(curator, address(store), address(0));
        vm.expectRevert(TwoStepOwnable.ZeroAddress.selector);
        new ArtifactsFactory(curator, address(0));
        vm.expectRevert(TwoStepOwnable.ZeroAddress.selector);
        new ArtifactsSource(curator, address(0));
    }

    /// @dev Constructors never call the addresses they are given, so they deploy on an empty chain.
    function test_constructorsDoNotCallDependencies() public {
        address noCode = address(0x1234);
        ArtHouse h = new ArtHouse(curator, noCode, address(0x5678));
        assertEq(address(h.artStorage()), noCode);
        assertTrue(h.collectionImplementation().code.length > 0);
        ArtifactsFactory f = new ArtifactsFactory(curator, noCode);
        assertEq(address(f.house()), noCode);
        assertEq(f.pieceImplementation(), address(0));
        ArtifactsSource s = new ArtifactsSource(curator, noCode);
        assertEq(s.pieceImplementation(), address(0));
    }

    function test_pendingOwnerHasNoPowerBeforeAccepting() public {
        vm.prank(curator);
        house.transferOwnership(bob);
        vm.prank(bob);
        vm.expectRevert(TwoStepOwnable.NotOwner.selector);
        house.setBroker(bob, true);
        // the curator keeps every power until acceptance, and may redirect the handover
        vm.prank(curator);
        house.transferOwnership(carol);
        vm.prank(bob);
        vm.expectRevert(TwoStepOwnable.NotPendingOwner.selector);
        house.acceptOwnership();
        vm.prank(carol);
        house.acceptOwnership();
        assertEq(house.owner(), carol);
        assertEq(house.pendingOwner(), address(0));
    }

    // ---------- artists / brokers ----------

    function test_artistEdges() public {
        vm.prank(curator);
        vm.expectRevert(TwoStepOwnable.ZeroAddress.selector);
        house.approveArtist(address(0), "zero");
        vm.prank(artist);
        vm.expectRevert(TwoStepOwnable.ZeroAddress.selector);
        house.setPayout(address(0));
        // revoking stops new collections but keeps the artist's balances, payout and royalties
        _open(1 ether, 0);
        vm.prank(alice);
        house.mint{value: 1 ether}(address(col), 0, address(0));
        vm.prank(curator);
        house.revokeArtist(artist);
        vm.prank(curator);
        vm.expectRevert(ArtHouse.NotApprovedArtist.selector);
        house.createCollection("X", "X", artist);
        vm.prank(curator);
        vm.expectRevert(ArtHouse.NotApprovedArtist.selector);
        house.registerModuleCollection(makeAddr("mod"), artist);
        assertEq(artist.balance, 0.75 ether, "paid straight to the artist at the sale");
        vm.prank(artist);
        house.setPayout(carol);
        (address to,) = col.royaltyInfo(0, 1 ether);
        assertEq(to, carol);
    }

    /// @dev A payout address that refuses ETH: the sale still goes through and the artist's share waits in the
    /// ledger; withdrawing to it fails and keeps it; pointed at a wallet, it pays.
    function test_withdrawToRevertingPayoutKeepsBalance() public {
        _open(1 ether, 0);
        address sink = address(new RejectingReceiver()); // no receive(): ETH transfer fails
        vm.prank(artist);
        house.setPayout(sink);
        vm.prank(alice);
        house.mint{value: 1 ether}(address(col), 0, address(0)); // the sale doesn't fail because of the artist
        assertEq(house.balances(artist, address(0)), 0.75 ether, "the share waits in the ledger");
        vm.prank(artist);
        vm.expectRevert(ArtHouse.TransferFailed.selector);
        house.withdraw(address(0));
        assertEq(_artistEth(), 0.75 ether, "balance intact after a failed payout");
        vm.prank(artist);
        house.setPayout(artist);
        vm.prank(artist);
        house.withdraw(address(0));
        assertEq(artist.balance, 0.75 ether);
    }

    function test_revokedBrokerKeepsEarnedBalance_butEarnsNoMore() public {
        _open(1 ether, 0);
        vm.prank(alice);
        house.mint{value: 1 ether}(address(col), 0, broker);
        vm.prank(curator);
        house.setBroker(broker, false);
        vm.prank(bob);
        house.mint{value: 1 ether}(address(col), 1, broker);
        assertEq(house.balances(broker, address(0)), 0.15 ether, "only the first sale paid the broker");
        assertEq(house.balances(address(house), address(0)), 0.05 ether + 0.05 ether, "the house's 5% of each");
        assertEq(house.balances(house.BUYBACK(), address(0)), 0.05 ether + 0.2 ether, "unearned share to the burn");
        vm.prank(broker);
        house.withdraw(address(0));
        assertEq(broker.balance, 0.15 ether);
    }

    function test_registerModuleCollectionTwiceReverts() public {
        vm.prank(curator);
        vm.expectRevert(ArtHouse.UnknownCollection.selector);
        house.registerModuleCollection(address(factory), artist);
    }

    // ---------- splits ----------

    function test_splitExtremes() public {
        vm.startPrank(curator);
        vm.expectRevert(ArtHouse.UnknownCollection.selector);
        house.setSplit(makeAddr("nope"), 0, 0, 10_000, 0);
        vm.expectRevert(ArtHouse.BadSplit.selector);
        house.setSplit(address(col), 10_000, 10_000, 10_000, 10_000); // sum overflows uint16 but not the check
        house.setSplit(address(col), 10_000, 0, 0, 0); // everything to the broker
        vm.stopPrank();
        _open(1 ether, 0);
        vm.prank(alice);
        house.mint{value: 1 ether}(address(col), 0, broker);
        assertEq(house.balances(broker, address(0)), 1 ether);
        assertEq(house.balances(artist, address(0)), 0);
        assertEq(house.balances(address(house), address(0)), 0);
        // the same split without an eligible broker: the unearned share buys back and burns IMD
        vm.prank(bob);
        house.mint{value: 1 ether}(address(col), 1, bob);
        assertEq(house.balances(address(house), address(0)), 0);
        assertEq(house.balances(artist, address(0)), 0);
        assertEq(house.balances(house.BUYBACK(), address(0)), 1 ether);
    }

    // ---------- the default split and the buyback ----------

    function test_defaultSplit_agentHouseBurn() public {
        (,,,,, uint16 bb, uint16 hb, uint16 ab,,,, uint16 ub) = house.collections(address(factory));
        assertEq(bb, 1500, "agent 15");
        assertEq(hb, 500, "house 5");
        assertEq(ab, 7500, "artist 75");
        assertEq(ub, 500, "burn 5");
        vm.deal(address(factory), 2 ether);
        vm.prank(address(factory));
        house.recordSale{value: 1 ether}(address(factory), alice, broker);
        assertEq(_artistEth(), 0.75 ether, "artist 75");
        assertEq(house.balances(broker, address(0)), 0.15 ether, "agent 15");
        assertEq(house.balances(address(house), address(0)), 0.05 ether, "house 5");
        assertEq(house.balances(house.BUYBACK(), address(0)), 0.05 ether, "burn 5");
        // no agent on the sale: their 15 is burned too
        vm.prank(address(factory));
        house.recordSale{value: 1 ether}(address(factory), alice, address(0));
        assertEq(_artistEth(), 1.5 ether);
        assertEq(house.balances(broker, address(0)), 0.15 ether);
        assertEq(house.balances(address(house), address(0)), 0.1 ether);
        assertEq(house.balances(house.BUYBACK(), address(0)), 0.25 ether, "5 + 20");
    }

    function test_buybackOnlyToTheBurnerSetOnce() public {
        vm.deal(address(factory), 1 ether);
        vm.prank(address(factory));
        house.recordSale{value: 1 ether}(address(factory), alice, address(0));
        vm.expectRevert(ArtHouse.NoBuybackBurner.selector);
        house.releaseBuyback(address(0));
        address burner = makeAddr("burner");
        vm.prank(alice);
        vm.expectRevert();
        house.setBuybackBurner(alice);
        vm.startPrank(curator);
        vm.expectRevert(TwoStepOwnable.ZeroAddress.selector);
        house.setBuybackBurner(address(0));
        house.setBuybackBurner(burner);
        vm.expectRevert(ArtHouse.BuybackBurnerAlreadySet.selector);
        house.setBuybackBurner(curator);
        vm.stopPrank();
        vm.prank(bob); // anyone may send it on, and it can only go to the burner
        house.releaseBuyback(address(0));
        assertEq(burner.balance, 0.2 ether);
        assertEq(house.balances(house.BUYBACK(), address(0)), 0);
        vm.expectRevert(ArtHouse.NothingToWithdraw.selector);
        house.releaseBuyback(address(0));
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_splitConservesAndHouseTakesRounding(
        uint16 brokerBps,
        uint16 houseBps,
        uint16 burnBps,
        uint96 amount,
        uint8 brokerKind
    ) public {
        brokerBps = uint16(bound(brokerBps, 0, 10_000));
        houseBps = uint16(bound(houseBps, 0, 10_000 - brokerBps));
        burnBps = uint16(bound(burnBps, 0, 10_000 - brokerBps - houseBps));
        uint16 artistBps = 10_000 - brokerBps - houseBps - burnBps;
        amount = uint96(bound(amount, 1, type(uint96).max));
        vm.prank(curator);
        house.setSplit(address(factory), brokerBps, houseBps, artistBps, burnBps);
        address b = brokerKind % 4 == 0 ? address(0) : brokerKind % 4 == 1 ? alice : brokerKind % 4 == 2 ? bob : broker;
        vm.deal(address(factory), amount);
        vm.prank(address(factory));
        house.recordSale{value: amount}(address(factory), alice, b);
        uint256 a = _artistEth();
        uint256 br = house.balances(broker, address(0));
        uint256 h = house.balances(address(house), address(0));
        uint256 bu = house.balances(house.BUYBACK(), address(0));
        assertEq(a + br + h + bu, amount, "conservation");
        uint256 unearned;
        if (b == broker) {
            assertEq(br, (uint256(amount) * brokerBps) / 10_000, "broker share floors");
        } else {
            assertEq(br, 0, "no commission for an unapproved broker");
            unearned = (uint256(amount) * brokerBps) / 10_000;
        }
        // the burn share, plus any unearned broker share
        assertEq(bu, (uint256(amount) * burnBps) / 10_000 + unearned, "burn share");
        if (houseBps == 0) {
            // no house share: the artist takes the rounding
            assertEq(h, 0, "no house share");
            assertEq(a, amount - br - bu, "artist takes the rest");
        } else {
            assertEq(a, (uint256(amount) * artistBps) / 10_000, "artist share floors");
            assertGe(h, (uint256(amount) * houseBps) / 10_000, "house takes the rounding");
        }
        // the house holds everything but what went straight to the artist
        assertEq(address(house).balance, amount - (a - house.balances(artist, address(0))));
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_everyoneWithdrawsExactlyTheirShare(uint96 p1, uint96 p2, uint96 imdPrice) public {
        p1 = uint96(bound(p1, 1, 100 ether));
        p2 = uint96(bound(p2, 1, 100 ether));
        imdPrice = uint96(bound(imdPrice, 1, type(uint96).max));
        _open(p1, imdPrice);
        vm.deal(alice, p1);
        vm.prank(alice);
        house.mint{value: p1}(address(col), 0, broker);
        imd.mint(bob, imdPrice);
        vm.prank(bob);
        imd.approve(address(house), imdPrice);
        vm.prank(bob);
        house.mintWithIMD(address(col), 1, address(0), imdPrice);
        vm.deal(address(factory), p2);
        vm.prank(address(factory));
        house.recordSale{value: p2}(address(factory), carol, broker);

        uint256 artistEth = _artistEth();
        uint256 brokerEth = house.balances(broker, address(0));
        uint256 houseEth = house.balances(address(house), address(0));
        uint256 artistImd = house.balances(artist, address(imd));
        uint256 houseImd = house.balances(address(house), address(imd));
        uint256 burnEth = house.balances(house.BUYBACK(), address(0));
        uint256 burnImd = house.balances(house.BUYBACK(), address(imd));
        assertEq(artistEth + brokerEth + houseEth + burnEth, uint256(p1) + p2);
        assertEq(artistImd + houseImd + burnImd, imdPrice);
        assertEq(house.balances(broker, address(imd)), 0);

        // a floored share of zero (tiny prices) has nothing to withdraw; everything else drains exactly
        _withdrawAll(artist, address(0), house.balances(artist, address(0))); // paid directly at the sale: nothing waits
        _withdrawAll(artist, address(imd), artistImd);
        _withdrawAll(broker, address(0), brokerEth);
        _withdrawAll(address(house), address(0), houseEth);
        _withdrawAll(address(house), address(imd), houseImd);
        assertEq(artist.balance, artistEth);
        assertEq(broker.balance, brokerEth);
        assertEq(curator.balance, houseEth);
        assertEq(imd.balanceOf(artist), artistImd);
        assertEq(imd.balanceOf(curator), houseImd);
        assertEq(address(house).balance, burnEth, "only the buyback balance is left, for the burner");
        assertEq(imd.balanceOf(address(house)), burnImd);
        // and a second withdrawal finds nothing
        vm.prank(artist);
        vm.expectRevert(ArtHouse.NothingToWithdraw.selector);
        house.withdraw(address(0));
        vm.prank(curator);
        vm.expectRevert(ArtHouse.NothingToWithdraw.selector);
        house.withdrawHouse(address(imd));
    }

    function _withdrawAll(address party, address currency, uint256 expected) internal {
        bool isHouse = party == address(house);
        address caller = isHouse ? curator : party;
        vm.prank(caller);
        if (expected == 0) vm.expectRevert(ArtHouse.NothingToWithdraw.selector);
        if (isHouse) house.withdrawHouse(currency);
        else house.withdraw(currency);
        assertEq(house.balances(party, currency), 0);
    }

    // ---------- curation ----------

    function test_moduleCollectionsHaveNoPlainCuration() public {
        vm.deal(curator, 1 ether);
        vm.deal(address(factory), 1 ether);
        vm.startPrank(curator);
        vm.expectRevert(ArtHouse.UnknownCollection.selector);
        house.setPrices(address(factory), 1, 1);
        vm.expectRevert(ArtHouse.UnknownCollection.selector);
        house.setSaleOpen(address(factory), true);
        vm.expectRevert(ArtHouse.UnknownCollection.selector);
        house.registerPiece(address(factory), 0, keccak256("x"), "t", "d");
        vm.expectRevert(ArtHouse.UnknownCollection.selector);
        house.uploadChunk(address(factory), 0, 0, "x");
        vm.expectRevert(ArtHouse.UnknownCollection.selector);
        house.finalizePiece(address(factory), 0);
        vm.expectRevert(ArtHouse.UnknownCollection.selector);
        house.sealCollection(address(factory));
        vm.expectRevert(ArtHouse.BadPieceId.selector);
        house.clearPiece(address(factory), 0);
        vm.expectRevert(ArtHouse.UnknownCollection.selector);
        house.mint{value: 1 ether}(address(factory), 0, address(0));
        vm.stopPrank();
        vm.prank(address(factory));
        vm.expectRevert(ArtHouse.NotModuleCollection.selector);
        house.recordSale{value: 1 ether}(address(col), alice, address(0));
        vm.prank(address(factory));
        vm.expectRevert(ArtHouse.WrongPrice.selector);
        house.recordSale{value: 0}(address(factory), alice, address(0));
    }

    function test_curationEdges() public {
        vm.startPrank(artist);
        vm.expectRevert(ArtHouse.BadPieceId.selector);
        house.uploadChunk(address(col), 0, 0, svg); // not registered
        vm.expectRevert(ArtHouse.BadPieceId.selector);
        house.finalizePiece(address(col), 0);
        house.registerPiece(address(col), 0, keccak256(svg), "P", "D");
        vm.expectRevert(ArtHouse.HashMismatch.selector);
        house.finalizePiece(address(col), 0); // size zero
        vm.expectRevert(SSTORE2.TooLarge.selector);
        house.uploadChunk(address(col), 0, 0, new bytes(24_576)); // one chunk over the SSTORE2 limit
        house.uploadChunk(address(col), 0, 0, svg);
        house.finalizePiece(address(col), 0);
        vm.expectRevert(ArtHouse.Finalized.selector);
        house.finalizePiece(address(col), 0);
        vm.stopPrank();
        vm.prank(curator);
        vm.expectRevert(ArtHouse.UnknownCollection.selector);
        house.sealCollection(makeAddr("other")); // unknown collection
        vm.prank(curator);
        house.sealCollection(address(col));
    }

    /// @dev updatePiece: nothing to update in an empty collection; another approved artist, a pending owner and a
    /// revoked artist are all refused; the curator or the collection's artist may fix hash, title and description
    /// and the emitted event carries the new values.
    function test_updatePieceAccessEdges() public {
        vm.prank(curator);
        vm.expectRevert(ArtHouse.BadPieceId.selector);
        house.updatePiece(address(col), 0, keccak256(svg), "P", "D");
        address other = makeAddr("other");
        vm.prank(curator);
        house.approveArtist(other, "Other");
        vm.prank(curator);
        ArtCollection col2 = ArtCollection(house.createCollection("Other", "OTH", other));
        vm.prank(artist);
        house.registerPiece(address(col), 0, keccak256("typo"), "P", "D");
        // an approved artist of a different collection is a stranger here
        vm.prank(other);
        vm.expectRevert(ArtHouse.NotCurator.selector);
        house.updatePiece(address(col), 0, keccak256(svg), "P", "D");
        vm.prank(artist);
        vm.expectRevert(ArtHouse.NotCurator.selector);
        house.updatePiece(address(col2), 0, keccak256(svg), "P", "D");
        // a pending owner has no power until accepting
        vm.prank(curator);
        house.transferOwnership(carol);
        vm.prank(carol);
        vm.expectRevert(ArtHouse.NotCurator.selector);
        house.updatePiece(address(col), 0, keccak256(svg), "P", "D");
        vm.expectEmit(true, true, false, true, address(house));
        emit ArtHouse.PieceUpdated(address(col), 0, keccak256(svg), "Fixed");
        vm.prank(artist);
        house.updatePiece(address(col), 0, keccak256(svg), "Fixed", "New desc");
        (bytes32 hash, string memory title, string memory description, bool finalized,, uint256 size) =
            house.pieces(address(col), 0);
        assertEq(hash, keccak256(svg));
        assertEq(title, "Fixed");
        assertEq(description, "New desc");
        assertFalse(finalized);
        assertEq(size, 0);
        // once revoked the artist cannot touch it, even to restore the old values; the curator still can
        vm.prank(curator);
        house.revokeArtist(artist);
        vm.prank(artist);
        vm.expectRevert(ArtHouse.NotCurator.selector);
        house.updatePiece(address(col), 0, keccak256("typo"), "P", "D");
        vm.prank(curator);
        house.uploadChunk(address(col), 0, 0, svg);
        vm.prank(curator);
        house.finalizePiece(address(col), 0);
        (,,, finalized,, size) = house.pieces(address(col), 0);
        assertTrue(finalized);
        assertEq(size, svg.length);
    }

    function test_sealEmptyCollectionRevertsAndSealIsOnce() public {
        vm.prank(curator);
        vm.expectRevert(ArtHouse.NotFinalized.selector);
        house.sealCollection(address(col));
        _finalize(0);
        vm.prank(curator);
        house.sealCollection(address(col));
        vm.prank(curator);
        vm.expectRevert(ArtHouse.Sealed.selector);
        house.sealCollection(address(col));
        vm.prank(artist);
        vm.expectRevert(ArtHouse.Sealed.selector);
        house.registerPiece(address(col), 1, keccak256(svg), "P", "D");
        // supply = registered pieces: only token 0 can ever exist
        vm.startPrank(curator);
        house.setPrices(address(col), 1 ether, 0);
        house.setSaleOpen(address(col), true);
        vm.stopPrank();
        vm.prank(alice);
        vm.expectRevert(ArtHouse.BadPieceId.selector);
        house.mint{value: 1 ether}(address(col), 1, address(0));
    }

    function test_clearThenReuploadKeepsSizeAccounting() public {
        vm.startPrank(artist);
        house.registerPiece(address(col), 0, keccak256(svg), "P", "D");
        house.uploadChunk(address(col), 0, 0, new bytes(24_000));
        house.uploadChunk(address(col), 0, 1, new bytes(24_000));
        house.uploadChunk(address(col), 0, 2, new bytes(24_000));
        house.uploadChunk(address(col), 0, 3, new bytes(24_000));
        vm.stopPrank();
        vm.prank(curator);
        house.clearPiece(address(col), 0);
        (,,,,, uint256 size) = house.pieces(address(col), 0);
        assertEq(size, 0);
        vm.startPrank(artist);
        for (uint256 i; i < 4; ++i) {
            house.uploadChunk(address(col), 0, i, new bytes(24_000));
        }
        vm.expectRevert(ArtHouse.TooLarge.selector);
        house.uploadChunk(address(col), 0, 4, new bytes(4_001));
        vm.stopPrank();
    }

    // ---------- minting ----------

    function test_mintZeroPricesReject() public {
        _open(0, 0);
        vm.prank(alice);
        vm.expectRevert(ArtHouse.WrongPrice.selector);
        house.mint{value: 0}(address(col), 0, address(0));
        vm.prank(alice);
        vm.expectRevert(ArtHouse.WrongPrice.selector);
        house.mintWithIMD(address(col), 0, address(0), 0);
    }

    function test_mintWithIMD_stalePriceRejected() public {
        _open(0, 100e18);
        imd.mint(alice, 200e18);
        vm.prank(alice);
        imd.approve(address(house), 200e18);
        vm.prank(curator);
        house.setPrices(address(col), 0, 150e18);
        vm.prank(alice);
        vm.expectRevert(ArtHouse.WrongPrice.selector);
        house.mintWithIMD(address(col), 0, address(0), 100e18);
        vm.prank(alice);
        house.mintWithIMD(address(col), 0, address(0), 150e18);
        assertEq(imd.balanceOf(alice), 50e18, "pulled exactly the current price");
    }

    function _houseWith(address token) internal returns (ArtHouse h, ArtCollection c) {
        ArtStorage s = new ArtStorage(curator);
        h = new ArtHouse(curator, address(s), token);
        vm.startPrank(curator);
        s.setHouse(address(h));
        h.approveArtist(artist, "A");
        c = ArtCollection(h.createCollection("C", "C", artist));
        h.registerPiece(address(c), 0, keccak256(svg), "P", "D");
        h.uploadChunk(address(c), 0, 0, svg);
        h.finalizePiece(address(c), 0);
        h.sealCollection(address(c));
        h.setPrices(address(c), 0, 100e18);
        h.setSaleOpen(address(c), true);
        vm.stopPrank();
    }

    function test_mintWithIMD_feeOnTransferRejected() public {
        FeeOnTransferToken fot = new FeeOnTransferToken();
        (ArtHouse h, ArtCollection c) = _houseWith(address(fot));
        fot.mint(alice, 100e18);
        vm.prank(alice);
        fot.approve(address(h), 100e18);
        vm.prank(alice);
        vm.expectRevert(ArtHouse.TransferFailed.selector);
        h.mintWithIMD(address(c), 0, address(0), 100e18);
        assertEq(h.balances(artist, address(fot)), 0, "no credit survives a failed pull");
        (bool ok,) = address(c).staticcall(abi.encodeWithSignature("ownerOf(uint256)", 0));
        assertFalse(ok, "nothing minted");
    }

    function test_mintWithIMD_falseReturnRejected() public {
        FalseReturningToken bad = new FalseReturningToken();
        (ArtHouse h, ArtCollection c) = _houseWith(address(bad));
        vm.prank(alice);
        vm.expectRevert(ArtHouse.TransferFailed.selector);
        h.mintWithIMD(address(c), 0, address(0), 100e18);
    }

    function test_submissionEdges() public {
        vm.prank(alice);
        vm.expectRevert(ArtHouse.BadSubmission.selector);
        house.submit(bytes32(0), "x");
        vm.prank(curator);
        vm.expectRevert(ArtHouse.BadSubmission.selector);
        house.decideSubmission(0, true);
        vm.prank(alice);
        uint256 id = house.submit(keccak256("w"), "");
        assertEq(id, 0);
        assertEq(house.submissionCount(), 1);
        vm.prank(curator);
        house.decideSubmission(id, false);
        (address submitter,,, ArtHouse.SubmissionStatus status) = house.submissions(id);
        assertEq(submitter, alice);
        assertEq(uint8(status), uint8(ArtHouse.SubmissionStatus.Rejected));
    }

    function test_collectionErc721Edges() public {
        _open(1 ether, 0);
        vm.prank(alice);
        house.mint{value: 1 ether}(address(col), 0, address(0));
        vm.expectRevert(ERC721Lite.InvalidReceiver.selector);
        col.balanceOf(address(0));
        vm.prank(bob);
        vm.expectRevert(ERC721Lite.NotAuthorized.selector);
        col.transferFrom(alice, bob, 0);
        vm.prank(alice);
        vm.expectRevert(ERC721Lite.NotAuthorized.selector);
        col.transferFrom(bob, carol, 0); // from is not the owner
        vm.prank(alice);
        vm.expectRevert(ERC721Lite.InvalidReceiver.selector);
        col.transferFrom(alice, address(0), 0);
        RejectingReceiver rr = new RejectingReceiver();
        vm.prank(alice);
        vm.expectRevert(ERC721Lite.InvalidReceiver.selector);
        col.safeTransferFrom(alice, address(rr), 0);
        vm.prank(alice);
        col.setApprovalForAll(bob, true);
        vm.prank(bob);
        col.safeTransferFrom(alice, carol, 0);
        assertEq(col.ownerOf(0), carol);
        assertTrue(col.supportsInterface(0x80ac58cd) && col.supportsInterface(0x5b5e139f));
        assertFalse(col.supportsInterface(0xffffffff));
    }
}

/// @dev Edge inputs for the ARTIFACTS sale, VRF and claim.
contract ArtifactsEdgeTest is Fixture {
    function test_setPieceEdges() public {
        vm.startPrank(curator);
        vm.expectRevert(ArtifactsFactory.BadPieceId.selector);
        factory.setPiece(1, _traits(1), "", keccak256("k"));
        vm.expectRevert(ArtifactsFactory.BadPieceId.selector);
        factory.setPiece(1, _traits(1), "c", bytes32(0));
        factory.setPiece(1, _traits(1), "c1", keccak256("k1"));
        factory.setPiece(1, _traits(1), "c2", keccak256("k2")); // re-set before lock replaces, counts once
        vm.stopPrank();
        assertEq(factory.piecesSet(), 1);
        assertEq(factory.ciphertextOf(1), "c2");
        assertEq(factory.commitmentOf(1), keccak256("k2"));
        assertTrue(factory.isSet(1));
        assertFalse(factory.isSet(2));
        assertEq(factory.ciphertextOf(2), "");
        _publishAll();
        vm.prank(curator);
        vm.expectRevert(ArtifactsFactory.IsLocked.selector);
        factory.lock();
    }

    function test_configureVRFRejectsZeroes() public {
        ArtifactsFactory fresh = new ArtifactsFactory(curator, address(house));
        vm.startPrank(curator);
        fresh.setPieceImplementation(address(pieceImpl));
        vm.expectRevert(ArtifactsFactory.VRFNotConfigured.selector);
        fresh.configureVRF(address(vrf), bytes32(0), SUB_ID, false);
        vm.expectRevert(ArtifactsFactory.VRFNotConfigured.selector);
        fresh.configureVRF(address(vrf), KEY_HASH, 0, false);
        vm.stopPrank();
        vm.prank(alice);
        vm.expectRevert(TwoStepOwnable.NotOwner.selector);
        fresh.configureVRF(address(vrf), KEY_HASH, SUB_ID, false);
        vm.prank(curator);
        fresh.configureVRF(address(vrf), KEY_HASH, SUB_ID, true);
        assertTrue(fresh.vrfNativePayment());
    }

    function test_nonOwnerCannotRunTheSale() public {
        _publishAll();
        vm.startPrank(alice);
        vm.expectRevert(TwoStepOwnable.NotOwner.selector);
        factory.setPrice(1);
        vm.expectRevert(TwoStepOwnable.NotOwner.selector);
        factory.setSaleOpen(true);
        vm.expectRevert(TwoStepOwnable.NotOwner.selector);
        factory.lock();
        vm.expectRevert(TwoStepOwnable.NotOwner.selector);
        factory.postWrappedKey(1, "k");
        vm.stopPrank();
    }

    /// @dev A VRF request that reverts (unfunded subscription) reverts the whole purchase: nothing is recorded.
    function test_buyRevertsAtomicallyWhenCoordinatorReverts() public {
        ArtifactsFactory f = new ArtifactsFactory(curator, address(house));
        vm.startPrank(curator);
        f.setPieceImplementation(address(pieceImpl));
        house.setSaleModule(address(f), true);
        house.registerModuleCollection(address(f), artist);
        f.configureVRF(address(new RevertingCoordinator()), KEY_HASH, SUB_ID, false);
        for (uint256 i = 1; i <= 255; ++i) {
            f.setPiece(i, _traits(i), "c", keccak256(abi.encode(i)));
        }
        f.lock();
        f.setPrice(1 ether);
        f.setSaleOpen(true);
        vm.stopPrank();
        vm.prank(alice);
        vm.expectRevert("InsufficientBalance");
        f.buy{value: 1 ether}(address(0));
        assertEq(f.sold(), 0);
        assertEq(address(house).balance, 0);
        assertEq(alice.balance, 1000 ether);
    }

    /// @dev A coordinator returning a request id already in use cannot overwrite the earlier buyer.
    function test_duplicateRequestIdRejected() public {
        ArtifactsFactory f = new ArtifactsFactory(curator, address(house));
        vm.startPrank(curator);
        f.setPieceImplementation(address(pieceImpl));
        house.setSaleModule(address(f), true);
        house.registerModuleCollection(address(f), artist);
        f.configureVRF(address(new DuplicateIdCoordinator()), KEY_HASH, SUB_ID, false);
        for (uint256 i = 1; i <= 255; ++i) {
            f.setPiece(i, _traits(i), "c", keccak256(abi.encode(i)));
        }
        f.lock();
        f.setPrice(1 ether);
        f.setSaleOpen(true);
        vm.stopPrank();
        vm.prank(alice);
        assertEq(f.buy{value: 1 ether}(address(0)), 42);
        vm.prank(bob);
        vm.expectRevert(ArtifactsFactory.AlreadyFulfilled.selector);
        f.buy{value: 1 ether}(address(0));
        assertEq(f.requestBuyer(42), alice);
        assertEq(f.sold(), 1);
    }

    function test_unapprovedBuyerAsBrokerEarnsNothing_andOneWeiPriceWorks() public {
        _publishAll();
        _openSale(1);
        vm.prank(alice);
        uint256 id = factory.buy{value: 1}(alice);
        vrf.fulfill(id, 0);
        assertEq(factory.requestEdition(id), 1, "word 0 picks edition 1");
        assertEq(house.balances(address(house), address(0)), 1, "1 wei: artist floor is 0, house takes it all");
        assertEq(house.balances(artist, address(0)), 0);
        assertEq(house.balances(alice, address(0)), 0);
    }

    function test_callbackWithNoWordsReverts() public {
        _publishAll();
        _openSale(1 ether);
        vm.prank(alice);
        uint256 id = factory.buy{value: 1 ether}(address(0));
        vm.prank(address(vrf));
        vm.expectRevert();
        factory.rawFulfillRandomWords(id, new uint256[](0));
        assertEq(factory.requestEdition(id), 0, "still pending; a correct callback can follow");
        vrf.fulfill(id, type(uint256).max);
        assertEq(factory.requestEdition(id), (type(uint256).max % 255) + 1);
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_anyWordsAssignDistinctEditions(uint256[8] memory words) public {
        _publishAll();
        _openSale(1 ether);
        bool[256] memory seen;
        for (uint256 i; i < 8; ++i) {
            uint256 e = _buyAndAssign(i % 2 == 0 ? alice : bob, address(0), words[i]);
            assertTrue(e >= 1 && e <= 255);
            assertFalse(seen[e], "duplicate edition");
            seen[e] = true;
        }
        assertEq(factory.assigned(), 8);
        assertEq(factory.sold(), 8);
        assertEq(factory.remaining(), 247);
    }

    /// @dev The retry window is exact: one block short is too recent, the boundary block is allowed; a re-request
    /// can itself be re-requested after another full window; the forgotten ids never fulfil; sold, the ledger
    /// and the buyer's edition count are unchanged by any number of re-requests.
    function test_rerequestWindowBoundaryAndChaining() public {
        _publishAll();
        _openSale(1 ether);
        uint256 start = vm.getBlockNumber();
        vm.prank(alice);
        uint256 id0 = factory.buy{value: 1 ether}(address(0));
        assertEq(factory.requestBlock(id0), start);
        uint256 window = factory.VRF_RETRY_BLOCKS();

        vm.roll(start + window - 1);
        vm.prank(curator);
        vm.expectRevert(ArtifactsFactory.RequestTooRecent.selector);
        factory.rerequestRandomness(id0);
        // the sale being closed does not block a paid purchase's re-request
        vm.prank(curator);
        factory.setSaleOpen(false);
        vm.roll(start + window);
        vm.prank(curator);
        uint256 id1 = factory.rerequestRandomness(id0);
        assertEq(factory.requestBlock(id1), start + window);
        assertEq(factory.requestBlock(id0), 0, "old request forgotten");
        assertEq(factory.requestBuyer(id0), address(0));
        // the same old id cannot be re-requested twice
        vm.prank(curator);
        vm.expectRevert(ArtifactsFactory.UnknownRequest.selector);
        factory.rerequestRandomness(id0);
        // chain: the new request needs its own full window
        vm.roll(start + 2 * window - 1);
        vm.prank(curator);
        vm.expectRevert(ArtifactsFactory.RequestTooRecent.selector);
        factory.rerequestRandomness(id1);
        vm.roll(start + 2 * window);
        vm.prank(curator);
        uint256 id2 = factory.rerequestRandomness(id1);
        assertTrue(id2 != id1 && id2 != id0);
        assertEq(factory.requestBuyer(id2), alice);
        // every forgotten id is dead, whatever word the coordinator sends
        vm.expectRevert(ArtifactsFactory.UnknownRequest.selector);
        vrf.fulfill(id0, 1);
        vm.expectRevert(ArtifactsFactory.UnknownRequest.selector);
        vrf.fulfill(id1, 1);
        assertEq(factory.sold(), 1, "re-requests are not purchases");
        assertEq(factory.assigned(), 0);
        assertEq(factory.remaining(), 254);
        assertEq(address(house).balance + artist.balance, 1 ether, "no second payment");
        vrf.fulfill(id2, 77);
        uint256 e = factory.requestEdition(id2);
        assertEq(e, 77 % 255 + 1);
        assertEq(factory.editionBuyer(e), alice);
        assertEq(factory.editionsOf(alice).length, 1, "exactly one edition for one purchase");
        assertEq(factory.assigned(), 1);
        // the edition is claimable as any other
        ArtifactsPiece p = _claim(alice, e);
        assertEq(p.ownerOf(1), alice);
        assertEq(p.pieceId(), e);
    }

    /// @dev A re-request whose coordinator call reverts leaves the original request intact and retryable.
    function test_rerequestIsAtomicWhenCoordinatorReverts() public {
        TogglingCoordinator coord = new TogglingCoordinator();
        ArtifactsFactory f = new ArtifactsFactory(curator, address(house));
        vm.startPrank(curator);
        f.setPieceImplementation(address(pieceImpl));
        house.setSaleModule(address(f), true);
        house.registerModuleCollection(address(f), artist);
        f.configureVRF(address(coord), KEY_HASH, SUB_ID, false);
        for (uint256 i = 1; i <= 255; ++i) {
            f.setPiece(i, _traits(i), "c", keccak256(abi.encode(i)));
        }
        f.lock();
        f.setPrice(1 ether);
        f.setSaleOpen(true);
        vm.stopPrank();
        vm.prank(bob);
        uint256 id = f.buy{value: 1 ether}(broker);
        uint256 at = vm.getBlockNumber();
        coord.setFailing(true);
        vm.roll(at + f.VRF_RETRY_BLOCKS());
        vm.prank(curator);
        vm.expectRevert("InsufficientBalance");
        f.rerequestRandomness(id);
        assertEq(f.requestBuyer(id), bob, "original request kept");
        assertEq(f.requestBlock(id), at);
        // once the subscription is funded again the same request can be retried, and the late original answer
        // is still accepted if it arrives before the retry
        coord.setFailing(false);
        coord.fulfill(id, 3);
        assertEq(f.requestEdition(id), 4);
        vm.prank(curator);
        vm.expectRevert(ArtifactsFactory.AlreadyFulfilled.selector);
        f.rerequestRandomness(id);
        assertEq(f.editionsOf(bob).length, 1);
    }

    function test_wrappedKeyEdges() public {
        _publishAll();
        _openSale(1 ether);
        uint256 e = _buyAndAssign(alice, address(0), 7);
        vm.prank(curator);
        vm.expectRevert(ArtifactsFactory.NotAssigned.selector);
        factory.postWrappedKey(e == 1 ? 2 : 1, "k");
        vm.prank(alice);
        factory.registerViewingKey(keccak256("a"));
        vm.prank(curator);
        vm.expectRevert(ArtifactsFactory.KeyNotPosted.selector);
        factory.postWrappedKey(e, "");
        vm.prank(curator);
        factory.postWrappedKey(e, "first");
        vm.prank(curator);
        factory.postWrappedKey(e, "second"); // re-post before claim replaces
        assertEq(factory.wrappedKeyOf(e), "second");
        // the curator may claim on the buyer's behalf; the token still goes to the buyer
        vm.prank(curator);
        ArtifactsPiece piece = ArtifactsPiece(factory.claim(e));
        assertEq(piece.ownerOf(1), alice);
        assertEq(piece.wrappedKey(), "second");
        // after the claim a key goes into the piece, only into an empty slot: this one holds its key
        vm.prank(curator);
        vm.expectRevert(ArtifactsPiece.KeyAlreadyPosted.selector);
        factory.postWrappedKey(e, "third");
        assertEq(piece.wrappedKey(), "second");
        vm.prank(curator);
        vm.expectRevert(ArtifactsFactory.AlreadyClaimed.selector);
        factory.claim(e);
    }

    /// @dev Launch policy forbids the former EIP-1167 proxy; each edition must contain the full runtime.
    function test_claimedPieceIsAFullCopyOfTheImplementation() public {
        _publishAll();
        _openSale(1 ether);
        uint256 e = _buyAndAssign(alice, address(0), 3);
        ArtifactsPiece piece = _claim(alice, e);
        assertEq(address(piece).code, address(pieceImpl).code, "independent ArtifactsPiece runtime");
        assertEq(pieceImpl.controller(), address(pieceImpl), "implementation locked to itself");
        assertEq(piece.controller(), address(factory));
        assertEq(address(piece.house()), address(house));
        assertTrue(piece.supportsInterface(0x01ffc9a7));
        assertTrue(piece.supportsInterface(0x80ac58cd));
        assertTrue(piece.supportsInterface(0x5b5e139f));
        assertTrue(piece.supportsInterface(0x2a55205a));
        assertFalse(piece.supportsInterface(0xffffffff));
        vm.expectRevert(ERC721Lite.NonexistentToken.selector);
        piece.tokenURI(2);
    }

    /// @dev The seal for any traits is the R8 frame of the reference with the labels swapped and no dots.
    /// forge-config: default.fuzz.runs = 16
    function testFuzz_sealFramesAnyTraits(uint8 t, uint8 p, uint8 k, uint8 d, uint8 word) public {
        Traits memory tr = Traits({
            title: _pick(t % 10, "SPECTRUM,CHROMA,BLOOM,STIPPLE,DRIFT,HALFTONE,PRISM,RADIATE,FIELD,FLUX"),
            palette: _pick(p % 6, "SUNSET,AURORA,VOID,ICE,MAGMA,PRISM"),
            colourCount: uint8(bound(k, 2, 9)),
            direction: _pick(d % 8, "VERTICAL,HORIZONTAL,DIAGONAL,RADIAL,ANTIDIAG,CONIC,DIAMOND,SPIRAL")
        });
        vm.startPrank(curator);
        for (uint256 i = 1; i <= 255; ++i) {
            factory.setPiece(i, tr, "c", keccak256(abi.encode(i)));
        }
        factory.lock();
        vm.stopPrank();
        _openSale(1 ether);
        uint256 e = _buyAndAssign(alice, address(0), word);
        ArtifactsPiece piece = _claim(alice, e);
        bytes memory b = bytes(piece.tokenURI(1));
        bytes memory json = Base64Decode.decode(Base64Decode.slice(b, 29, b.length));
        uint256 at = Base64Decode.indexOf(json, bytes("data:image/svg+xml;base64,"), 0) + 26;
        bytes memory svg =
            Base64Decode.decode(Base64Decode.slice(json, at, Base64Decode.indexOf(json, bytes('"}'), at)));

        // template: framed-003 with dots removed, DRIFT / PRISM  ·  3C  ·  HORIZONTAL / SEED 003 swapped for these
        // traits and the edition's number (No. nnn), then marked SEALED
        bytes memory framed = bytes(vm.readFile("reference/framed/framed-003.svg"));
        uint256 frameAt = Base64Decode.indexOf(framed, bytes('<g fill="#1a1a1a"'), 0);
        uint256 dotsAt = Base64Decode.indexOf(framed, bytes("<circle"), 0);
        bytes memory frame = Base64Decode.slice(framed, frameAt, framed.length);
        uint256 a1 = Base64Decode.indexOf(frame, bytes(">DRIFT<"), 0) + 1;
        uint256 a2 = Base64Decode.indexOf(frame, bytes(unicode">PRISM  ·  3C  ·  HORIZONTAL<"), 0) + 1;
        uint256 a3 = Base64Decode.indexOf(frame, bytes(">SEED 003<"), 0) + 1;
        bytes memory unmarked = bytes.concat(
            Base64Decode.slice(framed, 0, dotsAt),
            Base64Decode.slice(frame, 0, a1),
            bytes(tr.title),
            Base64Decode.slice(frame, a1 + 5, a2),
            bytes(tr.palette),
            unicode"  ·  ",
            bytes(vm.toString(uint256(tr.colourCount))),
            unicode"C  ·  ",
            bytes(tr.direction),
            Base64Decode.slice(frame, a2 + bytes(unicode"PRISM  ·  3C  ·  HORIZONTAL").length, a3),
            bytes("No. "),
            bytes(e < 10 ? "00" : e < 100 ? "0" : ""),
            bytes(vm.toString(e)),
            Base64Decode.slice(frame, a3 + 8, frame.length)
        );
        assertEq(svg, Base64Decode.withMark(unmarked, Seal.SEALED_MARK), "seal is not the R8 frame for these traits");
        // attributes carry the same public traits (indexOf reverts when absent)
        Base64Decode.indexOf(json, bytes(string.concat('{"trait_type":"Title","value":"', tr.title, '"}')), 0);
        Base64Decode.indexOf(
            json, bytes(string.concat('{"trait_type":"Colours","value":', vm.toString(uint256(tr.colourCount)), "}")), 0
        );
        Base64Decode.indexOf(json, bytes(string.concat('{"trait_type":"Direction","value":"', tr.direction, '"}')), 0);
    }

    /// @dev The n-th comma-separated word of `csv`.
    function _pick(uint256 n, string memory csv) internal pure returns (string memory) {
        bytes memory b = bytes(csv);
        uint256 start;
        uint256 idx;
        for (uint256 i; i <= b.length; ++i) {
            if (i == b.length || b[i] == ",") {
                if (idx == n) return string(Base64Decode.slice(b, start, i));
                idx++;
                start = i + 1;
            }
        }
        revert("pick");
    }
}

/// @dev Edge inputs for the piece escrow, transfers and THE SOURCE paths.
contract PieceEdgeTest is Fixture {
    ArtifactsPiece internal piece;

    function setUp() public override {
        super.setUp();
        _publishAll();
        _openSale(1 ether);
        piece = _claim(alice, _buyAndAssign(alice, address(0), 10));
    }

    function test_listingEdges() public {
        vm.prank(alice);
        vm.expectRevert(ArtifactsPiece.WrongPrice.selector);
        piece.list(0);
        vm.prank(alice);
        piece.list(1 ether);
        vm.prank(alice);
        vm.expectRevert(ArtifactsPiece.AlreadyListed.selector);
        piece.list(2 ether);
        vm.prank(bob);
        vm.expectRevert(ArtifactsPiece.NotSeller.selector);
        piece.delist();
        vm.prank(alice);
        vm.expectRevert(ArtifactsPiece.NotEscrowBuyer.selector);
        piece.buy{value: 1 ether}(_vk("self"), address(0)); // seller cannot buy from themself
        vm.prank(bob);
        vm.expectRevert(ArtifactsPiece.NoViewingKey.selector);
        piece.buy{value: 1 ether}(bytes32(0), address(0));
        _postKeyReverts(piece, alice, (1 ether) / 10, ArtifactsPiece.NoEscrowBuyer.selector);
        vm.prank(alice);
        vm.expectRevert(ArtifactsPiece.NoEscrowBuyer.selector);
        piece.release();
        vm.prank(bob);
        piece.buy{value: 1 ether}(_vk("bob"), address(0));
        vm.prank(carol);
        vm.expectRevert(ArtifactsPiece.EscrowActive.selector);
        piece.buy{value: 1 ether}(_vk("carol"), address(0));
        _postKey(piece, alice, (1 ether) / 10);
        _postKeyReverts(piece, alice, (1 ether) / 10, ArtifactsPiece.KeyAlreadyPosted.selector);
        // an approved operator cannot move the token out of escrow either
        vm.prank(alice);
        piece.approve(carol, 1);
        vm.prank(carol);
        vm.expectRevert(ArtifactsPiece.EscrowActive.selector);
        piece.transferFrom(alice, carol, 1);
        vm.prank(alice);
        vm.expectRevert(ArtifactsPiece.EscrowActive.selector);
        piece.safeTransferFrom(alice, carol, 1);
    }

    function test_releaseAtExactly72HoursByStranger() public {
        vm.prank(alice);
        piece.list(1 ether);
        vm.prank(bob);
        piece.buy{value: 1 ether}(_vk("bob"), address(0));
        _postKey(piece, alice, (1 ether) / 10);
        uint256 paidAt = vm.getBlockTimestamp();
        vm.warp(paidAt + 72 hours);
        vm.prank(carol);
        piece.release();
        assertEq(piece.ownerOf(1), bob);
        // the old seller cannot list what it no longer owns; the new owner can
        vm.prank(alice);
        vm.expectRevert(ArtifactsPiece.NotTokenOwner.selector);
        piece.list(1 ether);
        vm.prank(bob);
        piece.list(3 ether);
        vm.prank(alice);
        vm.expectRevert(ArtifactsPiece.NotSeller.selector);
        piece.delist();
        // the escrowed key is delivered and stands: the paid seller keeps no re-key right, so the key bob paid
        // for can never be overwritten (not even with an empty one)
        assertEq(piece.wrappedKey(), _wrappedOf("key"));
        assertEq(piece.previousOwner(), address(0));
        vm.prank(alice);
        vm.expectRevert(ArtifactsPiece.NotPreviousOwner.selector);
        piece.rewrapFor("again");
        vm.prank(alice);
        vm.expectRevert(ArtifactsPiece.NotPreviousOwner.selector);
        piece.rewrapFor("");
        assertEq(piece.wrappedKey(), _wrappedOf("key"));
    }

    function test_cancelThenSecondBuyerAndRoyaltyToChangedPayout() public {
        vm.prank(alice);
        piece.list(2 ether);
        vm.prank(bob);
        piece.buy{value: 2 ether}(_vk("bob"), address(0));
        vm.warp(vm.getBlockTimestamp() + 24 hours); // the seller's window
        vm.prank(bob);
        piece.cancel();
        vm.prank(bob);
        vm.expectRevert(ArtifactsPiece.NotEscrowBuyer.selector);
        piece.cancel(); // twice
        vm.prank(carol);
        piece.buy{value: 2 ether}(_vk("carol"), address(0));
        vm.prank(artist);
        house.setPayout(makeAddr("payout"));
        _postKey(piece, alice, (2 ether) / 10);
        uint256 payoutBefore = makeAddr("payout").balance;
        vm.prank(carol);
        piece.release();
        // the royalty goes straight to the payout address the artist chose
        assertEq(makeAddr("payout").balance - payoutBefore, 0.15 ether, "royalty follows the artist's payout");
        assertEq(house.balances(artist, address(0)), 0, "nothing waits in the ledger");
        assertEq(piece.pendingWithdrawals(alice), 1.85 ether + 0.2 ether, "proceeds and the deposit back");
        assertEq(piece.pendingWithdrawals(bob), 2 ether);
        assertEq(address(piece).balance, 4.05 ether);
        vm.prank(bob);
        piece.withdraw();
        vm.prank(bob);
        vm.expectRevert(ArtifactsPiece.NothingToWithdraw.selector);
        piece.withdraw();
    }

    function test_safeTransferReceivers() public {
        RejectingReceiver rr = new RejectingReceiver();
        vm.prank(alice);
        vm.expectRevert(ERC721Lite.InvalidReceiver.selector);
        piece.safeTransferFrom(alice, address(rr), 1);
        ReenteringReceiver re = new ReenteringReceiver(piece);
        vm.prank(alice);
        piece.safeTransferFrom(alice, address(re), 1, "");
        assertEq(piece.ownerOf(1), address(re));
        assertTrue(re.listedDuringHook(), "the new owner may act in its receiver hook");
        (, address seller,,,,,,,,) = piece.escrow();
        assertEq(seller, address(re));
        assertEq(piece.previousOwner(), alice);
        assertEq(piece.wrappedKey(), "");
    }

    function test_transferAuthEdges() public {
        vm.prank(bob);
        vm.expectRevert(ERC721Lite.NotAuthorized.selector);
        piece.transferFrom(alice, bob, 1);
        vm.prank(alice);
        vm.expectRevert(ERC721Lite.NotAuthorized.selector);
        piece.transferFrom(bob, carol, 1);
        vm.prank(alice);
        vm.expectRevert(ERC721Lite.InvalidReceiver.selector);
        piece.transferFrom(alice, address(0), 1);
        vm.prank(bob);
        vm.expectRevert(ERC721Lite.NotAuthorized.selector);
        piece.approve(bob, 1);
        vm.prank(alice);
        piece.setApprovalForAll(bob, true);
        vm.prank(bob);
        piece.approve(carol, 1);
        vm.prank(carol);
        piece.transferFrom(alice, carol, 1);
        assertEq(piece.ownerOf(1), carol);
        assertEq(piece.balanceOf(alice), 0);
        assertEq(piece.balanceOf(carol), 1);
    }

    /// @dev THE SOURCE's reveal gate, reached through a runtime copy initialized by its stub controller.
    function test_revealNeedsTheSourceLocked_andEmptyRendererURI() public {
        StubController ctl = new StubController();
        ArtifactsPiece src = ArtifactsPiece(Clones.copyCode(address(pieceImpl)));
        vm.prank(address(ctl));
        src.initialize(
            address(ctl), address(house), 256, alice, _traits(256), address(0), SOURCE_COMMITMENT, "", true, bytes32(0)
        );
        assertEq(src.name(), unicode"ARTIFACTS · THE SOURCE");
        vm.prank(alice);
        vm.expectRevert(ArtifactsPiece.NotRevealable.selector);
        src.reveal(SOURCE_KEY);
        ctl.setLocked(true);
        vm.prank(alice);
        src.reveal(SOURCE_KEY);
        // no renderer stored: still well-formed metadata, the page being just the seed and the closing
        assertEq(src.revealedSeed(), keccak256(abi.encodePacked(SOURCE_KEY, uint256(0))), "stub seal is zero");
        assertTrue(bytes(src.tokenURI(1)).length > 29);
        // revealed is write-once and survives a transfer
        vm.prank(alice);
        src.transferFrom(alice, bob, 1);
        assertTrue(src.revealed());
        vm.prank(bob);
        vm.expectRevert(ArtifactsPiece.AlreadyRevealed.selector);
        src.reveal(SOURCE_KEY);
    }
}

/// @dev Edge inputs for THE SOURCE's payload and auction.
contract SourceEdgeTest is Fixture {
    function _lock() internal {
        vm.startPrank(curator);
        source.storeRendererChunk("payload");
        source.lock(SEALED_SEED, SOURCE_COMMITMENT);
        vm.stopPrank();
    }

    function test_payloadChunkLimits() public {
        vm.startPrank(curator);
        vm.expectRevert(SSTORE2.TooLarge.selector);
        source.storeRendererChunk(new bytes(24_576));
        source.storeRendererChunk(new bytes(24_575));
        assertEq(source.rendererSize(), 24_575);
        assertEq(source.rendererChunks().length, 1);
        vm.expectRevert(ArtifactsSource.EmptyRenderer.selector);
        source.storeRendererChunk("");
        vm.stopPrank();
        vm.prank(alice);
        vm.expectRevert(TwoStepOwnable.NotOwner.selector);
        source.lock(SEALED_SEED, SOURCE_COMMITMENT);
        vm.prank(alice);
        vm.expectRevert(TwoStepOwnable.NotOwner.selector);
        source.resetRenderer();
    }

    /// forge-config: default.fuzz.runs = 64
    function testFuzz_rendererHashIsKeccakOfConcatenation(bytes memory a, bytes memory b, bytes memory c) public {
        a = _clip(a);
        b = _clip(b);
        c = _clip(c);
        vm.startPrank(curator);
        source.storeRendererChunk(a);
        source.storeRendererChunk(b);
        source.storeRendererChunk(c);
        vm.stopPrank();
        assertEq(source.renderer(), bytes.concat(a, b, c));
        assertEq(source.rendererHash(), keccak256(bytes.concat(a, b, c)));
        assertEq(source.rendererSize(), a.length + b.length + c.length);
    }

    /// @dev Non-empty and within one SSTORE2 chunk.
    function _clip(bytes memory x) internal pure returns (bytes memory) {
        if (x.length == 0) return bytes("x");
        if (x.length > 24_575) {
            assembly ("memory-safe") {
                mstore(x, 24575)
            }
        }
        return x;
    }

    function test_setAuctionEdges() public {
        _lock();
        vm.startPrank(curator);
        vm.expectRevert(ArtifactsSource.BidTooLow.selector);
        source.setAuction(0, uint64(vm.getBlockTimestamp() + 1));
        vm.expectRevert(ArtifactsSource.BadEndTime.selector);
        source.setAuction(1, uint64(vm.getBlockTimestamp()));
        source.setAuction(1, uint64(vm.getBlockTimestamp() + 1));
        vm.stopPrank();
        vm.prank(alice);
        vm.expectRevert(TwoStepOwnable.NotOwner.selector);
        source.setAuction(1, uint64(vm.getBlockTimestamp() + 1 days));
        (bool open, bool isSettled, uint256 r, uint64 end, address bidder, uint256 amount) = source.auctionState();
        assertTrue(open);
        assertFalse(isSettled);
        assertEq(r, 1);
        assertEq(end, vm.getBlockTimestamp() + 1);
        assertEq(bidder, address(0));
        assertEq(amount, 0);
    }

    function test_bidBoundaries() public {
        _lock();
        uint64 end = uint64(vm.getBlockTimestamp() + 1 hours);
        vm.prank(curator);
        source.setAuction(1 ether, end);
        vm.prank(alice);
        source.bid{value: 1 ether}(address(0)); // exactly the reserve
        vm.prank(bob);
        vm.expectRevert(ArtifactsSource.BidTooLow.selector);
        source.bid{value: 1.05 ether - 1}(address(0));
        vm.prank(bob);
        source.bid{value: 1.05 ether}(address(0)); // exactly +5%
        // the high bidder may raise their own bid; the previous one becomes a refund
        vm.prank(bob);
        source.bid{value: 1.2 ether}(address(0));
        assertEq(source.refunds(bob), 1.05 ether);
        assertEq(source.refunds(alice), 1 ether);
        assertEq(address(source).balance, 1.2 ether + 1.05 ether + 1 ether);
        // exactly 10 minutes left: no extension; one second later: extension
        vm.warp(end - 10 minutes);
        vm.prank(carol);
        source.bid{value: 2 ether}(address(0));
        assertEq(source.endTime(), end);
        vm.warp(end - 10 minutes + 1);
        vm.prank(alice);
        source.bid{value: 2.1 ether}(address(0));
        assertEq(source.endTime(), end - 10 minutes + 1 + 10 minutes);
        // a bid at the (new) end time is late
        vm.warp(source.endTime());
        vm.prank(bob);
        vm.expectRevert(ArtifactsSource.AuctionEnded.selector);
        source.bid{value: 3 ether}(address(0));
    }

    /// @dev For any high bid, the smallest accepted raise is the exact ceiling of 105%: one wei less is refused,
    /// and it always strictly exceeds the high bid (no ties at dust sizes).
    /// forge-config: default.fuzz.runs = 512
    function testFuzz_minimumRaiseIsCeilingOfFivePercent(uint96 first, uint96 nextSeed) public {
        _lock();
        vm.prank(curator);
        source.setAuction(1, uint64(vm.getBlockTimestamp() + 1 hours));
        uint256 high = bound(first, 1, type(uint96).max);
        vm.deal(alice, high);
        vm.prank(alice);
        source.bid{value: high}(address(0));
        uint256 min = (high * 10_500 + 9_999) / 10_000;
        assertGt(min, high, "a raise always strictly exceeds the high bid");
        assertGe(min * 10_000, high * 10_500, "min is at least 105%");
        assertLt((min - 1) * 10_000, high * 10_500, "min is the smallest such amount");
        vm.deal(bob, min - 1);
        vm.prank(bob);
        vm.expectRevert(ArtifactsSource.BidTooLow.selector);
        source.bid{value: min - 1}(address(0));
        assertEq(source.highBidder(), alice);
        uint256 next = bound(nextSeed, min, min + 1 ether);
        vm.deal(bob, next);
        vm.prank(bob);
        source.bid{value: next}(address(0));
        assertEq(source.highBidder(), bob);
        assertEq(source.highBid(), next);
        assertEq(source.refunds(alice), high);
    }

    function test_settleEdges_brokerSplit() public {
        _lock();
        vm.prank(curator);
        source.setAuction(1 ether, uint64(vm.getBlockTimestamp() + 1 hours));
        vm.expectRevert(ArtifactsSource.AuctionNotEnded.selector);
        source.settle();
        vm.prank(alice);
        source.bid{value: 2 ether}(broker);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        ArtifactsPiece piece = ArtifactsPiece(source.settle());
        assertEq(house.balances(broker, address(0)), 0.3 ether, "broker on the winning bid is paid");
        assertEq(_artistEth(), 1.5 ether);
        assertEq(house.balances(address(house), address(0)), 0.1 ether);
        assertEq(house.balances(house.BUYBACK(), address(0)), 0.1 ether);
        assertEq(address(source).balance, 0);
        vm.expectRevert(ArtifactsSource.AuctionNotOpen.selector);
        source.settle();
        vm.prank(curator);
        vm.expectRevert(ArtifactsSource.AlreadySettled.selector);
        source.setAuction(1 ether, uint64(vm.getBlockTimestamp() + 1 hours));
        vm.prank(bob);
        vm.expectRevert(ArtifactsSource.AuctionNotOpen.selector);
        source.bid{value: 5 ether}(address(0));
        // THE SOURCE runs the same escrow and re-keying as an edition
        (address rTo, uint256 rAmt) = piece.royaltyInfo(1, 1 ether);
        assertEq(rTo, artist);
        assertEq(rAmt, 0.075 ether);
        vm.prank(alice);
        piece.list(10 ether);
        vm.prank(bob);
        piece.buy{value: 10 ether}(_vk("bob"), address(0));
        _postKey(piece, alice, (10 ether) / 10);
        uint256 artistBefore = _artistEth();
        vm.prank(bob);
        piece.release();
        assertEq(piece.ownerOf(1), bob);
        assertEq(_artistEth() - artistBefore, 0.75 ether);
        vm.prank(bob);
        piece.reveal(SOURCE_KEY);
        assertTrue(piece.revealed());
    }

    function test_settleWithUnapprovedBrokerPaysTheBurn() public {
        _lock();
        vm.prank(curator);
        source.setAuction(1 ether, uint64(vm.getBlockTimestamp() + 1 hours));
        vm.prank(alice);
        source.bid{value: 1 ether}(alice);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        source.settle();
        assertEq(house.balances(alice, address(0)), 0);
        assertEq(house.balances(address(house), address(0)), 0.05 ether);
        assertEq(house.balances(house.BUYBACK(), address(0)), 0.2 ether, "5% + the unearned 15%");
    }
}

/// @dev The launched runtimes: bounded size, no DELEGATECALL / CALLCODE / SELFDESTRUCT, and no renounce path.
contract RuntimeTest is Fixture {
    /// @dev Walks the instructions (skipping PUSH data). The compiler ends the code with INVALID (0xfe) and appends
    /// constant data after it, which is never executed; the walk stops there, and that boundary must sit in the last
    /// few hundred bytes, so no real code can hide behind it.
    function _scan(address a) internal view {
        bytes memory code = a.code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576, "runtime exceeds EIP-170");
        for (uint256 j; j < code.length; ++j) {
            uint8 op = uint8(code[j]);
            if (op >= 0x60 && op <= 0x7f) {
                j += op - 0x5f;
                continue;
            }
            if (op == 0xfe) {
                assertLe(code.length - j, 512, "data after the code is only a short tail");
                return;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden opcode in a launched runtime");
        }
    }

    function test_launchedRuntimesAreBoundedAndHaveNoEscapeOpcodes() public view {
        _scan(address(store));
        _scan(address(house));
        _scan(address(pieceImpl));
        _scan(address(keyProof));
        _scan(address(factory));
        _scan(address(source));
        _scan(house.collectionImplementation());
    }

    function test_noRenounceAnywhere() public {
        address[5] memory cs = [address(store), address(house), address(factory), address(source), address(pieceImpl)];
        for (uint256 i; i < 4; ++i) {
            vm.prank(curator);
            (bool ok,) = cs[i].call(abi.encodeWithSignature("renounceOwnership()"));
            assertFalse(ok);
            assertEq(TwoStepOwnable(cs[i]).owner(), curator);
        }
    }

    function test_implementationsAreLocked() public {
        vm.expectRevert(ArtifactsPiece.AlreadyInitialized.selector);
        pieceImpl.initialize(alice, alice, 1, alice, _traits(1), address(0), bytes32(0), "", false, bytes32(0));
        ArtCollection impl = ArtCollection(house.collectionImplementation());
        vm.expectRevert(ArtCollection.AlreadyInitialized.selector);
        impl.initialize(alice, "x", "x");
        vm.expectRevert(ArtCollection.NotHouse.selector);
        impl.mint(alice, 0);
    }
}
