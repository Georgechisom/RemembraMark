// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Reactive Network interfaces
// Based on Reactive smart contract patterns
// Content was rephrased for compliance with licensing restrictions

// System contract for Reactive Network subscriptions
interface IReactiveSystem {
    // Subscribe to events from a specific contract
    // chainId Chain ID where the contract is deployed
    // contractAddr Address of the contract to monitor
    // topic0 Event signature (topic0)
    // topic1 First indexed parameter (0 for wildcard)
    // topic2 Second indexed parameter (0 for wildcard)
    // topic3 Third indexed parameter (0 for wildcard)
    function subscribe(
        uint256 chainId,
        address contractAddr,
        uint256 topic0,
        uint256 topic1,
        uint256 topic2,
        uint256 topic3
    ) external;
}

// Interface for contracts that react to events
interface IReactive {
    // Called by Reactive Network when a subscribed event occurs
    // chainId Chain ID where the event occurred
    // _contract Address of the contract that emitted the event
    // topic0 Event signature
    // topic1 First indexed parameter
    // topic2 Second indexed parameter
    // topic3 Third indexed parameter
    // data Non-indexed event data
    // blockNumber Block number where event was emitted
    // txHash Transaction hash
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
    ) external;
}

// Interface for callback receivers on destination chains
interface IReactiveCallback {
    // Called by Reactive Network callback proxy
    //  markId The exposure mark identifier
    function onMarkResolutionTrigger(bytes32 markId) external;
}
