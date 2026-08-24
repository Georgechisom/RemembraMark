# RemembraMark

**Liquidity that remembers.**

RemembraMark is an experimental Uniswap v4 hook that introduces an "economic memory" primitive for concentrated liquidity. Instead of treating material swaps as instantaneously forgotten events, RemembraMark creates **Exposure Marks** that track how swaps interact with pools over time.

⚠️ **Experimental Software**: This is a research prototype under active development. Not production ready. Not audited. Testnet only.

## Overview

Traditional automated market makers treat each swap as an isolated event. Liquidity providers are exposed to adverse selection and toxic flow, but the protocol has no mechanism to distinguish between different types of market participants or remember past interactions.

RemembraMark implements a stateful observation model where material swaps create **Exposure Marks** that can be confirmed or cleared based on subsequent market behavior.

## Problem

Concentrated liquidity providers face systematic losses from:

1. **Adverse selection**: Informed traders extract value through timely swaps
2. **Toxic flow**: MEV bots and arbitrageurs trade against stale prices
3. **Information asymmetry**: LP positions cannot distinguish trade quality

Current AMM designs provide no protocol level mechanism to:

- Identify swaps that create meaningful exposure
- Track whether that exposure materializes into LP losses
- Differentiate between benign trading and value extraction

## Design Concept

RemembraMark introduces a three state lifecycle for tracking exposure:

```
OPEN → CONFIRMED
  ↓
CLEARED
```

When a materially significant swap occurs, the protocol creates an **Exposure Mark** in the `Open` state. Over an observation window, subsequent market behavior determines whether the exposure:

- **Confirms** (the swap predicted price movement harmful to LPs)
- **Clears** (market conditions normalized, minimal LP impact)

This primitive enables future development of:

- Differentiated fee structures based on exposure patterns
- LP protection mechanisms
- Sophisticated accounting of realized vs. unrealized exposure
- Analytics for trade quality and pool health

## Exposure Marks

An Exposure Mark captures:

- **Pool context**: Which pool and price/tick
- **Swap details**: Size, direction, timestamp
- **Lifecycle state**: Open, Confirmed, or Cleared
- **Resolution outcome**: When and how the mark was resolved

Marks use deterministic identifiers with a monotonic nonce:

```solidity
keccak256(poolId, swapper, tick, blockNumber, nonce)
```

The nonce ensures uniqueness even when the same address performs multiple swaps in the same block at the same tick. This prevents collisions without requiring external transaction data.

## Mark Lifecycle

### Open

A mark is created when a swap meets materiality criteria. The mark enters observation mode, awaiting future market data.

**Current status**: Materiality criteria not yet implemented. No marks are currently created.

### Confirmed

If subsequent market movement indicates the swap created genuine LP exposure, the mark transitions to `Confirmed`.

**Current status**: Confirmation criteria not yet implemented.

### Cleared

If market conditions normalize without material LP impact, the mark transitions to `Cleared`.

**Current status**: Clearing criteria not yet implemented.

### Invalid Transitions

The state machine enforces one-way transitions:

- ✅ Open → Confirmed
- ✅ Open → Cleared
- ❌ Confirmed → Open
- ❌ Confirmed → Cleared
- ❌ Cleared → Open
- ❌ Cleared → Confirmed

## Architecture

### Core Components

**`RemembraMarkHook.sol`**  
Main hook contract integrating with Uniswap v4. Observes swap lifecycle events. Inherits from `BaseHook` and uses only `beforeSwap` and `afterSwap` permissions.

**Important**: Current implementation performs **swap observation** at the pool level. It does NOT yet perform **liquidity exposure attribution** to specific LP ranges or positions.

**`ExposureLedger.sol`**  
Manages mark storage and state transitions. Enforces lifecycle rules and provides read access to mark data. Includes eligibility checking for mark resolution.

**`MarkTypes.sol`**  
Core data structures and utilities. Defines `ExposureMark` struct with nonce for uniqueness, `MarkStatus` enum, and deterministic ID computation.

