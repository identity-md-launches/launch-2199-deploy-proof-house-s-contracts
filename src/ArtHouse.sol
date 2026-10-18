// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TwoStepOwnable} from "./base/TwoStepOwnable.sol";
import {ReentrancyGuard} from "./base/ReentrancyGuard.sol";
import {Clones} from "./libs/Clones.sol";
import {ArtStorage} from "./ArtStorage.sol";
import {ArtCollection} from "./ArtCollection.sol";
import {IERC20, IArtCollection, IPieceRegistry, IPieceController, IBalanceOf} from "./interfaces/Interfaces.sol";

/// @notice Proof House ledger: artists, brokers, sale modules, per-collection splits, balances per currency,
/// plain SVG collections (curation, pricing, minting) and open submissions. Owner = curator.
contract ArtHouse is TwoStepOwnable, ReentrancyGuard {
    // ---------- constants ----------
    uint16 public constant BPS = 10_000;
    uint16 public constant ROYALTY_BPS = 750;
    // A sale's default split: 75% to the artist, 15% to the agent who brought the buyer, 5% to the house (team and
    // operations) and 5% to buy back and burn IMD. On any collection, an agent's share nobody earned is burned too.
    uint16 public constant DEFAULT_BROKER_BPS = 1500;
    uint16 public constant DEFAULT_HOUSE_BPS = 500;
    uint16 public constant DEFAULT_ARTIST_BPS = 7500;
    uint16 public constant DEFAULT_BURN_BPS = 500;
    /// @notice The balance key of ETH (or tokens) set aside to buy back and burn IMD. Only the buyback burner,
    /// set once, can receive it.
    address public constant BUYBACK = address(uint160(uint256(keccak256("proofhouse.buyback"))));
    /// @notice The gas an artist's payout address gets to receive its share at a sale (see _payArtist).
    uint256 public constant ARTIST_PAY_GAS = 50_000;
    /// @notice Bound the optional pass lookup so a broken pass cannot block sales.
    uint256 public constant BROKER_CALL_GAS = 100_000;
    uint256 public constant MAX_PIECE_BYTES = 100_000;
    address public constant ETH = address(0);

    // ---------- immutables ----------
    ArtStorage public immutable artStorage;
    address public immutable imd;
    address public immutable collectionImplementation;

    // ---------- types ----------
    struct Artist {
        string name;
        address payout;
        bool approved;
    }

    struct Collection {
        bool exists;
        bool isModule; // sold by an approved sale module (e.g. ArtifactsFactory) rather than by mint()
        bool open;
        bool isSealed;
        address artist;
        uint16 brokerBps;
        uint16 houseBps;
        uint16 artistBps;
        uint256 pieceCount;
        uint256 priceETH;
        uint256 priceIMD;
        uint16 burnBps; // last, so readers of the fields before it are unchanged
    }

    struct Piece {
        bytes32 contentHash;
        string title;
        string description;
        bool finalized;
        bool minted;
        uint256 size;
    }

    enum SubmissionStatus {
        Pending,
        Accepted,
        Rejected
    }

    struct Submission {
        address submitter;
        bytes32 contentHash;
        string previewURI;
        SubmissionStatus status;
    }

    // ---------- state ----------
    mapping(address => Artist) public artists;
    mapping(address => bool) public brokers;
    mapping(address => bool) public saleModules;
    mapping(address => Collection) public collections;
    mapping(address => mapping(uint256 => Piece)) public pieces;
    // party => currency => balance; the house's own balance is keyed by address(this)
    mapping(address => mapping(address => uint256)) public balances;
    Submission[] public submissions;
    address[] public collectionList;
    /// @notice Proof House Broker Pass: holding one makes a wallet a broker. Set once by the owner.
    address public brokerPass;
    /// @notice The contract that turns the buyback balance into IMD and burns it. Set once by the owner.
    address public buybackBurner;

    // ---------- events ----------
    event ArtistApproved(address indexed artist, string name, address payout);
    event ArtistRevoked(address indexed artist);
    event PayoutChanged(address indexed artist, address payout);
    event BrokerSet(address indexed broker, bool approved);
    event SaleModuleSet(address indexed module, bool approved);
    event BrokerPassSet(address indexed brokerPass);
    event Resale(
        address indexed collection, address indexed piece, address indexed broker, uint256 royalty, uint256 brokerShare
    );
    event CollectionCreated(address indexed collection, address indexed artist, string name, string symbol);
    event ModuleCollectionRegistered(address indexed collection, address indexed artist);
    event SplitSet(address indexed collection, uint16 brokerBps, uint16 houseBps, uint16 artistBps, uint16 burnBps);
    event BuybackBurnerSet(address indexed burner);
    event BuybackReleased(address indexed currency, address indexed burner, uint256 amount);
    event PricesSet(address indexed collection, uint256 priceETH, uint256 priceIMD);
    event SaleOpenSet(address indexed collection, bool open);
    event PieceRegistered(address indexed collection, uint256 indexed pieceId, bytes32 contentHash, string title);
    event PieceUpdated(address indexed collection, uint256 indexed pieceId, bytes32 contentHash, string title);
    event PieceCleared(address indexed collection, uint256 indexed pieceId);
    event PieceFinalized(address indexed collection, uint256 indexed pieceId);
    event CollectionSealed(address indexed collection);
    event Sale(
        address indexed collection,
        address indexed buyer,
        address indexed broker,
        address currency,
        uint256 amount,
        uint256 brokerShare,
        uint256 houseShare,
        uint256 artistShare,
        uint256 burnShare
    );
    event Withdrawn(address indexed party, address indexed currency, address to, uint256 amount);
    /// @notice An artist's ETH share, sent straight to their payout address at the sale.
    event ArtistPaid(address indexed artist, address indexed to, uint256 amount);
    /// @notice The artist's share waits in their balance (another currency, or the payout didn't take ETH).
    event ArtistCredited(address indexed artist, address indexed currency, uint256 amount);
    event Submitted(uint256 indexed id, address indexed submitter, bytes32 contentHash, string previewURI);
    event SubmissionDecided(uint256 indexed id, SubmissionStatus status);

    // ---------- errors ----------
    error NotApprovedArtist();
    error NotArtist();
    error NotSaleModule();
    error UnknownCollection();
    error BadSplit();
    error BadPieceId();
    error BadIndex();
    error Sealed();
    error NotSealed();
    error Finalized();
    error NotFinalized();
    error TooLarge();
    error HashMismatch();
    error SaleClosed();
    error WrongPrice();
    error AlreadyMinted();
    error NothingToWithdraw();
    error TransferFailed();
    error NotCurator();
    error BadSubmission();
    error NotPending();
    error NotModuleCollection();
    error BrokerPassAlreadySet();
    error NotPiece();
    error NotEligibleBroker();
    error BuybackBurnerAlreadySet();
    error NoBuybackBurner();

    constructor(address owner_, address storage_, address imd_) TwoStepOwnable(owner_) {
        if (storage_ == address(0) || imd_ == address(0)) revert ZeroAddress();
        artStorage = ArtStorage(storage_);
        imd = imd_;
        collectionImplementation = address(new ArtCollection());
    }

    // ---------- artists & brokers ----------

    function approveArtist(address artist, string calldata name_) external onlyOwner {
        if (artist == address(0)) revert ZeroAddress();
        Artist storage a = artists[artist];
        a.name = name_;
        a.approved = true;
        if (a.payout == address(0)) a.payout = artist; // kept across re-approval once the artist changed it
        emit ArtistApproved(artist, name_, a.payout);
    }

    function revokeArtist(address artist) external onlyOwner {
        artists[artist].approved = false;
        emit ArtistRevoked(artist);
    }

    /// @notice Only the artist can change where their earnings and royalties go.
    function setPayout(address payout) external {
        if (artists[msg.sender].payout == address(0)) revert NotArtist();
        if (payout == address(0)) revert ZeroAddress();
        artists[msg.sender].payout = payout;
        emit PayoutChanged(msg.sender, payout);
    }

    function setBroker(address broker, bool approved) external onlyOwner {
        brokers[broker] = approved;
        emit BrokerSet(broker, approved);
    }

    function setSaleModule(address module, bool approved) external onlyOwner {
        saleModules[module] = approved;
        emit SaleModuleSet(module, approved);
    }

    /// @notice Set once after deployment, like the VRF settings: the pass is deployed after the ledger.
    function setBrokerPass(address pass) external onlyOwner {
        if (brokerPass != address(0)) revert BrokerPassAlreadySet();
        if (pass == address(0)) revert ZeroAddress();
        brokerPass = pass;
        emit BrokerPassSet(pass);
    }

    /// @notice A broker earns when the curator approved it or it holds a Broker Pass at the time of the sale.
    function isEligibleBroker(address broker) public view returns (bool) {
        if (broker == address(0)) return false;
        if (brokers[broker]) return true;
        address pass = brokerPass;
        if (pass == address(0)) return false;
        bytes memory data = abi.encodeCall(IBalanceOf.balanceOf, (broker));
        uint256 g = BROKER_CALL_GAS;
        bool ok;
        uint256 held;
        assembly ("memory-safe") {
            mstore(0, 0)
            ok := staticcall(g, pass, add(data, 32), mload(data), 0, 32)
            if iszero(eq(returndatasize(), 32)) { ok := 0 }
            if ok { held := mload(0) }
        }
        return ok && held > 0;
    }

    // ---------- collections ----------

    function createCollection(string calldata name_, string calldata symbol_, address artist)
        external
        onlyOwner
        returns (address collection)
    {
        if (!artists[artist].approved) revert NotApprovedArtist();
        collection = Clones.copyCode(collectionImplementation);
        IArtCollection(collection).initialize(address(this), name_, symbol_);
        _newCollection(collection, artist, false);
        emit CollectionCreated(collection, artist, name_, symbol_);
    }

    /// @notice Registers a sale module (e.g. ArtifactsFactory) as a collection for splits and royalties.
    function registerModuleCollection(address module, address artist) external onlyOwner {
        if (!artists[artist].approved) revert NotApprovedArtist();
        if (collections[module].exists) revert UnknownCollection();
        _newCollection(module, artist, true);
        emit ModuleCollectionRegistered(module, artist);
    }

    function _newCollection(address collection, address artist, bool isModule) private {
        Collection storage c = collections[collection];
        c.exists = true;
        c.isModule = isModule;
        c.artist = artist;
        c.brokerBps = DEFAULT_BROKER_BPS;
        c.houseBps = DEFAULT_HOUSE_BPS;
        c.artistBps = DEFAULT_ARTIST_BPS;
        c.burnBps = DEFAULT_BURN_BPS;
        collectionList.push(collection);
    }

    function setSplit(address collection, uint16 brokerBps, uint16 houseBps, uint16 artistBps, uint16 burnBps)
        external
        onlyOwner
    {
        if (!collections[collection].exists) revert UnknownCollection();
        if (uint256(brokerBps) + houseBps + artistBps + burnBps != BPS) revert BadSplit();
        Collection storage c = collections[collection];
        c.brokerBps = brokerBps;
        c.houseBps = houseBps;
        c.artistBps = artistBps;
        c.burnBps = burnBps;
        emit SplitSet(collection, brokerBps, houseBps, artistBps, burnBps);
    }

    function setPrices(address collection, uint256 priceETH, uint256 priceIMD) external onlyOwner {
        Collection storage c = collections[collection];
        if (!c.exists || c.isModule) revert UnknownCollection();
        c.priceETH = priceETH;
        c.priceIMD = priceIMD;
        emit PricesSet(collection, priceETH, priceIMD);
    }

    function setSaleOpen(address collection, bool open) external onlyOwner {
        Collection storage c = collections[collection];
        if (!c.exists || c.isModule) revert UnknownCollection();
        if (open && !c.isSealed) revert NotSealed();
        c.open = open;
        emit SaleOpenSet(collection, open);
    }

    function collectionCount() external view returns (uint256) {
        return collectionList.length;
    }

    // ---------- piece curation (plain SVG) ----------

    /// @dev The curator, or the collection's artist while still approved: revocation ends curation rights too.
    function _curatorOrArtist(Collection storage c) private view {
        if (msg.sender == owner) return;
        if (msg.sender != c.artist || !artists[c.artist].approved) revert NotCurator();
    }

    function registerPiece(
        address collection,
        uint256 pieceId,
        bytes32 contentHash,
        string calldata title,
        string calldata description
    ) external {
        Collection storage c = collections[collection];
        if (!c.exists || c.isModule) revert UnknownCollection();
        _curatorOrArtist(c);
        if (c.isSealed) revert Sealed();
        if (pieceId != c.pieceCount) revert BadPieceId();
        c.pieceCount = pieceId + 1;
        Piece storage p = pieces[collection][pieceId];
        p.contentHash = contentHash;
        p.title = title;
        p.description = description;
        emit PieceRegistered(collection, pieceId, contentHash, title);
    }

    /// @notice Corrects an unfinalized piece's content hash, title and description (a mistyped hash would otherwise
    /// leave the collection unsealable forever). Uploaded chunks are kept; finalizePiece checks against the new hash.
    function updatePiece(
        address collection,
        uint256 pieceId,
        bytes32 contentHash,
        string calldata title,
        string calldata description
    ) external {
        Collection storage c = collections[collection];
        if (!c.exists || c.isModule) revert UnknownCollection();
        _curatorOrArtist(c);
        if (c.isSealed) revert Sealed();
        if (pieceId >= c.pieceCount) revert BadPieceId();
        Piece storage p = pieces[collection][pieceId];
        if (p.finalized) revert Finalized();
        p.contentHash = contentHash;
        p.title = title;
        p.description = description;
        emit PieceUpdated(collection, pieceId, contentHash, title);
    }

    function uploadChunk(address collection, uint256 pieceId, uint256 index, bytes calldata data) external {
        Collection storage c = collections[collection];
        if (!c.exists || c.isModule) revert UnknownCollection();
        _curatorOrArtist(c);
        if (pieceId >= c.pieceCount) revert BadPieceId();
        Piece storage p = pieces[collection][pieceId];
        if (p.finalized) revert Finalized();
        if (index != artStorage.chunkCount(collection, pieceId)) revert BadIndex();
        p.size += data.length;
        if (p.size > MAX_PIECE_BYTES) revert TooLarge();
        artStorage.write(collection, pieceId, index, data);
    }

    /// @notice The curator may wipe an unfinalized piece's chunks so they can be re-uploaded.
    function clearPiece(address collection, uint256 pieceId) external onlyOwner {
        Collection storage c = collections[collection];
        if (!c.exists || pieceId >= c.pieceCount) revert BadPieceId();
        Piece storage p = pieces[collection][pieceId];
        if (p.finalized) revert Finalized();
        p.size = 0;
        artStorage.clear(collection, pieceId);
        emit PieceCleared(collection, pieceId);
    }

    function finalizePiece(address collection, uint256 pieceId) external {
        Collection storage c = collections[collection];
        if (!c.exists || c.isModule) revert UnknownCollection();
        _curatorOrArtist(c);
        if (pieceId >= c.pieceCount) revert BadPieceId();
        Piece storage p = pieces[collection][pieceId];
        if (p.finalized) revert Finalized();
        if (p.size == 0 || keccak256(artStorage.read(collection, pieceId)) != p.contentHash) revert HashMismatch();
        p.finalized = true;
        emit PieceFinalized(collection, pieceId);
    }

    function sealCollection(address collection) external onlyOwner {
        Collection storage c = collections[collection];
        if (!c.exists || c.isModule) revert UnknownCollection();
        if (c.isSealed) revert Sealed();
        if (c.pieceCount == 0) revert NotFinalized();
        for (uint256 i; i < c.pieceCount; ++i) {
            if (!pieces[collection][i].finalized) revert NotFinalized();
        }
        c.isSealed = true;
        emit CollectionSealed(collection);
    }

    // ---------- buying ----------

    function mint(address collection, uint256 pieceId, address broker) external payable nonReentrant {
        Collection storage c = collections[collection];
        _checkMintable(c, collection, pieceId);
        if (c.priceETH == 0 || msg.value != c.priceETH) revert WrongPrice();
        pieces[collection][pieceId].minted = true;
        _credit(collection, msg.sender, broker, ETH, msg.value);
        IArtCollection(collection).mint(msg.sender, pieceId);
    }

    function mintWithIMD(address collection, uint256 pieceId, address broker, uint256 price) external nonReentrant {
        Collection storage c = collections[collection];
        _checkMintable(c, collection, pieceId);
        if (c.priceIMD == 0 || price != c.priceIMD) revert WrongPrice();
        pieces[collection][pieceId].minted = true;
        _credit(collection, msg.sender, broker, imd, price);
        _pullIMD(msg.sender, price);
        IArtCollection(collection).mint(msg.sender, pieceId);
    }

    function _checkMintable(Collection storage c, address collection, uint256 pieceId) private view {
        if (!c.exists || c.isModule) revert UnknownCollection();
        if (!c.open) revert SaleClosed();
        if (pieceId >= c.pieceCount) revert BadPieceId();
        Piece storage p = pieces[collection][pieceId];
        if (!p.finalized) revert NotFinalized();
        if (p.minted) revert AlreadyMinted();
    }

    function _pullIMD(address from, uint256 amount) private {
        IERC20 token = IERC20(imd);
        uint256 before = token.balanceOf(address(this));
        if (!token.transferFrom(from, address(this), amount)) revert TransferFailed();
        if (token.balanceOf(address(this)) - before != amount) revert TransferFailed();
    }

    /// @notice An ARTIFACTS piece contract credits a resale's royalty and broker share here, so the artist and
    /// brokers withdraw once from the ledger instead of from each piece. The caller must be a piece of an approved
    /// module collection, as that module confirms; the ETH comes with the call.
    function recordResale(address broker, uint256 royalty, uint256 brokerShare) external payable nonReentrant {
        address module = IPieceController(msg.sender).controller();
        Collection storage c = collections[module];
        if (!saleModules[module] || !c.exists || !c.isModule || !IPieceRegistry(module).isPiece(msg.sender)) {
            revert NotPiece();
        }
        if (msg.value != royalty + brokerShare) revert WrongPrice();
        if (brokerShare > 0 && !isEligibleBroker(broker)) revert NotEligibleBroker();
        if (brokerShare > 0) balances[broker][ETH] += brokerShare;
        emit Resale(module, msg.sender, brokerShare > 0 ? broker : address(0), royalty, brokerShare);
        _payArtist(c.artist, ETH, royalty);
    }

    /// @notice Whether `module` can record a sale of its own collection now: an approved sale module registered as a
    /// module collection. A module checks this before taking bids it will settle later.
    function canRecordSale(address module) external view returns (bool) {
        Collection storage c = collections[module];
        return saleModules[module] && c.exists && c.isModule;
    }

    /// @notice Approved sale modules record an ETH sale of a module collection; the ETH comes with the call.
    function recordSale(address collection, address buyer, address broker) external payable nonReentrant {
        if (!saleModules[msg.sender]) revert NotSaleModule();
        Collection storage c = collections[collection];
        if (!c.exists || !c.isModule) revert NotModuleCollection();
        if (msg.value == 0) revert WrongPrice();
        _credit(collection, buyer, broker, ETH, msg.value);
    }

    function _credit(address collection, address buyer, address broker, address currency, uint256 amount) private {
        Collection storage c = collections[collection];
        uint256 artistShare = (amount * c.artistBps) / BPS;
        uint256 burnShare = (amount * c.burnBps) / BPS;
        uint256 brokerShare = (amount * c.brokerBps) / BPS;
        if (isEligibleBroker(broker)) {
            balances[broker][currency] += brokerShare;
        } else {
            // No agent brought this sale: their share buys back and burns IMD, on every collection.
            burnShare += brokerShare;
            brokerShare = 0;
            broker = address(0);
        }
        uint256 houseShare = amount - artistShare - burnShare - brokerShare; // its share and the rounding
        if (c.houseBps == 0) {
            // a collection with no house share (THE SOURCE): what the house would have kept goes to the artist
            artistShare += houseShare;
            houseShare = 0;
        }
        balances[address(this)][currency] += houseShare;
        balances[BUYBACK][currency] += burnShare;
        emit Sale(collection, buyer, broker, currency, amount, brokerShare, houseShare, artistShare, burnShare);
        _payArtist(c.artist, currency, artistShare); // last: every other share is already recorded
    }

    /// @dev The artist's ETH share goes straight to their payout address, with enough gas for a wallet or a Safe to
    /// receive it and little more. If it can't take it, or the share is in another currency, it waits in their
    /// balance for withdraw, as every other share does, so a sale never fails because of the artist's address.
    function _payArtist(address artist, address currency, uint256 amount) private {
        if (amount == 0) return;
        if (currency == ETH) {
            address to = artists[artist].payout;
            if (to == address(0)) to = artist;
            uint256 g = ARTIST_PAY_GAS;
            bool ok;
            assembly ("memory-safe") {
                ok := call(g, to, amount, 0, 0, 0, 0) // nothing returned is copied: no return-data bomb
            }
            if (ok) {
                emit ArtistPaid(artist, to, amount);
                return;
            }
        }
        balances[artist][currency] += amount;
        emit ArtistCredited(artist, currency, amount);
    }

    // ---------- withdrawals ----------

    /// @notice Artists and brokers withdraw their own balance; an artist's goes to their payout address.
    function withdraw(address currency) external nonReentrant {
        uint256 amount = balances[msg.sender][currency];
        if (amount == 0) revert NothingToWithdraw();
        balances[msg.sender][currency] = 0;
        address to = artists[msg.sender].payout;
        if (to == address(0)) to = msg.sender;
        _pay(currency, to, amount);
        emit Withdrawn(msg.sender, currency, to, amount);
    }

    /// @notice The contract that buys back and burns IMD with the buyback balance. Set once, so what is set aside to
    /// burn can never go anywhere else.
    function setBuybackBurner(address burner) external onlyOwner {
        if (buybackBurner != address(0)) revert BuybackBurnerAlreadySet();
        if (burner == address(0)) revert ZeroAddress();
        buybackBurner = burner;
        emit BuybackBurnerSet(burner);
    }

    /// @notice Anyone may send the buyback balance (in one currency) to the buyback burner.
    function releaseBuyback(address currency) external nonReentrant {
        address burner = buybackBurner;
        if (burner == address(0)) revert NoBuybackBurner();
        uint256 amount = balances[BUYBACK][currency];
        if (amount == 0) revert NothingToWithdraw();
        balances[BUYBACK][currency] = 0;
        _pay(currency, burner, amount);
        emit BuybackReleased(currency, burner, amount);
    }

    /// @notice The house balance goes to the current owner.
    function withdrawHouse(address currency) external nonReentrant onlyOwner {
        uint256 amount = balances[address(this)][currency];
        if (amount == 0) revert NothingToWithdraw();
        balances[address(this)][currency] = 0;
        _pay(currency, owner, amount);
        emit Withdrawn(address(this), currency, owner, amount);
    }

    function _pay(address currency, address to, uint256 amount) private {
        if (currency == ETH) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert TransferFailed();
        } else {
            if (!IERC20(currency).transfer(to, amount)) revert TransferFailed();
        }
    }

    // ---------- views for collections ----------

    function royaltyFor(address collection, uint256 salePrice) external view returns (address, uint256) {
        Collection storage c = collections[collection];
        if (!c.exists) revert UnknownCollection();
        return (artists[c.artist].payout, (salePrice * ROYALTY_BPS) / BPS);
    }

    function pieceMetadata(address collection, uint256 pieceId)
        external
        view
        returns (string memory title, string memory description, bytes memory svg)
    {
        Piece storage p = pieces[collection][pieceId];
        return (p.title, p.description, artStorage.read(collection, pieceId));
    }

    function artistPayout(address artist) external view returns (address) {
        return artists[artist].payout;
    }

    // ---------- submissions ----------

    function submit(bytes32 contentHash, string calldata previewURI) external returns (uint256 id) {
        if (contentHash == bytes32(0)) revert BadSubmission();
        id = submissions.length;
        submissions.push(Submission(msg.sender, contentHash, previewURI, SubmissionStatus.Pending));
        emit Submitted(id, msg.sender, contentHash, previewURI);
    }

    function decideSubmission(uint256 id, bool accept) external onlyOwner {
        if (id >= submissions.length) revert BadSubmission();
        Submission storage s = submissions[id];
        if (s.status != SubmissionStatus.Pending) revert NotPending();
        s.status = accept ? SubmissionStatus.Accepted : SubmissionStatus.Rejected;
        emit SubmissionDecided(id, s.status);
    }

    function submissionCount() external view returns (uint256) {
        return submissions.length;
    }
}
