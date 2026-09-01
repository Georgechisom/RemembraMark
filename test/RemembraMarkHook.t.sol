// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseTest} from "./utils/BaseTest.sol";
import {RemembraMarkHook} from "../src/RemembraMarkHook.sol";
import {ExposureLedger} from "../src/ExposureLedger.sol";
import {MarkTypes} from "../src/libraries/MarkTypes.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

// Tests the RemembraMarkHook's core integration with Uniswap v4.
// Verifies hook permissions, deployment, and swap observation behavior.
contract RemembraMarkHookTest is BaseTest {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    RemembraMarkHook hook;
    PoolKey poolKey;
    PoolId poolId;

    function setUp() public {
        deployArtifactsAndLabel();
        (Currency currency0, Currency currency1) = deployCurrencyPair();

        // Deploy hook with correct permissions encoded in address using HookMiner
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);
        bytes memory constructorArgs = abi.encode(poolManager);
        (address hookAddress, bytes32 salt) =
            HookMiner.find(address(this), flags, type(RemembraMarkHook).creationCode, constructorArgs);

        hook = new RemembraMarkHook{salt: salt}(poolManager);
        require(address(hook) == hookAddress, "Hook address mismatch");

        // Initialize pool with the hook
        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        poolManager.initialize(poolKey, 79228162514264337593543950336); // sqrtPriceX96 = 1:1
        poolId = poolKey.toId();

        vm.label(address(hook), "RemembraMarkHook");
    }

    // Hook should deploy successfully and return correct permissions
    function testHookPermissions() public view {
        Hooks.Permissions memory perms = hook.getHookPermissions();

        assertFalse(perms.beforeInitialize);
        assertFalse(perms.afterInitialize);
        assertFalse(perms.beforeAddLiquidity);
        assertFalse(perms.afterAddLiquidity);
        assertFalse(perms.beforeRemoveLiquidity);
        assertFalse(perms.afterRemoveLiquidity);
        assertTrue(perms.beforeSwap);
        assertTrue(perms.afterSwap);
        assertFalse(perms.beforeDonate);
        assertFalse(perms.afterDonate);
    }

    // Pool should initialize successfully with hook attached
    function testPoolInitializesWithHook() public view {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        assertGt(sqrtPriceX96, 0);
    }

    // computeMarkId should be deterministic for same inputs
    function testComputeMarkIdIsDeterministic() public view {
        bytes32 id1 = hook.computeMarkId(poolId, address(this), 100, 1000);
        bytes32 id2 = hook.computeMarkId(poolId, address(this), 100, 1000);

        assertEq(id1, id2);
    }

    // Different inputs should produce different mark IDs
    function testComputeMarkIdDifferentInputs() public view {
        bytes32 id1 = hook.computeMarkId(poolId, address(this), 100, 1000);
        bytes32 id2 = hook.computeMarkId(poolId, address(this), 101, 1000);
        bytes32 id3 = hook.computeMarkId(poolId, address(0x1), 100, 1000);

        assertTrue(id1 != id2);
        assertTrue(id1 != id3);
        assertTrue(id2 != id3);
    }

    // External resolveMark call should fail when mark not eligible
    // (canResolveMark always returns false in current implementation)
    function testCannotResolveWhenNotEligible() public {
        bytes32 fakeMarkId = keccak256("nonexistent");

        vm.expectRevert(abi.encodeWithSelector(ExposureLedger.MarkNotEligibleForResolution.selector, fakeMarkId));
        hook.resolveMark(fakeMarkId, true);
    }
}
