// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ExposureLedger} from "../src/ExposureLedger.sol";
import {MarkTypes} from "../src/libraries/MarkTypes.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

// Concrete implementation for testing mark resolution
contract MarkResolutionLedger is ExposureLedger {
    function createMarkForTesting(
        PoolId poolId,
        address swapper,
        int24 tickAtMark,
        int256 swapAmountSpecified,
        bool zeroForOne
    ) external returns (bytes32) {
        return createMark(poolId, swapper, tickAtMark, swapAmountSpecified, zeroForOne);
    }

    function confirmMarkForTesting(bytes32 markId) external {
        confirmMark(markId);
    }

    function clearMarkForTesting(bytes32 markId) external {
        clearMark(markId);
    }
}

// Tests mark resolution and state transition logic.
// Verifies valid and invalid state transitions for exposure marks.
contract MarkResolutionTest is Test {
    MarkResolutionLedger ledger;
    PoolId testPoolId;

    function setUp() public {
        ledger = new MarkResolutionLedger();
        testPoolId = PoolId.wrap(keccak256("test-pool"));
    }

    // Open mark can transition to Confirmed
    function testOpenMarkCanBeConfirmed() public {
        bytes32 markId = ledger.createMarkForTesting(testPoolId, address(0x1), 100, 1000, true);

        // Verify initial state
        assertEq(uint8(ledger.getMarkStatus(markId)), uint8(MarkTypes.MarkStatus.Open));

        // Confirm the mark
        vm.expectEmit(true, true, false, true);
        emit ExposureLedger.MarkResolved(markId, testPoolId, MarkTypes.MarkStatus.Confirmed, block.number);

        ledger.confirmMarkForTesting(markId);

        // Verify final state
        MarkTypes.ExposureMark memory mark = ledger.getMark(markId);
        assertEq(uint8(mark.status), uint8(MarkTypes.MarkStatus.Confirmed));
        assertEq(mark.resolutionBlock, block.number);
    }

    // Open mark can transition to Cleared
    function testOpenMarkCanBeCleared() public {
        bytes32 markId = ledger.createMarkForTesting(testPoolId, address(0x1), 100, 1000, true);

        // Verify initial state
        assertEq(uint8(ledger.getMarkStatus(markId)), uint8(MarkTypes.MarkStatus.Open));

        // Clear the mark
        vm.expectEmit(true, true, false, true);
        emit ExposureLedger.MarkResolved(markId, testPoolId, MarkTypes.MarkStatus.Cleared, block.number);

        ledger.clearMarkForTesting(markId);

        // Verify final state
        MarkTypes.ExposureMark memory mark = ledger.getMark(markId);
        assertEq(uint8(mark.status), uint8(MarkTypes.MarkStatus.Cleared));
        assertEq(mark.resolutionBlock, block.number);
    }

    // Cannot confirm an already confirmed mark
    function testCannotConfirmConfirmedMark() public {
        bytes32 markId = ledger.createMarkForTesting(testPoolId, address(0x1), 100, 1000, true);

        ledger.confirmMarkForTesting(markId);

        // Attempt to confirm again should revert
        vm.expectRevert(abi.encodeWithSelector(ExposureLedger.MarkNotOpen.selector, markId));
        ledger.confirmMarkForTesting(markId);
    }

    // Cannot clear an already cleared mark
    function testCannotClearClearedMark() public {
        bytes32 markId = ledger.createMarkForTesting(testPoolId, address(0x1), 100, 1000, true);

        ledger.clearMarkForTesting(markId);

        // Attempt to clear again should revert
        vm.expectRevert(abi.encodeWithSelector(ExposureLedger.MarkNotOpen.selector, markId));
        ledger.clearMarkForTesting(markId);
    }

    // Cannot clear a confirmed mark (no status reversal)
    function testCannotClearConfirmedMark() public {
        bytes32 markId = ledger.createMarkForTesting(testPoolId, address(0x1), 100, 1000, true);

        ledger.confirmMarkForTesting(markId);

        // Attempt to clear a confirmed mark should revert
        vm.expectRevert(abi.encodeWithSelector(ExposureLedger.MarkNotOpen.selector, markId));
        ledger.clearMarkForTesting(markId);
    }

    // Cannot confirm a cleared mark (no status reversal)
    function testCannotConfirmClearedMark() public {
        bytes32 markId = ledger.createMarkForTesting(testPoolId, address(0x1), 100, 1000, true);

        ledger.clearMarkForTesting(markId);

        // Attempt to confirm a cleared mark should revert
        vm.expectRevert(abi.encodeWithSelector(ExposureLedger.MarkNotOpen.selector, markId));
        ledger.confirmMarkForTesting(markId);
    }

    // Cannot resolve nonexistent mark
    function testCannotResolveNonexistentMark() public {
        bytes32 fakeId = keccak256("fake");

        vm.expectRevert(abi.encodeWithSelector(ExposureLedger.MarkNotFound.selector, fakeId));
        ledger.confirmMarkForTesting(fakeId);
    }

    // canResolveMark returns false for all marks (placeholder implementation)
    function testCanResolveMarkReturnsFalse() public {
        bytes32 markId = ledger.createMarkForTesting(testPoolId, address(0x1), 100, 1000, true);

        // Current implementation always returns false (economic logic not implemented)
        assertFalse(ledger.canResolveMark(markId));
    }
}
