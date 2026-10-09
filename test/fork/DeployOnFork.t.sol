// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {DeploySoloPostLayer} from "../../script/DeploySoloPostLayer.s.sol";
import {DeterministicFactory} from "../../script/DeterministicFactory.sol";
import {PreflightDeployment} from "../../script/PreflightDeployment.s.sol";
import {SoloPostLayer} from "../../src/SoloPostLayer.sol";

/// @notice Runs the real deploy path on forks of every chain in CHAINS (env). Forge auto-loads ./.env, so CHAINS can be
/// set during plain `make test`; the test therefore also needs the explicit opt-in RELEASE_FORK_TEST=1, which only
/// `make test-fork-release` sets (through `script/release.sh fork-test`, which also exports each chain's `CHAIN_<id>_RPC_URL` and
/// `CHAIN_<id>_ID` from chains.json). Otherwise it is skipped and `make test` and `make ci` stay offline. With the opt-in set, an empty CHAINS fails instead of skipping. Answers: does the shipped (shanghai) bytecode deploy and work on each chain,
/// and is the proxy address identical everywhere.
contract DeployOnForkTest is Test {
    string internal constant SALT_LABEL = "postlayer-fork-test";

    function test_deployOnEveryConfiguredChain_givesTheSameWorkingProxy() public {
        if (keccak256(bytes(vm.envOr("RELEASE_FORK_TEST", string("")))) != keccak256("1")) {
            vm.skip(true, "RELEASE_FORK_TEST is not 1; fork test skipped");
        }
        string[] memory chainIds = _chainIds(vm.envOr("CHAINS", string("")));
        require(chainIds.length != 0, "RELEASE_FORK_TEST=1 but CHAINS is empty; set CHAINS in .env");

        address owner = makeAddr("fork-owner");
        address reader = makeAddr("fork-reader");
        DeploySoloPostLayer deployer = new DeploySoloPostLayer();
        bytes32 factoryCodehash = new PreflightDeployment().FACTORY_CODEHASH();
        (, address expectedProxy) = deployer.predict(owner, SALT_LABEL);

        for (uint256 i = 0; i < chainIds.length; ++i) {
            string memory prefix = string.concat("CHAIN_", chainIds[i]);
            vm.createSelectFork(vm.envString(string.concat(prefix, "_RPC_URL")));
            assertEq(block.chainid, vm.envUint(string.concat(prefix, "_ID")), "RPC reports the configured chain id");

            assertEq(DeterministicFactory.ADDRESS.codehash, factoryCodehash, chainIds[i]);

            (address implementation, address proxy) = deployer.deploy(owner, SALT_LABEL);
            assertEq(proxy, expectedProxy, "same proxy address on every chain");
            assertEq(SoloPostLayer(proxy).owner(), owner);
            assertEq(address(uint160(uint256(vm.load(proxy, ERC1967Utils.IMPLEMENTATION_SLOT)))), implementation);

            // Smoke path: publish, like, tip in the native coin.
            SoloPostLayer layer = SoloPostLayer(proxy);
            vm.startPrank(owner);
            uint256 postId = layer.publishPost(keccak256("blog"), "ipfs://fork-smoke", keccak256("body"));
            layer.setTokenAllowed(address(0), 1);
            vm.stopPrank();
            vm.deal(reader, 1 ether);
            uint256 readerBefore = reader.balance;
            uint256 authorBefore = owner.balance;
            uint256 contractBefore = proxy.balance;
            vm.startPrank(reader);
            layer.likePost(postId);
            layer.tipPost{value: 10}(postId, address(0), 10);
            vm.stopPrank();
            assertEq(reader.balance, readerBefore - 10, "reader paid the tip");
            assertEq(owner.balance, authorBefore + 10, "author received the tip");
            assertEq(proxy.balance, contractBefore, "contract keeps nothing");
            assertEq(layer.likeCount(postId), 1);
        }
    }

    /// @dev Splits `chains` on any whitespace (space, tab, newline) and drops empty entries.
    function _chainIds(string memory chains) private pure returns (string[] memory chainIds) {
        bytes memory raw = bytes(chains);
        string[] memory buffer = new string[](raw.length);
        uint256 count;
        uint256 start;
        for (uint256 i = 0; i <= raw.length; ++i) {
            bool isSeparator = i == raw.length || raw[i] == " " || raw[i] == "\t" || raw[i] == "\n" || raw[i] == "\r";
            if (!isSeparator) continue;
            if (i > start) buffer[count++] = string(_slice(raw, start, i));
            start = i + 1;
        }
        chainIds = new string[](count);
        for (uint256 i = 0; i < count; ++i) {
            chainIds[i] = buffer[i];
        }
    }

    function _slice(bytes memory data, uint256 from, uint256 to) private pure returns (bytes memory part) {
        part = new bytes(to - from);
        for (uint256 i = 0; i < part.length; ++i) {
            part[i] = data[from + i];
        }
    }
}