**`IRemembraMark.sol`**  
External interface for mark queries and protocol interaction.

### Design Principles

1. **Minimal critical-path logic** - Hook callbacks contain only essential operations
2. **Explicit state transitions** - Invalid state changes revert with clear errors
3. **Separation of concerns** - Hook integration separated from accounting logic
4. **No custody** - Protocol never holds user funds
5. **Deterministic identifiers** - Collision-resistant mark IDs using nonce
6. **Auditability** - Clean event emission for all state changes
7. **Modularity** - Economic logic can evolve independently of core architecture
8. **Permissionless resolution** - Eligibility enforced through economics, not access control

## Swap Observation vs Liquidity Exposure Attribution

### What Is Currently Implemented: Swap Observation

The current hook observes swaps at the **pool level**:

- Which pool was swapped against
- Price/tick before and after
- Swap size and direction
- Swapper address

These observations are sufficient to create exposure marks that represent **pool-level trading activity**.

### What Is NOT Yet Implemented: Liquidity Exposure Attribution

The current implementation does NOT identify:

- Which specific liquidity ranges were crossed during the swap
- How much liquidity was utilized in each tick range
- Which individual LP positions were affected
- Per position exposure amounts

### Why This Distinction Matters

True concentrated liquidity exposure tracking requires knowing which LP positions absorbed the swap. A swap that crosses many ticks affects different LPs than a swap contained in a single range.

### Path to Range-Level Attribution

Future development will require:

1. **Additional hook permissions**
   - Track liquidity additions/removals via `beforeAddLiquidity`/`afterAddLiquidity`
   - Build a mapping of active ranges

2. **Position state integration**
   - Query Position Manager for active positions
   - Track position lifecycle

3. **Tick range accounting**
   - Determine which ranges a swap crossed
   - Calculate per-range exposure

4. **Off-chain indexing**
   - Index position events
   - Provide Merkle proofs for on-chain verification

The current architecture provides a clean foundation for this development without requiring a full rewrite.

## Current Implementation Status

This branch (`remembramark-core`) establishes the foundational architecture.

✅ **Implemented:**

- Core state model (Open/Confirmed/Cleared)
- Exposure mark data structures with nonce-based uniqueness
- Ledger storage and lifecycle management
- Hook integration with Uniswap v4 (swap observation)
- Event emission for indexing (SwapObserved, ExposureMarked, MarkResolved)
- Deterministic mark identifiers with collision resistance
- State transition validation
- Eligibility checking framework for resolution
- Permissionless resolution with eligibility gates

❌ **Not Implemented (by design):**

- Economic materiality thresholds (research phase)
- Confirmation/clearing criteria (research phase)
- Observation window logic (research phase)
- Range-level liquidity exposure attribution (future phase)
- Settlement mechanics (future phase)
- LP rebates or fee adjustments (future phase)
- Governance or admin controls (intentionally avoided)
- Comprehensive testing (separate branch)
- Production deployment infrastructure

**Current behavior**: The hook observes all swaps and emits `SwapObserved` events, but does NOT create exposure marks because materiality assessment returns `false`. This prevents premature mark creation with arbitrary thresholds.

## Repository Structure

```
src/
├── RemembraMarkHook.sol        # Main hook contract
├── ExposureLedger.sol          # Mark storage and lifecycle
├── libraries/
│   └── MarkTypes.sol           # Core data types
└── interfaces/
    └── IRemembraMark.sol       # External interface

test/
└── utils/                       # Testing infrastructure (from template)

script/
└── base/                        # Deployment helpers (from template)
```

## Development Setup

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation) (stable version)
- Git

### Installation

```bash
git clone <repository-url>
cd remembramark
forge install
```

### Build

```bash
forge build
```

### Testing

Comprehensive testing will be performed on a separate branch.

```bash
forge test
```

## Local Development

The repository includes scripts for local testing with Anvil:

