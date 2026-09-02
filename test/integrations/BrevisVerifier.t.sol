// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {BrevisMarkVerifier} from "../../src/integrations/BrevisMarkVerifier.sol";
import {IBrevisProof, IBrevisCallback} from "../../src/integrations/interfaces/IBrevisProof.sol";
import {IRemembraMark} from "../../src/interfaces/IRemembraMark.sol";
import {MarkTypes} from "../../src/libraries/MarkTypes.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

// BrevisVerifier Tests
// Tests for BrevisMarkVerifier ZK proof integration
contract BrevisVerifierTest is Test {
    BrevisMarkVerifier public verifier;
    MockBrevisProof public mockBrevis;
    MockRemembraMark public mockHook;

    address public constant ALICE = address(0xA11CE);
    bytes32 public constant MOCK_MARK_ID = keccak256("mock_mark_id");

    function setUp() public {
        mockBrevis = new MockBrevisProof();
        mockHook = new MockRemembraMark();
        verifier = new BrevisMarkVerifier(address(mockBrevis), address(mockHook));

        // Setup mock mark in hook
        mockHook.setMockMark(
            MOCK_MARK_ID,
            MarkTypes.ExposureMark({
                poolId: PoolId.wrap(bytes32(0)),
                tickAtMark: 0,
                creationBlock: 100,
                resolutionBlock: 0,
                swapAmountSpecified: 1 ether,
                zeroForOne: true,
                status: MarkTypes.MarkStatus.Open,
                swapper: ALICE,
                nonce: 1,
                sqrtPriceAtMark: 1e18,
                exposureMagnitude: 50000
            })
        );
    }

    // Test proof request creation
    function test_RequestProofForMark() public {
        vm.prank(ALICE);
        bytes32 requestId = verifier.requestProofForMark(MOCK_MARK_ID);

        assertNotEq(requestId, bytes32(0), "Request ID should not be zero");
        assertEq(verifier.markToRequest(MOCK_MARK_ID), requestId, "Mark should map to request");
        assertEq(verifier.requestToMark(requestId), MOCK_MARK_ID, "Request should map to mark");
    }

    // Test proof verification callback with confirmed outcome
    function test_HandleProofResult_Confirmed() public {
        // Request proof
        vm.prank(ALICE);
        bytes32 requestId = verifier.requestProofForMark(MOCK_MARK_ID);

        // Simulate Brevis callback with proof that price rose (should confirm for zeroForOne)
        int256 priceChangeBps = 100; // 1% increase (> 50 bps threshold)
        bytes memory output = abi.encode(MOCK_MARK_ID, priceChangeBps, uint160(1e18), uint160(1.01e18));

        vm.expectEmit(true, true, false, true);
        emit BrevisMarkVerifier.ProofVerified(requestId, MOCK_MARK_ID, true, 100);

        vm.prank(address(mockBrevis));
        verifier.handleProofResult(requestId, output);
    }
}

// Mock Brevis proof contract
contract MockBrevisProof {
    function verifyProof(IBrevisProof.ProofData calldata, bytes calldata) external pure returns (bool) {
        return true;
    }
}

// Mock RemembraMark hook
contract MockRemembraMark is IRemembraMark {
    mapping(bytes32 => MarkTypes.ExposureMark) private marks;

    function setMockMark(bytes32 markId, MarkTypes.ExposureMark memory mark) external {
        marks[markId] = mark;
    }

    function getMark(bytes32 markId) external view override returns (MarkTypes.ExposureMark memory) {
        return marks[markId];
    }

    function markExists(bytes32) external pure override returns (bool) {
        return true;
    }

    function getMarkStatus(bytes32) external pure override returns (MarkTypes.MarkStatus) {
        return MarkTypes.MarkStatus.Open;
    }

    function canResolveMark(bytes32) external pure override returns (bool) {
        return true;
    }

    function computeMarkId(PoolId, address, int24, uint256) external pure override returns (bytes32) {
        return bytes32(0);
    }
}
