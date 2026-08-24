// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {MarkTypes} from "../libraries/MarkTypes.sol";

// IRemembraMark
// External interface for the RemembraMark protocol.
// Provides read access to exposure marks and protocol state.
interface IRemembraMark {
    // Get an exposure mark by its identifier.
    // markId The mark identifier
    // mark The exposure mark structure
    function getMark(bytes32 markId) external view returns (MarkTypes.ExposureMark memory mark);

    // Check if a mark exists.
    // markId The mark identifier
    // exists True if the mark exists
    function markExists(bytes32 markId) external view returns (bool exists);

    // Get the status of a mark.
    // markId The mark identifier
    // status The current status of the mark
    function getMarkStatus(bytes32 markId) external view returns (MarkTypes.MarkStatus status);

    // Compute the deterministic mark ID for given parameters.
    // poolId The pool identifier
    // swapper The swapper address
    // tick The tick at mark creation
    // blockNumber The block number
    // returns markId The computed mark identifier
    function computeMarkId(PoolId poolId, address swapper, int24 tick, uint256 blockNumber)
        external
        pure
        returns (bytes32 markId);
}
