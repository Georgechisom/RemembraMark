// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Brevis ZK proof verification interface
// Based on Brevis coprocessor callback pattern
// Content was rephrased for compliance with licensing restrictions
interface IBrevisProof {
    // Proof result structure returned by Brevis prover
    struct ProofData {
        bytes32 vkHash; // Verification key hash
        bytes32 appCommitHash; // Application circuit commitment
        bytes32 appVkHash; // Application verification key hash
        bytes proof; // ZK proof bytes
    }

    // Verify a ZK proof and return the output
    // proof The proof data structure
    // outputs Expected outputs from the circuit
    // success True if proof is valid
    function verifyProof(ProofData calldata proof, bytes calldata outputs) external view returns (bool success);
}

// Callback interface for contracts receiving Brevis proofs
// Content was rephrased for compliance with licensing restrictions
interface IBrevisCallback {
    // Called by Brevis when proof is ready
    //  requestId Unique identifier for the proof request
    //  output Circuit output data
    function handleProofResult(bytes32 requestId, bytes calldata output) external;
}
