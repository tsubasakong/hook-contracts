// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "../AgenticCommerceHooked.sol";
import "../BaseACPHook.sol";

/**
 * @title UnderwritingHook
 * @notice Experimental underwriting example that keeps all extra lineage state
 *         in the hook while preserving the standard ACP lifecycle.
 *
 * USE CASE
 * --------
 * This hook adds an underwriting trust layer between the client and provider
 * for jobs where the client does not want ACP to release funds based only on
 * provider submission. Instead, submitted evidence must also be independently
 * approved or rejected by a registered underwriter signer before the job can
 * be finalized.
 *
 * The same underwriting mechanism supports both:
 *  - a normal single-stage underwritten job, and
 *  - a two-stage underwritten flow where a parent job, once approved, may
 *    later admit one hook-linked close job under the same underwriter.
 *
 * FLOW
 * ----
 *  1. Client creates a job with `hook = this` and `evaluator = this`.
 *  2. Client calls `setBudget(jobId, amount, abi.encode(commit))`.
 *     → `_preSetBudget` commits the underwriting payload and locks the budget.
 *  3. Client funds the job through the normal ACP flow.
 *  4. Provider submits `deliverable = evidence.bundleHash` with
 *     `optParams = abi.encode(SubmitEvidence)`.
 *     → `_postSubmit` verifies the submitted evidence matches the committed
 *       policy and quote hashes.
 *  5. The underwriter signs either `CompleteDecision` or `RejectDecision`.
 *  6. Anyone may relay that signature via `completeBySig(...)` or
 *     `rejectBySig(...)`.
 *  7. If the committed job allows a follow-on close stage, `_postComplete`
 *     marks the parent job `AwaitingClose`.
 *  8. A later close job is just another normal ACP `createJob(...)` call whose
 *     committed payload points back to the parent `jobId`.
 *
 * TRUST MODEL
 * -----------
 * ACP escrow behavior stays unchanged. This hook adds policy around who may
 * underwrite a job, what evidence must be submitted, and whether a later close
 * job is allowed. It reduces client risk from bad provider behavior by binding
 * payment release to an agreed underwriter decision and to committed evidence
 * hashes. This example is intentionally labeled
 * experimental rather than production-ready settlement infrastructure.
 */
