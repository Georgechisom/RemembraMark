# RemembraMark

**Liquidity that remembers.**

RemembraMark is an experimental Uniswap v4 hook that introduces an "economic memory" primitive for concentrated liquidity. Instead of treating material swaps as instantaneously forgotten events, RemembraMark creates **Exposure Marks** that track how liquidity interacts with significant market movements over time.

## Overview

Traditional automated market makers treat each swap as an isolated event. Liquidity providers are exposed to adverse selection and toxic flow, but the protocol has no mechanism to distinguish between different types of market participants or remember past interactions.

RemembraMark changes this by implementing a stateful observation model where material swaps create **Exposure Marks** that can be confirmed or cleared based on subsequent market behavior.

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

RemembraMark introduces a three state lifecycle for tracking liquidity exposure:

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

- **Pool context**: Which pool and tick range
- **Swap details**: Size, direction, timestamp
- **Lifecycle state**: Open, Confirmed, or Cleared
- **Resolution outcome**: When and how the mark was resolved

Marks use deterministic identifiers derived from:

```solidity
keccak256(poolId, swapper, tick, blockNumber)
```

This design:

- Avoids sequential ID storage costs
- Enables efficient lookups
- Provides collision resistance

## Mark Lifecycle

### Open

A mark is created when a swap meets materiality criteria (currently under research). The mark enters observation mode, awaiting future market data.

### Confirmed

If subsequent market movement indicates the swap created genuine LP exposure, the mark transitions to `Confirmed`. This signals that the liquidity provider experienced material adverse selection.

### Cleared

If market conditions normalize without material LP impact, the mark transitions to `Cleared`. This indicates the swap did not create lasting exposure.

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
Main hook contract integrating with Uniswap v4. Observes swap lifecycle events and coordinates mark creation. Inherits from `BaseHook` and uses only `beforeSwap` and `afterSwap` permissions.

**`ExposureLedger.sol`**  
Manages mark storage and state transitions. Enforces lifecycle rules and provides read access to mark data. Separated from hook integration for modularity.

**`MarkTypes.sol`**  
Core data structures and utilities. Defines `ExposureMark` struct, `MarkStatus` enum, and deterministic ID computation.

**`IRemembraMark.sol`**  
External interface for mark queries and protocol interaction.

### Design Principles

1. **Minimal critical-path logic** - Hook callbacks contain only essential operations
2. **Explicit state transitions** - Invalid state changes revert with clear errors
3. **Separation of concerns** - Hook integration separated from accounting logic
4. **No custody** - Protocol never holds user funds
5. **Deterministic identifiers** - Efficient, collision-resistant mark IDs
6. **Auditability** - Clean event emission for all state changes
7. **Modularity** - Economic logic can evolve independently of core architecture

## Current Implementation Status

This branch (`remembramark-core`) establishes the foundational architecture:

✅ **Implemented:**

- Core state model (Open/Confirmed/Cleared)
- Exposure mark data structures
- Ledger storage and lifecycle management
- Hook integration with Uniswap v4
- Event emission for indexing
- Deterministic mark identifiers
- State transition validation

❌ **Not Implemented (by design):**

- Economic materiality thresholds
- Confirmation/clearing criteria
- Observation window logic
- Settlement mechanics
- LP rebates or fee adjustments
- Governance or admin controls
- Production deployment infrastructure

The current implementation is intentionally conservative. It establishes a clean foundation for research rather than prematurely implementing arbitrary economic parameters.

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

Comprehensive testing will be performed on a separate branch. The current implementation focuses on architecture correctness.

```bash
# Tests will be expanded in future branches
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
- Only enables `beforeSwap` and `afterSwap` permissions
- No delta return (no direct swap intervention)
- No fee override currently implemented
- Compatible with v4-core state management

### Gas Optimization

- Minimal storage writes in critical path
- Deterministic IDs avoid sequential counters
- Events over storage where appropriate
- No unnecessary external calls in callbacks

### Security Model

- No fund custody
- No upgradeability (inherits v4 architecture)
- Explicit error messages for debugging
- State transition validation prevents corruption
- No admin priviliges for economic behavior

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
   - Role-based resolution?

### Economic Settlement

7. **What happens to confirmed exposure?**
   - Fee rebates for LPs?
   - Penalty fees for confirmed swappers?
   - Redistributed to affected liquidity ranges?

8. **How to account for exposure liability?**
   - Maximum outstanding exposure limit?
   - Reserve mechanisms?
   - Cross-pool risk accounting?

9. **Should the model be symmetric?**
   - Different treatment for long/short exposure?
   - Pool-specific parameters?
   - Adaptive parameters based on realized outcomes?

These questions require empirical research, economic modeling, and likely iterative refinement based on real world data.

## Security Considerations

⚠️ **This is experimental software under active development.**

- **Not audited** - No professional security review has been conducted
- **Not production-ready** - Economic model incomplete
- **Testnet only** - Do not deploy to mainnet with real funds
- **Research code** - Intended for experimentation and iteration

Known considerations:

- Economic parameters are placeholders
- Resolution logic not finalized
- Gas optimization not complete
- Edge cases may not be handled
- No formal verification performed

## Future Work

### Short Term (Next Branches)

- Comprehensive test suite (unit, integration, fuzz)
- Invariant testing for state machine
- Gas optimization analysis
- Economic parameter research
- Empirical data collection from testnet

### Medium Term

- Confirmation/clearing criteria implementation
- Observation window logic
- Materiality assessment algorithms
- Settlement mechanics design
- Fee adjustment integration

### Long Term

- Multi-pool exposure aggregation
- LP-specific exposure tracking
- Advanced analytics and reporting
- Formal verification of state machine
- Economic parameter governance
- Production deployment preparation

## License

MIT

## Disclaimer

RemembraMark is experimental software provided "as is" without warranties. Use at your own risk. The protocol is under active research and should not be used in production environments.
