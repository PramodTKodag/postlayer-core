// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Script, console} from "forge-std/Script.sol";
import {DeploymentGuards} from "./DeploymentGuards.sol";
import {DeploySoloPostLayer} from "./DeploySoloPostLayer.s.sol";

/// @notice Read-only checks before a release: for every chain the RPC reports the expected chain id, the
/// deterministic factory is present with the pinned code, the deployer can pay for gas, and OWNER has code hashing to
/// OWNER_CODEHASH on the chain unless it is declared an EOA with OWNER_IS_EOA=true. Never sends a transaction.
/// Errors name the chain id, never the RPC URL (URLs often carry API keys), and RPC URLs are read from the
/// environment variables named in `rpcUrlEnvVars` so they never appear in script arguments or traces.
/// Usage: OWNER=<address> (OWNER_IS_EOA=true | OWNER_CODEHASH=<bytes32>) SALT_LABEL=<label> DEPLOYER_ADDRESS=<address> forge script script/PreflightDeployment.s.sol
///   --sig 'run(string[],uint256[])' '[<rpc url env var a>,<rpc url env var b>]' '[<chain id a>,<chain id b>]'
contract PreflightDeployment is Script, DeploymentGuards {
    error NoChainsToCheck();
    error LengthMismatch();
    error DeployerHasNoFunds(uint256 chainId, address deployer);

    /// @notice Checks every chain, then prints the predicted addresses (identical on every chain by construction).
    function run(string[] calldata rpcUrlEnvVars, uint256[] calldata chainIds) external {
        if (rpcUrlEnvVars.length == 0) revert NoChainsToCheck();
        if (rpcUrlEnvVars.length != chainIds.length) revert LengthMismatch();
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");
        address owner = vm.envAddress("OWNER");
        bool ownerIsEoa = vm.envOr("OWNER_IS_EOA", false);
        bytes32 ownerCodehash = _ownerCodehashFromEnv();

        for (uint256 i = 0; i < rpcUrlEnvVars.length; ++i) {
            vm.createSelectFork(vm.envString(rpcUrlEnvVars[i]));
            checkChain(chainIds[i], deployer, owner, ownerIsEoa, ownerCodehash);
            console.log("OK preflight, chain id", chainIds[i]);
        }
        predict();
    }

    /// @notice Reverts unless the currently selected chain is ready for a deploy by `deployer`: the checks the deploy
    /// script itself enforces before broadcasting, plus a funded deployer.
    function checkChain(
        uint256 expectedChainId,
        address deployer,
        address owner,
        bool ownerIsEoa,
        bytes32 ownerCodehash
    ) public view {
        _requireDeployable(expectedChainId, owner, ownerIsEoa, ownerCodehash);
        if (deployer.balance == 0) revert DeployerHasNoFunds(block.chainid, deployer);
    }

    /// @notice Logs and returns the implementation and proxy addresses for OWNER and SALT_LABEL. Needs no chain access.
    function predict() public returns (address implementation, address proxy) {
        return logPredicted(vm.envAddress("OWNER"), vm.envString("SALT_LABEL"));
    }

    /// @notice Logs and returns the addresses `predict` would for an explicit `owner` and `saltLabel`.
    function logPredicted(address owner, string memory saltLabel)
        public
        returns (address implementation, address proxy)
    {
        (implementation, proxy) = new DeploySoloPostLayer().predict(owner, saltLabel);
        console.log("Predicted implementation:", implementation);
        console.log("Predicted proxy:", proxy);
        // The single line release tooling parses; keep its format stable.
        console.log(
            string.concat("PREDICTED implementation=", vm.toString(implementation), " proxy=", vm.toString(proxy))
        );
    }
}
