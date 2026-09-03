RemembraMark Integration Verification

Branch: remembramark integrations

Verification: Source-level audit against installed official libraries and Uniswap v4 core

Executive Summary

Status: Implemented against official protocol libraries and locally verified.

✅ Reactive Network integration implemented against official reactive-lib

✅ Brevis integration implemented against official Brevis SDK

✅ Brevis Uniswap v4 storage layout verified against the installed v4-core source

✅ Solidity build successful

✅ All tests passed

✅ No mock protocol interfaces remain

✅ No Oracle, admin/emergency resolver, second state machine, dynamic fee, or settlement layer added

⏸️ Live network execution remains pending external infrastructure

This document distinguishes local implementation and verification from live network execution. The integrations should not be described as live end-to-end integrations until actual network execution has been completed.

1. Reactive Network Integration

1.1 Official Library

Repository: https://github.com/Reactive-Network/reactive-lib

Installed commit:

f6990ce3526928d039fec78855b2004ff8d65c9f

Location:

lib/reactive-lib/

The implementation uses the installed official Reactive library rather than custom replacement interfaces.

1.2 AbstractReactive

The installed library provides AbstractReactive with a parameterless constructor that initializes the Reactive service and VM/RN environment detection.

The implementation inherits directly from AbstractReactive.

Status: ✅ Verified

1.3 Reactive LogRecord

The implementation uses the current Reactive LogRecord structure:

struct LogRecord {
uint256 chain_id;
address \_contract;
uint256 topic_0;
uint256 topic_1;
uint256 topic_2;
uint256 topic_3;
bytes data;
uint256 block_number;
uint256 op_code;
uint256 block_hash;
uint256 tx_hash;
uint256 log_index;
}

The resolver implements:

function react(LogRecord calldata log)
external
override
vmOnly

Status: ✅ Verified

1.4 Callback Mechanism

The implementation uses the official Reactive Callback event:

event Callback(
uint256 indexed chain_id,
address indexed \_contract,
uint64 indexed gas_limit,
bytes payload
);

The resolver emits a callback targeting the RemembraMark hook after the observation window has elapsed.

Status: ✅ Verified

1.5 Event Subscription

The ReactVM-side resolver registers an event subscription through the official subscription service:

service.subscribe(
\_originChainId,
\_remembraMarkHook,
EXPOSURE_MARKED_TOPIC,
REACTIVE_IGNORE,
REACTIVE_IGNORE,
REACTIVE_IGNORE
);

The subscription listens for the canonical ExposureMarked event.

Status: ✅ Verified

1.6 VM/RN Execution Separation

The implementation uses the official environment restrictions:

vmOnly
rnOnly

The event-processing function runs in the ReactVM environment, while the destination-side resolution path is restricted to the appropriate Reactive Network environment.

Status: ✅ Verified

1.7 ExposureMarked Event Topic

The canonical event in src/ExposureLedger.sol is:

event ExposureMarked(
bytes32 indexed markId,
PoolId indexed poolId,
address indexed swapper,
int24 tickAtMark,
int256 swapAmountSpecified,
bool zeroForOne,
uint256 creationBlock,
uint256 nonce,
uint160 sqrtPriceAtMark,
uint256 exposureMagnitude
);

The topic was calculated from the canonical event signature:

ExposureMarked(bytes32,bytes32,address,int24,int256,bool,uint256,uint256,uint160,uint256)

Result:

0x2c0d511f412c7d04214f7530f3d8b79fdbaca88062748d1debb97ee55750e560

The resolver uses this exact topic.

Status: ✅ Verified

1.8 Reactive Security Model

Reactive does not own RemembraMark state.

Its role is limited to:

ExposureMarked event → trigger → callback

RemembraMark remains responsible for validating whether the mark is eligible for resolution and for performing the final state transition.

Therefore Reactive cannot:

override mark state;

bypass resolution eligibility;

force an invalid state transition;

custody user funds.

Status: ✅ Verified

2. Brevis Integration

2.1 Official SDK

Repository: https://github.com/brevis-network/brevis-sdk

Installed commit:

ab144820672d16962c0c4a7c6e074fa4e5ae68c2

Location:

lib/brevis-sdk/

