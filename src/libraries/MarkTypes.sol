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
        Open, // Mark created, awaiting observation window
        Confirmed, // Exposure confirmed by subsequent market movement
        Cleared // Exposure cleared, no material impact observed

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
    // nonce The hook-local nonce ensuring uniqueness within same block/tick/swapper
    // sqrtPriceAtMark The sqrt price (sqrtPriceX96) when mark was created, for resolution
    // exposureMagnitude Dimensionless exposure score; NOT quote-token or USD denominated
    struct ExposureMark {
        PoolId poolId;
        int24 tickAtMark;
        uint256 creationBlock;
        uint256 resolutionBlock;
        int256 swapAmountSpecified;
        bool zeroForOne;
        MarkStatus status;
        address swapper;
        uint256 nonce;
        uint160 sqrtPriceAtMark;
        uint256 exposureMagnitude;
    }

    // Generate a deterministic mark identifier.
    //
    // UNIQUENESS GUARANTEE:
    // The combination of (poolId, swapper, tick, blockNumber, nonce) is structurally unique.
    // A nonce is required because the same swapper can perform multiple swaps in the same
    // block at the same tick (e.g., via a contract making multiple calls, or flash accounting).
    //
    // The nonce is a hook-local monotonic counter that increments per mark creation.
    // This prevents collisions without requiring external transaction-specific data like
    // tx.origin (which is unsafe) or msg.sender (which may be a router/aggregator).
    //
    // Alternative approaches considered:
    // - tx.origin: Unsafe, can be manipulated via delegatecall patterns
    // - msg.sender in callback: Would be the PoolManager, not useful
    // - Transaction hash: Not available in EVM during execution
    // - Swap parameters as differentiator: Still allows collision (same params, same block)
    //
    // The nonce approach is clean, gas-efficient, and provides true uniqueness.
    function computeMarkId(PoolId poolId, address swapper, int24 tick, uint256 blockNumber, uint256 nonce)
        internal
        pure
        returns (bytes32 markId)
    {
        markId = keccak256(abi.encodePacked(poolId, swapper, tick, blockNumber, nonce));
    }
}
