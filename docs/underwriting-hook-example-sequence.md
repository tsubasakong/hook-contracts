# Underwriting Hook Example Sequence

This document describes the workflow currently implemented by the underwriting
example in `hook-contracts`. It is meant to help reviewers understand what the
contracts do today, not to mirror the fuller MCU settlement system in
`ERC-ACP`.

- `AgenticCommerceHooked` remains the only escrow rail in this example.
- `UnderwritingHook` is the ACP-facing hook and evaluator relay.
- `UnderwritingWorkflowCore` is the internal underwriting workflow module behind
  the hook.
- This example does not implement underwriting premium, provider collateral,
  client principal deployment, dispute windows, or settlement sidecars.

To keep GitHub rendering readable, this page uses several smaller sequence
diagrams instead of one large all-in-one chart.

## Business-Level Sequence Diagrams

### Root Job Request and Funding

Applies to both a single-stage job and the first job in a `ParentPlusClose`
workflow.

```mermaid
sequenceDiagram
    autonumber
    actor Admin
    actor Client
    participant ACP as ACP
    participant Hook as UnderwritingHook
    participant Flow as WorkflowCore

    Admin->>Hook: registerUnderwriter(underwriter)
    Hook->>Flow: add underwriter
    Client->>ACP: createJob(provider, evaluator=Hook, hook=Hook)
    Client->>ACP: setBudget(jobId, amount, commit)
    ACP->>Hook: beforeAction(setBudget)
    Hook->>Flow: lock commit + budget
    Flow-->>Hook: job admitted
    Hook-->>ACP: allow setBudget
    Client->>ACP: fund(jobId, amount)
```

### Root Job Submission and Decision

For readability, the diagrams show the `Client` relaying the underwriter
signature, although any caller may relay `completeBySig(...)` or
`rejectBySig(...)`.

```mermaid
sequenceDiagram
    autonumber
    actor Client
    actor Provider
    actor Underwriter
    participant ACP as ACP
    participant Hook as UnderwritingHook
    participant Flow as WorkflowCore

    Provider->>ACP: submit(jobId, bundleHash, evidence)
    ACP->>Hook: afterAction(submit)
    Hook->>Flow: verify evidence
    alt underwriter approves
        Underwriter-->>Client: sign CompleteDecision
        Client->>Hook: completeBySig(...)
        Hook->>ACP: complete(jobId, reason, "")
        ACP->>Hook: afterAction(complete)
        Hook->>Flow: finalize root job
    else underwriter rejects
        Underwriter-->>Client: sign RejectDecision
        Client->>Hook: rejectBySig(...)
        Hook->>ACP: reject(jobId, reason, "")
        ACP->>Hook: afterAction(reject)
        Hook->>Flow: finalize rejected job
    end
```

### Parent Job Approval With `allowCloseJob`

This branch exists only when the first commit sets `allowCloseJob = true`.

```mermaid
sequenceDiagram
    autonumber
    actor Client
    actor Underwriter
    participant ACP as ACP
    participant Hook as UnderwritingHook
    participant Flow as WorkflowCore

    Underwriter-->>Client: sign CompleteDecision
    Client->>Hook: completeBySig(...)
    Hook->>ACP: complete(parentJobId, reason, "")
    ACP->>Hook: afterAction(complete)
    Hook->>Flow: mark parent AwaitingClose
```

### Close Job Admission and Funding

The close job is a second ACP job that points back to the approved parent job.

```mermaid
sequenceDiagram
    autonumber
    actor Client
    participant ACP as ACP
    participant Hook as UnderwritingHook
    participant Flow as WorkflowCore

    Client->>ACP: createJob(provider, evaluator=Hook, hook=Hook)
    Client->>ACP: setBudget(closeJobId, closeAmount, closeCommit)
    ACP->>Hook: beforeAction(setBudget)
    Hook->>Flow: validate parent + close linkage
    Flow-->>Hook: close job admitted
    Hook-->>ACP: allow setBudget
    Client->>ACP: fund(closeJobId, closeAmount)
```

### Close Job Submission and Outcome

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
    Hook->>Flow: verify close evidence
    alt close approved
        Underwriter-->>Client: sign CompleteDecision
        Client->>Hook: completeBySig(...)
        Hook->>ACP: complete(closeJobId, reason, "")
        ACP->>Hook: afterAction(complete)
        Hook->>Flow: clear active close and AwaitingClose
    else close rejected
        Underwriter-->>Client: sign RejectDecision
        Client->>Hook: rejectBySig(...)
        Hook->>ACP: reject(closeJobId, reason, "")
        ACP->>Hook: afterAction(reject)
        Hook->>Flow: clear active close only
    else close expires
        Client->>ACP: claimRefund(closeJobId)
        Flow-->>Hook: stale close is cleared on the next close commit
    end
```

## Scope Notes

- The ACP budget is the only on-chain fee bucket in this example.
- `UnderwritingWorkflowCore` tracks commit admission, evidence matching, and
  parent or close linkage only.
- Reviewers comparing this flow to `ERC-ACP` should not expect premium,
  collateral, principal deployment, or dispute settlement behavior here.
