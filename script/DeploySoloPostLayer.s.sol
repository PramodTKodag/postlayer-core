// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {SoloPostLayer} from "../src/SoloPostLayer.sol";
import {DeterministicFactory} from "./DeterministicFactory.sol";
import {DeploymentGuards} from "./DeploymentGuards.sol";

/// @notice Deploys SoloPostLayer (implementation + UUPS proxy) through the deterministic factory.
/// Addresses depend only on the factory, `saltLabel`, `owner` and the compiled bytecode, so the same
/// inputs give the same proxy address on every chain. Re-running skips contracts that already exist.
/// Before broadcasting, `run` refuses unless the chain id is EXPECTED_CHAIN_ID, the factory has the pinned code, and
/// OWNER has code matching OWNER_CODEHASH on this chain (unless OWNER_IS_EOA=true), so no deploy path skips the preflight's safety checks.
/// Usage: OWNER=<address> (OWNER_IS_EOA=true | OWNER_CODEHASH=<bytes32>) SALT_LABEL=<label> EXPECTED_CHAIN_ID=<chain id>
///   forge script script/DeploySoloPostLayer.s.sol --rpc-url <url> --broadcast
contract DeploySoloPostLayer is Script, DeploymentGuards {
    error FactoryNotDeployed();
    error EmptySaltLabel();
    error ZeroOwner();
    error FactoryCallFailed(address expected);
    error UnexpectedDeployedAddress(address expected, address actual);

    string private constant IMPLEMENTATION_SALT_PART = "implementation";
    string private constant PROXY_SALT_PART = "proxy";

    /// @notice Reads OWNER, OWNER_IS_EOA, OWNER_CODEHASH, SALT_LABEL and EXPECTED_CHAIN_ID from the environment, then
    /// runs `broadcastDeploy`. OWNER_IS_EOA left unset or empty means false: an owner without code, or with code other
    /// than OWNER_CODEHASH, is refused.
    function run() external returns (address implementation, address proxy) {
        return broadcastDeploy(
            vm.envAddress("OWNER"),
            vm.envString("SALT_LABEL"),
            vm.envUint("EXPECTED_CHAIN_ID"),
            vm.envOr("OWNER_IS_EOA", false),
            vm.envOr("OWNER_CODEHASH", bytes32(0))
        );
    }

    /// @notice Checks the chain (see `DeploymentGuards`), logs the predicted addresses and deploys both contracts in a
    /// broadcast. Reverts before broadcasting anything when a check fails.
    function broadcastDeploy(
        address owner,
        string memory saltLabel,
        uint256 expectedChainId,
        bool ownerIsEoa,
        bytes32 ownerCodehash
    ) public returns (address implementation, address proxy) {
        _requireDeployable(expectedChainId, owner, ownerIsEoa, ownerCodehash);

        (address predictedImplementation, address predictedProxy) = predict(owner, saltLabel);
        console.log("Predicted implementation:", predictedImplementation);
        console.log("Predicted proxy:", predictedProxy);

        vm.startBroadcast();
        (implementation, proxy) = deploy(owner, saltLabel);
        vm.stopBroadcast();
    }

    /// @notice Computes the implementation and proxy addresses for `owner` and `saltLabel` without deploying.
    function predict(address owner, string memory saltLabel)
        public
        pure
        returns (address implementation, address proxy)
    {
        _requireValidInputs(owner, saltLabel);
        implementation = vm.computeCreate2Address(
            _salt(saltLabel, IMPLEMENTATION_SALT_PART),
            keccak256(_implementationInitCode()),
            DeterministicFactory.ADDRESS
        );
        proxy = vm.computeCreate2Address(
            _salt(saltLabel, PROXY_SALT_PART),
            keccak256(_proxyInitCode(implementation, owner)),
            DeterministicFactory.ADDRESS
        );
    }

    /// @notice Creates the implementation and the initialized proxy through the factory, skipping any that exist.
    function deploy(address owner, string memory saltLabel) public returns (address implementation, address proxy) {
        if (DeterministicFactory.ADDRESS.code.length == 0) revert FactoryNotDeployed();
        (implementation, proxy) = predict(owner, saltLabel);
        _createIfAbsent(_salt(saltLabel, IMPLEMENTATION_SALT_PART), _implementationInitCode(), implementation);
        _createIfAbsent(_salt(saltLabel, PROXY_SALT_PART), _proxyInitCode(implementation, owner), proxy);
    }

    function _createIfAbsent(bytes32 salt, bytes memory initCode, address expected) private {
        if (expected.code.length != 0) return;
        (bool ok, bytes memory returned) = DeterministicFactory.ADDRESS.call(abi.encodePacked(salt, initCode));
        if (!ok) revert FactoryCallFailed(expected);
        address actual = address(bytes20(returned));
        if (actual != expected) revert UnexpectedDeployedAddress(expected, actual);
    }

    /// @dev The proxy is created and initialized in one transaction so `initialize` cannot be front-run.
    function _proxyInitCode(address implementation, address owner) private pure returns (bytes memory) {
        bytes memory initializer = abi.encodeCall(SoloPostLayer.initialize, (owner));
        return abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(implementation, initializer));
    }

    function _implementationInitCode() private pure returns (bytes memory) {
        return type(SoloPostLayer).creationCode;
    }

    function _salt(string memory saltLabel, string memory part) private pure returns (bytes32) {
        return keccak256(abi.encode(saltLabel, part));
    }

    function _requireValidInputs(address owner, string memory saltLabel) private pure {
        if (owner == address(0)) revert ZeroOwner();
        if (bytes(saltLabel).length == 0) revert EmptySaltLabel();
    }
}
