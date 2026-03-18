# Underwriting Hook Sidecar Sequence

This document is the reviewer deep dive for the broader sidecar-oriented
underwriting workflow. It explains how the current underwriting scaffold in
`hook-contracts` can connect to premium, collateral, principal, and dispute
settlement sidecars.

It is intentionally a deeper architecture view, not a claim that every
money-moving step below already exists in the current scaffold.

- `AgenticCommerceHooked` remains the ACP job rail and fee escrow.
- `UnderwritingHook` stays the ACP-facing hook shell plus admin/view surface.
- `UnderwritingWorkflowCore` stays the hook-owned workflow and sidecar-state
  module.
- `UnderwritingEvaluator` relays underwriter signatures into ACP decisions.
- `UnderwritingCoordinator` orchestrates the sidecar steps around protection and
  settlement.
- `SettlementEscrow` is the sidecar escrow that stages collateral and principal
  movement.
- `CollateralManager` is the sidecar settlement system that locks, releases, or
  slashes collateral and collects underwriting premium.

To keep GitHub rendering readable, this page uses several smaller sequence
diagrams instead of one large all-in-one chart.

## Sidecar Deep-Dive Sequence Diagrams

### 1. Premium and Protection Activation

This is the sidecar-oriented version of `setBudget -> fund -> orchestrateFunding`.

```mermaid
sequenceDiagram
    autonumber
    actor Client
    actor Provider
    participant ACP as ACP
    participant Hook as UnderwritingHook
    participant Coord as UnderwritingCoordinator
    participant Escrow as SettlementEscrow
    participant Collateral as CollateralManager

    Client->>ACP: setBudget(jobId, serviceFee, commit)
    ACP->>Hook: beforeAction(setBudget)
    Hook-->>ACP: commit is locked
    Client->>ACP: fund(jobId, serviceFee)
    ACP->>Hook: afterAction(fund)
    Hook-->>Coord: sidecar state is FeeEscrowed
    Client->>Coord: orchestrateFunding(jobId, permit, permitSig)
    Coord->>Escrow: pullCollateralFromProvider(requiredCollateral)
    Coord->>Escrow: pullPrincipalFromClient(fundedPrincipal)
    Escrow->>Collateral: lockCollateral(permit, permitSig)
    Note over Collateral,Client: collateral flow may also collect the underwriting premium from the client
    opt releasePrincipal == true
        Escrow->>Collateral: releasePrincipalToMerchant(permit, permitSig)
    end
    Coord->>Hook: markProtected(jobId)
```

### 2. Open-Leg Underwriting Gate

This is the deeper sidecar view where the open leg can be approved or rejected
after protection is active but before final close-leg settlement exists.

```mermaid
sequenceDiagram
    autonumber
    actor Client
    actor Underwriter
    participant Eval as UnderwritingEvaluator
    participant ACP as ACP
    participant Hook as UnderwritingHook
    participant Flow as WorkflowCore

    Note over Client,Flow: open leg is already Protected
    Underwriter-->>Client: sign open-leg CompleteDecision or RejectDecision
    Client->>Eval: completeBySig(...) or rejectBySig(...)
    Eval->>ACP: complete(openJobId, ...) or reject(openJobId, ...)
    ACP->>Hook: afterAction(complete or reject)
    alt open leg approved
        Hook->>Flow: mark AwaitingClose
    else open leg rejected
        Hook->>Flow: mark reject-side terminal state
        Note over Client,Flow: workflow ends here. Continuing requires a new ACP job
    end
```

### 3. Close-Leg Admission and Parent Reuse

The close leg reuses the parent workflow identity and protection context.

```mermaid
sequenceDiagram
    autonumber
    actor Client
    participant ACP as ACP
    participant Hook as UnderwritingHook
    participant Flow as WorkflowCore
    participant Coord as UnderwritingCoordinator
    participant Escrow as SettlementEscrow

    Client->>ACP: setBudget(closeJobId, closeServiceFee, closeCommit{parentJobId})
    ACP->>Hook: beforeAction(setBudget)
    Hook->>Flow: validate parent readiness and same underwriter
    Flow-->>Hook: record active close linkage and settlementJobId = parentJobId
    Client->>ACP: fund(closeJobId, closeServiceFee)
    ACP->>Hook: afterAction(fund)
    Client->>Coord: orchestrateFunding(closeJobId, unusedPermit, unusedSig)
    Coord->>Escrow: reuse parent settlement escrow
    Note over Coord,Escrow: no new premium, collateral, or principal is pulled on the close leg
    Coord->>Hook: markProtected(closeJobId)
```

### 4. Provider Release Request and Client Dispute Window

The dispute window begins on the provider release request, not on ACP
completion itself.

```mermaid
sequenceDiagram
    autonumber
    actor Provider
    actor Client
    participant Coord as UnderwritingCoordinator
    participant Hook as UnderwritingHook
    participant Flow as WorkflowCore

    Note over Provider,Flow: close leg already reached SuccessPendingConfirmation
    Provider->>Coord: requestCollateralRelease(closeJobId)
    Coord->>Hook: markSuccessPendingCollateralRelease(closeJobId)
    Hook->>Flow: record settlementRequestedAt and open release window
    opt client disputes before deadline
        Client->>Coord: openSuccessDispute(closeJobId, disputeHash)
        Coord->>Hook: markSuccessDisputeOpen(closeJobId, disputeHash)
        Hook->>Flow: record dispute hash and dispute-open state
    end
```

### 5. Release vs Slash Outcome

After a release request, the sidecar path resolves toward collateral release or
collateral slash.

```mermaid
sequenceDiagram
    autonumber
    actor Client
    actor Provider
    actor Underwriter
    participant Eval as UnderwritingEvaluator
    participant Coord as UnderwritingCoordinator
    participant Escrow as SettlementEscrow
    participant Collateral as CollateralManager

    alt release path
        Underwriter-->>Provider: sign SuccessDisputeDecision(ReleaseCollateral)
        Provider->>Eval: resolveSuccessDisputeBySig(...)
        Eval->>Coord: apply release decision
        Provider->>Coord: releaseCollateral(closeJobId)
        Coord->>Escrow: releaseCollateralAndForward()
        Escrow->>Collateral: releaseCollateral(settlementJobId)
        Escrow-->>Provider: forward released collateral
    else slash path
        Underwriter-->>Client: sign SuccessDisputeDecision(SlashCollateral)
        Client->>Eval: resolveSuccessDisputeBySig(...)
        Eval->>Coord: apply slash decision
        Coord->>Escrow: slashCollateral(attestation, slashSig)
        Escrow->>Collateral: slash(attestation, slashSig)
        Collateral-->>Client: slash proceeds / coverage transfer
    end
```

## Scope Notes

- This doc is a deeper sidecar-oriented architecture view for reviewers who
  want the premium/collateral/principal/dispute picture.
- The current `hook-contracts` scaffold does **not** yet implement the full
  sidecar money movement shown here.
- The current scaffold already has the split control-plane roles
  (`Hook`, `WorkflowCore`, `Evaluator`, `Coordinator`) that a future sidecar
  implementation can build on.
