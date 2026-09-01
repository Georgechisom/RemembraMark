// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ExposureLedger} from "../src/ExposureLedger.sol";
import {MarkTypes} from "../src/libraries/MarkTypes.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

// Concrete implementation for testing ExposureLedger
contract ExposureLedgerForTesting is ExposureLedger {
    // Expose internal functions for testing
    function createMarkForTesting(
        PoolId poolId,
        address swapper,
        int24 tickAtMark,
        int256 swapAmountSpecified,
        bool zeroForOne
    ) external returns (bytes32) {
        return createMark(poolId, swapper, tickAtMark, swapAmountSpecified, zeroForOne);
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
        bytes32 markId = ledger.createMarkForTesting(testPoolId, testSwapper, 100, 1000, true);

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
    }

    // Should emit ExposureMarked event with correct values on creation
    function testEmitsExposureMarkedEvent() public {
        // Compute the expected markId
        bytes32 expectedMarkId = MarkTypes.computeMarkId(testPoolId, testSwapper, 100, block.number, 0);

        vm.expectEmit(true, true, true, true);
        emit ExposureLedger.ExposureMarked(expectedMarkId, testPoolId, testSwapper, 100, 1000, true, block.number, 0);

        bytes32 actualMarkId = ledger.createMarkForTesting(testPoolId, testSwapper, 100, 1000, true);

        assertEq(actualMarkId, expectedMarkId, "Mark ID mismatch");
    }

    // Multiple marks should have unique IDs via nonce
    function testCreatesUniqueMarkIds() public {
        // Same parameters in same block should get different IDs via nonce
        bytes32 markId1 = ledger.createMarkForTesting(testPoolId, testSwapper, 100, 1000, true);
        bytes32 markId2 = ledger.createMarkForTesting(testPoolId, testSwapper, 100, 1000, true);

        assertTrue(markId1 != markId2);

        MarkTypes.ExposureMark memory mark1 = ledger.getMark(markId1);
        MarkTypes.ExposureMark memory mark2 = ledger.getMark(markId2);

        assertEq(mark1.nonce, 0);
        assertEq(mark2.nonce, 1);
    }

    // markExists should return true for created marks
    function testMarkExistsReturnsTrueForCreatedMark() public {
        bytes32 markId = ledger.createMarkForTesting(testPoolId, testSwapper, 100, 1000, true);
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
