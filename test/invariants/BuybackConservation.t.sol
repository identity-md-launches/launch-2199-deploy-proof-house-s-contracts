// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ArtStorage} from "src/ArtStorage.sol";
import {ArtHouse} from "src/ArtHouse.sol";
import {ImdBuybackBurner} from "src/ImdBuybackBurner.sol";
import {MockIMD} from "../mocks/Mocks.sol";
import {MockPoolManager} from "../mocks/MockPoolManager.sol";

/// @dev The pool models v4 unlock/settle/take locally; this does not claim live pool coverage.
contract BuybackConservationHandler is Test {
    uint256 public constant RATE = 50_000;
    ArtHouse public immutable house;
    ImdBuybackBurner public immutable burner;
    MockIMD public immutable imd;
    address[3] public actors;
    uint256 public ethReceived;
    uint256 public imdReceived;
    uint256 public ethSpent;
    uint256 public swapImdBurned;
    uint256 public directImdBurned;

    constructor(ArtHouse house_, ImdBuybackBurner burner_, MockIMD imd_) {
        house = house_;
        burner = burner_;
        imd = imd_;
        actors = [makeAddr("burner caller A"), makeAddr("burner caller B"), makeAddr("burner caller C")];
    }

    function donateETH(uint256 amount, uint256 actorSeed) external {
        amount = bound(amount, 1, 5 ether);
        address actor = actors[actorSeed % 3];
        vm.deal(actor, amount);
        vm.prank(actor);
        (bool ok,) = address(burner).call{value: amount}("");
        assertTrue(ok);
        ethReceived += amount;
    }

    function donateIMD(uint256 amount) external {
        amount = bound(amount, 1, 100_000 ether);
        imd.mint(address(burner), amount);
        imdReceived += amount;
    }

    function burnIMD(uint256 actorSeed) external {
        uint256 amount = imd.balanceOf(address(burner));
        vm.prank(actors[actorSeed % 3]);
        if (amount == 0) vm.expectRevert(ImdBuybackBurner.NothingToBurn.selector);
        uint256 burned = burner.burnImd();
        if (amount != 0) {
            assertEq(burned, amount);
            directImdBurned += amount;
        }
    }

    function curatorSwap(uint256 seed, bool all) external {
        uint256 balance = address(burner).balance;
        uint256 amount = balance == 0 ? 0 : all ? balance : bound(seed, 1, balance);
        vm.prank(house.owner());
        if (amount == 0) vm.expectRevert(ImdBuybackBurner.BadAmount.selector);
        uint256 out = burner.burnEth(amount, amount == 0 ? 1 : amount * RATE, block.timestamp);
        if (amount != 0) {
            assertEq(out, amount * RATE);
            ethSpent += amount;
            swapImdBurned += out;
        }
    }

    function publicSwap(uint256 actorSeed) external {
        uint256 balance = address(burner).balance;
        uint256 amount = balance < burner.PUBLIC_MAX() ? balance : burner.PUBLIC_MAX();
        bytes4 error;
        if (block.timestamp < uint256(burner.lastCuratorSwapAt()) + burner.IDLE()) {
            error = ImdBuybackBurner.NotCurator.selector;
        } else if (
            burner.lastPublicSwapAt() != 0 && block.timestamp < uint256(burner.lastPublicSwapAt()) + burner.PUBLIC_GAP()
        ) {
            error = ImdBuybackBurner.TooSoon.selector;
        } else if (amount == 0) {
            error = ImdBuybackBurner.BadAmount.selector;
        }
        vm.prank(actors[actorSeed % 3]);
        if (error != bytes4(0)) vm.expectRevert(error);
        uint256 out = burner.burnEth(amount, amount == 0 ? 1 : amount * RATE, block.timestamp);
        if (error == bytes4(0)) {
            assertEq(out, amount * RATE);
            ethSpent += amount;
            swapImdBurned += out;
        }
    }

    /// @dev Failed swaps must roll back the callback, token transfers, counters, and inactivity clocks.
    function rejectedSwap(uint256 seed) external {
        uint256 balance = address(burner).balance;
        uint64 curatorAt = burner.lastCuratorSwapAt();
        uint64 publicAt = burner.lastPublicSwapAt();
        uint256 mode = seed % 4;
        uint256 amount = balance == 0 ? 1 : bound(seed, 1, balance);
        uint256 minimum = 1;
        uint256 deadline = block.timestamp;
        bytes memory error;
        if (mode == 0) {
            deadline = block.timestamp - 1;
            error = abi.encodeWithSelector(ImdBuybackBurner.Expired.selector);
        } else if (mode == 1) {
            minimum = 0;
            error = abi.encodeWithSelector(ImdBuybackBurner.NoMinimum.selector);
        } else if (mode == 2 || balance == 0) {
            amount = balance + 1;
            error = abi.encodeWithSelector(ImdBuybackBurner.BadAmount.selector);
        } else {
            minimum = amount * RATE + 1;
            error = abi.encodeWithSelector(ImdBuybackBurner.TooLittleOut.selector, amount * RATE, minimum);
        }
        vm.prank(house.owner());
        vm.expectRevert(error);
        burner.burnEth(amount, minimum, deadline);
        assertEq(burner.lastCuratorSwapAt(), curatorAt, "failed swap resets no clock");
        assertEq(burner.lastPublicSwapAt(), publicAt);
        assertEq(address(burner).balance, balance);
    }

    function advanceTime(uint256 seed) external {
        uint256[5] memory steps = [uint256(1), 1 days - 1, 1 days, 60 days - 1, 60 days];
        vm.warp(block.timestamp + steps[seed % 5]);
    }

    function handover(uint256 seed) external {
        address next = makeAddr(string.concat("successor curator", vm.toString(seed % 3)));
        vm.prank(house.owner());
        house.transferOwnership(next);
        vm.prank(next);
        house.acceptOwnership();
    }

    function unauthorizedCallback(uint256 actorSeed, bytes calldata data) external {
        vm.prank(actors[actorSeed % 3]);
        vm.expectRevert(ImdBuybackBurner.NotPoolManager.selector);
        burner.unlockCallback(data);
    }
}

