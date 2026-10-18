// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TwoStepOwnable} from "./base/TwoStepOwnable.sol";
import {ReentrancyGuard} from "./base/ReentrancyGuard.sol";
import {HolderGate} from "./base/HolderGate.sol";
import {SSTORE2} from "./libs/SSTORE2.sol";
import {Clones} from "./libs/Clones.sol";
import {IArtHouse, IArtifactsPiece, IVRFCoordinatorV2Plus, Traits} from "./interfaces/Interfaces.sol";

/// @notice Sells the 255 ARTIFACTS editions at one ETH price through the Proof House ledger, assigns editions
/// with Chainlink VRF v2.5, and deploys each buyer's independent piece contract at claim.
contract ArtifactsFactory is TwoStepOwnable, ReentrancyGuard, HolderGate {
    uint256 public constant EDITIONS = 255;
    /// @notice Most editions one wallet can buy, across all its purchases.
    uint256 public constant MAX_PER_WALLET = 5;
    /// @notice Bounds for the VRF callback's gas limit. One assignment writes a handful of new storage slots, whose
    /// price changes with Ethereum's upgrades (≈150k gas before Glamsterdam's repricing, ≈670k after, as measured on
    /// Sepolia), so the curator can set it; Chainlink charges the gas actually used, not the limit.
    uint32 public constant VRF_CALLBACK_GAS_MIN = 150_000;
    uint32 public constant VRF_CALLBACK_GAS_MAX = 2_500_000; // Chainlink's maximum
    uint16 public constant VRF_CONFIRMATIONS = 3;
    /// @dev Blocks a VRF request Chainlink still holds must wait before it can be asked again (~25h at 12s blocks).
    /// Chainlink keeps an unanswered request (e.g. an underfunded subscription) for up to 24 hours, then drops it, so
    /// nobody can watch its answer arrive and swap it for a fresh draw. A request the coordinator already answered
    /// whose callback failed (e.g. out of gas) will never answer again, so that one can be asked again at once.
    uint256 public constant VRF_RETRY_BLOCKS = 7_500;
    /// @dev The last resort for a draw Chainlink never answers (its service, the coordinator or the subscription gone):
    /// ~3 days after the purchase anyone may draw from the hash of a block a few blocks ahead, unknown when started.
    /// Counted from the purchase, so re-requests never push it back. Whoever builds that block could steer its hash;
    /// it is the last resort only, after three days without Chainlink.
    uint256 public constant FALLBACK_BLOCKS = 21_600;
    uint256 public constant FALLBACK_DELAY = 5;
    /// @dev EIP-2935: the hashes of the last 8,191 blocks, for a fallback finished after BLOCKHASH's 256. A started
    /// draw finishes with its block's hash whoever finishes it and whenever (within ~27 hours), so nobody can drop a
    /// result they dislike; only once that hash is gone too may it start again.
    address public constant BLOCK_HISTORY = 0x0000F90827F1C53a10cb7A02335B175320002935;
    /// @notice An edition whose key hasn't arrived 30 days after its draw may be claimed without it: the buyer holds
    /// the token, and the key can still be sent into the piece's own contract later.
    uint256 public constant KEY_WAIT = 30 days;

    IArtHouse public immutable house;
    address public immutable pieceImplementation;

    // ---------- piece publication (before the sale, then locked forever) ----------
    struct PieceData {
        Traits traits;
        address ciphertext;
        bytes32 commitment;
        bool set;
    }

    mapping(uint256 => PieceData) private _pieces;
    uint256 public piecesSet;
    bool public locked;

    // ---------- sale ----------
    uint256 public price;
    bool public saleOpen;
    bool public saleEnded; // set once by endSale: the edition sale is over for good, its supply final
    uint256 public sold; // purchases paid (VRF requested)
    uint256 public assigned; // editions assigned by VRF callbacks
    mapping(address => uint256) public mintedBy; // editions bought by each wallet, capped at MAX_PER_WALLET
    /// @notice When the sale first opened: the holders window (HolderGate) runs from here.
    uint64 public saleOpenedAt;
    /// @notice Mint phases, counted from when the sale first opens: up to phase1Cap editions per wallet (and per seat)
    /// for phase1Seconds, then up to phase2Cap until phase2Seconds more have passed, then MAX_PER_WALLET. Unset (0),
    /// the limit is MAX_PER_WALLET throughout. Set before the sale first opens.
    uint64 public phase1Seconds;
    uint64 public phase2Seconds;
    uint8 public phase1Cap;
    uint8 public phase2Cap;
    /// @notice Editions bought with each identity.md seat during the holders window, capped at MAX_PER_WALLET.
    mapping(uint256 => uint256) public mintedBySeat;

    // ---------- VRF ----------
    IVRFCoordinatorV2Plus public vrfCoordinator;
    bytes32 public vrfKeyHash;
    uint256 public vrfSubscriptionId;
    bool public vrfNativePayment;
    uint32 public vrfCallbackGas = 1_000_000;

    mapping(uint256 => address) public requestBuyer;
    mapping(uint256 => uint256) public requestEdition;
    mapping(uint256 => uint256) public requestBlock;
    /// @notice The block of the purchase a request serves, carried across re-requests (the fallback counts from it).
    mapping(uint256 => uint256) public purchaseBlock;
    mapping(uint16 => uint16) private _pool; // Fisher-Yates over 1..255, lazily initialised
    mapping(uint256 => address) public editionBuyer;
    mapping(address => uint256[]) private _editionsOf;
    mapping(uint256 => uint64) public editionAssignedAt;
    /// @notice A started fallback draw's block (see FALLBACK_BLOCKS); 0 when none.
    mapping(uint256 => uint256) public fallbackBlock;
    /// @notice The fallback draw under way (its request id; 0: none). One at a time, so editions are drawn in the
    /// order draws were started, before anyone could know their blocks' hashes: nobody can pick an order to suit them.
    uint256 public fallbackInFlight;
    /// @notice The block of Chainlink's latest answer. A fallback draw waits until Chainlink has answered nothing for
    /// FALLBACK_BLOCKS, so no answer can land between a fallback block's hash becoming known and its draw finishing.
    uint256 public lastAnsweredBlock;

    // ---------- claim ----------
    mapping(address => bytes32) public viewingKeyOf;
    mapping(uint256 => bytes) private _wrappedKey;
    mapping(uint256 => address) public pieceContract;
    /// @notice True for every piece contract this factory deployed (the ledger checks resale callers with it).
    mapping(address => bool) public isPiece;

    event PieceSet(uint256 indexed pieceId, bytes32 commitment, address ciphertext);
    event Locked();
    event PriceSet(uint256 price);
    event SaleOpenSet(bool open);
    event MintPhasesSet(uint64 phase1Seconds, uint8 phase1Cap, uint64 phase2Seconds, uint8 phase2Cap);
    event VRFConfigured(address coordinator, bytes32 keyHash, uint256 subscriptionId, bool nativePayment);
    event VRFCallbackGasSet(uint32 gas);
    event Purchased(address indexed buyer, address indexed broker, uint256 requestId, uint256 price);
    event EditionAssigned(uint256 indexed edition, address indexed buyer, uint256 requestId);
    event Rerequested(uint256 indexed oldRequestId, uint256 indexed newRequestId, address indexed buyer);
    event FallbackDrawStarted(uint256 indexed requestId, uint256 targetBlock);
    event ViewingKeyRegistered(address indexed account, bytes32 key);
    event WrappedKeyPosted(uint256 indexed edition);
    event Claimed(uint256 indexed edition, address indexed owner, address piece);
    event SaleEnded(uint256 editions);

    error BadPieceId();
    error IsLocked();
    error NotLocked();
    error NotAllSet();
    error SaleIsOpen();
    error SaleClosed();
    error WrongPrice();
    error SoldOut();
    error VRFNotConfigured();
    error VRFLocked();
    error BadCallbackGas();
    error LengthMismatch();
    error NotCoordinator();
    error UnknownRequest();
    error NotAssigned();
    error NotBuyer();
    error NoViewingKey();
    error KeyNotPosted();
    error AlreadyClaimed();
    error AlreadyFulfilled();
    error RequestTooRecent();
    error BadQuantity();
    error WalletLimit();
    error SeatLimit();
    error BadPhases();
    error SaleOver();
    error NeverOpened();
    error NothingToClaim();
    error FallbackPending();
    error FallbackBusy();
    error ChainlinkAnswering();
    error NoFallback();
    error FallbackNotReady();
    error FallbackMissed();

    constructor(address owner_, address house_, address pieceImplementation_) TwoStepOwnable(owner_) {
        if (house_ == address(0) || pieceImplementation_ == address(0)) revert ZeroAddress();
        house = IArtHouse(house_);
        pieceImplementation = pieceImplementation_;
    }

    // ---------- publication ----------

    /// @notice Curator publishes a piece's public traits, AES-256-GCM encrypted seed and keccak256(K). Re-settable
    /// until lock(); set once per id is counted.
    function setPiece(uint256 pieceId, Traits calldata traits, bytes calldata ciphertext, bytes32 commitment)
        external
        onlyOwner
    {
        if (locked) revert IsLocked();
        if (pieceId == 0 || pieceId > EDITIONS) revert BadPieceId();
        if (commitment == bytes32(0) || ciphertext.length == 0) revert BadPieceId();
        PieceData storage p = _pieces[pieceId];
        if (!p.set) {
            p.set = true;
            piecesSet += 1;
        }
        p.traits = traits;
        p.ciphertext = SSTORE2.write(ciphertext);
        p.commitment = commitment;
        emit PieceSet(pieceId, commitment, p.ciphertext);
    }

    function lock() external onlyOwner {
        if (locked) revert IsLocked();
        if (piecesSet != EDITIONS) revert NotAllSet();
        locked = true;
        emit Locked();
    }

    // ---------- sale control ----------

    function setPrice(uint256 newPrice) external onlyOwner {
        if (saleOpen) revert SaleIsOpen();
        if (newPrice == 0) revert WrongPrice();
        price = newPrice;
        emit PriceSet(newPrice);
    }

    function setSaleOpen(bool open) external onlyOwner {
        if (open) {
            if (saleEnded) revert SaleOver();
            if (!locked) revert NotLocked();
            if (price == 0) revert WrongPrice();
            if (address(vrfCoordinator) == address(0)) revert VRFNotConfigured();
            if (saleOpenedAt == 0) saleOpenedAt = uint64(block.timestamp);
        }
        saleOpen = open;
        emit SaleOpenSet(open);
    }

    /// @notice Ends the edition sale for good: it closes and can never open again, so the editions sold so far are the
    /// whole supply. Draws already paid for still complete, and every buyer can still claim. Only once the sale has
    /// opened; one way.
    function endSale() external onlyOwner {
        if (saleOpenedAt == 0) revert NeverOpened();
        if (saleEnded) revert SaleOver();
        saleEnded = true;
        if (saleOpen) {
            saleOpen = false;
            emit SaleOpenSet(false);
        }
        emit SaleEnded(sold);
    }

    /// @notice Chainlink VRF v2.5: coordinator, key hash, the curator's subscription id and how it pays. Can be set, and
    /// corrected, until the edition sale first opens; from then on it is locked forever, so once anyone can mint, nobody
    /// (the curator included) can change where the randomness comes from. No draw is requested before the sale opens.
    function configureVRF(address coordinator, bytes32 keyHash, uint256 subscriptionId, bool nativePayment)
        external
        onlyOwner
    {
        if (saleOpenedAt != 0) revert VRFLocked();
        if (coordinator == address(0) || keyHash == bytes32(0) || subscriptionId == 0) revert VRFNotConfigured();
        vrfCoordinator = IVRFCoordinatorV2Plus(coordinator);
        vrfKeyHash = keyHash;
        vrfSubscriptionId = subscriptionId;
        vrfNativePayment = nativePayment;
        emit VRFConfigured(coordinator, keyHash, subscriptionId, nativePayment);
    }

    /// @notice The gas Chainlink gives each draw's callback. Raise it if Ethereum reprices storage (a callback that
    /// runs out fails, and the draw must be re-requested); lower it to need a smaller subscription minimum, but only
    /// before the sale opens: after, it can only go up, so a limit between the cheapest and dearest draw can never
    /// filter which editions get assigned.
    function setVRFCallbackGas(uint32 gas) external onlyOwner {
        if (gas < VRF_CALLBACK_GAS_MIN || gas > VRF_CALLBACK_GAS_MAX) revert BadCallbackGas();
        if (saleOpenedAt != 0 && gas < vrfCallbackGas) revert BadCallbackGas();
        vrfCallbackGas = gas;
        emit VRFCallbackGasSet(gas);
    }

    // ---------- holders first ----------

    /// @notice Holders first: for `seconds_` from when the sale opens, only holders of an identity.md seat (buying
    /// with buyWithSeat) or of at least `minBalance` of `token` may buy. Set before the sale first opens.
    function setGate(address seats, address token, uint256 minBalance, uint64 seconds_) external onlyOwner {
        if (saleOpenedAt != 0) revert SaleIsOpen();
        _setGate(seats, token, minBalance, seconds_);
    }

    /// @notice Members of a membership contract (Cncptl Prspctv's points) may also buy in the holders window, as a
    /// token holder does (buy, buyMany). All zero for none. Set before the sale first opens.
    function setMemberGate(address member, bytes4 call_, uint256 minimum) external onlyOwner {
        if (saleOpenedAt != 0) revert SaleIsOpen();
        _setMemberGate(member, call_, minimum);
    }

    /// @notice Until this time only holders may buy; 0 when there is no holders window or the sale has not opened.
    function gateEndsAt() external view returns (uint256) {
        return gateSeconds == 0 || saleOpenedAt == 0 ? 0 : uint256(saleOpenedAt) + gateSeconds;
    }

    /// @notice Mint phases: e.g. (1 h, 1, 1 h, 2) is 1 per wallet for the first hour, 2 in all for the next hour, then
    /// MAX_PER_WALLET. Caps rise (1 to MAX_PER_WALLET, phase 1 at most phase 2); a phase of 0 seconds is skipped.
    /// Set before the sale first opens; (0, 0, 0, 0) clears them.
    function setMintPhases(uint64 phase1Seconds_, uint8 phase1Cap_, uint64 phase2Seconds_, uint8 phase2Cap_)
        external
        onlyOwner
    {
        if (saleOpenedAt != 0) revert SaleIsOpen();
        if (phase1Seconds_ != 0 && (phase1Cap_ == 0 || phase1Cap_ > MAX_PER_WALLET)) revert BadPhases();
        if (phase2Seconds_ != 0 && (phase2Cap_ == 0 || phase2Cap_ > MAX_PER_WALLET)) revert BadPhases();
        if (phase1Seconds_ != 0 && phase2Seconds_ != 0 && phase1Cap_ > phase2Cap_) revert BadPhases();
        phase1Seconds = phase1Seconds_;
        phase1Cap = phase1Cap_;
        phase2Seconds = phase2Seconds_;
        phase2Cap = phase2Cap_;
        emit MintPhasesSet(phase1Seconds_, phase1Cap_, phase2Seconds_, phase2Cap_);
    }

    /// @notice The most editions a wallet (or a seat) may hold from this sale right now, and when that limit next
    /// rises (0 once it is MAX_PER_WALLET). Before the sale opens: the first phase's limit, with no end yet.
    function currentPhase() public view returns (uint256 cap, uint256 endsAt) {
        uint256 opened = saleOpenedAt;
        uint256 t = opened == 0 ? 0 : block.timestamp - opened;
        if (phase1Seconds != 0 && t < phase1Seconds) return (phase1Cap, opened == 0 ? 0 : opened + phase1Seconds);
        if (phase2Seconds != 0 && t < uint256(phase1Seconds) + phase2Seconds) {
            return (phase2Cap, opened == 0 ? 0 : opened + phase1Seconds + phase2Seconds);
        }
        return (MAX_PER_WALLET, 0);
    }

    // ---------- buying ----------

    /// @notice Pay exactly `price` in ETH for one edition; the sale is recorded in the ledger and a VRF request
    /// assigns the edition. During the holders window the buyer must hold the minimum of the gate token.
    function buy(address broker) external payable nonReentrant returns (uint256 requestId) {
        _tokenGate();
        requestId = _buy(1, broker)[0];
    }

    /// @notice Buy `quantity` editions (1 to MAX_PER_WALLET, counting the wallet's earlier purchases) for exactly
    /// `price * quantity`. Each edition gets its own VRF request, so each is drawn independently.
    function buyMany(uint256 quantity, address broker)
        external
        payable
        nonReentrant
        returns (uint256[] memory requestIds)
    {
        _tokenGate();
        requestIds = _buy(quantity, broker);
    }

    /// @notice The same, for an identity.md seat holder during the holders window: each seat buys up to
    /// the current phase's limit (MAX_PER_WALLET at most), wherever it goes afterwards. After the window it is the same as
    /// buyMany.
    function buyWithSeat(uint256 seatId, uint256 quantity, address broker)
        external
        payable
        nonReentrant
        returns (uint256[] memory requestIds)
    {
        if (_inGate(saleOpenedAt)) {
            if (!_ownsSeat(msg.sender, seatId)) revert NotEligible();
            (uint256 cap,) = currentPhase();
            if (mintedBySeat[seatId] + quantity > cap) revert SeatLimit();
            mintedBySeat[seatId] += quantity;
        }
        requestIds = _buy(quantity, broker);
    }

    function _tokenGate() private view {
        if (_inGate(saleOpenedAt) && !holdsToken(msg.sender) && !isMember(msg.sender)) revert NotEligible();
    }

    function _buy(uint256 quantity, address broker) private returns (uint256[] memory requestIds) {
        if (!saleOpen) revert SaleClosed();
        if (quantity == 0 || quantity > MAX_PER_WALLET) revert BadQuantity();
        if (msg.value != price * quantity) revert WrongPrice();
        if (sold + quantity > EDITIONS) revert SoldOut();
        (uint256 cap,) = currentPhase();
        if (mintedBy[msg.sender] + quantity > cap) revert WalletLimit();
        if (address(vrfCoordinator) == address(0)) revert VRFNotConfigured();
        sold += quantity;
        mintedBy[msg.sender] += quantity;
        house.recordSale{value: msg.value}(address(this), msg.sender, broker);
        requestIds = new uint256[](quantity);
        for (uint256 i; i < quantity; ++i) {
            requestIds[i] = _requestRandomness(msg.sender, block.number);
            emit Purchased(msg.sender, broker, requestIds[i], price);
        }
    }

    /// @notice If a purchase's request will never be answered, the curator or the buyer may ask again: at once when
    /// the coordinator no longer holds it (it answered, but the callback failed), otherwise after VRF_RETRY_BLOCKS,
    /// once Chainlink has dropped it. The old id is forgotten, so a late answer to it is rejected as unknown and the
    /// buyer still gets exactly one edition. Not once a fallback draw has started: its result stands for as long as
    /// its block's hash can be read; a draw nobody finished in that time is dead, and asking again clears it.
    function rerequestRandomness(uint256 requestId) external returns (uint256 newRequestId) {
        address buyer = requestBuyer[requestId];
        if (buyer == address(0)) revert UnknownRequest();
        if (msg.sender != owner && msg.sender != buyer) revert NotBuyer();
        if (requestEdition[requestId] != 0) revert AlreadyFulfilled();
        if (_fallbackLive(requestId)) revert FallbackPending();
        if (_fallbackLive(fallbackInFlight)) revert FallbackBusy(); // no new answer while a fallback draw is under way
        if (block.number < requestBlock[requestId] + VRF_RETRY_BLOCKS && _stillHeld(requestId)) {
            revert RequestTooRecent();
        }
        uint256 bought = purchaseBlock[requestId];
        delete requestBuyer[requestId];
        delete requestBlock[requestId];
        delete purchaseBlock[requestId];
        delete fallbackBlock[requestId]; // a dead draw (its hash gone unread) ends with the request it was for
        if (fallbackInFlight == requestId) delete fallbackInFlight;
        newRequestId = _requestRandomness(buyer, bought);
        emit Rerequested(requestId, newRequestId, buyer);
    }

    /// @dev Whether the coordinator still holds this request's commitment (VRF v2.5 deletes it when it answers,
    /// whether or not the callback succeeds). A coordinator that can't say counts as still holding it.
    function _stillHeld(uint256 requestId) private view returns (bool) {
        (bool ok, bytes memory ret) =
            address(vrfCoordinator).staticcall(abi.encodeWithSignature("s_requestCommitments(uint256)", requestId));
        return !ok || ret.length < 32 || abi.decode(ret, (bytes32)) != bytes32(0);
    }

    function _requestRandomness(address buyer, uint256 bought) private returns (uint256 requestId) {
        requestId = vrfCoordinator.requestRandomWords(
            IVRFCoordinatorV2Plus.RandomWordsRequest({
                keyHash: vrfKeyHash,
                subId: vrfSubscriptionId,
                requestConfirmations: VRF_CONFIRMATIONS,
                callbackGasLimit: vrfCallbackGas,
                numWords: 1,
                extraArgs: abi.encodeWithSelector(bytes4(keccak256("VRF ExtraArgsV1")), vrfNativePayment)
            })
        );
        if (requestBuyer[requestId] != address(0)) revert AlreadyFulfilled();
        requestBuyer[requestId] = buyer;
        requestBlock[requestId] = block.number;
        purchaseBlock[requestId] = bought;
    }

    /// @notice VRF callback: assigns a uniformly random unassigned edition (Fisher-Yates over the remaining set).
    /// Not once a started fallback draw's block is behind us: from then on its hash is public, and that draw's result
    /// stands (finishFallbackDraw), so nobody can hold a known result against a later answer and keep the one they like.
    function rawFulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) external {
        if (msg.sender != address(vrfCoordinator)) revert NotCoordinator();
        uint256 target = fallbackBlock[requestId];
        if (target != 0 && block.number > target) revert FallbackPending();
        _assign(requestId, randomWords[0]);
        lastAnsweredBlock = block.number;
    }

    /// @notice Starts the fallback draw for a purchase Chainlink never answered, FALLBACK_BLOCKS after it was made and
    /// once Chainlink has answered nothing for as long (while it answers others, ask it again): anyone may, so no paid
    /// edition waits on any one person. It picks a block FALLBACK_DELAY ahead, whose hash
    /// nobody knows yet. Not while the coordinator may still answer the request itself (one it holds that is younger
    /// than VRF_RETRY_BLOCKS, e.g. just re-requested): the buyer would otherwise hold two draws, the fallback's known
    /// first, and keep whichever they like. Again only if a started draw's block hash can no longer be read (see
    /// BLOCK_HISTORY).
    function startFallbackDraw(uint256 requestId) external {
        if (requestBuyer[requestId] == address(0)) revert UnknownRequest();
        if (requestEdition[requestId] != 0) revert AlreadyFulfilled();
        if (block.number < purchaseBlock[requestId] + FALLBACK_BLOCKS) revert RequestTooRecent();
        if (block.number < lastAnsweredBlock + FALLBACK_BLOCKS) revert ChainlinkAnswering(); // ask it again instead
        if (block.number < requestBlock[requestId] + VRF_RETRY_BLOCKS && _stillHeld(requestId)) {
            revert RequestTooRecent();
        }
        if (_fallbackLive(requestId)) revert FallbackPending();
        uint256 busy = fallbackInFlight;
        if (busy != requestId && _fallbackLive(busy)) revert FallbackBusy(); // finish that one first (anyone may)
        uint256 target = block.number + FALLBACK_DELAY;
        fallbackBlock[requestId] = target;
        fallbackInFlight = requestId;
        emit FallbackDrawStarted(requestId, target);
    }

    /// @dev A started fallback draw still to be finished from its block: not answered meanwhile, and its block either
    /// still to come or its hash still readable.
    function _fallbackLive(uint256 requestId) private view returns (bool) {
        uint256 target = fallbackBlock[requestId];
        if (target == 0 || requestEdition[requestId] != 0 || requestBuyer[requestId] == address(0)) return false;
        return block.number <= target || _hashOf(target) != bytes32(0);
    }

    /// @notice Finishes a started fallback draw once its block exists (anyone may): the edition is drawn from that
    /// block's hash exactly as from a Chainlink word. If Chainlink answered meanwhile, that answer stands.
    function finishFallbackDraw(uint256 requestId) external {
        uint256 target = fallbackBlock[requestId];
        if (target == 0) revert NoFallback();
        if (block.number <= target) revert FallbackNotReady();
        bytes32 h = _hashOf(target);
        if (h == bytes32(0)) revert FallbackMissed(); // gone from the history too: start it again
        delete fallbackBlock[requestId];
        if (fallbackInFlight == requestId) delete fallbackInFlight;
        _assign(requestId, uint256(keccak256(abi.encode(h, requestId))));
    }

    /// @dev A past block's hash: BLOCKHASH for the last 256, then the EIP-2935 history (8,191); zero if neither has it.
    function _hashOf(uint256 n) private view returns (bytes32 h) {
        h = blockhash(n);
        if (h != bytes32(0)) return h;
        (bool ok, bytes memory ret) = BLOCK_HISTORY.staticcall(abi.encode(n));
        if (ok && ret.length == 32) h = abi.decode(ret, (bytes32));
    }

    function _assign(uint256 requestId, uint256 word) private {
        address buyer = requestBuyer[requestId];
        if (buyer == address(0)) revert UnknownRequest();
        if (requestEdition[requestId] != 0) revert AlreadyFulfilled();
        uint16 left = uint16(EDITIONS - assigned);
        uint16 idx = uint16(word % left);
        uint16 edition = _pool[idx] == 0 ? idx + 1 : _pool[idx];
        uint16 lastIdx = left - 1;
        uint16 last = _pool[lastIdx] == 0 ? lastIdx + 1 : _pool[lastIdx];
        _pool[idx] = last;
        assigned += 1;
        requestEdition[requestId] = edition;
        editionBuyer[edition] = buyer;
        editionAssignedAt[edition] = uint64(block.timestamp);
        _editionsOf[buyer].push(edition);
        emit EditionAssigned(edition, buyer, requestId);
    }

    // ---------- claim ----------

    function registerViewingKey(bytes32 key) external {
        if (key == bytes32(0)) revert NoViewingKey();
        viewingKeyOf[msg.sender] = key;
        emit ViewingKeyRegistered(msg.sender, key);
    }

    /// @notice Curator posts K wrapped to the buyer's registered viewing key.
    function postWrappedKey(uint256 edition, bytes calldata wrapped) external onlyOwner {
        _postWrappedKey(edition, wrapped);
    }

    /// @notice The same for many editions in one transaction: the curator's offline batch (tools/editions). All or
    /// nothing, so a batch built from a stale list fails whole rather than half-posted.
    function postWrappedKeys(uint256[] calldata editions, bytes[] calldata wrapped) external onlyOwner {
        if (editions.length != wrapped.length || editions.length == 0) revert LengthMismatch();
        for (uint256 i; i < editions.length; ++i) {
            _postWrappedKey(editions[i], wrapped[i]);
        }
    }

    function _postWrappedKey(uint256 edition, bytes calldata wrapped) private {
        address buyer = editionBuyer[edition];
        if (buyer == address(0)) revert NotAssigned();
        if (wrapped.length == 0) revert KeyNotPosted();
        address piece = pieceContract[edition];
        if (piece != address(0)) {
            // already claimed (without its key, after KEY_WAIT) or re-sold without being re-keyed: the key goes into
            // the piece, wrapped to whoever holds it now; the piece takes it only into an empty key slot
            IArtifactsPiece(piece).rewrapFor(wrapped);
        } else {
            if (viewingKeyOf[buyer] == bytes32(0)) revert NoViewingKey();
            _wrappedKey[edition] = wrapped;
        }
        // Keep the event ABI unchanged while avoiding a compiler constant-data tail containing 0xf4.
        // The launch scans every runtime byte outside PUSH data, including otherwise unreachable constants.
        bytes memory signature = bytes("WrappedKeyPosted(uint256)");
        assembly ("memory-safe") {
            log2(0, 0, keccak256(add(signature, 32), mload(signature)), edition)
        }
    }

    /// @notice Deploys an independent runtime copy for the edition and mints its single token to the buyer.
    function claim(uint256 edition) external nonReentrant returns (address piece) {
        piece = _claim(edition);
    }

    /// @notice Claims several editions in one transaction, each exactly as `claim` would; any one that can't be claimed
    /// reverts the whole call.
    function claimMany(uint256[] calldata editions) external nonReentrant returns (address[] memory pieces) {
        if (editions.length == 0) revert NothingToClaim();
        pieces = new address[](editions.length);
        for (uint256 i; i < editions.length; ++i) {
            pieces[i] = _claim(editions[i]);
        }
    }

    function _claim(uint256 edition) private returns (address piece) {
        address buyer = editionBuyer[edition];
        if (buyer == address(0)) revert NotAssigned();
        if (msg.sender != buyer && msg.sender != owner) revert NotBuyer();
        if (pieceContract[edition] != address(0)) revert AlreadyClaimed();
        bytes memory wrapped = _wrappedKey[edition];
        // no key yet: only once KEY_WAIT has passed since the draw (the key can still be sent into the piece)
        if (wrapped.length == 0 && block.timestamp < editionAssignedAt[edition] + KEY_WAIT) revert KeyNotPosted();
        piece = Clones.copyCode(pieceImplementation);
        pieceContract[edition] = piece;
        isPiece[piece] = true;
        PieceData storage p = _pieces[edition];
        IArtifactsPiece(piece)
            .initialize(
                address(this),
                address(house),
                edition,
                buyer,
                p.traits,
                p.ciphertext,
                p.commitment,
                wrapped,
                false,
                viewingKeyOf[buyer]
            );
        emit Claimed(edition, buyer, piece);
    }

    // ---------- views ----------

    /// @notice Editions still to sell: none once the sale has ended.
    function remaining() external view returns (uint256) {
        return saleEnded ? 0 : EDITIONS - sold;
    }

    /// @notice How many more editions `buyer` may buy now: the current phase's limit, or what is left, whichever is
    /// lower; none once the sale has ended.
    function allowanceOf(address buyer) external view returns (uint256) {
        if (saleEnded) return 0;
        (uint256 cap,) = currentPhase();
        uint256 left = cap > mintedBy[buyer] ? cap - mintedBy[buyer] : 0;
        uint256 unsold = EDITIONS - sold;
        return left < unsold ? left : unsold;
    }

    function editionsOf(address buyer) external view returns (uint256[] memory) {
        return _editionsOf[buyer];
    }

    function traitsOf(uint256 pieceId) external view returns (Traits memory) {
        return _pieces[pieceId].traits;
    }

    function ciphertextOf(uint256 pieceId) external view returns (bytes memory) {
        address ptr = _pieces[pieceId].ciphertext;
        return ptr == address(0) ? bytes("") : SSTORE2.read(ptr);
    }

    function ciphertextPointer(uint256 pieceId) external view returns (address) {
        return _pieces[pieceId].ciphertext;
    }

    function commitmentOf(uint256 pieceId) external view returns (bytes32) {
        return _pieces[pieceId].commitment;
    }

    function isSet(uint256 pieceId) external view returns (bool) {
        return _pieces[pieceId].set;
    }

    function wrappedKeyOf(uint256 edition) external view returns (bytes memory) {
        return _wrappedKey[edition];
    }

    function vrfConfigured() external view returns (bool) {
        return address(vrfCoordinator) != address(0);
    }
}
