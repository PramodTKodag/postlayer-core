// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {IReactions} from "../src/interfaces/IReactions.sol";
import {SoloPostLayer} from "../src/SoloPostLayer.sol";
import {SoloPostLayerTestBase} from "./SoloPostLayerTestBase.t.sol";

contract ReactionsHandler is Test {
    error UnexpectedAuthorLikeRevert(bytes reason);

    SoloPostLayer internal immutable layer;
    address internal immutable owner;
    address[] internal actors;

    uint256 public publishedCount;
    bool public authorLikeSucceeded;

    constructor(SoloPostLayer layer_, address owner_) {
        layer = layer_;
        owner = owner_;
        for (uint256 i = 0; i < 4; ++i) {
            actors.push(makeAddr(string.concat("actor", vm.toString(i))));
        }
    }

    function actorAt(uint256 index) external view returns (address) {
        return actors[index];
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function publish() external {
        vm.prank(owner);
        layer.publishPost(keccak256("blog"), "ipfs://x", keccak256("body"));
        ++publishedCount;
    }

    function like(uint256 postSeed, uint256 actorSeed) external {
        if (publishedCount == 0) return;
        uint256 postId = bound(postSeed, 1, publishedCount);
        address actor = actors[bound(actorSeed, 0, actors.length - 1)];
        if (layer.hasLiked(postId, actor) || layer.getPost(postId).hidden) return;

        vm.prank(actor);
        layer.likePost(postId);
    }

    function unlike(uint256 postSeed, uint256 actorSeed) external {
        if (publishedCount == 0) return;
        uint256 postId = bound(postSeed, 1, publishedCount);
        address actor = actors[bound(actorSeed, 0, actors.length - 1)];
        if (!layer.hasLiked(postId, actor)) return;

        vm.prank(actor);
        layer.unlikePost(postId);
    }

    function likeAsAuthor(uint256 postSeed) external {
        if (publishedCount == 0) return;
        uint256 postId = bound(postSeed, 1, publishedCount);
        if (layer.getPost(postId).hidden) return;

        vm.prank(owner);
        try layer.likePost(postId) {
            authorLikeSucceeded = true;
        } catch (bytes memory reason) {
            if (bytes4(reason) != IReactions.AuthorCannotLikeOwnPost.selector) {
                revert UnexpectedAuthorLikeRevert(reason);
            }
        }
    }

    function toggleHidden(uint256 postSeed, bool hide) external {
        if (publishedCount == 0) return;
        uint256 postId = bound(postSeed, 1, publishedCount);
        vm.prank(owner);
        if (hide) layer.hidePost(postId);
        else layer.unhidePost(postId);
    }
}

contract ReactionsInvariantTest is SoloPostLayerTestBase {
    ReactionsHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new ReactionsHandler(layer, owner);
        targetContract(address(handler));
    }

    function invariant_likeCountEqualsNumberOfLikers() public view {
        for (uint256 postId = 1; postId <= handler.publishedCount(); ++postId) {
            uint256 likers;
            for (uint256 i = 0; i < handler.actorCount(); ++i) {
                if (layer.hasLiked(postId, handler.actorAt(i))) ++likers;
            }
            assertEq(layer.likeCount(postId), likers);
        }
    }

    function invariant_authorIsNeverCounted() public view {
        for (uint256 postId = 1; postId <= handler.publishedCount(); ++postId) {
            assertFalse(layer.hasLiked(postId, owner));
        }
        assertFalse(handler.authorLikeSucceeded());
    }
}
