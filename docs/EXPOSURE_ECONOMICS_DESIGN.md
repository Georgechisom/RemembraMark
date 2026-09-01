# RemembraMark Exposure Economics Design

Document Status: Research & Design Phase

## Executive Summary

This document presents the engineering design for RemembraMark's Exposure Mark mechanism, a stateful primitive for tracking and resolving trade induced liquidity exposure in Uniswap v4 concentrated liquidity pools. After comprehensive analysis of v4 APIs, LVR literature, and existing MEV mitigation approaches, we recommend a pool level exposure tracking model (Model C) for V1, with clear economic parameters grounded in first principles analysis.

Core Innovation: RemembraMark does NOT attempt to perfectly identify "bad MEV." Instead, it creates economic memory around material price moving swaps and uses subsequent market behavior to probabilistically identify adverse selection vs. legitimate arbitrage.

## 1. Recommended Attribution Model

### Model Comparison Summary

We evaluated three approaches:

| Model              | Description                            | Data Available                   | Accuracy | Gas Cost              | Complexity | V1 Feasible |
| ------------------ | -------------------------------------- | -------------------------------- | -------- | --------------------- | ---------- | ----------- |
| A: Exact Tick-Path | Reconstruct which LP ranges crossed    | Must query StateLibrary per tick | High     | Very High (unbounded) | Very High  | No          |
| B: Range-Bucket    | Aggregate exposure into coarse buckets | StateLibrary + custom tracking   | Medium   | High                  | High       | Difficult   |
| C: Pool-Level      | Track exposure at pool granularity     | afterSwap params only            | Lower    | Low (constant)        | Low        | Yes         |

### Recommendation: Model C (Pool-Level Exposure Fallback)

Rationale:

1. Data Limitations: Uniswap v4 `afterSwap` provides:
   `BalanceDelta` (swap amounts)
   `SwapParams` (direction, size, price limit)
   Sender address

   It does NOT directly provide which ticks were crossed or which LP positions absorbed the swap.

2. Gas Feasibility: Reconstructing tick paths requires:
   Iterating through TickBitmap (`nextInitializedTickWithinOneWord`)
   Multiple `extsload` calls via StateLibrary
   Unbounded loop depending on swap size
   Estimated 50k-500k+ gas for large swaps crossing many ticks

3. Solo/Two-Person Team: Model A/B require substantial engineering:
   Custom liquidity tracking via `afterAddLiquidity`/`afterRemoveLiquidity`
   Storage of active positions per pool
   Complex accounting logic
   Extensive testing for edge cases

4. Incremental Path: Model C can be upgraded later without breaking changes:
   V1 establishes economic primitives at pool level
   V2 adds range-level refinement using off-chain indexing + on-chain verification
   V3 potentially integrates with Position Manager for precise attribution

5. Sufficient for Core Hypothesis: The key research question "can subsequent market behavior identify adverse selection?" can be tested at pool level before investing in per-range mechanics.

### What Pool-Level Tracking Means

Exposure Unit: Total pool exposure in quote token terms
Attribution: Swapper address + pool + timestamp, NOT individual LP positions
Resolution: Based on pool-level price movement, not per-range P&L
Settlement (future): Redistributed proportionally to all LPs in pool, not targeted to affected ranges

---

## 2. Exposure Units Formula

### Definition

Exposure is measured as a dimensionless magnitude:

```
Exposure(swap) = |ΔPrice_bps| × L_active_normalized
```

Where:
`|ΔPrice_bps|` = Absolute price change from swap in basis points (dimensionless ratio × 10000)
`L_active_normalized` = Active liquidity at swap execution (from `StateLibrary.getLiquidity()`) / 1e18
`exposure result` = Dimensionless score

### Units and Dimensions

The exposure formula produces a **dimensionless score**:

- Input: price change (dimensionless ratio, scaled to basis points)
- Input: active liquidity at current price (uint128, normalized by 1e18)
- Output: dimensionless score (product of above)

**The result is NOT:**

- ❌ Quote token denominated
- ❌ USD denominated
- ❌ Directly convertible to economic loss

