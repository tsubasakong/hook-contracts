// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/UnderwritingHookTestBase.sol";
import "../contracts/hooks/UnderwritingEvaluator.sol";
import "../contracts/hooks/UnderwritingTypes.sol";

contract UnderwritingHookDecisionsTest is UnderwritingHookTestBase {
    function testCoordinatorMarksJobProtectedAfterFunding() public {
        _registerUnderwriter();
        uint256 jobId = _createBaseJob(address(hook), address(evaluator));
        _commitBudget(jobId, DEFAULT_BUDGET, _singleStageCommit());
        _fundJob(jobId, DEFAULT_BUDGET);

        _protectJob(jobId);

        assertEq(uint256(hook.jobSidecarState(jobId)), uint256(UnderwritingTypes.SidecarState.Protected));
    }

    function testSubmitRequiresProtectedState() public {
        _registerUnderwriter();
        uint256 jobId = _createBaseJob(address(hook), address(evaluator));
        _commitBudget(jobId, DEFAULT_BUDGET, _singleStageCommit());
        _fundJob(jobId, DEFAULT_BUDGET);

        vm.prank(provider);
        vm.expectRevert(ERR_INVALID_STATE);
        acp.submit(jobId, _matchingEvidence().bundleHash, abi.encode(_matchingEvidence()));
    }

    function testCommittedRootJobCanBeRejectedWhileOpen() public {
        _registerUnderwriter();
        uint256 jobId = _createBaseJob(address(hook), address(evaluator));
        _commitBudget(jobId, DEFAULT_BUDGET, _singleStageCommit());

        vm.prank(client);
        acp.reject(jobId, DEFAULT_REJECT_REASON, "");

        assertEq(uint256(acp.getJob(jobId).status), uint256(AgenticCommerceHooked.JobStatus.Rejected));
        assertEq(uint256(hook.jobSidecarState(jobId)), uint256(UnderwritingTypes.SidecarState.RejectSettled));
    }

    function testOpenCloseRejectClearsReservedCloseSlot() public {
        uint256 parentJobId = _completeParentStageJob();
        uint256 closeJobId = _createBaseJob(address(hook), address(evaluator));
        _commitBudget(closeJobId, CLOSE_BUDGET, _closeStageCommit(parentJobId));

        vm.prank(client);
        acp.reject(closeJobId, DEFAULT_REJECT_REASON, "");

        assertEq(uint256(acp.getJob(closeJobId).status), uint256(AgenticCommerceHooked.JobStatus.Rejected));
        assertEq(uint256(hook.jobSidecarState(closeJobId)), uint256(UnderwritingTypes.SidecarState.RejectSettled));
        assertEq(hook.getActiveCloseJobId(parentJobId), 0);
        assertTrue(hook.isAwaitingClose(parentJobId));
    }

    function testSubmitRevertsOnBundleMismatch() public {
        _registerUnderwriter();
        uint256 jobId = _createBaseJob(address(hook), address(evaluator));
        _commitBudget(jobId, DEFAULT_BUDGET, _singleStageCommit());
        _fundJob(jobId, DEFAULT_BUDGET);
        _protectJob(jobId);

        vm.prank(provider);
        vm.expectRevert(ERR_EVIDENCE_MISMATCH);
        acp.submit(jobId, keccak256("deliverable"), abi.encode(_mismatchedEvidence()));
    }

    function testSubmitRevertsOnPolicyMismatch() public {
        _registerUnderwriter();
        uint256 jobId = _createBaseJob(address(hook), address(evaluator));
        _commitBudget(jobId, DEFAULT_BUDGET, _singleStageCommit());
        _fundJob(jobId, DEFAULT_BUDGET);
        _protectJob(jobId);

        UnderwritingTypes.SubmitEvidence memory evidence = _matchingEvidence();
        evidence.policyHash = keccak256("wrong-policy");

        vm.prank(provider);
        vm.expectRevert(ERR_EVIDENCE_MISMATCH);
        acp.submit(jobId, evidence.bundleHash, abi.encode(evidence));
    }

    function testSubmitRevertsOnQuoteIdMismatch() public {
        _registerUnderwriter();
        uint256 jobId = _createBaseJob(address(hook), address(evaluator));
        _commitBudget(jobId, DEFAULT_BUDGET, _singleStageCommit());
        _fundJob(jobId, DEFAULT_BUDGET);
        _protectJob(jobId);

        UnderwritingTypes.SubmitEvidence memory evidence = _matchingEvidence();
        evidence.quoteIdHash = keccak256("wrong-quote");

        vm.prank(provider);
        vm.expectRevert(ERR_EVIDENCE_MISMATCH);
        acp.submit(jobId, evidence.bundleHash, abi.encode(evidence));
    }

    function testCompleteBySigSucceedsForSubmittedSingleStageJob() public {
        _registerUnderwriter();
        uint256 jobId = _createBaseJob(address(hook), address(evaluator));
        _commitBudget(jobId, DEFAULT_BUDGET, _singleStageCommit());
        _fundJob(jobId, DEFAULT_BUDGET);
        _protectJob(jobId);
        _submitEvidence(jobId, _matchingEvidence());

        (UnderwritingTypes.CompleteDecision memory decision, bytes memory signature) =
            _signedCompleteDecision(jobId, UNDERWRITER_PK);

        evaluator.completeBySig(decision, signature);

        assertEq(uint256(acp.getJob(jobId).status), uint256(AgenticCommerceHooked.JobStatus.Completed));
        assertEq(
            uint256(hook.jobSidecarState(jobId)), uint256(UnderwritingTypes.SidecarState.SuccessPendingConfirmation)
        );
    }

    function testCompleteBySigOnParentStageMarksAwaitingClose() public {
        _registerUnderwriter();
        uint256 jobId = _createBaseJob(address(hook), address(evaluator));
        _commitBudget(jobId, DEFAULT_BUDGET, _parentStageCommit());
        _fundJob(jobId, DEFAULT_BUDGET);
        _protectJob(jobId);
        _submitEvidence(jobId, _matchingEvidence());

        (UnderwritingTypes.CompleteDecision memory decision, bytes memory signature) =
            _signedCompleteDecision(jobId, UNDERWRITER_PK);

        evaluator.completeBySig(decision, signature);

        assertTrue(hook.isAwaitingClose(jobId));
        assertEq(uint256(hook.jobSidecarState(jobId)), uint256(UnderwritingTypes.SidecarState.AwaitingClose));
    }

    function testCompleteBySigRejectsNonSubmittedJob() public {
        _registerUnderwriter();
        uint256 jobId = _createBaseJob(address(hook), address(evaluator));
        _commitBudget(jobId, DEFAULT_BUDGET, _singleStageCommit());
        _fundJob(jobId, DEFAULT_BUDGET);

        (UnderwritingTypes.CompleteDecision memory decision, bytes memory signature) =
            _signedCompleteDecision(jobId, UNDERWRITER_PK);

        vm.expectRevert(UnderwritingEvaluator.WrongDecisionStatus.selector);
        evaluator.completeBySig(decision, signature);
    }

    function testRejectBySigSucceedsForSubmittedCloseStageJob() public {
        uint256 parentJobId = _completeParentStageJob();
        uint256 closeJobId = _createAndSubmitCloseJob(parentJobId);

        (UnderwritingTypes.RejectDecision memory decision, bytes memory signature) =
            _signedRejectDecision(closeJobId, UNDERWRITER_PK);

        evaluator.rejectBySig(decision, signature);

        assertEq(uint256(acp.getJob(closeJobId).status), uint256(AgenticCommerceHooked.JobStatus.Rejected));
        assertEq(uint256(hook.jobSidecarState(closeJobId)), uint256(UnderwritingTypes.SidecarState.RejectSettled));
    }

    function testRejectBySigRejectsInvalidSigner() public {
        _registerUnderwriter();
        uint256 jobId = _createBaseJob(address(hook), address(evaluator));
        _commitBudget(jobId, DEFAULT_BUDGET, _singleStageCommit());
        _fundJob(jobId, DEFAULT_BUDGET);
        _protectJob(jobId);
        _submitEvidence(jobId, _matchingEvidence());

        (UnderwritingTypes.RejectDecision memory decision, bytes memory signature) =
            _signedRejectDecision(jobId, OUTSIDER_PK);

        vm.expectRevert(abi.encodeWithSelector(UnderwritingEvaluator.InvalidSigner.selector, underwriter, outsider));
        evaluator.rejectBySig(decision, signature);
    }

    function testCompleteBySigRejectsInvalidSigner() public {
        _registerUnderwriter();
        uint256 jobId = _createBaseJob(address(hook), address(evaluator));
        _commitBudget(jobId, DEFAULT_BUDGET, _singleStageCommit());
        _fundJob(jobId, DEFAULT_BUDGET);
        _protectJob(jobId);
        _submitEvidence(jobId, _matchingEvidence());

        (UnderwritingTypes.CompleteDecision memory decision, bytes memory signature) =
            _signedCompleteDecision(jobId, OUTSIDER_PK);

        vm.expectRevert(abi.encodeWithSelector(UnderwritingEvaluator.InvalidSigner.selector, underwriter, outsider));
        evaluator.completeBySig(decision, signature);
    }

    function testCompleteBySigRejectsUsedNonce() public {
        _registerUnderwriter();
        uint256 jobId = _createBaseJob(address(hook), address(evaluator));
        _commitBudget(jobId, DEFAULT_BUDGET, _singleStageCommit());
        _fundJob(jobId, DEFAULT_BUDGET);
        _protectJob(jobId);
        _submitEvidence(jobId, _matchingEvidence());

        (UnderwritingTypes.CompleteDecision memory decision, bytes memory signature) =
            _signedCompleteDecision(jobId, UNDERWRITER_PK);

        evaluator.completeBySig(decision, signature);

        uint256 retryJobId = _createBaseJob(address(hook), address(evaluator));
        _commitBudget(retryJobId, DEFAULT_BUDGET, _singleStageCommit());
        _fundJob(retryJobId, DEFAULT_BUDGET);
        _protectJob(retryJobId);
        _submitEvidence(retryJobId, _matchingEvidence());

        decision.jobId = retryJobId;
        bytes32 structHash =
            keccak256(abi.encode(COMPLETE_TYPEHASH, decision.jobId, decision.reason, decision.deadline, decision.nonce));
        signature = _signDigest(UNDERWRITER_PK, _hashTypedDataV4(structHash));

        vm.expectRevert(abi.encodeWithSelector(UnderwritingEvaluator.NonceUsed.selector, underwriter, decision.nonce));
        evaluator.completeBySig(decision, signature);
    }

    function testCompleteBySigRejectsExpiredDecision() public {
        _registerUnderwriter();
        uint256 jobId = _createBaseJob(address(hook), address(evaluator));
        _commitBudget(jobId, DEFAULT_BUDGET, _singleStageCommit());
        _fundJob(jobId, DEFAULT_BUDGET);
        _protectJob(jobId);
        _submitEvidence(jobId, _matchingEvidence());

        UnderwritingTypes.CompleteDecision memory decision = UnderwritingTypes.CompleteDecision({
            jobId: jobId,
            reason: DEFAULT_REASON,
            deadline: uint64(block.timestamp - 1),
            nonce: 7
        });
        bytes32 structHash =
            keccak256(abi.encode(COMPLETE_TYPEHASH, decision.jobId, decision.reason, decision.deadline, decision.nonce));
        bytes memory signature = _signDigest(UNDERWRITER_PK, _hashTypedDataV4(structHash));

        vm.expectRevert(
            abi.encodeWithSelector(
                UnderwritingEvaluator.DecisionExpired.selector, decision.deadline, uint64(block.timestamp)
            )
        );
        evaluator.completeBySig(decision, signature);
    }

    function testCloseCompletionClearsParentLinkage() public {
        uint256 parentJobId = _completeParentStageJob();
        uint256 closeJobId = _createAndSubmitCloseJob(parentJobId);

        (UnderwritingTypes.CompleteDecision memory decision, bytes memory signature) =
            _signedCompleteDecision(closeJobId, UNDERWRITER_PK);

        evaluator.completeBySig(decision, signature);

        assertEq(hook.getActiveCloseJobId(parentJobId), 0);
        assertFalse(hook.isAwaitingClose(parentJobId));
        assertEq(
            uint256(hook.jobSidecarState(closeJobId)), uint256(UnderwritingTypes.SidecarState.SuccessPendingConfirmation)
        );
    }

    function testCloseRejectClearsOnlyActiveCloseSlot() public {
        uint256 parentJobId = _completeParentStageJob();
        uint256 closeJobId = _createAndSubmitCloseJob(parentJobId);

        (UnderwritingTypes.RejectDecision memory decision, bytes memory signature) =
            _signedRejectDecision(closeJobId, UNDERWRITER_PK);

        evaluator.rejectBySig(decision, signature);

        assertEq(hook.getActiveCloseJobId(parentJobId), 0);
        assertTrue(hook.isAwaitingClose(parentJobId));
    }

    function testExpiredCloseCanBeReplacedOnNextCommit() public {
        uint256 parentJobId = _completeParentStageJob();
        uint256 firstCloseJobId = _createBaseJob(address(hook), address(evaluator));
        _commitBudget(firstCloseJobId, CLOSE_BUDGET, _closeStageCommit(parentJobId));
        _fundJob(firstCloseJobId, CLOSE_BUDGET);

        vm.warp(acp.getJob(firstCloseJobId).expiredAt + 1);
        acp.claimRefund(firstCloseJobId);

        uint256 replacementCloseJobId = _createBaseJob(address(hook), address(evaluator));
        _commitBudget(replacementCloseJobId, CLOSE_BUDGET, _closeStageCommit(parentJobId));

        assertEq(hook.getActiveCloseJobId(parentJobId), replacementCloseJobId);
    }
}
