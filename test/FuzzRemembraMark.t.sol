// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ExposureLedger} from "../src/ExposureLedger.sol";
import {MarkTypes} from "../src/libraries/MarkTypes.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

// Test ledger implementation for fuzz testing
contract FuzzTestLedger is ExposureLedger {
    function canResolveMark(bytes32) public pure override returns (bool) {
        return false;
    }

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

    function confirmMarkForTesting(bytes32 markId) external {
        confirmMark(markId);
    }

    function clearMarkForTesting(bytes32 markId) external {
        clearMark(markId);
    }
}

// Fuzz tests for RemembraMark protocol invariants.
// Verifies key properties hold under arbitrary valid inputs.
contract FuzzRemembraMarkTest is Test {
    FuzzTestLedger ledger;

    function setUp() public {
        ledger = new FuzzTestLedger();
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
        uint160 testSqrtPrice = 79228162514264337593543950336;
        uint256 testExposure = 15000;

        bytes32[] memory markIds = new bytes32[](count);

        // Create multiple marks with same parameters
        for (uint256 i = 0; i < count; i++) {
            markIds[i] = ledger.createMarkForTesting(poolId, swapper, tick, amount, direction, testSqrtPrice, testExposure);
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
        uint160 testSqrtPrice = 79228162514264337593543950336;
        uint256 testExposure = 15000;

        bytes32 markId = ledger.createMarkForTesting(poolId, swapper, tick, amount, direction, testSqrtPrice, testExposure);
        ledger.confirmMarkForTesting(markId);

        // Verify status is Confirmed
        assertEq(uint8(ledger.getMarkStatus(markId)), uint8(MarkTypes.MarkStatus.Confirmed));

        // Attempt to clear should revert (no status reversal)
        vm.expectRevert();
        ledger.clearMarkForTesting(markId);

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
        uint160 testSqrtPrice = 79228162514264337593543950336;
        uint256 testExposure = 15000;

        bytes32 markId = ledger.createMarkForTesting(poolId, swapper, tick, amount, direction, testSqrtPrice, testExposure);
        ledger.clearMarkForTesting(markId);

        // Verify status is Cleared
        assertEq(uint8(ledger.getMarkStatus(markId)), uint8(MarkTypes.MarkStatus.Cleared));

        // Attempt to confirm should revert (no status reversal)
        vm.expectRevert();
        ledger.confirmMarkForTesting(markId);

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
        uint160 testSqrtPrice = 79228162514264337593543950336;
        uint256 testExposure = 15000;

        uint256 blockBefore = block.number;
        bytes32 markId = ledger.createMarkForTesting(poolId, swapper, tick, amount, direction, testSqrtPrice, testExposure);

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
        uint160 testSqrtPrice = 79228162514264337593543950336;
        uint256 testExposure = 15000;

        bytes32 markId = ledger.createMarkForTesting(poolId, swapper, tick, amount, direction, testSqrtPrice, testExposure);

        // Advance block
        vm.roll(block.number + 10);
        uint256 resolutionBlock = block.number;

        if (confirmOrClear) {
            ledger.confirmMarkForTesting(markId);
        } else {
            ledger.clearMarkForTesting(markId);
        }

        MarkTypes.ExposureMark memory mark = ledger.getMark(markId);

        // Resolution block should be set
        assertEq(mark.resolutionBlock, resolutionBlock);
        assertGt(mark.resolutionBlock, mark.creationBlock);
    }
}