The magnitude serves as a **relative indicator** of swap impact on active liquidity.
Future work (V2+) may convert to economic terms using token decimals and price oracles.

### Rationale

1. Price-Liquidity Product: Captures both swap impact magnitude AND pool depth
   Large price move + low active liquidity → high exposure
   Small price move + high active liquidity → moderate exposure
   Normalizes across different pool sizes

2. Observable On-Chain: All components available in `afterSwap`:
   Price change via `StateLibrary.getSlot0()` (before/after ticks → sqrt prices)
   Active liquidity at current price via `StateLibrary.getLiquidity(poolId)`
   No external oracle needed

3. Active Liquidity Context: Uses `Pool.State.liquidity` which represents:
   - Active liquidity available for trading at the current tick
   - NOT total liquidity across all ranges
   - The actual liquidity depth that absorbed the swap impact

### Alternative Formulas Considered

Option 1: Absolute Swap Size

```
Exposure = |amountSpecified|
```

- Ignores active liquidity depth (same $1M swap affects 10M vs 100M pool differently)
- Vulnerable to manipulation via token choice (specify in low-value token)

Option 2: Tick Displacement

```
Exposure = |tickAfter - tickBefore| × tickSpacing
```

- Not normalized across pools with different tick spacings
- Non-linear relationship to economic impact

Option 3: LVR-Inspired

```
Exposure = (σ² × P² × L) / 2
```

- Requires volatility estimation (not available on-chain without oracle)
- Theoretically grounded but impractical for real-time assessment

---

## 3. Mark Lifecycle Design

### State Diagram

```
           createMark()
              ↓
┌─────────────────────────┐
│        OPEN             │
│  (observation window)   │
└─────────────────────────┘
         ↓           ↓
   confirmMark()   clearMark()
         ↓           ↓
   ┌──────────┐   ┌──────────┐
   │CONFIRMED │   │ CLEARED  │
   │ (adverse │   │(benign)  │
   │selection)│   │          │
   └──────────┘   └──────────┘
```

### Open State

Entry Condition: Swap meets materiality threshold

Duration: Fixed observation window (recommended: 25-50 blocks on mainnet, ~5-10 minutes)

Data Captured:
Pool ID
Swapper address
Tick at mark creation
Sqrt price at mark creation
Swap direction (zeroForOne)
Swap amount
Creation block
Exposure magnitude (calculated)
Nonce (uniqueness)

Why Fixed Window:
Predictable for swappers (no surprise resolution)
Prevents manipulation via intentional delay
Simpler than adaptive windows for V1

### Confirmed State

Entry Condition: Price movement during observation window may correlate with persistent exposure

Criteria:

```
Price moved AGAINST the swap direction by threshold percentage

For zeroForOne swap (selling token0):
   May correlate with exposure if price INCREASED (swapper sold before price rise)
   Threshold: priceAfterWindow > priceAtMark × (1 + confirmThreshold)

For oneForZero swap (buying token0):
   May correlate with exposure if price DECREASED (swapper bought before price drop)
   Threshold: priceAfterWindow < priceAtMark × (1 - confirmThreshold)
```

Recommended confirmThreshold: 0.3% - 0.5% (30-50 bps)
Too low → false positives (normal volatility triggers confirmation)
Too high → false negatives (miss genuine adverse selection)
Calibrated against typical intra-block price movements

Interpretation: Swap predicted price movement; proxy signal that may correlate with adverse selection or informed trading

### Cleared State

Entry Condition: Observation window elapsed WITHOUT meeting confirmation criteria

Criteria:

```
block.number >= mark.creationBlock + observationWindow
AND
NOT confirmed
```

Interpretation: Market normalized; swap did not predict harmful price movement

### Invalid Transitions

Enforced by `ExposureLedger.sol`:
Confirmed → Cleared (no reversal)
Cleared → Confirmed (no reversal)
Any state → Open (no reopening)

---

## 4. Resolution Algorithm

### Pseudocode

