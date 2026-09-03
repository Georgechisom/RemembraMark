# RemembraMark

## Liquidity that remembers.

**RemembraMark** is an experimental Uniswap v4 hook that introduces an economic memory primitive for concentrated liquidity.

Instead of treating a material swap as an isolated event, RemembraMark records an **Exposure Mark** and observes what happens after the trade. The mark remains open during a bounded observation window and can later resolve to **Confirmed** or **Cleared** based on subsequent market behavior.

The result is a new pool level primitive for measuring whether a material trade is followed by price movement in the direction that may indicate persistent post-trade exposure.

> **RemembraMark does not try to eliminate all MEV. It gives liquidity a memory of material exposure and lets subsequent market behavior determine how that exposure resolves.**

---

## Why RemembraMark?

Concentrated liquidity gives capital efficiency, but it also exposes liquidity providers to adverse selection, arbitrage, and other forms of post trade value leakage.

Most AMM mechanisms focus on what happens **during execution**.

RemembraMark explores a different question:

**What if liquidity could remember a material trade and evaluate the market after the trade?**

That creates a time shifted observation model:

```text
Material Swap
     │
     ▼
Exposure Mark Created
     │
     ▼
Observation Window
     │
     ├───────────────┐
     ▼               ▼
 Confirmed         Cleared
```

This makes post trade behavior measurable without requiring an oracle, centralized monitoring service, or immediate intervention in the swap path.

---

## The Core Primitive: Exposure Mark

An **Exposure Mark** is a persistent record of material pool level trading activity.

Each mark captures:

- Pool context
- Price and tick at creation
- Swap size and direction
- Swapper address
- Creation block
- Observation and resolution information
- Lifecycle status
- Deterministic identifier

Mark identifiers use a monotonic nonce to prevent collisions even when the same address performs multiple swaps in the same block and at the same tick.

Conceptually:

```solidity
keccak256(poolId, swapper, tick, blockNumber, nonce)
```

The nonce is maintained by the protocol rather than relying on external transaction data.

---

## Mark Lifecycle

RemembraMark uses a deliberately small state machine:

```text
OPEN
  │
  ├──────────────► CONFIRMED
  │
  └──────────────► CLEARED
```

### Open

A mark is created when a swap satisfies the current experimental materiality criteria.

The mark then enters an observation period.

### Confirmed

A mark becomes Confirmed when subsequent market movement satisfies the experimental confirmation threshold.

The current V1 implementation uses a **50 basis point price movement threshold**.

A Confirmed mark is a **proxy signal**. It is not definitive proof of informed trading, toxic flow, or MEV.

### Cleared

A mark becomes Cleared when the observation period completes without satisfying the confirmation condition.

### State Integrity

Terminal states cannot be reopened or changed:

```text
Open → Confirmed
Open → Cleared

Confirmed → Open       Not allowed
Confirmed → Cleared    Not allowed
Cleared → Open         Not allowed
Cleared → Confirmed    Not allowed
```

---

## What a Confirmed Mark Means

A Confirmed Mark means that the observed price movement during the defined window met the experimental confirmation condition.

That behavior may be consistent with:

- Adverse selection
- Persistent post trade exposure
- Informed flow
- Ordinary market volatility

Therefore:

> **Confirmed does not mean “toxic trader proven.”**

The V1 mechanism is intentionally framed as an **empirical signal**, not a perfect classifier.

The purpose of the primitive is to create measurable data that can later support stronger economic mechanisms.

---

## Design Philosophy

RemembraMark is built around a small number of explicit principles.

### 1. Memory without intervention

The hook records and evaluates exposure rather than changing the execution of a swap.

### 2. Minimal critical path

Hook callbacks perform only the operations required to observe and record activity.

### 3. Canonical state authority

RemembraMark remains the final authority over mark state.

### 4. Deterministic state

Mark identity and lifecycle transitions are deterministic and auditable.

### 5. Permissionless resolution

Resolution is gated by protocol eligibility rules rather than privileged administration.

### 6. No custody

The system does not custody user funds.

### 7. No oracle dependency

The current mechanism does not require an external price oracle.

### 8. Modular verification

Historical verification and automation are separated from the core state machine.

---

# Architecture

## Core Contracts

### `src/RemembraMarkHook.sol`

The main Uniswap v4 hook.

It observes swap activity through the configured `beforeSwap` and `afterSwap` lifecycle callbacks.