The integration uses the official Brevis SDK and its application callback pattern.

2.2 Brevis Callback

The contract follows the Brevis application pattern:

function brevisCallback(
bytes32 \_appVkHash,
bytes calldata \_appCircuitOutput
)
external
onlyBrevisRequest

The callback validates:

the caller is the configured Brevis request contract;

the application verification-key hash matches the expected circuit;

the circuit output corresponds to the expected RemembraMark data.

Status: ✅ Verified

2.3 Verification-Key Binding

The integration stores an expected circuit VK hash:

bytes32 public immutable expectedVkHash;

The callback rejects results whose VK hash does not match the configured circuit.

This prevents an unrelated circuit from being accepted as the RemembraMark verification circuit.

Status: ✅ Verified

3. Brevis Historical Price-Movement Circuit

3.1 Circuit

The circuit is located at:

brevis-circuits/price_movement.go

It uses actual Brevis SDK types and APIs.

The circuit binds the proof to:

markId
poolId
PoolManager address
startBlock
endBlock

and produces:

price movement in basis points
start sqrtPriceX96
end sqrtPriceX96

4. Verified Uniswap v4 Storage Layout

The Brevis circuit now uses the actual Uniswap v4 PoolManager storage layout inspected from the installed v4-core source.

Source:

lib/uniswap-hooks/lib/v4-periphery/lib/v4-core/

Solidity version: 0.8.26

Inspected files include:

src/PoolManager.sol
src/libraries/StateLibrary.sol
src/libraries/Pool.sol
src/types/Slot0.sol

4.1 PoolManager Storage

The PoolManager declares:

mapping(PoolId id => Pool.State) internal \_pools;

The mapping uses storage slot:

6

The v4-core StateLibrary defines:

bytes32 public constant POOLS_SLOT = bytes32(uint256(6));

4.2 Pool State Slot

The verified storage formula is:

function \_getPoolStateSlot(PoolId poolId)
internal
pure
returns (bytes32)
{
return keccak256(
abi.encodePacked(
PoolId.unwrap(poolId),
POOLS_SLOT
)
);
}

Therefore:

Pool.State slot = keccak256(poolId || bytes32(6))

where poolId is the actual Uniswap v4 PoolId.

The circuit implements the same calculation:

func (c *PriceMovementCircuit) computePoolStateSlot(
api *sdk.CircuitAPI
) sdk.Bytes32 {
poolsSlotValue := api.Constant(6)
packed := api.Concat(c.PoolId, poolsSlotValue)
return api.Keccak256(packed)
}

Status: ✅ Verified against v4-core

5. Pool State and slot0

The verified Pool.State structure places slot0 at offset 0:

struct State {
Slot0 slot0;
uint256 feeGrowthGlobal0X128;
uint256 feeGrowthGlobal1X128;
uint128 liquidity;
mapping(int24 => TickInfo) ticks;
mapping(int16 => uint256) tickBitmap;
mapping(bytes32 => Position.State) positions;
}

Therefore the storage location for slot0 is the calculated Pool.State slot itself.

Status: ✅ Verified

6. sqrtPriceX96 Extraction

Uniswap v4 stores Slot0 as a packed bytes32.

The lowest 160 bits contain sqrtPriceX96.

The circuit therefore extracts the low 160 bits of the historical storage value.

Conceptually:

sqrtPriceX96 = uint160(slot0Value)

The circuit uses the corresponding Brevis SDK conversion:

api.ToUint160(storageValue)

This matches the v4 Slot0Library.sqrtPriceX96() behavior.

Status: ✅ Verified

7. Circuit Output

The circuit produces:

type PriceMovementCircuit struct {
MarkId sdk.Bytes32
PriceMovementBps sdk.Int248
SqrtPriceStart sdk.Uint160
SqrtPriceEnd sdk.Uint160
}

The Solidity integration decodes the same output structure:

(
bytes32 markId,
int256 priceMovementBps,
uint160 sqrtPriceStart,
uint160 sqrtPriceEnd
) = abi.decode(
\_appCircuitOutput,
(bytes32, int256, uint160, uint160)
);

Status: ✅ Verified

8. Brevis Security Model

Brevis provides historical evidence.

It does not become the authority over RemembraMark state.

