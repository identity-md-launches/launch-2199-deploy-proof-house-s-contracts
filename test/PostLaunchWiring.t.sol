// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./Fixture.sol";
import {ArtifactsFactory} from "../src/ArtifactsFactory.sol";
import {ArtifactsSource} from "../src/ArtifactsSource.sol";
import {ArtifactsPiece} from "../src/ArtifactsPiece.sol";
import {TwoStepOwnable} from "../src/base/TwoStepOwnable.sol";
import {Traits} from "../src/interfaces/Interfaces.sol";
import {Clones} from "../src/libs/Clones.sol";

/// @dev Makes a runtime copy of a piece the way the factory does, outside the factory.
contract CopyMaker {
    function copy(address implementation) external returns (address) {
        return Clones.copyCode(implementation);
    }

    function init(ArtifactsPiece p, address house, address to) external {
        p.initialize(
            address(this),
            house,
            1,
            to,
            Traits({title: "FAKE", palette: "PRISM", colourCount: 3, direction: "HORIZONTAL"}),
            address(0),
            bytes32(0),
            "",
            false,
            bytes32(0)
        );
    }
}

/// @notice The post-launch wiring the curator does by hand: the piece implementation (set once, after the launch,
/// outside IMD's transaction), who may set it across an ownership handover, and what a claim copies from it.
/// The setter's weak validation (code length only) is reported in .imd-findings.json, not asserted here.
contract PostLaunchWiringTest is Fixture {
    /// forge-config: default.fuzz.runs = 256
    function testFuzz_onlyTheOwnerSetsThePieceImplementation(address caller) public {
        if (caller == curator) caller = alice;
        ArtifactsFactory f = new ArtifactsFactory(curator, address(house));
        ArtifactsSource s = new ArtifactsSource(curator, address(house));
        vm.startPrank(caller);
        vm.expectRevert(TwoStepOwnable.NotOwner.selector);
        f.setPieceImplementation(address(pieceImpl));
        vm.expectRevert(TwoStepOwnable.NotOwner.selector);
        s.setPieceImplementation(address(pieceImpl));
        vm.stopPrank();
        assertEq(f.pieceImplementation(), address(0));
        assertEq(s.pieceImplementation(), address(0));
    }

    /// @dev A nominated owner has no power until it accepts; once it does, the old owner has none.
    function test_handoverDecidesWhoSetsThePieceImplementation() public {
        ArtifactsFactory f = new ArtifactsFactory(curator, address(house));
        ArtifactsSource s = new ArtifactsSource(curator, address(house));
        vm.startPrank(curator);
        f.transferOwnership(bob);
        s.transferOwnership(bob);
        vm.stopPrank();

        vm.startPrank(bob);
        vm.expectRevert(TwoStepOwnable.NotOwner.selector);
        f.setPieceImplementation(address(pieceImpl));
        vm.expectRevert(TwoStepOwnable.NotOwner.selector);
        s.setPieceImplementation(address(pieceImpl));
        vm.stopPrank();

        vm.prank(carol);
        vm.expectRevert(TwoStepOwnable.NotPendingOwner.selector);
        f.acceptOwnership();

        vm.startPrank(bob);
        f.acceptOwnership();
        s.acceptOwnership();
        vm.stopPrank();
        assertEq(f.owner(), bob);
        assertEq(f.pendingOwner(), address(0));

        vm.startPrank(curator);
        vm.expectRevert(TwoStepOwnable.NotOwner.selector);
        f.setPieceImplementation(address(pieceImpl));
        vm.expectRevert(TwoStepOwnable.NotOwner.selector);
        s.setPieceImplementation(address(pieceImpl));
        vm.stopPrank();

        vm.startPrank(bob);
        f.setPieceImplementation(address(pieceImpl));
        s.setPieceImplementation(address(pieceImpl));
        // and once set it stays, for the new owner too
        vm.expectRevert(ArtifactsFactory.PieceImplementationAlreadySet.selector);
        f.setPieceImplementation(address(f));
        vm.expectRevert(ArtifactsSource.PieceImplementationAlreadySet.selector);
        s.setPieceImplementation(address(s));
        vm.stopPrank();
    }

    /// @dev The implementation the curator deploys from launch.piece.json is locked to itself: nobody initialises it.
    /// forge-config: default.fuzz.runs = 256
    function testFuzz_theImplementationCannotBeInitialised(address caller) public {
        assertEq(pieceImpl.controller(), address(pieceImpl));
        assertEq(address(pieceImpl.keyProof()), address(keyProof));
        vm.prank(caller);
        vm.expectRevert(ArtifactsPiece.AlreadyInitialized.selector);
        pieceImpl.initialize(
            caller, address(house), 1, caller, _traits(1), address(0), bytes32(0), "", false, bytes32(0)
        );
    }

    /// @dev A copy made outside the factory: an EOA cannot claim to be its controller, nor name the factory; a
    /// contract can initialise its own copy, and the factory and ledger do not take it as a piece.
    function test_aCopyMadeOutsideTheFactoryIsNotAPiece() public {
        CopyMaker maker = new CopyMaker();
        ArtifactsPiece copy = ArtifactsPiece(maker.copy(address(pieceImpl)));
        assertEq(address(copy).codehash, address(pieceImpl).codehash);
        assertEq(copy.controller(), address(0));

        vm.startPrank(alice);
        vm.expectRevert(ArtifactsPiece.NotController.selector);
        copy.initialize(alice, address(house), 1, alice, _traits(1), address(0), bytes32(0), "", false, bytes32(0));
        vm.expectRevert(ArtifactsPiece.NotController.selector);
        copy.initialize(
            address(factory), address(house), 1, alice, _traits(1), address(0), bytes32(0), "", false, bytes32(0)
        );
        vm.stopPrank();

        maker.init(copy, address(house), alice);
        assertEq(copy.ownerOf(copy.TOKEN_ID()), alice);
        assertFalse(factory.isPiece(address(copy)));
        assertEq(factory.pieceContract(1), address(0));
        vm.expectRevert(ArtifactsPiece.AlreadyInitialized.selector);
        maker.init(copy, address(house), bob);
    }

    /// @dev A claimed edition is a byte-for-byte runtime copy of the connected implementation, keeping its KeyProof.
    function test_aClaimedEditionIsAnExactCopyOfTheImplementation() public {
        _publishAll();
        _openSale(1 ether);
        uint256 edition = _buyAndAssign(alice, address(0), 42);
        ArtifactsPiece piece = _claim(alice, edition);
        assertEq(address(piece).codehash, address(pieceImpl).codehash);
        assertEq(address(piece).code.length, address(pieceImpl).code.length);
        assertEq(address(piece.keyProof()), address(keyProof));
        assertEq(piece.controller(), address(factory));
        assertTrue(factory.isPiece(address(piece)));
        assertEq(piece.ownerOf(piece.TOKEN_ID()), alice);
        // the implementation itself is untouched by the claim
        assertEq(pieceImpl.controller(), address(pieceImpl));
    }

    /// @dev Closing and reopening the sale keeps the implementation; it can never be swapped mid-sale.
    function test_implementationSurvivesASaleCloseAndReopen() public {
        _publishAll();
        _openSale(1 ether);
        vm.startPrank(curator);
        factory.setSaleOpen(false);
        ArtifactsPiece other = new ArtifactsPiece(address(keyProof));
        vm.expectRevert(ArtifactsFactory.PieceImplementationAlreadySet.selector);
        factory.setPieceImplementation(address(other));
        factory.setSaleOpen(true);
        vm.stopPrank();
        assertEq(factory.pieceImplementation(), address(pieceImpl));
        uint256 edition = _buyAndAssign(bob, address(0), 7);
        ArtifactsPiece piece = _claim(bob, edition);
        assertEq(address(piece).codehash, address(pieceImpl).codehash);
    }
}