/// forge-config: default.invariant.runs = 96
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract BuybackConservationTest is Test {
    uint256 internal constant LIQUIDITY = 1e36;
    MockIMD internal imd;
    MockPoolManager internal pool;
    ImdBuybackBurner internal burner;
    BuybackConservationHandler internal handler;

    function setUp() public {
        vm.warp(1_700_000_000);
        address owner = makeAddr("buyback curator");
        imd = new MockIMD();
        ArtHouse house = new ArtHouse(owner, address(new ArtStorage(owner)), address(imd));
        pool = new MockPoolManager(50_000);
        imd.mint(address(pool), LIQUIDITY);
        burner = new ImdBuybackBurner(address(house), address(pool), address(imd), 10_000, 200, address(0));
        handler = new BuybackConservationHandler(house, burner, imd);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = handler.donateETH.selector;
        selectors[1] = handler.donateIMD.selector;
        selectors[2] = handler.burnIMD.selector;
        selectors[3] = handler.curatorSwap.selector;
        selectors[4] = handler.publicSwap.selector;
        selectors[5] = handler.rejectedSwap.selector;
        selectors[6] = handler.advanceTime.selector;
        selectors[7] = handler.handover.selector;
        selectors[8] = handler.unauthorizedCallback.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function test_oneWeiSwapAndDirectBurnConserveFunds() public {
        handler.donateETH(1, 0);
        handler.donateIMD(1);
        handler.burnIMD(0);
        handler.curatorSwap(1, true);
        assertEq(address(burner).balance, 0);
        assertEq(imd.balanceOf(address(burner)), 0);
        assertEq(imd.balanceOf(burner.DEAD()), 50_001);
        invariant_ethGoesOnlyToPool();
        invariant_imdGoesOnlyToBurnDestination();
    }

    function test_failedCuratorSwapDoesNotPostponePublicLiveness() public {
        handler.donateETH(1 ether, 0);
        uint256 idleAt = uint256(burner.lastCuratorSwapAt()) + burner.IDLE();
        vm.warp(idleAt - 1);
        handler.publicSwap(0); // rejected exactly one second before permission opens
        vm.warp(idleAt);
        handler.rejectedSwap(3); // callback ran, but slippage must roll back even the inactivity clock
        handler.publicSwap(0);
        assertEq(handler.ethSpent(), burner.PUBLIC_MAX());
        vm.warp(idleAt + burner.PUBLIC_GAP() - 1);
        handler.publicSwap(1); // rejected one second before the next public swap
        assertEq(handler.ethSpent(), burner.PUBLIC_MAX());
        vm.warp(idleAt + burner.PUBLIC_GAP());
        handler.publicSwap(1);
        assertEq(handler.ethSpent(), 2 * burner.PUBLIC_MAX());
        invariant_ethGoesOnlyToPool();
        invariant_imdGoesOnlyToBurnDestination();
    }

    function test_publicSwapDrainsRemainderBelowTheDailyCap() public {
        handler.donateETH(1, 0);
        vm.warp(uint256(burner.lastCuratorSwapAt()) + burner.IDLE());
        handler.publicSwap(2);
        assertEq(address(burner).balance, 0);
        assertEq(handler.ethSpent(), 1);
        assertEq(imd.balanceOf(burner.DEAD()), 50_000);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_fundingBurnRoundTrip(uint96 ethSeed, uint96 imdSeed) public {
        handler.donateETH(ethSeed, 0);
        handler.donateIMD(imdSeed);
        handler.handover(1);
        handler.burnIMD(1);
        handler.curatorSwap(ethSeed, true);
        assertEq(address(burner).balance, 0);
        assertEq(imd.balanceOf(address(burner)), 0);
        invariant_ethGoesOnlyToPool();
        invariant_imdGoesOnlyToBurnDestination();
    }

    function invariant_ethGoesOnlyToPool() public view {
        assertEq(address(burner).balance + handler.ethSpent(), handler.ethReceived());
        assertEq(address(pool).balance, handler.ethSpent());
        assertEq(burner.totalEthSwapped(), handler.ethSpent());
        assertFalse(pool.unlocked(), "flash accounting closes after every swap");
    }

    function invariant_imdGoesOnlyToBurnDestination() public view {
        uint256 burned = handler.directImdBurned() + handler.swapImdBurned();
        assertEq(imd.balanceOf(burner.DEAD()), burned);
        assertEq(burner.totalImdBurned(), burned);
        assertEq(imd.balanceOf(address(burner)) + handler.directImdBurned(), handler.imdReceived());
        assertEq(imd.balanceOf(address(pool)) + handler.swapImdBurned(), LIQUIDITY);
        assertEq(handler.swapImdBurned(), handler.ethSpent() * 50_000);
    }
}
