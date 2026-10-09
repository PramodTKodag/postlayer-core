// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {IPostRegistry} from "../src/interfaces/IPostRegistry.sol";
import {SoloPostLayer} from "../src/SoloPostLayer.sol";
import {SoloPostLayerTestBase} from "./SoloPostLayerTestBase.t.sol";

contract PostRegistryHandler is Test {
    SoloPostLayer internal immutable layer;
    address internal immutable owner;

    uint256 public publishedCount;
    bool public versionChangedUnexpectedly;
    bool public versionDecreased;
    bool public authorChanged;
    bool public toggleChangedMoreThanHidden;
    mapping(uint256 postId => uint32 version) public lastSeenVersion;

    constructor(SoloPostLayer layer_, address owner_) {
        layer = layer_;
        owner = owner_;
    }

    function publish(bytes32 contentType, string memory contentUri, bytes32 contentHash) external {
        if (contentType == bytes32(0)) contentType = bytes32(uint256(1));
        if (contentHash == bytes32(0)) contentHash = bytes32(uint256(1));
        if (bytes(contentUri).length == 0) contentUri = "ipfs://x";

        vm.warp(block.timestamp + 1);
        vm.prank(owner);
        uint256 postId = layer.publishPost(contentType, contentUri, contentHash);
        publishedCount++;
        _recordVersion(postId);
    }

    function update(uint256 postSeed, string memory contentUri, bytes32 contentHash) external {
        if (publishedCount == 0) return;
        if (contentHash == bytes32(0)) contentHash = bytes32(uint256(1));
        if (bytes(contentUri).length == 0) contentUri = "ipfs://x";
        uint256 postId = bound(postSeed, 1, publishedCount);

        IPostRegistry.Post memory before = layer.getPost(postId);
        vm.prank(owner);
        layer.updatePost(postId, contentUri, contentHash);
        IPostRegistry.Post memory after_ = layer.getPost(postId);

        if (after_.version != before.version + 1) versionChangedUnexpectedly = true;
        if (after_.author != before.author) authorChanged = true;
        _recordVersion(postId);
    }

    function toggleHidden(uint256 postSeed, bool hide) external {
        if (publishedCount == 0) return;
        uint256 postId = bound(postSeed, 1, publishedCount);

        IPostRegistry.Post memory before = layer.getPost(postId);
        vm.prank(owner);
        if (hide) layer.hidePost(postId);
        else layer.unhidePost(postId);
        IPostRegistry.Post memory after_ = layer.getPost(postId);

        if (after_.version != before.version) versionChangedUnexpectedly = true;
        if (after_.author != before.author) authorChanged = true;
        before.hidden = after_.hidden;
        if (keccak256(abi.encode(after_)) != keccak256(abi.encode(before))) toggleChangedMoreThanHidden = true;
        _recordVersion(postId);
    }

    function _recordVersion(uint256 postId) private {
        uint32 version = layer.getPost(postId).version;
        if (version < lastSeenVersion[postId]) versionDecreased = true;
        lastSeenVersion[postId] = version;
    }
}

contract PostRegistryInvariantTest is SoloPostLayerTestBase {
    PostRegistryHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new PostRegistryHandler(layer, owner);
        targetContract(address(handler));
    }

    function invariant_postCountEqualsPublishedCount() public view {
        assertEq(layer.postCount(), handler.publishedCount());
    }

    function invariant_versionOnlyIncreasesByOne() public view {
        assertFalse(handler.versionChangedUnexpectedly());
        assertFalse(handler.versionDecreased());
    }

    function invariant_toggleOnlyChangesHiddenFlag() public view {
        assertFalse(handler.toggleChangedMoreThanHidden());
    }

    function invariant_authorNeverChanges() public view {
        assertFalse(handler.authorChanged());
    }

    function invariant_everyPostHasVersionAtLeastOneAndOwnerAuthor() public view {
        uint256 count = layer.postCount();
        for (uint256 postId = 1; postId <= count; postId++) {
            IPostRegistry.Post memory post = layer.getPost(postId);
            assertGe(post.version, 1);
            assertGe(post.version, handler.lastSeenVersion(postId));
            assertEq(post.author, owner);
        }
    }
}
