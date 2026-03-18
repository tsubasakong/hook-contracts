# Underwriting Hook Example Sequence

This document describes the current underwriting scaffold in `hook-contracts`.
It is still intentionally narrower than the fuller MCU settlement system in
`ERC-ACP`, but it now uses the same high-level split:

- `AgenticCommerceHooked` keeps the ACP job rail and fee escrow.
- `UnderwritingHook` is the ACP-facing hook shell plus admin/view surface.
- `UnderwritingWorkflowCore` is the internal underwriting workflow state behind
  the hook.
- `UnderwritingEvaluator` verifies underwriter signatures and calls ACP
  `complete()` / `reject()`.
- `UnderwritingCoordinator` advances funded jobs into the `Protected` sidecar
  phase before submission.

This scaffold still does **not** implement underwriting premium, provider
collateral, client principal deployment, dispute windows, or settlement sidecar
money movement.

To keep GitHub rendering readable, this page uses several smaller sequence
diagrams instead of one large all-in-one chart.

## Business-Level Sequence Diagrams

### 1. Setup

```mermaid
sequenceDiagram
    autonumber
    actor Admin
    participant Hook as UnderwritingHook

    Admin->>Hook: registerUnderwriter(underwriter)
    Admin->>Hook: setWiring(evaluator, coordinator)
```

### 2. Root Job Request and Fee Funding

Applies to both a single-stage job and the first job in a `ParentPlusClose`
workflow.

```mermaid
sequenceDiagram
    autonumber
    actor Client
    participant ACP as ACP
    participant Hook as UnderwritingHook
    participant Flow as WorkflowCore

    Client->>ACP: createJob(provider, evaluator=Evaluator, hook=Hook)
    Client->>ACP: setBudget(jobId, amount, commit)
    ACP->>Hook: beforeAction(setBudget)
    Hook->>Flow: lock commit and budget
    Hook-->>ACP: allow setBudget
    Client->>ACP: fund(jobId, amount)
    ACP->>Hook: afterAction(fund)
    Hook->>Flow: mark FeeEscrowed
```

### 3. Root Job Protection and Submission

```mermaid
sequenceDiagram
    autonumber
    actor Client
    actor Provider
    participant Coord as UnderwritingCoordinator
    participant ACP as ACP
    participant Hook as UnderwritingHook
    participant Flow as WorkflowCore

    Client->>Coord: orchestrateFunding(jobId)
    Coord->>Hook: markProtected(jobId)
    Hook->>Flow: mark Protected
    Provider->>ACP: submit(jobId, bundleHash, evidence)
    ACP->>Hook: beforeAction(submit)
    Hook->>Flow: require Protected
    ACP->>Hook: afterAction(submit)
    Hook->>Flow: verify evidence and mark EvidenceSubmitted
```

### 4. Root Job Decision

For readability, the diagrams show the `Client` relaying the signature, though
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
    Eval->>ACP: complete(jobId, ...) or reject(jobId, ...)
    ACP->>Hook: afterAction(complete or reject)
    alt root approved with allowCloseJob
        Hook->>Flow: mark AwaitingClose
    else single-stage approved
        Hook->>Flow: mark SuccessPendingConfirmation
    else root rejected
        Hook->>Flow: mark RejectSettled
    end
```

### 5. Close Job Admission and Protection

The close job is a second ACP job that points back to the approved parent job.
If the client rejects that close job while it is still `Open`, the hook clears
the reserved close slot and the parent remains `AwaitingClose`.

```mermaid
sequenceDiagram
    autonumber
    actor Client
    participant ACP as ACP
    participant Hook as UnderwritingHook
    participant Flow as WorkflowCore
    participant Coord as UnderwritingCoordinator

    Client->>ACP: createJob(provider, evaluator=Evaluator, hook=Hook)
    Client->>ACP: setBudget(closeJobId, closeAmount, closeCommit)
    ACP->>Hook: beforeAction(setBudget)
    Hook->>Flow: validate parent and close linkage
    Hook-->>ACP: admit close job
    Client->>ACP: fund(closeJobId, closeAmount)
    ACP->>Hook: afterAction(fund)
    Hook->>Flow: mark FeeEscrowed
    Client->>Coord: orchestrateFunding(closeJobId)
    Coord->>Hook: markProtected(closeJobId)
```

### 6. Close Job Submission and Outcome

```mermaid
sequenceDiagram
    autonumber
    actor Client
    actor Provider
    actor Underwriter
    participant ACP as ACP
    participant Eval as UnderwritingEvaluator
    participant Hook as UnderwritingHook
    participant Flow as WorkflowCore

    Provider->>ACP: submit(closeJobId, closeBundleHash, closeEvidence)
    ACP->>Hook: afterAction(submit)
    Hook->>Flow: verify close evidence
    Underwriter-->>Client: sign CompleteDecision or RejectDecision
    Client->>Eval: completeBySig(...) or rejectBySig(...)
    Eval->>ACP: complete(closeJobId, ...) or reject(closeJobId, ...)
    ACP->>Hook: afterAction(complete or reject)
    alt close approved
        Hook->>Flow: clear active close and end AwaitingClose
    else close rejected
        Hook->>Flow: clear active close only
    else close expires
        Client->>ACP: claimRefund(closeJobId)
        Note over Flow: stale close is cleared on the next close commit
    end
```

## Scope Notes

- The ACP budget is the only on-chain fee bucket in this scaffold.
- `UnderwritingWorkflowCore` tracks commit admission, sidecar state, evidence
  matching, and parent/close linkage only.
- A committed job may still be rejected while `Open`; that is the escape hatch
  for cancelling an abandoned root or close job before funding.
- Reviewers comparing this flow to `ERC-ACP` should not expect premium,
  collateral, principal deployment, or dispute settlement behavior here yet.
