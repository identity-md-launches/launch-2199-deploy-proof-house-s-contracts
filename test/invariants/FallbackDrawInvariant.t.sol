// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Fixture} from "../Fixture.sol";
import {ArtifactsFactory} from "../../src/ArtifactsFactory.sol";
import {ArtHouse} from "../../src/ArtHouse.sol";
import {MockVRFCoordinator, MockBlockHistory} from "../mocks/Mocks.sol";

/// @dev Random sequences over the edition draw's recovery paths: purchases, Chainlink answers (including ones whose
/// callback fails and late answers to forgotten ids), re-requests by buyer, curator and strangers, fallback draws
/// started and finished by anyone, and block jumps across VRF_RETRY_BLOCKS, BLOCKHASH's 256, the EIP-2935 history's
/// 8,191 and FALLBACK_BLOCKS. The model is kept per purchase, independent of request ids, so a re-request or a fallback
/// can never lose, duplicate or move a paid edition without an invariant seeing it.
contract FallbackDrawHandler is Test {
    struct Purchase {
        address buyer;
        uint256 requestId; // the id currently serving it
        uint256 boughtAt;
        uint256 edition; // 0 until assigned
    }

    ArtifactsFactory public factory;
    MockVRFCoordinator public vrf;
    MockBlockHistory public history;
    address public curator;
    address[] public buyers;

    Purchase[] internal _purchases;
    uint256[] public retired; // ids a re-request replaced
    mapping(uint256 => bool) public editionSeen;
    mapping(address => uint256) public assignedTo;
    uint256 public assignedCount;
    uint256 public paid;
    uint256 public fallbackFinishes;
    uint256 public fallbacksStarted;
    uint256 public rerequests;
    uint256 public refusedAnswers; // Chainlink answers refused because a started draw's hash was public

    constructor(ArtifactsFactory f, MockVRFCoordinator v, MockBlockHistory h, address curator_, address[] memory b) {
        factory = f;
        vrf = v;
        history = h;
        curator = curator_;
        buyers = b;
    }

    function purchaseCount() external view returns (uint256) {
        return _purchases.length;
    }

    function purchase(uint256 i) external view returns (Purchase memory) {
        return _purchases[i];
    }

    function retiredCount() external view returns (uint256) {
        return retired.length;
    }

    /// @dev What the chain can say about block n's hash: BLOCKHASH, then the history (as the factory reads them).
    function chainHash(uint256 n) public view returns (bytes32 h) {
        h = blockhash(n);
        if (h != bytes32(0)) return h;
        (bool ok, bytes memory ret) = address(history).staticcall(abi.encode(n));
        if (ok && ret.length == 32) h = abi.decode(ret, (bytes32));
    }

    /// @dev A started draw that is still to be finished from its block (not assigned, block ahead or hash readable).
    function liveFallback(uint256 requestId) public view returns (bool) {
        uint256 t = factory.fallbackBlock(requestId);
        if (t == 0 || factory.requestEdition(requestId) != 0 || factory.requestBuyer(requestId) == address(0)) {
            return false;
        }
        return block.number <= t || chainHash(t) != bytes32(0);
    }

    function _open(uint256 seed) internal view returns (bool found, uint256 idx) {
        uint256 n = _purchases.length;
        for (uint256 k; k < n; ++k) {
            uint256 i = (seed % n + k) % n;
            if (_purchases[i].edition == 0) return (true, i);
        }
    }

    function _record(uint256 idx) internal {
        Purchase storage p = _purchases[idx];
        uint256 e = factory.requestEdition(p.requestId);
        assertGe(e, 1);
        assertLe(e, 255);
        assertFalse(editionSeen[e], "an edition drawn twice");
        assertEq(factory.editionBuyer(e), p.buyer, "the edition goes to the purchase's buyer");
        editionSeen[e] = true;
        p.edition = e;
        assignedTo[p.buyer]++;
        assignedCount++;
    }

    function _sel(bytes memory err) internal pure returns (bytes4 s) {
        if (err.length >= 4) s = bytes4(err);
    }

    // ---------- actions ----------

    function buy(uint256 buyerSeed, uint256 quantity) external {
        address buyer = buyers[buyerSeed % buyers.length];
        uint256 left = factory.MAX_PER_WALLET() - factory.mintedBy(buyer);
        if (left == 0) {
            uint256 p = factory.price();
            vm.deal(buyer, p);
            vm.prank(buyer);
            vm.expectRevert(ArtifactsFactory.WalletLimit.selector);
            factory.buy{value: p}(address(0));
            return;
        }
        quantity = bound(quantity, 1, left);
        uint256 value = factory.price() * quantity;
        vm.deal(buyer, value);
        vm.prank(buyer);
        uint256[] memory ids = factory.buyMany{value: value}(quantity, address(0));
        for (uint256 i; i < ids.length; ++i) {
            _purchases.push(Purchase(buyer, ids[i], block.number, 0));
        }
        paid += value;
    }

    /// @dev Chainlink answers an open purchase's current request, once. Refused only if that request's fallback block
    /// is behind us; the real coordinator then still counts it answered (the callback failed), as the mock's
    /// answerWithFailedCallback does.
    function answer(uint256 seed, uint256 word) external {
        (bool found, uint256 idx) = _open(seed);
        if (!found) return;
        uint256 id = _purchases[idx].requestId;
        if (vrf.s_requestCommitments(id) == bytes32(0)) return; // the coordinator answers each request once
        uint256 t = factory.fallbackBlock(id);
        bool hashPublic = t != 0 && block.number > t;
        try vrf.fulfill(id, word) {
            assertFalse(hashPublic, "an answer landed after a started draw's hash was public");
            _record(idx);
        } catch (bytes memory err) {
            assertTrue(hashPublic, "an answer refused although no started draw's hash was public");
            assertEq(_sel(err), ArtifactsFactory.FallbackPending.selector);
            vrf.answerWithFailedCallback(id);
            refusedAnswers++;
        }
    }

    /// @dev The coordinator answered but the callback ran out of gas: the request is gone, nothing assigned.
    function failedCallback(uint256 seed) external {
        (bool found, uint256 idx) = _open(seed);
        if (!found) return;
        vrf.answerWithFailedCallback(_purchases[idx].requestId);
    }

    /// @dev A late answer to an id a re-request replaced draws nothing.
    function lateAnswerToRetired(uint256 seed, uint256 word) external {
        if (retired.length == 0) return;
        uint256 id = retired[seed % retired.length];
        if (vrf.s_requestCommitments(id) == bytes32(0)) return;
        vm.expectRevert(ArtifactsFactory.UnknownRequest.selector);
        vrf.fulfill(id, word);
        vrf.answerWithFailedCallback(id);
    }

    function rerequest(uint256 seed, bool byCurator) external {
        (bool found, uint256 idx) = _open(seed);
        if (!found) return;
        Purchase storage p = _purchases[idx];
        uint256 id = p.requestId;
        bool ownLive = liveFallback(id);
        bool otherLive = liveFallback(factory.fallbackInFlight());
        vm.prank(byCurator ? curator : p.buyer);
        try factory.rerequestRandomness(id) returns (uint256 newId) {
            assertFalse(ownLive, "a live fallback draw was re-requested away");
            assertFalse(otherLive, "a new answer was asked for while a fallback draw was under way");
            assertEq(factory.requestBuyer(id), address(0), "the old id is forgotten");
            assertEq(factory.fallbackBlock(id), 0);
            assertTrue(factory.fallbackInFlight() != id);
            assertEq(factory.requestBuyer(newId), p.buyer);
            assertEq(factory.purchaseBlock(newId), p.boughtAt, "the purchase block carries over");
            assertEq(factory.requestEdition(newId), 0);
            retired.push(id);
            p.requestId = newId;
            rerequests++;
        } catch (bytes memory err) {
            bytes4 s = _sel(err);
            if (ownLive) assertEq(s, ArtifactsFactory.FallbackPending.selector);
            else if (otherLive) assertEq(s, ArtifactsFactory.FallbackBusy.selector);
            else assertEq(s, ArtifactsFactory.RequestTooRecent.selector);
        }
    }

    function strangerRerequest(uint256 seed, address stranger) external {
        (bool found, uint256 idx) = _open(seed);
        if (!found) return;
        Purchase storage p = _purchases[idx];
        if (stranger == p.buyer || stranger == curator) return;
        vm.prank(stranger);
        vm.expectRevert(ArtifactsFactory.NotBuyer.selector);
        factory.rerequestRandomness(p.requestId);
    }

    function startFallback(uint256 seed, address anyone) external {
        (bool found, uint256 idx) = _open(seed);
        if (!found) return;
        Purchase storage p = _purchases[idx];
        uint256 id = p.requestId;
        bool ownLive = liveFallback(id);
        uint256 busy = factory.fallbackInFlight();
        bool otherLive = busy != id && liveFallback(busy);
        vm.prank(anyone);
        try factory.startFallbackDraw(id) {
            assertGe(block.number, p.boughtAt + factory.FALLBACK_BLOCKS(), "counted from the purchase");
            assertGe(block.number, factory.lastAnsweredBlock() + factory.FALLBACK_BLOCKS(), "Chainlink silent");
            assertFalse(ownLive, "restarted while its hash could be read");
            assertFalse(otherLive, "two fallback draws under way");
            assertTrue(
                block.number >= factory.requestBlock(id) + factory.VRF_RETRY_BLOCKS()
                    || vrf.s_requestCommitments(id) == bytes32(0),
                "started while the coordinator could still answer it"
            );
            assertEq(factory.fallbackBlock(id), block.number + factory.FALLBACK_DELAY());
            assertEq(factory.fallbackInFlight(), id);
            fallbacksStarted++;
        } catch (bytes memory err) {
            bytes4 s = _sel(err);
            assertTrue(
                s == ArtifactsFactory.RequestTooRecent.selector || s == ArtifactsFactory.ChainlinkAnswering.selector
                    || s == ArtifactsFactory.FallbackPending.selector || s == ArtifactsFactory.FallbackBusy.selector,
                "an unexpected refusal"
            );
            if (s == ArtifactsFactory.FallbackPending.selector) assertTrue(ownLive);
            if (s == ArtifactsFactory.FallbackBusy.selector) assertTrue(otherLive);
        }
    }

    function finishFallback(uint256 seed, address anyone) external {
        (bool found, uint256 idx) = _open(seed);
        if (!found) return;
        uint256 id = _purchases[idx].requestId;
        uint256 t = factory.fallbackBlock(id);
        vm.prank(anyone);
        try factory.finishFallbackDraw(id) {
            assertTrue(t != 0 && block.number > t && chainHash(t) != bytes32(0), "finished without a known hash");
            assertEq(factory.fallbackBlock(id), 0);
            assertTrue(factory.fallbackInFlight() != id);
            _record(idx);
            fallbackFinishes++;
        } catch (bytes memory err) {
            bytes4 s = _sel(err);
            if (t == 0) assertEq(s, ArtifactsFactory.NoFallback.selector);
            else if (block.number <= t) assertEq(s, ArtifactsFactory.FallbackNotReady.selector);
            else assertEq(s, ArtifactsFactory.FallbackMissed.selector);
        }
    }

    /// @dev Finishing or restarting a draw for an assigned purchase or a forgotten id gives nothing.
    function finishSettledOrRetired(uint256 seed) external {
        uint256 n = _purchases.length;
        for (uint256 k; k < n; ++k) {
            Purchase storage p = _purchases[(seed % n + k) % n];
            if (p.edition == 0) continue;
            vm.expectRevert(ArtifactsFactory.AlreadyFulfilled.selector);
            factory.startFallbackDraw(p.requestId);
            break;
        }
        if (retired.length == 0) return;
        uint256 id = retired[seed % retired.length];
        vm.expectRevert(ArtifactsFactory.NoFallback.selector);
        factory.finishFallbackDraw(id);
        vm.expectRevert(ArtifactsFactory.UnknownRequest.selector);
        factory.startFallbackDraw(id);
    }

    /// @dev Moves the chain forward. The in-flight draw's block hash enters the history once that block exists, and
    /// leaves it 8,191 blocks later, as EIP-2935's ring buffer does.
    function roll(uint256 choice, uint256 extra) external {
        uint256[8] memory steps = [uint256(1), 5, 200, 300, 7_500, 8_200, 21_600, 30_000];
        uint256 delta = steps[choice % steps.length] + bound(extra, 0, 50);
        uint256 cur = block.number;
        uint256 next = cur + delta;
        uint256 t = factory.fallbackBlock(factory.fallbackInFlight());
        if (t != 0 && cur <= t && next > t) {
            vm.roll(t + 1);
            history.set(t, keccak256(abi.encode("block hash", t)));
        }
        vm.roll(next);
        if (t != 0 && next > t + 8_191) history.set(t, bytes32(0));
    }
}

