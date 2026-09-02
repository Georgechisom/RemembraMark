// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IBrevisProof, IBrevisCallback} from "./interfaces/IBrevisProof.sol";
import {IRemembraMark} from "../interfaces/IRemembraMark.sol";
import {MarkTypes} from "../libraries/MarkTypes.sol";

// BrevisMarkVerifier
// Verifies historical pool price movement using Brevis ZK proofs for RemembraMark
// This contract acts as a verification layer that uses ZK proofs to verify:
//      1. Pool state at mark creation
//      2. Pool state at resolution time
//      3. Price change calculation
//      RemembraMark remains the source of truth and validates independently.
contract BrevisMarkVerifier is IBrevisCallback {
    // Address of the Brevis proof verification contract
    address public immutable brevisProof;

    // Address of the RemembraMark hook contract
    address public immutable remembraMarkHook;

    // Mapping from proof request ID to mark ID
    mapping(bytes32 => bytes32) public requestToMark;

    // Mapping from mark ID to proof request ID
    mapping(bytes32 => bytes32) public markToRequest;

    // Emitted when a proof request is submitted
    event ProofRequested(bytes32 indexed requestId, bytes32 indexed markId, uint256 timestamp);

    // Emitted when a proof is verified
    event ProofVerified(bytes32 indexed requestId, bytes32 indexed markId, bool shouldConfirm, uint256 priceChangeBps);

    // Proof request already exists
    error ProofAlreadyRequested(bytes32 markId);

    // Invalid proof request ID
    error InvalidRequestId(bytes32 requestId);

    // Unauthorized caller
    error Unauthorized();

    // Invalid proof output
    error InvalidProofOutput();

    //  _brevisProof Address of the Brevis proof verifier
    //  _remembraMarkHook Address of the RemembraMark hook
    constructor(address _brevisProof, address _remembraMarkHook) {
        brevisProof = _brevisProof;
        remembraMarkHook = _remembraMarkHook;
    }

    // Request ZK proof verification for a mark
    // This initiates the Brevis proof generation process
    // markId The exposure mark identifier
    // requestId The Brevis proof request identifier
    function requestProofForMark(bytes32 markId) external returns (bytes32 requestId) {
        // Check if proof already requested
        if (markToRequest[markId] != bytes32(0)) {
            revert ProofAlreadyRequested(markId);
        }

        // Get mark from RemembraMark
        MarkTypes.ExposureMark memory mark = IRemembraMark(remembraMarkHook).getMark(markId);

        // Generate deterministic request ID
        requestId = keccak256(abi.encodePacked(markId, block.number, msg.sender));

        // Store bidirectional mapping
        requestToMark[requestId] = markId;
        markToRequest[markId] = requestId;

        emit ProofRequested(requestId, markId, block.timestamp);

        // Brevis prover service
        // to generate a ZK proof verifying:
        // 1. Pool slot0 at mark.creationBlock (sqrtPriceAtMark)
        // 2. Pool slot0 at current block (sqrtPriceNow)
        // 3. Price change calculation: ((sqrtPriceNow/sqrtPriceAtMark)² - 1) × 10000
        //
        // The proof circuit would:
        // Read historical pool state from Uniswap v4 PoolManager
        // Verify state roots via Merkle proofs
        // Compute price change in zero-knowledge
        // Output: (markId, priceChangeBps, sqrtPriceAtMark, sqrtPriceNow)
        //
        // For testnet/demo: Off-chain prover service would be called here
        return requestId;
    }

    // Callback from Brevis when proof is ready
    // Only callable by Brevis proof contract
    // requestId The proof request identifier
    // output The proof output data
    function handleProofResult(bytes32 requestId, bytes calldata output) external override {
        // Verify caller is Brevis
        if (msg.sender != brevisProof) {
            revert Unauthorized();
        }

        // Get associated mark ID
        bytes32 markId = requestToMark[requestId];
        if (markId == bytes32(0)) {
            revert InvalidRequestId(requestId);
        }

        // Decode proof output
        // Expected format: (bytes32 markId, int256 priceChangeBps, uint160 sqrtPriceAtMark, uint160 sqrtPriceNow)
        if (output.length < 128) {
            revert InvalidProofOutput();
        }

        (bytes32 proofMarkId, int256 priceChangeBps, uint160 sqrtPriceAtMark, uint160 sqrtPriceNow) =
            abi.decode(output, (bytes32, int256, uint160, uint160));

        // Verify markId matches
        if (proofMarkId != markId) {
            revert InvalidProofOutput();
        }

        // Get mark from RemembraMark to verify zeroForOne direction
        MarkTypes.ExposureMark memory mark = IRemembraMark(remembraMarkHook).getMark(markId);

        // Determine if mark should be confirmed based on ZK-verified price movement
        bool shouldConfirm = _shouldConfirm(mark.zeroForOne, priceChangeBps);

        emit ProofVerified(
            requestId, markId, shouldConfirm, uint256(priceChangeBps > 0 ? priceChangeBps : -priceChangeBps)
        );

        // RemembraMark.resolveMark() must still be called externally
        // This contract only provides ZK-verified price data
        // RemembraMark validates eligibility and performs state transition
        //
        // The verified data can be used by:
        // 1. Off-chain indexers to inform resolution decisions
        // 2. Dashboard UIs to display verified price movements
        // 3. Automated resolvers (like ReactiveMarkResolver) to trigger resolution
    }

    // Determine if mark should be confirmed based on price movement
    // Matches RemembraMark's confirmation logic
    //  zeroForOne Direction of the swap
    //  priceChangeBps Price change in basis points (can be negative)
    //  shouldConfirm True if price moved against swap direction
    function _shouldConfirm(bool zeroForOne, int256 priceChangeBps) internal pure returns (bool shouldConfirm) {
        // Confirmation threshold: 50 bps (matches RemembraMark.CONFIRM_THRESHOLD_BPS)
        int256 threshold = 50;

        if (zeroForOne) {
            // Sold token0 → confirm if price rose
            return priceChangeBps > threshold;
        } else {
            // Bought token0 → confirm if price fell
            return priceChangeBps < -threshold;
        }
    }

    // Get proof request ID for a mark
    // markId The exposure mark identifier
    // requestId The proof request ID (zero if not requested)
    function getProofRequestForMark(bytes32 markId) external view returns (bytes32 requestId) {
        return markToRequest[markId];
    }

    // Get mark ID for a proof request
    // requestId The proof request identifier
    // markId The mark ID (zero if invalid request)
    function getMarkForProofRequest(bytes32 requestId) external view returns (bytes32 markId) {
        return requestToMark[requestId];
    }
}
