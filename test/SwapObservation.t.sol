// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseTest} from "./utils/BaseTest.sol";
import {RemembraMarkHook} from "../src/RemembraMarkHook.sol";
import {Vm} from "forge-std/Vm.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {EasyPosm} from "./utils/libraries/EasyPosm.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

// Tests the hook's swap observation capabilities.
// Verifies that swaps are properly observed and events are emitted.
contract SwapObservationTest is BaseTest {
    using PoolIdLibrary for PoolKey;
    using EasyPosm for IPositionManager;
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;

    RemembraMarkHook hook;
    PoolKey poolKey;
    PoolId poolId;
    PoolSwapTest swapTest;

    function setUp() public {
        deployArtifactsAndLabel();
        (Currency currency0, Currency currency1) = deployCurrencyPair();

        // Deploy hook with both BEFORE_SWAP and AFTER_SWAP permissions using HookMiner
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);
        bytes memory constructorArgs = abi.encode(poolManager);
        (address hookAddress, bytes32 salt) =
            HookMiner.find(address(this), flags, type(RemembraMarkHook).creationCode, constructorArgs);

        hook = new RemembraMarkHook{salt: salt}(poolManager);
        require(address(hook) == hookAddress, "Hook address mismatch");

        // Initialize pool
        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        poolManager.initialize(poolKey, 79228162514264337593543950336); // 1:1 price
        poolId = poolKey.toId();

        // Add liquidity to enable swaps
        positionManager.mint(
            poolKey,
            -600, // tickLower
            600, // tickUpper
            10 ether, // liquidity
            10 ether, // amount0Max
            10 ether, // amount1Max
            address(this), // recipient
            block.timestamp, // deadline
            "" // hookData
        );

        // Deploy swap test router
        swapTest = new PoolSwapTest(poolManager);

        // Approve swap router to spend tokens
        IERC20(Currency.unwrap(currency0)).approve(address(swapTest), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(swapTest), type(uint256).max);

        vm.label(address(hook), "RemembraMarkHook");
        vm.label(address(swapTest), "SwapRouter");
    }

    // Swap executes through hook and emits SwapObserved event
    // Property: Hook observes swaps without blocking them
    function testSwapExecutesThroughHook() public {
        (, int24 tickBefore,,) = poolManager.getSlot0(poolId);

        vm.recordLogs();

        // Perform a small swap with valid price limit
        // For zeroForOne, price moves down, so limit must be < current price
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -100, // exact input of 100 token0
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1 // price can go down to MIN + 1
        });

        BalanceDelta delta =
            swapTest.swap(poolKey, params, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), "");

        // Verify swap executed (delta is non-zero)
        assertTrue(delta.amount0() != 0 || delta.amount1() != 0, "Swap did not execute");

        // Verify tick moved (swap had impact)
        (, int24 tickAfter,,) = poolManager.getSlot0(poolId);
        assertTrue(tickAfter != tickBefore, "Tick did not change");

        // Check that SwapObserved event was emitted
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool foundSwapObserved = false;

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("SwapObserved(bytes32,address,int24,int24,int256,bool)")) {
                foundSwapObserved = true;

                // Verify event has poolId in topic[1]
                assertEq(logs[i].topics[1], bytes32(PoolId.unwrap(poolId)));
                break;
            }
        }

        assertTrue(foundSwapObserved, "SwapObserved event not emitted");
    }

    // Hook does not create marks because materiality check returns false
    // Property: Observation does not create marks without materiality
    function testSwapDoesNotCreateMarksWithoutMateriality() public {
        vm.recordLogs();

        // For !zeroForOne, price moves up, so limit must be > current price
        SwapParams memory params = SwapParams({
            zeroForOne: false,
            amountSpecified: -50, // exact input of 50 token1
            sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1 // price can go up to MAX - 1
        });

        swapTest.swap(poolKey, params, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), "");

        // Check that ExposureMarked event was NOT emitted
        Vm.Log[] memory logs = vm.getRecordedLogs();

        for (uint256 i = 0; i < logs.length; i++) {
            assertFalse(
                logs[i].topics[0]
                    == keccak256("ExposureMarked(bytes32,bytes32,address,int24,int256,bool,uint256,uint256)"),
                "ExposureMarked event should not be emitted without materiality"
            );
        }
    }
}