```solidity
function resolveMarkIfEligible(bytes32 markId) external {
    ExposureMark memory mark = getMark(markId);

    // 1. Must be Open
    require(mark.status == MarkStatus.Open, "Not open");

    // 2. Must be past minimum observation window
    require(
        block.number >= mark.creationBlock + MIN_OBSERVATION_WINDOW,
        "Too early"
    );

    // 3. Get current pool state
    (uint160 sqrtPriceNow, int24 tickNow, , ) =
        poolManager.getSlot0(mark.poolId);

    // 4. Calculate price change
    uint160 sqrtPriceAtMark = getSqrtPriceFromMark(mark);
    int256 priceChange = calculatePriceChange(
        sqrtPriceAtMark,
        sqrtPriceNow,
        mark.zeroForOne
    );

    // 5. Check confirmation condition
    bool meetsConfirmation = false;
    if (mark.zeroForOne) {
        // Sold token0 → adverse if price rose
        meetsConfirmation = priceChange > CONFIRM_THRESHOLD_BPS;
    } else {
        // Bought token0 → adverse if price fell
        meetsConfirmation = priceChange < -CONFIRM_THRESHOLD_BPS;
    }

    // 6. Resolve
    if (meetsConfirmation) {
        _confirmMark(markId);
        // Future: trigger settlement logic
    } else {
        _clearMark(markId);
    }
}
```

### Gas Analysis

Best Case (mark clears):
1 SLOAD (mark data)
1 `extsload` (pool slot0)
Price calculation (pure math)
1 SSTORE (status update)
Event emission
Estimated: ~30k gas

Worst Case (mark confirms with settlement):
Same as best case + settlement operations
Estimated: ~50k-80k gas (depends on settlement complexity)

### Griefing Protection

1. No Unbounded Loops: Single mark resolution is constant-time
2. No Free Resolution Spam: Future versions could require:
   Small fee to call `resolveMark()` (burned or donated to pool)
   Rate limit per caller address
   Batch resolution to amortize overhead
3. Permissionless with Incentive: Resolver gets gas refund from settlement (future)

---

## 5. Settlement Model (Future Implementation)

### V1: No Settlement

Current scope: Mark creation and resolution ONLY
Proves the tracking mechanism works
Collects empirical data on confirmation rates
Validates economic parameters

No Immediate Penalties: Swappers are not charged extra fees (yet)

No Immediate Rebates: LPs do not receive compensation (yet)

### V2: Fee Redistribution

Mechanism: Confirmed marks trigger rebate from pool fees

```
On mark confirmation:
  1. Calculate rebate = f(exposure_magnitude, pool_fee_tier)
  2. Reserve rebate from next N blocks of swap fees
  3. Distribute proportionally to LPs who held positions during mark window
```

Challenges:

- Fee availability: What if pool has low volume? (Answer: cap rebate, carry forward deficit)
- LP tracking: Need to know who was LP at mark creation (requires `afterAddLiquidity` tracking)
- Fair distribution: Proportional to liquidity provided in affected range (V2+)

### V3: Dynamic Fees

Mechanism: Adjust swap fees based on recent confirmation rate

```
fee_multiplier = 1.0 + (confirmed_marks / total_marks) × sensitivity
```

- High confirmation rate → increase fees to deter adverse selection
- Low confirmation rate → decrease fees to attract volume
- Implemented as `beforeSwap` fee override

Differentiation from existing dynamic fee hooks:

- NOT based on volatility (which penalizes all swaps)
- NOT based on pool utilization
- Based on REALIZED adverse selection (confirmed marks)

---

## 6. Anti-Manipulation Rules

### 6.1. Mark Farming Prevention

Attack: Create artificial "confirmed" marks to collect rebates

Example:

1. Attacker opens large position
2. Attacker swaps to create mark
3. Attacker swaps again (opposite direction) to artificially move price
4. Mark confirms, attacker collects rebate

Mitigations:

M1: Self-Resolution Prohibition

```solidity
// In resolveMark():
require(
    msg.sender != mark.swapper,
    "Cannot self-resolve"
);
```

Swapper cannot trigger resolution of their own marks
Requires independent market participant to resolve
Still vulnerable if attacker uses two addresses

M2: Same-Block Resolution Block

```solidity
require(
    block.number > mark.creationBlock + MIN_OBSERVATION_WINDOW,
    "Too early"
);
```

