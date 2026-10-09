// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Pramod Kodag
pragma solidity 0.8.37;

/// @title ITipping
/// @notice Tips paid to a post's author in the native coin or an approved ERC-20, in the same transaction.
interface ITipping {
    event PostTipped(
        uint256 indexed postId, address indexed tipper, address indexed token, address author, uint256 amount
    );

    error PostHiddenCannotBeTipped(uint256 postId);
    error AuthorCannotTipOwnPost(uint256 postId);
    error TokenNotAllowed(address token);
    error TipBelowMinimum(address token, uint256 amount, uint256 minTip);
    error TipValueMismatch(uint256 expected, uint256 actual);
    error ReentrantCall();
    error NativeTransferFailed(address author, uint256 amount);

    /// @notice Tips the post's author `amount` of `token` (the zero address is the native coin).
    /// @dev Native: `msg.value` must equal `amount`. ERC-20: `msg.value` must be 0 and the caller must have approved
    /// this contract for `amount`; tokens go straight from the caller to the author. Reverts `ReentrantCall` if a tip
    /// is already in progress, then, checked in this order: `PostNotFound` (declared in `IPostRegistry`),
    /// `PostHiddenCannotBeTipped`, `AuthorCannotTipOwnPost`, `TokenNotAllowed`, `TipBelowMinimum` (also for a zero
    /// amount), `TipValueMismatch`. A failed payout reverts the whole tip: `NativeTransferFailed` for the native coin;
    /// for an ERC-20, the token's own revert data, or `SafeERC20FailedOperation` if it returns false or has no code.
    function tipPost(uint256 postId, address token, uint256 amount) external payable;
}
