// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TwoStepOwnable} from "./base/TwoStepOwnable.sol";
import {ReentrancyGuard} from "./base/ReentrancyGuard.sol";
import {HolderGate} from "./base/HolderGate.sol";
import {SSTORE2} from "./libs/SSTORE2.sol";
import {Clones} from "./libs/Clones.sol";
import {IArtHouse, IArtifactsPiece, Traits} from "./interfaces/Interfaces.sol";

/// @notice THE SOURCE (ARTIFACTS piece 256): stores the rules' renderer page (SSTORE2) and THE SOURCE's seed,
/// encrypted, locks both forever with a commitment to the seed's key, and sells the single lot by an ascending ETH
/// auction whose proceeds go through the Proof House ledger. The curator delivers the key to the winner once,
/// wrapped to their viewing key; the winner alone decides whether to reveal it.
///
/// The seed is stored as seed XOR keccak256(K ‖ uint256(0)), with K a random 256-bit key and the commitment
/// keccak256(K). Revealing publishes K; the piece then serves the renderer page drawing THE SOURCE from its seed.
contract ArtifactsSource is TwoStepOwnable, ReentrancyGuard, HolderGate {
    uint256 public constant SOURCE_ID = 256;
    uint256 public constant MIN_RAISE_BPS = 500; // each bid beats the high bid by 5%
    uint256 public constant EXTENSION = 10 minutes;
    /// @notice Anyone can close the auction once it ends. If it still isn't closed this long after the end (closing
    /// failed, or nobody did), the winning bid can be taken back and the auction is void.
    uint256 public constant SETTLE_GRACE = 7 days;

    IArtHouse public immutable house;
    /// @notice The locked ArtifactsPiece THE SOURCE is a runtime copy of. Set once by the curator after the launch (the
    /// piece is deployed outside IMD's one launch transaction, which EIP-7825 caps at 2^24 gas); the auction cannot
    /// open without it.
    address public pieceImplementation;

    // ---------- the renderer and the sealed seed ----------
    address[] private _chunks; // the renderer page: ARTIFACTS' rules.js in an HTML page, up to where the seed goes
    uint256 public rendererSize;
    bool public locked;
    bytes32 public sealedSeed; // THE SOURCE's seed XOR keccak256(K ‖ uint256(0))
    bytes32 public keyCommitment; // keccak256(K)
    bool public keyDelivered; // the curator's one delivery of K to the winner

    // ---------- auction ----------
    uint256 public reserve;
    uint64 public endTime;
    bool public auctionOpen;
    /// @notice When the auction (re)opened: the holders window (HolderGate) runs from here.
    uint64 public auctionStart;
    bool public settled;
    address public highBidder;
    uint256 public highBid;
    address public highBroker;
    mapping(address => uint256) public refunds;
    address public pieceContract;

    event RendererChunkStored(uint256 index, address pointer, uint256 size);
    event Locked(bytes32 rendererHash, uint256 rendererSize, bytes32 sealedSeed, bytes32 keyCommitment);
    event KeyDelivered(address indexed owner);
    event AuctionSet(uint256 reserve, uint64 endTime);
    event Bid(address indexed bidder, address indexed broker, uint256 amount, uint64 endTime);
    event RefundWithdrawn(address indexed bidder, uint256 amount);
    event Settled(address indexed winner, uint256 amount, address piece);
    event AuctionVoided(address indexed bidder, uint256 amount);
    event PieceImplementationSet(address implementation);

    error IsLocked();
    error NotLocked();
    error EmptyRenderer();
    error AuctionLive();
    error AuctionNotOpen();
    error AuctionEnded();
    error AuctionNotEnded();
    error BadEndTime();
    error BidTooLow();
    error AlreadySettled();
    error NoBids();
    error NothingToWithdraw();
    error TransferFailed();
    error NoCommitment();
    error NotSettled();
    error AlreadyDelivered();
    error NotRegistered();
    error NoPieceImplementation();
    error PieceImplementationAlreadySet();

    constructor(address owner_, address house_) TwoStepOwnable(owner_) {
        if (house_ == address(0)) revert ZeroAddress();
        house = IArtHouse(house_);
    }

    /// @notice The locked ArtifactsPiece implementation (deployed by the curator after the launch, with the launched
    /// KeyProof): set once, so what settlement copies can never change. Required before the auction opens.
    function setPieceImplementation(address implementation) external onlyOwner {
        if (pieceImplementation != address(0)) revert PieceImplementationAlreadySet();
        if (implementation.code.length == 0) revert NoPieceImplementation();
        pieceImplementation = implementation;
        emit PieceImplementationSet(implementation);
    }

    // ---------- the renderer and the sealed seed (from the artist's offline ceremony) ----------

    function storeRendererChunk(bytes calldata data) external onlyOwner {
        if (locked) revert IsLocked();
        if (data.length == 0) revert EmptyRenderer();
        address ptr = SSTORE2.write(data);
        _chunks.push(ptr);
        rendererSize += data.length;
        emit RendererChunkStored(_chunks.length - 1, ptr, data.length);
    }

    /// @notice Drops every stored chunk so the upload can start over (only while unlocked).
    function resetRenderer() external onlyOwner {
        if (locked) revert IsLocked();
        delete _chunks;
        rendererSize = 0;
    }

    /// @notice Locks the renderer and THE SOURCE's sealed seed forever, with the commitment keccak256(K) to the key
    /// that opens the seed.
    function lock(bytes32 sealedSeed_, bytes32 keyCommitment_) external onlyOwner {
        if (locked) revert IsLocked();
        if (_chunks.length == 0) revert EmptyRenderer();
        if (keyCommitment_ == bytes32(0)) revert NoCommitment();
        locked = true;
        sealedSeed = sealedSeed_;
        keyCommitment = keyCommitment_;
        emit Locked(rendererHash(), rendererSize, sealedSeed_, keyCommitment_);
    }

    function rendererChunks() external view returns (address[] memory) {
        return _chunks;
    }

    function renderer() public view returns (bytes memory data) {
        data = new bytes(rendererSize);
        uint256 offset;
        for (uint256 i; i < _chunks.length; ++i) {
            uint256 dest;
            assembly ("memory-safe") {
                dest := add(add(data, 32), offset)
            }
            offset += SSTORE2.copyTo(_chunks[i], dest);
        }
    }

    function rendererHash() public view returns (bytes32) {
        return keccak256(renderer());
    }

    // ---------- the key ----------

    /// @notice The curator's single delivery of K to THE SOURCE's owner after settlement, wrapped to the viewing key
    /// they registered on THE SOURCE's contract. Later owners receive K from the owner before them (re-wrap after a
    /// transfer, or the keyed escrow), never from the curator.
    function deliverKey(bytes calldata wrapped) external onlyOwner {
        if (!settled) revert NotSettled();
        if (keyDelivered) revert AlreadyDelivered();
        keyDelivered = true;
        IArtifactsPiece piece = IArtifactsPiece(pieceContract);
        piece.rewrapFor(wrapped);
        emit KeyDelivered(piece.ownerOf(1));
    }

    // ---------- auction ----------

    /// @notice Opens (or re-opens, if no bid came) the single-lot auction. Needs the renderer and seed locked, and
    /// this contract set up in the house as a sale module and its collection, so the winning bid can always settle.
    function setAuction(uint256 reserve_, uint64 endTime_) external onlyOwner {
        if (!locked) revert NotLocked();
        if (!house.canRecordSale(address(this))) revert NotRegistered();
        if (pieceImplementation == address(0)) revert NoPieceImplementation();
        if (settled) revert AlreadySettled();
        if (highBidder != address(0)) revert AuctionLive();
        if (endTime_ <= block.timestamp) revert BadEndTime();
        if (reserve_ == 0) revert BidTooLow();
        reserve = reserve_;
        endTime = endTime_;
        auctionOpen = true;
        auctionStart = uint64(block.timestamp);
        emit AuctionSet(reserve_, endTime_);
    }

    /// @notice Holders first: for `seconds_` from when the auction opens, only holders of an identity.md seat or of
    /// at least `minBalance` of `token` may bid. Until the first bid, so a wrong address can always be corrected.
    function setGate(address seats, address token, uint256 minBalance, uint64 seconds_) external onlyOwner {
        if (settled) revert AlreadySettled();
        if (highBidder != address(0)) revert AuctionLive();
        _setGate(seats, token, minBalance, seconds_);
    }

    /// @notice Members of a membership contract (Cncptl Prspctv's points) may also bid in the holders window. All zero
    /// for none. Until the first bid, as the gate.
    function setMemberGate(address member, bytes4 call_, uint256 minimum) external onlyOwner {
        if (settled) revert AlreadySettled();
        if (highBidder != address(0)) revert AuctionLive();
        _setMemberGate(member, call_, minimum);
    }

    /// @notice Until this time only holders may bid; 0 when there is no holders window or the auction has not opened.
    function gateEndsAt() external view returns (uint256) {
        return gateSeconds == 0 || auctionStart == 0 ? 0 : uint256(auctionStart) + gateSeconds;
    }

    function bid(address broker) external payable nonReentrant {
        if (!auctionOpen) revert AuctionNotOpen();
        if (block.timestamp >= endTime) revert AuctionEnded();
        if (_inGate(auctionStart) && !holdsSeat(msg.sender) && !holdsToken(msg.sender) && !isMember(msg.sender)) {
            revert NotEligible();
        }
        if (msg.value < reserve) revert BidTooLow();
        // the 5% raise rounds up, so a bid must strictly exceed the high bid even at dust sizes
        if (highBid != 0 && msg.value < (highBid * (10_000 + MIN_RAISE_BPS) + 9_999) / 10_000) revert BidTooLow();
        if (highBidder != address(0)) refunds[highBidder] += highBid;
        highBidder = msg.sender;
        highBid = msg.value;
        highBroker = broker;
        if (endTime - block.timestamp < EXTENSION) endTime = uint64(block.timestamp + EXTENSION);
        emit Bid(msg.sender, broker, msg.value, endTime);
    }

    function withdrawRefund() external nonReentrant {
        uint256 amount = refunds[msg.sender];
        if (amount == 0) revert NothingToWithdraw();
        refunds[msg.sender] = 0;
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit RefundWithdrawn(msg.sender, amount);
    }

    /// @notice After the end: proceeds go through the ledger and THE SOURCE's contract is deployed to the winner.
    function settle() external nonReentrant returns (address piece) {
        if (!auctionOpen) revert AuctionNotOpen();
        if (block.timestamp < endTime) revert AuctionNotEnded();
        if (settled) revert AlreadySettled();
        if (highBidder == address(0)) revert NoBids();
        settled = true;
        auctionOpen = false;
        // THE SOURCE gets its own full contract (a byte copy of ArtifactsPiece's runtime, not an EIP-1167 proxy),
        // so building the revealed tokenURI (the renderer page, ≈12.8 KB, plus the seed) skips a proxy hop.
        piece = Clones.copyCode(pieceImplementation);
        pieceContract = piece;
        IArtifactsPiece(piece)
            .initialize(
                address(this),
                address(house),
                SOURCE_ID,
                highBidder,
                Traits({
                    title: unicode"ARTIFACTS  ◆  MASTER", palette: "PRISM", colourCount: 9, direction: "DIAGONAL"
                }),
                address(0),
                keyCommitment,
                "",
                true,
                bytes32(0)
            );
        house.recordSale{value: highBid}(address(this), highBidder, highBroker); // last: it pays the artist
        emit Settled(highBidder, highBid, piece);
    }

    /// @notice An auction still not closed SETTLE_GRACE after its end: the winning bid goes back to the bidder (to
    /// withdraw, as any refund), the auction is void, and the curator may open it again. Anyone may call it.
    function voidUnsettled() external {
        if (!auctionOpen || settled) revert AuctionNotOpen();
        if (highBidder == address(0)) revert NoBids();
        if (block.timestamp < uint256(endTime) + SETTLE_GRACE) revert AuctionNotEnded();
        address bidder = highBidder;
        uint256 amount = highBid;
        refunds[bidder] += amount;
        highBidder = address(0);
        highBid = 0;
        highBroker = address(0);
        auctionOpen = false;
        emit AuctionVoided(bidder, amount);
    }

    /// @notice True only for THE SOURCE's own piece contract (the ledger checks resale callers with it).
    function isPiece(address piece) external view returns (bool) {
        return piece != address(0) && piece == pieceContract;
    }

    function auctionState()
        external
        view
        returns (bool open, bool isSettled, uint256 reserve_, uint64 endTime_, address bidder, uint256 amount)
    {
        return (auctionOpen, settled, reserve, endTime, highBidder, highBid);
    }
}
