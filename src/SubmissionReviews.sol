// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IOwnerOf} from "./interfaces/Interfaces.sol";

interface IHouseSubmissions {
    function submissions(uint256 id)
        external
        view
        returns (address submitter, bytes32 contentHash, string memory previewURI, uint8 status);
    function submissionCount() external view returns (uint256);
}

interface IFactoryPieceContracts {
    function pieceContract(uint256 edition) external view returns (address);
}

interface ISourcePieceContract {
    function pieceContract() external view returns (address);
}

/// @notice Reviews of artist submissions to Proof House. Every identity.md seat and every claimed ARTIFACTS piece
/// is one voice per submission: back it, stay neutral, or pass on it, with a short note. Reviews are advisory: the
/// curator still decides on ArtHouse. A review can change while its submission is pending and is frozen once the
/// curator decides. The seat or piece speaks, not the wallet: whoever holds it now may update its review, so moving
/// it never adds a voice. No owner, no fees, nothing to switch off.
/// A voice is a number: a seat's is its seat id; a piece's is PIECE_VOICE + its piece id (1 to 255 editions, 256 THE
/// SOURCE).
/// Any wallet may also publish a thesis on a submission (the case for it, in its own words), or apply to be a broker
/// with a thesis for the house itself (applyAsBroker). Neither grants anything: a broker (a Broker Pass holder, or a
/// wallet the curator approved) earns the broker share on every sale its link brings, so a thesis that wins buyers
/// earns, and the curator may approve the writers of the best ones. Theses and applications are unverified text
/// (an "On X:" link can name any account): readers filter by ArtHouse.isEligibleBroker or the curator's own reading.
/// Advisory too: agents vet, a person picks.
contract SubmissionReviews {
    enum Verdict {
        None,
        Back,
        Neutral,
        Pass
    }

    struct Review {
        Verdict verdict;
        uint64 at;
        address reviewer;
        string note;
    }

    uint256 public constant MAX_NOTE = 280; // bytes
    uint256 public constant MAX_THESIS = 4_000; // bytes
    uint256 public constant PIECE_VOICE = 1 << 128; // piece voices sit above every seat id
    uint256 public constant SOURCE_ID = 256;
    uint8 private constant PENDING = 0; // ArtHouse.SubmissionStatus.Pending
    uint8 private constant REJECTED = 2; // ArtHouse.SubmissionStatus.Rejected

    IHouseSubmissions public immutable house;
    IOwnerOf public immutable seats; // identity.md seats (ERC-721)
    address public immutable factory; // ArtifactsFactory: editions 1 to 255
    address public immutable source; // ArtifactsSource: THE SOURCE, 256

    // submission id => voice => review
    mapping(uint256 => mapping(uint256 => Review)) private _reviews;
    // submission id => the voices that reviewed it, in order of their first review
    mapping(uint256 => uint256[]) private _voices;
    // submission id => count of current reviews by verdict (index = Verdict)
    mapping(uint256 => uint256[4]) private _tally;
    /// @notice When each wallet last published a thesis on a submission (0: never), and how many wallets have.
    mapping(uint256 => mapping(address => uint64)) public thesisAt;
    /// @notice When each wallet last applied to be a broker (applyAsBroker); 0 if it never has.
    mapping(address => uint64) public appliedAt;
    mapping(uint256 => uint256) public thesisAuthors;

    event Reviewed(
        uint256 indexed submissionId, uint256 indexed voice, address indexed reviewer, Verdict verdict, string note
    );
    event Thesis(uint256 indexed submissionId, address indexed author, string text);
    event BrokerApplication(address indexed author, string text);

    error ZeroAddress();
    error BadVerdict();
    error NoteTooLong();
    error NoSuchSubmission();
    error NotPending();
    error NotHolder();
    error NoSuchPiece();
    error BadThesis();
    error Declined();

    constructor(address house_, address seats_, address factory_, address source_) {
        if (house_ == address(0) || seats_ == address(0) || factory_ == address(0) || source_ == address(0)) {
            revert ZeroAddress();
        }
        house = IHouseSubmissions(house_);
        seats = IOwnerOf(seats_);
        factory = factory_;
        source = source_;
    }

    /// @notice Review a pending submission with an identity.md seat you hold.
    function reviewAsSeat(uint256 submissionId, uint256 seatId, Verdict verdict, string calldata note) external {
        if (seatId >= PIECE_VOICE) revert NotHolder();
        address holder;
        try seats.ownerOf(seatId) returns (address o) {
            holder = o;
        } catch {
            revert NotHolder();
        }
        if (holder != msg.sender) revert NotHolder();
        _review(submissionId, seatId, verdict, note);
    }

    /// @notice Review a pending submission with a claimed ARTIFACTS piece you hold (1 to 255, or 256 for THE SOURCE).
    function reviewAsPiece(uint256 submissionId, uint256 pieceId, Verdict verdict, string calldata note) external {
        address piece;
        if (pieceId >= 1 && pieceId <= 255) piece = IFactoryPieceContracts(factory).pieceContract(pieceId);
        else if (pieceId == SOURCE_ID) piece = ISourcePieceContract(source).pieceContract();
        if (piece == address(0)) revert NoSuchPiece(); // an unclaimed edition has no contract yet
        if (IOwnerOf(piece).ownerOf(1) != msg.sender) revert NotHolder();
        _review(submissionId, PIECE_VOICE + pieceId, verdict, note);
    }

    function _review(uint256 submissionId, uint256 voice, Verdict verdict, string calldata note) private {
        if (verdict == Verdict.None) revert BadVerdict();
        if (bytes(note).length > MAX_NOTE) revert NoteTooLong();
        if (submissionId >= house.submissionCount()) revert NoSuchSubmission();
        (,,, uint8 status) = house.submissions(submissionId);
        if (status != PENDING) revert NotPending();

        Review storage r = _reviews[submissionId][voice];
        if (r.verdict == Verdict.None) _voices[submissionId].push(voice);
        else _tally[submissionId][uint8(r.verdict)] -= 1;
        _tally[submissionId][uint8(verdict)] += 1;
        r.verdict = verdict;
        r.at = uint64(block.timestamp);
        r.reviewer = msg.sender;
        r.note = note;
        emit Reviewed(submissionId, voice, msg.sender, verdict, note);
    }

    /// @notice A thesis on a submission (up to MAX_THESIS bytes), from any wallet: the latest one per author is the
    /// one that stands. A broker's earns through their link; anyone else's makes their case to the curator, who may
    /// make them a broker (ArtHouse.setBroker). Open while the submission is pending and after it is accepted, to keep
    /// making the case for the drop; closed once it is declined. The text lives in the event; the contract keeps only
    /// when and how many.
    function postThesis(uint256 submissionId, string calldata text) external {
        _thesis(submissionId, text);
    }

    /// @notice A thesis for Proof House itself, to be made a broker: from any wallet, up to MAX_THESIS bytes, the
    /// latest one standing (by convention ending "On X: <the writer's post>"). The curator reads them and may approve
    /// the writer (ArtHouse.setBroker); it grants nothing by itself. The text lives in the event.
    function applyAsBroker(string calldata text) external {
        uint256 len = bytes(text).length;
        if (len == 0 || len > MAX_THESIS) revert BadThesis();
        appliedAt[msg.sender] = uint64(block.timestamp);
        emit BrokerApplication(msg.sender, text);
    }

    function _thesis(uint256 submissionId, string calldata text) private {
        uint256 len = bytes(text).length;
        if (len == 0 || len > MAX_THESIS) revert BadThesis();
        if (submissionId >= house.submissionCount()) revert NoSuchSubmission();
        (,,, uint8 status) = house.submissions(submissionId);
        if (status == REJECTED) revert Declined();
        if (thesisAt[submissionId][msg.sender] == 0) thesisAuthors[submissionId] += 1;
        thesisAt[submissionId][msg.sender] = uint64(block.timestamp);
        emit Thesis(submissionId, msg.sender, text);
    }

    // ---------- views ----------

    /// @notice A seat's voice number (its seat id) and a piece's (PIECE_VOICE + piece id).
    function seatVoice(uint256 seatId) external pure returns (uint256) {
        return seatId;
    }

    function pieceVoice(uint256 pieceId) external pure returns (uint256) {
        return PIECE_VOICE + pieceId;
    }

    /// @notice One voice's review of a submission; verdict None if it has not reviewed it.
    function reviewOf(uint256 submissionId, uint256 voice) external view returns (Review memory) {
        return _reviews[submissionId][voice];
    }

    /// @notice How many voices back, are neutral on, or pass on a submission.
    function tally(uint256 submissionId) external view returns (uint256 backs, uint256 neutrals, uint256 passes) {
        uint256[4] storage t = _tally[submissionId];
        return (t[1], t[2], t[3]);
    }

    /// @notice How many voices have reviewed a submission.
    function reviewCount(uint256 submissionId) external view returns (uint256) {
        return _voices[submissionId].length;
    }

    /// @notice A page of a submission's reviews, in order of each voice's first review.
    function reviewsOf(uint256 submissionId, uint256 start, uint256 count)
        external
        view
        returns (uint256[] memory voices, Review[] memory list)
    {
        uint256[] storage ids = _voices[submissionId];
        // clamp before adding, so `count = type(uint256).max` (everything from `start`) returns the tail
        uint256 n = start >= ids.length ? 0 : ids.length - start;
        if (count < n) n = count;
        voices = new uint256[](n);
        list = new Review[](n);
        for (uint256 i; i < n; ++i) {
            voices[i] = ids[start + i];
            list[i] = _reviews[submissionId][voices[i]];
        }
    }
}
