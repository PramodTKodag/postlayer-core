// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @title IReactions
/// @notice Free likes on posts: one per address, never by the post's author.
interface IReactions {
    event PostLiked(uint256 indexed postId, address indexed liker);
    event PostUnliked(uint256 indexed postId, address indexed liker);

    error AuthorCannotLikeOwnPost(uint256 postId);
    error AlreadyLiked(uint256 postId, address liker);
    error NotLiked(uint256 postId, address liker);
    error PostHiddenCannotBeLiked(uint256 postId);

    /// @notice Likes a post as the caller.
    /// @dev Reverts, checked in this order: `PostNotFound` (declared in `IPostRegistry`) for an unknown post,
    /// `PostHiddenCannotBeLiked` if the post is hidden, `AuthorCannotLikeOwnPost` if the caller is the post's
    /// author, `AlreadyLiked` if the caller already likes it.
    function likePost(uint256 postId) external;

    /// @notice Removes the caller's like from a post. Allowed on hidden posts.
    /// @dev Reverts with `PostNotFound` for an unknown post, or `NotLiked` if the caller does not like it.
    function unlikePost(uint256 postId) external;

    /// @notice Number of accounts currently liking the post.
    /// @dev Reverts with `PostNotFound` for an unknown post.
    function likeCount(uint256 postId) external view returns (uint256);

    /// @notice Whether `account` currently likes the post.
    /// @dev Reverts with `PostNotFound` for an unknown post.
    function hasLiked(uint256 postId, address account) external view returns (bool);
}
