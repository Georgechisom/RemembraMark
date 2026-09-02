// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ReactiveMarkResolver} from "../../src/integrations/ReactiveMarkResolver.sol";
import {IRemembraMark} from "../../src/interfaces/IRemembraMark.sol";
import {MarkTypes} from "../../src/libraries/MarkTypes.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

// ReactiveResolver Tests
// Tests for ReactiveMarkResolver automation integration
contract ReactiveResolverTest is Test {
    ReactiveMarkResolver public resolver;
    MockRemembraMark public mockHook;

    uint256 public constant CHAIN_ID = 11155111; // Sepolia
    address public constant ALICE = address(0xA11CE);
    bytes32 public constant MOCK_MARK_ID = keccak256("mock_mark_id");

    function setUp() public {
        mockHook = new MockRemembraMark();
        resolver = new ReactiveMarkResolver(CHAIN_ID, address(mockHook));
    }

    // Test manual mark registration
    function test_ManualRegisterMark() public {
        uint256 creationBlock = 100;

        vm.expectEmit(true, false, false, true);
        emit ReactiveMarkResolver.MarkRegistered(MOCK_MARK_ID, creationBlock, creationBlock + 25);

        resolver.manualRegisterMark(MOCK_MARK_ID, creationBlock);

        assertEq(resolver.markCreationBlocks(MOCK_MARK_ID), creationBlock, "Creation block should be stored");
        assertFalse(resolver.resolutionTriggered(MOCK_MARK_ID), "Resolution should not be triggered yet");
    }

    // Test resolution triggering after observation window
    function test_CheckAndTriggerResolution() public {
        uint256 creationBlock = 100;
        uint256 observationWindow = 25;

        // Register mark
        resolver.manualRegisterMark(MOCK_MARK_ID, creationBlock);

        // Check not ready before window
        assertFalse(
            resolver.isReadyForResolution(MOCK_MARK_ID, creationBlock + 24), "Should not be ready before window"
        );

        // Check ready after window
        assertTrue(
            resolver.isReadyForResolution(MOCK_MARK_ID, creationBlock + observationWindow),
            "Should be ready after window"
        );

        // Trigger resolution
        vm.expectEmit(true, false, false, true);
        emit ReactiveMarkResolver.ResolutionTriggered(MOCK_MARK_ID, creationBlock + observationWindow);

        resolver.checkAndTriggerResolution(MOCK_MARK_ID, creationBlock + observationWindow);

        assertTrue(resolver.resolutionTriggered(MOCK_MARK_ID), "Resolution should be triggered");

        // Check not ready after trigger
        assertFalse(
            resolver.isReadyForResolution(MOCK_MARK_ID, creationBlock + observationWindow + 100),
            "Should not be ready after trigger"
        );
    }
}

// Mock RemembraMark hook
contract MockRemembraMark is IRemembraMark {
    function getMark(bytes32) external pure override returns (MarkTypes.ExposureMark memory) {
        return MarkTypes.ExposureMark({
            poolId: PoolId.wrap(bytes32(0)),
            tickAtMark: 0,
            creationBlock: 100,
            resolutionBlock: 0,
            swapAmountSpecified: 1 ether,
            zeroForOne: true,
            status: MarkTypes.MarkStatus.Open,
            swapper: address(0),
            nonce: 1,
            sqrtPriceAtMark: 1e18,
            exposureMagnitude: 50000
        });
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