The current implementation focuses on **pool level swap observation** rather than assigning exposure to individual LP positions.

### `src/ExposureLedger.sol`

The canonical mark ledger.

It stores Exposure Marks, enforces state transitions, and validates resolution eligibility.

### `src/libraries/MarkTypes.sol`

Defines the core mark data structures, status enum, and deterministic identifier logic.

### `src/interfaces/IRemembraMark.sol`

Defines the external interface for interacting with and querying RemembraMark.

---

# Protocol Flow

```text
                 UNISWAP V4
                     │
                     ▼
                    Swap
                     │
                     ▼
               RemembraMarkHook
                     │
                     ▼
               ExposureLedger
                     │
                     ▼
               Exposure Mark
                     │
                     ▼
               Observation
                   Window
                     │
          ┌──────────┴──────────┐
          │                     │
          ▼                     ▼
       Brevis                Reactive
   Historical Evidence     Resolution Trigger
          │                     │
          └──────────┬──────────┘
                     ▼
              RemembraMark
               State Check
                     │
              ┌──────┴──────┐
              ▼             ▼
          Confirmed       Cleared
```

**RemembraMark is the canonical state authority.**

---

# Integrations

## Brevis ZK Coprocessor

### Purpose

Brevis is used to provide historical evidence for price movement during the observation period.

The integration is built around the official Brevis SDK and a custom circuit in:

```text
brevis-circuits/price_movement.go
```

The circuit binds historical verification to:

- `markId`
- `poolId`
- PoolManager address
- Start block
- End block
- Historical `sqrtPriceX96`

### Verification Model

```text

Exposure Mark
     │
     ▼
Proof Request
     │
     ▼
Brevis Circuit
     │
     ├── Historical PoolManager storage
     ├── Storage proofs
     ├── sqrtPriceX96 extraction
     └── Price movement calculation
     │
     ▼
ZK Proof
     │
     ▼
Brevis Callback
     │
     ▼
BrevisMarkVerifier
     │
     ▼
RemembraMark validation

```

### Uniswap v4 Storage Verification

The circuit uses the actual Uniswap v4 PoolManager storage layout verified from the installed v4-core source.

The PoolManager stores pool state in:

```solidity
mapping(PoolId id => Pool.State) internal _pools;
```

The verified base storage slot is:

```text
POOLS_SLOT = 6
```

The pool state slot is derived using:

```solidity
keccak256(
    abi.encodePacked(
        PoolId.unwrap(poolId),
        bytes32(uint256(6))
    )
)
```

`Pool.State.slot0` is at offset `0`, and the low 160 bits of the packed `Slot0` value contain `sqrtPriceX96`.

This is reflected in the circuit implementation rather than using a simplified pool address proxy.

### Brevis Contract

```text
src/integrations/BrevisMarkVerifier.sol
```

The contract uses the Brevis callback pattern, validates the configured request sender, validates the expected verification key hash, and validates the circuit output before exposing the result to RemembraMark.

### Current Status

**Implemented and locally verified.**

Live proof generation and callback execution remain dependent on the required Brevis proving infrastructure.

---

## Reactive Network

### Purpose

Reactive Network provides event driven automation for the RemembraMark observation lifecycle.

Instead of requiring a centralized process to poll the blockchain and trigger eligible marks, the Reactive integration listens for `ExposureMarked` events and schedules the resolution callback.

### Flow

```text

Origin Chain
     │
     │ ExposureMarked
     ▼
Reactive Network
     │
     ▼
ReactiveMarkResolver.react(...)
     │
     │ observation window reached
     ▼
Callback(...)
     │
     ▼
RemembraMark
     │
     ▼
Resolution

```

### Implementation

```text
src/integrations/ReactiveMarkResolver.sol
```

The resolver is implemented against the official Reactive Network library and uses:

- `AbstractReactive`
- `IReactive`
- `LogRecord`
- `ISystemContract`
- `vmOnly`
- `rnOnly`
- Official `Callback` mechanism

The resolver subscribes to the canonical `ExposureMarked` event.

The event topic is derived from the actual event declaration in `src/ExposureLedger.sol`.

### Current Status

**Implemented and locally verified against the installed official Reactive library.**

Live Reactive Network execution remains pending testnet deployment.

---

# Integration Security Model

The integrations helps the RemembraMark core.

## Brevis

