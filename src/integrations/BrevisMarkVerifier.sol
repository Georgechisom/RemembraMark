// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IRemembraMark} from "../interfaces/IRemembraMark.sol";
import {MarkTypes} from "../libraries/MarkTypes.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";


// BrevisMarkVerifier
// Brevis ZK coprocessor integration for RemembraMark historical price verification
// Implements the official Brevis BrevisApp pattern (lib/brevis-sdk/examples/contracts/contracts/lib/BrevisApp.sol)

// VERIFIED AGAINST: brevis-sdk commit ab14482
// Pattern: BrevisApp with brevisCallback(bytes32 _appVkHash, bytes calldata _appCircuitOutput)
 
// ARCHITECTURE:
// 1. Off-chain: Brevis circuit proves historical Uniswap v4 pool price movement
// 2. Off-chain: Circuit computes if price changed ≥50 bps during observation window  
// 3. On-chain: Brevis Gateway calls brevisCallback() with verified circuit output
// 4. On-chain: This contract stores verified result for RemembraMark to query
  
// SECURITY:
// Only Brevis Request contract can call brevisCallback()
// Circuit output is cryptographically verified by Brevis before callback
// RemembraMark remains canonical authority for state transitions
// This contract provides verified historical evidence, not state control
contract BrevisMarkVerifier {
    using PoolIdLibrary for PoolId;

    // Brevis Request contract address (set per network)
    address public immutable brevisRequest;

    // RemembraMark hook address
    address public immutable remembraMarkHook;

    // Expected app circuit vkHash (from compiled Brevis circuit)
    bytes32 public immutable expectedVkHash;

    // Mapping from markId to verification status
    mapping(bytes32 => bool) public markVerified;

    // Mapping from markId to verified price movement (in bps)
    mapping(bytes32 => int256) public verifiedPriceMovement;

    // Emitted when Brevis delivers verified result
    event ProofVerified(bytes32 indexed markId, int256 priceMovementBps, bool meetsThreshold);

    error UnauthorizedCaller();
    error InvalidVkHash();
    error InvalidCircuitOutput();
    error MarkAlreadyVerified();

    modifier onlyBrevisRequest() {
        if (msg.sender != brevisRequest) revert UnauthorizedCaller();
        _;
    }

    // _brevisRequest Address of Brevis Request contract
    // _remembraMarkHook Address of RemembraMark hook  
    // _expectedVkHash Verification key hash of compiled Brevis circuit
    constructor(address _brevisRequest, address _remembraMarkHook, bytes32 _expectedVkHash) {
        brevisRequest = _brevisRequest;
        remembraMarkHook = _remembraMarkHook;
        expectedVkHash = _expectedVkHash;
    }

    // Brevis callback (called by Brevis Request after proof verification)
    // Implements BrevisApp.brevisCallback() from official SDK
    // _appVkHash Circuit verification key hash
    // _appCircuitOutput ABI-encoded circuit output
      
    // Circuit output format:
    // abi.encode(
    //     bytes32 markId,
    //     int256 priceMovementBps,  // Price change in basis points (signed)
    //     uint160 sqrtPriceStart,   // sqrtPriceX96 at start
    //     uint160 sqrtPriceEnd      // sqrtPriceX96 at end
    // )
    function brevisCallback(bytes32 _appVkHash, bytes calldata _appCircuitOutput)
        external
        onlyBrevisRequest
    {
        // Verify circuit vkHash matches expected
        if (_appVkHash != expectedVkHash) {
            revert InvalidVkHash();
        }

        // Decode circuit output
        (bytes32 markId, int256 priceMovementBps, uint160 sqrtPriceStart, uint160 sqrtPriceEnd) =
            abi.decode(_appCircuitOutput, (bytes32, int256, uint160, uint160));

        // Verify mark exists
        MarkTypes.ExposureMark memory mark = IRemembraMark(remembraMarkHook).getMark(markId);
        
        // Prevent re-verification
        if (markVerified[markId]) {
            revert MarkAlreadyVerified();
        }

        // Store verified result
        markVerified[markId] = true;
        verifiedPriceMovement[markId] = priceMovementBps;

        // Determine if mark should be Confirmed based on verified price movement
        // Threshold: 50 bps (0.50%)
        bool meetsThreshold = _shouldConfirm(mark.zeroForOne, priceMovementBps);

        emit ProofVerified(markId, priceMovementBps, meetsThreshold);

        // This contract does NOT automatically call resolveMark()
        // RemembraMark.resolveMark() must be called separately
        // RemembraMark independently validates eligibility before state transition
    }

    // Check if mark should be confirmed based on verified price movement
    // Matches RemembraMark confirmation logic
    function _shouldConfirm(bool zeroForOne, int256 priceMovementBps) internal pure returns (bool) {
        int256 threshold = 50; // 50 bps = 0.50%

        if (zeroForOne) {
            // Sold token0 → confirm if price rose (adverse movement)
            return priceMovementBps >= threshold;
        } else {
            // Bought token0 → confirm if price fell
            return priceMovementBps <= -threshold;
        }
    }

    // Get verification status and result for a mark
    function getVerificationResult(bytes32 markId)
        external
        view
        returns (bool verified, int256 priceMovementBps, bool meetsThreshold)
    {
        verified = markVerified[markId];
        priceMovementBps = verifiedPriceMovement[markId];

        if (verified) {
            MarkTypes.ExposureMark memory mark = IRemembraMark(remembraMarkHook).getMark(markId);
            meetsThreshold = _shouldConfirm(mark.zeroForOne, priceMovementBps);
        }
    }
}
