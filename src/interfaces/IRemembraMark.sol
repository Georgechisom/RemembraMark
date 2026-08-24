// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {MarkTypes} from "../libraries/MarkTypes.sol";

// External interface for the RemembraMark protocol.
// Provides read access to exposure marks and protocol state.
interface IRemembraMark {
    // Get an exposure mark by its identifier.
    function getMark(bytes32 markId) external view returns (MarkTypes.ExposureMark memory mark);

    // Check if a mark exists.
    function markExists(bytes32 markId) external view returns (bool exists);

    // Get the status of a mark.
    function getMarkStatus(bytes32 markId) external view returns (MarkTypes.MarkStatus status);

    // Check if a mark is eligible for resolution.
    function canResolveMark(bytes32 markId) external view returns (bool eligible);

    // Compute a mark ID for informational purposes.
    // Note: Actual mark IDs include a nonce assigned during creation.
    function computeMarkId(PoolId poolId, address swapper, int24 tick, uint256 blockNumber)
        external
        pure
        returns (bytes32 markId);
}
