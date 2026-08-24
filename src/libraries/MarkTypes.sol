// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

// MarkTypes
// Core data structures for RemembraMark exposure marks.
// Defines the state model and data types for tracking liquidity exposure.
library MarkTypes {
    
    // Lifecycle status of an exposure mark.
    // Valid transitions:
    //      Open → Confirmed
    //      Open → Cleared
    //      
    //      Invalid transitions:
    //      Confirmed → Open
    //      Confirmed → Cleared
    //      Cleared → Open
    //      Cleared → Confirmed
    enum MarkStatus {
        Open,      // Mark created, awaiting observation window
        Confirmed, // Exposure confirmed by subsequent market movement
        Cleared    // Exposure cleared, no material impact observed
    }

    // Core structure for an exposure mark.
    // poolId The unique identifier for the pool where exposure occurred
    // tickAtMark The tick at the time the mark was created
    // creationBlock The block number when the mark was opened
    // resolutionBlock The block number when the mark was resolved (0 if still open)
    // swapAmountSpecified The specified swap amount (can be negative for exactOutput)
    // zeroForOne The direction of the swap that created the mark
    // status The current lifecycle status of the mark
    // swapper The address that initiated the swap creating this mark
    struct ExposureMark {
        PoolId poolId;
        int24 tickAtMark;
        uint256 creationBlock;
        uint256 resolutionBlock;
        int256 swapAmountSpecified;
        bool zeroForOne;
        MarkStatus status;
        address swapper;
    }

    // Generate a deterministic mark identifier.
    // Uses poolId, swapper, tick, and block to create collision-resistant ID.
    // poolId The pool identifier
    // swapper The address that initiated the swap
    // tick The tick at mark creation
    // blockNumber The block number of mark creation
    // markId The deterministic mark identifier
    function computeMarkId(PoolId poolId, address swapper, int24 tick, uint256 blockNumber)
        internal
        pure
        returns (bytes32 markId)
    {
        markId = keccak256(abi.encodePacked(poolId, swapper, tick, blockNumber));
    }
}
