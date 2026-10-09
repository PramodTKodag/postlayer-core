// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ITokenAllowlist} from "../src/interfaces/ITokenAllowlist.sol";
import {SoloPostLayerTestBase} from "./SoloPostLayerTestBase.t.sol";

contract TokenAllowlistTest is SoloPostLayerTestBase {
    bytes32 internal constant TOKEN_ALLOWLIST_STORAGE_LOCATION =
        0x7fcf3268e1c8216aafb2f1e76cc9cb026ffda613c1b6e1873ce58ac17b237e00;

    address internal token = makeAddr("token");

    function test_setTokenAllowed_storesMinimumAndEmitsEvent() public {
        vm.expectEmit(true, false, false, true, address(layer));
        emit ITokenAllowlist.TokenAllowed(token, 5);

        vm.prank(owner);
        layer.setTokenAllowed(token, 5);

        (bool allowed, uint256 minTip) = layer.tipConfig(token);
        assertTrue(allowed);
        assertEq(minTip, 5);
    }

    function test_setTokenAllowed_acceptsNativeCoinAsZeroAddress() public {
        vm.prank(owner);
        layer.setTokenAllowed(address(0), 1 wei);

        (bool allowed,) = layer.tipConfig(address(0));
        assertTrue(allowed);
    }

    function test_setTokenAllowed_changesTheMinimumOfAnApprovedToken() public {
        vm.startPrank(owner);
        layer.setTokenAllowed(token, 5);
        layer.setTokenAllowed(token, 9);
        vm.stopPrank();

        (, uint256 minTip) = layer.tipConfig(token);
        assertEq(minTip, 9);
    }

    function test_setTokenDisallowed_removesTokenAndEmitsEvent() public {
        vm.startPrank(owner);
        layer.setTokenAllowed(token, 5);

        vm.expectEmit(true, false, false, false, address(layer));
        emit ITokenAllowlist.TokenDisallowed(token);
        layer.setTokenDisallowed(token);
        vm.stopPrank();

        (bool allowed, uint256 minTip) = layer.tipConfig(token);
        assertFalse(allowed);
        assertEq(minTip, 0);
    }

    function test_tipConfig_isNotAllowedByDefault() public view {
        (bool allowed, uint256 minTip) = layer.tipConfig(token);
        assertFalse(allowed);
        assertEq(minTip, 0);
    }

    function test_RevertWhen_setTokenAllowedWithZeroMinimum() public {
        vm.prank(owner);
        vm.expectRevert(ITokenAllowlist.InvalidMinTip.selector);
        layer.setTokenAllowed(token, 0);
    }

    function test_RevertWhen_setTokenDisallowedOnUnapprovedToken() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ITokenAllowlist.TokenNotApproved.selector, token));
        layer.setTokenDisallowed(token);
    }

    function test_RevertWhen_setTokenAllowedCalledByNonOwner() public {
        _expectUnauthorized(stranger);
        layer.setTokenAllowed(token, 5);
    }

    function test_RevertWhen_setTokenDisallowedCalledByNonOwner() public {
        vm.prank(owner);
        layer.setTokenAllowed(token, 5);

        _expectUnauthorized(stranger);
        layer.setTokenDisallowed(token);
    }

    function test_storageLocation_matchesErc7201Formula() public {
        bytes32 computed =
            keccak256(abi.encode(uint256(keccak256("postlayer.storage.TokenAllowlist")) - 1)) & ~bytes32(uint256(0xff));
        assertEq(computed, TOKEN_ALLOWLIST_STORAGE_LOCATION);

        vm.prank(owner);
        layer.setTokenAllowed(token, 7);

        // TokenAllowlistStorage: slot base + 0 = minTips mapping.
        bytes32 minTipSlot = keccak256(abi.encode(token, uint256(TOKEN_ALLOWLIST_STORAGE_LOCATION)));
        assertEq(uint256(vm.load(address(layer), minTipSlot)), 7, "minimum at the namespaced slot");
    }
}
