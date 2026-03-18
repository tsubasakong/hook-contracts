// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../AgenticCommerceHooked.sol";

/**
 * @title UnderwritingWorkflowCore
 * @notice Internal workflow module behind `UnderwritingHook`.
 *
 * USE CASE
 * --------
 * This abstract module owns the underwriting state that ACP itself does not
 * track: the registered underwriter set, the locked commitment for each job,
 * and the optional parent/close linkage for a two-stage underwritten flow.
 *
 * `UnderwritingHook` remains the thin ACP-facing shell and signature relay.
 * This module is where the underwriting-specific admission rules live:
 * commit locking, evidence matching, `AwaitingClose`, and close-job lineage.
 *
 * FLOW (workflow helpers marked with →)
 * ----
 *  1. Hook admin registers an allowed underwriter through the shell:
 *     → `_registerUnderwriter` / `_unregisterUnderwriter` maintain the local
 *       allowlist.
 *
 *  2. Client calls `setBudget(jobId, amount, abi.encode(commit))`:
 *     → `_preSetBudgetWorkflow` decodes the commit, locks the first
 *       `{commit,budget}` pair for the job, and classifies it as:
 *         - a root underwriting job (`parentJobId == 0`), or
 *         - a close job that points at an already approved parent job.
 *
 *  3. Provider submits `deliverable = evidence.bundleHash` with
 *     `optParams = abi.encode(SubmitEvidence)`:
 *     → `_postSubmitWorkflow` verifies the submitted bundle, policy, and quote
 *       hashes against the committed underwriting terms.
 *
 *  4. After the shell relays an underwriter completion/rejection into ACP:
 *     → `_postCompleteWorkflow` either marks a root job `AwaitingClose` or, for
 *       a close job, clears the parent/close linkage after success.
 *     → `_postRejectWorkflow` clears only the active close slot so the parent
 *       may remain open for a later replacement close job.
 *
 * RECOVERY
 * --------
 *  - repeated `setBudget`: once a job is locked, only the exact same
 *    `{commit,budget}` pair may be replayed; any change reverts with
 *    `CommitLocked`.
 *  - stale close jobs: because `claimRefund()` is outside hook callbacks, the
 *    next close commit lazily clears the parent's active close slot when the
 *    previous close already reached a terminal state.
 *
 * KEY PROPERTY
 * ------------
 * ACP stays the generic escrow lifecycle. This module adds underwriting-specific
 * workflow state without teaching ACP core about underwriter policy or
 * parent/close lineage.
 */
