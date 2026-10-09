// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {DeterministicFactory} from "../script/DeterministicFactory.sol";
import {DeploySoloPostLayer} from "../script/DeploySoloPostLayer.s.sol";
import {PreflightDeployment} from "../script/PreflightDeployment.s.sol";

contract PreflightDeploymentTest is Test {
    uint256 internal constant CHAIN_ID = 84532;
    address internal deployer = makeAddr("deployer");
    address internal contractOwner = makeAddr("contractOwner");
    address internal eoaOwner = makeAddr("eoaOwner");
    PreflightDeployment internal preflight;

    function setUp() public {
        preflight = new PreflightDeployment();
        vm.chainId(CHAIN_ID);
        vm.etch(DeterministicFactory.ADDRESS, DeterministicFactory.RUNTIME_CODE);
        vm.deal(deployer, 1 ether);
        vm.etch(contractOwner, hex"00");
    }

    function test_factoryRuntimeCode_matchesPinnedCodehash() public view {
        assertEq(DeterministicFactory.ADDRESS.codehash, preflight.FACTORY_CODEHASH());
    }

    function test_checkChain_passesWhenEverythingIsInPlace() public view {
        preflight.checkChain(CHAIN_ID, deployer, contractOwner, false);
    }

    function test_RevertWhen_chainIdDiffers() public {
        vm.expectRevert(abi.encodeWithSelector(PreflightDeployment.WrongChainId.selector, 1, CHAIN_ID));
        preflight.checkChain(1, deployer, contractOwner, false);
    }

    function test_RevertWhen_factoryIsMissing() public {
        vm.etch(DeterministicFactory.ADDRESS, "");
        vm.expectRevert(abi.encodeWithSelector(PreflightDeployment.FactoryMissing.selector, CHAIN_ID));
        preflight.checkChain(CHAIN_ID, deployer, contractOwner, false);
    }

    function test_RevertWhen_factoryCodeIsDifferent() public {
        vm.etch(DeterministicFactory.ADDRESS, hex"00");
        vm.expectRevert(
            abi.encodeWithSelector(PreflightDeployment.FactoryCodehashMismatch.selector, CHAIN_ID, keccak256(hex"00"))
        );
        preflight.checkChain(CHAIN_ID, deployer, contractOwner, false);
    }

    function test_RevertWhen_deployerHasNoFunds() public {
        vm.deal(deployer, 0);
        vm.expectRevert(abi.encodeWithSelector(PreflightDeployment.DeployerHasNoFunds.selector, CHAIN_ID, deployer));
        preflight.checkChain(CHAIN_ID, deployer, contractOwner, false);
    }

    function test_checkChain_passesForAnEoaOwnerWhenDeclared() public view {
        preflight.checkChain(CHAIN_ID, deployer, eoaOwner, true);
    }

    // A contract-wallet owner (for example a Safe) that is not deployed on this chain could later be owned by
    // whoever deploys code at that address; an EOA owner must be declared explicitly.
    function test_RevertWhen_ownerHasNoCodeAndIsNotDeclaredAnEoa() public {
        vm.expectRevert(abi.encodeWithSelector(PreflightDeployment.OwnerHasNoCode.selector, CHAIN_ID, eoaOwner));
        preflight.checkChain(CHAIN_ID, deployer, eoaOwner, false);
    }

    function test_RevertWhen_noChainsAreGiven() public {
        string[] memory rpcUrlEnvVars = new string[](0);
        uint256[] memory ids = new uint256[](0);
        vm.expectRevert(PreflightDeployment.NoChainsToCheck.selector);
        preflight.run(rpcUrlEnvVars, ids);
    }

    function test_RevertWhen_urlAndChainIdCountsDiffer() public {
        string[] memory rpcUrlEnvVars = new string[](1);
        rpcUrlEnvVars[0] = "UNUSED_RPC_URL";
        uint256[] memory ids = new uint256[](2);
        vm.expectRevert(PreflightDeployment.LengthMismatch.selector);
        preflight.run(rpcUrlEnvVars, ids);
    }

    function test_predict_matchesTheDeployScript() public {
        address owner = makeAddr("owner");
        vm.setEnv("OWNER", vm.toString(owner));
        vm.setEnv("SALT_LABEL", "postlayer-test");
        (address expectedImplementation, address expectedProxy) =
            new DeploySoloPostLayer().predict(owner, "postlayer-test");
        (address implementation, address proxy) = preflight.predict();
        assertEq(implementation, expectedImplementation);
        assertEq(proxy, expectedProxy);

        vm.setEnv("SALT_LABEL", "");
        vm.expectRevert(DeploySoloPostLayer.EmptySaltLabel.selector);
        preflight.predict();
    }
}