/// forge-config: default.invariant.runs = 96
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract FallbackDrawInvariantTest is Fixture {
    FallbackDrawHandler internal h;
    MockBlockHistory internal history;

    function setUp() public override {
        super.setUp();
        _publishAll();
        _openSale(0.25 ether);
        vm.etch(factory.BLOCK_HISTORY(), address(new MockBlockHistory()).code);
        history = MockBlockHistory(factory.BLOCK_HISTORY());
        address[] memory buyers = new address[](4);
        buyers[0] = alice;
        buyers[1] = bob;
        buyers[2] = carol;
        buyers[3] = makeAddr("dave");
        h = new FallbackDrawHandler(factory, vrf, history, curator, buyers);
        // the mock coordinator answers for anyone; the handler is the only caller that does
        bytes4[] memory selectors = new bytes4[](10);
        selectors[0] = FallbackDrawHandler.buy.selector;
        selectors[1] = FallbackDrawHandler.answer.selector;
        selectors[2] = FallbackDrawHandler.failedCallback.selector;
        selectors[3] = FallbackDrawHandler.lateAnswerToRetired.selector;
        selectors[4] = FallbackDrawHandler.rerequest.selector;
        selectors[5] = FallbackDrawHandler.strangerRerequest.selector;
        selectors[6] = FallbackDrawHandler.startFallback.selector;
        selectors[7] = FallbackDrawHandler.finishFallback.selector;
        selectors[8] = FallbackDrawHandler.finishSettledOrRetired.selector;
        selectors[9] = FallbackDrawHandler.roll.selector;
        targetSelector(FuzzSelector({addr: address(h), selectors: selectors}));
        targetContract(address(h));
    }

    /// @dev Every paid purchase is either assigned exactly one edition, to its buyer, or still served by exactly one
    /// known request that carries its purchase block; nothing else is assigned.
    function invariant_everyPurchaseOneEdition() public view {
        uint256 n = h.purchaseCount();
        assertEq(factory.sold(), n, "one purchase per paid edition");
        assertEq(factory.assigned(), h.assignedCount(), "only the model's assignments happened");
        for (uint256 i; i < n; ++i) {
            FallbackDrawHandler.Purchase memory p = h.purchase(i);
            assertEq(factory.requestBuyer(p.requestId), p.buyer);
            if (p.edition != 0) {
                assertEq(factory.requestEdition(p.requestId), p.edition);
                assertEq(factory.editionBuyer(p.edition), p.buyer);
            } else {
                assertEq(factory.requestEdition(p.requestId), 0);
                assertEq(factory.purchaseBlock(p.requestId), p.boughtAt);
            }
        }
        for (uint256 i; i < 4; ++i) {
            address b = h.buyers(i);
            assertEq(factory.editionsOf(b).length, h.assignedTo(b));
            assertLe(factory.mintedBy(b), factory.MAX_PER_WALLET());
        }
    }

    /// @dev An id a re-request replaced is gone for good: no buyer, no edition, no fallback.
    function invariant_retiredIdsStayDead() public view {
        for (uint256 i; i < h.retiredCount(); ++i) {
            uint256 id = h.retired(i);
            assertEq(factory.requestBuyer(id), address(0));
            assertEq(factory.requestEdition(id), 0);
            assertEq(factory.fallbackBlock(id), 0);
        }
    }

    /// @dev At most one fallback draw is under way, and it is the one fallbackInFlight names.
    function invariant_oneFallbackAtATime() public view {
        uint256 live;
        uint256 n = h.purchaseCount();
        for (uint256 i; i < n; ++i) {
            uint256 id = h.purchase(i).requestId;
            if (h.liveFallback(id)) {
                live++;
                assertEq(factory.fallbackInFlight(), id);
            }
        }
        assertLe(live, 1);
    }

    /// @dev Retries and fallbacks never move ETH: every purchase's price sits in the ledger or went to the artist.
    function invariant_paymentsUntouched() public view {
        assertEq(address(factory).balance, 0);
        assertEq(address(house).balance + artist.balance, h.paid());
    }

    /// @dev Fallback draws, finished from the history long past BLOCKHASH's 256, still assign: sequence that only
    /// a 3-day silence opens. Pins the whole route once with fixed steps so the campaign is known to reach it.
    function test_fallbackRouteIsReachable() public {
        h.buy(0, 1);
        h.roll(6, 0); // FALLBACK_BLOCKS
        h.startFallback(0, address(this));
        assertEq(h.fallbacksStarted(), 1);
        h.roll(3, 0); // 300 blocks: past BLOCKHASH, still in the history
        h.answer(0, 7); // Chainlink's late answer is refused, the draw stands
        assertEq(h.refusedAnswers(), 1);
        h.rerequest(0, false); // its own live draw: refused
        assertEq(h.rerequests(), 0);
        h.finishFallback(0, address(this));
        assertEq(h.fallbackFinishes(), 1);
        invariant_everyPurchaseOneEdition();
        invariant_oneFallbackAtATime();
    }

    /// @dev A draw nobody finished before its hash left the history is dead: Chainlink's answer to it is refused, and
    /// a re-request clears it and lets the purchase be drawn again, exactly once.
    function test_deadFallbackIsClearedByARerequest() public {
        h.buy(1, 1);
        h.roll(6, 0);
        h.startFallback(0, address(this));
        h.roll(5, 0); // 8,200 blocks: gone from the history too
        assertFalse(h.liveFallback(h.purchase(0).requestId));
        h.finishFallback(0, address(this)); // FallbackMissed
        assertEq(h.fallbackFinishes(), 0);
        h.answer(0, 3); // its block is behind us: refused, and the coordinator drops it
        assertEq(h.refusedAnswers(), 1);
        h.rerequest(0, true); // not held any more: at once
        assertEq(h.rerequests(), 1);
        h.answer(0, 3);
        assertEq(h.assignedCount(), 1);
        invariant_everyPurchaseOneEdition();
        invariant_retiredIdsStayDead();
    }
}
