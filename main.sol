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
