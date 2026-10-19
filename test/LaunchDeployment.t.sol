// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ArtStorage} from "../src/ArtStorage.sol";
import {ArtHouse} from "../src/ArtHouse.sol";
import {ArtCollection} from "../src/ArtCollection.sol";
import {KeyProof} from "../src/KeyProof.sol";
import {ArtifactsPiece} from "../src/ArtifactsPiece.sol";
import {ArtifactsFactory} from "../src/ArtifactsFactory.sol";
import {ArtifactsSource} from "../src/ArtifactsSource.sol";
import {BrokerPass} from "../src/BrokerPass.sol";
import {SubmissionReviews} from "../src/SubmissionReviews.sol";
import {TwoStepOwnable} from "../src/base/TwoStepOwnable.sol";

/// @dev Local stand-in for CREATE2 deployment only; it has no configuration or ownership powers.
contract LaunchDeploymentHarness {
    function deployAll(bytes[] memory codes) external returns (address[] memory result) {
        result = new address[](codes.length);
        for (uint256 i; i < codes.length; ++i) {
            bytes memory code = codes[i];
            require(code.length <= 49_152, "init code too large");
            bytes32 salt = bytes32(i + 1);
            address deployed;
            assembly ("memory-safe") {
                deployed := create2(0, add(code, 32), mload(code), salt)
            }
            require(deployed != address(0), "constructor failed");
            result[i] = deployed;
        }
    }
}