Brevis provides historical evidence.

It does not independently control the mark state.

## Reactive

Reactive provides an automation trigger.

It does not determine whether a mark is Confirmed or Cleared.

## RemembraMark

RemembraMark performs the final eligibility checks and state transition.

This separation means external infrastructure cannot:

- Force arbitrary mark states
- Bypass lifecycle rules
- Override resolution eligibility
- Custody protocol funds
- Change fee structures
- Introduce an external price oracle into the core mechanism

---

# Swap Observation vs. LP Exposure Attribution

The current implementation is intentionally **pool level**.

It records:

- Pool
- Tick and price context
- Swap size
- Swap direction
- Swapper
- Block information
- Subsequent market movement

It does not yet attribute the exposure to individual concentrated liquidity ranges or positions.

That distinction is important.

A swap that crosses several tick ranges can affect a very different set of liquidity providers from a swap that stays within one range.

---

# Current Parameters

The V1 implementation uses experimental parameters intended for research and calibration.

| Parameter              |                         Current Value |
| ---------------------- | ------------------------------------: |
| Observation Window     |                             25 blocks |
| Confirmation Threshold |                                50 bps |
| Mark Identifier        | Pool + swap context + monotonic nonce |
| Resolution             |     Permissionless, eligibility gated |

These parameters are experimental and are not presented as optimized economic constants.

---

# Testing

The complete Solidity test suite currently passes:

```text
All tests passed
0 failed
0 skipped
```

The suite covers the core hook, mark identity, lifecycle transitions, economic logic, swaps, and integration contracts.

Integration coverage includes:

```text
BrevisVerifierTest
ReactiveResolverTest
```

The local build completes successfully with the project's Solidity compiler configuration.

The Brevis circuit dependencies have also been verified through the Go module configuration.

Live protocol execution is separate from local contract testing and remains an infrastructure dependent step.

---

# Repository Structure

```text

RemembraMark/
│
├── src/
│   ├── RemembraMarkHook.sol
│   ├── ExposureLedger.sol
│   ├── integrations/
│   │   ├── BrevisMarkVerifier.sol
│   │   └── ReactiveMarkResolver.sol
│   ├── libraries/
│   │   └── MarkTypes.sol
│   └── interfaces/
│       └── IRemembraMark.sol
│
├── brevis-circuits/
│   ├── price_movement.go
│   ├── main.go
│   ├── go.mod
│   └── README.md
│
├── test/
│   ├── integrations/
│   │   ├── BrevisVerifier.t.sol
│   │   └── ReactiveResolver.t.sol
│   └── ...
│
├── lib/
│   ├── brevis-sdk/
│   └── reactive-lib/
│
├── script/
│
├── integration.md
├── foundry.toml
└── README.md

```

---

# Development

## Requirements

- Foundry
- Git
- Go 1.21 or newer for Brevis circuit work

## Install

```bash
git clone https://github.com/Georgechisom/RemembraMark.git
cd RemembraMark
forge install
```

## Build

```bash
forge build
```

## Test

```bash
forge test
```

Expected local result:

```text
All 52 tests passed
```

## Local Anvil Development

Start Anvil:

```bash
anvil
```

Then use the deployment and interaction scripts in `script/` for local pool creation, liquidity setup, swaps, and hook testing.

---

# Research Questions

RemembraMark is intentionally presented as an experimental economic primitive. Several research questions remain open.

## Materiality

What should make a swap materially significant?

Possible signals include:

- Absolute swap size
- Swap size relative to pool liquidity
- Price impact
- Tick displacement
- Volatility adjusted exposure

## Normalization

How should exposure be normalized across:

- Stablecoin pools
- Volatile pairs
- Different liquidity profiles
- Different tick spacings

## Confirmation

What post trade behavior is the strongest signal of persistent exposure?

Possible approaches include:

- Absolute price movement
- Movement relative to swap size
- Volatility adjusted movement
- Time-weighted movement
- Liquidity adjusted measures

## Manipulation Resistance

How should the protocol handle:

- Repeated small swaps
- Self trading
- Manufactured marks
- Resolution manipulation
- Liquidity position churn

## Range Attribution

How should a pool level mark eventually map to:

- Tick ranges
- Individual liquidity providers
- Position-level exposure
- Realized and unrealized exposure

## Economic Settlement

Once the signal is sufficiently validated, what should happen economically?