Prevents atomically creating + confirming mark in same transaction
Forces time delay for external price discovery

M3: Minimum Exposure Threshold

```
Only create marks if:
  exposure >= MIN_EXPOSURE_AMOUNT (e.g., $1000 quote token equivalent)
```

Makes small-scale farming unprofitable
Focuses tracking on material swaps

M4: Confirmation Requires External Price Movement (V2)

Use TWAP or other oracle to verify price change is market-wide, not pool-isolated
Prevents attacker from moving price via low-liquidity pool manipulation

### 6.2. Liquidity Churn Attacks

Attack: Add liquidity → receive rebate → remove liquidity immediately

Mitigation (V2 when settlement implemented):

```solidity
// Only LPs who held position during mark observation window receive rebate
// Checked via minimum holding period or snapshot at mark creation
```

### 6.3. Repeated Small Swap Attacks

Attack: Fragment one large swap into many small swaps to evade materiality threshold

Example: Instead of 1 × $10k swap, do 100 × $100 swaps

Mitigations:

M1: Same-Block Aggregation

```solidity
// Track cumulative exposure per (poolId, swapper, block)
// Aggregate all swaps in block for materiality check
mapping(bytes32 => uint256) public blockExposure;
```

M2: Rolling Window Aggregation (more complex)

```solidity
// Track exposure over last N blocks per swapper
// Create mark if rolling sum exceeds threshold
```

Trade off: Adds storage overhead and complexity; may be V2+ feature

### 6.4. Large Swap Split Across Pools

Attack: Route large trade through multiple pools to stay under per-pool threshold

Mitigation (V3):

Cross-pool exposure aggregation
Requires global registry of related pools
Significant complexity increase

### 6.5. Flash Liquidity Gaming

Attack:

1. Add large liquidity before mark observation window ends
2. Price moves due to external factors
3. Mark confirms, attacker collects rebate
4. Remove liquidity immediately

Mitigation (V2):

```solidity
// Rebate calculation weights by time-in-pool
rebate_share = (liquidity × blocks_held) / total_liquidity_time
```

---

## 7. State Variables & Storage

### Per-Pool State

```solidity
struct PoolExposureState {
    // Cumulative confirmed exposure (quote token)
    uint256 totalConfirmedExposure;

    // Cumulative cleared exposure
    uint256 totalClearedExposure;

    // Count of marks by status
    uint32 openMarks;
    uint32 confirmedMarks;
    uint32 clearedMarks;

    // Reserved fees for pending rebates (V2)
    uint256 reservedForRebates;

    // Last updated block
    uint256 lastUpdateBlock;
}
```

Storage cost: ~5 SSTOREs per pool (one-time on first mark)

### Per-Mark State

Already implemented in `MarkTypes.ExposureMark`:

```solidity
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
}
```

Addition for V1:

```solidity
struct ExposureMark {
    // ... existing fields ...

    uint256 exposureMagnitude;      // Calculated exposure in quote token
    uint160 sqrtPriceAtMark;        // For resolution calculation
}
```

Storage cost: 3 additional SSTOREs per mark (~60k gas)

### Global State

```solidity
// Immutable configuration
uint256 public immutable MIN_EXPOSURE_SCORE;        // e.g., 10000 (dimensionless score)
uint256 public immutable OBSERVATION_WINDOW;        // e.g., 25 blocks
uint256 public immutable CONFIRM_THRESHOLD_BPS;     // e.g., 30 (0.3%)

// Dynamic statistics
uint256 public totalMarksCreated;
uint256 public totalMarksConfirmed;
uint256 public totalMarksClear;

// Per-pool mapping
mapping(PoolId => PoolExposureState) public poolState;
```

---

## 8. Required Hook Callbacks

### Current (Implemented)

```solidity
function beforeSwap(
    address sender,
    PoolKey calldata key,
    SwapParams calldata params,
    bytes calldata hookData
) external returns (bytes4, BeforeSwapDelta, uint24);
```

- Use: Capture pre-swap pool state (optional for price change calculation)
- Gas impact: Minimal (~5k)

