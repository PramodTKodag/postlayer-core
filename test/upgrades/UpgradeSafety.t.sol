// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {Upgrades, Options} from "openzeppelin-foundry-upgrades/Upgrades.sol";

contract UpgradeSafetyTest is Test {
    function test_soloPostLayer_isUpgradeSafe() public {
        Options memory opts;
        Upgrades.validateImplementation("SoloPostLayer.sol:SoloPostLayer", opts);
    }

    // Baseline is the released version, built by `make upgrade-reference` (see UPGRADE_REFERENCE_TAG in the Makefile).
    function test_soloPostLayer_isStorageCompatibleWithReleasedVersion() public {
        Options memory opts;
        opts.referenceBuildInfoDir = ".upgrade-reference/reference-build-info";
        opts.referenceContract = "reference-build-info:SoloPostLayer";
        Upgrades.validateUpgrade("SoloPostLayer.sol:SoloPostLayer", opts);
    }

    function test_v2Mock_isStorageCompatibleWithSoloPostLayer() public {
        Options memory opts;
        opts.referenceContract = "SoloPostLayer.sol:SoloPostLayer";
        Upgrades.validateUpgrade("SoloPostLayerV2Mock.sol:SoloPostLayerV2Mock", opts);
    }
}
