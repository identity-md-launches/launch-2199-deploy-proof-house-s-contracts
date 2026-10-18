// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ArtHouse} from "../../src/ArtHouse.sol";
import {Test, Vm} from "forge-std/Test.sol";
import {Fixture} from "../Fixture.sol";
import {ArtifactsPiece} from "../../src/ArtifactsPiece.sol";
import {KeyProof} from "../../src/KeyProof.sol";

/// @dev Drives one claimed piece's keyed resale escrow (keys sent with the seller's deposit, keys proven fake, the
/// seller's refunds), plain transfers, re-keying and withdrawals with four actors calling in random order. Each action computes from the contract's state whether it must succeed, and
/// asserts exactly that, so access control and ordering rules are checked on every call.
contract EscrowHandler is Test {
    ArtifactsPiece public piece;
    address[] public actors;
    address public royaltyTo;

    uint256 public paidIn;
    uint256 public paidOut;
    address public ghostOwner;
    uint256 public releases;
    uint256 public cancels;
    uint256 public transfers;
    uint256 public proofs;
    uint256 public refunds;

    uint256 internal constant N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
    mapping(bytes32 => uint256) internal secretOf; // each viewing key a buyer used, and its secret
    uint256 internal postedE; // the scalar behind the posted key's E

    constructor(ArtifactsPiece p, address[] memory actors_, address royaltyTo_) {
        piece = p;
        actors = actors_;
        royaltyTo = royaltyTo_;
        ghostOwner = p.ownerOf(1);
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function _escrow()
        internal
        view
        returns (uint256 price, address seller, address buyer, uint64 paidAt, bool keyPosted)
    {
        (price, seller, buyer, paidAt, keyPosted,,,,,) = piece.escrow();
    }

    /// @dev When the key arrived, and the seller's deposit.
    function _state() internal view returns (uint64 keyPostedAt, uint256 deposit) {
        (,,,,,,, keyPostedAt,, deposit) = piece.escrow();
    }

    function list(uint256 a, uint256 price) external {
        address actor = actors[a % actors.length];
        price = a % 7 == 0 ? 0 : bound(price, 1, 50 ether);
        (, address seller,,,) = _escrow();
        bool ok = actor == piece.ownerOf(1) && seller == address(0) && price > 0;
        vm.prank(actor);
        if (!ok) vm.expectRevert();
        piece.list(price);
        if (ok) {
            (uint256 p, address s,,,) = _escrow();
            assertEq(s, actor);
            assertEq(p, price);
        }
    }

    function delist(uint256 a) external {
        address actor = actors[a % actors.length];
        (, address seller, address buyer,,) = _escrow();
        bool ok = actor == seller && buyer == address(0);
        vm.prank(actor);
        if (!ok) vm.expectRevert();
        piece.delist();
        if (ok) {
            (, address s,,,) = _escrow();
            assertEq(s, address(0));
        }
    }

    function buy(uint256 a, bytes32 key, bool exact) external {
        address actor = actors[a % actors.length];
        (uint256 price, address seller, address buyer,,) = _escrow();
        uint256 value = exact ? price : (a % 2 == 0 ? price + 1 : (price == 0 ? 0 : price - 1));
        vm.deal(actor, actor.balance + value);
        if (key != bytes32(0)) {
            // a valid viewing key, and its secret (for the point with an even y) so this buyer can prove a fake
            Vm.Wallet memory w = vm.createWallet(uint256(key) % 1e70 + 1);
            key = bytes32(w.publicKeyX);
            secretOf[key] = w.publicKeyY & 1 == 1 ? N - w.privateKey : w.privateKey;
        }
        bool ok = seller != address(0) && buyer == address(0) && exact && key != bytes32(0) && actor != seller;
        vm.prank(actor);
        if (!ok) vm.expectRevert();
        piece.buy{value: value}(key, address(0));
        if (ok) {
            paidIn += value;
            (,, address b, uint64 paidAt,) = _escrow();
            assertEq(b, actor);
            assertEq(paidAt, uint64(block.timestamp));
            assertEq(piece.viewingKeyOf(actor), key);
        }
    }

    /// @dev A key as a seller's tool makes it (E = e·G, a junk masked key) with its proof, or (`proven` false) the same
    /// key with a broken proof, which is refused.
    function postKey(uint256 a, uint256 eSeed, bool proven) external {
        address actor = actors[a % actors.length];
        (uint256 price, address seller, address buyer, uint64 paidAt, bool keyPosted) = _escrow();
        (,,,,,,,, bytes32 vk,) = piece.escrow();
        bool ok = actor == seller && buyer != address(0) && !keyPosted && proven
            && block.timestamp < paidAt + piece.SELLER_WINDOW();
        uint256 e = eSeed % (N - 1) + 1;
        if (vm.createWallet(e).publicKeyY & 1 == 1) e = N - e;
        bytes memory wrapped = abi.encodePacked(uint8(2), vm.createWallet(e).publicKeyX, keccak256(abi.encode(eSeed)));
        uint256 k = uint256(keccak256(abi.encode("k", eSeed))) % (N - 1) + 1;
        address r = vm.addr(k);
        uint256 c = uint256(
            keccak256(
                abi.encodePacked(
                    "Proof House key wrap v2 proof", block.chainid, address(piece), buyer, vk, keccak256(wrapped), r
                )
            )
        ) % N;
        uint256 z = addmod(k, mulmod(c, e, N), N);
        if (!proven) z = addmod(z, 1, N);
        uint256 deposit = piece.depositFor(price);
        vm.deal(actor, actor.balance + deposit);
        vm.prank(actor);
        if (!ok) vm.expectRevert();
        piece.postEscrowKey{value: deposit}(wrapped, r, z);
        if (ok) {
            postedE = e;
            paidIn += deposit;
            (, uint256 d) = _state();
            assertEq(d, deposit);
            (,,,, bool posted,,,,,) = piece.escrow();
            assertTrue(posted);
        }
    }

    function cancel(uint256 a) external {
        address actor = actors[a % actors.length];
        (uint256 price,, address buyer,, bool keyPosted) = _escrow();
        (,,, uint64 paidAt,) = _escrow();
        bool ok = actor == buyer && !keyPosted && block.timestamp >= paidAt + piece.SELLER_WINDOW();
        uint256 pendingBefore = piece.pendingWithdrawals(actor);
        vm.prank(actor);
        if (!ok) vm.expectRevert();
        piece.cancel();
        if (ok) {
            assertEq(piece.pendingWithdrawals(actor), pendingBefore + price, "refund credited");
            (,, address b,,) = _escrow();
            assertEq(b, address(0));
            cancels++;
        }
    }

    function release(uint256 a) external {
        address actor = actors[a % actors.length];
        (uint256 price, address seller, address buyer,, bool keyPosted) = _escrow();
        (uint64 keyAt, uint256 deposit) = _state();
        bool ok = buyer != address(0) && keyPosted && (actor == buyer || block.timestamp >= keyAt + 72 hours);
        uint256 sellerBefore = piece.pendingWithdrawals(seller);
        uint256 ledgerBefore = ArtHouse(address(piece.house())).balances(royaltyTo, address(0));
        uint256 ethBefore = royaltyTo.balance;
        (,,,,, bytes memory keyBefore,,,,) = piece.escrow();
        vm.prank(actor);
        if (!ok) vm.expectRevert();
        piece.release();
        if (ok) {
            uint256 royalty = (price * 750) / 10_000;
            assertEq(piece.ownerOf(1), buyer, "token to the buyer");
            // the royalty goes straight to the artist (or waits in the ledger); the seller's proceeds stay on the piece
            assertEq(
                piece.pendingWithdrawals(seller),
                sellerBefore + price - royalty + deposit,
                "seller proceeds and deposit"
            );
            assertEq(
                ArtHouse(address(piece.house())).balances(royaltyTo, address(0)) - ledgerBefore
                    + (royaltyTo.balance - ethBefore),
                royalty,
                "royalty to the artist"
            );
            paidOut += royalty; // that ETH left the piece for the ledger
            assertEq(piece.previousOwner(), address(0), "a paid seller keeps no re-key right");
            assertEq(keccak256(piece.wrappedKey()), keccak256(keyBefore), "the escrowed key is delivered");
            (, address s, address b,,) = _escrow();
            assertEq(s, address(0));
            assertEq(b, address(0));
            ghostOwner = buyer;
            releases++;
        }
    }

    /// @dev Only the buyer, only with a key posted. The keys posted here are junk, so the buyer proves it (a real
    /// proof, made from scalars: every point is a multiple of G): payment and deposit to the buyer, the seller keeps
    /// the piece.
    function proveFake(uint256 a) external {
        address actor = actors[a % actors.length];
        (uint256 price,, address buyer,, bool keyPosted) = _escrow();
        (,,,,,,,, bytes32 vk,) = piece.escrow();
        (, uint256 deposit) = _state();
        bool ok = buyer != address(0) && actor == buyer && keyPosted;
        uint256 before = piece.pendingWithdrawals(actor);
        address owner = piece.ownerOf(1);
        KeyProof.Proof memory proof;
        if (keyPosted && secretOf[vk] != 0) proof = _fakeProof(actor, vk, secretOf[vk], postedE);
        vm.prank(actor);
        if (!ok) vm.expectRevert();
        piece.proveFakeKey(proof);
        if (ok) {
            assertEq(piece.pendingWithdrawals(actor), before + price + deposit, "payment and deposit");
            assertEq(piece.ownerOf(1), owner, "the seller keeps the piece");
            (, address s, address b,,) = _escrow();
            assertEq(s, address(0));
            assertEq(b, address(0));
            proofs++;
        }
    }

    /// @dev The seller may end a sale before sending the key, refunding the buyer in full.
    function _fakeProof(address buyer, bytes32 vk, uint256 b, uint256 e) internal returns (KeyProof.Proof memory) {
        uint256 w = uint256(keccak256(abi.encode("w", e, b))) % (N - 1) + 1;
        Vm.Wallet memory S = vm.createWallet(mulmod(b, e, N));
        Vm.Wallet memory A1 = vm.createWallet(w);
        Vm.Wallet memory A2 = vm.createWallet(mulmod(w, e, N));
        uint256 c = uint256(
            keccak256(
                abi.encodePacked(
                    "Proof House fake key v2",
                    block.chainid,
                    address(piece),
                    buyer,
                    uint256(vk),
                    vm.createWallet(e).publicKeyX,
                    S.publicKeyX,
                    S.publicKeyY,
                    A1.publicKeyX,
                    A1.publicKeyY,
                    A2.publicKeyX,
                    A2.publicKeyY
                )
            )
        ) % N;
        Vm.Wallet memory X = vm.createWallet(mulmod(c, mulmod(b, e, N), N));
        return KeyProof.Proof(
            S.publicKeyX,
            S.publicKeyY,
            A1.publicKeyX,
            A1.publicKeyY,
            A2.publicKeyX,
            A2.publicKeyY,
            X.publicKeyX,
            X.publicKeyY,
            addmod(w, mulmod(c, b, N), N)
        );
    }

    function refundBuyer(uint256 a) external {
        address actor = actors[a % actors.length];
        (uint256 price, address seller, address buyer,, bool keyPosted) = _escrow();
        bool ok = buyer != address(0) && actor == seller && !keyPosted;
        uint256 before = buyer == address(0) ? 0 : piece.pendingWithdrawals(buyer);
        vm.prank(actor);
        if (!ok) vm.expectRevert();
        piece.refundBuyer();
        if (ok) {
            assertEq(piece.pendingWithdrawals(buyer), before + price, "full refund");
            (, address s, address b,,) = _escrow();
            assertEq(s, address(0));
            assertEq(b, address(0));
            refunds++;
        }
    }

    function withdraw(uint256 a) external {
        address actor = actors[a % actors.length];
        uint256 amount = piece.pendingWithdrawals(actor);
        uint256 before = actor.balance;
        vm.prank(actor);
        if (amount == 0) vm.expectRevert(ArtifactsPiece.NothingToWithdraw.selector);
        piece.withdraw();
        if (amount > 0) {
            assertEq(actor.balance - before, amount);
            assertEq(piece.pendingWithdrawals(actor), 0);
            paidOut += amount;
        }
    }

    function withdrawRoyalty() external {
        uint256 amount = piece.pendingWithdrawals(royaltyTo);
        if (amount == 0) return;
        vm.prank(royaltyTo);
        piece.withdraw();
        paidOut += amount;
    }

    function transfer(uint256 a, uint256 toSeed, bool safe) external {
        address actor = actors[a % actors.length];
        address to = actors[toSeed % actors.length];
        address owner = piece.ownerOf(1);
        (,, address buyer,,) = _escrow();
        bool ok = actor == owner && buyer == address(0);
        vm.prank(actor);
        if (!ok) vm.expectRevert();
        if (safe) piece.safeTransferFrom(owner, to, 1);
        else piece.transferFrom(owner, to, 1);
        if (ok) {
            assertEq(piece.ownerOf(1), to);
            assertEq(piece.wrappedKey(), "", "plain transfer clears the wrapped key");
            assertEq(piece.previousOwner(), actor);
            (, address s,,,) = _escrow();
            assertEq(s, address(0), "a listing without a buyer is dropped");
            ghostOwner = to;
            transfers++;
        }
    }

    function approveAndTransfer(uint256 a, uint256 opSeed) external {
        address owner = piece.ownerOf(1);
        address op = actors[opSeed % actors.length];
        address to = actors[a % actors.length];
        vm.prank(owner);
        piece.approve(op, 1);
        (,, address buyer,,) = _escrow();
        bool ok = buyer == address(0);
        vm.prank(op);
        if (!ok) vm.expectRevert(ArtifactsPiece.EscrowActive.selector);
        piece.transferFrom(owner, to, 1);
        if (ok) {
            ghostOwner = to;
            transfers++;
            assertEq(piece.getApproved(1), address(0), "approval cleared");
        } else {
            vm.prank(owner);
            piece.approve(address(0), 1);
        }
    }

    function registerKey(uint256 a, bytes32 key) external {
        address actor = actors[a % actors.length];
        if (a % 5 == 0) key = bytes32(0);
        bytes32 before = piece.viewingKeyOf(actor);
        vm.prank(actor);
        if (key == bytes32(0)) vm.expectRevert(ArtifactsPiece.NoViewingKey.selector);
        piece.registerViewingKey(key);
        assertEq(piece.viewingKeyOf(actor), key == bytes32(0) ? before : key);
    }

    /// @dev One shot: only the previous owner, only into an empty slot, never empty, and the right ends with it.
    function rewrap(uint256 a, bytes calldata wrapped) external {
        address actor = actors[a % actors.length];
        bytes memory keyBefore = piece.wrappedKey();
        address prevBefore = piece.previousOwner();
        bool ok = actor == prevBefore && keyBefore.length == 0 && wrapped.length > 0
            && piece.viewingKeyOf(piece.ownerOf(1)) != bytes32(0);
        vm.prank(actor);
        if (!ok) vm.expectRevert();
        piece.rewrapFor(wrapped);
        if (ok) {
            assertEq(piece.wrappedKey(), wrapped);
            assertEq(piece.previousOwner(), address(0), "re-key right is spent");
        } else {
            assertEq(keccak256(piece.wrappedKey()), keccak256(keyBefore), "a failed re-key changes nothing");
            assertEq(piece.previousOwner(), prevBefore);
        }
    }

    function warp(uint256 delta) external {
        // mostly within the 72 hours, sometimes past the 14-day report window
        vm.warp(block.timestamp + bound(delta, 1, delta % 5 == 0 ? 15 days : 80 hours));
    }
}

/// forge-config: default.invariant.runs = 96
/// forge-config: default.invariant.depth = 60
/// forge-config: default.invariant.fail-on-revert = true
contract PieceEscrowInvariantTest is Fixture {
    EscrowHandler internal h;
    ArtifactsPiece internal piece;
    address internal dave = makeAddr("dave");

    function setUp() public override {
        super.setUp();
        _publishAll();
        _openSale(1 ether);
        uint256 edition = _buyAndAssign(alice, address(0), 10);
        piece = _claim(alice, edition);
        address[] memory actors = new address[](4);
        actors[0] = alice;
        actors[1] = bob;
        actors[2] = carol;
        actors[3] = dave;
        h = new EscrowHandler(piece, actors, artist);
        targetContract(address(h));
    }

    function _held() internal view returns (uint256) {
        (uint256 price,, address buyer,,,,,,, uint256 deposit) = piece.escrow();
        return buyer == address(0) ? 0 : price + deposit;
    }

    /// @dev The piece holds exactly the escrowed payment plus every pending withdrawal, and nothing else.
    function invariant_escrowConservation() public view {
        uint256 pending = piece.pendingWithdrawals(artist);
        for (uint256 i; i < h.actorCount(); ++i) {
            pending += piece.pendingWithdrawals(h.actors(i));
        }
        assertEq(address(piece).balance, _held() + pending, "balance = escrowed + owed");
        assertEq(address(piece).balance, h.paidIn() - h.paidOut(), "balance = in - out");
    }

    /// @dev One token, one owner, and it is the owner the handler expects.
    function invariant_singleToken() public view {
        uint256 total;
        for (uint256 i; i < h.actorCount(); ++i) {
            total += piece.balanceOf(h.actors(i));
        }
        assertEq(total, 1, "exactly one token");
        assertEq(piece.ownerOf(1), h.ghostOwner(), "owner moves only by release or plain transfer");
        (bool ok,) = address(piece).staticcall(abi.encodeWithSignature("ownerOf(uint256)", 2));
        assertFalse(ok, "no second token");
    }

    /// @dev While a buyer's payment sits in escrow the seller still owns the token.
    function invariant_escrowSellerOwns() public view {
        (, address seller, address buyer,,,,,,,) = piece.escrow();
        if (buyer != address(0)) {
            assertEq(piece.ownerOf(1), seller, "seller keeps the token until release");
            assertTrue(seller != buyer);
        }
        if (seller != address(0)) assertEq(piece.ownerOf(1), seller, "only the owner has a live listing");
    }

    function invariant_royaltyAndIdentity() public view {
        (address to, uint256 amt) = piece.royaltyInfo(1, 1 ether);
        assertEq(to, artist);
        assertEq(amt, 0.075 ether);
        assertEq(piece.symbol(), "ARTIFACTS");
        assertFalse(piece.revealed());
    }
}
