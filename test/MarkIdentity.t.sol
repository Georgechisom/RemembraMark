// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {MarkTypes} from "../src/libraries/MarkTypes.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

// Tests the mark ID generation and uniqueness guarantees.
// Verifies that mark IDs are deterministic and structurally unique.
contract MarkIdentityTest is Test {
    PoolId testPoolId;

    function setUp() public {
        testPoolId = PoolId.wrap(keccak256("test-pool"));
    }

    // Mark ID should be deterministic for identical inputs
    function testMarkIdIsDeterministic() public view {
        bytes32 id1 = MarkTypes.computeMarkId(testPoolId, address(0x1), 100, 1000, 0);
        bytes32 id2 = MarkTypes.computeMarkId(testPoolId, address(0x1), 100, 1000, 0);

        assertEq(id1, id2);
    }

    // Different nonces produce different IDs (critical for uniqueness)
    function testDifferentNonceProducesDifferentId() public view {
        bytes32 id1 = MarkTypes.computeMarkId(testPoolId, address(0x1), 100, 1000, 0);
        bytes32 id2 = MarkTypes.computeMarkId(testPoolId, address(0x1), 100, 1000, 1);

        assertTrue(id1 != id2, "Same nonce produced same ID");
    }

    // Different pools produce different IDs
    function testDifferentPoolProducesDifferentId() public view {
        PoolId pool2 = PoolId.wrap(keccak256("test-pool-2"));

        bytes32 id1 = MarkTypes.computeMarkId(testPoolId, address(0x1), 100, 1000, 0);
        bytes32 id2 = MarkTypes.computeMarkId(pool2, address(0x1), 100, 1000, 0);

        assertTrue(id1 != id2);
    }

    // Different swappers produce different IDs
    function testDifferentSwapperProducesDifferentId() public view {
        bytes32 id1 = MarkTypes.computeMarkId(testPoolId, address(0x1), 100, 1000, 0);
        bytes32 id2 = MarkTypes.computeMarkId(testPoolId, address(0x2), 100, 1000, 0);

        assertTrue(id1 != id2);
    }

    // Different ticks produce different IDs
    function testDifferentTickProducesDifferentId() public view {
        bytes32 id1 = MarkTypes.computeMarkId(testPoolId, address(0x1), 100, 1000, 0);
        bytes32 id2 = MarkTypes.computeMarkId(testPoolId, address(0x1), 101, 1000, 0);

        assertTrue(id1 != id2);
    }

    // Different blocks produce different IDs
    function testDifferentBlockProducesDifferentId() public view {
        bytes32 id1 = MarkTypes.computeMarkId(testPoolId, address(0x1), 100, 1000, 0);
        bytes32 id2 = MarkTypes.computeMarkId(testPoolId, address(0x1), 100, 1001, 0);

        assertTrue(id1 != id2);
    }
}
