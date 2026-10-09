// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {DeterministicFactory} from "../script/DeterministicFactory.sol";
import {DeploySoloPostLayer} from "../script/DeploySoloPostLayer.s.sol";
import {PreflightDeployment} from "../script/PreflightDeployment.s.sol";
import {DeploymentGuards} from "../script/DeploymentGuards.sol";

contract PreflightDeploymentTest is Test {
    uint256 internal constant CHAIN_ID = 84532;
    address internal deployer = makeAddr("deployer");
    address internal contractOwner = makeAddr("contractOwner");
    address internal eoaOwner = makeAddr("eoaOwner");
    bytes32 internal constant OWNER_CODEHASH = keccak256(hex"00");
    PreflightDeployment internal preflight;

    function setUp() public {
        preflight = new PreflightDeployment();
        vm.chainId(CHAIN_ID);
        vm.etch(DeterministicFactory.ADDRESS, DeterministicFactory.RUNTIME_CODE);
        vm.deal(deployer, 1 ether);
        vm.etch(contractOwner, hex"00");
    }

    function test_factoryRuntimeCode_matchesPinnedCodehash() public view {
        assertEq(DeterministicFactory.ADDRESS.codehash, preflight.FACTORY_CODEHASH());
    }

    function test_checkChain_passesWhenEverythingIsInPlace() public view {
        preflight.checkChain(CHAIN_ID, deployer, contractOwner, false, OWNER_CODEHASH);
    }

    function test_RevertWhen_chainIdDiffers() public {
        vm.expectRevert(abi.encodeWithSelector(DeploymentGuards.WrongChainId.selector, 1, CHAIN_ID));
        preflight.checkChain(1, deployer, contractOwner, false, OWNER_CODEHASH);
    }

    function test_RevertWhen_factoryIsMissing() public {
        vm.etch(DeterministicFactory.ADDRESS, "");
        vm.expectRevert(abi.encodeWithSelector(DeploymentGuards.FactoryMissing.selector, CHAIN_ID));
        preflight.checkChain(CHAIN_ID, deployer, contractOwner, false, OWNER_CODEHASH);
    }

    function test_RevertWhen_factoryCodeIsDifferent() public {
        vm.etch(DeterministicFactory.ADDRESS, hex"00");
        vm.expectRevert(
            abi.encodeWithSelector(DeploymentGuards.FactoryCodehashMismatch.selector, CHAIN_ID, keccak256(hex"00"))
        );
        preflight.checkChain(CHAIN_ID, deployer, contractOwner, false, OWNER_CODEHASH);
    }

    function test_RevertWhen_deployerHasNoFunds() public {
        vm.deal(deployer, 0);
        vm.expectRevert(abi.encodeWithSelector(PreflightDeployment.DeployerHasNoFunds.selector, CHAIN_ID, deployer));
        preflight.checkChain(CHAIN_ID, deployer, contractOwner, false, OWNER_CODEHASH);
    }

    function test_checkChain_passesForAnEoaOwnerWhenDeclared() public view {
        preflight.checkChain(CHAIN_ID, deployer, eoaOwner, true, bytes32(0));
    }

    // A contract-wallet owner (for example a Safe) that is not deployed on this chain could later be owned by
    // whoever deploys code at that address; an EOA owner must be declared explicitly.
    function test_RevertWhen_ownerHasNoCodeAndIsNotDeclaredAnEoa() public {
        vm.expectRevert(abi.encodeWithSelector(DeploymentGuards.OwnerHasNoCode.selector, CHAIN_ID, eoaOwner));
        preflight.checkChain(CHAIN_ID, deployer, eoaOwner, false, OWNER_CODEHASH);
    }

    // The same Safe address can be claimed on another chain by a different contract. The owner's code on each chain
    // must hash to the value the operator pinned, so a different contract at OWNER is refused.
    function test_RevertWhen_ownerCodeIsNotThePinnedOne() public {
        vm.etch(contractOwner, hex"6000");
        vm.expectRevert(
            abi.encodeWithSelector(
                DeploymentGuards.OwnerCodehashMismatch.selector,
                CHAIN_ID,
                contractOwner,
                OWNER_CODEHASH,
                keccak256(hex"6000")
            )
        );
        preflight.checkChain(CHAIN_ID, deployer, contractOwner, false, OWNER_CODEHASH);
    }

    // An unset pin must never pass: it would mean "any code is fine", which is the squatting hole.
    function test_RevertWhen_ownerHasCodeButNoCodehashIsPinned() public {
        vm.expectRevert(
            abi.encodeWithSelector(DeploymentGuards.OwnerCodehashNotPinned.selector, CHAIN_ID, contractOwner)
        );
        preflight.checkChain(CHAIN_ID, deployer, contractOwner, false, bytes32(0));
    }

    // An EOA owner has no code to pin; a pin next to OWNER_IS_EOA=true would be silently ignored, so it is refused.
    function test_RevertWhen_ownerIsDeclaredAnEoaButACodehashIsPinned() public {
        vm.expectRevert(
            abi.encodeWithSelector(DeploymentGuards.OwnerIsEoaWithCodehash.selector, CHAIN_ID, eoaOwner, OWNER_CODEHASH)
        );
        preflight.checkChain(CHAIN_ID, deployer, eoaOwner, true, OWNER_CODEHASH);
    }

    // The EOA flag must not switch the owner checks off: an address that has code is a contract wallet, whatever the
    // flag says (for example a reused testnet .env), and then the code hash pin is the check that applies.
    function test_RevertWhen_ownerIsDeclaredAnEoaButHasCode() public {
        vm.expectRevert(abi.encodeWithSelector(DeploymentGuards.OwnerIsEoaHasCode.selector, CHAIN_ID, contractOwner));
        preflight.checkChain(CHAIN_ID, deployer, contractOwner, true, bytes32(0));
    }

    // EIP-7702: an EOA that delegated to a contract has the 23 bytes 0xef0100 + delegate as its code and is still an EOA
    // controlled by its key, so it is accepted as one. Anything else with code is not.
    function test_checkChain_passesForAnEoaOwnerThatDelegatedWithEip7702() public {
        vm.etch(eoaOwner, abi.encodePacked(hex"ef0100", makeAddr("delegate")));
        preflight.checkChain(CHAIN_ID, deployer, eoaOwner, true, bytes32(0));
    }

    // Code with the delegation's length and plain contract code are refused unless it is exactly 0xef0100 + address.
    // A conforming post-London chain cannot deploy code starting with 0xef (EIP-3541), and vm.etch and anvil reject
    // 0xef01xx / 0xef00xx code of the delegation's length, so the other prefix bytes and lengths cannot be built here.
    function test_RevertWhen_ownerIsDeclaredAnEoaButHasCodeThatIsNotADelegation() public {
        address delegate = makeAddr("delegate");
        bytes[3] memory notDelegations = [
            abi.encodePacked(hex"6000", new bytes(21)), // 23 bytes, plain code
            abi.encodePacked(hex"ee0100", delegate), // 23 bytes, first byte differs
            abi.encodePacked(hex"ef", delegate) // 21 bytes, too short
        ];
        for (uint256 i = 0; i < notDelegations.length; ++i) {
            vm.etch(eoaOwner, notDelegations[i]);
            vm.expectRevert(abi.encodeWithSelector(DeploymentGuards.OwnerIsEoaHasCode.selector, CHAIN_ID, eoaOwner));
            preflight.checkChain(CHAIN_ID, deployer, eoaOwner, true, bytes32(0));
        }
    }

    // Declaring an EOA together with a pin is refused as that contradiction even when the owner has code, so the
    // operator is told to drop the pin instead of the code check hiding it.
    function test_RevertWhen_ownerIsDeclaredAnEoaWithAPinAndHasCode() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                DeploymentGuards.OwnerIsEoaWithCodehash.selector, CHAIN_ID, contractOwner, OWNER_CODEHASH
            )
        );
        preflight.checkChain(CHAIN_ID, deployer, contractOwner, true, OWNER_CODEHASH);
    }

    function test_RevertWhen_noChainsAreGiven() public {
        string[] memory rpcUrlEnvVars = new string[](0);
        uint256[] memory ids = new uint256[](0);
        vm.expectRevert(PreflightDeployment.NoChainsToCheck.selector);
        preflight.run(rpcUrlEnvVars, ids);
    }

    function test_RevertWhen_urlAndChainIdCountsDiffer() public {
        string[] memory rpcUrlEnvVars = new string[](1);
        rpcUrlEnvVars[0] = "UNUSED_RPC_URL";
        uint256[] memory ids = new uint256[](2);
        vm.expectRevert(PreflightDeployment.LengthMismatch.selector);
        preflight.run(rpcUrlEnvVars, ids);
    }

    // Called with explicit arguments: forge shares the process environment between parallel tests, so no test here writes it.
    function test_logPredicted_matchesTheDeployScript() public {
        address owner = makeAddr("owner");
        (address expectedImplementation, address expectedProxy) =
            new DeploySoloPostLayer().predict(owner, "postlayer-test");
        (address implementation, address proxy) = preflight.logPredicted(owner, "postlayer-test");
        assertEq(implementation, expectedImplementation);
        assertEq(proxy, expectedProxy);
    }

    function test_RevertWhen_logPredictedSaltLabelIsEmpty() public {
        vm.expectRevert(DeploySoloPostLayer.EmptySaltLabel.selector);
        preflight.logPredicted(makeAddr("owner"), "");
    }
}
