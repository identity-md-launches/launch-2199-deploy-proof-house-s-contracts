// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./Fixture.sol";
import {ArtifactsPiece} from "../src/ArtifactsPiece.sol";

/// @dev Regression for a0cc401d2e36, exercised on real edition claims and THE SOURCE settlements.
abstract contract EscrowDeadlineTests is Fixture {
    ArtifactsPiece internal piece;
    uint256 internal deadline;

    function _makePiece() internal virtual returns (ArtifactsPiece);

    function setUp() public override {
        super.setUp();
        piece = _makePiece();
        vm.prank(alice);
        piece.list(1 ether);
        bytes32 viewingKey = _vk("deadline buyer");
        vm.prank(bob);
        piece.buy{value: 1 ether}(viewingKey, broker);
        (,,, uint64 paidAt,,,,,,) = piece.escrow();
        deadline = uint256(paidAt) + piece.SELLER_WINDOW();
    }

    function test_postJustBeforeDeadlinePreventsCancellation() public {
        vm.warp(deadline - 1);
        vm.prank(bob);
        vm.expectRevert(ArtifactsPiece.TooEarly.selector);
        piece.cancel();

        _postKey(piece, alice, 0.1 ether);
        (,,,, bool posted,,, uint64 keyAt,, uint256 deposit) = piece.escrow();
        assertTrue(posted);
        assertEq(keyAt, deadline - 1);
        assertEq(deposit, 0.1 ether);

        vm.warp(deadline);
        vm.prank(bob);
        vm.expectRevert(ArtifactsPiece.KeyAlreadyPosted.selector);
        piece.cancel();
        vm.prank(bob);
        piece.release();
        assertEq(piece.ownerOf(1), bob);
        assertEq(piece.wrappedKey(), _wrappedOf("key"));
        assertEq(piece.pendingWithdrawals(alice), 1 ether); // price - royalty - broker share + deposit
    }

    function test_postAtCancellationDeadlineReverts() public {
        _assertLatePost(deadline);
    }

    function test_postOneSecondAfterDeadlineReverts() public {
        _assertLatePost(deadline + 1);
    }

    function testFuzz_postAfterDeadlineReverts(uint32 delay) public {
        _assertLatePost(deadline + uint256(delay));
    }

    function _escrowHash() internal view returns (bytes32) {
        (bool ok, bytes memory data) = address(piece).staticcall(abi.encodeWithSelector(piece.escrow.selector));
        assertTrue(ok);
        return keccak256(data);
    }

    function _assertLatePost(uint256 when) internal {
        vm.warp(when);
        (bytes memory wrapped, address r, uint256 z) = _sellerKey(piece, "key");

        // Cancellation succeeds in this exact state. Restore it before attempting the valid seller proof.
        uint256 snapshot = vm.snapshotState();
        vm.prank(bob);
        piece.cancel();
        assertEq(piece.pendingWithdrawals(bob), 1 ether);
        assertTrue(vm.revertToState(snapshot));

        bytes32 escrowBefore = _escrowHash();
        uint256 sellerBalance = alice.balance;
        vm.prank(alice);
        vm.expectRevert(ArtifactsPiece.TooLate.selector);
        piece.postEscrowKey{value: 0.1 ether}(wrapped, r, z);
        assertEq(_escrowHash(), escrowBefore, "late post changes no escrow fields");
        assertEq(alice.balance, sellerBalance, "seller keeps the rejected deposit");
        assertEq(address(piece).balance, 1 ether, "only the buyer's price remains escrowed");
        assertEq(piece.ownerOf(1), alice);
        assertEq(piece.pendingWithdrawals(bob), 0);

        vm.prank(bob);
        piece.cancel();
        vm.prank(bob);
        piece.withdraw();
        assertEq(bob.balance, 1000 ether, "the buyer recovers the full price");
        assertEq(address(piece).balance, 0);
        assertEq(piece.ownerOf(1), alice);
    }

    function test_expiredSaleCanBeRefundedAndBoughtAgain() public {
        vm.warp(deadline);
        vm.prank(alice);
        piece.refundBuyer();
        assertEq(piece.pendingWithdrawals(bob), 1 ether);
        vm.prank(bob);
        piece.withdraw();
        vm.prank(alice);
        piece.list(1 ether);
        _buyAgainWithFreshKey();
    }

    function test_cancelledSaleCanBeBoughtAgain() public {
        vm.warp(deadline);
        vm.prank(bob);
        piece.cancel();
        vm.prank(bob);
        piece.withdraw();
        // cancel keeps the listing; the next purchase must get a full new posting window.
        _buyAgainWithFreshKey();
    }

    function _buyAgainWithFreshKey() internal {
        bytes32 freshKey = _vk("deadline buyer retry");
        vm.prank(bob);
        piece.buy{value: 1 ether}(freshKey, broker);
        (,,, uint64 paidAt,,,,, bytes32 viewingKey,) = piece.escrow();
        assertEq(paidAt, deadline);
        assertEq(viewingKey, freshKey);
        vm.warp(uint256(paidAt) + piece.SELLER_WINDOW() - 1);
        _postKey(piece, alice, 0.1 ether);
        vm.prank(bob);
        piece.release();
        assertEq(piece.ownerOf(1), bob);
        assertEq(piece.wrappedKey(), _wrappedOf("key"));
        assertEq(piece.pendingWithdrawals(bob), 0);
    }
}

contract EditionEscrowDeadlineTest is EscrowDeadlineTests {
    function _makePiece() internal override returns (ArtifactsPiece) {
        _publishAll();
        _openSale(1 ether);
        return _claim(alice, _buyAndAssign(alice, address(0), 10));
    }
}

contract SourceEscrowDeadlineTest is EscrowDeadlineTests {
    function _makePiece() internal override returns (ArtifactsPiece) {
        uint64 end = uint64(vm.getBlockTimestamp() + 1 days);
        vm.startPrank(curator);
        source.storeRendererChunk("<html>test renderer</html>");
        source.lock(SEALED_SEED, SOURCE_COMMITMENT);
        source.setAuction(1 ether, end);
        vm.stopPrank();
        vm.prank(alice);
        source.bid{value: 1 ether}(address(0));
        vm.warp(end);
        ArtifactsPiece result = ArtifactsPiece(source.settle());
        assertTrue(result.isSource());
        return result;
    }
}