```solidity
function afterSwap(
    address sender,
    PoolKey calldata key,
    SwapParams calldata params,
    BalanceDelta delta,
    bytes calldata hookData
) external returns (bytes4, int128);
```

- Use: Assess materiality, create marks, emit events
- Gas impact: ~30k-60k when mark is created

### Future (V2 Range Tracking)

```solidity
function afterAddLiquidity(
    address sender,
    PoolKey calldata key,
    ModifyLiquidityParams calldata params,
    BalanceDelta delta,
    BalanceDelta feesAccrued,
    bytes calldata hookData
) external returns (bytes4, BalanceDelta);
```

- Use: Track which positions exist and their ranges
- Storage: Maintain mapping of (poolId, owner, tickLower, tickUpper) → positionId

```solidity
function afterRemoveLiquidity(...) external returns (bytes4, BalanceDelta);
```

- Use: Update position tracking when liquidity removed

---

## 9. Gas & Storage Estimates

### Per-Swap Gas (Current Path)

No Mark Created (majority of swaps):

`beforeSwap`: ~5k gas
`afterSwap`: ~15k gas (state reads, materiality check, event)
Total overhead: ~20k gas per swap

Mark Created (material swaps only):

Mark creation: ~60k gas (3-4 SSTOREs)
Event emission: ~5k gas
Total overhead: ~85k gas per material swap

Comparison: Uniswap v4 base swap ~120k gas → 17% overhead for material swaps

### Per-Resolution Gas

Mark resolution: ~30k gas (clearing)
Mark resolution + settlement (future): ~50k-80k gas

### Storage Costs

One time per pool: ~100k gas (initialize PoolExposureState)

Per mark: ~60k gas

Annual cost estimate (hypothetical mainnet pool):

1000 material swaps/year → 1000 marks
1000 × 60k = 60M gas
At 50 gwei, 60M gas = 3 ETH
At $3000/ETH = $9000/year storage cost
Distributed across all swappers (fraction of cent per swap)

---

## 10. Failure Modes & Risks

### 10.1. Low Confirmation Rate

Risk: If <5% of marks confirm, mechanism provides no signal

Causes:

Threshold too high (misses real adverse selection)
Observation window wrong length
Pool has no informed flow

Mitigation:

Empirical calibration using testnet data
Per pool threshold adjustment
Accept that some pools may not benefit

### 10.2. High False Positive Rate

Risk: Normal volatility triggers confirmations, penalizing legitimate traders

Causes:

Threshold too low
Observation window too long (captures unrelated moves)

Mitigation:

Conservative threshold (0.5% vs. 0.1%)
Shorter observation window for volatile pools
Optional: Use TWAP to filter noise

### 10.3. Gaming Creates Noise

Risk: Attackers create spurious marks to obscure real signal

Mitigation:

Minimum exposure threshold makes spam expensive
Settlement (future) rewards only legitimate marks
Off chain analytics can flag suspicious patterns

### 10.4. Settlement Insolvency

Risk (V2): Confirmed marks accumulate faster than fee revenue

Scenarios:

Low volume pool with high adverse selection
Many large confirmed marks in short period
Fee tier too low to cover rebates

Mitigation:

Cap rebate per mark (e.g., max 10% of exposure)
Rebate queue with FIFO settlement
Deficit carried forward (no immediate obligation)
LPs opt-in to enhanced protection (trade volume for safety)

### 10.5. Oracle Manipulation

Risk (if V2 uses external oracle): Attacker manipulates oracle price to trigger false confirmations

Mitigation:

Use robust oracle (Chainlink, Uniswap TWAP)
Require large divergence from pool price before trusting oracle
Fallback to pool-only resolution if oracle unavailable

### 10.6. Griefing via Resolution Spam

Risk: Attacker repeatedly calls `resolveMark()` on ineligible marks to waste gas

Mitigation:

Caller pays gas (natural disincentive)
Future: Small fee to resolve (refunded if successful)
Future: Batch resolution to amortize overhead
Eligibility check happens before expensive operations

---

## 11. Differentiation from Existing Approaches

