// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IReactions} from "../src/interfaces/IReactions.sol";
import {IPostRegistry} from "../src/interfaces/IPostRegistry.sol";
import {SoloPostLayerTestBase} from "./SoloPostLayerTestBase.t.sol";

contract ReactionsTest is SoloPostLayerTestBase {
    bytes32 internal constant REACTION_STORAGE_LOCATION =
        0x16f73fc2b2345ce60d4f858f1a87099ae5bf00fb61326c4467c7b1627e68ff00;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public override {
        super.setUp();
        _publishDefaultPost(); // post 1, authored by `owner`
    }

    function test_likePost_recordsLikeAndEmitsEvent() public {
        vm.expectEmit(true, true, false, true, address(layer));
        emit IReactions.PostLiked(1, alice);

        vm.prank(alice);
        layer.likePost(1);

        assertTrue(layer.hasLiked(1, alice));
        assertEq(layer.likeCount(1), 1);
    }

    function test_likePost_countsEachAccountOnce() public {
        vm.prank(alice);
        layer.likePost(1);
        vm.prank(bob);
        layer.likePost(1);

        assertEq(layer.likeCount(1), 2);
        assertTrue(layer.hasLiked(1, alice));
        assertTrue(layer.hasLiked(1, bob));
    }

    function test_unlikePost_removesLikeAndEmitsEvent() public {
        vm.prank(alice);
        layer.likePost(1);

        vm.expectEmit(true, true, false, true, address(layer));
        emit IReactions.PostUnliked(1, alice);
        vm.prank(alice);
        layer.unlikePost(1);

        assertFalse(layer.hasLiked(1, alice));
        assertEq(layer.likeCount(1), 0);
    }

    function test_likePost_isAllowedAgainAfterUnlike() public {
        vm.startPrank(alice);
        layer.likePost(1);
        layer.unlikePost(1);
        layer.likePost(1);
        vm.stopPrank();

        assertTrue(layer.hasLiked(1, alice));
        assertEq(layer.likeCount(1), 1);
    }

    function test_unlikePost_keepsOtherAccountsLikes() public {
        vm.prank(alice);
        layer.likePost(1);
        vm.prank(bob);
        layer.likePost(1);

        vm.prank(alice);
        layer.unlikePost(1);

        assertFalse(layer.hasLiked(1, alice));
        assertTrue(layer.hasLiked(1, bob));
        assertEq(layer.likeCount(1), 1);
    }

    function test_likes_areIndependentPerPost() public {
        vm.prank(owner);
        layer.publishPost(BLOG, "ipfs://second", keccak256("second"));

        vm.prank(alice);
        layer.likePost(1);

        assertEq(layer.likeCount(1), 1);
        assertEq(layer.likeCount(2), 0);
        assertFalse(layer.hasLiked(2, alice));
    }

    function test_likes_surviveUpdateHideAndUnhide() public {
        vm.prank(alice);
        layer.likePost(1);

        vm.startPrank(owner);
        layer.updatePost(1, "ipfs://v2", keccak256("v2"));
        layer.hidePost(1);
        layer.unhidePost(1);
        vm.stopPrank();

        assertTrue(layer.hasLiked(1, alice));
        assertEq(layer.likeCount(1), 1);
    }

    function test_unlikePost_worksOnHiddenPost() public {
        vm.prank(alice);
        layer.likePost(1);
        vm.prank(owner);
        layer.hidePost(1);

        vm.prank(alice);
        layer.unlikePost(1);

        assertFalse(layer.hasLiked(1, alice));
        assertEq(layer.likeCount(1), 0);
        assertTrue(layer.getPost(1).hidden);
    }

    function test_reads_workOnHiddenPost() public {
        vm.prank(alice);
        layer.likePost(1);
        vm.prank(owner);
        layer.hidePost(1);

        assertTrue(layer.hasLiked(1, alice));
        assertEq(layer.likeCount(1), 1);
    }

    function test_afterOwnershipTransfer_previousOwnerStaysAuthorAndNewOwnerMayLike() public {
        address newOwner = makeAddr("newOwner");
        vm.prank(owner);
        layer.transferOwnership(newOwner);
        vm.prank(newOwner);
        layer.acceptOwnership();

        vm.expectRevert(abi.encodeWithSelector(IReactions.AuthorCannotLikeOwnPost.selector, 1));
        vm.prank(owner);
        layer.likePost(1);

        vm.prank(newOwner);
        layer.likePost(1);
        assertEq(layer.likeCount(1), 1);
    }

    function test_RevertWhen_authorLikesOwnPost() public {
        vm.expectRevert(abi.encodeWithSelector(IReactions.AuthorCannotLikeOwnPost.selector, 1));
        vm.prank(owner);
        layer.likePost(1);
    }

    function test_RevertWhen_likedTwice() public {
        vm.startPrank(alice);
        layer.likePost(1);
        vm.expectRevert(abi.encodeWithSelector(IReactions.AlreadyLiked.selector, 1, alice));
        layer.likePost(1);
        vm.stopPrank();
    }

    function test_RevertWhen_likingHiddenPost() public {
        vm.prank(owner);
        layer.hidePost(1);

        vm.expectRevert(abi.encodeWithSelector(IReactions.PostHiddenCannotBeLiked.selector, 1));
        vm.prank(alice);
        layer.likePost(1);
    }

    function test_RevertWhen_authorLikesOwnHiddenPost_hiddenIsCheckedFirst() public {
        vm.startPrank(owner);
        layer.hidePost(1);

        vm.expectRevert(abi.encodeWithSelector(IReactions.PostHiddenCannotBeLiked.selector, 1));
        layer.likePost(1);
        vm.stopPrank();
    }

    function test_RevertWhen_likingMissingPost() public {
        vm.expectRevert(abi.encodeWithSelector(IPostRegistry.PostNotFound.selector, 2));
        vm.prank(alice);
        layer.likePost(2);

        vm.expectRevert(abi.encodeWithSelector(IPostRegistry.PostNotFound.selector, 0));
        vm.prank(alice);
        layer.likePost(0);
    }

    function test_RevertWhen_unlikingWithoutLike() public {
        vm.expectRevert(abi.encodeWithSelector(IReactions.NotLiked.selector, 1, alice));
        vm.prank(alice);
        layer.unlikePost(1);
    }

    function test_RevertWhen_unlikingMissingPost() public {
        vm.expectRevert(abi.encodeWithSelector(IPostRegistry.PostNotFound.selector, 2));
        vm.prank(alice);
        layer.unlikePost(2);
    }

    function test_RevertWhen_readingLikesOfMissingPost() public {
        vm.expectRevert(abi.encodeWithSelector(IPostRegistry.PostNotFound.selector, 2));
        layer.likeCount(2);

        vm.expectRevert(abi.encodeWithSelector(IPostRegistry.PostNotFound.selector, 2));
        layer.hasLiked(2, alice);
    }

    function testFuzz_likeThenUnlike_restoresCount(address liker) public {
        vm.assume(liker != owner && liker != address(0) && liker != address(layer));

        vm.startPrank(liker);
        layer.likePost(1);
        assertEq(layer.likeCount(1), 1);
        layer.unlikePost(1);
        vm.stopPrank();

        assertEq(layer.likeCount(1), 0);
        assertFalse(layer.hasLiked(1, liker));
    }

    function test_storageLocation_matchesErc7201Formula() public {
        bytes32 base = REACTION_STORAGE_LOCATION;
        bytes32 computed =
            keccak256(abi.encode(uint256(keccak256("postlayer.storage.Reaction")) - 1)) & ~bytes32(uint256(0xff));
        assertEq(computed, base);

        vm.prank(alice);
        layer.likePost(1);

        // ReactionStorage: slot base + 0 = liked mapping, slot base + 1 = likeCounts mapping.
        bytes32 likedSlot = keccak256(abi.encode(alice, keccak256(abi.encode(uint256(1), uint256(base)))));
        bytes32 countSlot = keccak256(abi.encode(uint256(1), uint256(base) + 1));
        assertEq(uint256(vm.load(address(layer), likedSlot)), 1, "liked flag at the namespaced slot");
        assertEq(uint256(vm.load(address(layer), countSlot)), 1, "count at the namespaced slot");
    }
}
