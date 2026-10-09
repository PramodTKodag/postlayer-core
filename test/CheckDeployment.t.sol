// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {DeterministicFactory} from "../script/DeterministicFactory.sol";
import {DeploySoloPostLayer} from "../script/DeploySoloPostLayer.s.sol";
import {CheckDeployment} from "../script/CheckDeployment.s.sol";

contract CheckDeploymentTest is Test {
    uint256 internal constant CHAIN_ID = 84532;
    string internal constant LABEL = "postlayer-test";

    address internal owner = makeAddr("owner");
    address internal implementation;
    address internal proxy;
    CheckDeployment internal checker;

    function setUp() public {
        checker = new CheckDeployment();
        vm.chainId(CHAIN_ID);
        vm.etch(DeterministicFactory.ADDRESS, DeterministicFactory.RUNTIME_CODE);
        (implementation, proxy) = new DeploySoloPostLayer().deploy(owner, LABEL);
    }

    function test_checkChain_passesForTheDeployedProxy() public view {
        checker.checkChain(CHAIN_ID, owner, proxy, implementation);
    }

    function test_RevertWhen_noChainsAreGiven() public {
        string[] memory rpcUrlEnvVars = new string[](0);
        uint256[] memory ids = new uint256[](0);
        vm.expectRevert(CheckDeployment.NoChainsToCheck.selector);
        checker.run(rpcUrlEnvVars, ids);
    }

    function test_RevertWhen_urlAndChainIdCountsDiffer() public {
        string[] memory rpcUrlEnvVars = new string[](1);
        rpcUrlEnvVars[0] = "UNUSED_RPC_URL";
        uint256[] memory ids = new uint256[](2);
        vm.expectRevert(CheckDeployment.LengthMismatch.selector);
        checker.run(rpcUrlEnvVars, ids);
    }

    function test_RevertWhen_chainIdDiffers() public {
        vm.expectRevert(abi.encodeWithSelector(CheckDeployment.WrongChainId.selector, 1, CHAIN_ID));
        checker.checkChain(1, owner, proxy, implementation);
    }

    function test_RevertWhen_proxyHasNoCode() public {
        vm.etch(proxy, "");
        vm.expectRevert(abi.encodeWithSelector(CheckDeployment.NoCodeAtProxy.selector, CHAIN_ID, proxy));
        checker.checkChain(CHAIN_ID, owner, proxy, implementation);
    }

    function test_RevertWhen_ownerDiffers() public {
        address expectedOwner = makeAddr("other-owner");
        vm.expectRevert(abi.encodeWithSelector(CheckDeployment.WrongOwner.selector, CHAIN_ID, expectedOwner, owner));
        checker.checkChain(CHAIN_ID, expectedOwner, proxy, implementation);
    }

    function test_RevertWhen_implementationDiffers() public {
        address otherImplementation = makeAddr("other-implementation");
        vm.store(proxy, ERC1967Utils.IMPLEMENTATION_SLOT, bytes32(uint256(uint160(otherImplementation))));
        vm.expectRevert(
            abi.encodeWithSelector(
                CheckDeployment.WrongImplementation.selector, CHAIN_ID, implementation, otherImplementation
            )
        );
        checker.checkChain(CHAIN_ID, owner, proxy, implementation);
    }
}
