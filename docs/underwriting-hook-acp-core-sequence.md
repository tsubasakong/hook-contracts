# Underwriting Hook ACP/Core Sequence

This document mirrors the phased sequencing style used in `ERC-ACP`, but it
stays limited to the contracts that actually exist in `hook-contracts`.

- `AgenticCommerceHooked` owns job status changes plus budget escrow, payout,
  and refund.
- `UnderwritingHook` is the ACP hook shell plus admin/view surface.
- `UnderwritingWorkflowCore` is the internal workflow and sidecar-state module
  behind the hook.
- `UnderwritingEvaluator` owns the EIP-712 decision relay and calls ACP
  `complete()` / `reject()`.
- `UnderwritingCoordinator` is the minimal scaffold that marks funded jobs
  `Protected` before submission.
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

    Admin->>Hook: registerUnderwriter(underwriter)
    Admin->>Hook: setWiring(evaluator, coordinator)
```

### 2. Root Job Commit Lock

The job is first created with `hook = Hook` and `evaluator = Evaluator`. The
actual underwriting admission still happens on the first `setBudget(...)`.

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

### 3. Root Job Funding and Protection

The coordinator does not move tokens yet. It only advances the hook-owned
sidecar state from `FeeEscrowed` to `Protected`.

```mermaid
sequenceDiagram
    autonumber
    actor Client
    participant ACP as ACP
    participant Hook as UnderwritingHook
    participant Flow as WorkflowCore
    participant Coord as UnderwritingCoordinator

    Client->>ACP: fund(jobId, amount)
    ACP->>Hook: beforeAction(fund)
    Hook->>Flow: _preFundWorkflow(...)
    ACP->>Hook: afterAction(fund)
    Hook->>Flow: _postFundWorkflow(...)
    Flow-->>Hook: mark FeeEscrowed
    Client->>Coord: orchestrateFunding(jobId)
    Coord->>ACP: getJob(jobId)
    Coord->>Hook: jobSidecarState(jobId)
    Coord->>Hook: markProtected(jobId)
    Hook->>Flow: _markProtectedWorkflow(jobId)
```

### 4. Root Job Submission

`UnderwritingHook` now blocks submission until the coordinator has marked the
job `Protected`.

```mermaid
sequenceDiagram
    autonumber
    actor Provider
    participant ACP as ACP
    participant Hook as UnderwritingHook
    participant Flow as WorkflowCore

    Provider->>ACP: submit(jobId, bundleHash, evidence)
    ACP->>Hook: beforeAction(submit)
    Hook->>Flow: _preSubmitWorkflow(...)
    ACP->>Hook: afterAction(submit)
    Hook->>Flow: _postSubmitWorkflow(...)
    Flow-->>Hook: verify evidence and mark EvidenceSubmitted
```

### 5. Root Job Decision

For readability, this diagram shows the `Client` relaying the signature, though
any caller may relay `completeBySig(...)` or `rejectBySig(...)`.

```mermaid
sequenceDiagram
    autonumber
    actor Client
    actor Underwriter
    participant Eval as UnderwritingEvaluator
    participant ACP as ACP
    participant Hook as UnderwritingHook
    participant Flow as WorkflowCore

    Underwriter-->>Client: sign CompleteDecision or RejectDecision
    Client->>Eval: completeBySig(...) or rejectBySig(...)
    Eval->>ACP: getJob(jobId)
    ACP-->>Eval: job metadata
    Eval->>Hook: jobSidecarState(jobId)
    Eval->>Hook: jobUnderwriter(jobId)
    Eval->>ACP: complete(jobId, ...) or reject(jobId, ...)
    ACP->>Hook: beforeAction(complete or reject)
    Hook->>Flow: _preDecisionWorkflow(...)
    ACP->>Hook: afterAction(complete or reject)
    alt approved with allowCloseJob
        Hook->>Flow: _postCompleteWorkflow(jobId)
        Flow-->>Hook: mark AwaitingClose
    else approved single-stage
        Hook->>Flow: _postCompleteWorkflow(jobId)
        Flow-->>Hook: mark SuccessPendingConfirmation
    else rejected
        Hook->>Flow: _postRejectWorkflow(jobId)
        Flow-->>Hook: mark RejectSettled
    end
```

### 6. Close Job Admission

Precondition: `awaitingCloseByJobId[parentJobId] = true`.
If the client rejects the close job while it is still `Open`, the hook marks it
`RejectSettled` and clears the reserved active-close slot.

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

### 7. Close Job Funding and Protection

```mermaid
sequenceDiagram
    autonumber
    actor Client
    participant ACP as ACP
    participant Hook as UnderwritingHook
    participant Flow as WorkflowCore
    participant Coord as UnderwritingCoordinator

    Client->>ACP: fund(closeJobId, closeAmount)
    ACP->>Hook: afterAction(fund)
    Hook->>Flow: mark FeeEscrowed
    Client->>Coord: orchestrateFunding(closeJobId)
    Coord->>Hook: markProtected(closeJobId)
    Hook->>Flow: mark Protected
```

### 8. Close Job Submission and Outcome

```mermaid
sequenceDiagram
    autonumber
    actor Client
    actor Provider
    actor Underwriter
    participant Eval as UnderwritingEvaluator
    participant ACP as ACP
    participant Hook as UnderwritingHook
    participant Flow as WorkflowCore

    Provider->>ACP: submit(closeJobId, closeBundleHash, closeEvidence)
    ACP->>Hook: beforeAction(submit)
    Hook->>Flow: require Protected
    ACP->>Hook: afterAction(submit)
    Hook->>Flow: verify close evidence and mark EvidenceSubmitted
    Underwriter-->>Client: sign CompleteDecision or RejectDecision
    Client->>Eval: completeBySig(...) or rejectBySig(...)
    Eval->>ACP: complete(closeJobId, ...) or reject(closeJobId, ...)
    ACP->>Hook: afterAction(complete or reject)
    alt close approved
        Hook->>Flow: _postCompleteWorkflow(closeJobId)
        Flow-->>Hook: clear active close and end AwaitingClose
    else close rejected
        Hook->>Flow: _postRejectWorkflow(closeJobId)
        Flow-->>Hook: clear active close and mark RejectSettled
    else close expires
        Client->>ACP: claimRefund(closeJobId)
        Flow-->>Hook: stale close is cleared on next close commit
    end
```

## Scope Notes

- The ACP budget is still the only token amount moved by these contracts.
- `UnderwritingCoordinator` is state-only in this scaffold and does not yet
  move premium, collateral, or principal.
- `UnderwritingWorkflowCore` should be read as commit, sidecar state, and
  lineage state only.
- A committed job may still be rejected while `Open`; this prevents abandoned
  root or close jobs from getting stuck before funding.
