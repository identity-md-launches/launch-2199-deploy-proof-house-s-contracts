// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IBalanceOf, IOwnerOf} from "../interfaces/Interfaces.sol";

/// @notice Holders first: for the first `gateSeconds` of a sale, only holders of an identity.md seat, of at least
/// `gateMinBalance` of a token (IMD), or members of a membership contract (Cncptl Prspctv: any points) may buy; after
/// that, anyone. The owner sets it before the sale opens: the editions' rules are fixed once their sale opens, THE
/// SOURCE's from its first bid. A seat, token or membership contract that cannot answer counts as not held.
abstract contract HolderGate {
    uint64 public constant MAX_GATE_SECONDS = 30 days;

    address public gateSeats; // identity.md seats (ERC-721)
    address public gateToken; // IMD (ERC-20)
    uint256 public gateMinBalance; // in the token's smallest unit
    uint64 public gateSeconds; // 0: no holders window
    /// @notice Members: `gateMember`'s view `gateMemberCall`(wallet) returns at least `gateMemberMin` (0: no members).
    address public gateMember; // Cncptl Prspctv's points (EngageV2), read with points(address)
    bytes4 public gateMemberCall;
    uint256 public gateMemberMin;
    uint256 public constant MEMBER_CALL_GAS = 100_000;

    event GateSet(address seats, address token, uint256 minBalance, uint64 gateSeconds);
    event MemberGateSet(address member, bytes4 call, uint256 minimum);

    error NotEligible();
    error BadGate();

    function _setGate(address seats, address token, uint256 minBalance, uint64 seconds_) internal {
        if (seconds_ > MAX_GATE_SECONDS) revert BadGate();
        bool tokenGate = token != address(0) && minBalance > 0;
        if (seconds_ > 0 && seats == address(0) && !tokenGate) revert BadGate(); // a window nobody could enter
        if ((token == address(0)) != (minBalance == 0)) revert BadGate(); // a token needs a minimum, and back
        gateSeats = seats;
        gateToken = token;
        gateMinBalance = minBalance;
        gateSeconds = seconds_;
        emit GateSet(seats, token, minBalance, seconds_);
    }

    /// @dev Members as a third way in: a contract, its view taking the wallet and returning a number, and the minimum
    /// (a membership with no minimum, or a minimum with no contract, is refused). All zero: no members.
    function _setMemberGate(address member, bytes4 call_, uint256 minimum) internal {
        if ((member == address(0)) != (minimum == 0) || (member == address(0)) != (call_ == bytes4(0))) {
            revert BadGate();
        }
        if (member != address(0) && member.code.length == 0) revert BadGate(); // a typo would shut every member out
        gateMember = member;
        gateMemberCall = call_;
        gateMemberMin = minimum;
        emit MemberGateSet(member, call_, minimum);
    }

    /// @notice A member: the membership contract's view returns at least the minimum for this wallet. Read with a gas
    /// cap and exactly one return word, so dynamic ABI offsets cannot count as points. Only 32 bytes are copied.
    function isMember(address account) public view returns (bool) {
        address m = gateMember;
        if (m == address(0)) return false;
        bytes memory data = abi.encodeWithSelector(gateMemberCall, account);
        uint256 g = MEMBER_CALL_GAS;
        bool ok;
        uint256 n;
        assembly ("memory-safe") {
            mstore(0, 0)
            ok := staticcall(g, m, add(data, 32), mload(data), 0, 32)
            if iszero(eq(returndatasize(), 32)) { ok := 0 } // reject dynamic, short and multi-word answers
            if ok { n := mload(0) }
        }
        return ok && n >= gateMemberMin;
    }

    /// @dev Whether a sale that started at `start` is still in its holders window.
    function _inGate(uint256 start) internal view returns (bool) {
        return gateSeconds != 0 && start != 0 && block.timestamp < start + gateSeconds;
    }

    /// @notice Holds at least the minimum of the gate token.
    function holdsToken(address account) public view returns (bool) {
        address t = gateToken;
        if (t == address(0)) return false;
        (bool ok, uint256 b) = _readWord(t, abi.encodeCall(IBalanceOf.balanceOf, (account)));
        return ok && b >= gateMinBalance;
    }

    /// @notice Holds at least one identity.md seat.
    function holdsSeat(address account) public view returns (bool) {
        address s = gateSeats;
        if (s == address(0)) return false;
        (bool ok, uint256 b) = _readWord(s, abi.encodeCall(IBalanceOf.balanceOf, (account)));
        return ok && b > 0;
    }

    /// @dev Holds this particular seat.
    function _ownsSeat(address account, uint256 seatId) internal view returns (bool) {
        address s = gateSeats;
        if (s == address(0)) return false;
        (bool ok, uint256 o) = _readWord(s, abi.encodeCall(IOwnerOf.ownerOf, (seatId)));
        return ok && o == uint256(uint160(account));
    }

    /// @dev One word from a view on `target`: not ok if the call reverts or answers anything but exactly 32 bytes,
    /// which includes an address with no code there (an empty answer). A Solidity try/catch would not do: the
    /// callee's empty return fails to decode in the caller, and that revert is the caller's, not caught. Only 32
    /// bytes are copied.
    function _readWord(address target, bytes memory data) private view returns (bool ok, uint256 word) {
        assembly ("memory-safe") {
            mstore(0, 0)
            ok := staticcall(gas(), target, add(data, 32), mload(data), 0, 32)
            if iszero(eq(returndatasize(), 32)) { ok := 0 }
            if ok { word := mload(0) }
        }
    }
}