| Approach              | Mechanism                                    | RemembraMark Difference                                                                                                                        |
| --------------------- | -------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------- |
| Dynamic Fees          | Adjust fees based on volatility              | ✅ We adjust based on REALIZED adverse selection (confirmed marks), not predicted volatility. Distinguishes toxic flow from normal volatility. |
| Fee Rebates           | Refund fees to LPs when losses occur         | ✅ We determine losses via subsequent price movement, not immediate calculation. Time-shifted assessment.                                      |
| MEV Auctions          | Sell exclusive swap rights to highest bidder | ✅ We don't restrict swaps. All swappers treated equally upfront; marks identify adverse selection ex-post.                                    |
| LVR Auctions (am-AMM) | Auction arbitrage rights to recapture LVR    | ✅ We use market-driven resolution, not explicit auction. No bid submission, no preferential access.                                           |
| TWAMM                 | Time-weighted AMM for large orders           | ✅ Not a new AMM. Works with standard v4 swaps. Observes existing mechanics, doesn't replace them.                                             |
| Private Order Flow    | Route trades off-chain first                 | ✅ Fully on-chain. No off-chain coordination or trusted parties.                                                                               |
| JIT Liquidity Hooks   | Add liquidity right before swap              | ✅ Not about liquidity provision timing. About identifying adverse selection after-the-fact.                                                   |
| Liquidity Tranching   | Separate LP tiers by risk                    | ✅ Not about risk segmentation. About measuring realized vs. unrealized exposure.                                                              |
| Reputation Scoring    | Whitelist/blacklist addresses                | ✅ Permissionless. No address discrimination. Economic signal, not access control.                                                             |
| ZK/Privacy Hooks      | Hide trade details                           | ✅ Transparent on-chain tracking. No privacy layer.                                                                                            |

### Key Novelty

RemembraMark's core innovation is time-shifted adverse selection identification:

1. Don't predict which swaps are toxic at execution time
2. Observe subsequent market behavior
3. Retroactively label swaps as adverse or benign
4. Learn from confirmed marks to improve pool economics

This is fundamentally different from approaches that try to identify toxic flow in real-time (which requires perfect information or complex heuristics).

---

## 12. MVP vs. Later Versions

### V1 MVP (Current Design Document Scope)

Goal: Prove the core hypothesis with minimal complexity

Scope:

- ✅ Pool-level exposure tracking
- ✅ Materiality assessment (price-liquidity formula)
- ✅ Fixed observation window (25-50 blocks)
- ✅ Confirmation/clearing logic
- ✅ Mark lifecycle (Open → Confirmed/Cleared)
- ✅ Basic anti-manipulation (self-resolution block, minimum threshold)
- ✅ Gas-efficient implementation
- ❌ NO settlement/rebates
- ❌ NO range-level attribution
- ❌ NO dynamic fees
- ❌ NO off-chain components

Success Criteria:

10-30% confirmation rate on material swaps
<5% false positive rate (normal volatility causing confirmation)
Confirmed marks correlate with LP losses (validated off-chain)
No critical exploits found in testing

### V2: Settlement & Refined Attribution

Additions:

- ✅ Fee-based rebate mechanism
- ✅ LP position tracking (`afterAddLiquidity` hooks)
- ✅ Proportional rebate distribution
- ✅ Rebate solvency management
- ✅ Enhanced anti-manipulation (time-weighted rebates)
- ✅ Multi-pool exposure aggregation (simple version)

Success Criteria:

- Rebate mechanism is solvent (fees cover rebates over 30-day window)
- LPs report improved net returns in pools with high adverse selection
- No rebate farming exploits

### V3: Advanced Features

Additions:

- ✅ Range-level exposure attribution
- ✅ Off-chain indexing + on-chain verification
- ✅ Dynamic fee adjustment based on confirmation rates
- ✅ Oracle integration for cross-market validation
- ✅ Adaptive observation windows
- ✅ Cross-chain exposure tracking (if multichain)

---

## RECOMMENDED V1 DESIGN

### Core Parameters

