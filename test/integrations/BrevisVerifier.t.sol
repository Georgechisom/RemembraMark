// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {BrevisMarkVerifier} from "../../src/integrations/BrevisMarkVerifier.sol";
import {IRemembraMark} from "../../src/interfaces/IRemembraMark.sol";
import {MarkTypes} from "../../src/libraries/MarkTypes.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

// BrevisVerifierTest
// Tests for real Brevis ZK coprocessor integration
// Verified against brevis-sdk commit ab14482
 
// Pattern: BrevisApp.brevisCallback(bytes32 _appVkHash, bytes calldata _appCircuitOutput)
// NOT: handleBrevisCallback(bytes32 _requestId, ...)

contract BrevisVerifierTest is Test {
    BrevisMarkVerifier public verifier;
    MockRemembraMark public mockHook;
    address public mockBrevisRequest;

    bytes32 public constant CIRCUIT_VK_HASH = bytes32(uint256(0x1234)); // Placeholder vkHash
    bytes32 public constant MOCK_MARK_ID = keccak256("mock_mark_id");
    address public constant ALICE = address(0xA11CE);

    function setUp() public {
        mockBrevisRequest = address(0xBEEF);
        mockHook = new MockRemembraMark();
        
        verifier = new BrevisMarkVerifier(
            mockBrevisRequest,
            address(mockHook),
            CIRCUIT_VK_HASH
        );

        // Setup mock mark
        mockHook.setMockMark(
            MOCK_MARK_ID,
            MarkTypes.ExposureMark({
                poolId: PoolId.wrap(bytes32(uint256(0x1))),
                tickAtMark: 0,
                creationBlock: 100,
                resolutionBlock: 0,
                swapAmountSpecified: 1 ether,
                zeroForOne: true,  // Sold token0
                status: MarkTypes.MarkStatus.Open,
                swapper: ALICE,
                nonce: 1,
                sqrtPriceAtMark: 1e18,
                exposureMagnitude: 50000
            })
        );
    }

    function test_BrevisCallbackConfirmed() public {
        int256 priceMovementBps = 100;
        uint160 sqrtPriceStart = uint160(1e18);
        uint160 sqrtPriceEnd = uint160(1.005e18);

        bytes memory circuitOutput = abi.encode(
            MOCK_MARK_ID,
            priceMovementBps,
            sqrtPriceStart,
            sqrtPriceEnd
        );

        vm.expectEmit(true, false, false, true);
        emit BrevisMarkVerifier.ProofVerified(MOCK_MARK_ID, priceMovementBps, true);

        vm.prank(mockBrevisRequest);
        verifier.brevisCallback(CIRCUIT_VK_HASH, circuitOutput);

        (bool verified, int256 storedMovement, bool meetsThreshold) = verifier.getVerificationResult(MOCK_MARK_ID);
        assertTrue(verified);
        assertEq(storedMovement, priceMovementBps);
        assertTrue(meetsThreshold);
    }

    function test_BrevisCallbackCleared() public {
        int256 priceMovementBps = 30;
        bytes memory circuitOutput = abi.encode(
            MOCK_MARK_ID,
            priceMovementBps,
            uint160(1e18),
            uint160(1.003e18)
        );

        vm.expectEmit(true, false, false, true);
        emit BrevisMarkVerifier.ProofVerified(MOCK_MARK_ID, priceMovementBps, false);

        vm.prank(mockBrevisRequest);
        verifier.brevisCallback(CIRCUIT_VK_HASH, circuitOutput);

        (bool verified, int256 storedMovement, bool meetsThreshold) = verifier.getVerificationResult(MOCK_MARK_ID);
        assertTrue(verified);
        assertEq(storedMovement, priceMovementBps);
        assertFalse(meetsThreshold);
    }

    function test_RevertUnauthorizedCallback() public {
        bytes memory circuitOutput = abi.encode(MOCK_MARK_ID, int256(100), uint160(1e18), uint160(1.005e18));

        vm.prank(ALICE);
        vm.expectRevert(BrevisMarkVerifier.UnauthorizedCaller.selector);
        verifier.brevisCallback(CIRCUIT_VK_HASH, circuitOutput);
    }

    function test_RevertInvalidVkHash() public {
        bytes32 wrongVkHash = bytes32(uint256(0x5678));
        bytes memory circuitOutput = abi.encode(MOCK_MARK_ID, int256(100), uint160(1e18), uint160(1.005e18));

        vm.prank(mockBrevisRequest);
        vm.expectRevert(BrevisMarkVerifier.InvalidVkHash.selector);
        verifier.brevisCallback(wrongVkHash, circuitOutput);
    }

    function test_RevertAlreadyVerified() public {
        bytes memory circuitOutput = abi.encode(MOCK_MARK_ID, int256(100), uint160(1e18), uint160(1.005e18));

        vm.prank(mockBrevisRequest);
        verifier.brevisCallback(CIRCUIT_VK_HASH, circuitOutput);

        vm.prank(mockBrevisRequest);
        vm.expectRevert(BrevisMarkVerifier.MarkAlreadyVerified.selector);
        verifier.brevisCallback(CIRCUIT_VK_HASH, circuitOutput);
    }
}

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
