// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ExposureLedger} from "../src/ExposureLedger.sol";
import {MarkTypes} from "../src/libraries/MarkTypes.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

// Concrete implementation for testing ExposureLedger
contract ExposureLedgerForTesting is ExposureLedger {
    // Implement required abstract function
    function canResolveMark(bytes32) public pure override returns (bool) {
        return false; // Simple implementation for testing
    }

    // Expose internal functions for testing
    function createMarkForTesting(
        PoolId poolId,
        address swapper,
        int24 tickAtMark,
        int256 swapAmountSpecified,
        bool zeroForOne,
        uint160 sqrtPriceAtMark,
        uint256 exposureMagnitude
    ) external returns (bytes32) {
        return createMark(poolId, swapper, tickAtMark, swapAmountSpecified, zeroForOne, sqrtPriceAtMark, exposureMagnitude);
    }
}

// Tests the ExposureLedger's mark storage and lifecycle management.
// Verifies mark creation, state transitions, and validation logic.
contract ExposureLedgerTest is Test {
    ExposureLedgerForTesting ledger;
    PoolId testPoolId;
    address testSwapper;

    function setUp() public {
        ledger = new ExposureLedgerForTesting();
        testPoolId = PoolId.wrap(keccak256("test-pool"));
        testSwapper = address(0x1234);
    }

    // Should create mark with correct initial state
    function testCreatesMarkWithCorrectState() public {
        uint160 testSqrtPrice = 79228162514264337593543950336; // 1:1 price
        uint256 testExposure = 15000; // 1.5% exposure
        
        bytes32 markId = ledger.createMarkForTesting(
            testPoolId, testSwapper, 100, 1000, true, testSqrtPrice, testExposure
        );

        MarkTypes.ExposureMark memory mark = ledger.getMark(markId);
        assertEq(PoolId.unwrap(mark.poolId), PoolId.unwrap(testPoolId));
        assertEq(mark.tickAtMark, 100);
        assertEq(mark.creationBlock, block.number);
        assertEq(mark.resolutionBlock, 0);
        assertEq(mark.swapAmountSpecified, 1000);
        assertTrue(mark.zeroForOne);
        assertEq(uint8(mark.status), uint8(MarkTypes.MarkStatus.Open));
        assertEq(mark.swapper, testSwapper);
        assertEq(mark.nonce, 0); // First mark has nonce 0
        assertEq(mark.sqrtPriceAtMark, testSqrtPrice);
        assertEq(mark.exposureMagnitude, testExposure);
    }

    // Should emit ExposureMarked event with correct values on creation
    function testEmitsExposureMarkedEvent() public {
        uint160 testSqrtPrice = 79228162514264337593543950336;
        uint256 testExposure = 15000;
        
        // Compute the expected markId
        bytes32 expectedMarkId = MarkTypes.computeMarkId(testPoolId, testSwapper, 100, block.number, 0);

        vm.expectEmit(true, true, true, true);
        emit ExposureLedger.ExposureMarked(
            expectedMarkId, testPoolId, testSwapper, 100, 1000, true, block.number, 0, testSqrtPrice, testExposure
        );

        bytes32 actualMarkId = ledger.createMarkForTesting(
            testPoolId, testSwapper, 100, 1000, true, testSqrtPrice, testExposure
        );

        assertEq(actualMarkId, expectedMarkId, "Mark ID mismatch");
    }

    // Multiple marks should have unique IDs via nonce
    function testCreatesUniqueMarkIds() public {
        uint160 testSqrtPrice = 79228162514264337593543950336;
        uint256 testExposure = 15000;
        
        // Same parameters in same block should get different IDs via nonce
        bytes32 markId1 = ledger.createMarkForTesting(
            testPoolId, testSwapper, 100, 1000, true, testSqrtPrice, testExposure
        );
        bytes32 markId2 = ledger.createMarkForTesting(
            testPoolId, testSwapper, 100, 1000, true, testSqrtPrice, testExposure
        );

        assertTrue(markId1 != markId2);

        MarkTypes.ExposureMark memory mark1 = ledger.getMark(markId1);
        MarkTypes.ExposureMark memory mark2 = ledger.getMark(markId2);

        assertEq(mark1.nonce, 0);
        assertEq(mark2.nonce, 1);
    }

    // markExists should return true for created marks
    function testMarkExistsReturnsTrueForCreatedMark() public {
        uint160 testSqrtPrice = 79228162514264337593543950336;
        uint256 testExposure = 15000;
        
        bytes32 markId = ledger.createMarkForTesting(
            testPoolId, testSwapper, 100, 1000, true, testSqrtPrice, testExposure
        );
        assertTrue(ledger.markExists(markId));
    }

    // markExists should return false for nonexistent marks
    function testMarkExistsReturnsFalseForNonexistent() public view {
        bytes32 fakeId = keccak256("fake");
        assertFalse(ledger.markExists(fakeId));
    }

    // getMark should revert for nonexistent marks
    function testGetMarkRevertsForNonexistent() public {
        bytes32 fakeId = keccak256("fake");

        vm.expectRevert(abi.encodeWithSelector(ExposureLedger.MarkNotFound.selector, fakeId));
        ledger.getMark(fakeId);
    }

    // getMarkStatus should revert for nonexistent marks
    function testGetMarkStatusRevertsForNonexistent() public {
        bytes32 fakeId = keccak256("fake");

        vm.expectRevert(abi.encodeWithSelector(ExposureLedger.MarkNotFound.selector, fakeId));
        ledger.getMarkStatus(fakeId);
    }
}
