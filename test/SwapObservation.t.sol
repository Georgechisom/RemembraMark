// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseTest} from "./utils/BaseTest.sol";
import {RemembraMarkHook} from "../src/RemembraMarkHook.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

// Tests the hook's swap observation capabilities.
// Verifies that swaps are properly observed and events are emitted.
contract SwapObservationTest is BaseTest {
    using PoolIdLibrary for PoolKey;

    RemembraMarkHook hook;
    PoolKey poolKey;
    PoolId poolId;
    PoolSwapTest swapRouter;

    function setUp() public {
        deployArtifactsAndLabel();
        (Currency currency0, Currency currency1) = deployCurrencyPair();

        // Deploy hook with correct permissions
        uint160 permissions = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);

        address hookAddress = address(permissions);

        hook = new RemembraMarkHook(poolManager);
        _etch(hookAddress, address(hook).code);
        hook = RemembraMarkHook(hookAddress);

        // Initialize pool
        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        poolManager.initialize(poolKey, 79228162514264337593543950336);
        poolId = poolKey.toId();

        // Deploy swap test router
        swapRouter = new PoolSwapTest(poolManager);

        vm.label(address(hook), "RemembraMarkHook");
        vm.label(address(swapRouter), "SwapRouter");
    }

    // SwapObserved event should be emitted on swap
    // Notes: Current implementation emits event but does not create marks
    function testEmitsSwapObservedEvent() public {
        // We expect the SwapObserved event but NOT ExposureMarked
        // (because _assessMateriality returns false)
        vm.recordLogs();

        // Perform a small swap
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -100, // exact input
            sqrtPriceLimitX96: 0
        });

        swapRouter.swap(poolKey, params, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), "");

        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Should have SwapObserved event
        bool foundSwapObserved = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("SwapObserved(bytes32,address,int24,int24,int256,bool)")) {
                foundSwapObserved = true;
                break;
            }
        }

        assertTrue(foundSwapObserved, "SwapObserved event not found");
    }

    // Hook should not create marks (materiality check returns false)
    function testDoesNotCreateMarksWithoutMateriality() public {
        vm.recordLogs();

        IPoolManager.SwapParams memory params =
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: -100, sqrtPriceLimitX96: 0});

        swapRouter.swap(poolKey, params, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), "");

        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Should NOT have ExposureMarked event
        bool foundExposureMarked = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (
                logs[i].topics[0]
                    == keccak256("ExposureMarked(bytes32,bytes32,address,int24,int256,bool,uint256,uint256)")
            ) {
                foundExposureMarked = true;
                break;
            }
        }

        assertFalse(foundExposureMarked, "Unexpected ExposureMarked event");
    }

    // Hook should observe swaps in both directions
    function testObservesBothSwapDirections() public {
        // Swap token0 for token1
        vm.recordLogs();

        IPoolManager.SwapParams memory params1 =
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: -100, sqrtPriceLimitX96: 0});

        swapRouter.swap(poolKey, params1, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), "");

        Vm.Log[] memory logs1 = vm.getRecordedLogs();
        bool foundSwap1 = false;
        for (uint256 i = 0; i < logs1.length; i++) {
            if (logs1[i].topics[0] == keccak256("SwapObserved(bytes32,address,int24,int24,int256,bool)")) {
                foundSwap1 = true;
                break;
            }
        }
        assertTrue(foundSwap1);

        // Swap token1 for token0
        vm.recordLogs();

        IPoolManager.SwapParams memory params2 =
            IPoolManager.SwapParams({zeroForOne: false, amountSpecified: -100, sqrtPriceLimitX96: type(uint160).max});

        swapRouter.swap(poolKey, params2, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), "");

        Vm.Log[] memory logs2 = vm.getRecordedLogs();
        bool foundSwap2 = false;
        for (uint256 i = 0; i < logs2.length; i++) {
            if (logs2[i].topics[0] == keccak256("SwapObserved(bytes32,address,int24,int24,int256,bool)")) {
                foundSwap2 = true;
                break;
            }
        }
        assertTrue(foundSwap2);
    }
}
