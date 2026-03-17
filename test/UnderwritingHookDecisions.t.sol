// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/UnderwritingHookTestBase.sol";

contract UnderwritingHookDecisionsTest is UnderwritingHookTestBase {
    function testSubmitRevertsOnBundleMismatch() public {
        _registerUnderwriter();
        uint256 jobId = _createBaseJob(address(hook), address(hook));
        _commitBudget(jobId, DEFAULT_BUDGET, _singleStageCommit());
        _fundJob(jobId, DEFAULT_BUDGET);

        vm.prank(provider);
        vm.expectRevert(UnderwritingHook.EvidenceMismatch.selector);
        acp.submit(jobId, keccak256("deliverable"), abi.encode(_mismatchedEvidence()));
    }

    function testSubmitRevertsOnPolicyMismatch() public {
        _registerUnderwriter();
        uint256 jobId = _createBaseJob(address(hook), address(hook));
        _commitBudget(jobId, DEFAULT_BUDGET, _singleStageCommit());
        _fundJob(jobId, DEFAULT_BUDGET);

        UnderwritingHook.SubmitEvidence memory evidence = _matchingEvidence();
        evidence.policyHash = keccak256("wrong-policy");

        vm.prank(provider);
        vm.expectRevert(UnderwritingHook.EvidenceMismatch.selector);
        acp.submit(jobId, evidence.bundleHash, abi.encode(evidence));
    }

    function testSubmitRevertsOnQuoteIdMismatch() public {
        _registerUnderwriter();
        uint256 jobId = _createBaseJob(address(hook), address(hook));
        _commitBudget(jobId, DEFAULT_BUDGET, _singleStageCommit());
        _fundJob(jobId, DEFAULT_BUDGET);

        UnderwritingHook.SubmitEvidence memory evidence = _matchingEvidence();
        evidence.quoteIdHash = keccak256("wrong-quote");

        vm.prank(provider);
        vm.expectRevert(UnderwritingHook.EvidenceMismatch.selector);
        acp.submit(jobId, evidence.bundleHash, abi.encode(evidence));
    }

    function testCompleteBySigSucceedsForSubmittedSingleStageJob() public {
        _registerUnderwriter();
        uint256 jobId = _createBaseJob(address(hook), address(hook));
        _commitBudget(jobId, DEFAULT_BUDGET, _singleStageCommit());
        _fundJob(jobId, DEFAULT_BUDGET);
        _submitEvidence(jobId, _matchingEvidence());

        (UnderwritingHook.CompleteDecision memory decision, bytes memory signature) =
            _signedCompleteDecision(jobId, UNDERWRITER_PK);

        hook.completeBySig(decision, signature);

        assertEq(uint256(acp.getJob(jobId).status), uint256(AgenticCommerceHooked.JobStatus.Completed));
    }

    function testCompleteBySigOnParentStageMarksAwaitingClose() public {
        _registerUnderwriter();
        uint256 jobId = _createBaseJob(address(hook), address(hook));
        _commitBudget(jobId, DEFAULT_BUDGET, _parentStageCommit());
        _fundJob(jobId, DEFAULT_BUDGET);
        _submitEvidence(jobId, _matchingEvidence());

        (UnderwritingHook.CompleteDecision memory decision, bytes memory signature) =
            _signedCompleteDecision(jobId, UNDERWRITER_PK);

        hook.completeBySig(decision, signature);

        assertTrue(hook.isAwaitingClose(jobId));
    }

    function testCompleteBySigRejectsNonSubmittedJob() public {
        _registerUnderwriter();
        uint256 jobId = _createBaseJob(address(hook), address(hook));
        _commitBudget(jobId, DEFAULT_BUDGET, _singleStageCommit());
        _fundJob(jobId, DEFAULT_BUDGET);

        (UnderwritingHook.CompleteDecision memory decision, bytes memory signature) =
            _signedCompleteDecision(jobId, UNDERWRITER_PK);

        vm.expectRevert(UnderwritingHook.WrongDecisionStatus.selector);
        hook.completeBySig(decision, signature);
    }

    function testRejectBySigSucceedsForSubmittedCloseStageJob() public {
        uint256 parentJobId = _completeParentStageJob();
        uint256 closeJobId = _createAndSubmitCloseJob(parentJobId);

        (UnderwritingHook.RejectDecision memory decision, bytes memory signature) =
            _signedRejectDecision(closeJobId, UNDERWRITER_PK);

        hook.rejectBySig(decision, signature);

        assertEq(uint256(acp.getJob(closeJobId).status), uint256(AgenticCommerceHooked.JobStatus.Rejected));
    }

    function testRejectBySigRejectsInvalidSigner() public {
        _registerUnderwriter();
        uint256 jobId = _createBaseJob(address(hook), address(hook));
        _commitBudget(jobId, DEFAULT_BUDGET, _singleStageCommit());
        _fundJob(jobId, DEFAULT_BUDGET);
        _submitEvidence(jobId, _matchingEvidence());

        (UnderwritingHook.RejectDecision memory decision, bytes memory signature) =
            _signedRejectDecision(jobId, OUTSIDER_PK);

        vm.expectRevert(abi.encodeWithSelector(UnderwritingHook.InvalidSigner.selector, underwriter, outsider));
        hook.rejectBySig(decision, signature);
    }

    function testCompleteBySigRejectsInvalidSigner() public {
        _registerUnderwriter();
        uint256 jobId = _createBaseJob(address(hook), address(hook));
        _commitBudget(jobId, DEFAULT_BUDGET, _singleStageCommit());
        _fundJob(jobId, DEFAULT_BUDGET);
        _submitEvidence(jobId, _matchingEvidence());

        (UnderwritingHook.CompleteDecision memory decision, bytes memory signature) =
            _signedCompleteDecision(jobId, OUTSIDER_PK);

        vm.expectRevert(abi.encodeWithSelector(UnderwritingHook.InvalidSigner.selector, underwriter, outsider));
        hook.completeBySig(decision, signature);
    }

    function testCompleteBySigRejectsUsedNonce() public {
        _registerUnderwriter();
        uint256 jobId = _createBaseJob(address(hook), address(hook));
        _commitBudget(jobId, DEFAULT_BUDGET, _singleStageCommit());
        _fundJob(jobId, DEFAULT_BUDGET);
        _submitEvidence(jobId, _matchingEvidence());

        (UnderwritingHook.CompleteDecision memory decision, bytes memory signature) =
            _signedCompleteDecision(jobId, UNDERWRITER_PK);

        hook.completeBySig(decision, signature);

        uint256 retryJobId = _createBaseJob(address(hook), address(hook));
        _commitBudget(retryJobId, DEFAULT_BUDGET, _singleStageCommit());
        _fundJob(retryJobId, DEFAULT_BUDGET);
        _submitEvidence(retryJobId, _matchingEvidence());

        decision.jobId = retryJobId;
        bytes32 structHash =
            keccak256(abi.encode(COMPLETE_TYPEHASH, decision.jobId, decision.reason, decision.deadline, decision.nonce));
        signature = _signDigest(UNDERWRITER_PK, _hashTypedDataV4(structHash));

        vm.expectRevert(abi.encodeWithSelector(UnderwritingHook.NonceUsed.selector, underwriter, decision.nonce));
        hook.completeBySig(decision, signature);
    }

    function testCompleteBySigRejectsExpiredDecision() public {
        _registerUnderwriter();
        uint256 jobId = _createBaseJob(address(hook), address(hook));
        _commitBudget(jobId, DEFAULT_BUDGET, _singleStageCommit());
        _fundJob(jobId, DEFAULT_BUDGET);
        _submitEvidence(jobId, _matchingEvidence());

        UnderwritingHook.CompleteDecision memory decision = UnderwritingHook.CompleteDecision({
            jobId: jobId,
            reason: DEFAULT_REASON,
            deadline: uint64(block.timestamp - 1),
            nonce: 7
        });
        bytes32 structHash =
            keccak256(abi.encode(COMPLETE_TYPEHASH, decision.jobId, decision.reason, decision.deadline, decision.nonce));
        bytes memory signature = _signDigest(UNDERWRITER_PK, _hashTypedDataV4(structHash));

        vm.expectRevert(
            abi.encodeWithSelector(UnderwritingHook.DecisionExpired.selector, decision.deadline, uint64(block.timestamp))
        );
        hook.completeBySig(decision, signature);
    }

    function testCloseCompletionClearsParentLinkage() public {
        uint256 parentJobId = _completeParentStageJob();
        uint256 closeJobId = _createAndSubmitCloseJob(parentJobId);

        (UnderwritingHook.CompleteDecision memory decision, bytes memory signature) =
            _signedCompleteDecision(closeJobId, UNDERWRITER_PK);

        hook.completeBySig(decision, signature);

        assertEq(hook.getActiveCloseJobId(parentJobId), 0);
        assertFalse(hook.isAwaitingClose(parentJobId));
    }

    function testCloseRejectClearsOnlyActiveCloseSlot() public {
        uint256 parentJobId = _completeParentStageJob();
        uint256 closeJobId = _createAndSubmitCloseJob(parentJobId);

        (UnderwritingHook.RejectDecision memory decision, bytes memory signature) =
            _signedRejectDecision(closeJobId, UNDERWRITER_PK);

        hook.rejectBySig(decision, signature);

        assertEq(hook.getActiveCloseJobId(parentJobId), 0);
        assertTrue(hook.isAwaitingClose(parentJobId));
    }

    function testExpiredCloseCanBeReplacedOnNextCommit() public {
        uint256 parentJobId = _completeParentStageJob();
        uint256 firstCloseJobId = _createBaseJob(address(hook), address(hook));
        _commitBudget(firstCloseJobId, CLOSE_BUDGET, _closeStageCommit(parentJobId));
        _fundJob(firstCloseJobId, CLOSE_BUDGET);

        vm.warp(acp.getJob(firstCloseJobId).expiredAt + 1);
        acp.claimRefund(firstCloseJobId);

        uint256 replacementCloseJobId = _createBaseJob(address(hook), address(hook));
        _commitBudget(replacementCloseJobId, CLOSE_BUDGET, _closeStageCommit(parentJobId));

        assertEq(hook.getActiveCloseJobId(parentJobId), replacementCloseJobId);
    }
}
