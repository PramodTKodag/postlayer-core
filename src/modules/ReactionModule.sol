// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Pramod Kodag
pragma solidity 0.8.37;

import {IReactions} from "../interfaces/IReactions.sol";
import {PostRegistryModule} from "./PostRegistryModule.sol";

/// @title ReactionModule
/// @notice Free likes. State lives in its own ERC-7201 namespaced slot, separate from the post registry.
abstract contract ReactionModule is IReactions, PostRegistryModule {
    /// @custom:storage-location erc7201:postlayer.storage.Reaction
    struct ReactionStorage {
        mapping(uint256 postId => mapping(address account => bool)) liked;
        mapping(uint256 postId => uint256) likeCounts;
    }

    // keccak256(abi.encode(uint256(keccak256("postlayer.storage.Reaction")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant REACTION_STORAGE_LOCATION =
        0x16f73fc2b2345ce60d4f858f1a87099ae5bf00fb61326c4467c7b1627e68ff00;

    /// @inheritdoc IReactions
    function likePost(uint256 postId) external {
        Post storage post = _getExistingPost(postId);
        if (post.hidden) revert PostHiddenCannotBeLiked(postId);
        if (post.author == msg.sender) revert AuthorCannotLikeOwnPost(postId);

        ReactionStorage storage $ = _getReactionStorage();
        if ($.liked[postId][msg.sender]) revert AlreadyLiked(postId, msg.sender);
        $.liked[postId][msg.sender] = true;
        ++$.likeCounts[postId];

        // False positive: forge-lint reads the storage getter's assembly as an external call; see docs/AUDIT.md.
        // forge-lint: disable-next-line(reentrancy-events)
        emit PostLiked(postId, msg.sender);
    }

    /// @inheritdoc IReactions
    function unlikePost(uint256 postId) external {
        _getExistingPost(postId);

        ReactionStorage storage $ = _getReactionStorage();
        if (!$.liked[postId][msg.sender]) revert NotLiked(postId, msg.sender);
        $.liked[postId][msg.sender] = false;
        --$.likeCounts[postId];

        // False positive: forge-lint reads the storage getter's assembly as an external call; see docs/AUDIT.md.
        // forge-lint: disable-next-line(reentrancy-events)
        emit PostUnliked(postId, msg.sender);
    }

    /// @inheritdoc IReactions
    function likeCount(uint256 postId) external view returns (uint256) {
        _getExistingPost(postId);
        return _getReactionStorage().likeCounts[postId];
    }

    /// @inheritdoc IReactions
    function hasLiked(uint256 postId, address account) external view returns (bool) {
        _getExistingPost(postId);
        return _getReactionStorage().liked[postId][account];
    }

    function _getReactionStorage() private pure returns (ReactionStorage storage $) {
        assembly {
            $.slot := REACTION_STORAGE_LOCATION
        }
    }
}
