# Underwriting Hook ACP/Core Sequence

This document mirrors the phased sequencing style used in `ERC-ACP`, but it
stays limited to the contracts that actually exist in `hook-contracts`.

- `AgenticCommerceHooked` owns job status changes plus budget escrow, payout,
  and refund.
- `UnderwritingHook` is both the ACP hook and the EIP-712 evaluator relay.
- `UnderwritingWorkflowCore` is an internal module behind the hook, not a
  separate user-facing contract.
- Out of scope here: underwriting premium, provider collateral, client
  principal deployment, dispute windows, and settlement sidecars.

## Implementation-Level Sequence Diagrams

### Root Job Admission and Decision

`parentJobId = 0`. This is the exact callback and helper flow for a root
underwriting job.

```mermaid
sequenceDiagram
    autonumber
    actor Admin
    actor Client
    actor Provider
    actor Underwriter
    actor Relayer
    participant ACP as ACP / AgenticCommerceHooked
    participant Hook as UnderwritingHook
    participant Workflow as UnderwritingWorkflowCore

    Note over Client,Underwriter: Resource model: one ACP job, one locked underwriting commit, no close linkage yet

    rect rgb(255, 236, 240)
        Note over Admin,Underwriter: Phase 0 - Setup
        Admin->>Hook: registerUnderwriter(underwriter)
        Hook->>Workflow: _registerUnderwriter(underwriter)
    end

    rect rgb(255, 236, 240)
        Note over Client,Underwriter: Phase 1 - Request and Commit Lock
        Client->>ACP: createJob(provider, evaluator=Hook, hook=Hook)
        Client->>ACP: setBudget(jobId, amount, abi.encode(commit))
        ACP->>Hook: beforeAction(jobId, setBudget, abi.encode(amount, commit))
        Hook->>Workflow: _preSetBudgetWorkflow(acp, address(this), jobId, amount, commit)
        Workflow->>ACP: getJob(jobId)
        ACP-->>Workflow: job metadata
        Workflow-->>Hook: require provider set, evaluator == Hook, registered underwriter, and validUntil in the future
        Workflow-->>Hook: lock commitHashByJobId, committedBudgetByJobId, and commits[jobId]
        Hook-->>ACP: allow setBudget
    end

    rect rgb(255, 236, 240)
        Note over Client,Underwriter: Phase 2 - Funding and Submission
        Client->>ACP: fund(jobId, amount, "")
        Note over ACP,Hook: UnderwritingHook does not override _preFund or _postFund
        Provider->>ACP: submit(jobId, bundleHash, abi.encode(evidence))
        ACP->>Hook: beforeAction(jobId, submit, data)
        Note over Hook: _preSubmit is a no-op in this hook
        ACP->>Hook: afterAction(jobId, submit, abi.encode(bundleHash, evidence))
        Hook->>Workflow: _postSubmitWorkflow(jobId, bundleHash, evidence)
        Workflow-->>Hook: require bundleHash, policyHash, and quoteIdHash to match the locked commit
        Hook-->>ACP: accept submit or revert
    end

    rect rgb(255, 236, 240)
        Note over Client,Underwriter: Phase 3 - Underwriter Decision
        Underwriter-->>Relayer: sign CompleteDecision or RejectDecision off-chain
        Relayer->>Hook: completeBySig(...) or rejectBySig(...)
        Hook->>ACP: getJob(jobId)
        ACP-->>Hook: job metadata
        Hook->>Workflow: _requireCommit(jobId)
        Workflow-->>Hook: committed underwriter and locked workflow state
        Hook->>Hook: verify deadline, nonce, and recovered signer
        Hook->>ACP: complete(jobId, reason, "") or reject(jobId, reason, "")
        ACP->>Hook: beforeAction(jobId, complete or reject, data)
        Note over Hook: _preComplete and _preReject are no-ops in this hook
        ACP->>ACP: mark Completed or Rejected and release or refund the budget
        ACP->>Hook: afterAction(jobId, complete or reject, data)
    end

    rect rgb(255, 236, 240)
        Note over Client,Underwriter: Phase 4 - Outcome
        alt root job approved with allowCloseJob = true
            Hook->>Workflow: _postCompleteWorkflow(jobId)
            Workflow-->>Hook: awaitingCloseByJobId[jobId] = true
        else single-stage approved
            Hook->>Workflow: _postCompleteWorkflow(jobId)
            Workflow-->>Hook: no parent or close linkage changes
        else root job rejected
            Hook->>Workflow: _postRejectWorkflow(jobId)
            Workflow-->>Hook: no parent or close linkage changes
        end
    end
```