contract UnderwritingHook is BaseACPHook, EIP712 {
    bytes32 private constant COMPLETE_TYPEHASH =
        keccak256("CompleteDecision(uint256 jobId,bytes32 reason,uint64 deadline,uint256 nonce)");
    bytes32 private constant REJECT_TYPEHASH =
        keccak256("RejectDecision(uint256 jobId,bytes32 reason,uint64 deadline,uint256 nonce)");

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

    struct CompleteDecision {
        uint256 jobId;
        bytes32 reason;
        uint64 deadline;
        uint256 nonce;
    }

    struct RejectDecision {
        uint256 jobId;
        bytes32 reason;
        uint64 deadline;
        uint256 nonce;
    }

    error OnlyAdmin();
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
    error WrongDecisionStatus();
    error DecisionExpired(uint64 deadline, uint64 currentTimestamp);
    error NonceUsed(address underwriter, uint256 nonce);
    error InvalidSigner(address expected, address actual);

    AgenticCommerceHooked public immutable acp;
    address public immutable admin;

    mapping(address => bool) public registeredUnderwriters;
    mapping(uint256 => UnderwriteCommit) internal commits;
    mapping(uint256 => bytes32) internal commitHashByJobId;
    mapping(uint256 => uint256) internal committedBudgetByJobId;
    mapping(uint256 => bool) internal awaitingCloseByJobId;
    mapping(uint256 => uint256) internal parentJobIdByCloseJobId;
    mapping(uint256 => uint256) internal activeCloseJobIdByParentJobId;
    mapping(address => mapping(uint256 => bool)) public usedNonces;

    modifier onlyAdmin() {
        if (msg.sender != admin) revert OnlyAdmin();
        _;
    }

    constructor(address acpContract_, address admin_) BaseACPHook(acpContract_) EIP712("Underwriting Hook", "1") {
        if (admin_ == address(0)) revert ZeroAddress();
        acp = AgenticCommerceHooked(acpContract_);
        admin = admin_;
    }

    function registerUnderwriter(address underwriter) external onlyAdmin {
        if (underwriter == address(0)) revert ZeroAddress();
        registeredUnderwriters[underwriter] = true;
    }

    function unregisterUnderwriter(address underwriter) external onlyAdmin {
        if (underwriter == address(0)) revert ZeroAddress();
        delete registeredUnderwriters[underwriter];
    }

    function getCommit(uint256 jobId) external view returns (UnderwriteCommit memory) {
        return commits[jobId];
    }

    function isAwaitingClose(uint256 jobId) external view returns (bool) {
        return awaitingCloseByJobId[jobId];
    }

    function getParentJobId(uint256 closeJobId) external view returns (uint256) {
        return parentJobIdByCloseJobId[closeJobId];
    }

    function getActiveCloseJobId(uint256 parentJobId) external view returns (uint256) {
        return activeCloseJobIdByParentJobId[parentJobId];
    }

    function completeBySig(CompleteDecision calldata decision, bytes calldata signature) external {
        if (block.timestamp > decision.deadline) revert DecisionExpired(decision.deadline, uint64(block.timestamp));

        AgenticCommerceHooked.Job memory job = acp.getJob(decision.jobId);
        if (job.status != AgenticCommerceHooked.JobStatus.Submitted) revert WrongDecisionStatus();

        UnderwriteCommit memory commit = _requireCommit(decision.jobId);
        _consumeNonceAndVerifySigner(
            commit.underwriter,
            decision.nonce,
            _hashTypedDataV4(
                keccak256(abi.encode(COMPLETE_TYPEHASH, decision.jobId, decision.reason, decision.deadline, decision.nonce))
            ),
            signature
        );

        acp.complete(decision.jobId, decision.reason, "");
    }

    function rejectBySig(RejectDecision calldata decision, bytes calldata signature) external {
        if (block.timestamp > decision.deadline) revert DecisionExpired(decision.deadline, uint64(block.timestamp));

        AgenticCommerceHooked.Job memory job = acp.getJob(decision.jobId);
        if (job.status != AgenticCommerceHooked.JobStatus.Submitted) revert WrongDecisionStatus();

        UnderwriteCommit memory commit = _requireCommit(decision.jobId);
        _consumeNonceAndVerifySigner(
            commit.underwriter,
            decision.nonce,
            _hashTypedDataV4(
                keccak256(abi.encode(REJECT_TYPEHASH, decision.jobId, decision.reason, decision.deadline, decision.nonce))
            ),
            signature
        );

        acp.reject(decision.jobId, decision.reason, "");
    }

    function _preSetBudget(uint256 jobId, uint256 amount, bytes memory optParams) internal override {
        AgenticCommerceHooked.Job memory job = acp.getJob(jobId);
        UnderwriteCommit memory commit = abi.decode(optParams, (UnderwriteCommit));
        bytes32 newCommitHash = keccak256(abi.encode(commit));

        if (job.provider == address(0)) revert ProviderRequired();
        if (job.evaluator != address(this)) revert EvaluatorMismatch();

        if (commitHashByJobId[jobId] != bytes32(0)) {
            if (commitHashByJobId[jobId] != newCommitHash) revert CommitLocked();
            if (committedBudgetByJobId[jobId] != amount) revert CommitLocked();
            return;
        }

        if (commit.validUntil <= block.timestamp) revert CommitExpired();

        if (commit.parentJobId == 0) {
            if (!registeredUnderwriters[commit.underwriter]) revert UnderwriterNotRegistered();
        } else {
            _clearStaleCloseIfTerminal(commit.parentJobId);
            _validateCloseCommit(jobId, job, commit);
            parentJobIdByCloseJobId[jobId] = commit.parentJobId;
            activeCloseJobIdByParentJobId[commit.parentJobId] = jobId;
        }

        commitHashByJobId[jobId] = newCommitHash;
        committedBudgetByJobId[jobId] = amount;
        commits[jobId] = commit;
    }

    function _postSubmit(uint256 jobId, bytes32 deliverable, bytes memory optParams) internal view override {
        SubmitEvidence memory evidence = abi.decode(optParams, (SubmitEvidence));
        UnderwriteCommit memory commit = _requireCommit(jobId);

        if (deliverable != evidence.bundleHash) revert EvidenceMismatch();
        if (evidence.policyHash != commit.policyHash) revert EvidenceMismatch();
        if (evidence.quoteIdHash != commit.quoteIdHash) revert EvidenceMismatch();
    }

    function _postComplete(uint256 jobId, bytes32, bytes memory) internal override {
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

    function _postReject(uint256 jobId, bytes32, bytes memory) internal override {
        UnderwriteCommit memory commit = commits[jobId];
        if (commit.parentJobId != 0 && activeCloseJobIdByParentJobId[commit.parentJobId] == jobId) {
            delete activeCloseJobIdByParentJobId[commit.parentJobId];
        }
    }

    function _validateCloseCommit(uint256 jobId, AgenticCommerceHooked.Job memory job, UnderwriteCommit memory commit) internal view {
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

    function _clearStaleCloseIfTerminal(uint256 parentJobId) internal {
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

    function _consumeNonceAndVerifySigner(
        address expectedUnderwriter,
        uint256 nonce,
        bytes32 digest,
        bytes calldata signature
    ) internal {
        if (usedNonces[expectedUnderwriter][nonce]) revert NonceUsed(expectedUnderwriter, nonce);

        address recovered = ECDSA.recover(digest, signature);
        if (recovered != expectedUnderwriter || expectedUnderwriter == address(0)) {
            revert InvalidSigner(expectedUnderwriter, recovered);
        }

        usedNonces[expectedUnderwriter][nonce] = true;
    }
}
