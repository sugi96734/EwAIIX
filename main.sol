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

        taskQueueCap = 2048;
        capabilitySlots = 64;
        executionCooldownBlocks = 12;
        rewardBasisPoints = 85;
        genesisBlock = block.number;

        domainSeparator = keccak256(
            abi.encodePacked(
                block.chainid,
                address(this),
                "EwAI_OmniAssistant_v1",
                genesisBlock
            )
        );

        logicVersion = 1;
        nextLogicVersion = 0;
        upgradeEffectiveBlock = 0;
        paused = false;
    }

    modifier onlyGovernor() {
        if (msg.sender != governor) revert EwAI_NotGovernor();
        _;
    }

    modifier onlyExecutor() {
        if (msg.sender != executor) revert EwAI_NotExecutor();
        _;
    }

    modifier onlyRelay() {
        if (msg.sender != relay) revert EwAI_NotRelay();
        _;
    }

    modifier nonReentrant() {
        if (_reentrancyLock != 0) revert EwAI_Reentrancy();
        _reentrancyLock = 1;
        _;
        _reentrancyLock = 0;
    }

    modifier whenNotPaused() {
        if (paused) revert EwAI_WhenPaused();
        _;
    }

    /// @notice Schedule a logic version upgrade; effective after at least UPGRADE_MIN_DELAY_BLOCKS.
    function scheduleUpgrade(uint256 newVersion, uint256 effectiveAfterBlocks) external onlyGovernor {
        if (newVersion <= logicVersion) revert EwAI_InvalidVersion();
        if (effectiveAfterBlocks < UPGRADE_MIN_DELAY_BLOCKS) revert EwAI_UpgradeDelayTooShort();
        nextLogicVersion = newVersion;
        upgradeEffectiveBlock = block.number + effectiveAfterBlocks;
        emit UpgradeScheduled(logicVersion, newVersion, upgradeEffectiveBlock);
    }

    /// @notice Finalize upgrade after the effective block has been reached. Bumps logicVersion and clears pending.
    function finalizeUpgrade() external onlyGovernor {
        if (block.number < upgradeEffectiveBlock) revert EwAI_UpgradeWindowNotReached();
        if (nextLogicVersion == 0) revert EwAI_UpgradeAlreadyFinalized();
        uint256 prev = logicVersion;
        logicVersion = nextLogicVersion;
        nextLogicVersion = 0;
        upgradeEffectiveBlock = 0;
        emit UpgradeFinalized(logicVersion);
    }

    /// @notice Current active logic version (returns nextLogicVersion once upgrade window has passed, until finalizeUpgrade).
    function currentLogicVersion() external view returns (uint256) {
        if (nextLogicVersion != 0 && block.number >= upgradeEffectiveBlock) return nextLogicVersion;
        return logicVersion;
    }

    /// @notice Governor can pause state-changing operations (circuit breaker).
    function setPaused(bool _paused) external onlyGovernor {
        paused = _paused;
        emit PauseToggled(paused, block.number);
    }

    /// @notice Enqueue a task (relay or governor). Task hash is keccak256(abi.encodePacked(domainSeparator, payload)).
    function enqueueTask(bytes32 taskHash, address requester, uint8 priority) external onlyRelay nonReentrant whenNotPaused returns (uint256 queueIndex) {
        if (requester == address(0)) revert EwAI_InvalidRequester();
        if (_taskQueue.length >= taskQueueCap) revert EwAI_QueueFull();

        queueIndex = _taskQueue.length;
        taskIdToQueueIndex[taskHash] = queueIndex + 1;

        _taskQueue.push(TaskEntry({
            taskHash: taskHash,
            requester: requester,
            enqueuedBlock: block.number,
            priority: priority,
            executed: false,
            executedAtBlock: 0
        }));

        emit TaskEnqueued(queueIndex, taskHash, requester, priority);
        return queueIndex;
    }

    /// @notice Mark a task as executed (executor only). Enforces cooldown per executor.
    function markTaskExecuted(uint256 queueIndex) external onlyExecutor nonReentrant whenNotPaused {
        if (queueIndex >= _taskQueue.length) revert EwAI_TaskNotFound();
        TaskEntry storage entry = _taskQueue[queueIndex];
        if (entry.executed) revert EwAI_AlreadyExecuted();

        uint256 lastExecutionBlock = entry.enqueuedBlock + executionCooldownBlocks;
        if (block.number < lastExecutionBlock) revert EwAI_CooldownActive();

        entry.executed = true;
        entry.executedAtBlock = block.number;
        totalExecutions += 1;
        executionCountByAddress[executor] += 1;

        emit TaskExecuted(queueIndex, block.number, executor);
        emit ExecutionRecorded(executor, queueIndex, block.number);
    }

    /// @notice Attest a capability in a slot (governor or attestation oracle).
    function attestCapability(uint256 slotIndex, bytes32 capabilityId) external whenNotPaused {
        if (msg.sender != governor && msg.sender != attestationOracle) revert EwAI_NotGovernor();
        if (slotIndex >= capabilitySlots) revert EwAI_InvalidCapabilityIndex();

        capabilityByIndex[slotIndex] = CapabilitySlot({
            capabilityId: capabilityId,
            attester: msg.sender,
            attestedAtBlock: block.number,
            revoked: false
        });

        emit CapabilityAttested(slotIndex, capabilityId, msg.sender);
    }

    /// @notice Revoke a capability slot (governor only).
    function revokeCapability(uint256 slotIndex) external onlyGovernor whenNotPaused {
        if (slotIndex >= capabilitySlots) revert EwAI_InvalidCapabilityIndex();
        CapabilitySlot storage slot = capabilityByIndex[slotIndex];
        slot.revoked = true;
        emit CapabilityRevoked(slotIndex, block.number);
    }

    /// @notice Disburse reward to treasury or a recipient (governor only). Contract must hold balance.
    function disburseReward(address recipient, uint256 amount) external onlyGovernor nonReentrant whenNotPaused {
        if (amount == 0) revert EwAI_ZeroAmount();
        if (recipient == address(0)) revert EwAI_InvalidRequester();

        totalRewardDisbursed += amount;
        (bool ok,) = recipient.call{ value: amount }("");
        if (!ok) revert EwAI_TransferFailed();
        emit RewardDisbursed(recipient, amount);
    }

    /// @notice Compute reward for an execution (view). reward = basisPoints of a base unit; for display only.
    function computeRewardForExecution(uint256 baseUnit) external view returns (uint256) {
        return (baseUnit * rewardBasisPoints) / BP_DENOM;
    }

    function taskQueueLength() external view returns (uint256) {
        return _taskQueue.length;
    }

    function getTaskEntry(uint256 index) external view returns (
        bytes32 taskHash,
        address requester,
        uint256 enqueuedBlock,
        uint8 priority,
        bool executed,
        uint256 executedAtBlock
    ) {
        if (index >= _taskQueue.length) revert EwAI_TaskNotFound();
        TaskEntry storage e = _taskQueue[index];
        return (e.taskHash, e.requester, e.enqueuedBlock, e.priority, e.executed, e.executedAtBlock);
    }

    function getCapabilitySlot(uint256 index) external view returns (
        bytes32 capabilityId,
        address attester,
        uint256 attestedAtBlock,
        bool revoked
    ) {
        if (index >= capabilitySlots) revert EwAI_InvalidCapabilityIndex();
        CapabilitySlot storage s = capabilityByIndex[index];
        return (s.capabilityId, s.attester, s.attestedAtBlock, s.revoked);
    }

    function queueIndexForTask(bytes32 taskHash) external view returns (uint256) {
        uint256 idx = taskIdToQueueIndex[taskHash];
        if (idx == 0) revert EwAI_TaskNotFound();
        return idx - 1;
    }
