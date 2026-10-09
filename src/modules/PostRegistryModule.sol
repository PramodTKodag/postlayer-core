// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IPostRegistry} from "../interfaces/IPostRegistry.sol";

/// @title PostRegistryModule
/// @notice Post storage and logic. State lives in an ERC-7201 namespaced slot so later modules cannot collide with it.
abstract contract PostRegistryModule is IPostRegistry {
    /// @custom:storage-location erc7201:postlayer.storage.PostRegistry
    struct PostRegistryStorage {
        uint256 postCount;
        mapping(uint256 postId => Post) posts;
    }

    // keccak256(abi.encode(uint256(keccak256("postlayer.storage.PostRegistry")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant POST_REGISTRY_STORAGE_LOCATION =
        0x9d195c327da67d9ee5c8c8174d89034cb46ce023c73164f0b8fdfc850b9f1200;

    /// @dev Reverts unless the caller may write posts. Solo mode: owner only.
    function _authorizePostWrite() internal view virtual;

    function publishPost(bytes32 contentType, string calldata contentUri, bytes32 contentHash)
        external
        returns (uint256 postId)
    {
        _authorizePostWrite();
        if (contentType == bytes32(0)) revert EmptyContentType();
        _requireValidContent(contentUri, contentHash);

        PostRegistryStorage storage $ = _getPostRegistryStorage();
        postId = ++$.postCount;
        uint48 timestamp = uint48(block.timestamp);
        $.posts[postId] = Post({
            author: msg.sender,
            hidden: false,
            publishedAt: timestamp,
            updatedAt: timestamp,
            version: 1,
            contentType: contentType,
            contentHash: contentHash,
            contentUri: contentUri
        });

        emit PostPublished(postId, msg.sender, contentType, contentUri, contentHash);
    }

    function updatePost(uint256 postId, string calldata contentUri, bytes32 contentHash) external {
        _authorizePostWrite();
        _requireValidContent(contentUri, contentHash);

        Post storage post = _getExistingPost(postId);
        bytes32 previousContentHash = post.contentHash;
        uint32 newVersion = post.version + 1;

        post.version = newVersion;
        post.updatedAt = uint48(block.timestamp);
        post.contentUri = contentUri;
        post.contentHash = contentHash;

        emit PostUpdated(postId, newVersion, previousContentHash, contentUri, contentHash);
    }

    function hidePost(uint256 postId) external {
        _authorizePostWrite();
        Post storage post = _getExistingPost(postId);
        if (post.hidden) return;
        post.hidden = true;
        emit PostHidden(postId);
    }

    function unhidePost(uint256 postId) external {
        _authorizePostWrite();
        Post storage post = _getExistingPost(postId);
        if (!post.hidden) return;
        post.hidden = false;
        emit PostUnhidden(postId);
    }

    function getPost(uint256 postId) external view returns (Post memory) {
        return _getExistingPost(postId);
    }

    function postCount() external view returns (uint256) {
        return _getPostRegistryStorage().postCount;
    }

    function _requireValidContent(string calldata contentUri, bytes32 contentHash) internal pure {
        if (bytes(contentUri).length == 0) revert EmptyContentUri();
        if (contentHash == bytes32(0)) revert EmptyContentHash();
    }

    function _getExistingPost(uint256 postId) internal view returns (Post storage post) {
        PostRegistryStorage storage $ = _getPostRegistryStorage();
        if (postId == 0 || postId > $.postCount) revert PostNotFound(postId);
        post = $.posts[postId];
    }

    function _getPostRegistryStorage() private pure returns (PostRegistryStorage storage $) {
        assembly {
            $.slot := POST_REGISTRY_STORAGE_LOCATION
        }
    }
}
