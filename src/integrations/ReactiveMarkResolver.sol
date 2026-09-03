// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AbstractReactive} from "@reactive-network/reactive-lib/abstract-base/AbstractReactive.sol";
import {IReactive} from "@reactive-network/reactive-lib/interfaces/IReactive.sol";
import {IRemembraMark} from "../interfaces/IRemembraMark.sol";


 // ReactiveMarkResolver
 // Reactive Network automation for RemembraMark observation window monitoring
 // Implements the official reactive-lib AbstractReactive pattern
 
 // ARCHITECTURE:
 // Deployed on Reactive Network (dual deployment: RNK + ReactVM)
 // Subscribes to ExposureMarked events from RemembraMark on origin chain
 // When observation window elapses, emits Callback to trigger resolution
 // RemembraMark remains the canonical authority for all state transitions
 
 // SECURITY:
 // Non-authoritative: Cannot force Confirmed/Cleared state
 // RemembraMark validates ALL eligibility criteria independently
 // Callback authentication handled by Reactive Network callback proxy
 
contract ReactiveMarkResolver is AbstractReactive {
    // Origin chain ID where RemembraMark is deployed
    uint256 public immutable originChainId;

    // Address of RemembraMark hook on origin chain
    address public immutable remembraMarkHook;

    // Observation window in blocks (matches RemembraMark.OBSERVATION_WINDOW_BLOCKS)
    uint256 public constant OBSERVATION_WINDOW_BLOCKS = 25;

    // ExposureMarked event topic0: keccak256("ExposureMarked(bytes32,bytes32,address,int24,int256,bool,uint256,uint256,uint160,uint256)")
    uint256 private constant EXPOSURE_MARKED_TOPIC = 0x2c0d511f412c7d04214f7530f3d8b79fdbaca88062748d1debb97ee55750e560;

    // Mapping from mark ID to creation block number
    mapping(bytes32 => uint256) public markCreationBlocks;

    // Emitted when a mark is registered for monitoring
    event MarkRegistered(bytes32 indexed markId, uint256 creationBlock, uint256 targetBlock);

    // Emitted when resolution callback is triggered
    event ResolutionCallbackTriggered(bytes32 indexed markId, uint256 blockNumber);

    
    // _originChainId Chain ID where RemembraMark is deployed (e.g., Base = 8453)
    // _remembraMarkHook Address of RemembraMark hook contract
    constructor(uint256 _originChainId, address _remembraMarkHook) {
        originChainId = _originChainId;
        remembraMarkHook = _remembraMarkHook;

        // Subscribe to ExposureMarked events (only on Reactive Network deployment, not ReactVM)
        if (!vm) {
            service.subscribe(
                _originChainId,
                _remembraMarkHook,
                EXPOSURE_MARKED_TOPIC,
                REACTIVE_IGNORE, // topic1: markId (any)
                REACTIVE_IGNORE, // topic2: poolId (any)
                REACTIVE_IGNORE // topic3: swapper (any)
            );
        }
    }

    
    // React to ExposureMarked events and trigger resolution when observation window elapses
    // Called by Reactive Network system contract when subscribed event occurs
    // Only runs in ReactVM (vmOnly modifier)
    function react(LogRecord calldata log) external override vmOnly {
        // Verify this is an ExposureMarked event from our target contract
        if (log.chain_id != originChainId || log._contract != remembraMarkHook) {
            return;
        }

        if (log.topic_0 != EXPOSURE_MARKED_TOPIC) {
            return;
        }

        // Extract markId from topic1 (first indexed parameter)
        bytes32 markId = bytes32(log.topic_1);

        // Register mark for monitoring
        uint256 creationBlock = log.block_number;
        markCreationBlocks[markId] = creationBlock;

        uint256 targetBlock = creationBlock + OBSERVATION_WINDOW_BLOCKS;
        emit MarkRegistered(markId, creationBlock, targetBlock);

        // Check if observation window has already elapsed
        // Note: Reactive Network delivers events with block context
        // We trigger callback immediately if window elapsed, or wait for next delivery
        if (log.block_number >= targetBlock) {
            _triggerResolutionCallback(markId);
        }

        // Note: For marks where observation window hasn't elapsed yet,
        // this contract relies on Reactive Network's event re-delivery mechanism
        // or can be enhanced with CRON subscription for periodic checks
    }

    
    // Manually check and trigger resolution for a registered mark
    // Can be called from RNK deployment to force resolution attempt
    // Useful for marks that may have been registered but callback not yet sent
    function checkAndResolve(bytes32 markId, uint256 currentBlock) external rnOnly {
        uint256 creationBlock = markCreationBlocks[markId];
        require(creationBlock != 0, "Mark not registered");
        require(currentBlock >= creationBlock + OBSERVATION_WINDOW_BLOCKS, "Window not elapsed");

        _triggerResolutionCallback(markId);
    }

    
    // Internal function to emit callback event for mark resolution
    // Callback will be delivered to destination chain by Reactive Network
    function _triggerResolutionCallback(bytes32 markId) internal {
        emit ResolutionCallbackTriggered(markId, block.number);

        // Prepare callback payload
        // The destination contract must implement: resolveMark(bytes32 markId)
        // Reactive Network will deliver this to the origin chain
        bytes memory payload = abi.encodeWithSignature("resolveMark(bytes32)", markId);

        // Emit Callback event (Reactive Network intercepts and delivers)
        emit Callback(
            originChainId, // Destination chain
            remembraMarkHook, // Destination contract
            1000000, // Gas limit for callback
            payload // Encoded function call
        );
    }

    
    // Get creation block for a registered mark
    // creationBlock Block number when mark was created (0 if not registered)
    function getMarkCreationBlock(bytes32 markId) external view returns (uint256) {
        return markCreationBlocks[markId];
    }

    // if mark is ready for resolution based on current block
    // ready True if observation window has elapsed
    function isReadyForResolution(bytes32 markId, uint256 currentBlock) external view returns (bool) {
        uint256 creationBlock = markCreationBlocks[markId];
        if (creationBlock == 0) return false;
        return currentBlock >= creationBlock + OBSERVATION_WINDOW_BLOCKS;
    }
}
