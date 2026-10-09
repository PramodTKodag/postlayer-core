// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IPostRegistry} from "../src/interfaces/IPostRegistry.sol";
import {SoloPostLayerTestBase} from "./SoloPostLayerTestBase.t.sol";

contract PostRegistryTest is SoloPostLayerTestBase {
    // keccak256(abi.encode(uint256(keccak256("postlayer.storage.PostRegistry")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant REGISTRY_STORAGE_LOCATION =
        0x9d195c327da67d9ee5c8c8174d89034cb46ce023c73164f0b8fdfc850b9f1200;

    string internal constant NEW_URI = "ipfs://bafy-edited-post";
    bytes32 internal constant NEW_HASH = keccak256("edited post body");

    function test_publishPost_storesPostAndEmits() public {
        vm.warp(1_000);

        vm.expectEmit(true, true, false, true, address(layer));
        emit IPostRegistry.PostPublished(1, owner, BLOG, URI, HASH);
        vm.prank(owner);
        uint256 postId = layer.publishPost(BLOG, URI, HASH);

        assertEq(postId, 1);
        assertEq(layer.postCount(), 1);

        IPostRegistry.Post memory post = layer.getPost(1);
        assertEq(post.author, owner);
        assertEq(post.version, 1);
        assertFalse(post.hidden);
        assertEq(post.publishedAt, 1_000);
        assertEq(post.updatedAt, 1_000);
        assertEq(post.contentType, BLOG);
        assertEq(post.contentHash, HASH);
        assertEq(post.contentUri, URI);
    }

    function test_publishPost_assignsSequentialIds() public {
        vm.startPrank(owner);
        assertEq(layer.publishPost(BLOG, URI, HASH), 1);
        assertEq(layer.publishPost(BLOG, URI, HASH), 2);
        assertEq(layer.publishPost(BLOG, URI, HASH), 3);
        vm.stopPrank();
        assertEq(layer.postCount(), 3);
    }

    function test_RevertWhen_publishPostCalledByNonOwner() public {
        _expectUnauthorized(stranger);
        layer.publishPost(BLOG, URI, HASH);
    }

    function test_RevertWhen_publishPostWithEmptyContentType() public {
        vm.prank(owner);
        vm.expectRevert(IPostRegistry.EmptyContentType.selector);
        layer.publishPost(bytes32(0), URI, HASH);
    }

    function test_RevertWhen_publishPostWithEmptyContentUri() public {
        vm.prank(owner);
        vm.expectRevert(IPostRegistry.EmptyContentUri.selector);
        layer.publishPost(BLOG, "", HASH);
    }

    function test_RevertWhen_publishPostWithEmptyContentHash() public {
        vm.prank(owner);
        vm.expectRevert(IPostRegistry.EmptyContentHash.selector);
        layer.publishPost(BLOG, URI, bytes32(0));
    }

    function test_RevertWhen_getPostForUnknownId() public {
        vm.expectRevert(abi.encodeWithSelector(IPostRegistry.PostNotFound.selector, 0));
        layer.getPost(0);

        vm.expectRevert(abi.encodeWithSelector(IPostRegistry.PostNotFound.selector, 1));
        layer.getPost(1);
    }

    function test_storageLocation_matchesErc7201Formula() public {
        bytes32 computed =
            keccak256(abi.encode(uint256(keccak256("postlayer.storage.PostRegistry")) - 1)) & ~bytes32(uint256(0xff));
        assertEq(computed, REGISTRY_STORAGE_LOCATION);

        _publishDefaultPost();

        assertEq(uint256(vm.load(address(layer), REGISTRY_STORAGE_LOCATION)), 1, "postCount at the namespaced slot");
        assertEq(address(uint160(uint256(vm.load(address(layer), _postSlot(1, 0))))), owner, "author in post slot 0");
    }

    function test_updatePost_neverWritesSlotZero() public {
        _publishDefaultPost();
        bytes32 slot0Before = vm.load(address(layer), _postSlot(1, 0));
        bytes32 slot1Before = vm.load(address(layer), _postSlot(1, 1));
        vm.warp(block.timestamp + 100);

        vm.prank(owner);
        layer.updatePost(1, NEW_URI, NEW_HASH);

        assertEq(vm.load(address(layer), _postSlot(1, 0)), slot0Before);
        assertTrue(vm.load(address(layer), _postSlot(1, 1)) != slot1Before);
    }

    function test_hideAndUnhide_neverWriteSlotOne() public {
        vm.warp(1_000);
        _publishDefaultPost();
        bytes32 slot0Before = vm.load(address(layer), _postSlot(1, 0));
        bytes32 slot1Before = vm.load(address(layer), _postSlot(1, 1));

        vm.prank(owner);
        layer.hidePost(1);
        assertTrue(vm.load(address(layer), _postSlot(1, 0)) != slot0Before);
        assertEq(vm.load(address(layer), _postSlot(1, 1)), slot1Before);

        vm.prank(owner);
        layer.unhidePost(1);
        assertEq(vm.load(address(layer), _postSlot(1, 0)), slot0Before);
        assertEq(vm.load(address(layer), _postSlot(1, 1)), slot1Before);
    }

    function test_hideAndUnhide_changeOnlyTheHiddenFlag() public {
        vm.warp(1_000);
        _publishDefaultPost();
        IPostRegistry.Post memory expected = layer.getPost(1);

        vm.prank(owner);
        layer.hidePost(1);
        expected.hidden = true;
        _assertSamePost(layer.getPost(1), expected);

        vm.prank(owner);
        layer.unhidePost(1);
        expected.hidden = false;
        _assertSamePost(layer.getPost(1), expected);
    }

    function test_updatePost_changesOnlyUriHashVersionAndUpdatedAt() public {
        _publishDefaultPost();
        IPostRegistry.Post memory expected = layer.getPost(1);
        vm.warp(block.timestamp + 100);

        vm.prank(owner);
        layer.updatePost(1, NEW_URI, NEW_HASH);

        expected.contentUri = NEW_URI;
        expected.contentHash = NEW_HASH;
        expected.version = 2;
        expected.updatedAt = uint48(block.timestamp);
        _assertSamePost(layer.getPost(1), expected);
    }

    function test_updatePost_isAllowedOnHiddenPost() public {
        _publishDefaultPost();
        vm.startPrank(owner);
        layer.hidePost(1);

        vm.expectEmit(true, false, false, true, address(layer));
        emit IPostRegistry.PostUpdated(1, 2, HASH, NEW_URI, NEW_HASH);
        layer.updatePost(1, NEW_URI, NEW_HASH);
        vm.stopPrank();

        IPostRegistry.Post memory post = layer.getPost(1);
        assertTrue(post.hidden);
        assertEq(post.version, 2);
        assertEq(post.contentUri, NEW_URI);
    }

    function testFuzz_publishPost_storesInputs(bytes32 contentType, string calldata contentUri, bytes32 contentHash)
        public
    {
        vm.assume(contentType != bytes32(0));
        vm.assume(contentHash != bytes32(0));
        vm.assume(bytes(contentUri).length > 0);

        vm.prank(owner);
        uint256 postId = layer.publishPost(contentType, contentUri, contentHash);

        IPostRegistry.Post memory post = layer.getPost(postId);
        assertEq(post.contentType, contentType);
        assertEq(post.contentUri, contentUri);
        assertEq(post.contentHash, contentHash);
        assertEq(post.author, owner);
    }

    function test_updatePost_bumpsVersionAndEmitsPreviousHash() public {
        _publishDefaultPost();
        vm.warp(5_000);

        vm.expectEmit(true, false, false, true, address(layer));
        emit IPostRegistry.PostUpdated(1, 2, HASH, NEW_URI, NEW_HASH);
        vm.prank(owner);
        layer.updatePost(1, NEW_URI, NEW_HASH);

        IPostRegistry.Post memory post = layer.getPost(1);
        assertEq(post.version, 2);
        assertEq(post.updatedAt, 5_000);
        assertEq(post.contentUri, NEW_URI);
        assertEq(post.contentHash, NEW_HASH);
        assertEq(post.author, owner);
        assertEq(post.contentType, BLOG);
    }

    function testFuzz_updatePost_storesInputs(string calldata contentUri, bytes32 contentHash) public {
        vm.assume(bytes(contentUri).length > 0);
        vm.assume(contentHash != bytes32(0));
        _publishDefaultPost();

        vm.prank(owner);
        layer.updatePost(1, contentUri, contentHash);

        IPostRegistry.Post memory post = layer.getPost(1);
        assertEq(post.contentUri, contentUri);
        assertEq(post.contentHash, contentHash);
        assertEq(post.version, 2);
        assertEq(post.author, owner);
        assertEq(post.contentType, BLOG);
    }

    function test_updatePost_keepsPublishedAt() public {
        vm.warp(1_000);
        _publishDefaultPost();
        vm.warp(9_000);
        vm.prank(owner);
        layer.updatePost(1, NEW_URI, NEW_HASH);

        assertEq(layer.getPost(1).publishedAt, 1_000);
    }

    function test_RevertWhen_updatePostCalledByNonOwner() public {
        _publishDefaultPost();

        _expectUnauthorized(stranger);
        layer.updatePost(1, NEW_URI, NEW_HASH);
    }

    function test_RevertWhen_updatePostForUnknownId() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IPostRegistry.PostNotFound.selector, 7));
        layer.updatePost(7, NEW_URI, NEW_HASH);
    }

    function test_RevertWhen_updatePostWithEmptyContentUri() public {
        vm.startPrank(owner);
        layer.publishPost(BLOG, URI, HASH);
        vm.expectRevert(IPostRegistry.EmptyContentUri.selector);
        layer.updatePost(1, "", NEW_HASH);
        vm.stopPrank();
    }

    function test_RevertWhen_updatePostWithEmptyContentHash() public {
        vm.startPrank(owner);
        layer.publishPost(BLOG, URI, HASH);
        vm.expectRevert(IPostRegistry.EmptyContentHash.selector);
        layer.updatePost(1, NEW_URI, bytes32(0));
        vm.stopPrank();
    }

    function test_hidePost_setsFlagAndEmits() public {
        vm.startPrank(owner);
        layer.publishPost(BLOG, URI, HASH);

        vm.expectEmit(true, false, false, false, address(layer));
        emit IPostRegistry.PostHidden(1);
        layer.hidePost(1);
        vm.stopPrank();

        assertTrue(layer.getPost(1).hidden);
    }

    function test_unhidePost_clearsFlagAndEmits() public {
        vm.startPrank(owner);
        layer.publishPost(BLOG, URI, HASH);
        layer.hidePost(1);

        vm.expectEmit(true, false, false, false, address(layer));
        emit IPostRegistry.PostUnhidden(1);
        layer.unhidePost(1);
        vm.stopPrank();

        assertFalse(layer.getPost(1).hidden);
    }

    function test_hidePost_isNoOpWhenAlreadyHidden() public {
        vm.startPrank(owner);
        layer.publishPost(BLOG, URI, HASH);
        layer.hidePost(1);

        vm.recordLogs();
        layer.hidePost(1);
        vm.stopPrank();

        assertEq(vm.getRecordedLogs().length, 0);
        assertTrue(layer.getPost(1).hidden);
    }

    function test_unhidePost_isNoOpWhenAlreadyVisible() public {
        vm.startPrank(owner);
        layer.publishPost(BLOG, URI, HASH);

        vm.recordLogs();
        layer.unhidePost(1);
        vm.stopPrank();

        assertEq(vm.getRecordedLogs().length, 0);
        assertFalse(layer.getPost(1).hidden);
    }

    function test_hiddenPost_remainsReadable() public {
        vm.startPrank(owner);
        layer.publishPost(BLOG, URI, HASH);
        layer.hidePost(1);
        vm.stopPrank();

        assertTrue(layer.getPost(1).hidden);
        assertEq(layer.getPost(1).contentUri, URI);
    }

    function test_RevertWhen_hidePostCalledByNonOwner() public {
        _publishDefaultPost();

        _expectUnauthorized(stranger);
        layer.hidePost(1);
    }

    function test_RevertWhen_unhidePostCalledByNonOwner() public {
        _publishDefaultPost();

        _expectUnauthorized(stranger);
        layer.unhidePost(1);
    }

    function test_RevertWhen_hidePostForUnknownId() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IPostRegistry.PostNotFound.selector, 3));
        layer.hidePost(3);
    }

    function test_RevertWhen_unhidePostForUnknownId() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IPostRegistry.PostNotFound.selector, 3));
        layer.unhidePost(3);
    }

    /// @dev Storage slot `offset` of `posts[postId]`; `posts` is the second field of the registry storage struct.
    function _postSlot(uint256 postId, uint256 offset) internal pure returns (bytes32) {
        uint256 postsMappingSlot = uint256(REGISTRY_STORAGE_LOCATION) + 1;
        return bytes32(uint256(keccak256(abi.encode(postId, postsMappingSlot))) + offset);
    }
}
