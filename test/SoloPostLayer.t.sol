// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {SoloPostLayer} from "../src/SoloPostLayer.sol";
import {SoloPostLayerTestBase} from "./SoloPostLayerTestBase.t.sol";

contract SoloPostLayerTest is SoloPostLayerTestBase {
    // bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1)
    bytes32 internal constant ERC1967_IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function test_initialize_setsOwner() public view {
        assertEq(layer.owner(), owner);
    }

    function test_RevertWhen_initializeCalledTwice() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        layer.initialize(stranger);
    }

    function test_RevertWhen_initializeCalledOnImplementation() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(stranger);
    }

    function test_RevertWhen_ownerRenouncesOwnership() public {
        vm.expectRevert(SoloPostLayer.RenounceOwnershipDisabled.selector);
        vm.prank(owner);
        layer.renounceOwnership();

        assertEq(layer.owner(), owner);
    }

    function test_transferOwnership_requiresAcceptance() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(owner);
        layer.transferOwnership(newOwner);
        assertEq(layer.owner(), owner);
        assertEq(layer.pendingOwner(), newOwner);

        vm.prank(newOwner);
        layer.acceptOwnership();
        assertEq(layer.owner(), newOwner);
    }

    function test_RevertWhen_initializeWithZeroOwner() public {
        bytes memory initData = abi.encodeCall(SoloPostLayer.initialize, (address(0)));

        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableInvalidOwner.selector, address(0)));
        new ERC1967Proxy(address(implementation), initData);
    }

    function test_RevertWhen_pendingOwnerPublishesBeforeAccepting() public {
        address newOwner = makeAddr("newOwner");
        vm.prank(owner);
        layer.transferOwnership(newOwner);

        _expectUnauthorized(newOwner);
        layer.publishPost(BLOG, URI, HASH);
    }

    function test_RevertWhen_acceptOwnershipCalledByNonPendingOwner() public {
        address newOwner = makeAddr("newOwner");
        vm.prank(owner);
        layer.transferOwnership(newOwner);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, stranger));
        layer.acceptOwnership();
        assertEq(layer.owner(), owner);
    }

    function test_ownershipTransfer_movesPostWriteAccess() public {
        address newOwner = makeAddr("newOwner");
        vm.prank(owner);
        layer.transferOwnership(newOwner);
        vm.prank(newOwner);
        layer.acceptOwnership();

        _expectUnauthorized(owner);
        layer.publishPost(BLOG, URI, HASH);

        vm.prank(newOwner);
        uint256 postId = layer.publishPost(BLOG, URI, HASH);
        assertEq(layer.getPost(postId).author, newOwner);
    }

    function test_RevertWhen_nonOwnerUpgrades() public {
        SoloPostLayer newImplementation = new SoloPostLayer();

        _expectUnauthorized(stranger);
        layer.upgradeToAndCall(address(newImplementation), "");
    }

    function test_upgradeToAndCall_succeedsForOwner() public {
        SoloPostLayer newImplementation = new SoloPostLayer();

        vm.prank(owner);
        layer.upgradeToAndCall(address(newImplementation), "");

        assertEq(layer.owner(), owner);
        assertEq(
            address(uint160(uint256(vm.load(address(layer), ERC1967_IMPLEMENTATION_SLOT)))), address(newImplementation)
        );
    }

    function test_RevertWhen_upgradingToNonUupsAddress() public {
        address notAnImplementation = address(this);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ERC1967Utils.ERC1967InvalidImplementation.selector, notAnImplementation));
        layer.upgradeToAndCall(notAnImplementation, "");
    }
}
