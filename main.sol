// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title EwAI — Omni-assistant task ledger and capability attestation
/// @notice Caduceus-style task routing and capability attestation; execution proofs bind to chain entropy.
/// @custom:inspiration Hermetic execution logs and capability slots for on-chain assistant state.
contract EwAI {
    // ─── Configuration (immutable) ───────────────────────────────────────────────
    address public immutable governor;
    address public immutable executor;
    address public immutable treasury;
    address public immutable relay;
    address public immutable attestationOracle;

    uint256 public immutable taskQueueCap;
    uint256 public immutable capabilitySlots;
    uint256 public immutable executionCooldownBlocks;
    uint256 public immutable rewardBasisPoints;
    uint256 public immutable genesisBlock;

    bytes32 public immutable domainSeparator;
    uint256 private constant BP_DENOM = 10_000;

    // ─── State ──────────────────────────────────────────────────────────────────
    struct TaskEntry {
        bytes32 taskHash;
        address requester;
        uint256 enqueuedBlock;
        uint8 priority;
        bool executed;
        uint256 executedAtBlock;
    }

    struct CapabilitySlot {
        bytes32 capabilityId;
        address attester;
        uint256 attestedAtBlock;
        bool revoked;
    }

    TaskEntry[] private _taskQueue;
    mapping(uint256 => CapabilitySlot) public capabilityByIndex;
    mapping(address => uint256) public executionCountByAddress;
    mapping(bytes32 => uint256) public taskIdToQueueIndex;

    uint256 public totalExecutions;
    uint256 public totalRewardDisbursed;
    uint256 private _reentrancyLock;

    // ─── Upgrade (versioned, time-delayed; governor only) ─────────────────────────
    uint256 public logicVersion;
    uint256 public nextLogicVersion;
    uint256 public upgradeEffectiveBlock;
    uint256 public constant UPGRADE_MIN_DELAY_BLOCKS = 100;

    // ─── Circuit breaker ──────────────────────────────────────────────────────
    bool public paused;

    // ─── Custom errors (EwAI-specific) ──────────────────────────────────────────
    error EwAI_NotGovernor();
    error EwAI_NotExecutor();
    error EwAI_NotRelay();
    error EwAI_QueueFull();
    error EwAI_TaskNotFound();
