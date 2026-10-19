// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ArtStorage} from "../src/ArtStorage.sol";
import {ArtHouse} from "../src/ArtHouse.sol";
import {ArtifactsPiece} from "../src/ArtifactsPiece.sol";
import {KeyProof} from "../src/KeyProof.sol";
import {ArtifactsFactory} from "../src/ArtifactsFactory.sol";
import {ArtifactsSource} from "../src/ArtifactsSource.sol";

/// @notice Deployment order and constructor wiring, as the launch manifest performs it. Reviewable only: this
/// contract holds no keys and broadcasts nothing; tests call `deploy` directly with their own owner and IMD.
contract Deploy {
    /// @dev Launch constants. The owner is the curator named by the launch; IMD is the existing ERC-20.
    address public constant SEPOLIA_OWNER = 0xd3e32C1eBEa3a675EffCaAcAf89196948Abd1386;
    address public constant SEPOLIA_IMD = 0x44a1Cd38474FB1748400E7DEb5F8D786ccE3F89A;

    struct Deployed {
        ArtStorage artStorage;
        ArtHouse artHouse;
        ArtifactsPiece artifactsPiece;
        KeyProof keyProof;
        ArtifactsFactory artifactsFactory;
        ArtifactsSource artifactsSource;
    }

    function deploy(address owner, address imd) public returns (Deployed memory d) {
        d.artStorage = new ArtStorage(owner);
        d.artHouse = new ArtHouse(owner, address(d.artStorage), imd);
        d.keyProof = new KeyProof();
        d.artifactsPiece = new ArtifactsPiece(address(d.keyProof));
        d.artifactsFactory = new ArtifactsFactory(owner, address(d.artHouse));
        d.artifactsSource = new ArtifactsSource(owner, address(d.artHouse));
        // the piece implementation is deployed outside IMD's launch transaction (EIP-7825 caps it at 2^24 gas) and
        // the owner connects it once: factory.setPieceImplementation / source.setPieceImplementation
    }

    function deploySepolia() external returns (Deployed memory) {
        return deploy(SEPOLIA_OWNER, SEPOLIA_IMD);
    }
}
