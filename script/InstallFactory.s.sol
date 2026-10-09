// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Script} from "forge-std/Script.sol";
import {DeterministicFactory} from "./DeterministicFactory.sol";

/// @notice Installs the deterministic factory on a LOCAL anvil chain. Never run against a real network.
/// Usage: forge script script/InstallFactory.s.sol --rpc-url <local anvil url>
contract InstallFactory is Script {
    /// @notice Sets the factory runtime code at its canonical address unless it is already there.
    function run() external {
        if (DeterministicFactory.ADDRESS.code.length != 0) return;
        vm.rpc(
            "anvil_setCode",
            string.concat(
                '["',
                vm.toString(DeterministicFactory.ADDRESS),
                '","',
                vm.toString(DeterministicFactory.RUNTIME_CODE),
                '"]'
            )
        );
    }
}
