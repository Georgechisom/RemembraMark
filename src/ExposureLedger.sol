// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {MarkTypes} from "./libraries/MarkTypes.sol";

// Manages the storage and lifecycle of exposure marks.
// Handles mark creation, resolution, and state validation.
// Does NOT implement economic settlement mechanics in this version.
contract ExposureLedger {
    using MarkTypes for *;

    // Mapping from mark ID to exposure mark
    mapping(bytes32 => MarkTypes.ExposureMark) private _marks;

    // Emitted when a new exposure mark is created
    event ExposureMarked(
        bytes32 indexed markId,
        PoolId indexed poolId,
        address indexed swapper,
        int24 tickAtMark,
        int256 swapAmountSpecified,
        bool zeroForOne,
        uint256 creationBlock
    );

    // Emitted when a mark is resolved
    event MarkResolved(
        bytes32 indexed markId, PoolId indexed poolId, MarkTypes.MarkStatus status, uint256 resolutionBlock
    );

    // Mark does not exist
    error MarkNotFound(bytes32 markId);

    // Mark already exists
    error MarkAlreadyExists(bytes32 markId);

    // Invalid state transition attempted
    error InvalidStateTransition(MarkTypes.MarkStatus from, MarkTypes.MarkStatus to);

    // Mark is not in Open status
    error MarkNotOpen(bytes32 markId);

    // Create a new open exposure mark.
    // Mark ID is deterministically computed from parameters.
    function createMark(
        PoolId poolId,
        address swapper,
        int24 tickAtMark,
        int256 swapAmountSpecified,
        bool zeroForOne
    ) internal returns (bytes32 markId) {
        markId = MarkTypes.computeMarkId(poolId, swapper, tickAtMark, block.number);

        if (_marks[markId].creationBlock != 0) {
            revert MarkAlreadyExists(markId);
        }

        _marks[markId] = MarkTypes.ExposureMark({
            poolId: poolId,
            tickAtMark: tickAtMark,
            creationBlock: block.number,
            resolutionBlock: 0,
            swapAmountSpecified: swapAmountSpecified,
            zeroForOne: zeroForOne,
            status: MarkTypes.MarkStatus.Open,
            swapper: swapper
        });

        emit ExposureMarked(markId, poolId, swapper, tickAtMark, swapAmountSpecified, zeroForOne, block.number);
    }

    // Resolve an open mark to Confirmed status.
    // Only valid from Open status.
    function confirmMark(bytes32 markId) internal {
        MarkTypes.ExposureMark storage mark = _marks[markId];

        if (mark.creationBlock == 0) {
            revert MarkNotFound(markId);
        }

        if (mark.status != MarkTypes.MarkStatus.Open) {
            revert MarkNotOpen(markId);
        }

        mark.status = MarkTypes.MarkStatus.Confirmed;
        mark.resolutionBlock = block.number;

        emit MarkResolved(markId, mark.poolId, MarkTypes.MarkStatus.Confirmed, block.number);
    }

    // Resolve an open mark to Cleared status.
    // Only valid from Open status.
    function clearMark(bytes32 markId) internal {
        MarkTypes.ExposureMark storage mark = _marks[markId];

        if (mark.creationBlock == 0) {
            revert MarkNotFound(markId);
        }

        if (mark.status != MarkTypes.MarkStatus.Open) {
            revert MarkNotOpen(markId);
        }

        mark.status = MarkTypes.MarkStatus.Cleared;
        mark.resolutionBlock = block.number;

        emit MarkResolved(markId, mark.poolId, MarkTypes.MarkStatus.Cleared, block.number);
    }

    // Get an exposure mark by ID.
    function getMark(bytes32 markId) public view virtual returns (MarkTypes.ExposureMark memory mark) {
        mark = _marks[markId];
        if (mark.creationBlock == 0) {
            revert MarkNotFound(markId);
        }
    }

    // Check if a mark exists.
    function markExists(bytes32 markId) public view virtual returns (bool exists) {
        return _marks[markId].creationBlock != 0;
    }

    // Get the status of a mark.
    function getMarkStatus(bytes32 markId) public view virtual returns (MarkTypes.MarkStatus status) {
        MarkTypes.ExposureMark storage mark = _marks[markId];
        if (mark.creationBlock == 0) {
            revert MarkNotFound(markId);
        }
        return mark.status;
    }
}
