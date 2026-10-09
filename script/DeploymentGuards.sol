// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {CommonBase} from "forge-std/Base.sol";
import {DeterministicFactory} from "./DeterministicFactory.sol";

/// @notice Checks shared by the preflight and by the deploy script itself, so a broadcast can never skip them.
abstract contract DeploymentGuards is CommonBase {
    bytes32 public constant FACTORY_CODEHASH = 0x2fa86add0aed31f33a762c9d88e807c475bd51d0f52bd0955754b2608f7e4989;

    error WrongChainId(uint256 expected, uint256 actual);
    error FactoryMissing(uint256 chainId);
    error FactoryCodehashMismatch(uint256 chainId, bytes32 actual);
    /// @dev Either `owner` is a contract wallet that is not deployed on this chain, or it is a plain account (EOA)
    /// that was not declared with OWNER_IS_EOA=true.
    error OwnerHasNoCode(uint256 chainId, address owner);
    /// @dev A contract-wallet `owner` was given without OWNER_CODEHASH. Without a pin any code would pass.
    error OwnerCodehashNotPinned(uint256 chainId, address owner);
    /// @dev The code at a contract-wallet `owner` is not the code the operator pinned with OWNER_CODEHASH. The same
    /// wallet address can be claimed on another chain by a different contract, which would then own the proxy there.
    error OwnerCodehashMismatch(uint256 chainId, address owner, bytes32 expected, bytes32 actual);
    /// @dev OWNER_IS_EOA=true and OWNER_CODEHASH were both given. An EOA has no code to pin, so the pin would be
    /// silently ignored; the operator must say which kind of owner this is.
    error OwnerIsEoaWithCodehash(uint256 chainId, address owner, bytes32 codehash);
    /// @dev OWNER_IS_EOA=true but `owner` has code, so it is a contract wallet declared by mistake (for example a
    /// reused testnet .env). Declaring an EOA must not switch the owner checks off.
    error OwnerIsEoaHasCode(uint256 chainId, address owner);

    /// @dev Reverts unless the selected chain is `expectedChainId`.
    function _requireChainId(uint256 expectedChainId) internal view {
        if (block.chainid != expectedChainId) revert WrongChainId(expectedChainId, block.chainid);
    }

    /// @dev Reverts unless the selected chain is `expectedChainId`, has the pinned deterministic factory, and the
    /// owner is acceptable. An EOA owner is declared with `ownerIsEoa`, must come with no `ownerCodehash` and must have
    /// no contract code (an account with code is a contract wallet, whatever the flag says; the code of an EIP-7702
    /// delegated EOA is not contract code). Any other owner is a contract wallet: it must already have code on this
    /// chain (a missing wallet could later be claimed by whoever deploys code at that address) and that code must hash
    /// to `ownerCodehash`, so a different contract that claimed the address first is refused. The pin proves which code is at `owner`, not who controls it: a wallet
    /// that is identical on every chain (a Safe proxy) still needs its signers checked on each chain. Errors name the
    /// chain id, never the RPC URL.
    function _requireDeployable(uint256 expectedChainId, address owner, bool ownerIsEoa, bytes32 ownerCodehash)
        internal
        view
    {
        _requireChainId(expectedChainId);
        address factory = DeterministicFactory.ADDRESS;
        if (factory.code.length == 0) revert FactoryMissing(block.chainid);
        if (factory.codehash != FACTORY_CODEHASH) revert FactoryCodehashMismatch(block.chainid, factory.codehash);
        if (ownerIsEoa) {
            if (ownerCodehash != bytes32(0)) revert OwnerIsEoaWithCodehash(block.chainid, owner, ownerCodehash);
            if (_hasContractCode(owner)) revert OwnerIsEoaHasCode(block.chainid, owner);
            return;
        }
        if (owner.code.length == 0) revert OwnerHasNoCode(block.chainid, owner);
        if (ownerCodehash == bytes32(0)) revert OwnerCodehashNotPinned(block.chainid, owner);
        bytes32 actualCodehash = owner.codehash;
        if (actualCodehash != ownerCodehash) {
            revert OwnerCodehashMismatch(block.chainid, owner, ownerCodehash, actualCodehash);
        }
    }

    /// @dev True when `account` has code other than an EIP-7702 delegation designator (0xef0100 followed by the 20-byte
    /// delegate address). An EOA that delegated is still controlled by its key, so it is not treated as a contract.
    /// Relies on EIP-3541: a conforming post-London chain cannot deploy other code starting with 0xef, so on such a
    /// chain the delegation prefix only ever appears as exactly these 23 bytes.
    function _hasContractCode(address account) internal view returns (bool) {
        bytes memory code = account.code;
        if (code.length == 23 && code[0] == 0xef && code[1] == 0x01 && code[2] == 0x00) return false;
        return code.length != 0;
    }

    /// @dev Reads OWNER_CODEHASH: unset or empty gives zero ("no pin"); anything else must be a 32-byte hex hash, or
    /// the script reverts, so a truncated or mistyped hash is never mistaken for "not given".
    function _ownerCodehashFromEnv() internal view returns (bytes32) {
        string memory raw = vm.envOr("OWNER_CODEHASH", string(""));
        return bytes(raw).length == 0 ? bytes32(0) : vm.parseBytes32(raw);
    }
}
