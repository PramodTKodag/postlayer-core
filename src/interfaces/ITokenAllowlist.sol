// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Pramod Kodag
pragma solidity 0.8.37;

/// @title ITokenAllowlist
/// @notice Owner-approved tip tokens with a per-token minimum tip. The zero address stands for the native coin.
interface ITokenAllowlist {
    event TokenAllowed(address indexed token, uint256 minTip);
    event TokenDisallowed(address indexed token);

    error InvalidMinTip();
    error TokenNotApproved(address token);

    /// @notice Approves `token` for tips, or changes its minimum. Owner only.
    /// @dev Reverts with `InvalidMinTip` if `minTip` is zero. Never approve fee-on-transfer or rebasing tokens.
    function setTokenAllowed(address token, uint256 minTip) external;

    /// @notice Stops accepting tips in `token`. Owner only.
    /// @dev Reverts with `TokenNotApproved` if the token is not currently approved.
    function setTokenDisallowed(address token) external;

    /// @notice Whether `token` is approved and the minimum tip for it (zero when not approved).
    function tipConfig(address token) external view returns (bool allowed, uint256 minTip);
}
