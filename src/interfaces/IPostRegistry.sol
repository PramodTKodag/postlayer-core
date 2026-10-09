// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Pramod Kodag
pragma solidity 0.8.37;

/// @title IPostRegistry
/// @notice Content-neutral posts: each post is a pointer (URI) plus a hash and a type.
interface IPostRegistry {
    /// @dev Field order packs storage: slot 0 = author + hidden + publishedAt (27 bytes), slot 1 = updatedAt +
    /// version (10 bytes). An update never writes slot 0; hide and unhide write slot 0 only.
    /// `author` is the original publisher, not the current editing authority: after an ownership transfer the
    /// new owner edits and hides posts that were published by the previous owner.
    struct Post {
        address author;
        bool hidden;
        uint48 publishedAt;
        uint48 updatedAt;
        uint32 version;
        bytes32 contentType;
        bytes32 contentHash;
        string contentUri;
    }

    event PostPublished(
        uint256 indexed postId, address indexed author, bytes32 contentType, string contentUri, bytes32 contentHash
    );

    event PostUpdated(
        uint256 indexed postId, uint32 version, bytes32 previousContentHash, string contentUri, bytes32 contentHash
    );

    event PostHidden(uint256 indexed postId);
    event PostUnhidden(uint256 indexed postId);

    error PostNotFound(uint256 postId);
    error EmptyContentType();
    error EmptyContentUri();
    error EmptyContentHash();

    function publishPost(bytes32 contentType, string calldata contentUri, bytes32 contentHash)
        external
        returns (uint256 postId);

    function updatePost(uint256 postId, string calldata contentUri, bytes32 contentHash) external;

    function hidePost(uint256 postId) external;

    function unhidePost(uint256 postId) external;

    function getPost(uint256 postId) external view returns (Post memory);

    function postCount() external view returns (uint256);
}
