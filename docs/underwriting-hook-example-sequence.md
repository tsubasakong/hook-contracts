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

For the broader sidecar-oriented reviewer deep dive, see
`docs/underwriting-hook-sidecar-sequence.md`.

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

The `createJob(...)` ACP call is identical for all three job types. **The
commit payload encoded in `setBudget(...)` is the sole discriminator.** The
hook decodes the `UnderwriteCommit` struct from the `optParams` and branches
on two fields:

| Scenario | `parentJobId` | `allowCloseJob` |
|---|---|---|
| Single-stage root job | `0` | `false` |
| Two-stage parent job | `0` | `true` |
| Close job for existing parent | `!= 0` (parent's jobId) | `false` |

This section covers the first two rows (root jobs). Close-job admission is
described in §5.

For root jobs (`parentJobId == 0`) the hook validates that the named
`underwriter` is in the registered allowlist and locks the commit. Whether the
root job is single-stage or the parent of a two-stage flow only matters later
at completion time (§4), when `allowCloseJob` determines whether the job
enters `AwaitingClose` or `SuccessPendingConfirmation`.

```mermaid
sequenceDiagram
    autonumber
    actor Client
    participant ACP as ACP
    participant Hook as UnderwritingHook
    participant Flow as WorkflowCore

    Client->>ACP: createJob(provider, evaluator=Evaluator, hook=Hook)
    Client->>ACP: setBudget(jobId, amount, commit)
    Note over Client: commit.parentJobId == 0
    ACP->>Hook: beforeAction(setBudget)
    Hook->>Flow: validate underwriter is registered, lock commit and budget
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

This is where the `allowCloseJob` flag — committed at `setBudget` time (§2) —
finally takes effect. `_postCompleteWorkflow` checks `parentJobId == 0 &&
allowCloseJob`:

- **true** → the root job becomes a two-stage parent and enters
  `AwaitingClose`, which enables a future close job to reference it (§5).
- **false** (with `parentJobId == 0`) → single-stage; goes straight to
  `SuccessPendingConfirmation`.

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
    alt approved with allowCloseJob == true (two-stage parent)
        Hook->>Flow: mark AwaitingClose
    else approved with allowCloseJob == false (single-stage)
        Hook->>Flow: mark SuccessPendingConfirmation
    else root rejected
        Hook->>Flow: mark RejectSettled
    end
```

### 5. Close Job Admission and Protection

A close job is just another `createJob(...)` → `setBudget(...)` sequence, but
its commit payload carries `parentJobId != 0` (pointing to the approved parent
from §4). This triggers the close-job branch of the same
`_preSetBudgetWorkflow` described in §2. Instead of checking the underwriter
registry, the hook validates:

- the parent is in `AwaitingClose` state,
- the actors (client, provider, evaluator, hook) and underwriter match the
  parent,
- no other live close job already occupies the parent's active-close slot.

If the client rejects the close job while it is still `Open`, the hook clears
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
    Note over Client: closeCommit.parentJobId != 0
    ACP->>Hook: beforeAction(setBudget)
    Hook->>Flow: validate parent AwaitingClose, same actors, record linkage
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
