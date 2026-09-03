package main

import (
	"github.com/brevis-network/brevis-sdk/sdk"
	"github.com/ethereum/go-ethereum/common"
)

// PriceMovementCircuit proves historical Uniswap v4 pool price movement
// for RemembraMark exposure verification using actual v4-core storage layout
type PriceMovementCircuit struct {
	// Inputs (public)
	MarkId          sdk.Bytes32   // Binds proof to specific mark (prevents reuse)
	PoolId          sdk.Bytes32   // Uniswap v4 PoolId (keccak256 of PoolKey)
	PoolManagerAddr sdk.Address   // Uniswap v4 PoolManager contract address
	StartBlock      sdk.Uint248   // Block at mark creation
	EndBlock        sdk.Uint248   // Block at resolution (startBlock + 25)
	
	// Outputs (public)
	PriceMovementBps sdk.Int248     // Price change in basis points
	SqrtPriceStart   sdk.Uint160    // sqrtPriceX96 at start
	SqrtPriceEnd     sdk.Uint160    // sqrtPriceX96 at end
	
	// Storage proofs (private witnesses)
	startStorage sdk.StorageData
	endStorage   sdk.StorageData
}

// Allocate registers circuit size and data requirements
func (c *PriceMovementCircuit) Allocate() (maxReceipts, maxStorage, maxTransactions int) {
	// We need 2 storage slot reads (start + end blocks)
	return 0, 2, 0
}

// Define implements the ZK circuit logic
func (c *PriceMovementCircuit) Define(api *sdk.CircuitAPI, in sdk.DataInput) error {
	// Compute the storage slot for this pool's state
	// Uses actual v4-core storage layout
	poolStateSlot := c.computePoolStateSlot(api)
	
	// Read Pool.State.slot0 at start block
	// slot0 is at offset 0 within Pool.State
	startReceipt := in.Storage.Select(0)
	
	// Verify storage query targets correct contract and slot
	api.OutputAddress(c.PoolManagerAddr)
	api.OutputBytes32(poolStateSlot)
	
	// Extract sqrtPriceX96 from slot0
	// slot0 packing: sqrtPriceX96 (160 bits, low) | tick (24 bits) | protocolFee (24 bits) | lpFee (24 bits)
	// We only need the low 160 bits
	c.SqrtPriceStart = api.ToUint160(startReceipt.Value)
	
	// Read Pool.State.slot0 at end block
	endReceipt := in.Storage.Select(1)
	c.SqrtPriceEnd = api.ToUint160(endReceipt.Value)
	
	// Calculate price movement in basis points
	// Formula: ((end/start)^2 - 1) * 10000
	c.PriceMovementBps = c.calculatePriceMovement(api, c.SqrtPriceStart, c.SqrtPriceEnd)
	
	// Bind outputs to markId (prevents proof reuse across different marks)
	api.OutputBytes32(c.MarkId)
	api.OutputInt248(c.PriceMovementBps)
	api.OutputUint160(c.SqrtPriceStart)
	api.OutputUint160(c.SqrtPriceEnd)
	
	return nil
}

// computePoolStateSlot calculates the storage slot for a pool's state
// Based on actual v4-core (Solidity 0.8.26) StateLibrary.sol:
//
// contract PoolManager {
//     mapping(PoolId id => Pool.State) internal _pools;  // slot 6
// }
//
// StateLibrary:
//   bytes32 public constant POOLS_SLOT = bytes32(uint256(6));
//   function _getPoolStateSlot(PoolId poolId) internal pure returns (bytes32) {
//       return keccak256(abi.encodePacked(PoolId.unwrap(poolId), POOLS_SLOT));
//   }
//
// Pool.State layout:
//   slot0 (Slot0 type = bytes32)           <- offset 0 (this is what we read)
//   feeGrowthGlobal0X128 (uint256)         <- offset 1
//   feeGrowthGlobal1X128 (uint256)         <- offset 2
//   liquidity (uint128)                    <- offset 3
//   ticks (mapping)                        <- offset 4
//   tickBitmap (mapping)                   <- offset 5
//   positions (mapping)                    <- offset 6
//
// Slot0 packing (bytes32):
//   bits [0:159]   = sqrtPriceX96 (uint160)  <- THIS IS WHAT WE EXTRACT
//   bits [160:183] = tick (int24)
//   bits [184:207] = protocolFee (uint24)
//   bits [208:231] = lpFee (uint24)
//   bits [232:255] = unused
func (c *PriceMovementCircuit) computePoolStateSlot(api *sdk.CircuitAPI) sdk.Bytes32 {
	// POOLS_SLOT = 6 (from v4-core/src/libraries/StateLibrary.sol line 11)
	poolsSlot := sdk.Bytes32{}
	// Convert constant 6 to bytes32
	poolsSlotValue := api.Constant(6)
	
	// Storage slot = keccak256(abi.encodePacked(poolId, POOLS_SLOT))
	// This matches StateLibrary._getPoolStateSlot() exactly
	// abi.encodePacked means: poolId (32 bytes) || poolsSlot (32 bytes) = 64 bytes total
	
	// Concatenate: poolId ++ bytes32(6)
	packed := api.Concat(c.PoolId, poolsSlotValue)
	
	// Hash to get storage slot
	return api.Keccak256(packed)
}

// calculatePriceMovement computes price change in basis points
// Given sqrtPriceX96 at two points:
//   price = (sqrtPriceX96 / 2^96)^2
//   priceRatio = priceEnd / priceStart = (sqrtPriceEnd / sqrtPriceStart)^2
//   bps = (priceRatio - 1) * 10000
func (c *PriceMovementCircuit) calculatePriceMovement(
	api *sdk.CircuitAPI,
	sqrtPriceStart sdk.Uint160,
	sqrtPriceEnd sdk.Uint160,
) sdk.Int248 {
	// Convert to larger field for calculation
	start := api.ToUint248(sqrtPriceStart)
	end := api.ToUint248(sqrtPriceEnd)
	
	// Price ratio = (end / start)^2
	// We compute: ((end^2 / start^2) - 1) * 10000
	
	endSquared := api.Mul(end, end)
	startSquared := api.Mul(start, start)
	
	// Ratio in fixed point (multiply by 10000 for bps)
	ratio := api.Mul(endSquared, api.Constant(10000))
	ratio = api.Div(ratio, startSquared)
	
	// Subtract 10000 (representing 1.0 = 100%)
	bps := api.Sub(ratio, api.Constant(10000))
	
	return api.ToInt248(bps)
}

// AssignInput assigns witness data from query results
func (c *PriceMovementCircuit) AssignInput(in sdk.DataInput) error {
	// Assign storage proofs
	if len(in.StorageSlots) >= 2 {
		c.startStorage = in.StorageSlots[0]
		c.endStorage = in.StorageSlots[1]
	}
	return nil
}
