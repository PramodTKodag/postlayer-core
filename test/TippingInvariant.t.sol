// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {SoloPostLayer} from "../src/SoloPostLayer.sol";
import {SoloPostLayerTestBase} from "./SoloPostLayerTestBase.t.sol";
import {MockToken} from "./mocks/TippingMocks.sol";

contract TippingHandler is Test {
    SoloPostLayer internal layer;
    MockToken internal token;
    address internal author;
    address[] internal tippers;

    uint256 public nativeTipped;
    uint256 public tokenTipped;

    constructor(SoloPostLayer layer_, MockToken token_, address author_) {
        layer = layer_;
        token = token_;
        author = author_;
        for (uint256 i = 0; i < 3; i++) {
            address tipper = makeAddr(string.concat("tipper", vm.toString(i)));
            tippers.push(tipper);
            vm.deal(tipper, 100 ether);
            token.mint(tipper, 100 ether);
            vm.prank(tipper);
            token.approve(address(layer), type(uint256).max);
        }
    }

    function tipNative(uint256 tipperSeed, uint256 amount) external {
        (bool allowed, uint256 minTip) = layer.tipConfig(address(0));
        if (!allowed || layer.getPost(1).hidden) return;
        amount = bound(amount, minTip, minTip + 1 ether);
        vm.prank(tippers[bound(tipperSeed, 0, tippers.length - 1)]);
        layer.tipPost{value: amount}(1, address(0), amount);
        nativeTipped += amount;
    }

    function tipToken(uint256 tipperSeed, uint256 amount) external {
        (bool allowed, uint256 minTip) = layer.tipConfig(address(token));
        if (!allowed || layer.getPost(1).hidden) return;
        amount = bound(amount, minTip, minTip + 1 ether);
        vm.prank(tippers[bound(tipperSeed, 0, tippers.length - 1)]);
        layer.tipPost(1, address(token), amount);
        tokenTipped += amount;
    }

    function setMinimum(bool useNative, uint256 minTip) external {
        minTip = bound(minTip, 1, 1000);
        vm.prank(author);
        layer.setTokenAllowed(useNative ? address(0) : address(token), minTip);
    }

    function disallow(bool useNative) external {
        address target = useNative ? address(0) : address(token);
        (bool allowed,) = layer.tipConfig(target);
        if (!allowed) return;
        vm.prank(author);
        layer.setTokenDisallowed(target);
    }

    function toggleHidden(bool hide) external {
        vm.prank(author);
        if (hide) layer.hidePost(1);
        else layer.unhidePost(1);
    }
}

contract TippingInvariantTest is SoloPostLayerTestBase {
    TippingHandler internal handler;
    MockToken internal token;
    uint256 internal authorNativeStart;

    function setUp() public override {
        super.setUp();
        _publishDefaultPost();
        token = new MockToken();
        vm.startPrank(owner);
        layer.setTokenAllowed(address(0), 10);
        layer.setTokenAllowed(address(token), 100);
        vm.stopPrank();

        authorNativeStart = owner.balance;
        handler = new TippingHandler(layer, token, owner);
        targetContract(address(handler));
    }

    function invariant_contractNeverHoldsFunds() public view {
        assertEq(address(layer).balance, 0);
        assertEq(token.balanceOf(address(layer)), 0);
    }

    function invariant_authorReceivesExactlyWhatWasTipped() public view {
        assertEq(owner.balance - authorNativeStart, handler.nativeTipped());
        assertEq(token.balanceOf(owner), handler.tokenTipped());
    }
}
