// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Pramod Kodag
pragma solidity 0.8.37;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PostRegistryModule} from "./modules/PostRegistryModule.sol";
import {ReactionModule} from "./modules/ReactionModule.sol";
import {TippingModule} from "./modules/TippingModule.sol";

/// @title SoloPostLayer
/// @notice Solo mode: a single owner publishes posts; anyone can like and tip them; the contract is a UUPS-upgradeable proxy target.
contract SoloPostLayer is
    Initializable,
    Ownable2StepUpgradeable,
    UUPSUpgradeable,
    PostRegistryModule,
    ReactionModule,
    TippingModule
{
    error RenounceOwnershipDisabled();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address initialOwner) external initializer {
        __Ownable_init(initialOwner);
        __Ownable2Step_init();
    }

    /// @dev Disabled: a single mistaken call must not permanently lock posting and upgrades.
    /// A deliberate one-way upgrade lock is a separate future feature.
    function renounceOwnership() public view override onlyOwner {
        revert RenounceOwnershipDisabled();
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    function _authorizePostWrite() internal view override {
        _checkOwner();
    }

    function _authorizeTokenConfig() internal view override {
        _checkOwner();
    }
}
