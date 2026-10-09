// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {SoloPostLayer} from "../../src/SoloPostLayer.sol";

/// @dev Test-only V2: adds a second namespaced storage module to prove upgrades keep existing state.
/// @custom:oz-upgrades-unsafe-allow missing-initializer
contract SoloPostLayerV2Mock is SoloPostLayer {
    /// @custom:storage-location erc7201:postlayer.storage.MockMarker
    struct MockMarkerStorage {
        uint256 marker;
    }

    bytes32 private constant MOCK_MARKER_STORAGE_LOCATION =
        keccak256(abi.encode(uint256(keccak256("postlayer.storage.MockMarker")) - 1)) & ~bytes32(uint256(0xff));

    function setMarker(uint256 newMarker) external onlyOwner {
        _getMockMarkerStorage().marker = newMarker;
    }

    function marker() external view returns (uint256) {
        return _getMockMarkerStorage().marker;
    }

    function _getMockMarkerStorage() private pure returns (MockMarkerStorage storage $) {
        bytes32 location = MOCK_MARKER_STORAGE_LOCATION;
        assembly {
            $.slot := location
        }
    }
}
