// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/UnderwritingHookTestBase.sol";

contract UnderwritingHookAdmissionTest is UnderwritingHookTestBase {
    function testConstructorRequiresNonZeroAdmin() public {
        vm.expectRevert(ERR_ZERO_ADDRESS);
        new UnderwritingHook(address(acp), address(0));
    }

    function testRegisterUnderwriterRejectsZeroAddress() public {
        vm.expectRevert(ERR_ZERO_ADDRESS);
        hook.registerUnderwriter(address(0));
    }

    function testFirstCommitRequiresRegisteredUnderwriter() public {
        uint256 jobId = _createBaseJob(address(hook), address(hook));

        vm.prank(client);
        vm.expectRevert(ERR_UNDERWRITER_NOT_REGISTERED);
        acp.setBudget(jobId, DEFAULT_BUDGET, abi.encode(_singleStageCommit()));
    }

    function testFirstCommitRequiresProviderAlreadySet() public {
        _registerUnderwriter();
        uint256 jobId = _createJobWithoutProvider(address(hook), address(hook));

        vm.prank(client);
        vm.expectRevert(ERR_PROVIDER_REQUIRED);
        acp.setBudget(jobId, DEFAULT_BUDGET, abi.encode(_singleStageCommit()));
    }

    function testFirstCommitRequiresEvaluatorToBeHook() public {
        _registerUnderwriter();
        uint256 jobId = _createBaseJob(address(hook), outsider);

        vm.prank(client);
        vm.expectRevert(ERR_EVALUATOR_MISMATCH);
        acp.setBudget(jobId, DEFAULT_BUDGET, abi.encode(_singleStageCommit()));
    }

    function testFirstCommitRequiresFutureValidityWindow() public {
        _registerUnderwriter();
        uint256 jobId = _createBaseJob(address(hook), address(hook));
        UnderwriteCommitData memory commit = _singleStageCommit();
        commit.validUntil = uint64(block.timestamp);

        vm.prank(client);
        vm.expectRevert(ERR_COMMIT_EXPIRED);
        acp.setBudget(jobId, DEFAULT_BUDGET, abi.encode(commit));
    }

    function testFirstCommitLocksBudgetAndPayload() public {
        _registerUnderwriter();
        uint256 jobId = _createBaseJob(address(hook), address(hook));
        UnderwriteCommitData memory commit = _singleStageCommit();

        _commitBudget(jobId, DEFAULT_BUDGET, commit);

        vm.prank(client);
        vm.expectRevert(ERR_COMMIT_LOCKED);
        acp.setBudget(jobId, DEFAULT_BUDGET + 1, abi.encode(commit));
    }

    function testSameBudgetReplayWithSamePayloadIsAllowed() public {
        _registerUnderwriter();
        uint256 jobId = _createBaseJob(address(hook), address(hook));
        UnderwriteCommitData memory commit = _singleStageCommit();

        _commitBudget(jobId, DEFAULT_BUDGET, commit);
        _commitBudget(jobId, DEFAULT_BUDGET, commit);

        assertEq(acp.getJob(jobId).budget, DEFAULT_BUDGET);
    }

    function testParentStageCompletionMarksAwaitingClose() public {
        uint256 parentJobId = _completeParentStageJob();

        assertTrue(hook.isAwaitingClose(parentJobId));
    }

    function testCloseCommitRequiresParentToAllowCloseJob() public {
        _registerUnderwriter();
        uint256 parentJobId = _createBaseJob(address(hook), address(hook));
        _commitBudget(parentJobId, DEFAULT_BUDGET, _singleStageCommit());
        _fundJob(parentJobId, DEFAULT_BUDGET);
        _submitEvidence(parentJobId, _matchingEvidence());

        vm.prank(address(hook));
        acp.complete(parentJobId, DEFAULT_REASON, "");

        uint256 closeJobId = _createBaseJob(address(hook), address(hook));

        vm.prank(client);
        vm.expectRevert(ERR_PARENT_MISMATCH);
        acp.setBudget(closeJobId, CLOSE_BUDGET, abi.encode(_closeStageCommit(parentJobId)));
    }

    function testCloseCommitRequiresParentAwaitingClose() public {
        _registerUnderwriter();
        uint256 parentJobId = _createBaseJob(address(hook), address(hook));
        _commitBudget(parentJobId, DEFAULT_BUDGET, _parentStageCommit());

        uint256 closeJobId = _createBaseJob(address(hook), address(hook));

        vm.prank(client);
        vm.expectRevert(ERR_PARENT_NOT_AWAITING_CLOSE);
        acp.setBudget(closeJobId, CLOSE_BUDGET, abi.encode(_closeStageCommit(parentJobId)));
    }

    function testCloseCommitStoresParentLinkage() public {
        uint256 parentJobId = _completeParentStageJob();

        uint256 closeJobId = _createBaseJob(address(hook), address(hook));
        _commitBudget(closeJobId, CLOSE_BUDGET, _closeStageCommit(parentJobId));

        assertEq(hook.getParentJobId(closeJobId), parentJobId);
        assertEq(hook.getActiveCloseJobId(parentJobId), closeJobId);
    }

    function testCloseCommitRequiresSameUnderwriterAsParent() public {
        uint256 parentJobId = _completeParentStageJob();
        uint256 closeJobId = _createBaseJob(address(hook), address(hook));

        UnderwriteCommitData memory closeCommit = _closeStageCommit(parentJobId);
        closeCommit.underwriter = outsider;

        vm.prank(client);
        vm.expectRevert(ERR_PARENT_MISMATCH);
        acp.setBudget(closeJobId, CLOSE_BUDGET, abi.encode(closeCommit));
    }

    function testCloseCommitRequiresSameActorsAsParent() public {
        uint256 parentJobId = _completeParentStageJob();
        uint256 closeJobId = _createJobWithProvider(outsider, address(hook), address(hook));

        vm.prank(client);
        vm.expectRevert(ERR_PARENT_MISMATCH);
        acp.setBudget(closeJobId, CLOSE_BUDGET, abi.encode(_closeStageCommit(parentJobId)));
    }

    function testSecondActiveCloseJobIsBlocked() public {
        uint256 parentJobId = _completeParentStageJob();
        uint256 firstCloseJobId = _createBaseJob(address(hook), address(hook));
        _commitBudget(firstCloseJobId, CLOSE_BUDGET, _closeStageCommit(parentJobId));

        uint256 secondCloseJobId = _createBaseJob(address(hook), address(hook));

        vm.prank(client);
        vm.expectRevert(ERR_ACTIVE_CLOSE_EXISTS);
        acp.setBudget(secondCloseJobId, CLOSE_BUDGET, abi.encode(_closeStageCommit(parentJobId)));
    }
}
