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

    /// @dev Reverts unless the selected chain is `expectedChainId`, has the pinned deterministic factory, and `owner`
    /// has code. A proxy initialized with a contract-wallet owner that has no code on this chain could later be owned
    /// by whoever deploys code at that address, so such an owner must already exist here; an EOA owner is declared
    /// with `ownerIsEoa`. Errors name the chain id, never the RPC URL.
    function _requireDeployable(uint256 expectedChainId, address owner, bool ownerIsEoa) internal view {
        if (block.chainid != expectedChainId) revert WrongChainId(expectedChainId, block.chainid);
        address factory = DeterministicFactory.ADDRESS;
        if (factory.code.length == 0) revert FactoryMissing(block.chainid);
        if (factory.codehash != FACTORY_CODEHASH) revert FactoryCodehashMismatch(block.chainid, factory.codehash);
        if (!ownerIsEoa && owner.code.length == 0) revert OwnerHasNoCode(block.chainid, owner);
    }
}
