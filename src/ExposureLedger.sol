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

    // Global nonce for ensuring mark ID uniqueness
    // Incremented on each mark creation
    uint256 private _markNonce;

    // Emitted when a new exposure mark is created
    event ExposureMarked(
        bytes32 indexed markId,
        PoolId indexed poolId,
        address indexed swapper,
        int24 tickAtMark,
        int256 swapAmountSpecified,
        bool zeroForOne,
        uint256 creationBlock,
        uint256 nonce
    );

    // Emitted when a mark is resolved
    event MarkResolved(
        bytes32 indexed markId, PoolId indexed poolId, MarkTypes.MarkStatus status, uint256 resolutionBlock
    );

    // Mark does not exist
    error MarkNotFound(bytes32 markId);

    // Mark already exists (should be impossible with nonce, defensive check)
    error MarkAlreadyExists(bytes32 markId);

    // Mark is not in Open status
    error MarkNotOpen(bytes32 markId);

    // Mark is not eligible for resolution
    error MarkNotEligibleForResolution(bytes32 markId);

    // Create a new open exposure mark.
    // Mark ID is deterministically computed from parameters plus unique nonce.
    function createMark(
        PoolId poolId,
        address swapper,
        int24 tickAtMark,
        int256 swapAmountSpecified,
        bool zeroForOne
    ) internal returns (bytes32 markId) {
        uint256 nonce = _markNonce++;
        
        markId = MarkTypes.computeMarkId(poolId, swapper, tickAtMark, block.number, nonce);

        // Defensive check - should be impossible with monotonic nonce
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
            swapper: swapper,
            nonce: nonce
        });

        emit ExposureMarked(markId, poolId, swapper, tickAtMark, swapAmountSpecified, zeroForOne, block.number, nonce);
    }

    // Check if a mark is eligible for resolution.
    // 
    // PLACEHOLDER: This is where economic resolution conditions will be evaluated.
    // Current implementation returns false for all marks, preventing arbitrary resolution.
    // 
    // Future implementation should check:
    // - Observation window has elapsed
    // - Price movement criteria met
    // - Market conditions observed
    // - No gaming/manipulation detected
    //
    // This separation between eligibility and state transition ensures clean architecture.
    function canResolveMark(bytes32 markId) public view virtual returns (bool eligible) {
        MarkTypes.ExposureMark storage mark = _marks[markId];
        
        // Mark must exist
        if (mark.creationBlock == 0) {
            return false;
        }
        
        // Mark must be in Open status
        if (mark.status != MarkTypes.MarkStatus.Open) {
            return false;
        }
        
        // Task: Add economic resolution conditions here
        // For now, return false to prevent premature/arbitrary resolution
        // This is intentionally conservative - resolution logic must be
        // explicitly implemented before marks can be resolved in production
        return false;
    }

    // Resolve an open mark to Confirmed status.
    // Only valid from Open status and when eligibility conditions are met.
    function confirmMark(bytes32 markId) internal {
        MarkTypes.ExposureMark storage mark = _marks[markId];

        if (mark.creationBlock == 0) {
            revert MarkNotFound(markId);
        }

        if (mark.status != MarkTypes.MarkStatus.Open) {
            revert MarkNotOpen(markId);
        }

        // Notes: Eligibility check intentionally not enforced here for internal calls
        // This allows the hook to resolve marks based on its own logic
        // External resolution functions should check canResolveMark()

        mark.status = MarkTypes.MarkStatus.Confirmed;
        mark.resolutionBlock = block.number;

        emit MarkResolved(markId, mark.poolId, MarkTypes.MarkStatus.Confirmed, block.number);
    }

    // Resolve an open mark to Cleared status.
    // Only valid from Open status and when eligibility conditions are met.
    function clearMark(bytes32 markId) internal {
        MarkTypes.ExposureMark storage mark = _marks[markId];

        if (mark.creationBlock == 0) {
            revert MarkNotFound(markId);
        }

        if (mark.status != MarkTypes.MarkStatus.Open) {
            revert MarkNotOpen(markId);
        }

        // Notes: Eligibility check intentionally not enforced here for internal calls
        // This allows the hook to resolve marks based on its own logic
        // External resolution functions should check canResolveMark()

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