```solidity
// Materiality
MIN_EXPOSURE_SCORE = 10000;  // Dimensionless score threshold

// Observation
OBSERVATION_WINDOW = 25;  // blocks (~5 min on mainnet)

// Confirmation
CONFIRM_THRESHOLD_BPS = 50;  // 0.5% price movement against swap direction

// Attribution
ATTRIBUTION_MODEL = POOL_LEVEL;  // No per-range tracking in V1
```

### Implementation Checklist

1. Materiality Assessment (`_assessMateriality`):

   ```solidity
   exposure = |priceChange_bps| × activeLiquidity_normalized
   return exposure >= MIN_EXPOSURE_SCORE
   ```

2. Mark Creation (already implemented):
   - Capture `sqrtPriceAtMark` for later resolution
   - Calculate and store `exposureMagnitude`

3. Resolution Logic (`canResolveMark`):

   ```solidity
   if (block.number < mark.creationBlock + OBSERVATION_WINDOW) return false;

   priceNow = getSlot0(mark.poolId).sqrtPriceX96;
   priceDelta = (priceNow - mark.sqrtPriceAtMark) / mark.sqrtPriceAtMark;

   if (mark.zeroForOne) {
       // Sold token0; adverse if price rose
       return priceDelta > CONFIRM_THRESHOLD_BPS / 10000;
   } else {
       // Bought token0; adverse if price fell
       return priceDelta < -CONFIRM_THRESHOLD_BPS / 10000;
   }
   ```

4. Anti-Manipulation:

   ```solidity
   require(msg.sender != mark.swapper, "No self-resolution");
   require(exposureScore >= MIN_EXPOSURE_SCORE, "Below threshold");
   ```

5. Events & Analytics:
   - Emit `SwapObserved` for all swaps
   - Emit `ExposureMarked` when mark created
   - Emit `MarkResolved` with confirmation status

### WHY This Design

1. Technically Feasible: Uses only data available in `afterSwap` + StateLibrary queries (constant gas)
2. Economically Grounded: Exposure formula captures price impact × active liquidity interaction
3. Manipulation-Resistant: Minimum thresholds, observation delays, and self-resolution blocks prevent obvious attacks
4. Testable Hypothesis: Confirmation rate can validate whether subsequent price movement correlates with certain swap patterns
5. Incrementally Upgradeable: V2 can add settlement; V3 can add range-level tracking—no breaking changes
6. Solo/Two-Person Feasible: Constant-time operations, no complex off-chain infrastructure, clear scope

---

## KNOWN TRADEOFFS

### 1. Pool-Level Granularity

Limitation: Cannot identify which specific LP positions absorbed adverse selection

Impact: Future rebates (V2) distributed to ALL LPs in pool, not just affected ranges

Justification: Precision can be added in V2 without rewriting V1. Testing core hypothesis first.

### 2. Fixed Observation Window

Limitation: 25 blocks may be too short for low-volatility pools, too long for high-volatility

Impact: False negatives (miss slow-developing adverse selection) or false positives (random noise)

Justification: Adaptive windows add complexity. Start with fixed, tune based on data.

### 3. No Oracle Integration

Limitation: Pool-isolated price manipulation could create fake confirmations

Impact: Attacker could move price in low-liquidity pool to confirm their own mark

Mitigation: Minimum exposure threshold makes attack expensive. V2 can add oracle validation.

### 4. No Immediate Settlement

Limitation: V1 tracks adverse selection but doesn't compensate LPs

Impact: LPs still suffer losses, but now have data to quantify them

Justification: Settlement requires LP tracking (complex). Prove measurement works first.

### 5. Gas Overhead

Limitation: Adds ~20k gas per swap (observation) and ~85k for material swaps (mark creation)

Impact: On a base swap of ~120k, this is 17-71% overhead

Justification: Only material swaps (minority) pay full cost. Most swaps pay <20% overhead. Acceptable for novel functionality.

### 6. Distinguishing Arbitrage Types

Limitation: All price-moving swaps treated equally; doesn't distinguish:

Beneficial arbitrage (corrects mispricing)
Sandwiching (extracts value from victim)
Informed trading (front-runs CEX)

Impact: Confirmed marks include mix of adverse selection types

