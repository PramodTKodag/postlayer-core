// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Pramod Kodag
pragma solidity 0.8.37;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {SoloPostLayer} from "../src/SoloPostLayer.sol";
import {DeploySoloPostLayer} from "./DeploySoloPostLayer.s.sol";
import {DeploymentGuards} from "./DeploymentGuards.sol";

/// @notice Fails unless the predicted proxy exists with the expected owner and implementation on every chain, and
/// every RPC reports the expected chain id.
/// Errors name the chain id, never the RPC URL (URLs often carry API keys), and RPC URLs are read from the
/// environment variables named in `rpcUrlEnvVars` so they never appear in script arguments or traces.
/// Usage: OWNER=<address> SALT_LABEL=<label> forge script script/CheckDeployment.s.sol
///   --sig 'run(string[],uint256[])' '[<rpc url env var a>,<rpc url env var b>]' '[<chain id a>,<chain id b>]'
contract CheckDeployment is Script, DeploymentGuards {
    error NoChainsToCheck();
    error LengthMismatch();
    error NoCodeAtProxy(uint256 chainId, address proxy);
    error WrongOwner(uint256 chainId, address expected, address actual);
    error WrongImplementation(uint256 chainId, address expected, address actual);

    /// @notice Checks the predicted proxy on each chain, reverting on the first mismatch or when no chain is given.
    function run(string[] calldata rpcUrlEnvVars, uint256[] calldata chainIds) external {
        if (rpcUrlEnvVars.length == 0) revert NoChainsToCheck();
        if (rpcUrlEnvVars.length != chainIds.length) revert LengthMismatch();
        address owner = vm.envAddress("OWNER");
        string memory saltLabel = vm.envString("SALT_LABEL");
        (address implementation, address proxy) = new DeploySoloPostLayer().predict(owner, saltLabel);

        for (uint256 i = 0; i < rpcUrlEnvVars.length; ++i) {
            vm.createSelectFork(vm.envString(rpcUrlEnvVars[i]));
            checkChain(chainIds[i], owner, proxy, implementation);
            console.log("OK", block.chainid, proxy);
        }
    }

    /// @notice Reverts unless the currently selected chain is `expectedChainId` and holds the expected proxy.
    function checkChain(uint256 expectedChainId, address owner, address proxy, address implementation) public view {
        _requireChainId(expectedChainId);
        if (proxy.code.length == 0) revert NoCodeAtProxy(block.chainid, proxy);
        address actualImplementation = address(uint160(uint256(vm.load(proxy, ERC1967Utils.IMPLEMENTATION_SLOT))));
        if (actualImplementation != implementation) {
            revert WrongImplementation(block.chainid, implementation, actualImplementation);
        }
        address actualOwner = SoloPostLayer(proxy).owner();
        if (actualOwner != owner) revert WrongOwner(block.chainid, owner, actualOwner);
    }
}
