// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @notice The standard deterministic deployment proxy (Arachnid), present at the same address on most chains.
/// Call it with `salt (32 bytes) ++ initCode`; it CREATE2-deploys and returns the 20-byte address.
library DeterministicFactory {
    address internal constant ADDRESS = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    /// @dev Runtime code of the factory, used to install it on local chains and in tests.
    bytes internal constant RUNTIME_CODE =
        hex"7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3";
}
