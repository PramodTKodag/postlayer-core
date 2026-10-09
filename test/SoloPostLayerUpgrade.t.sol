// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {SoloPostLayerV2Mock} from "./mocks/SoloPostLayerV2Mock.sol";
import {SoloPostLayerTestBase} from "./SoloPostLayerTestBase.t.sol";
import {MockToken} from "./mocks/TippingMocks.sol";

contract SoloPostLayerUpgradeTest is SoloPostLayerTestBase {
    function _upgradeToV2() internal returns (SoloPostLayerV2Mock layerV2) {
        SoloPostLayerV2Mock newImplementation = new SoloPostLayerV2Mock();
        vm.prank(owner);
        layer.upgradeToAndCall(address(newImplementation), "");
        layerV2 = SoloPostLayerV2Mock(address(layer));
    }

    function test_upgrade_keepsExistingPostsAndOwner() public {
        vm.startPrank(owner);
        layer.publishPost(BLOG, URI, HASH);
        layer.updatePost(1, "ipfs://v2-uri", keccak256("v2"));
        layer.publishPost(BLOG, "ipfs://second", keccak256("second"));
        layer.hidePost(2);
        vm.stopPrank();

        bytes memory post1Before = abi.encode(layer.getPost(1));
        bytes memory post2Before = abi.encode(layer.getPost(2));

        SoloPostLayerV2Mock layerV2 = _upgradeToV2();

        assertEq(abi.encode(layerV2.getPost(1)), post1Before);
        assertEq(abi.encode(layerV2.getPost(2)), post2Before);
        assertEq(layerV2.postCount(), 2);
        assertEq(layerV2.owner(), owner);
    }

    function test_upgrade_newModuleStorageWorksAndDoesNotTouchPosts() public {
        _publishDefaultPost();
        bytes memory postBefore = abi.encode(layer.getPost(1));

        SoloPostLayerV2Mock layerV2 = _upgradeToV2();
        vm.prank(owner);
        layerV2.setMarker(42);

        assertEq(layerV2.marker(), 42);
        assertEq(layerV2.postCount(), 1);
        assertEq(abi.encode(layerV2.getPost(1)), postBefore);
    }

    function test_upgrade_keepsLikesAndLikingKeepsWorking() public {
        _publishDefaultPost();
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        vm.prank(alice);
        layer.likePost(1);

        SoloPostLayerV2Mock layerV2 = _upgradeToV2();

        assertTrue(layerV2.hasLiked(1, alice));
        assertEq(layerV2.likeCount(1), 1);

        vm.prank(bob);
        layerV2.likePost(1);
        vm.prank(alice);
        layerV2.unlikePost(1);

        assertEq(layerV2.likeCount(1), 1);
        assertTrue(layerV2.hasLiked(1, bob));
        assertFalse(layerV2.hasLiked(1, alice));
    }

    function test_upgrade_keepsApprovedTokensAndTippingKeepsWorking() public {
        _publishDefaultPost();
        MockToken token = new MockToken();
        vm.startPrank(owner);
        layer.setTokenAllowed(address(token), 100);
        layer.setTokenAllowed(address(0), 10);
        vm.stopPrank();
        address alice = makeAddr("alice");
        token.mint(alice, 1000);
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        token.approve(address(layer), 1000);

        SoloPostLayerV2Mock layerV2 = _upgradeToV2();

        (bool allowed, uint256 minTip) = layerV2.tipConfig(address(token));
        assertTrue(allowed);
        assertEq(minTip, 100);

        (bool nativeAllowed, uint256 nativeMinTip) = layerV2.tipConfig(address(0));
        assertTrue(nativeAllowed);
        assertEq(nativeMinTip, 10);

        uint256 authorNativeBefore = owner.balance;
        vm.startPrank(alice);
        layerV2.tipPost(1, address(token), 300);
        layerV2.tipPost{value: 50}(1, address(0), 50);
        vm.stopPrank();

        assertEq(token.balanceOf(owner), 300);
        assertEq(owner.balance, authorNativeBefore + 50);
    }

    function test_upgrade_registryKeepsWorkingAfterUpgrade() public {
        SoloPostLayerV2Mock layerV2 = _upgradeToV2();

        vm.prank(owner);
        uint256 postId = layerV2.publishPost(BLOG, URI, HASH);

        assertEq(postId, 1);
        assertEq(layerV2.postCount(), 1);
        assertEq(layerV2.getPost(1).author, owner);
        assertEq(layerV2.getPost(1).contentUri, URI);
    }

    function test_RevertWhen_postWriteAfterUpgradeByNonOwner() public {
        SoloPostLayerV2Mock layerV2 = _upgradeToV2();

        _expectUnauthorized(stranger);
        layerV2.publishPost(BLOG, URI, HASH);
    }
}
