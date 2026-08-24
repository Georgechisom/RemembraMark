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
// Tracks material swaps as exposure marks that can be confirmed or cleared
// based on subsequent market behavior.
//
// IMPORTANT: Economic parameters (materiality thresholds, confirmation logic,
// observation windows, and settlement mechanics) are intentionally left as
// research questions. Current implementation focuses on state architecture.
contract RemembraMarkHook is BaseHook, ExposureLedger, IRemembraMark {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // Emitted when swap observation logic is triggered
    event SwapObserved(PoolId indexed poolId, address indexed swapper, int24 tickBefore, int24 tickAfter);

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    // Define hook permissions.
    // Only enables beforeSwap and afterSwap for minimal critical-path logic.
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
    // Observes pool state before the swap. Currently captures tick information.
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // Observe pool state before swap
        // Future: This is where pre-swap exposure assessment could occur
        poolManager.getSlot0(key.toId());

        // Minimal observation - no blocking logic
        // Economic assessment logic will be developed separately

        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    // Hook called after a swap is executed.
    // Evaluates whether the swap created material exposure and creates a mark if needed.
    //
    // Task: Implement materiality assessment:
    // - What swap size/impact constitutes material exposure?
    // - How to normalize across pools with different liquidity?
    // - How to measure tick displacement vs liquidity utilization?
    // - How to prevent gaming through small repeated swaps?
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

        emit SwapObserved(poolId, sender, 0, tickAfter);

        // TODO: Determine materiality criteria
        // For now, create a mark for demonstration of the state model
        // In production, this would be gated by economic significance checks

        bool shouldCreateMark = _assessMateriality(params, delta);

        if (shouldCreateMark) {
            createMark(poolId, sender, tickAfter, params.amountSpecified, params.zeroForOne);

            // TODO: Implement observation window and resolution logic
            // Questions to research:
            // - What observation period should be used?
            // - What price movement confirms exposure?
            // - What price movement clears exposure?
            // - How to prevent self-resolution by the swapper?
        }

        return (BaseHook.afterSwap.selector, 0);
    }

    // Assess whether a swap creates material exposure.
    // Placeholder for economic research. Currently returns false to prevent
    // mark creation until proper economic model is defined.
    //
    // RESEARCH QUESTIONS:
    // 1. What defines "material" in different pool contexts?
    // 2. Should we use absolute amounts, relative price impact, or liquidity utilization?
    // 3. How to prevent manipulation through repeated small swaps?
    // 4. Should materiality depend on swap direction or tick range?
    function _assessMateriality(SwapParams calldata, BalanceDelta) internal pure returns (bool material) {
        // Intentionally return false until economic model is researched
        // This prevents unintended mark creation with arbitrary thresholds
        return false;

        // Future implementation will evaluate:
        // - Swap size relative to pool liquidity
        // - Price impact magnitude
        // - Tick displacement
        // - Historical swap patterns
        // - Pool-specific parameters
    }

    // Resolve a mark to Confirmed or Cleared status.
    // Public function for external mark resolution.
    //
    // TODO: Access control and resolution logic
    // - Who can resolve marks?
    // - What conditions must be met?
    // - How to prevent premature resolution?
    function resolveMark(bytes32 markId, bool confirmed) external {
        // TODO: Implement proper resolution logic with:
        // - Price observation validation
        // - Time window checks
        // - Economic confirmation criteria
        // - Access control (if needed)

        if (confirmed) {
            confirmMark(markId);
        } else {
            clearMark(markId);
        }
    }

    // Compute the deterministic mark ID for given parameters.
    function computeMarkId(PoolId poolId, address swapper, int24 tick, uint256 blockNumber)
        external
        pure
        override
        returns (bytes32)
    {
        return MarkTypes.computeMarkId(poolId, swapper, tick, blockNumber);
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
}
