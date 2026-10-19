// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {ArtStorage} from "../src/ArtStorage.sol";
import {ArtHouse} from "../src/ArtHouse.sol";
import {KeyProof} from "../src/KeyProof.sol";
import {ArtifactsPiece} from "../src/ArtifactsPiece.sol";
import {ArtifactsFactory} from "../src/ArtifactsFactory.sol";
import {ArtifactsSource} from "../src/ArtifactsSource.sol";
import {BrokerPass} from "../src/BrokerPass.sol";
import {SubmissionReviews} from "../src/SubmissionReviews.sol";

/// @dev The same loop as IMD's protected harness (ContractsDeploymentProbe.deployAll): every application of the
/// manifest in one call, as ProjectFactory.launchContracts deploys them in one transaction.
contract OneTxLauncher {
    function deployAll(bytes[] memory codes, bytes32[] memory salts) external returns (address[] memory deployed) {
        deployed = new address[](codes.length);
        for (uint256 i; i < codes.length; ++i) {
            bytes memory code = codes[i];
            bytes32 salt = salts[i];
            address created;
            assembly ("memory-safe") {
                created := create2(0, add(code, 32), mload(code), salt)
            }
            require(created != address(0) && created.code.length > 0, "constructor failed");
            deployed[i] = created;
        }
    }
}

/// @notice Finding 180a7e1d59e1: since Fusaka (EIP-7825) no Ethereum mainnet transaction may use more than 2^24 gas.
/// The launch manifest (launch.json: 7 contracts, ArtifactsPiece deployed by the curator after it) must fit in one
/// such transaction, intrinsic calldata cost included, with margin for the factory's own bookkeeping.
contract LaunchGasCapTest is Test {
    uint256 internal constant TX_GAS_CAP = 16_777_216;
    /// @dev Room left for ProjectFactory.launchContracts' own work around the CREATE2s (records, events).
    uint256 internal constant FACTORY_MARGIN = 1_000_000;
    address internal constant OWNER = address(0xd3e32C1eBEa3a675EffCaAcAf89196948Abd1386);
    address internal constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address internal constant SEATS = 0x0000eC93127BAA929E58E97dd0095A2BFb38ec1D;

    function _predict(address deployer, bytes32 salt, bytes memory code) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, keccak256(code))))));
    }

    function test_launchManifestFitsInOneMainnetTransaction() public {
        OneTxLauncher launcher = new OneTxLauncher();
        bytes[] memory codes = new bytes[](7);
        bytes32[] memory salts = new bytes32[](7);
        address[] memory a = new address[](7);
        for (uint256 i; i < 7; ++i) {
            salts[i] = keccak256(abi.encode("launch", i));
        }
        codes[0] = bytes.concat(type(ArtStorage).creationCode, abi.encode(OWNER));
        a[0] = _predict(address(launcher), salts[0], codes[0]);
        codes[1] = bytes.concat(type(ArtHouse).creationCode, abi.encode(OWNER, a[0], IMD));
        a[1] = _predict(address(launcher), salts[1], codes[1]);
        codes[2] = type(KeyProof).creationCode;
        a[2] = _predict(address(launcher), salts[2], codes[2]);
        codes[3] = bytes.concat(type(ArtifactsFactory).creationCode, abi.encode(OWNER, a[1]));
        a[3] = _predict(address(launcher), salts[3], codes[3]);
        codes[4] = bytes.concat(type(ArtifactsSource).creationCode, abi.encode(OWNER, a[1]));
        a[4] = _predict(address(launcher), salts[4], codes[4]);
        codes[5] = bytes.concat(type(BrokerPass).creationCode, abi.encode(SEATS, a[3], a[4]));
        a[5] = _predict(address(launcher), salts[5], codes[5]);
        codes[6] = bytes.concat(type(SubmissionReviews).creationCode, abi.encode(a[1], SEATS, a[3], a[4]));

        bytes memory data = abi.encodeCall(OneTxLauncher.deployAll, (codes, salts));
        uint256 intrinsic = 21_000;
        for (uint256 i; i < data.length; ++i) {
            intrinsic += data[i] == 0 ? 4 : 16;
        }
        uint256 before = gasleft();
        address[] memory deployed = launcher.deployAll(codes, salts);
        uint256 execution = before - gasleft();
        assertEq(deployed[6], _predict(address(launcher), salts[6], codes[6]));
        console2.log("calldata bytes", data.length);
        console2.log("execution gas", execution);
        console2.log("total gas", intrinsic + execution);
        assertLe(intrinsic + execution + FACTORY_MARGIN, TX_GAS_CAP, "the launch transaction exceeds EIP-7825's cap");

        // the curator's own transaction after the launch: the piece implementation, then connected once
        vm.startPrank(OWNER);
        ArtifactsPiece piece = new ArtifactsPiece(a[2]);
        ArtifactsFactory(deployed[3]).setPieceImplementation(address(piece));
        ArtifactsSource(deployed[4]).setPieceImplementation(address(piece));
        vm.stopPrank();
        assertEq(ArtifactsFactory(deployed[3]).pieceImplementation(), address(piece));
        assertEq(ArtifactsSource(deployed[4]).pieceImplementation(), address(piece));
    }
}
