// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ITokenAllowlist} from "../interfaces/ITokenAllowlist.sol";

/// @title TokenAllowlistModule
/// @notice Approved tip tokens and their minimums. State lives in its own ERC-7201 namespaced slot.
abstract contract TokenAllowlistModule is ITokenAllowlist {
    /// @custom:storage-location erc7201:postlayer.storage.TokenAllowlist
    struct TokenAllowlistStorage {
        mapping(address token => uint256) minTips;
    }

    // keccak256(abi.encode(uint256(keccak256("postlayer.storage.TokenAllowlist")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant TOKEN_ALLOWLIST_STORAGE_LOCATION =
        0x7fcf3268e1c8216aafb2f1e76cc9cb026ffda613c1b6e1873ce58ac17b237e00;

    /// @dev Reverts unless the caller may change the token allowlist. Implemented by the deployed contract.
    function _authorizeTokenConfig() internal view virtual;

    /// @inheritdoc ITokenAllowlist
    function setTokenAllowed(address token, uint256 minTip) external {
        _authorizeTokenConfig();
        if (minTip == 0) revert InvalidMinTip();

        _getTokenAllowlistStorage().minTips[token] = minTip;

        emit TokenAllowed(token, minTip);
    }

    /// @inheritdoc ITokenAllowlist
    function setTokenDisallowed(address token) external {
        _authorizeTokenConfig();

        TokenAllowlistStorage storage $ = _getTokenAllowlistStorage();
        if ($.minTips[token] == 0) revert TokenNotApproved(token);
        delete $.minTips[token];

        emit TokenDisallowed(token);
    }

    /// @inheritdoc ITokenAllowlist
    function tipConfig(address token) external view returns (bool allowed, uint256 minTip) {
        minTip = _tokenMinTip(token);
        allowed = minTip != 0;
    }

    /// @dev Zero means the token is not approved.
    function _tokenMinTip(address token) internal view returns (uint256) {
        return _getTokenAllowlistStorage().minTips[token];
    }

    function _getTokenAllowlistStorage() private pure returns (TokenAllowlistStorage storage $) {
        assembly {
            $.slot := TOKEN_ALLOWLIST_STORAGE_LOCATION
        }
    }
}