### Close Job Extension

Precondition: the parent root job already completed and
`awaitingCloseByJobId[parentJobId] = true`.

```mermaid
sequenceDiagram
    autonumber
    actor Client
    actor Provider
    actor Underwriter
    actor Relayer
    participant ACP as ACP / AgenticCommerceHooked
    participant Hook as UnderwritingHook
    participant Workflow as UnderwritingWorkflowCore

    Note over Client,Underwriter: Resource model: the close job is a second ACP job that reuses the approved parent workflow

    rect rgb(255, 236, 240)
        Note over Client,Underwriter: Phase 1 - Close Admission
        Client->>ACP: createJob(provider, evaluator=Hook, hook=Hook)
        Client->>ACP: setBudget(closeJobId, closeAmount, abi.encode(closeCommit))
        ACP->>Hook: beforeAction(closeJobId, setBudget, abi.encode(closeAmount, closeCommit))
        Hook->>Workflow: _preSetBudgetWorkflow(acp, address(this), closeJobId, closeAmount, closeCommit)
        Workflow->>ACP: getJob(closeJobId)
        ACP-->>Workflow: close job metadata
        Workflow->>ACP: getJob(parentJobId)
        ACP-->>Workflow: parent job metadata
        Workflow-->>Hook: clear stale rejected or expired close linkage if needed
        Workflow-->>Hook: validate same actors, same hook, same underwriter, and parent Completed plus AwaitingClose
        Workflow-->>Hook: record parentJobIdByCloseJobId and activeCloseJobIdByParentJobId
        Hook-->>ACP: allow close setBudget
    end

    rect rgb(255, 236, 240)
        Note over Client,Underwriter: Phase 2 - Funding and Submission
        Client->>ACP: fund(closeJobId, closeAmount, "")
        Note over ACP,Hook: Close jobs still use the normal ACP funding rail
        Provider->>ACP: submit(closeJobId, closeBundleHash, abi.encode(closeEvidence))
        ACP->>Hook: beforeAction(closeJobId, submit, data)
        Note over Hook: _preSubmit remains a no-op here too
        ACP->>Hook: afterAction(closeJobId, submit, abi.encode(closeBundleHash, closeEvidence))
        Hook->>Workflow: _postSubmitWorkflow(closeJobId, closeBundleHash, closeEvidence)
        Workflow-->>Hook: require close evidence to match the locked close commit
    end

    rect rgb(255, 236, 240)
        Note over Client,Underwriter: Phase 3 - Decision and Parent State Update
        Underwriter-->>Relayer: sign close CompleteDecision or RejectDecision off-chain
        Relayer->>Hook: completeBySig(...) or rejectBySig(...)
        Hook->>ACP: getJob(closeJobId)
        ACP-->>Hook: close job metadata
        Hook->>Workflow: _requireCommit(closeJobId)
        Workflow-->>Hook: committed underwriter and locked close-stage state
        Hook->>Hook: verify deadline, nonce, and recovered signer
        Hook->>ACP: complete(closeJobId, reason, "") or reject(closeJobId, reason, "")
        ACP->>Hook: afterAction(closeJobId, complete or reject, data)
        alt close approved
            Hook->>Workflow: _postCompleteWorkflow(closeJobId)
            Workflow-->>Hook: clear activeCloseJobIdByParentJobId[parentJobId] and awaitingCloseByJobId[parentJobId]
        else close rejected
            Hook->>Workflow: _postRejectWorkflow(closeJobId)
            Workflow-->>Hook: clear activeCloseJobIdByParentJobId[parentJobId] only
        else close expires
            Client->>ACP: claimRefund(closeJobId)
            Note over ACP,Workflow: claimRefund is not hookable. The next close setBudget can lazily clear the stale slot if the expired close was still active
        end
    end
```

## Scope Notes

- The ACP budget is still the only token amount moved by these contracts.
- `UnderwritingHook` never pulls premium, collateral, or principal.
- `UnderwritingWorkflowCore` should be read as commit and lineage state only.