Potential directions include:

- LP rebates
- Exposure aware fees
- Liability accounting
- Range specific redistribution

These mechanisms are intentionally outside the current V1 scope.

---

# What RemembraMark Claims

RemembraMark introduces an economic memory primitive for concentrated liquidity.

It claims that material swaps can be recorded as persistent Exposure Marks and evaluated against subsequent market behavior rather than being treated as isolated events.

The protocol is designed to provide:

- A measurable record of post trade liquidity exposure
- A time shifted signal for identifying potentially adverse post trade conditions
- Historical evidence that can be independently verified
- Automated resolution of exposure observations
- A foundation for economically differentiating trading conditions based on observed exposure

The long term objective is to turn this exposure signal into an economic mechanism that can improve the alignment between liquidity providers and the activity that consumes their liquidity.

RemembraMark is not limited to analytics. The Exposure Mark is designed as the primitive through which future economic mechanisms can be built.

## Economic Value

RemembraMark is designed to create an economic feedback loop around liquidity exposure.

Today, the protocol records and resolves exposure. As the economic layer matures, confirmed exposure can become an input into mechanisms that improve how value is distributed around liquidity.

Potential economic applications include:

### Exposure aware fees

Trading activity that repeatedly creates significant post trade exposure could be priced differently from ordinary flow.

### LP compensation

A portion of fees associated with confirmed exposure could eventually be directed toward the liquidity that absorbed that risk.

### Exposure based liquidity incentives

Pools and liquidity ranges that consistently absorb high quality flow could receive differentiated incentives.

### Risk aware pool analytics

Exposure Marks can provide a measurable history of how a pool reacts to different trading conditions, enabling more informed liquidity allocation.

### Realized exposure accounting

Future versions can connect observed exposure to realized outcomes and build a more precise accounting model for liquidity-provider risk.

The intended economic loop is:

```text

Swap
  ↓
Exposure Mark
  ↓
Observation
  ↓
Confirmed Exposure
  ↓
Economic Attribution
  ↓
Value returned to liquidity

```

## Why This Can Matter Economically

Liquidity providers currently earn fees for supplying liquidity, but the economic relationship between fees earned and adverse post trade exposure is difficult to measure directly.

RemembraMark introduces a measurable intermediate layer:

```text

Trading Activity
      ↓
Liquidity Exposure
      ↓
Observed Market Consequence
      ↓
Economic Attribution

```

# Current Scope

Implemented:

- Uniswap v4 hook integration
- Exposure Mark data model
- Deterministic mark identifiers
- Monotonic nonce-based uniqueness
- Open, Confirmed, and Cleared lifecycle
- Resolution eligibility checks
- Permissionless resolution
- ExposureMarked event stream
- Brevis integration layer
- Brevis historical price-movement circuit
- Reactive Network integration layer
- Integration tests
- Comprehensive Solidity test suite

Not included in V1:

- Individual LP range attribution
- LP-specific settlement
- Rebate distribution
- Dynamic fee adjustment
- Oracle-based resolution
- Administrative or emergency resolution
- Production deployment infrastructure
- Formal verification

# Security and Limitations

RemembraMark is experimental research software.

It has not undergone a professional security audit and should not be treated as production ready financial infrastructure.

Important limitations include:

- Economic parameters remain experimental
- Range level exposure attribution is not implemented
- Live Brevis proving has not been demonstrated in the current development environment
- Live Reactive Network execution has not been demonstrated in the current development environment
- No formal verification has been performed
- The economic settlement model remains future work

Do not use the system with funds you cannot afford to lose.

# Future Direction

RemembraMark is designed to evolve from an exposure observation primitive into an economic coordination layer for liquidity.

```text
V1
Exposure Memory
    ↓
V2
Range-Level Attribution
    ↓
V3
Exposure-Aware Economics
    ↓
V4
Liquidity Risk & Value Distribution

```

The architectural goal is to keep the observation primitive simple while allowing economic mechanisms to evolve independently.

## License

MIT

# Disclaimer

RemembraMark is experimental software provided on an "as is" basis without warranties.

The project is being developed toward production deployment as its economic and security model matures.

Production development is expected to extend the current Exposure Mark primitive into economically meaningful mechanisms including exposure aware fees, liquidity provider compensation, exposure attribution, and realized risk accounting.

The current implementation should therefore be understood as the foundational protocol layer.