```bash
# Start local node
anvil

# Deploy hook (in separate terminal)
forge script script/00_DeployHook.s.sol \
    --rpc-url http://localhost:8545 \
    --private-key <PRIVATE_KEY> \
    --broadcast
```

See the `script/` directory for pool creation, liquidity provision, and swap execution examples.

## Design Constraints

### Uniswap v4 Integration

- Uses OpenZeppelin's `BaseHook` implementation
- Only enables `beforeSwap` and `afterSwap` permissions currently
- No delta return (no direct swap intervention)
- No fee override currently implemented
- Compatible with v4-core state management

### Gas Optimization

- Minimal storage writes in critical path
- Monotonic nonce for uniqueness (single SLOAD/SSTORE)
- Events over storage where appropriate
- No unnecessary external calls in callbacks

### Security Model

- No fund custody
- No upgradeability (inherits v4 architecture)
- Explicit error messages for debugging
- State transition validation prevents corruption
- No admin privileges for economic behavior
- Permissionless resolution gated by eligibility logic

## Research Questions

The following economic questions remain open for research:

### Materiality Assessment

1. **What constitutes a material swap?**
   - Absolute amount thresholds?
   - Relative to pool liquidity?
   - Price impact percentage?
   - Tick displacement magnitude?

2. **How to normalize across pools?**
   - Different pools have different liquidity profiles
   - Stablecoin pairs vs. volatile pairs require different criteria
   - Tick spacing affects sensitivity

3. **How to prevent gaming?**
   - Many small swaps to manufacture exposure?
   - Self-trading to create and resolve marks?
   - LP position churn to farm benefits?

### Confirmation Logic

4. **What market movement confirms exposure?**
   - Absolute price change?
   - Relative to swap size?
   - Time-weighted price change?
   - Liquidity-adjusted impact?

5. **What observation window should be used?**
   - Block count?
   - Time-based (requires oracle)?
   - Adaptive based on volatility?

6. **How to prevent self-resolution?**
   - Can swapper trade again to clear their own mark?
   - Should there be a cooldown period?
   - Permissionless vs role-based resolution?

### Range-Level Attribution

7. **How to identify affected liquidity ranges?**
   - Track all positions via liquidity hooks?
   - Off-chain indexing with on-chain verification?
   - Integration with Position Manager?

8. **How to calculate per-range exposure?**
   - Proportional to liquidity in range?
   - Based on tick ranges crossed?
   - Time-weighted exposure?

### Economic Settlement

9. **What happens to confirmed exposure?**
   - Fee rebates for LPs?
   - Penalty fees for confirmed swappers?
   - Redistributed to affected liquidity ranges?

10. **How to account for exposure liability?**

- Maximum outstanding exposure limit?
- Reserve mechanisms?
- Cross-pool risk accounting?

## Security Considerations

⚠️ **This is experimental software under active development.**

- **Not audited** - No professional security review has been conducted
- **Not production-ready** - Economic model incomplete
- **Testnet only** - Do not deploy to mainnet with real funds
- **Research code** - Intended for experimentation and iteration

Known limitations:

- Economic parameters are placeholders
- Resolution logic not finalized
- Range-level attribution not implemented
- Gas optimization not complete
- Edge cases may not be handled
- No formal verification performed

## Future Work

### Short Term (Next Branches)

- Comprehensive test suite (unit, integration, fuzz, invariant)
- Gas optimization analysis
- Economic parameter research
- Empirical data collection from testnet

### Medium Term

- Materiality assessment implementation
- Confirmation/clearing criteria implementation
- Observation window logic
- Range-level exposure attribution architecture
- Settlement mechanics design

### Long Term

- Multi-pool exposure aggregation
- LP-specific exposure tracking
- Advanced analytics and reporting
- Formal verification of state machine
- Economic parameter governance (if needed)
- Production deployment preparation

## License

MIT

## Disclaimer

RemembraMark is experimental software provided "as is" without warranties. Use at your own risk. The protocol is under active research and development. Not intended for production use.