contract LaunchDeploymentTest is Test {
    address internal constant OWNER = 0xd3e32C1eBEa3a675EffCaAcAf89196948Abd1386;
    address internal constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address internal constant SEATS = address(bytes20(hex"0000ec93127baa929e58e97dd0095a2bfb38ec1d"));

    function _codes(LaunchDeploymentHarness harness, bool emptyDependencies)
        internal
        returns (bytes[] memory codes, address[] memory predicted)
    {
        codes = new bytes[](7);
        predicted = new address[](7);
        // Every dependency is code-less when constructor isolation is requested. These are test inputs only.
        address empty = makeAddr("empty constructor dependency");
        assertEq(empty.code.length, 0);
        // ArtifactsPiece is no longer in the launch: the curator deploys it after and connects it once (EIP-7825).
        for (uint256 i; i < 7; ++i) {
            address storage_ = emptyDependencies ? empty : predicted[0];
            address house_ = emptyDependencies ? empty : predicted[1];
            address factory_ = emptyDependencies ? empty : predicted[3];
            address source_ = emptyDependencies ? empty : predicted[4];
            if (i == 0) codes[i] = bytes.concat(vm.getCode("ArtStorage.sol:ArtStorage"), abi.encode(OWNER));
            if (i == 1) codes[i] = bytes.concat(vm.getCode("ArtHouse.sol:ArtHouse"), abi.encode(OWNER, storage_, IMD));
            if (i == 2) codes[i] = vm.getCode("KeyProof.sol:KeyProof");
            if (i == 3) {
                codes[i] = bytes.concat(vm.getCode("ArtifactsFactory.sol:ArtifactsFactory"), abi.encode(OWNER, house_));
            }
            if (i == 4) {
                codes[i] = bytes.concat(vm.getCode("ArtifactsSource.sol:ArtifactsSource"), abi.encode(OWNER, house_));
            }
            if (i == 5) {
                codes[i] = bytes.concat(vm.getCode("BrokerPass.sol:BrokerPass"), abi.encode(SEATS, factory_, source_));
            }
            if (i == 6) {
                codes[i] = bytes.concat(
                    vm.getCode("SubmissionReviews.sol:SubmissionReviews"), abi.encode(house_, SEATS, factory_, source_)
                );
            }
            predicted[i] = address(
                uint160(
                    uint256(
                        keccak256(abi.encodePacked(bytes1(0xff), address(harness), bytes32(i + 1), keccak256(codes[i])))
                    )
                )
            );
        }
    }

    function _scan(address target) internal view {
        bytes memory code = target.code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576, "runtime exceeds EIP-170");
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden application opcode");
        }
    }

    function _deploy(bool emptyDependencies) internal returns (address[] memory deployed) {
        vm.chainId(1);
        LaunchDeploymentHarness harness = new LaunchDeploymentHarness();
        (bytes[] memory codes, address[] memory predicted) = _codes(harness, emptyDependencies);
        deployed = harness.deployAll(codes);
        assertEq(deployed, predicted);
        for (uint256 i; i < deployed.length; ++i) {
            _scan(deployed[i]);
        }
        uint256[4] memory owned = [uint256(0), 1, 3, 4];
        for (uint256 i; i < owned.length; ++i) {
            TwoStepOwnable target = TwoStepOwnable(deployed[owned[i]]);
            assertEq(target.owner(), OWNER);
            assertEq(target.pendingOwner(), address(0));
            vm.prank(address(harness));
            vm.expectRevert(TwoStepOwnable.NotOwner.selector);
            target.transferOwnership(address(harness));
            vm.prank(OWNER);
            (bool ok,) = address(target).call(abi.encodeWithSignature("renounceOwnership()"));
            assertFalse(ok);
        }
    }

    function test_allSevenConstructorsAcceptCodeLessDependencies() public {
        _deploy(true);
    }

    /// @dev Reproduces 5fab1872a919 and a85c2484bf00, preserving the brief's explicit owner configuration flow.
    function test_manifestOrderAndOwnerConfigurationRemainIntact() public {
        address[] memory deployed = _deploy(false);
        ArtStorage store = ArtStorage(deployed[0]);
        ArtHouse house = ArtHouse(deployed[1]);
        ArtifactsFactory factory = ArtifactsFactory(deployed[3]);
        ArtifactsSource source = ArtifactsSource(deployed[4]);
        BrokerPass pass = BrokerPass(deployed[5]);
        SubmissionReviews reviews = SubmissionReviews(deployed[6]);
        assertEq(address(house.artStorage()), address(store));
        assertEq(house.imd(), IMD);
        assertEq(address(factory.house()), address(house));
        assertEq(factory.pieceImplementation(), address(0));
        assertEq(address(source.house()), address(house));
        assertEq(source.pieceImplementation(), address(0));
        // the curator's step after the launch: the piece implementation, with the launched KeyProof, set once
        vm.startPrank(OWNER);
        ArtifactsPiece piece = new ArtifactsPiece(deployed[2]);
        _scan(address(piece));
        vm.expectRevert(ArtifactsFactory.NoPieceImplementation.selector);
        factory.setPieceImplementation(makeAddr("no code"));
        factory.setPieceImplementation(address(piece));
        source.setPieceImplementation(address(piece));
        vm.expectRevert(ArtifactsFactory.PieceImplementationAlreadySet.selector);
        factory.setPieceImplementation(address(piece));
        vm.expectRevert(ArtifactsSource.PieceImplementationAlreadySet.selector);
        source.setPieceImplementation(address(piece));
        vm.stopPrank();
        vm.prank(makeAddr("not the owner"));
        vm.expectRevert(TwoStepOwnable.NotOwner.selector);
        factory.setPieceImplementation(address(piece));
        assertEq(address(piece.keyProof()), deployed[2]);
        assertEq(factory.pieceImplementation(), address(piece));
        assertEq(source.pieceImplementation(), address(piece));
        assertEq(address(pass.seats()), SEATS);
        assertEq(pass.factory(), address(factory));
        assertEq(pass.source(), address(source));
        assertEq(address(reviews.house()), address(house));
        assertEq(address(reviews.seats()), SEATS);
        assertEq(reviews.factory(), address(factory));
        assertEq(reviews.source(), address(source));

        // ArtHouse's additional template is intentional and must itself satisfy the runtime checks.
        address template = house.collectionImplementation();
        _scan(template);
        assertEq(address(ArtCollection(template).house()), template);
        for (uint256 i; i < deployed.length; ++i) {
            assertTrue(template != deployed[i]);
        }

        assertEq(store.house(), address(0));
        assertEq(house.brokerPass(), address(0));
        assertFalse(house.canRecordSale(address(factory)));
        assertFalse(house.canRecordSale(address(source)));
        assertFalse(pass.claimsOpen());
        vm.expectRevert(ArtifactsFactory.SaleClosed.selector);
        factory.buy(address(0));
        vm.expectRevert(BrokerPass.ClaimsNotOpen.selector);
        pass.claimWithSeat(1);

        address artist = makeAddr("launch artist");
        vm.startPrank(OWNER);
        house.approveArtist(artist, "Artist");
        address col = house.createCollection("Plain", "PLN", artist);
        bytes memory svg = bytes("<svg/>");
        house.registerPiece(col, 0, keccak256(svg), "T", "D");
        vm.expectRevert(ArtStorage.NotHouse.selector);
        house.uploadChunk(col, 0, 0, svg);
        store.setHouse(address(house));
        house.uploadChunk(col, 0, 0, svg);
        house.setSaleModule(address(factory), true);
        house.registerModuleCollection(address(factory), artist);
        house.setSaleModule(address(source), true);
        house.registerModuleCollection(address(source), artist);
        house.setBrokerPass(address(pass));
        pass.setClaimsOpenAt(uint64(block.timestamp));
        vm.stopPrank();
        assertEq(store.read(col, 0), svg);
        assertTrue(house.canRecordSale(address(factory)));
        assertTrue(house.canRecordSale(address(source)));
        assertTrue(pass.claimsOpen());
    }
}
