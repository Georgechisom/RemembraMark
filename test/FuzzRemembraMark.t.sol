// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ExposureLedger} from "../src/ExposureLedger.sol";
import {MarkTypes} from "../src/libraries/MarkTypes.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

// Test ledger implementation
contract TestLedger is ExposureLedger {
    function testCreateMark(
        PoolId poolId,
        address swapper,
        int24 tickAtMark,
        int256 swapAmountSpecified,
        bool zeroForOne
    ) external returns (bytes32) {
        return createMark(poolId, swapper, tickAtMark, swapAmountSpecified, zeroForOne);
    }

    function testConfirmMark(bytes32 markId) external {
        confirmMark(markId);
    }

    function testClearMark(bytes32 markId) external {
        clearMark(markId);
    }
}

// Fuzz tests for RemembraMark protocol invariants.
// Verifies key properties hold under arbitrary valid inputs.
contract FuzzRemembraMarkTest is Test {
    TestLedger ledger;

    function setUp() public {
        ledger = new TestLedger();
    }

    // Property: Mark IDs are always unique via nonce increment
    // Even with identical pool/swapper/tick/block, different marks get different IDs
    function testFuzz_MarkIdsAlwaysUnique(
        bytes32 poolIdRaw,
        address swapper,
        int24 tick,
        int256 amount,
        bool direction,
        uint8 count
    ) public {
        // Bound count to reasonable range (1-20 marks)
        count = uint8(bound(count, 1, 20));

        PoolId poolId = PoolId.wrap(poolIdRaw);

        bytes32[] memory markIds = new bytes32[](count);

        // Create multiple marks with same parameters
        for (uint256 i = 0; i < count; i++) {
            markIds[i] = ledger.testCreateMark(poolId, swapper, tick, amount, direction);
        }

        // Verify all IDs are unique
        for (uint256 i = 0; i < count; i++) {
            for (uint256 j = i + 1; j < count; j++) {
                assertTrue(markIds[i] != markIds[j], "Mark ID collision detected");
            }
        }
    }

    // Property: Confirmed marks cannot transition back to Open
    function testFuzz_ConfirmedMarksStayConfirmed(
        bytes32 poolIdRaw,
        address swapper,
        int24 tick,
        int256 amount,
        bool direction
    ) public {
        PoolId poolId = PoolId.wrap(poolIdRaw);

        bytes32 markId = ledger.testCreateMark(poolId, swapper, tick, amount, direction);
        ledger.testConfirmMark(markId);

        // Verify status is Confirmed
        assertEq(uint8(ledger.getMarkStatus(markId)), uint8(MarkTypes.MarkStatus.Confirmed));

        // Attempt to clear should revert (no status reversal)
        vm.expectRevert();
        ledger.testClearMark(markId);

        // Status should still be Confirmed
        assertEq(uint8(ledger.getMarkStatus(markId)), uint8(MarkTypes.MarkStatus.Confirmed));
    }

    // Property: Cleared marks cannot transition back to Open
    function testFuzz_ClearedMarksStayCleared(
        bytes32 poolIdRaw,
        address swapper,
        int24 tick,
        int256 amount,
        bool direction
    ) public {
        PoolId poolId = PoolId.wrap(poolIdRaw);

        bytes32 markId = ledger.testCreateMark(poolId, swapper, tick, amount, direction);
        ledger.testClearMark(markId);

        // Verify status is Cleared
        assertEq(uint8(ledger.getMarkStatus(markId)), uint8(MarkTypes.MarkStatus.Cleared));

        // Attempt to confirm should revert (no status reversal)
        vm.expectRevert();
        ledger.testConfirmMark(markId);

        // Status should still be Cleared
        assertEq(uint8(ledger.getMarkStatus(markId)), uint8(MarkTypes.MarkStatus.Cleared));
    }

    // Property: Marks always have valid creation block
    function testFuzz_MarksHaveValidCreationBlock(
        bytes32 poolIdRaw,
        address swapper,
        int24 tick,
        int256 amount,
        bool direction
    ) public {
        PoolId poolId = PoolId.wrap(poolIdRaw);

        uint256 blockBefore = block.number;
        bytes32 markId = ledger.testCreateMark(poolId, swapper, tick, amount, direction);

        MarkTypes.ExposureMark memory mark = ledger.getMark(markId);

        // Creation block should be the block it was created in
        assertEq(mark.creationBlock, blockBefore);
        assertGt(mark.creationBlock, 0);

        // Resolution block should be 0 for Open marks
        assertEq(mark.resolutionBlock, 0);
    }

    // Property: Resolution block set correctly on mark resolution
    function testFuzz_ResolutionBlockSetCorrectly(
        bytes32 poolIdRaw,
        address swapper,
        int24 tick,
        int256 amount,
        bool direction,
        bool confirmOrClear
    ) public {
        PoolId poolId = PoolId.wrap(poolIdRaw);

        bytes32 markId = ledger.testCreateMark(poolId, swapper, tick, amount, direction);

        // Advance block
        vm.roll(block.number + 10);
        uint256 resolutionBlock = block.number;

        if (confirmOrClear) {
            ledger.testConfirmMark(markId);
        } else {
            ledger.testClearMark(markId);
        }

        MarkTypes.ExposureMark memory mark = ledger.getMark(markId);

        // Resolution block should be set
        assertEq(mark.resolutionBlock, resolutionBlock);
        assertGt(mark.resolutionBlock, mark.creationBlock);
    }
}
