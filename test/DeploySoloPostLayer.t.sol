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
    // The code hash a test owner contract is pinned to (its code is hex"00"); other code is "someone else's contract".
    bytes32 internal constant OWNER_CODEHASH = keccak256(hex"00");

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

    // broadcastDeploy is what `run` calls after reading the environment. It is tested with explicit arguments so no
    // test races on the process environment, which forge shares between parallel tests.
    function test_broadcastDeploy_deploysWhenOwnerIsAnEoaDeclaredAsSuch() public {
        (, address proxy) = deployer.broadcastDeploy(owner, LABEL, block.chainid, true, bytes32(0));

        assertEq(SoloPostLayer(proxy).owner(), owner);
    }

    function test_broadcastDeploy_deploysWhenOwnerHasCode() public {
        vm.etch(owner, hex"00");

        (, address proxy) = deployer.broadcastDeploy(owner, LABEL, block.chainid, false, OWNER_CODEHASH);

        assertEq(SoloPostLayer(proxy).owner(), owner);
    }

    // A contract-wallet owner (for example a Safe) missing on this chain could later be claimed by whoever deploys
    // code at that address, so the broadcast itself must refuse, with or without a prior preflight.
    function test_RevertWhen_broadcastDeployOwnerHasNoCodeAndIsNotDeclaredAnEoa() public {
        vm.expectRevert(abi.encodeWithSelector(DeploymentGuards.OwnerHasNoCode.selector, block.chainid, owner));
        deployer.broadcastDeploy(owner, LABEL, block.chainid, false, OWNER_CODEHASH);
    }

    function test_RevertWhen_broadcastDeployOwnerCodeIsNotThePinnedOne() public {
        vm.etch(owner, hex"6000");

        vm.expectRevert(
            abi.encodeWithSelector(
                DeploymentGuards.OwnerCodehashMismatch.selector,
                block.chainid,
                owner,
                OWNER_CODEHASH,
                keccak256(hex"6000")
            )
        );
        deployer.broadcastDeploy(owner, LABEL, block.chainid, false, OWNER_CODEHASH);
    }

    // No pin means "any code is fine", which is the squatting hole the pin exists to close.
    function test_RevertWhen_broadcastDeployOwnerHasCodeButNoCodehashIsPinned() public {
        vm.etch(owner, hex"00");

        vm.expectRevert(abi.encodeWithSelector(DeploymentGuards.OwnerCodehashNotPinned.selector, block.chainid, owner));
        deployer.broadcastDeploy(owner, LABEL, block.chainid, false, bytes32(0));
    }

    // An EOA owner has no code to pin; both settings together mean the operator is unsure what the owner is.
    function test_RevertWhen_broadcastDeployOwnerIsDeclaredAnEoaButACodehashIsPinned() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                DeploymentGuards.OwnerIsEoaWithCodehash.selector, block.chainid, owner, OWNER_CODEHASH
            )
        );
        deployer.broadcastDeploy(owner, LABEL, block.chainid, true, OWNER_CODEHASH);
    }

    // Declaring an address with code an EOA must not skip the owner checks, with or without a prior preflight.
    function test_RevertWhen_broadcastDeployOwnerIsDeclaredAnEoaButHasCode() public {
        vm.etch(owner, hex"00");

        vm.expectRevert(abi.encodeWithSelector(DeploymentGuards.OwnerIsEoaHasCode.selector, block.chainid, owner));
        deployer.broadcastDeploy(owner, LABEL, block.chainid, true, bytes32(0));
    }

    function test_RevertWhen_broadcastDeployOwnerIsDeclaredAnEoaWithAPinAndHasCode() public {
        vm.etch(owner, hex"00");

        vm.expectRevert(
            abi.encodeWithSelector(
                DeploymentGuards.OwnerIsEoaWithCodehash.selector, block.chainid, owner, OWNER_CODEHASH
            )
        );
        deployer.broadcastDeploy(owner, LABEL, block.chainid, true, OWNER_CODEHASH);
    }

    function test_broadcastDeploy_deploysWhenOwnerIsAnEoaThatDelegatedWithEip7702() public {
        vm.etch(owner, abi.encodePacked(hex"ef0100", makeAddr("delegate")));

        (, address proxy) = deployer.broadcastDeploy(owner, LABEL, block.chainid, true, bytes32(0));

        assertEq(SoloPostLayer(proxy).owner(), owner);
    }

    function test_RevertWhen_broadcastDeployChainIsNotTheExpectedOne() public {
        vm.expectRevert(abi.encodeWithSelector(DeploymentGuards.WrongChainId.selector, 1, block.chainid));
        deployer.broadcastDeploy(owner, LABEL, 1, true, bytes32(0));
    }

    function test_RevertWhen_broadcastDeployFactoryCodeIsDifferent() public {
        vm.etch(DeterministicFactory.ADDRESS, hex"00");

        vm.expectRevert(
            abi.encodeWithSelector(DeploymentGuards.FactoryCodehashMismatch.selector, block.chainid, keccak256(hex"00"))
        );
        deployer.broadcastDeploy(owner, LABEL, block.chainid, true, bytes32(0));
    }

    function test_RevertWhen_broadcastDeployFactoryIsMissing() public {
        vm.etch(DeterministicFactory.ADDRESS, "");

        vm.expectRevert(abi.encodeWithSelector(DeploymentGuards.FactoryMissing.selector, block.chainid));
        deployer.broadcastDeploy(owner, LABEL, block.chainid, true, bytes32(0));
    }

    // The one test that sets environment variables (forge shares the process environment between parallel tests, so
    // no other test may write OWNER, SALT_LABEL, EXPECTED_CHAIN_ID, OWNER_IS_EOA or OWNER_CODEHASH). It pins the
    // security defaults of `run`: an owner without code is refused unless OWNER_IS_EOA says true, so an empty value
    // must not mean EOA; and the owner's code hash must be given, well formed and equal to the owner's code.
    function test_run_readsTheOwnerSettingsFromTheEnvironment() public {
        vm.setEnv("OWNER", vm.toString(owner));
        vm.setEnv("SALT_LABEL", LABEL);
        vm.setEnv("EXPECTED_CHAIN_ID", vm.toString(block.chainid));
        vm.setEnv("OWNER_IS_EOA", "");
        vm.setEnv("OWNER_CODEHASH", "");

        // No code at the owner and not declared an EOA.
        vm.expectRevert(abi.encodeWithSelector(DeploymentGuards.OwnerHasNoCode.selector, block.chainid, owner));
        deployer.run();

        // The owner has code but no pin was given: refused as not pinned, not as a mismatch.
        vm.etch(owner, hex"00");
        vm.expectRevert(abi.encodeWithSelector(DeploymentGuards.OwnerCodehashNotPinned.selector, block.chainid, owner));
        deployer.run();

        // A value that is not a 32-byte hash is an error in itself, never read as "unset".
        vm.setEnv("OWNER_CODEHASH", "zz");
        vm.expectRevert();
        deployer.run();
        vm.setEnv("OWNER_CODEHASH", "0x12");
        vm.expectRevert();
        deployer.run();

        // A well-formed pin that is not the owner's code names both values.
        vm.setEnv("OWNER_CODEHASH", vm.toString(keccak256(hex"6000")));
        vm.expectRevert(
            abi.encodeWithSelector(
                DeploymentGuards.OwnerCodehashMismatch.selector,
                block.chainid,
                owner,
                keccak256(hex"6000"),
                OWNER_CODEHASH
            )
        );
        deployer.run();

        // The right pin deploys.
        vm.setEnv("OWNER_CODEHASH", vm.toString(OWNER_CODEHASH));
        (, address proxy) = deployer.run();
        assertEq(SoloPostLayer(proxy).owner(), owner);
    }
}
