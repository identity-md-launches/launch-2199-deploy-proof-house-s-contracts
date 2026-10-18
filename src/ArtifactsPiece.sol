// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC721Lite} from "./base/ERC721Lite.sol";
import {ReentrancyGuard} from "./base/ReentrancyGuard.sol";
import {SSTORE2} from "./libs/SSTORE2.sol";
import {Encoding} from "./libs/Encoding.sol";
import {Seal} from "./libs/Seal.sol";
import {IArtHouse, ISourceStore, Traits} from "./interfaces/Interfaces.sol";
import {KeyProof} from "./KeyProof.sol";

/// @notice One ARTIFACTS piece: a one-token ERC-721 + ERC-2981, deployed as an independent runtime copy at claim.
/// Holds the ciphertext pointer, public traits, key commitment and the current owner's wrapped content key.
/// Runs its own keyed resale escrow, where a key that doesn't open can be proven fake (KeyProof) and costs the seller a
/// deposit, and re-keying after plain transfers. THE SOURCE (piece 256) adds a one-time
/// reveal: its owner publishes its content key, which opens its stored seed; from then on tokenURI serves the
/// on-chain renderer page drawing it from that seed.
contract ArtifactsPiece is ERC721Lite, ReentrancyGuard {
    uint256 public constant TOKEN_ID = 1;
    uint256 public constant ESCROW_TIMEOUT = 72 hours; // the buyer's time to check a key, from when it arrives
    uint16 public constant DEPOSIT_BPS = 1_000; // the seller's deposit sent with the key: 10% of the price
    uint256 public constant SELLER_WINDOW = 24 hours; // from paying, only the seller may end a sale (key or refund)
    uint16 public constant ROYALTY_BPS = 750;
    uint16 public constant RESALE_BROKER_BPS = 250; // 2.5% of a resale to the broker who brought the buyer
    uint16 public constant BPS = 10_000;
    /// @notice Closes THE SOURCE's renderer page after its seed (tools/source/renderer.js SUFFIX, byte for byte).
    string public constant RENDER_SUFFIX =
        '"),true);document.body.innerHTML=s;try{if(parent!==window)parent.postMessage({artifacts:s},"*")}catch(e){}</script></body></html>';

    /// @notice Checks fake-key proofs; shared by every piece (an immutable preserved in each runtime copy).
    KeyProof public immutable keyProof;

    address public controller; // ArtifactsFactory (editions) or ArtifactsSource (THE SOURCE)
    IArtHouse public house;
    uint256 public pieceId;
    bool public isSource;
    bool public revealed;
    bytes32 public revealKey; // THE SOURCE's content key K, published by its owner at reveal

    Traits private _traits;
    address public ciphertextPointer;
    bytes32 public commitment;
    bytes public wrappedKey; // wrapped to the current owner's viewing key; cleared on plain transfer
    address public previousOwner; // may post a re-wrapped key after a plain transfer

    mapping(address => bytes32) public viewingKeyOf;
    mapping(address => uint256) public pendingWithdrawals;

    struct Escrow {
        uint256 price;
        address seller;
        address buyer;
        uint64 paidAt;
        bool keyPosted;
        bytes key;
        address broker; // named by the buyer; paid at release if the ledger counts it as a broker
        uint64 keyPostedAt; // when the key arrived: the buyer's 72 hours to check it count from here
        bytes32 viewingKey; // the buyer's viewing key for this purchase: the key is wrapped to it, a proof uses it
        uint256 deposit; // the seller's, sent with the key: theirs again at release, the buyer's if the key is fake
    }

    Escrow public escrow;

    event ViewingKeyRegistered(address indexed account, bytes32 key);
    event WrappedKeyPosted(address indexed by, address indexed forOwner);
    event Listed(address indexed seller, uint256 price);
    event Delisted();
    event EscrowPaid(address indexed buyer, uint256 price);
    event EscrowKeyPosted();
    event EscrowCancelled(address indexed buyer);
    event EscrowRefunded(address indexed buyer, uint256 amount);
    event EscrowProvenFake(address indexed buyer, uint256 amount);
    event EscrowReleased(
        address indexed seller,
        address indexed buyer,
        uint256 price,
        uint256 royalty,
        address broker,
        uint256 brokerShare
    );
    event Revealed(bytes32 key);
    event Withdrawn(address indexed to, uint256 amount);

    error AlreadyInitialized();
    error NotController();
    error NotTokenOwner();
    error NotPreviousOwner();
    error NotSource();
    error AlreadyRevealed();
    error NotListed();
    error AlreadyListed();
    error EscrowActive();
    error NoEscrowBuyer();
    error NotEscrowBuyer();
    error NotSeller();
    error KeyAlreadyPosted();
    error KeyNotPosted();
    error TooEarly();
    error WrongPrice();
    error NoViewingKey();
    error TransferFailed();
    error NothingToWithdraw();
    error NotRevealable();
    error WrongKey();
    error KeyOpens();
    error NoKeyProof();
    error BadWrappedKey();

    constructor(address keyProof_) {
        if (keyProof_ == address(0)) revert NoKeyProof();
        keyProof = KeyProof(keyProof_);
        controller = address(this); // lock the implementation; only runtime copies can be initialised
    }

    // ---------- initialisation (by the controller, at claim / settlement) ----------

    function initialize(
        address controller_,
        address house_,
        uint256 pieceId_,
        address to,
        Traits calldata traits_,
        address ciphertext_,
        bytes32 commitment_,
        bytes calldata wrappedKey_,
        bool isSource_,
        bytes32 ownerViewingKey_
    ) external {
        if (controller != address(0)) revert AlreadyInitialized();
        if (msg.sender != controller_ || controller_.code.length == 0) revert NotController();
        controller = controller_;
        house = IArtHouse(house_);
        pieceId = pieceId_;
        isSource = isSource_;
        _traits = traits_;
        ciphertextPointer = ciphertext_;
        commitment = commitment_;
        wrappedKey = wrappedKey_;
        _name = isSource_ ? unicode"ARTIFACTS · THE SOURCE" : string.concat("ARTIFACTS #", Encoding.pad3(pieceId_));
        _symbol = "ARTIFACTS";
        // the viewing key the owner registered with the controller, so a key can be sent here later too
        if (ownerViewingKey_ != bytes32(0)) {
            viewingKeyOf[to] = ownerViewingKey_;
            emit ViewingKeyRegistered(to, ownerViewingKey_);
        }
        _mint(to, TOKEN_ID);
    }

    // ---------- views ----------

    function traits() external view returns (Traits memory) {
        return _traits;
    }

    function ciphertext() external view returns (bytes memory) {
        return ciphertextPointer == address(0) ? bytes("") : SSTORE2.read(ciphertextPointer);
    }

    function royaltyInfo(uint256, uint256 salePrice) public view returns (address, uint256) {
        return house.royaltyFor(controller, salePrice);
    }

    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return interfaceId == 0x2a55205a || super.supportsInterface(interfaceId);
    }

    // ---------- keys ----------

    function registerViewingKey(bytes32 key) external {
        if (key == bytes32(0)) revert NoViewingKey();
        viewingKeyOf[msg.sender] = key;
        emit ViewingKeyRegistered(msg.sender, key);
    }

    /// @notice After a plain transfer the previous owner re-wraps K to the new owner's viewing key and posts it here.
    /// The controller may too (the curator, through it): THE SOURCE's delivery, an edition claimed before its key
    /// arrived, or a piece whose previous owner never re-keyed it. One shot: the key slot must be empty, and posting
    /// ends the previous owner's right, so a delivered key can never be overwritten.
    function rewrapFor(bytes calldata wrapped) external {
        if (msg.sender != previousOwner && msg.sender != controller) revert NotPreviousOwner();
        if (wrappedKey.length != 0) revert KeyAlreadyPosted();
        if (wrapped.length == 0) revert KeyNotPosted();
        address current = ownerOf(TOKEN_ID);
        if (viewingKeyOf[current] == bytes32(0)) revert NoViewingKey();
        wrappedKey = wrapped;
        delete previousOwner;
        emit WrappedKeyPosted(msg.sender, current);
    }

    // ---------- keyed resale escrow ----------

    function list(uint256 price) external {
        if (msg.sender != ownerOf(TOKEN_ID)) revert NotTokenOwner();
        if (escrow.seller != address(0)) revert AlreadyListed();
        if (price == 0) revert WrongPrice();
        escrow.price = price;
        escrow.seller = msg.sender;
        emit Listed(msg.sender, price);
    }

    function delist() external {
        if (msg.sender != escrow.seller) revert NotSeller();
        if (escrow.buyer != address(0)) revert EscrowActive();
        delete escrow;
        emit Delisted();
    }

    /// @notice The buyer pays the listed price into escrow and registers their viewing key for this purchase in the
    /// same step (a version 2 key, so a fake key can be proven), naming the broker who brought them (or zero).
    function buy(bytes32 viewingKey, address broker) external payable nonReentrant {
        Escrow storage e = escrow;
        if (e.seller == address(0)) revert NotListed();
        if (e.buyer != address(0)) revert EscrowActive();
        if (msg.value != e.price) revert WrongPrice();
        if (!keyProof.isViewingKey(viewingKey)) revert NoViewingKey();
        if (msg.sender == e.seller) revert NotEscrowBuyer();
        e.buyer = msg.sender;
        e.paidAt = uint64(block.timestamp);
        e.broker = broker;
        e.viewingKey = viewingKey;
        viewingKeyOf[msg.sender] = viewingKey;
        emit ViewingKeyRegistered(msg.sender, viewingKey);
        emit EscrowPaid(msg.sender, msg.value);
    }

    /// @notice The seller's deposit with the key: DEPOSIT_BPS of the price.
    function depositFor(uint256 price) public pure returns (uint256) {
        return (price * DEPOSIT_BPS) / BPS;
    }

    /// @notice The seller sends the piece's key, wrapped to the buyer's viewing key for this purchase, with a deposit
    /// of 10% of the price: back to the seller with the payment at release, the buyer's if the key is proven fake.
    /// (`r`, `z`) prove the seller made this wrapped key for this buyer and key (KeyProof.knowsWrap).
    function postEscrowKey(bytes calldata wrapped, address r, uint256 z) external payable {
        Escrow storage e = escrow;
        if (msg.sender != e.seller) revert NotSeller();
        if (e.buyer == address(0)) revert NoEscrowBuyer();
        if (e.keyPosted) revert KeyAlreadyPosted();
        if (!keyProof.knowsWrap(wrapped, e.viewingKey, e.buyer, r, z)) revert BadWrappedKey();
        if (msg.value != depositFor(e.price)) revert WrongPrice();
        e.keyPosted = true;
        e.key = wrapped;
        e.keyPostedAt = uint64(block.timestamp);
        e.deposit = msg.value;
        emit EscrowKeyPosted();
    }

    /// @notice The buyer proves the key they were sent doesn't open the piece (see KeyProof): they get their payment
    /// and the seller's deposit, and the seller keeps the piece. Any time until the payment is released. A key that
    /// opens can never be proven fake, so an honest seller can't lose their deposit.
    function proveFakeKey(KeyProof.Proof calldata proof) external nonReentrant {
        Escrow storage e = escrow;
        if (msg.sender != e.buyer) revert NotEscrowBuyer();
        if (!e.keyPosted) revert KeyNotPosted();
        if (!keyProof.isFake(e.key, pieceId, e.viewingKey, commitment, msg.sender, proof)) revert KeyOpens();
        uint256 amount = e.price + e.deposit;
        delete escrow; // the listing ends with it; the seller may list again
        pendingWithdrawals[msg.sender] += amount;
        emit EscrowProvenFake(msg.sender, amount);
    }

    /// @notice The seller may end a sale before sending the key: the buyer gets it all back and the listing ends. Once
    /// the key is sent, only release or a proven fake key ends the sale, so a seller can't dodge a proof.
    function refundBuyer() external nonReentrant {
        Escrow storage e = escrow;
        if (msg.sender != e.seller) revert NotSeller();
        if (e.buyer == address(0)) revert NoEscrowBuyer();
        if (e.keyPosted) revert KeyAlreadyPosted();
        address buyer = e.buyer;
        uint256 amount = e.price;
        delete escrow;
        pendingWithdrawals[buyer] += amount;
        emit EscrowRefunded(buyer, amount);
    }

    /// @notice The buyer may cancel and take their payment back if the key hasn't come SELLER_WINDOW after paying. Not
    /// sooner: a key in a pending transaction is readable, and a buyer could take it and cancel ahead of it.
    function cancel() external nonReentrant {
        Escrow storage e = escrow;
        if (msg.sender != e.buyer) revert NotEscrowBuyer();
        if (e.keyPosted) revert KeyAlreadyPosted();
        if (block.timestamp < e.paidAt + SELLER_WINDOW) revert TooEarly();
        uint256 refund = e.price;
        address buyer = e.buyer;
        e.buyer = address(0);
        e.paidAt = 0;
        e.broker = address(0);
        pendingWithdrawals[buyer] += refund;
        emit EscrowCancelled(buyer);
    }

    /// @notice Release: by the buyer once the key is posted, or by anyone 72 hours after the key arrived. The seller
    /// gets the price (less royalty and broker share) and their deposit back.
    function release() external nonReentrant {
        Escrow storage e = escrow;
        if (e.buyer == address(0)) revert NoEscrowBuyer();
        if (!e.keyPosted) revert KeyNotPosted();
        if (msg.sender != e.buyer && block.timestamp < e.keyPostedAt + ESCROW_TIMEOUT) revert TooEarly();
        address seller = e.seller;
        address buyer = e.buyer;
        address broker = e.broker;
        uint256 price = e.price;
        uint256 deposit = e.deposit;
        bytes memory key = e.key;
        delete escrow;
        (address royaltyTo, uint256 royalty) = royaltyInfo(TOKEN_ID, price);
        if (royaltyTo == address(0)) royalty = 0;
        uint256 brokerShare;
        if (broker != seller && _isBroker(broker)) brokerShare = (price * RESALE_BROKER_BPS) / BPS;
        else broker = address(0);
        pendingWithdrawals[seller] += price - royalty - brokerShare + deposit;
        // The piece and its key are the buyer's before any outside call (the ledger pays the artist directly), so
        // nothing called from there can list, move or reveal it as the seller's.
        _releasing = true;
        _transfer(seller, buyer, TOKEN_ID);
        _releasing = false;
        wrappedKey = key;
        delete previousOwner; // the escrowed key is delivered; the paid seller keeps no re-key right
        // The royalty and broker share go to the ledger, so each party withdraws once from one place. If the
        // ledger refuses (e.g. this piece's module was revoked), they stay here as pull payments instead.
        uint256 toLedger = royalty + brokerShare;
        if (toLedger > 0) {
            try house.recordResale{value: toLedger}(broker, royalty, brokerShare) {}
            catch {
                if (royalty > 0) pendingWithdrawals[royaltyTo] += royalty;
                if (brokerShare > 0) pendingWithdrawals[broker] += brokerShare;
            }
        }
        emit EscrowReleased(seller, buyer, price, royalty, broker, brokerShare);
    }

    function _isBroker(address broker) private view returns (bool) {
        if (broker == address(0)) return false;
        try house.isEligibleBroker(broker) returns (bool ok) {
            return ok;
        } catch {
            return false;
        }
    }

    function withdraw() external nonReentrant {
        uint256 amount = pendingWithdrawals[msg.sender];
        if (amount == 0) revert NothingToWithdraw();
        pendingWithdrawals[msg.sender] = 0;
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit Withdrawn(msg.sender, amount);
    }

    /// @dev Plain transfers stay allowed, except while a buyer's payment sits in escrow (only release() moves a
    /// token then). A transfer clears the wrapped key and remembers who can re-wrap it; a listing without a
    /// buyer is dropped.
    function _beforeTransfer(address from, address, uint256) internal override {
        if (from == address(0)) return;
        if (!_releasing) {
            if (escrow.buyer != address(0)) revert EscrowActive();
            delete escrow;
        }
        previousOwner = from;
        delete wrappedKey;
    }

    bool private _releasing;

    // ---------- THE SOURCE ----------

    /// @notice THE SOURCE's owner reveals it to everyone, once and forever, by publishing its content key K, which
    /// opens its stored seed. The key must match the commitment locked before the auction. Not while a buyer's payment
    /// sits in escrow: they paid for it sealed. A listing with no buyer yet is taken down, since it was listed sealed.
    function reveal(bytes32 key) external {
        if (!isSource) revert NotSource();
        if (msg.sender != ownerOf(TOKEN_ID)) revert NotTokenOwner();
        if (revealed) revert AlreadyRevealed();
        if (!ISourceStore(controller).locked()) revert NotRevealable();
        if (escrow.buyer != address(0)) revert EscrowActive();
        if (keccak256(abi.encodePacked(key)) != commitment) revert WrongKey();
        revealKey = key;
        revealed = true;
        if (escrow.seller != address(0)) {
            delete escrow;
            emit Delisted();
        }
        emit Revealed(key);
    }

    // ---------- metadata ----------

    function tokenURI(uint256 tokenId) external view returns (string memory) {
        ownerOf(tokenId);
        if (isSource && revealed) return _revealedURI();
        string memory svg = isSource
            ? Seal.source()
            : Seal.edition(_traits.title, _traits.palette, _traits.colourCount, _traits.direction, pieceId);
        bytes memory json = abi.encodePacked(
            '{"name":"',
            _name,
            '","description":"',
            isSource
                ? "THE SOURCE. The full prism the 255 editions are fragments of. Sealed until its owner reveals it."
                : "An ARTIFACTS edition. Encrypted generative art; only the owner can render it. The seal shows its public traits.",
            '","attributes":[',
            _attributes(),
            '],"image":"data:image/svg+xml;base64,',
            Encoding.base64(bytes(svg)),
            '"}'
        );
        return string.concat("data:application/json;base64,", Encoding.base64(json));
    }

    function _attributes() private view returns (string memory) {
        if (isSource) return '{"trait_type":"Piece","value":"THE SOURCE"}';
        return string.concat(
            '{"trait_type":"Title","value":"',
            _traits.title,
            '"},{"trait_type":"Palette","value":"',
            _traits.palette,
            '"},{"trait_type":"Colours","value":',
            Encoding.toString(_traits.colourCount),
            '},{"trait_type":"Direction","value":"',
            _traits.direction,
            '"},{"trait_type":"Edition","value":"',
            Encoding.pad3(pieceId),
            '"}'
        );
    }

    /// @notice THE SOURCE's seed, once revealed (zero before): the stored sealed seed XOR keccak256(K ‖ uint256(0)).
    function revealedSeed() public view returns (bytes32) {
        if (!revealed) return bytes32(0);
        return ISourceStore(controller).sealedSeed() ^ keccak256(abi.encodePacked(revealKey, uint256(0)));
    }

    /// @dev After the reveal the seal stays the still image (marketplace thumbnails), and animation_url is the
    /// on-chain renderer page drawing THE SOURCE from its seed: the rules, stored once, plus the seed.
    function _revealedURI() private view returns (string memory) {
        string memory seedHex = Encoding.toHexString(revealedSeed());
        address[] memory chunks = ISourceStore(controller).rendererChunks();
        bytes memory page;
        for (uint256 i; i < chunks.length; ++i) {
            page = bytes.concat(page, SSTORE2.read(chunks[i]));
        }
        page = bytes.concat(page, bytes(seedHex), bytes(RENDER_SUFFIX));
        bytes memory json = abi.encodePacked(
            '{"name":"',
            _name,
            '","description":"THE SOURCE, revealed by its owner. Drawn from its seed by the ARTIFACTS rules stored on-chain.",',
            '"attributes":[{"trait_type":"Piece","value":"THE SOURCE"},{"trait_type":"Seed","value":"',
            seedHex,
            '"}],"image":"data:image/svg+xml;base64,',
            Encoding.base64(bytes(Seal.sourceRevealed())),
            '","animation_url":"data:text/html;base64,',
            Encoding.base64(page),
            '"}'
        );
        return string.concat("data:application/json;base64,", Encoding.base64(json));
    }
}
