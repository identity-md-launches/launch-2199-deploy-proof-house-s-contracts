// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {ArtStorage} from "../src/ArtStorage.sol";
import {ArtHouse} from "../src/ArtHouse.sol";
import {ArtifactsPiece} from "../src/ArtifactsPiece.sol";
import {ArtifactsFactory} from "../src/ArtifactsFactory.sol";
import {ArtifactsSource} from "../src/ArtifactsSource.sol";
import {KeyProof} from "../src/KeyProof.sol";
import {Traits} from "../src/interfaces/Interfaces.sol";
import {MockIMD, MockVRFCoordinator} from "./mocks/Mocks.sol";
import {Deploy} from "../script/Deploy.s.sol";

/// @dev Deploys the launch set exactly as the deploy script does, with mocks for IMD and the VRF coordinator.
abstract contract Fixture is Test {
    address internal curator = makeAddr("curator");
    address internal artist = makeAddr("artist");
    address internal broker = makeAddr("broker");
    address internal alice = makeAddr("alice");
    /// @dev THE SOURCE's test content key K and its commitment keccak256(K) (a test value, not a ceremony key).
    bytes32 internal constant SOURCE_KEY = keccak256("ARTIFACTS test source key");
    bytes32 internal SOURCE_COMMITMENT = keccak256(abi.encodePacked(SOURCE_KEY));
    /// @dev THE SOURCE's test seed, and how it is stored: seed XOR keccak256(K ‖ uint256(0)).
    bytes32 internal constant SOURCE_SEED = keccak256("ARTIFACTS test source seed");
    bytes32 internal SEALED_SEED = SOURCE_SEED ^ keccak256(abi.encodePacked(SOURCE_KEY, uint256(0)));
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    MockIMD internal imd;
    MockVRFCoordinator internal vrf;
    ArtStorage internal store;
    ArtHouse internal house;
    ArtifactsPiece internal pieceImpl;
    ArtifactsFactory internal factory;
    ArtifactsSource internal source;
    KeyProof internal keyProof;

    bytes32 internal constant KEY_HASH = keccak256("keyhash");
    uint256 internal constant SUB_ID = 777;

    function setUp() public virtual {
        imd = new MockIMD();
        vrf = new MockVRFCoordinator();
        Deploy.Deployed memory d = new Deploy().deploy(curator, address(imd));
        store = d.artStorage;
        house = d.artHouse;
        pieceImpl = d.artifactsPiece;
        factory = d.artifactsFactory;
        source = d.artifactsSource;
        keyProof = d.keyProof;

        // after-launch curator steps
        vm.startPrank(curator);
        store.setHouse(address(house));
        factory.setPieceImplementation(address(pieceImpl));
        source.setPieceImplementation(address(pieceImpl));
        house.approveArtist(artist, "Myles");
        house.setBroker(broker, true);
        house.setSaleModule(address(factory), true);
        house.setSaleModule(address(source), true);
        house.registerModuleCollection(address(factory), artist);
        house.registerModuleCollection(address(source), artist);
        factory.configureVRF(address(vrf), KEY_HASH, SUB_ID, false);
        vm.stopPrank();

        vm.deal(alice, 1000 ether);
        vm.deal(bob, 1000 ether);
        vm.deal(carol, 1000 ether);
    }

    uint256 internal constant SECP_N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

    /// @dev A wrapped key as a seller's tool makes one for `p`'s current sale, with the proof postEscrowKey takes
    /// (KeyProof.knowsWrap): E = e·G for a scalar from `seed`, and `seed`'s hash as the masked key (whether it opens
    /// is only the buyer's to find out). Reads the escrow, so call it before any vm.prank or vm.expectRevert.
    function _sellerKey(ArtifactsPiece p, string memory seed)
        internal
        returns (bytes memory wrapped, address r, uint256 z)
    {
        uint256 e = _eOf(seed);
        wrapped = _wrappedOf(seed);
        (,, address buyer,,,,,, bytes32 vk,) = p.escrow();
        (r, z) = _wrapProof(address(p), buyer, vk, wrapped, e);
    }

    /// @dev The Schnorr proof that the poster knows e: R = k·G (as its address), z = k + c·e.
    function _wrapProof(address p, address buyer, bytes32 vk, bytes memory wrapped, uint256 e)
        internal
        view
        returns (address r, uint256 z)
    {
        uint256 k = uint256(keccak256(abi.encodePacked("k", wrapped, e))) % (SECP_N - 1) + 1;
        r = vm.addr(k);
        uint256 c = uint256(
            keccak256(
                abi.encodePacked("Proof House key wrap v2 proof", block.chainid, p, buyer, vk, keccak256(wrapped), r)
            )
        ) % SECP_N;
        z = addmod(k, mulmod(c, e, SECP_N), SECP_N);
    }

    /// @dev The wrapped key _sellerKey makes for a seed (what the piece holds once the sale releases).
    function _wrappedOf(string memory seed) internal returns (bytes memory) {
        return
            abi.encodePacked(
                uint8(2), vm.createWallet(_eOf(seed)).publicKeyX, keccak256(abi.encodePacked("masked", seed))
            );
    }

    /// @dev The wrapping scalar for a seed, with E = e·G's y even (as KeyProof reads E back from its x).
    function _eOf(string memory seed) internal returns (uint256 e) {
        e = uint256(keccak256(abi.encodePacked("e", seed))) % (SECP_N - 1) + 1;
        if (vm.createWallet(e).publicKeyY & 1 == 1) e = SECP_N - e;
    }

    /// @dev The secret behind _vk(label), for the point with an even y.
    function _secretOf(string memory label) internal returns (uint256 b) {
        Vm.Wallet memory w = vm.createWallet(label);
        b = w.publicKeyY & 1 == 1 ? SECP_N - w.privateKey : w.privateKey;
    }

    /// @dev The buyer's proof that the key _sellerKey(p, seed) made doesn't open (KeyProof.isFake), made from scalars
    /// alone: every point is a multiple of G (E = e·G, S = b·e·G, A1 = w·G, A2 = w·e·G, X = c·b·e·G).
    function _fakeProof(address p, address buyer, string memory vkLabel, string memory seed)
        internal
        returns (KeyProof.Proof memory pr)
    {
        uint256 b = _secretOf(vkLabel);
        uint256 e = _eOf(seed);
        uint256 w = uint256(keccak256(abi.encodePacked("w", seed))) % (SECP_N - 1) + 1;
        Vm.Wallet memory S = vm.createWallet(mulmod(b, e, SECP_N));
        Vm.Wallet memory A1 = vm.createWallet(w);
        Vm.Wallet memory A2 = vm.createWallet(mulmod(w, e, SECP_N));
        uint256 c = uint256(
            keccak256(
                abi.encodePacked(
                    "Proof House fake key v2",
                    block.chainid,
                    p,
                    buyer,
                    vm.createWallet(vkLabel).publicKeyX,
                    vm.createWallet(e).publicKeyX,
                    S.publicKeyX,
                    S.publicKeyY,
                    A1.publicKeyX,
                    A1.publicKeyY,
                    A2.publicKeyX,
                    A2.publicKeyY
                )
            )
        ) % SECP_N;
        Vm.Wallet memory X = vm.createWallet(mulmod(c, mulmod(b, e, SECP_N), SECP_N));
        pr = KeyProof.Proof(
            S.publicKeyX,
            S.publicKeyY,
            A1.publicKeyX,
            A1.publicKeyY,
            A2.publicKeyX,
            A2.publicKeyY,
            X.publicKeyX,
            X.publicKeyY,
            addmod(w, mulmod(c, b, SECP_N), SECP_N)
        );
    }

    /// @dev The seller posts a key with its proof and `deposit`.
    function _postKey(ArtifactsPiece p, address seller, uint256 deposit) internal {
        (bytes memory wrapped, address r, uint256 z) = _sellerKey(p, "key");
        vm.prank(seller);
        p.postEscrowKey{value: deposit}(wrapped, r, z);
    }

    /// @dev The same, expected to revert with `err`.
    function _postKeyReverts(ArtifactsPiece p, address seller, uint256 deposit, bytes4 err) internal {
        (bytes memory wrapped, address r, uint256 z) = _sellerKey(p, "key");
        vm.prank(seller);
        vm.expectRevert(err);
        p.postEscrowKey{value: deposit}(wrapped, r, z);
    }

    /// @dev All the ETH the artist has received: paid straight to the payout address at each sale, plus anything
    /// waiting in the ledger (a payout address that couldn't take it).
    function _artistEth() internal view returns (uint256) {
        address to = house.artistPayout(artist);
        return house.balances(artist, address(0)) + (to == address(0) ? artist : to).balance;
    }

    /// @dev A valid version 2 viewing key for a label (a secp256k1 point's x): what a buyer registers on a piece.
    function _vk(string memory label) internal returns (bytes32) {
        return bytes32(vm.createWallet(label).publicKeyX);
    }

    function _traits(uint256 id) internal pure returns (Traits memory) {
        // piece 3 matches the reference framed-003.svg (DRIFT / PRISM 3C HORIZONTAL); others vary the title
        return Traits({title: id == 3 ? "DRIFT" : "FLUX", palette: "PRISM", colourCount: 3, direction: "HORIZONTAL"});
    }

    function _publishAll() internal {
        vm.startPrank(curator);
        for (uint256 i = 1; i <= 255; ++i) {
            factory.setPiece(i, _traits(i), abi.encodePacked("ciphertext", i), keccak256(abi.encodePacked("K", i)));
        }
        factory.lock();
        vm.stopPrank();
    }

    function _openSale(uint256 price) internal {
        vm.startPrank(curator);
        factory.setPrice(price);
        factory.setSaleOpen(true);
        vm.stopPrank();
    }

    /// @dev buy as `buyer` with `broker_` and fulfil VRF with `word`; returns the edition assigned.
    function _buyAndAssign(address buyer, address broker_, uint256 word) internal returns (uint256 edition) {
        uint256 p = factory.price();
        vm.prank(buyer);
        uint256 id = factory.buy{value: p}(broker_);
        vrf.fulfill(id, word);
        edition = factory.requestEdition(id);
    }

    function _claim(address buyer, uint256 edition) internal returns (ArtifactsPiece piece) {
        vm.prank(buyer);
        factory.registerViewingKey(keccak256(abi.encodePacked("vk", buyer)));
        vm.prank(curator);
        factory.postWrappedKey(edition, abi.encodePacked("wrapped", edition));
        vm.prank(buyer);
        piece = ArtifactsPiece(factory.claim(edition));
    }
}
