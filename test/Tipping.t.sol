// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPostRegistry} from "../src/interfaces/IPostRegistry.sol";
import {ITipping} from "../src/interfaces/ITipping.sol";
import {SoloPostLayer} from "../src/SoloPostLayer.sol";
import {SoloPostLayerTestBase} from "./SoloPostLayerTestBase.t.sol";
import {
    MockToken,
    BlocklistToken,
    NoReturnToken,
    FalseReturnToken,
    RejectingAuthor,
    ReentrantAuthor
} from "./mocks/TippingMocks.sol";

contract TippingTest is SoloPostLayerTestBase {
    address internal alice = makeAddr("alice");
    MockToken internal token;
    bytes32 internal constant TIPPING_GUARD_SLOT = 0xd5b949a62cde8bd1c7f90559cfcc5b99f5f058717d8404fc4b456f9a72bb0100;

    function setUp() public override {
        super.setUp();
        _publishDefaultPost(); // post 1, authored by `owner`
        token = new MockToken();
        vm.startPrank(owner);
        layer.setTokenAllowed(address(0), 10); // native coin, minimum 10 wei
        layer.setTokenAllowed(address(token), 100);
        vm.stopPrank();
        vm.deal(alice, 1 ether);
        token.mint(alice, 1_000_000);
        vm.prank(alice);
        token.approve(address(layer), type(uint256).max);
    }

    // ---- happy paths ----

    function test_tipPost_native_paysAuthorAndEmitsEvent() public {
        uint256 authorBefore = owner.balance;

        vm.expectEmit(true, true, true, true, address(layer));
        emit ITipping.PostTipped(1, alice, address(0), owner, 50);
        vm.prank(alice);
        layer.tipPost{value: 50}(1, address(0), 50);

        assertEq(owner.balance, authorBefore + 50);
        assertEq(alice.balance, 1 ether - 50);
        assertEq(address(layer).balance, 0, "contract holds nothing");
    }

    function test_tipPost_erc20_paysAuthorDirectly() public {
        vm.expectEmit(true, true, true, true, address(layer));
        emit ITipping.PostTipped(1, alice, address(token), owner, 500);
        vm.prank(alice);
        layer.tipPost(1, address(token), 500);

        assertEq(token.balanceOf(owner), 500);
        assertEq(token.balanceOf(alice), 1_000_000 - 500);
        assertEq(token.balanceOf(address(layer)), 0, "contract holds nothing");
    }

    function test_tipPost_erc20_worksWithTokenThatReturnsNothing() public {
        NoReturnToken usdtLike = new NoReturnToken();
        usdtLike.mint(alice, 1000);
        vm.prank(alice);
        usdtLike.approve(address(layer), 1000);
        vm.prank(owner);
        layer.setTokenAllowed(address(usdtLike), 1);

        vm.prank(alice);
        layer.tipPost(1, address(usdtLike), 400);

        assertEq(usdtLike.balanceOf(owner), 400);
    }

    function test_tipPost_paysTheOriginalAuthorAfterOwnershipTransfer() public {
        address newOwner = makeAddr("newOwner");
        vm.prank(owner);
        layer.transferOwnership(newOwner);
        vm.prank(newOwner);
        layer.acceptOwnership();
        uint256 authorBefore = owner.balance;

        vm.prank(alice);
        layer.tipPost{value: 50}(1, address(0), 50);

        assertEq(owner.balance, authorBefore + 50, "original author is paid");
        assertEq(newOwner.balance, 0);
    }

    function test_tipPost_isAllowedAtExactlyTheMinimum() public {
        uint256 authorBefore = owner.balance;
        vm.prank(alice);
        layer.tipPost{value: 10}(1, address(0), 10);
        assertEq(owner.balance, authorBefore + 10);
    }

    function test_tipPost_onHiddenThenUnhiddenPostWorks() public {
        vm.startPrank(owner);
        layer.hidePost(1);
        layer.unhidePost(1);
        vm.stopPrank();
        uint256 authorBefore = owner.balance;

        vm.prank(alice);
        layer.tipPost{value: 50}(1, address(0), 50);
        assertEq(owner.balance, authorBefore + 50);
    }

    // ---- revert conditions and order ----

    function test_RevertWhen_postDoesNotExist() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IPostRegistry.PostNotFound.selector, 99));
        layer.tipPost{value: 50}(99, address(0), 50);
    }

    function test_RevertWhen_postIsHidden() public {
        vm.prank(owner);
        layer.hidePost(1);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ITipping.PostHiddenCannotBeTipped.selector, 1));
        layer.tipPost{value: 50}(1, address(0), 50);
    }

    function test_RevertWhen_authorTipsOwnPost() public {
        vm.deal(owner, 1 ether);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ITipping.AuthorCannotTipOwnPost.selector, 1));
        layer.tipPost{value: 50}(1, address(0), 50);
    }

    function test_RevertWhen_hiddenCheckComesBeforeOwnPostCheck() public {
        vm.startPrank(owner);
        layer.hidePost(1);
        vm.deal(owner, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(ITipping.PostHiddenCannotBeTipped.selector, 1));
        layer.tipPost{value: 50}(1, address(0), 50);
        vm.stopPrank();
    }

    function test_RevertWhen_ownPostCheckComesBeforeTokenCheck() public {
        MockToken other = new MockToken();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ITipping.AuthorCannotTipOwnPost.selector, 1));
        layer.tipPost(1, address(other), 500);
    }

    function test_RevertWhen_minimumCheckComesBeforeValueCheck() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ITipping.TipBelowMinimum.selector, address(token), 50, 100));
        layer.tipPost{value: 1}(1, address(token), 50);
    }

    function test_RevertWhen_tokenIsNotApproved() public {
        MockToken other = new MockToken();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ITipping.TokenNotAllowed.selector, address(other)));
        layer.tipPost(1, address(other), 500);
    }

    function test_RevertWhen_tokenWasDisallowed() public {
        vm.prank(owner);
        layer.setTokenDisallowed(address(token));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ITipping.TokenNotAllowed.selector, address(token)));
        layer.tipPost(1, address(token), 500);
    }

    function test_RevertWhen_tipIsBelowMinimum() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ITipping.TipBelowMinimum.selector, address(0), 9, 10));
        layer.tipPost{value: 9}(1, address(0), 9);
    }

    function test_RevertWhen_tipAmountIsZero() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ITipping.TipBelowMinimum.selector, address(token), 0, 100));
        layer.tipPost(1, address(token), 0);
    }

    function test_RevertWhen_nativeValueDiffersFromAmount() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ITipping.TipValueMismatch.selector, 50, 49));
        layer.tipPost{value: 49}(1, address(0), 50);
    }

    function test_RevertWhen_erc20TipCarriesNativeValue() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ITipping.TipValueMismatch.selector, 0, 1));
        layer.tipPost{value: 1}(1, address(token), 500);
    }

    function test_RevertWhen_erc20AllowanceIsMissing() public {
        address bob = makeAddr("bob");
        token.mint(bob, 1000);

        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(layer), 0, 500)
        );
        layer.tipPost(1, address(token), 500);
    }

    function test_RevertWhen_erc20ReturnsFalse() public {
        FalseReturnToken bad = new FalseReturnToken();
        vm.prank(owner);
        layer.setTokenAllowed(address(bad), 1);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(bad)));
        layer.tipPost(1, address(bad), 10);
    }

    function test_RevertWhen_authorIsBlocklistedByTheToken() public {
        BlocklistToken usdcLike = new BlocklistToken();
        usdcLike.mint(alice, 1000);
        vm.prank(alice);
        usdcLike.approve(address(layer), 1000);
        vm.startPrank(owner);
        layer.setTokenAllowed(address(usdcLike), 1);
        vm.stopPrank();
        usdcLike.setBlocked(owner, true);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BlocklistToken.Blocked.selector, owner));
        layer.tipPost(1, address(usdcLike), 100);

        assertEq(usdcLike.balanceOf(alice), 1000, "tipper keeps funds");
    }

    // ---- contract authors ----

    function _layerOwnedBy(address contractOwner) internal returns (SoloPostLayer) {
        bytes memory initData = abi.encodeCall(SoloPostLayer.initialize, (contractOwner));
        return SoloPostLayer(address(new ERC1967Proxy(address(implementation), initData)));
    }

    function test_RevertWhen_nativePayoutIsRejectedByAuthorContract() public {
        RejectingAuthor author = new RejectingAuthor();
        SoloPostLayer authoredLayer = _layerOwnedBy(address(author));
        author.publish(authoredLayer);
        vm.prank(address(author));
        authoredLayer.setTokenAllowed(address(0), 10);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ITipping.NativeTransferFailed.selector, address(author), 50));
        authoredLayer.tipPost{value: 50}(1, address(0), 50);

        assertEq(alice.balance, 1 ether, "tipper keeps funds");
        assertEq(address(authoredLayer).balance, 0);
    }

    function test_tipPost_blocksReentrancyFromAuthorContract() public {
        ReentrantAuthor author = new ReentrantAuthor();
        SoloPostLayer authoredLayer = _layerOwnedBy(address(author));
        author.publish(authoredLayer);
        vm.prank(address(author));
        authoredLayer.setTokenAllowed(address(0), 1);

        vm.prank(alice);
        authoredLayer.tipPost{value: 50}(1, address(0), 50);

        assertEq(bytes4(author.reentryRevertReason()), ITipping.ReentrantCall.selector);
        assertEq(address(author).balance, 50, "outer tip paid once");
        assertEq(address(authoredLayer).balance, 0);
    }

    // ---- fuzz ----

    function testFuzz_tipPost_native_movesExactlyTheAmount(uint256 amount) public {
        amount = bound(amount, 10, 1 ether);
        uint256 authorBefore = owner.balance;

        vm.prank(alice);
        layer.tipPost{value: amount}(1, address(0), amount);

        assertEq(owner.balance, authorBefore + amount);
        assertEq(alice.balance, 1 ether - amount);
        assertEq(address(layer).balance, 0);
    }

    function testFuzz_tipPost_erc20_movesExactlyTheAmount(uint256 amount) public {
        amount = bound(amount, 100, 1_000_000);

        vm.prank(alice);
        layer.tipPost(1, address(token), amount);

        assertEq(token.balanceOf(owner), amount);
        assertEq(token.balanceOf(alice), 1_000_000 - amount);
        assertEq(token.balanceOf(address(layer)), 0);
    }

    function testFuzz_tipPost_belowMinimumAlwaysReverts(uint256 amount) public {
        amount = bound(amount, 0, 99);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ITipping.TipBelowMinimum.selector, address(token), amount, 100));
        layer.tipPost(1, address(token), amount);
    }

    // ---- no plain transfers ----

    function test_RevertWhen_plainNativeTransferIsSent() public {
        vm.prank(alice);
        (bool ok,) = address(layer).call{value: 1}("");
        assertFalse(ok);
    }

    function test_storageLocation_matchesErc7201Formula() public pure {
        bytes32 computed =
            keccak256(abi.encode(uint256(keccak256("postlayer.storage.Tipping")) - 1)) & ~bytes32(uint256(0xff));
        assertEq(computed, TIPPING_GUARD_SLOT);
    }

    function test_tipPost_readsReentrancyGuardFromTheErc7201Slot() public {
        vm.store(address(layer), TIPPING_GUARD_SLOT, bytes32(uint256(1)));

        vm.prank(alice);
        vm.expectRevert(ITipping.ReentrantCall.selector);
        layer.tipPost{value: 50}(1, address(0), 50);
    }

    function test_tipPost_leavesReentrancyGuardIdleAfterATip() public {
        vm.prank(alice);
        layer.tipPost{value: 50}(1, address(0), 50);

        assertEq(uint256(vm.load(address(layer), TIPPING_GUARD_SLOT)), 0);
    }

    function test_RevertWhen_approvedTokenHasNoCode() public {
        address noCode = makeAddr("noCode");
        vm.prank(owner);
        layer.setTokenAllowed(noCode, 1);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, noCode));
        layer.tipPost(1, noCode, 5);
    }
}