Justification: Perfect classification is impossible on-chain. Statistical aggregate signal is sufficient for V1.

---

## WHAT MUST BE IMPLEMENTED NEXT

### Immediate (Before V1 Deployment)

1. Implement Materiality Logic:

   ```solidity
   function _assessMateriality(SwapParams params, BalanceDelta delta) internal view returns (bool) {
       uint160 sqrtPriceBefore = ... // from beforeSwap
       uint160 sqrtPriceAfter = ... // from afterSwap
       uint128 liquidity = poolManager.getLiquidity(poolId);

       uint256 exposureScore = calculateExposure(sqrtPriceBefore, sqrtPriceAfter, liquidity);
       return exposureScore >= MIN_EXPOSURE_SCORE;
   }
   ```

2. Implement Resolution Logic:

   ```solidity
   function canResolveMark(bytes32 markId) public view override returns (bool) {
       ExposureMark memory mark = getMark(markId);

       if (mark.status != MarkStatus.Open) return false;
       if (block.number < mark.creationBlock + OBSERVATION_WINDOW) return false;

       (uint160 sqrtPriceNow, , , ) = poolManager.getSlot0(mark.poolId);
       return meetsConfirmationCriteria(mark, sqrtPriceNow);
   }
   ```

3. Add Storage Fields:
   - `sqrtPriceAtMark` to `ExposureMark` struct
   - `exposureMagnitude` to `ExposureMark` struct

4. Configuration Constants:
   ```solidity
   uint256 public constant MIN_EXPOSURE_SCORE = 10000;
   uint256 public constant OBSERVATION_WINDOW = 25;
   uint256 public constant CONFIRM_THRESHOLD_BPS = 50;
   ```

### Short Term (V1 Testing Phase)

5. Comprehensive Test Suite:
   Unit tests for exposure calculation
   Integration tests with live pool simulation
   Fuzz tests for edge cases (very small/large swaps)
   Invariant tests for state machine

6. Testnet Deployment:
   Deploy to Sepolia/Goerli
   Create instrumented pool with mock tokens
   Execute synthetic swap patterns
   Collect 1000+ swap samples

7. Analytics Dashboard:
   Off-chain indexer for events
   Visualization of:
   Confirmation rate over time
   Exposure distribution
   Time-to-resolution
   False positive rate (manual labeling)

8. Parameter Tuning:
   Calibrate `CONFIRM_THRESHOLD_BPS` based on testnet data
   Adjust `MIN_EXPOSURE_SCORE` per pool characteristics
   Validate `OBSERVATION_WINDOW` captures meaningful price movements

### Medium Term (V2 Planning)

9. Settlement Mechanism Design:
   Rebate calculation formula
   Fee reservation logic
   LP position tracking architecture
   Solvency management

10. Range-Level Attribution Research:
    Evaluate off-chain indexing vs. on-chain tracking
    Gas cost analysis for `afterAddLiquidity` approach
    Design Position Manager integration

## References

### Uniswap v4 Documentation

[Reading Pool State](https://developers.uniswap.org/docs/protocols/v4/guides/read-pool-state) — StateLibrary usage
[Swap Hooks](https://developers.uniswap.org/docs/protocols/v4/guides/hooks/swap-hooks) — Hook callback parameters
[Dynamic Fees](https://developers.uniswap.org/docs/protocols/v4/concepts/dynamic-fees) — Fee override mechanism

### Academic Literature

Milionis et al. (2024). [_Automated Market Making and Loss-Versus-Rebalancing_](https://arxiv.org/html/2208.06046v5). Defines LVR as adverse selection cost from stale prices.
Content was rephrased for compliance with licensing restrictions

### Related Projects

[Arrakis Pro Hook](https://arrakis.finance/blog/the-arrakis-pro-hook-dynamic-fees-for-token-issuers-on-uniswap-v4) — Dynamic fees for MEV protection
[am-AMM (Adams et al. 2024)](https://arxiv.org/abs/2403.03367) — Auction-managed AMM for LVR capture
[Detoxer MEV Protection Suite](https://github.com/web3yurii/detoxer) — Punitive fees for sandwich attacks
