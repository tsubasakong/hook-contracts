# Underwriting Hook ACP/Core Sequence

This sequence focuses on the on-chain interaction boundary between:

- `AgenticCommerceHooked` as the ACP core escrow rail
- `UnderwritingHook` as the ACP-facing hook and evaluator relay
- `UnderwritingWorkflowCore` as the hook-owned underwriting workflow state

It intentionally omits the larger MCU sidecars and shows only the callbacks and
state transitions that this underwriting example actually uses.

```mermaid
sequenceDiagram
    autonumber
    actor Admin
    actor Client
    actor Provider
    actor Underwriter
    actor Relayer
    participant ACP as AgenticCommerceHooked
    participant Hook as UnderwritingHook
    participant Workflow as UnderwritingWorkflowCore

    Note over ACP,Workflow: Job is created with hook = UnderwritingHook and evaluator = UnderwritingHook.

    Admin->>Hook: registerUnderwriter(underwriter)
    Hook->>Workflow: _registerUnderwriter(underwriter)

    Client->>ACP: createJob(provider, evaluator=Hook, hook=Hook)
    Note over ACP,Hook: createJob stores hook/evaluator but does not call hook callbacks.

    Client->>ACP: setBudget(jobId, amount, abi.encode(commit))
    ACP->>Hook: beforeAction(jobId, setBudget, abi.encode(amount, commit))
    Hook->>Workflow: _preSetBudgetWorkflow(acp, address(this), jobId, amount, commit)
    Workflow->>ACP: getJob(jobId)
    ACP-->>Workflow: job metadata

    alt First-stage job
        Workflow-->>Hook: Require provider set, evaluator == Hook, underwriter registered, and commit not expired.<br/>Lock commit hash, budget, and commit payload.
    else Close job
        Workflow->>ACP: getJob(parentJobId)
        ACP-->>Workflow: parent job metadata
        Workflow-->>Hook: Clear stale rejected/expired close if needed.<br/>Validate same actors, same underwriter, parent Completed + AwaitingClose.<br/>Store parent/active-close linkage.
    end

    Hook-->>ACP: allow setBudget
    Note over ACP,Hook: fund() still follows the ACP lifecycle, but UnderwritingHook does not add extra fund logic.

    Provider->>ACP: submit(jobId, bundleHash, abi.encode(evidence))
    Note over ACP,Hook: ACP also calls beforeAction on submit. UnderwritingHook leaves _preSubmit as a no-op.
    ACP->>Hook: afterAction(jobId, submit, abi.encode(bundleHash, evidence))
    Hook->>Workflow: _postSubmitWorkflow(jobId, bundleHash, evidence)
    Workflow-->>Hook: Load locked commit and verify bundleHash, policyHash, and quoteIdHash.
    Hook-->>ACP: accept submit or revert

    Underwriter-->>Relayer: Sign CompleteDecision or RejectDecision off-chain
    Relayer->>Hook: completeBySig(...) or rejectBySig(...)
    Hook->>ACP: getJob(jobId)
    ACP-->>Hook: job metadata
    Hook->>Workflow: _requireCommit(jobId)
    Workflow-->>Hook: committed underwriter and workflow state
    Hook->>Hook: Verify deadline, nonce, and recovered signer
    Hook->>ACP: complete(jobId, reason, "") or reject(jobId, reason, "")

    ACP->>Hook: beforeAction(jobId, complete/reject, ...)
    Note right of Hook: UnderwritingHook does not override _preComplete or _preReject.
    ACP->>ACP: Mark job Completed or Rejected.<br/>Release payment or refund from core escrow.
    ACP->>Hook: afterAction(jobId, complete/reject, ...)

    alt Parent completed with allowCloseJob = true
        Hook->>Workflow: _postCompleteWorkflow(parentJobId)
        Workflow-->>Hook: awaitingCloseByJobId[parentJobId] = true
        Note over Client,Workflow: A later close job repeats the same setBudget -> submit -> decision rail,<br/>but its commit includes parentJobId.
    else Close completed
        Hook->>Workflow: _postCompleteWorkflow(closeJobId)
        Workflow-->>Hook: Clear activeClose and clear parent AwaitingClose.
    else Close rejected
        Hook->>Workflow: _postRejectWorkflow(closeJobId)
        Workflow-->>Hook: Clear activeClose only. Parent stays AwaitingClose.
    else First-stage rejected or single-stage completed
        Hook->>Workflow: _postRejectWorkflow(jobId) or _postCompleteWorkflow(jobId)
        Workflow-->>Hook: No parent/close linkage change.
    end

    Note over ACP,Workflow: claimRefund() is not hookable. If a close job expires, the next close setBudget lazily clears stale activeClose state.
```

## Reading The Diagram

- `UnderwritingHook` is both the ACP `hook` and the ACP `evaluator`, so it can
  relay an off-chain underwriter signature into ACP `complete()` or `reject()`.
- `UnderwritingWorkflowCore` owns commit locking, evidence validation, and the
  optional parent/close linkage state, while ACP still owns escrow and status
  transitions.
- The optional close job is not a special ACP primitive. It is just another ACP
  job whose committed payload points back to the approved parent job.
- `claimRefund()` stays outside the hook callback surface, so expired close jobs
  are cleaned up lazily on the next close `setBudget(...)`.