abstract contract UnderwritingWorkflowCore {
    struct UnderwriteCommit {
        uint256 parentJobId;
        address underwriter;
        uint64 validUntil;
        bytes32 policyHash;
        bytes32 quoteIdHash;
        bytes32 termsHash;
        bool allowCloseJob;
    }

    struct SubmitEvidence {
        bytes32 bundleHash;
        bytes32 policyHash;
        bytes32 quoteIdHash;
    }

    error UnderwriterNotRegistered();
    error ProviderRequired();
    error EvaluatorMismatch();
    error ZeroAddress();
    error CommitExpired();
    error CommitLocked();
    error CommitNotFound();
    error ParentNotCommitted();
    error ParentNotAwaitingClose();
    error ActiveCloseExists();
    error ParentMismatch();
    error EvidenceMismatch();

    // -------------------------------------------------------------------------
    // Workflow storage
    // -------------------------------------------------------------------------

    mapping(address => bool) internal registeredUnderwriterByAddress;
    mapping(uint256 => UnderwriteCommit) internal commits;
    mapping(uint256 => bytes32) internal commitHashByJobId; // keccak256 lock for the committed underwriting terms
    mapping(uint256 => uint256) internal committedBudgetByJobId; // budget that was locked alongside the commit hash
    mapping(uint256 => bool) internal awaitingCloseByJobId; // true once an approved parent may admit a close job
    mapping(uint256 => uint256) internal parentJobIdByCloseJobId; // reverse lookup from close job -> parent job
    mapping(uint256 => uint256) internal activeCloseJobIdByParentJobId; // at most one live close job per parent

    // -------------------------------------------------------------------------
    // Underwriter registry
    // -------------------------------------------------------------------------

    /// @dev Admit an underwriter signer that future commits may reference.
    function _registerUnderwriter(address underwriter) internal {
        if (underwriter == address(0)) revert ZeroAddress();
        registeredUnderwriterByAddress[underwriter] = true;
    }

    /// @dev Remove an underwriter signer from the local allowlist.
    function _unregisterUnderwriter(address underwriter) internal {
        if (underwriter == address(0)) revert ZeroAddress();
        delete registeredUnderwriterByAddress[underwriter];
    }

    /// @dev Check whether an underwriter is currently allowed for new root commits.
    function _isRegisteredUnderwriter(address underwriter) internal view returns (bool) {
        return registeredUnderwriterByAddress[underwriter];
    }

    // -------------------------------------------------------------------------
    // Workflow views
    // -------------------------------------------------------------------------

    /// @dev Return the stored underwriting commit for a job, if any.
    function _getCommit(uint256 jobId) internal view returns (UnderwriteCommit memory) {
        return commits[jobId];
    }

    /// @dev Return whether a completed parent job is waiting for a close stage.
    function _isAwaitingClose(uint256 jobId) internal view returns (bool) {
        return awaitingCloseByJobId[jobId];
    }

    /// @dev Return the parent job recorded for an admitted close job.
    function _getParentJobId(uint256 closeJobId) internal view returns (uint256) {
        return parentJobIdByCloseJobId[closeJobId];
    }

    /// @dev Return the currently active close job for a parent, if any.
    function _getActiveCloseJobId(uint256 parentJobId) internal view returns (uint256) {
        return activeCloseJobIdByParentJobId[parentJobId];
    }

    // -------------------------------------------------------------------------
    // ACP lifecycle workflow helpers
    // -------------------------------------------------------------------------

    /// @dev Lock underwriting terms on first `setBudget` and admit close jobs
    ///      only when the referenced parent workflow is ready.
    function _preSetBudgetWorkflow(
        AgenticCommerceHooked acp,
        address hookAddress,
        uint256 jobId,
        uint256 amount,
        bytes memory optParams
    ) internal {
        AgenticCommerceHooked.Job memory job = acp.getJob(jobId);
        UnderwriteCommit memory commit = abi.decode(optParams, (UnderwriteCommit));
        bytes32 newCommitHash = keccak256(abi.encode(commit));

        if (job.provider == address(0)) revert ProviderRequired();
        if (job.evaluator != hookAddress) revert EvaluatorMismatch();

        // Once a job is committed, only an exact replay of the same
        // `{commit,budget}` pair is allowed.
        if (commitHashByJobId[jobId] != bytes32(0)) {
            if (commitHashByJobId[jobId] != newCommitHash) revert CommitLocked();
            if (committedBudgetByJobId[jobId] != amount) revert CommitLocked();
            return;
        }

        if (commit.validUntil <= block.timestamp) revert CommitExpired();

        if (commit.parentJobId == 0) {
            // Root jobs must name a currently registered underwriter.
            if (!registeredUnderwriterByAddress[commit.underwriter]) revert UnderwriterNotRegistered();
        } else {
            // Close jobs must point at a compatible, approved parent workflow.
            _clearStaleCloseIfTerminal(acp, commit.parentJobId);
            _validateCloseCommit(acp, jobId, job, commit);
            parentJobIdByCloseJobId[jobId] = commit.parentJobId;
            activeCloseJobIdByParentJobId[commit.parentJobId] = jobId;
        }

        commitHashByJobId[jobId] = newCommitHash;
        committedBudgetByJobId[jobId] = amount;
        commits[jobId] = commit;
    }

    /// @dev Ensure the submitted evidence exactly matches the committed hashes.
    function _postSubmitWorkflow(uint256 jobId, bytes32 deliverable, bytes memory optParams) internal view {
        SubmitEvidence memory evidence = abi.decode(optParams, (SubmitEvidence));
        UnderwriteCommit memory commit = _requireCommit(jobId);

        if (deliverable != evidence.bundleHash) revert EvidenceMismatch();
        if (evidence.policyHash != commit.policyHash) revert EvidenceMismatch();
        if (evidence.quoteIdHash != commit.quoteIdHash) revert EvidenceMismatch();
    }

    /// @dev Advance workflow state after ACP completes an underwritten job.
    function _postCompleteWorkflow(uint256 jobId) internal {
        UnderwriteCommit memory commit = _requireCommit(jobId);
        if (commit.parentJobId == 0 && commit.allowCloseJob) {
            // A successful parent job may now admit one close job.
            awaitingCloseByJobId[jobId] = true;
            return;
        }

        if (commit.parentJobId != 0) {
            // A successful close job retires the parent/close linkage.
            uint256 parentJobId = commit.parentJobId;
            if (activeCloseJobIdByParentJobId[parentJobId] == jobId) {
                delete activeCloseJobIdByParentJobId[parentJobId];
            }
            delete awaitingCloseByJobId[parentJobId];
        }
    }

    /// @dev Clear the active close slot when a close job is rejected.
    function _postRejectWorkflow(uint256 jobId) internal {
        UnderwriteCommit memory commit = commits[jobId];
        if (commit.parentJobId != 0 && activeCloseJobIdByParentJobId[commit.parentJobId] == jobId) {
            delete activeCloseJobIdByParentJobId[commit.parentJobId];
        }
    }

    // -------------------------------------------------------------------------
    // Validation helpers
    // -------------------------------------------------------------------------

    /// @dev Admit a close commit only when it matches an approved parent
    ///      workflow and no different live close job is already occupying the slot.
    function _validateCloseCommit(
        AgenticCommerceHooked acp,
        uint256 jobId,
        AgenticCommerceHooked.Job memory job,
        UnderwriteCommit memory commit
    ) internal view {
        UnderwriteCommit memory parentCommit = commits[commit.parentJobId];
        AgenticCommerceHooked.Job memory parentJob = acp.getJob(commit.parentJobId);
        uint256 activeCloseJobId = activeCloseJobIdByParentJobId[commit.parentJobId];

        if (commitHashByJobId[commit.parentJobId] == bytes32(0)) revert ParentNotCommitted();
        if (parentJob.id == 0) revert ParentMismatch();
        if (commit.parentJobId == jobId) revert ParentMismatch();
        if (parentCommit.parentJobId != 0 || !parentCommit.allowCloseJob || commit.allowCloseJob) {
            revert ParentMismatch();
        }
        if (
            parentJob.client != job.client || parentJob.provider != job.provider || parentJob.evaluator != job.evaluator
                || parentJob.hook != job.hook
        ) revert ParentMismatch();
        if (parentCommit.underwriter != commit.underwriter) revert ParentMismatch();
        if (parentJob.status != AgenticCommerceHooked.JobStatus.Completed || !awaitingCloseByJobId[commit.parentJobId]) {
            revert ParentNotAwaitingClose();
        }
        if (activeCloseJobId != 0 && activeCloseJobId != jobId) revert ActiveCloseExists();
    }

    /// @dev Lazily clear a parent's active close slot when the recorded close
    ///      job has already reached a terminal state outside the hook callbacks.
    function _clearStaleCloseIfTerminal(AgenticCommerceHooked acp, uint256 parentJobId) internal {
        uint256 activeCloseJobId = activeCloseJobIdByParentJobId[parentJobId];
        if (activeCloseJobId == 0) return;

        AgenticCommerceHooked.Job memory activeCloseJob = acp.getJob(activeCloseJobId);
        if (
            activeCloseJob.status == AgenticCommerceHooked.JobStatus.Rejected
                || activeCloseJob.status == AgenticCommerceHooked.JobStatus.Expired
        ) {
            delete activeCloseJobIdByParentJobId[parentJobId];
        }
    }

    /// @dev Load a previously locked commit or revert if the job never
    ///      established underwriting terms.
    function _requireCommit(uint256 jobId) internal view returns (UnderwriteCommit memory) {
        if (commitHashByJobId[jobId] == bytes32(0)) revert CommitNotFound();
        return commits[jobId];
    }
}
