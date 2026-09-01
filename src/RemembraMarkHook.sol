// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {ExposureLedger} from "./ExposureLedger.sol";
import {MarkTypes} from "./libraries/MarkTypes.sol";
import {IRemembraMark} from "./interfaces/IRemembraMark.sol";

// An exposure-memory hook for Uniswap v4.
//
// CURRENT SCOPE:
// This implementation observes swaps at the pool level and creates exposure marks
// based on swap parameters. It does NOT yet attribute exposure to specific liquidity
// ranges or positions.
//
// IMPORTANT DISTINCTION:
// - SWAP OBSERVATION: Recording that a swap occurred (implemented)
// - LIQUIDITY EXPOSURE ATTRIBUTION: Identifying which LP ranges were affected (not implemented)
//
// The current hook callbacks (beforeSwap/afterSwap) provide:
// - Pool-level price/tick changes
// - Swap size and direction
// - Sender address
//
// The current hook callbacks do NOT directly provide:
// - Which specific liquidity positions were crossed
// - How much liquidity was utilized in each tick range
// - Individual LP position identifiers
//
// FUTURE DEVELOPMENT:
// Range-level exposure attribution will require either:
// 1. Additional hook permissions (beforeAddLiquidity/afterAddLiquidity to track ranges)
// 2. Off-chain indexing of liquidity positions with on-chain verification
// 3. Integration with Position Manager state
// 4. Custom accounting layer that maintains range→LP mapping
//
// The current architecture provides a clean foundation for adding range-level
// attribution without requiring a full rewrite.
contract RemembraMarkHook is BaseHook, ExposureLedger, IRemembraMark {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // Emitted when a swap is observed (not necessarily material enough to create a mark)
    event SwapObserved(
        PoolId indexed poolId,
        address indexed swapper,
        int24 tickBefore,
        int24 tickAfter,
        int256 amountSpecified,
        bool zeroForOne
    );

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    // Define hook permissions.
    // Only enables beforeSwap and afterSwap for minimal critical-path logic.
    //
    // NOTEs: Future range-level exposure tracking may require adding:
    // - beforeAddLiquidity / afterAddLiquidity (to track LP positions)
    // - beforeRemoveLiquidity / afterRemoveLiquidity (to track position changes)
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // Hook called before a swap is executed.
    // Observes pool state before the swap.
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // Observe pre-swap state
        // Future: This is where pre-swap exposure assessment could occur
        poolManager.getSlot0(key.toId());

        // Minimal observation - no blocking logic
        // Economic assessment logic will be developed separately

        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    // Hook called after a swap is executed.
    // Evaluates whether the swap created material exposure and creates a mark if needed.
    //
    // CURRENT BEHAVIOR:
    // Observes all swaps but does NOT create marks because materiality assessment
    // returns false. This prevents premature mark creation with arbitrary thresholds.
    //
    // SwapObserved events are emitted for all swaps regardless of materiality.
    // ExposureMarked events are only emitted when a mark is actually created.
    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        PoolId poolId = key.toId();

        // Get post-swap tick
        (, int24 tickAfter,,) = poolManager.getSlot0(poolId);

        // Emit observation event (always emitted, regardless of materiality)
        emit SwapObserved(poolId, sender, 0, tickAfter, params.amountSpecified, params.zeroForOne);

        // Check if swap is material enough to create an exposure mark
        bool shouldCreateMark = _assessMateriality(params, delta);

        // Only create mark if material (currently always false)
        if (shouldCreateMark) {
            createMark(poolId, sender, tickAfter, params.amountSpecified, params.zeroForOne);
            // ExposureMarked event emitted by createMark() in ledger
        }

        return (BaseHook.afterSwap.selector, 0);
    }

    // Assess whether a swap creates material exposure.
    //
    // CURRENT IMPLEMENTATION:
    // Returns false for all swaps. This is intentionally conservative.
    // No marks are created until proper economic criteria are defined.
    //
    // FUTURE IMPLEMENTATION WILL EVALUATE:
    // - Swap size relative to pool liquidity
    // - Price impact magnitude
    // - Tick displacement
    // - Liquidity utilization
    // - Historical swap patterns
    // - Pool-specific parameters
    //
    // RESEARCH QUESTIONS:
    // 1. What defines "material" in different pool contexts?
    // 2. Should we use absolute amounts, relative price impact, or liquidity utilization?
    // 3. How to prevent manipulation through repeated small swaps?
    // 4. Should materiality depend on swap direction or tick range?
    // 5. How to normalize across pools with different characteristics?
    function _assessMateriality(SwapParams calldata, BalanceDelta) internal pure returns (bool) {
        // Return false until economic model is implemented
        return false;
    }

    // Resolve a mark to Confirmed or Cleared status.
    //
    // PERMISSIONLESS RESOLUTION WITH ELIGIBILITY CHECK:
    // Anyone can call this function, but resolution only succeeds if the mark
    // meets eligibility criteria defined in canResolveMark().
    //
    // This approach avoids centralized control while preventing arbitrary resolution.
    // The economics are enforced through eligibility logic, not access control.
    //
    // CURRENT BEHAVIOR:
    // canResolveMark() returns false for all marks, so resolution always fails.
    // This prevents premature resolution until economic conditions are implemented.
    function resolveMark(bytes32 markId, bool confirmed) external {
        // Check eligibility before allowing resolution
        if (!canResolveMark(markId)) {
            revert MarkNotEligibleForResolution(markId);
        }

        // Eligibility confirmed, proceed with state transition
        if (confirmed) {
            confirmMark(markId);
        } else {
            clearMark(markId);
        }
    }

    // Compute the deterministic mark ID for given parameters.
    // Notes: External callers cannot compute mark ID without knowing the nonce,
    // which is assigned during mark creation. This is by design.
    function computeMarkId(PoolId poolId, address swapper, int24 tick, uint256 blockNumber)
        external
        pure
        override
        returns (bytes32)
    {
        // External callers cannot predict nonce, so this is informational only
        // Actual mark IDs are computed during createMark() with the current nonce
        return MarkTypes.computeMarkId(poolId, swapper, tick, blockNumber, 0);
    }

    // Get an exposure mark by its identifier.
    function getMark(bytes32 markId)
        public
        view
        override(ExposureLedger, IRemembraMark)
        returns (MarkTypes.ExposureMark memory)
    {
        return super.getMark(markId);
    }

    // Check if a mark exists.
    function markExists(bytes32 markId) public view override(ExposureLedger, IRemembraMark) returns (bool) {
        return super.markExists(markId);
    }

    // Get the status of a mark.
    function getMarkStatus(bytes32 markId)
        public
        view
        override(ExposureLedger, IRemembraMark)
        returns (MarkTypes.MarkStatus)
    {
        return super.getMarkStatus(markId);
    }

    // Check if a mark is eligible for resolution.
    function canResolveMark(bytes32 markId) public view override(ExposureLedger, IRemembraMark) returns (bool) {
        return super.canResolveMark(markId);
    }
}
