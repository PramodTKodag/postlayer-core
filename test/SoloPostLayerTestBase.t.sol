// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IPostRegistry} from "../src/interfaces/IPostRegistry.sol";
import {SoloPostLayer} from "../src/SoloPostLayer.sol";

abstract contract SoloPostLayerTestBase is Test {
    bytes32 internal constant BLOG = keccak256("blog");
    string internal constant URI = "ipfs://bafy-first-post";
    bytes32 internal constant HASH = keccak256("first post body");

    address internal owner = makeAddr("owner");
    address internal stranger = makeAddr("stranger");

    SoloPostLayer internal implementation;
    SoloPostLayer internal layer;

    function setUp() public virtual {
        implementation = new SoloPostLayer();
        bytes memory initData = abi.encodeCall(SoloPostLayer.initialize, (owner));
        layer = SoloPostLayer(address(new ERC1967Proxy(address(implementation), initData)));
    }

    /// @dev Makes the next call come from `caller` and expects the owner-only check to reject it.
    function _expectUnauthorized(address caller) internal {
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, caller));
    }

    function _publishDefaultPost() internal returns (uint256 postId) {
        vm.prank(owner);
        postId = layer.publishPost(BLOG, URI, HASH);
    }

    function _assertSamePost(IPostRegistry.Post memory actual, IPostRegistry.Post memory expected) internal pure {
        assertEq(actual.author, expected.author);
        assertEq(actual.hidden, expected.hidden);
        assertEq(actual.publishedAt, expected.publishedAt);
        assertEq(actual.updatedAt, expected.updatedAt);
        assertEq(actual.version, expected.version);
        assertEq(actual.contentType, expected.contentType);
        assertEq(actual.contentHash, expected.contentHash);
        assertEq(actual.contentUri, expected.contentUri);
    }
}
