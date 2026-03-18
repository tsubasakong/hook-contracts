# Underwriting Hook Example Sequence

This diagram shows how the refactored underwriting example works with
`AgenticCommerceHooked`, and how it relates to the fuller MCU design in
`ERC-ACP`.

- `UnderwritingHook` is the ACP-facing shell and evaluator relay.
- `UnderwritingWorkflowCore` is the internal underwriting workflow module behind it.
- Every job still uses the standard ACP lifecycle:
  `createJob -> setBudget -> fund -> submit -> complete/reject`
- The full MCU sidecars are intentionally omitted here:
  `MCUCoordinator`, `MCUSettlementEscrow`, `CollateralManager`, and a separate
  `UnderwriterEvaluator`.

```mermaid
sequenceDiagram
    autonumber
    actor Admin
    actor Client
    actor Provider
    actor Underwriter
    participant ACP as AgenticCommerceHooked
    participant Hook as UnderwritingHook
    participant WorkflowCore as UnderwritingWorkflowCore
    participant Coord as MCUCoordinator
    participant Escrow as MCUSettlementEscrow
    participant Collateral as CollateralManager

    Note over Hook,Collateral: Boundary in this example: ACP talks to UnderwritingHook, UnderwritingHook delegates workflow state to UnderwritingWorkflowCore, and the larger MCU sidecars are intentionally omitted.

    Admin->>Hook: registerUnderwriter(underwriter)
    Hook->>WorkflowCore: store registered underwriter

    Client->>ACP: createJob(provider, evaluator=Hook, hook=Hook)
    Client->>ACP: setBudget(jobId, amount, abi.encode(commit))
    ACP->>Hook: beforeAction(jobId, setBudget, data)
    Hook->>WorkflowCore: preSetBudgetWorkflow(...)
    WorkflowCore-->>Hook: lock budget + commit underwriting terms + choose SingleStage or ParentPlusClose
    Hook-->>ACP: allow setBudget

    Client->>ACP: fund(jobId, amount, "")
    Provider->>ACP: submit(jobId, bundleHash, abi.encode(evidence))
    ACP->>Hook: afterAction(jobId, submit, data)
    Hook->>WorkflowCore: postSubmitWorkflow(...)
    WorkflowCore-->>Hook: verify bundleHash, policyHash, and quoteIdHash

    Underwriter-->>Client: sign CompleteDecision or RejectDecision
    Client->>Hook: completeBySig(...) or rejectBySig(...)
    Hook->>WorkflowCore: load committed underwriter + workflow state
    Hook->>Hook: verify signer, deadline, and nonce
    Hook->>ACP: complete(jobId, ...) or reject(jobId, ...)

    alt First job rejected
        ACP->>Hook: afterAction(jobId, reject, data)
        Hook->>WorkflowCore: postRejectWorkflow(jobId)
        Note over Client,Hook: Workflow ends. No close job is admitted.

    else First job approved as SingleStage
        ACP->>Hook: afterAction(jobId, complete, data)
        Hook->>WorkflowCore: postCompleteWorkflow(jobId)
        Note over Client,Hook: Workflow ends after the first approved job.

    else First job approved as ParentPlusClose
        ACP->>Hook: afterAction(parentJobId, complete, data)
        Hook->>WorkflowCore: postCompleteWorkflow(parentJobId)
        Note over WorkflowCore: parent job marked AwaitingClose

        Client->>ACP: createJob(provider, evaluator=Hook, hook=Hook)
        Client->>ACP: setBudget(closeJobId, closeAmount, abi.encode(closeCommit{parentJobId}))
        ACP->>Hook: beforeAction(closeJobId, setBudget, data)
        Hook->>WorkflowCore: preSetBudgetWorkflow(...)
        WorkflowCore-->>Hook: validate same actors, same underwriter, parent AwaitingClose, and lazily clear stale close linkage if needed
        Hook-->>ACP: allow close commit

        Client->>ACP: fund(closeJobId, closeAmount, "")
        Provider->>ACP: submit(closeJobId, closeBundleHash, abi.encode(closeEvidence))
        ACP->>Hook: afterAction(closeJobId, submit, data)
        Hook->>WorkflowCore: postSubmitWorkflow(...)
        WorkflowCore-->>Hook: verify close evidence against the close commit

        Underwriter-->>Client: sign close CompleteDecision or RejectDecision
        Client->>Hook: completeBySig(...) or rejectBySig(...)
        Hook->>ACP: complete(closeJobId, ...) or reject(closeJobId, ...)

        alt Close approved
            ACP->>Hook: afterAction(closeJobId, complete, data)
            Hook->>WorkflowCore: postCompleteWorkflow(closeJobId)
            Note over WorkflowCore: clear activeClose linkage and clear AwaitingClose

        else Close rejected
            ACP->>Hook: afterAction(closeJobId, reject, data)
            Hook->>WorkflowCore: postRejectWorkflow(closeJobId)
            Note over WorkflowCore: clear activeClose only. Parent stays AwaitingClose.

        else Close expires
            Client->>ACP: claimRefund(closeJobId)
            Note over WorkflowCore: claimRefund is not hookable. The next close commit lazily clears the stale activeClose slot.
        end
    end
```

## Reading The Diagram

- The first committed job decides whether the flow is:
  - `SingleStage`, or
  - `ParentPlusClose` via `allowCloseJob = true`
- `AwaitingClose` only exists inside the hook-owned underwriting workflow
  state; ACP itself does not know about parent/close lineage.
- The top-level hook is intentionally thin: it adapts ACP callbacks and
  signature decisions, while `UnderwritingWorkflowCore` owns commit locking,
  lineage, and evidence/state transitions.
- That is a deliberate design choice: this example keeps parent/close linkage
  in the hook to minimize changes to the current ACP core and avoid turning one
  experimental underwriting workflow into a generic kernel-level linkage
  primitive.
- The underwriter decision is signature-based:
  the signer decides off-chain, and a caller relays that signature on-chain.
- Compared with the full MCU system in `ERC-ACP`, this example stops at the
  underwriting policy layer and does not include collateral, principal
  deployment, dispute windows, or settlement sidecars.
