// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Independent runtime-copy deployment, without proxies or DELEGATECALL.
library Clones {
    error CloneFailed();

    /// @notice Deploys a full, independent copy of `implementation`'s runtime code (no proxy, no DELEGATECALL).
    /// The init code is: PUSH20 impl, EXTCODESIZE, DUP1, PUSH0, PUSH0, PUSH20 impl, EXTCODECOPY, PUSH0, RETURN.
    /// Used for plain collections, ARTIFACTS editions and THE SOURCE. Storage is initialized by the caller
    /// immediately after creation; immutables embedded in the implementation's runtime are preserved.
    function copyCode(address implementation) internal returns (address instance) {
        bytes memory initCode = abi.encodePacked(hex"73", implementation, hex"3b805f5f73", implementation, hex"3c5ff3");
        assembly ("memory-safe") {
            instance := create(0, add(initCode, 32), mload(initCode))
        }
        if (instance == address(0) || instance.code.length == 0) revert CloneFailed();
    }
}