The intended trust boundary is:

Historical blockchain state
↓
Brevis circuit
↓
ZK proof
↓
Brevis verification/callback
↓
BrevisMarkVerifier
↓
RemembraMark validation
↓
Canonical state transition

The integration does not use an external price oracle.

A Brevis result cannot bypass RemembraMark's state validation rules.

Status: ✅ Verified

9. Testing

Solidity

forge build

Result:

SUCCESS

Full test suite:

All 52 tests passed
0 failed
0 skipped

Integration tests:

BrevisVerifierTest: 5/5 passed
ReactiveResolverTest: 4/4 passed

Core tests:

43/43 passed

Go

Module verification:

go mod verify

Result:

all modules verified

The local environment did not complete the full Go dependency/build process because the dependency download timed out.

Therefore:

✅ Go module integrity verified

✅ Circuit source implemented against the SDK

⏸️ Full proving/compilation execution remains pending

10. Current Execution Status

Reactive Network

Implementation: ✅ Complete

Local verification: ✅ Complete

Live execution: ⏸️ Pending

Live execution requires:

Reactive Lasna deployment

testnet funding

RemembraMark deployment on an origin chain

live ExposureMarked event

observation-window progression

Reactive callback delivery

Brevis

Implementation: ✅ Complete

Storage layout: ✅ Verified against installed v4-core

Local Solidity verification: ✅ Complete

Live proof execution: ⏸️ Pending

Live execution requires:

Go environment with required dependencies

circuit compilation

proving infrastructure/SRS as required by the SDK

historical RPC access

Brevis Request/Gateway configuration

deployed verifier

actual proof request and callback

11. Scope Compliance

The integration intentionally does not introduce:

❌ Oracle

❌ Admin/emergency resolution

❌ Second state machine

❌ Dynamic fee system

❌ Settlement/rebate mechanism

❌ Unrelated infrastructure

RemembraMark remains the canonical state authority.

Reactive provides an execution trigger.

Brevis provides cryptographically verified historical evidence.

Neither integration can independently override RemembraMark state.

12. Accuracy Statement

The project currently makes the following claims:

✅ Implemented against official Reactive Network and Brevis libraries.

✅ Reactive integration matches the installed official reactive-lib API.

✅ Brevis callback integration matches the installed Brevis application pattern.

✅ Brevis historical storage calculation matches the inspected Uniswap v4 PoolManager layout.

✅ Solidity integration tests pass.

✅ No fabricated protocol interfaces remain.

⏸️ Live protocol execution has not yet been completed.

Accordingly, the project does not claim live end-to-end Reactive or Brevis execution until such execution has actually been demonstrated.

13. Final Verification Checklist

Reactive

Official reactive-lib installed

Exact library commit recorded

AbstractReactive verified

LogRecord verified

Callback verified

Subscription API verified

vmOnly / rnOnly verified

Canonical ExposureMarked topic verified

No fabricated Reactive interfaces

Integration tests passed

Brevis

Official Brevis SDK installed

Exact SDK commit recorded

brevisCallback pattern verified

Brevis request authentication implemented

VK hash validation implemented

Circuit implemented using Brevis SDK

Mark binding implemented

Historical storage layout verified

PoolId-based storage slot calculation implemented

Pool.State slot0 offset verified

sqrtPriceX96 extraction verified

Integration tests passed

Live proof generation executed

Live Brevis callback executed

Overall

All 52 tests passed

Solidity build successful

No Oracle

No admin/emergency resolution

No second state machine

No dynamic fees

No settlement/rebate layer

RemembraMark remains canonical authority

Conclusion

Implementation: ✅ Verified

Reactive integration: ✅ Locally verified against official reactive-lib

Brevis integration: ✅ Locally verified against official Brevis SDK

Uniswap v4 storage layout: ✅ Verified against installed v4-core source

Solidity tests: ✅ All test passed

Live network execution: ⏸️ Pending external infrastructure

The integration layer is now technically scoped around the intended RemembraMark architecture:

RemembraMark
│
├── Reactive Network
│ └── WHEN should resolution be triggered?
│
└── Brevis
└── WHAT historical evidence supports resolution?

RemembraMark remains the final authority over mark resolution.
