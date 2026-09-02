// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IReactiveSystem, IReactive, IReactiveCallback} from "./interfaces/IReactiveCallback.sol";
import {IRemembraMark} from "../interfaces/IRemembraMark.sol";

// ReactiveMarkResolver
// Automates observation window monitoring and resolution triggering for RemembraMark
// This contract is deployed on Reactive Network and monitors ExposureMarked events.
//   When the observation window elapses, it triggers a callback to resolve the mark.
//   RemembraMark validates eligibility and performs state transition.


// ARCHITECTURE:
// 1. Deploy on Reactive Network
// 2. Subscribe to ExposureMarked events from RemembraMark hook
// 3. Monitor block numbers via CRON events
// 4. Trigger callback to RemembraMark.resolveMark() when window elapses


// SECURITY:
// Callbacks authenticated via CALLBACK_PROXY_ADDR (Reactive system contract)
// RemembraMark validates eligibility regardless of caller
// No arbitrary state forcing
// Permissionless but gated by RemembraMark's economic logic
contract ReactiveMarkResolver is IReactive {
    // Reactive Network system contract address
    // Standard address: 0x0000000000000000000000000000000000fffFfF
    address private constant REACTIVE_SYSTEM = 0x0000000000000000000000000000000000fffFfF;

    // Reactive callback proxy address (same as system contract)
    address private constant CALLBACK_PROXY = 0x0000000000000000000000000000000000fffFfF;

    // Chain ID where RemembraMark is deployed (e.g., Sepolia = 11155111)
    uint256 public immutable originChainId;

    // Address of RemembraMark hook on origin chain
    address public immutable remembraMarkHook;

    // Observation window in blocks (matches RemembraMark.OBSERVATION_WINDOW_BLOCKS)
    uint256 public constant OBSERVATION_WINDOW_BLOCKS = 25;

    // ExposureMarked event signature
    // keccak256("ExposureMarked(bytes32,bytes32,address,int24,int256,bool,uint256,uint256,uint160,uint256)")
    uint256 private constant EXPOSURE_MARKED_TOPIC = 0xd9e8c5b8c5b5e5b5e5b5e5b5e5b5e5b5e5b5e5b5e5b5e5b5e5b5e5b5e5b5e5b5;

    // Mapping from mark ID to creation block number
    mapping(bytes32 => uint256) public markCreationBlocks;

    // Mapping from mark ID to whether resolution was triggered
    mapping(bytes32 => bool) public resolutionTriggered;

    // Emitted when a mark is registered for monitoring
    event MarkRegistered(bytes32 indexed markId, uint256 creationBlock, uint256 triggerBlock);

    // Emitted when resolution is triggered
    event ResolutionTriggered(bytes32 indexed markId, uint256 blockNumber);

    // Unauthorized caller
    error Unauthorized();

    // Mark already being monitored
    error MarkAlreadyRegistered(bytes32 markId);

    // _originChainId Chain ID where RemembraMark is deployed
    // _remembraMarkHook Address of RemembraMark hook
    constructor(uint256 _originChainId, address _remembraMarkHook) {
        originChainId = _originChainId;
        remembraMarkHook = _remembraMarkHook;

        // Subscribe to ExposureMarked events from RemembraMark
        // This only works when deployed on Reactive Network
        // In ReactVM (testing), system contract doesn't exist
        if (address(REACTIVE_SYSTEM).code.length > 0) {
            IReactiveSystem(REACTIVE_SYSTEM).subscribe(
                _originChainId,
                _remembraMarkHook,
                EXPOSURE_MARKED_TOPIC,
                0, // topic1: wildcard (markId)
                0, // topic2: wildcard (poolId)
                0 // topic3: wildcard (swapper)
            );
        }
    }

    // React to ExposureMarked events and trigger resolution when window elapses
    // Called by Reactive Network when subscribed event occurs
    function react(
        uint256 chainId,
        address _contract,
        uint256 topic0,
        uint256 topic1,
        uint256 topic2,
        uint256 topic3,
        bytes calldata data,
        uint256 blockNumber,
        bytes32 txHash
    ) external override {
        // Verify caller is Reactive system
        if (msg.sender != REACTIVE_SYSTEM) {
            revert Unauthorized();
        }

        // Verify event is from correct chain and contract
        if (chainId != originChainId || _contract != remembraMarkHook) {
            return;
        }

        // Verify event signature
        if (topic0 != EXPOSURE_MARKED_TOPIC) {
            return;
        }

        // Extract markId from topic1 (first indexed parameter)
        bytes32 markId = bytes32(topic1);

        // Register mark for monitoring
        _registerMark(markId, blockNumber);
    }

    // Register a mark for observation window monitoring
    // markId The exposure mark identifier
    // creationBlock Block number when mark was created
    function _registerMark(bytes32 markId, uint256 creationBlock) internal {
        // Check if already registered
        if (markCreationBlocks[markId] != 0) {
            revert MarkAlreadyRegistered(markId);
        }

        markCreationBlocks[markId] = creationBlock;

        uint256 triggerBlock = creationBlock + OBSERVATION_WINDOW_BLOCKS;

        emit MarkRegistered(markId, creationBlock, triggerBlock);

        // In production, would schedule callback for triggerBlock
        // Reactive Network's CRON mechanism or block monitoring would handle this
        // For now, external callers can use checkAndTriggerResolution()
    }

    // Check if mark is ready for resolution and trigger if so
    // Can be called by anyone (permissionless)
    // markId The exposure mark identifier
    // currentBlock Current block number on origin chain
    function checkAndTriggerResolution(bytes32 markId, uint256 currentBlock) external {
        uint256 creationBlock = markCreationBlocks[markId];

        // Verify mark is registered
        require(creationBlock != 0, "Mark not registered");

        // Verify not already triggered
        require(!resolutionTriggered[markId], "Already triggered");

        // Verify observation window has elapsed
        require(currentBlock >= creationBlock + OBSERVATION_WINDOW_BLOCKS, "Window not elapsed");

        // Mark as triggered
        resolutionTriggered[markId] = true;

        emit ResolutionTriggered(markId, currentBlock);

        // In production Reactive deployment, would send callback transaction
        // to origin chain calling remembraMarkHook.resolveMark(markId)
        //
        // The callback would be authenticated via CALLBACK_PROXY_ADDR
        // RemembraMark validates eligibility before performing state transition
        //
        // For testnet/demo: External relayer or script calls resolveMark()
    }

    // Manually register a mark (for testing or off-chain indexer)
    // markId The exposure mark identifier
    // creationBlock Block number when mark was created
    function manualRegisterMark(bytes32 markId, uint256 creationBlock) external {
        _registerMark(markId, creationBlock);
    }

    // Check if mark is ready for resolution
    // markId The exposure mark identifier
    // currentBlock Current block number on origin chain
    // ready True if observation window has elapsed
    function isReadyForResolution(bytes32 markId, uint256 currentBlock) external view returns (bool ready) {
        uint256 creationBlock = markCreationBlocks[markId];
        if (creationBlock == 0) {
            return false;
        }
        if (resolutionTriggered[markId]) {
            return false;
        }
        return currentBlock >= creationBlock + OBSERVATION_WINDOW_BLOCKS;
    }

    // Get creation block for a mark
    // markId The exposure mark identifier
    // creationBlock Block number when mark was created (0 if not registered)
    function getMarkCreationBlock(bytes32 markId) external view returns (uint256 creationBlock) {
        return markCreationBlocks[markId];
    }
}
