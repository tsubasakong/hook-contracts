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

To keep GitHub rendering readable, this page splits the implementation flow into
smaller diagrams with fewer lanes and shorter labels.

## Implementation-Level Sequence Diagrams

### 1. Underwriter Setup

```mermaid
sequenceDiagram
    autonumber
    actor Admin
    participant Hook as UnderwritingHook
    participant Flow as WorkflowCore

    Admin->>Hook: registerUnderwriter(underwriter)
    Hook->>Flow: _registerUnderwriter(underwriter)
```

### 2. Root Job Commit Lock

The job is first created with `hook = Hook` and `evaluator = Hook`. The actual
underwriting admission happens on the first `setBudget(...)`.

```mermaid
sequenceDiagram
    autonumber
    actor Client
    participant ACP as ACP
    participant Hook as UnderwritingHook
    participant Flow as WorkflowCore

    Client->>ACP: setBudget(jobId, amount, commit)
    ACP->>Hook: beforeAction(setBudget)
    Hook->>Flow: _preSetBudgetWorkflow(...)
    Flow->>ACP: getJob(jobId)
    ACP-->>Flow: job metadata
    Flow-->>Hook: validate provider, evaluator, underwriter, and validUntil
    Flow-->>Hook: store commit hash, budget, and commit
    Hook-->>ACP: allow setBudget
```

### 3. Root Job Submission

`UnderwritingHook` does not implement `_preSubmit`, so the real underwriting
check runs after ACP records the submission.

```mermaid
sequenceDiagram
    autonumber
    actor Provider
    participant ACP as ACP
    participant Hook as UnderwritingHook
    participant Flow as WorkflowCore

    Provider->>ACP: submit(jobId, bundleHash, evidence)
    ACP->>Hook: beforeAction(submit)
    Hook-->>ACP: no-op
    ACP->>Hook: afterAction(submit)
    Hook->>Flow: _postSubmitWorkflow(...)
    Flow-->>Hook: require bundleHash, policyHash, and quoteIdHash to match
    Hook-->>ACP: accept submit or revert
```

### 4. Root Job Decision

For readability, this diagram shows the `Client` relaying the signature, though
any caller may relay `completeBySig(...)` or `rejectBySig(...)`.

```mermaid
sequenceDiagram
    autonumber
    actor Client
    actor Underwriter
    participant ACP as ACP
    participant Hook as UnderwritingHook
    participant Flow as WorkflowCore

    Underwriter-->>Client: sign CompleteDecision or RejectDecision
    Client->>Hook: completeBySig(...) or rejectBySig(...)
    Hook->>ACP: getJob(jobId)
    ACP-->>Hook: job metadata
    Hook->>Flow: _requireCommit(jobId)
    Flow-->>Hook: committed underwriter
    Hook->>Hook: verify deadline, nonce, and signer
    Hook->>ACP: complete(jobId, ...) or reject(jobId, ...)
    ACP->>Hook: beforeAction(complete or reject)
    Hook-->>ACP: no-op
    ACP->>Hook: afterAction(complete or reject)
    alt approved with allowCloseJob
        Hook->>Flow: _postCompleteWorkflow(jobId)
        Flow-->>Hook: mark AwaitingClose
    else approved single-stage
        Hook->>Flow: _postCompleteWorkflow(jobId)
        Flow-->>Hook: no linkage change
    else rejected
        Hook->>Flow: _postRejectWorkflow(jobId)
        Flow-->>Hook: no linkage change
    end
```

### 5. Close Job Admission

Precondition: `awaitingCloseByJobId[parentJobId] = true`.

```mermaid
sequenceDiagram
    autonumber
    actor Client
    participant ACP as ACP
    participant Hook as UnderwritingHook
    participant Flow as WorkflowCore

    Client->>ACP: setBudget(closeJobId, closeAmount, closeCommit)
    ACP->>Hook: beforeAction(setBudget)
    Hook->>Flow: _preSetBudgetWorkflow(...)
    Flow->>ACP: getJob(closeJobId)
    ACP-->>Flow: close job metadata
    Flow->>ACP: getJob(parentJobId)
    ACP-->>Flow: parent job metadata
    Flow-->>Hook: validate parent readiness and same actors
    Flow-->>Hook: record parent and active close linkage
    Hook-->>ACP: allow close setBudget
```

### 6. Close Job Submission and Outcome

```mermaid
sequenceDiagram
    autonumber
    actor Client
    actor Provider
    actor Underwriter
    participant ACP as ACP
    participant Hook as UnderwritingHook
    participant Flow as WorkflowCore

    Provider->>ACP: submit(closeJobId, closeBundleHash, closeEvidence)
    ACP->>Hook: afterAction(submit)
    Hook->>Flow: _postSubmitWorkflow(...)
    Flow-->>Hook: require close evidence to match
    Underwriter-->>Client: sign CompleteDecision or RejectDecision
    Client->>Hook: completeBySig(...) or rejectBySig(...)
    Hook->>ACP: complete(closeJobId, ...) or reject(closeJobId, ...)
    ACP->>Hook: afterAction(complete or reject)
    alt close approved
        Hook->>Flow: _postCompleteWorkflow(closeJobId)
        Flow-->>Hook: clear active close and AwaitingClose
    else close rejected
        Hook->>Flow: _postRejectWorkflow(closeJobId)
        Flow-->>Hook: clear active close only
    else close expires
        Client->>ACP: claimRefund(closeJobId)
        Flow-->>Hook: stale close is cleared on next close commit
    end
```

## Scope Notes

- The ACP budget is still the only token amount moved by these contracts.
- `UnderwritingHook` never pulls premium, collateral, or principal.
- `UnderwritingWorkflowCore` should be read as commit and lineage state only.
