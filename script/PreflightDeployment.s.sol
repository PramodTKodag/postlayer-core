// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Script, console} from "forge-std/Script.sol";
import {DeterministicFactory} from "./DeterministicFactory.sol";
import {DeploySoloPostLayer} from "./DeploySoloPostLayer.s.sol";

/// @notice Read-only checks before a release: for every chain the RPC reports the expected chain id, the
/// deterministic factory is present with the pinned code, the deployer can pay for gas, and OWNER has code on the chain
/// unless it is declared an EOA with OWNER_IS_EOA=true. Never sends a transaction.
/// Errors name the chain id, never the RPC URL (URLs often carry API keys), and RPC URLs are read from the
/// environment variables named in `rpcUrlEnvVars` so they never appear in script arguments or traces.
/// Usage: OWNER=<address> [OWNER_IS_EOA=true] SALT_LABEL=<label> DEPLOYER_ADDRESS=<address> forge script script/PreflightDeployment.s.sol
///   --sig 'run(string[],uint256[])' '[<rpc url env var a>,<rpc url env var b>]' '[<chain id a>,<chain id b>]'
contract PreflightDeployment is Script {
    bytes32 public constant FACTORY_CODEHASH = 0x2fa86add0aed31f33a762c9d88e807c475bd51d0f52bd0955754b2608f7e4989;

    error NoChainsToCheck();
    error LengthMismatch();
    error WrongChainId(uint256 expected, uint256 actual);
    error FactoryMissing(uint256 chainId);
    error FactoryCodehashMismatch(uint256 chainId, bytes32 actual);
    error DeployerHasNoFunds(uint256 chainId, address deployer);
    /// @dev Either `owner` is a contract wallet that is not deployed on this chain, or it is a plain account (EOA)
    /// that was not declared with OWNER_IS_EOA=true.
    error OwnerHasNoCode(uint256 chainId, address owner);

    /// @notice Checks every chain, then prints the predicted addresses (identical on every chain by construction).
    function run(string[] calldata rpcUrlEnvVars, uint256[] calldata chainIds) external {
        if (rpcUrlEnvVars.length == 0) revert NoChainsToCheck();
        if (rpcUrlEnvVars.length != chainIds.length) revert LengthMismatch();
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");
        address owner = vm.envAddress("OWNER");
        bool ownerIsEoa = vm.envOr("OWNER_IS_EOA", false);

        for (uint256 i = 0; i < rpcUrlEnvVars.length; ++i) {
            vm.createSelectFork(vm.envString(rpcUrlEnvVars[i]));
            checkChain(chainIds[i], deployer, owner, ownerIsEoa);
            console.log("OK preflight, chain id", chainIds[i]);
        }
        predict();
    }

    /// @notice Reverts unless the currently selected chain is ready for a deploy by `deployer`.
    /// A proxy initialized with a contract-wallet owner that has no code on this chain could later be owned by whoever
    /// deploys code at that address, so such an owner must already exist here; an EOA owner is declared with `ownerIsEoa`.
    function checkChain(uint256 expectedChainId, address deployer, address owner, bool ownerIsEoa) public view {
        if (block.chainid != expectedChainId) revert WrongChainId(expectedChainId, block.chainid);
        address factory = DeterministicFactory.ADDRESS;
        if (factory.code.length == 0) revert FactoryMissing(block.chainid);
        if (factory.codehash != FACTORY_CODEHASH) revert FactoryCodehashMismatch(block.chainid, factory.codehash);
        if (deployer.balance == 0) revert DeployerHasNoFunds(block.chainid, deployer);
        if (!ownerIsEoa && owner.code.length == 0) revert OwnerHasNoCode(block.chainid, owner);
    }

    /// @notice Logs and returns the implementation and proxy addresses for OWNER and SALT_LABEL. Needs no chain access.
    function predict() public returns (address implementation, address proxy) {
        (implementation, proxy) = new DeploySoloPostLayer().predict(vm.envAddress("OWNER"), vm.envString("SALT_LABEL"));
        console.log("Predicted implementation:", implementation);
        console.log("Predicted proxy:", proxy);
        // The single line release tooling parses; keep its format stable.
        console.log(
            string.concat("PREDICTED implementation=", vm.toString(implementation), " proxy=", vm.toString(proxy))
        );
    }
}
