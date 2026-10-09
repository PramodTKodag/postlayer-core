// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {DeterministicFactory} from "./DeterministicFactory.sol";

/// @notice Checks shared by the preflight and by the deploy script itself, so a broadcast can never skip them.
abstract contract DeploymentGuards {
    bytes32 public constant FACTORY_CODEHASH = 0x2fa86add0aed31f33a762c9d88e807c475bd51d0f52bd0955754b2608f7e4989;

    error WrongChainId(uint256 expected, uint256 actual);
    error FactoryMissing(uint256 chainId);
    error FactoryCodehashMismatch(uint256 chainId, bytes32 actual);
    /// @dev Either `owner` is a contract wallet that is not deployed on this chain, or it is a plain account (EOA)
    /// that was not declared with OWNER_IS_EOA=true.
    error OwnerHasNoCode(uint256 chainId, address owner);
    /// @dev The code at a contract-wallet `owner` is not the code the operator pinned with OWNER_CODEHASH. The same
    /// wallet address can be claimed on another chain by a different contract, which would then own the proxy there.
    /// `expected` is zero when no OWNER_CODEHASH was given.
    error OwnerCodehashMismatch(uint256 chainId, address owner, bytes32 expected, bytes32 actual);

    /// @dev Reverts unless the selected chain is `expectedChainId`.
    function _requireChainId(uint256 expectedChainId) internal view {
        if (block.chainid != expectedChainId) revert WrongChainId(expectedChainId, block.chainid);
    }

    /// @dev Reverts unless the selected chain is `expectedChainId`, has the pinned deterministic factory, and `owner`
    /// is usable. A proxy initialized with a contract-wallet owner that has no code on this chain could later be owned
    /// by whoever deploys code at that address, so such an owner must already exist here and its code must hash to
    /// `ownerCodehash`, so a different contract that claimed the address first is refused. An EOA owner is declared
    /// with `ownerIsEoa`. The pin proves which code is at `owner`, not who controls it: a wallet that is identical
    /// on every chain (a Safe proxy) still needs its signers checked on each chain. Errors name the chain id, never
    /// the RPC URL.
    function _requireDeployable(uint256 expectedChainId, address owner, bool ownerIsEoa, bytes32 ownerCodehash)
        internal
        view
    {
        _requireChainId(expectedChainId);
        address factory = DeterministicFactory.ADDRESS;
        if (factory.code.length == 0) revert FactoryMissing(block.chainid);
        if (factory.codehash != FACTORY_CODEHASH) revert FactoryCodehashMismatch(block.chainid, factory.codehash);
        if (ownerIsEoa) return;
        if (owner.code.length == 0) revert OwnerHasNoCode(block.chainid, owner);
        if (owner.codehash != ownerCodehash) {
            revert OwnerCodehashMismatch(block.chainid, owner, ownerCodehash, owner.codehash);
        }
    }
}
