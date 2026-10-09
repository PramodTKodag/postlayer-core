// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {LowLevelCall} from "@openzeppelin/contracts/utils/LowLevelCall.sol";
import {ITipping} from "../interfaces/ITipping.sol";
import {PostRegistryModule} from "./PostRegistryModule.sol";
import {TokenAllowlistModule} from "./TokenAllowlistModule.sol";

/// @title TippingModule
/// @notice Pays a post's author directly. Holds no balances. The only state it owns is the reentrancy flag in its own
/// ERC-7201 slot (OpenZeppelin's ReentrancyGuard has a constructor, which the upgrade-safety validator rejects for
/// proxied contracts); approved tokens live in the allowlist module.
abstract contract TippingModule is ITipping, PostRegistryModule, TokenAllowlistModule {
    using SafeERC20 for IERC20;

    /// @custom:storage-location erc7201:postlayer.storage.Tipping
    struct TippingStorage {
        uint256 status; // 0 = idle, 1 = a tip is in progress
    }

    // keccak256(abi.encode(uint256(keccak256("postlayer.storage.Tipping")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant TIPPING_STORAGE_LOCATION =
        0xd5b949a62cde8bd1c7f90559cfcc5b99f5f058717d8404fc4b456f9a72bb0100;

    modifier nonReentrant() {
        TippingStorage storage $ = _getTippingStorage();
        if ($.status != 0) revert ReentrantCall();
        $.status = 1;
        _;
        $.status = 0;
    }

    /// @inheritdoc ITipping
    function tipPost(uint256 postId, address token, uint256 amount) external payable nonReentrant {
        Post storage post = _getExistingPost(postId);
        if (post.hidden) revert PostHiddenCannotBeTipped(postId);
        address author = post.author;
        if (author == msg.sender) revert AuthorCannotTipOwnPost(postId);

        uint256 minTip = _tokenMinTip(token);
        if (minTip == 0) revert TokenNotAllowed(token);
        if (amount < minTip) revert TipBelowMinimum(token, amount, minTip);

        uint256 expectedValue = token == address(0) ? amount : 0;
        if (msg.value != expectedValue) revert TipValueMismatch(expectedValue, msg.value);

        emit PostTipped(postId, msg.sender, token, author, amount);

        if (token == address(0)) {
            // The author is fixed by the post, not chosen by the caller; a failed send reverts the whole tip.
            // slither-disable-next-line arbitrary-send-eth,low-level-calls
            bool sent = LowLevelCall.callNoReturn(author, amount, "");
            if (!sent) revert NativeTransferFailed(author, amount);
        } else {
            IERC20(token).safeTransferFrom(msg.sender, author, amount);
        }
    }

    function _getTippingStorage() private pure returns (TippingStorage storage $) {
        assembly {
            $.slot := TIPPING_STORAGE_LOCATION
        }
    }
}
