// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {DeterministicFactory} from "../script/DeterministicFactory.sol";
import {DeploySoloPostLayer} from "../script/DeploySoloPostLayer.s.sol";
import {DeploymentGuards} from "../script/DeploymentGuards.sol";
import {SoloPostLayer} from "../src/SoloPostLayer.sol";

contract DeploySoloPostLayerTest is Test {
    string internal constant LABEL = "postlayer-test";

    address internal owner = makeAddr("owner");
    DeploySoloPostLayer internal deployer;

    function setUp() public {
        vm.etch(DeterministicFactory.ADDRESS, DeterministicFactory.RUNTIME_CODE);
        deployer = new DeploySoloPostLayer();
    }

    function test_deploy_createsContractsAtPredictedAddresses() public {
        (address predictedImplementation, address predictedProxy) = deployer.predict(owner, LABEL);
        assertEq(predictedImplementation.code.length, 0);
        assertEq(predictedProxy.code.length, 0);

        (address implementation, address proxy) = deployer.deploy(owner, LABEL);

        assertEq(implementation, predictedImplementation);
        assertEq(proxy, predictedProxy);
        assertGt(implementation.code.length, 0);
        assertGt(proxy.code.length, 0);
    }

    function test_factoryRuntimeCode_matchesCanonicalCodehash() public pure {
        assertEq(
            keccak256(DeterministicFactory.RUNTIME_CODE),
            0x2fa86add0aed31f33a762c9d88e807c475bd51d0f52bd0955754b2608f7e4989
        );
    }

    function test_deploy_completesWhenOnlyImplementationExists() public {
        (address predictedImplementation, address predictedProxy) = deployer.predict(owner, LABEL);
        (bool ok,) = DeterministicFactory.ADDRESS
            .call(abi.encodePacked(keccak256(abi.encode(LABEL, "implementation")), type(SoloPostLayer).creationCode));
        assertTrue(ok);
        assertGt(predictedImplementation.code.length, 0);
        assertEq(predictedProxy.code.length, 0);

        (address implementation, address proxy) = deployer.deploy(owner, LABEL);

        assertEq(implementation, predictedImplementation);
        assertEq(proxy, predictedProxy);
        assertEq(SoloPostLayer(proxy).owner(), owner);
    }

    function test_deploy_proxyIsInitializedWithOwnerAndPointsToImplementation() public {
        (address implementation, address proxy) = deployer.deploy(owner, LABEL);

        assertEq(SoloPostLayer(proxy).owner(), owner);
        assertEq(address(uint160(uint256(vm.load(proxy, ERC1967Utils.IMPLEMENTATION_SLOT)))), implementation);
    }

    function test_deploy_proxyCannotBeInitializedAgain() public {
        (, address proxy) = deployer.deploy(owner, LABEL);

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        SoloPostLayer(proxy).initialize(makeAddr("attacker"));
    }

    function test_deploy_implementationCannotBeInitialized() public {
        (address implementation,) = deployer.deploy(owner, LABEL);

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        SoloPostLayer(implementation).initialize(makeAddr("attacker"));
    }

    function test_deploy_isIdempotent() public {
        (address implementation, address proxy) = deployer.deploy(owner, LABEL);

        (address implementationAgain, address proxyAgain) = deployer.deploy(owner, LABEL);

        assertEq(implementationAgain, implementation);
        assertEq(proxyAgain, proxy);
    }

    function test_deploy_sameInputsGiveSameAddressesOnAnotherChain() public {
        uint256 freshChain = vm.snapshotState();
        (address implementation, address proxy) = deployer.deploy(owner, LABEL);

        // Back to a fresh chain state (factory installed, nothing deployed) with a different chain id.
        vm.revertToState(freshChain);
        vm.chainId(31338);
        assertEq(block.chainid, 31338);
        assertEq(proxy.code.length, 0);
        (address implementationB, address proxyB) = deployer.deploy(owner, LABEL);

        assertEq(implementationB, implementation);
        assertEq(proxyB, proxy);
    }

    function test_deploy_differentOwnerGivesDifferentProxyAndSameImplementation() public {
        (address implementationA, address proxyA) = deployer.predict(owner, LABEL);
        (address implementationB, address proxyB) = deployer.predict(makeAddr("otherOwner"), LABEL);

        assertEq(implementationB, implementationA);
        assertTrue(proxyB != proxyA);
    }

    function test_deploy_differentLabelGivesDifferentAddresses() public view {
        (address implementationA, address proxyA) = deployer.predict(owner, LABEL);
        (address implementationB, address proxyB) = deployer.predict(owner, "another-label");

        assertTrue(implementationB != implementationA);
        assertTrue(proxyB != proxyA);
    }

    function test_RevertWhen_factoryIsNotDeployed() public {
        vm.etch(DeterministicFactory.ADDRESS, "");

        vm.expectRevert(DeploySoloPostLayer.FactoryNotDeployed.selector);
        deployer.deploy(owner, LABEL);
    }

    function test_RevertWhen_saltLabelIsEmpty() public {
        vm.expectRevert(DeploySoloPostLayer.EmptySaltLabel.selector);
        deployer.deploy(owner, "");
    }

    function test_RevertWhen_ownerIsZero() public {
        vm.expectRevert(DeploySoloPostLayer.ZeroOwner.selector);
        deployer.deploy(address(0), LABEL);
    }

    // run() is what `forge script --broadcast` executes: it must refuse before broadcasting anything.
    function _setRunEnv(uint256 expectedChainId, address runOwner, string memory ownerIsEoa) internal {
        vm.setEnv("OWNER", vm.toString(runOwner));
        vm.setEnv("SALT_LABEL", LABEL);
        vm.setEnv("EXPECTED_CHAIN_ID", vm.toString(expectedChainId));
        vm.setEnv("OWNER_IS_EOA", ownerIsEoa);
    }

    function test_run_deploysWhenOwnerIsAnEoaDeclaredAsSuch() public {
        _setRunEnv(block.chainid, owner, "true");

        (, address proxy) = deployer.run();

        assertEq(SoloPostLayer(proxy).owner(), owner);
    }

    function test_run_deploysWhenOwnerHasCode() public {
        vm.etch(owner, hex"00");
        _setRunEnv(block.chainid, owner, "false");

        (, address proxy) = deployer.run();

        assertEq(SoloPostLayer(proxy).owner(), owner);
    }

    // A contract-wallet owner (for example a Safe) missing on this chain could later be claimed by whoever deploys
    // code at that address, so the broadcast itself must refuse, with or without a prior preflight.
    function test_RevertWhen_runOwnerHasNoCodeAndIsNotDeclaredAnEoa() public {
        _setRunEnv(block.chainid, owner, "false");

        vm.expectRevert(abi.encodeWithSelector(DeploymentGuards.OwnerHasNoCode.selector, block.chainid, owner));
        deployer.run();
    }

    function test_RevertWhen_runChainIsNotTheExpectedOne() public {
        _setRunEnv(1, owner, "true");

        vm.expectRevert(abi.encodeWithSelector(DeploymentGuards.WrongChainId.selector, 1, block.chainid));
        deployer.run();
    }

    function test_RevertWhen_runFactoryCodeIsDifferent() public {
        vm.etch(DeterministicFactory.ADDRESS, hex"00");
        _setRunEnv(block.chainid, owner, "true");

        vm.expectRevert(
            abi.encodeWithSelector(DeploymentGuards.FactoryCodehashMismatch.selector, block.chainid, keccak256(hex"00"))
        );
        deployer.run();
    }

    function test_RevertWhen_runFactoryIsMissing() public {
        vm.etch(DeterministicFactory.ADDRESS, "");
        _setRunEnv(block.chainid, owner, "true");

        vm.expectRevert(abi.encodeWithSelector(DeploymentGuards.FactoryMissing.selector, block.chainid));
        deployer.run();
    }

    function test_RevertWhen_runHasNoExpectedChainId() public {
        _setRunEnv(block.chainid, owner, "true");
        vm.setEnv("EXPECTED_CHAIN_ID", "");

        vm.expectRevert();
        deployer.run();
    }
}
