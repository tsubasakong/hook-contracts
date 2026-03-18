// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../AgenticCommerceHooked.sol";

abstract contract UnderwritingMCUCore {
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

    mapping(address => bool) internal registeredUnderwriterByAddress;
    mapping(uint256 => UnderwriteCommit) internal commits;
    mapping(uint256 => bytes32) internal commitHashByJobId;
    mapping(uint256 => uint256) internal committedBudgetByJobId;
    mapping(uint256 => bool) internal awaitingCloseByJobId;
    mapping(uint256 => uint256) internal parentJobIdByCloseJobId;
    mapping(uint256 => uint256) internal activeCloseJobIdByParentJobId;

    function _registerUnderwriter(address underwriter) internal {
        if (underwriter == address(0)) revert ZeroAddress();
        registeredUnderwriterByAddress[underwriter] = true;
    }

    function _unregisterUnderwriter(address underwriter) internal {
        if (underwriter == address(0)) revert ZeroAddress();
        delete registeredUnderwriterByAddress[underwriter];
    }

    function _isRegisteredUnderwriter(address underwriter) internal view returns (bool) {
        return registeredUnderwriterByAddress[underwriter];
    }

    function _getCommit(uint256 jobId) internal view returns (UnderwriteCommit memory) {
        return commits[jobId];
    }

    function _isAwaitingClose(uint256 jobId) internal view returns (bool) {
        return awaitingCloseByJobId[jobId];
    }

    function _getParentJobId(uint256 closeJobId) internal view returns (uint256) {
        return parentJobIdByCloseJobId[closeJobId];
    }

    function _getActiveCloseJobId(uint256 parentJobId) internal view returns (uint256) {
        return activeCloseJobIdByParentJobId[parentJobId];
    }

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

        if (commitHashByJobId[jobId] != bytes32(0)) {
            if (commitHashByJobId[jobId] != newCommitHash) revert CommitLocked();
            if (committedBudgetByJobId[jobId] != amount) revert CommitLocked();
            return;
        }

        if (commit.validUntil <= block.timestamp) revert CommitExpired();

        if (commit.parentJobId == 0) {
            if (!registeredUnderwriterByAddress[commit.underwriter]) revert UnderwriterNotRegistered();
        } else {
            _clearStaleCloseIfTerminal(acp, commit.parentJobId);
            _validateCloseCommit(acp, jobId, job, commit);
            parentJobIdByCloseJobId[jobId] = commit.parentJobId;
            activeCloseJobIdByParentJobId[commit.parentJobId] = jobId;
        }

        commitHashByJobId[jobId] = newCommitHash;
        committedBudgetByJobId[jobId] = amount;
        commits[jobId] = commit;
    }

    function _postSubmitWorkflow(uint256 jobId, bytes32 deliverable, bytes memory optParams) internal view {
        SubmitEvidence memory evidence = abi.decode(optParams, (SubmitEvidence));
        UnderwriteCommit memory commit = _requireCommit(jobId);

        if (deliverable != evidence.bundleHash) revert EvidenceMismatch();
        if (evidence.policyHash != commit.policyHash) revert EvidenceMismatch();
        if (evidence.quoteIdHash != commit.quoteIdHash) revert EvidenceMismatch();
    }

    function _postCompleteWorkflow(uint256 jobId) internal {
        UnderwriteCommit memory commit = _requireCommit(jobId);
        if (commit.parentJobId == 0 && commit.allowCloseJob) {
            awaitingCloseByJobId[jobId] = true;
            return;
        }

        if (commit.parentJobId != 0) {
            uint256 parentJobId = commit.parentJobId;
            if (activeCloseJobIdByParentJobId[parentJobId] == jobId) {
                delete activeCloseJobIdByParentJobId[parentJobId];
            }
            delete awaitingCloseByJobId[parentJobId];
        }
    }

    function _postRejectWorkflow(uint256 jobId) internal {
        UnderwriteCommit memory commit = commits[jobId];
        if (commit.parentJobId != 0 && activeCloseJobIdByParentJobId[commit.parentJobId] == jobId) {
            delete activeCloseJobIdByParentJobId[commit.parentJobId];
        }
    }

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

    function _requireCommit(uint256 jobId) internal view returns (UnderwriteCommit memory) {
        if (commitHashByJobId[jobId] == bytes32(0)) revert CommitNotFound();
        return commits[jobId];
    }
}
