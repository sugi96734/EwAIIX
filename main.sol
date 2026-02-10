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
    error EwAI_AlreadyExecuted();
    error EwAI_CooldownActive();
    error EwAI_InvalidRequester();
    error EwAI_InvalidCapabilityIndex();
    error EwAI_CapabilityRevoked();
    error EwAI_ZeroAmount();
    error EwAI_Reentrancy();
    error EwAI_InvalidSlot();
    error EwAI_TransferFailed();
    error EwAI_UpgradeWindowNotReached();
    error EwAI_UpgradeAlreadyFinalized();
    error EwAI_WhenPaused();
    error EwAI_InvalidVersion();
    error EwAI_UpgradeDelayTooShort();

    // ─── Events (unique naming) ──────────────────────────────────────────────────
    event TaskEnqueued(uint256 indexed queueIndex, bytes32 taskHash, address requester, uint8 priority);
    event TaskExecuted(uint256 indexed queueIndex, uint256 atBlock, address executor);
    event CapabilityAttested(uint256 indexed slotIndex, bytes32 capabilityId, address attester);
    event CapabilityRevoked(uint256 indexed slotIndex, uint256 atBlock);
    event RewardDisbursed(address indexed recipient, uint256 amount);
    event ExecutionRecorded(address indexed executor, uint256 taskIndex, uint256 blockNumber);
    event UpgradeScheduled(uint256 fromVersion, uint256 toVersion, uint256 effectiveBlock);
    event UpgradeFinalized(uint256 newVersion);
    event PauseToggled(bool paused, uint256 atBlock);

    constructor() {
        governor = address(0x1F8a3c5E7b9D2f4A6c8e0B2d4F6a8C0e2B4d6F8a0);
        executor = address(0x2A9b4c6D8e0F2a4B6c8D0e2F4a6B8c0D2e4F6a8B);
        treasury = address(0x3B0c5d7E9f1A3b5C7d9E1f3A5b7C9d1E3f5A7b9C);
        relay = address(0x4C1d6e8F0a2B4c6D8e0F2a4B6c8D0e2F4a6B8c0D);
        attestationOracle = address(0x5D2e7f9A1b3C5d7E9f1A3b5C7d9E1f3A5b7C9d1E);
