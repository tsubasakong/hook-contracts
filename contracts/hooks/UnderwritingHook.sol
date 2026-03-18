// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "../AgenticCommerceHooked.sol";
import "../BaseACPHook.sol";
import "./UnderwritingWorkflowCore.sol";

/**
 * @title UnderwritingHook
 * @notice Experimental underwriting example whose top-level hook acts as the
 *         ACP-facing shell and evaluator relay, while `UnderwritingWorkflowCore`
 *         owns the internal underwriting workflow state.
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
 *  - a normal single-stage underwritten job (token swap,etc.), and
 *  - a two-stage underwritten flow (open/close position, Defi yield farming, etc.) where a parent job, once approved, may
 *    later admit one hook-linked close job under the same underwriter.
 *
 * FLOW (hook callbacks marked with →)
 * ----
 *  1. Hook admin registers an allowed underwriter signer.
 *  2. Client creates a job with `hook = this` and `evaluator = this`.
 *  3. Client calls `setBudget(jobId, amount, abi.encode(commit))`:
 *     → `_preSetBudget`: delegate into `UnderwritingWorkflowCore` to lock the
 *       committed underwriting terms and classify the job as:
 *         - `SingleStage`, or
 *         - `ParentPlusClose` when `allowCloseJob = true`.
 *  4. Client funds the job through the normal ACP flow.
 *  5. Provider submits `deliverable = evidence.bundleHash` with
 *     `optParams = abi.encode(SubmitEvidence)`:
 *     → `_postSubmit`: verify the submitted bundle, policy, and quote hashes
 *       against the committed underwriting terms.
 *  6. The underwriter signs either `CompleteDecision` or `RejectDecision`
 *     off-chain.
 *  7. Anyone may relay that signature via `completeBySig(...)` or
 *     `rejectBySig(...)`:
 *     → hook shell verifies deadline, nonce, and signer
 *     → ACP `complete()` or `reject()` finalizes the job.
 *  8. If the first job was committed with `allowCloseJob = true` and is
 *     approved:
 *     → `_postComplete`: mark the parent job `AwaitingClose`.
 *  9. A later close job is just another normal ACP `createJob(...)` call whose
 *     committed payload points back to the parent `jobId`:
 *     → `_preSetBudget`: validate same actors, same underwriter, and parent
 *       readiness before admitting the close stage.
 * 10. The close job then follows the same ACP rail:
 *     `setBudget -> fund -> submit -> completeBySig/rejectBySig`.
 *
 * RECOVERY
 * --------
 *  - close rejection: `_postReject` clears only the active close linkage so
 *    the parent may stay `AwaitingClose`.
 *  - close expiry: `claimRefund()` remains outside the hook surface; the next
 *    close commit lazily clears the stale close slot if the previous close job
 *    already reached `Expired`.
 *
 * KEY PROPERTY
 * ------------
 * ACP remains the generic escrow rail. `UnderwritingHook` is the ACP-facing
 * shell and evaluator relay, while `UnderwritingWorkflowCore` owns the internal
 * underwriting workflow state, including commit locking, parent/close linkage,
 * and close-stage admission rules.
 *
 * TRUST MODEL
 * -----------
 * ACP escrow behavior stays unchanged. This hook adds policy around who may
 * underwrite a job, what evidence must be submitted, and whether a later close
 * job is allowed. It reduces client risk from bad provider behavior by binding
 * payment release to an agreed underwriter decision and to committed evidence
 * hashes. Parent/close lineage is intentionally kept in hook state rather than
 * promoted into ACP core so this example can model a two-stage underwriting
 * flow without expanding the shared escrow kernel with workflow-specific
 * linkage primitives. This example is intentionally labeled
 * experimental rather than production-ready settlement infrastructure.
 */
contract UnderwritingHook is BaseACPHook, EIP712, UnderwritingWorkflowCore {
    bytes32 private constant COMPLETE_TYPEHASH =
        keccak256("CompleteDecision(uint256 jobId,bytes32 reason,uint64 deadline,uint256 nonce)");
    bytes32 private constant REJECT_TYPEHASH =
        keccak256("RejectDecision(uint256 jobId,bytes32 reason,uint64 deadline,uint256 nonce)");

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
    error WrongDecisionStatus();
    error DecisionExpired(uint64 deadline, uint64 currentTimestamp);
    error NonceUsed(address underwriter, uint256 nonce);
    error InvalidSigner(address expected, address actual);

    AgenticCommerceHooked public immutable acp;
    address public immutable admin;

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
        _registerUnderwriter(underwriter);
    }

    function unregisterUnderwriter(address underwriter) external onlyAdmin {
        _unregisterUnderwriter(underwriter);
    }

    function registeredUnderwriters(address underwriter) external view returns (bool) {
        return _isRegisteredUnderwriter(underwriter);
    }

    function getCommit(uint256 jobId) external view returns (UnderwriteCommit memory) {
        return _getCommit(jobId);
    }

    function isAwaitingClose(uint256 jobId) external view returns (bool) {
        return _isAwaitingClose(jobId);
    }

    function getParentJobId(uint256 closeJobId) external view returns (uint256) {
        return _getParentJobId(closeJobId);
    }

    function getActiveCloseJobId(uint256 parentJobId) external view returns (uint256) {
        return _getActiveCloseJobId(parentJobId);
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
        _preSetBudgetWorkflow(acp, address(this), jobId, amount, optParams);
    }

    function _postSubmit(uint256 jobId, bytes32 deliverable, bytes memory optParams) internal view override {
        _postSubmitWorkflow(jobId, deliverable, optParams);
    }

    function _postComplete(uint256 jobId, bytes32, bytes memory) internal override {
        _postCompleteWorkflow(jobId);
    }

    function _postReject(uint256 jobId, bytes32, bytes memory) internal override {
        _postRejectWorkflow(jobId);
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
