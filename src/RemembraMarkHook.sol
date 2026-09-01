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

    // ECONOMIC PARAMETERS (V1 EXPERIMENTAL - NOT OPTIMIZED)
    // These values require empirical validation through testnet deployment.
    // Do NOT treat as production-ready constants.

    // Minimum exposure threshold for mark creation (dimensionless score)
    // 10000 = 1% price impact × normalized liquidity magnitude
    // EXPERIMENTAL: Selected conservatively; requires calibration per pool type
    // Rationale: Focuses tracking on material swaps; prevents noise from tiny trades
    uint256 public constant MIN_EXPOSURE_SCORE = 10000;

    // Observation window for mark resolution (in blocks)
    // 25 blocks ≈ 5 minutes on mainnet (12s block time)
    // EXPERIMENTAL: Fixed window may be suboptimal for different volatility regimes
    // Rationale: Long enough for external price discovery, short enough for timely resolution
    uint256 public constant OBSERVATION_WINDOW_BLOCKS = 25;

    // Price movement threshold to confirm persistent exposure (in basis points)
    // 50 bps = 0.5% price movement against swap direction
    // EXPERIMENTAL: Threshold to distinguish signal from noise; requires empirical tuning
    // Rationale: Above typical noise, below rare volatility; proxy for post-trade exposure
    uint256 public constant CONFIRM_THRESHOLD_BPS = 50;

    // Transient storage for capturing pre-swap state
    // Maps poolId → pre-swap sqrtPriceX96
    // Only used during beforeSwap → afterSwap sequence within single transaction
    mapping(PoolId => uint160) private _preSwapSqrtPrice;

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
        PoolId poolId = key.toId();

        // Capture pre-swap price for exposure calculation in afterSwap
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        _preSwapSqrtPrice[poolId] = sqrtPriceX96;

        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    // Hook called after a swap is executed.
    // Evaluates whether the swap created material exposure and creates a mark if needed.
    //
    // CURRENT BEHAVIOR:
    // Observes all swaps and creates marks when materiality threshold is met.
    // SwapObserved events are emitted for all swaps regardless of materiality.
    // ExposureMarked events are only emitted when a mark is actually created.
    function _afterSwap(address sender, PoolKey calldata key, SwapParams calldata params, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        _processSwapExposure(sender, key, params);
        return (BaseHook.afterSwap.selector, 0);
    }

    // Process swap exposure assessment and mark creation (internal helper to avoid stack too deep)
    function _processSwapExposure(address sender, PoolKey calldata key, SwapParams calldata params) internal {
        PoolId poolId = key.toId();

        // Get post-swap state
        (uint160 sqrtPriceAfter, int24 tickAfter,,) = poolManager.getSlot0(poolId);

        // Retrieve pre-swap price captured in beforeSwap
        uint160 sqrtPriceBefore = _preSwapSqrtPrice[poolId];

        // Emit observation event (always emitted, regardless of materiality)
        emit SwapObserved(poolId, sender, 0, tickAfter, params.amountSpecified, params.zeroForOne);

        // Get current active liquidity at current price (NOT total liquidity across all ranges)
        // This is the liquidity available for trading at the current tick
        uint128 liquidity = poolManager.getLiquidity(poolId);
        (bool isMaterial, uint256 exposureScore) = _assessMateriality(sqrtPriceBefore, sqrtPriceAfter, liquidity);

        // Only create mark if material
        if (isMaterial) {
            createMark(
                poolId, sender, tickAfter, params.amountSpecified, params.zeroForOne, sqrtPriceAfter, exposureScore
            );
            // ExposureMarked event emitted by createMark() in ledger
        }
    }

    // Assess whether a swap creates material exposure.
    //
    // ECONOMIC FORMULA (DIMENSIONLESS SCORE):
    // exposureScore = |price_change_bps| × liquidity_normalized
    //
    // Where:
    // - price_change_bps = ((sqrtPriceAfter² - sqrtPriceBefore²) / sqrtPriceBefore²) × 10000
    // - liquidity_normalized = active_liquidity / 1e18 (to prevent overflow)
    //
    // UNITS: Dimensionless exposure score
    // This is NOT:
    // - ❌ Quote token denominated
    // - ❌ USD denominated
    // - ❌ Directly convertible to economic loss
    //
    // The result serves as a RELATIVE INDICATOR of swap impact on active liquidity.
    // Future work (V2+) may convert to economic terms using token decimals and price oracles.
    //
    // IMPLEMENTATION NOTES:
    // - Uses safe fixed-point arithmetic to handle uint160 sqrt prices
    // - Converts sqrt price ratio to linear price ratio: (p_after/p_before - 1)
    // - Scales to basis points for threshold comparison
    // - Normalizes active liquidity to prevent uint256 overflow
    //
    // RETURNS:
    // - true if exposureScore >= MIN_EXPOSURE_SCORE
    // - false otherwise (no mark created)
    // - exposureScore (dimensionless magnitude)
    function _assessMateriality(uint160 sqrtPriceBefore, uint160 sqrtPriceAfter, uint128 liquidity)
        internal
        pure
        returns (bool, uint256 exposureScore)
    {
        // Edge case: no price change or no liquidity
        if (sqrtPriceBefore == sqrtPriceAfter || liquidity == 0) {
            return (false, 0);
        }

        // Calculate absolute price change in basis points
        // Formula: |((sqrtPriceAfter/sqrtPriceBefore)² - 1)| × 10000
        //
        // To avoid overflow with uint160², we compute:
        // ratio = sqrtPriceAfter / sqrtPriceBefore (in fixed point)
        // price_change = |ratio² - 1| × 10000

        uint256 priceChangeBps;

        if (sqrtPriceAfter > sqrtPriceBefore) {
            // Price increased
            // Compute: ((after/before)² - 1) × 10000
            uint256 ratio = (uint256(sqrtPriceAfter) * 1e18) / uint256(sqrtPriceBefore);
            uint256 ratioSquared = (ratio * ratio) / 1e18;
            priceChangeBps = ((ratioSquared - 1e18) * 10000) / 1e18;
        } else {
            // Price decreased
            // Compute: (1 - (after/before)²) × 10000
            uint256 ratio = (uint256(sqrtPriceAfter) * 1e18) / uint256(sqrtPriceBefore);
            uint256 ratioSquared = (ratio * ratio) / 1e18;
            priceChangeBps = ((1e18 - ratioSquared) * 10000) / 1e18;
        }

        // Normalize liquidity to prevent overflow
        // Divide by 1e18 to bring active liquidity into reasonable magnitude
        uint256 liquidityNormalized = uint256(liquidity) / 1e18;

        // If liquidity is tiny (< 1e18), use minimum value of 1
        if (liquidityNormalized == 0) {
            liquidityNormalized = 1;
        }

        // Calculate exposure: price_change_bps × liquidity_normalized
        exposureScore = priceChangeBps * liquidityNormalized;

        return (exposureScore >= MIN_EXPOSURE_SCORE, exposureScore);
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
    // ANTI-MANIPULATION: Prevents self-resolution (swapper cannot resolve own mark)
    //
    // AUTOMATIC DETERMINATION:
    // The function automatically determines whether to confirm or clear based on
    // price movement analysis. Caller doesn't specify the outcome.
    //
    // This approach avoids centralized control while preventing arbitrary resolution.
    // The economics are enforced through eligibility logic, not access control.
    function resolveMark(bytes32 markId) external {
        // Anti-manipulation: Prevent swapper from resolving their own mark
        MarkTypes.ExposureMark memory mark = getMark(markId);
        if (msg.sender == mark.swapper) {
            revert("Cannot self-resolve mark");
        }

        // Check eligibility before allowing resolution
        if (!canResolveMark(markId)) {
            revert MarkNotEligibleForResolution(markId);
        }

        // Determine resolution based on price movement
        bool shouldConfirm = _shouldConfirmMark(markId);

        // Eligibility confirmed, proceed with state transition
        if (shouldConfirm) {
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
    //
    // ECONOMIC RESOLUTION CONDITIONS (V1):
    // 1. Mark must exist and be in Open status
    // 2. Observation window must have elapsed (OBSERVATION_WINDOW_BLOCKS)
    // 3. Check if price movement may correlate with persistent post-trade exposure
    //
    // CONFIRMATION CRITERIA:
    // - For zeroForOne swap (sold token0): Price INCREASED by > CONFIRM_THRESHOLD_BPS
    // - For oneForZero swap (bought token0): Price DECREASED by > CONFIRM_THRESHOLD_BPS
    //
    // CLEARING CRITERIA:
    // - Observation window elapsed AND confirmation criteria NOT met
    //
    // INTERPRETATION:
    // Confirmed marks indicate price moved against swap direction, which may correlate
    // with adverse selection, informed trading, or persistent post-trade exposure.
    // Confirmation is a PROXY SIGNAL, not definitive proof of toxic flow or MEV.
    // False positives (normal volatility) and false negatives (slow adverse selection) are expected.
    //
    // RETURNS:
    // - true if mark is ready for resolution (either confirm or clear)
    // - false if mark doesn't exist, isn't Open, or observation window hasn't elapsed
    function canResolveMark(bytes32 markId) public view override(ExposureLedger, IRemembraMark) returns (bool) {
        // Try to get mark (will revert if doesn't exist)
        MarkTypes.ExposureMark memory mark;
        try this.getMark(markId) returns (MarkTypes.ExposureMark memory m) {
            mark = m;
        } catch {
            return false;
        }

        // Mark must be in Open status
        if (mark.status != MarkTypes.MarkStatus.Open) {
            return false;
        }

        // Observation window must have elapsed
        if (block.number < mark.creationBlock + OBSERVATION_WINDOW_BLOCKS) {
            return false;
        }

        // Mark is eligible for resolution once observation window passes
        // Caller must determine whether to confirm or clear based on price movement
        return true;
    }

    // Determine if price movement warrants mark confirmation.
    //
    // CONFIRMATION LOGIC:
    // Calculate price change from mark creation to now:
    // - price_change_bps = ((priceNow/priceAtMark)² - 1) × 10000
    //
    // For zeroForOne swap (sold token0 for token1):
    // - May correlate with exposure if price ROSE (swapper sold before price increased)
    // - Confirm if price_change_bps > CONFIRM_THRESHOLD_BPS
    //
    // For oneForZero swap (bought token0 with token1):
    // - May correlate with exposure if price FELL (swapper bought before price decreased)
    // - Confirm if price_change_bps < -CONFIRM_THRESHOLD_BPS
    //
    // INTERPRETATION:
    // This is a PROXY SIGNAL that price moved against the swap direction.
    // May correlate with adverse selection, informed trading, or persistent post-trade exposure.
    // NOT definitive proof of toxic flow, MEV, or LP harm.
    //
    // RETURNS:
    // - true if price movement may correlate with persistent post-trade exposure
    // - false if price movement is within normal range
    function _shouldConfirmMark(bytes32 markId) internal view returns (bool) {
        MarkTypes.ExposureMark memory mark = getMark(markId);

        // Get current pool price
        (uint160 sqrtPriceNow,,,) = poolManager.getSlot0(mark.poolId);

        // Calculate price change in basis points
        int256 priceChangeBps = _calculatePriceChangeBps(mark.sqrtPriceAtMark, sqrtPriceNow);

        // Check if price moved against swap direction (may correlate with exposure)
        if (mark.zeroForOne) {
            // Sold token0 → may correlate with exposure if price rose
            return priceChangeBps > int256(CONFIRM_THRESHOLD_BPS);
        } else {
            // Bought token0 → may correlate with exposure if price fell
            return priceChangeBps < -int256(CONFIRM_THRESHOLD_BPS);
        }
    }

    // Calculate price change in basis points between two sqrt prices.
    //
    // FORMULA:
    // price_change_bps = ((sqrtPriceNow/sqrtPriceBefore)² - 1) × 10000
    //
    // RETURNS:
    // - Positive value if price increased
    // - Negative value if price decreased
    // - Zero if no change
    function _calculatePriceChangeBps(uint160 sqrtPriceBefore, uint160 sqrtPriceNow) internal pure returns (int256) {
        if (sqrtPriceBefore == sqrtPriceNow) {
            return 0;
        }

        // Calculate ratio: sqrtPriceNow / sqrtPriceBefore (in fixed point 1e18)
        uint256 ratio = (uint256(sqrtPriceNow) * 1e18) / uint256(sqrtPriceBefore);

        // Square the ratio: (sqrtPriceNow / sqrtPriceBefore)²
        uint256 ratioSquared = (ratio * ratio) / 1e18;

        // Calculate price change: (ratio² - 1) × 10000
        if (ratioSquared > 1e18) {
            // Price increased
            uint256 change = ((ratioSquared - 1e18) * 10000) / 1e18;
            return int256(change);
        } else {
            // Price decreased
            uint256 change = ((1e18 - ratioSquared) * 10000) / 1e18;
            return -int256(change);
        }
    }
}
