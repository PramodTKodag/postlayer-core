// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SoloPostLayer} from "../../src/SoloPostLayer.sol";

/// @dev Well-behaved ERC-20.
contract MockToken is ERC20 {
    constructor() ERC20("Mock", "MCK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev ERC-20 whose transfers revert for blocked recipients (USDC/USDT style blocklist).
contract BlocklistToken is MockToken {
    error Blocked(address account);

    mapping(address => bool) public blocked;

    function setBlocked(address account, bool isBlocked) external {
        blocked[account] = isBlocked;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (blocked[to]) revert Blocked(to);
        super._update(from, to, value);
    }
}

/// @dev USDT-style token: `approve` and `transferFrom` return nothing.
contract NoReturnToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external {
        allowance[msg.sender][spender] = amount;
    }

    function transferFrom(address from, address to, uint256 amount) external {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

/// @dev Token whose `transferFrom` reports failure by returning false.
contract FalseReturnToken {
    function transferFrom(address, address, uint256) external pure returns (bool) {
        return false;
    }
}

/// @dev A contract that owns a layer (so it is the author of its posts) and rejects native coin.
contract RejectingAuthor {
    function publish(SoloPostLayer target) external {
        target.publishPost(keccak256("blog"), "ipfs://contract-author", keccak256("body"));
    }
}

/// @dev A contract author that tries to re-enter `tipPost` when it receives native coin.
contract ReentrantAuthor {
    SoloPostLayer internal target;
    bytes public reentryRevertReason;

    function publish(SoloPostLayer target_) external {
        target = target_;
        target_.publishPost(keccak256("blog"), "ipfs://contract-author", keccak256("body"));
    }

    receive() external payable {
        try target.tipPost{value: 1}(1, address(0), 1) {}
        catch (bytes memory reason) {
            reentryRevertReason = reason;
        }
    }
}
