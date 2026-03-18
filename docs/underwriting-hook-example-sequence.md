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

## Business-Level Sequence Diagrams

### Single-Stage Job

`parentJobId = 0`. One ACP job carries request, budget funding, submission, and
the underwriter decision.

```mermaid
sequenceDiagram
    autonumber
    actor Admin
    actor Client
    actor Provider
    actor Underwriter
    participant ACP as ACP / AgenticCommerceHooked
    participant Hook as UnderwritingHook
    participant Workflow as UnderwritingWorkflowCore

    Note over Client,Underwriter: Resource model: one ACP job, one underwriting commit, no follow-on close leg

    rect rgb(255, 236, 240)
        Note over Admin,Underwriter: Phase 0 - Setup
        Admin->>Hook: registerUnderwriter(underwriter)
        Hook->>Workflow: admit underwriter for future root commits
    end

    rect rgb(255, 236, 240)
        Note over Client,Underwriter: Phase 1 - Request
        Client->>ACP: createJob(provider, evaluator=Hook, hook=Hook)
        Client->>ACP: setBudget(jobId, amount, abi.encode(commit))
        ACP->>Hook: beforeAction(jobId, setBudget, data)
        Hook->>Workflow: lock the root commit and budget
        Note over ACP,Workflow: Root commits require a provider, a registered underwriter, and a future validity window
    end

    rect rgb(255, 236, 240)
        Note over Client,Underwriter: Phase 2 - Funding
        Client->>ACP: fund(jobId, amount, "")
        Note over ACP,Workflow: ACP escrows the normal job budget. No premium or collateral sidecar exists here
    end

    rect rgb(255, 236, 240)
        Note over Client,Underwriter: Phase 3 - Submission and Decision
        Provider->>ACP: submit(jobId, bundleHash, abi.encode(evidence))
        ACP->>Hook: afterAction(jobId, submit, data)
        Hook->>Workflow: compare evidence against the locked commit
        alt underwriter approves
            Underwriter-->>Client: sign CompleteDecision off-chain
            Client->>Hook: relay completeBySig(decision, sig)
            Hook->>ACP: complete(jobId, reason, "")
            ACP->>Hook: afterAction(jobId, complete, data)
            Hook->>Workflow: finalize the single-stage workflow
        else underwriter rejects
            Underwriter-->>Client: sign RejectDecision off-chain
            Client->>Hook: relay rejectBySig(decision, sig)
            Hook->>ACP: reject(jobId, reason, "")
            ACP->>Hook: afterAction(jobId, reject, data)
            Hook->>Workflow: finalize the rejected workflow
        end
    end
```

### ParentPlusClose Workflow

The first approved job sets `AwaitingClose` inside `UnderwritingWorkflowCore`.
A second ACP job later closes the workflow under the same actors and
underwriter.

```mermaid
sequenceDiagram
    autonumber
    actor Client
    actor Provider
    actor Underwriter
    participant ACP as ACP / AgenticCommerceHooked
    participant Hook as UnderwritingHook
    participant Workflow as UnderwritingWorkflowCore

    Note over Client,Underwriter: Resource model: two ACP jobs. The parent job establishes AwaitingClose and the close job later settles the follow-on stage

    rect rgb(255, 236, 240)
        Note over Client,Underwriter: Phase 1 - Parent Job
        Client->>ACP: createJob(provider, evaluator=Hook, hook=Hook)
        Client->>ACP: setBudget(parentJobId, amount, abi.encode(parentCommit))
        Note over Client,Workflow: parentCommit sets allowCloseJob = true
        ACP->>Hook: beforeAction(parentJobId, setBudget, data)
        Hook->>Workflow: lock the parent commit and budget
        Client->>ACP: fund(parentJobId, amount, "")
        Provider->>ACP: submit(parentJobId, bundleHash, abi.encode(parentEvidence))
        ACP->>Hook: afterAction(parentJobId, submit, data)
        Hook->>Workflow: compare parent evidence against the locked parent commit
        Underwriter-->>Client: sign parent CompleteDecision or RejectDecision
        Client->>Hook: relay parent decision
        alt parent rejected
            Hook->>ACP: reject(parentJobId, reason, "")
            ACP->>Hook: afterAction(parentJobId, reject, data)
            Hook->>Workflow: end the workflow with no close job
        else parent approved
            Hook->>ACP: complete(parentJobId, reason, "")
            ACP->>Hook: afterAction(parentJobId, complete, data)
            Hook->>Workflow: mark parent AwaitingClose
        end
    end

    rect rgb(255, 236, 240)
        Note over Client,Underwriter: Phase 2 - Close Job Admission and Funding
        Client->>ACP: createJob(provider, evaluator=Hook, hook=Hook)
        Client->>ACP: setBudget(closeJobId, closeAmount, abi.encode(closeCommit))
        Note over Client,Workflow: closeCommit points back to parentJobId
        ACP->>Hook: beforeAction(closeJobId, setBudget, data)
        Hook->>Workflow: validate parent readiness, same actors, same underwriter, and one active close slot
        Hook-->>ACP: admit the close job
        Client->>ACP: fund(closeJobId, closeAmount, "")
    end

    rect rgb(255, 236, 240)
        Note over Client,Underwriter: Phase 3 - Close Submission and Outcome
        Provider->>ACP: submit(closeJobId, closeBundleHash, abi.encode(closeEvidence))
        ACP->>Hook: afterAction(closeJobId, submit, data)
        Hook->>Workflow: compare close evidence against the locked close commit
        Underwriter-->>Client: sign close CompleteDecision or RejectDecision
        Client->>Hook: relay close decision
        alt close approved
            Hook->>ACP: complete(closeJobId, reason, "")
            ACP->>Hook: afterAction(closeJobId, complete, data)
            Hook->>Workflow: clear active close linkage and clear AwaitingClose
        else close rejected
            Hook->>ACP: reject(closeJobId, reason, "")
            ACP->>Hook: afterAction(closeJobId, reject, data)
            Hook->>Workflow: clear the active close only. Parent stays AwaitingClose
        else close expires
            Client->>ACP: claimRefund(closeJobId)
            Note over ACP,Workflow: claimRefund is not hookable. A later close commit can replace the expired close after stale-link cleanup
        end
    end
```

## Scope Notes

- The ACP budget is the only on-chain fee bucket in this example.
- `UnderwritingWorkflowCore` tracks commit admission, evidence matching, and
  parent or close linkage only.
- Reviewers comparing this flow to `ERC-ACP` should not expect premium,
  collateral, principal deployment, or dispute settlement behavior here.
