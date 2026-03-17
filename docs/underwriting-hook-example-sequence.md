# Underwriting Hook Example Sequence

This diagram shows how the minimal `UnderwritingHook` example works with
`AgenticCommerceHooked`, and how it relates to the fuller MCU design in
`ERC-ACP`.

- `UnderwritingHook` is both the hook and the evaluator in this example.
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
    participant Coord as MCUCoordinator
    participant Escrow as MCUSettlementEscrow
    participant Collateral as CollateralManager

    Note over Hook,Collateral: Minimal example boundary: no Coordinator, Escrow, or CollateralManager calls. UnderwritingHook also plays the evaluator role.

    Admin->>Hook: registerUnderwriter(underwriter)

    Client->>ACP: createJob(provider, evaluator=Hook, hook=Hook)
    Client->>ACP: setBudget(jobId, amount, abi.encode(commit))
    ACP->>Hook: beforeAction(jobId, setBudget, data)
    Hook-->>ACP: lock budget + commit underwriting terms + choose SingleStage or ParentPlusClose

    Client->>ACP: fund(jobId, amount, "")
    Provider->>ACP: submit(jobId, bundleHash, abi.encode(evidence))
    ACP->>Hook: afterAction(jobId, submit, data)
    Hook-->>ACP: verify bundleHash, policyHash, and quoteIdHash

    Underwriter-->>Client: sign CompleteDecision or RejectDecision
    Client->>Hook: completeBySig(...) or rejectBySig(...)
    Hook->>Hook: verify signer, deadline, nonce, and committed underwriter
    Hook->>ACP: complete(jobId, ...) or reject(jobId, ...)

    alt First job rejected
        ACP->>Hook: afterAction(jobId, reject, data)
        Note over Client,Hook: Workflow ends. No close job is admitted.

    else First job approved as SingleStage
        ACP->>Hook: afterAction(jobId, complete, data)
        Note over Client,Hook: Workflow ends after the first approved job.

    else First job approved as ParentPlusClose
        ACP->>Hook: afterAction(parentJobId, complete, data)
        Note over Hook: parent job marked AwaitingClose

        Client->>ACP: createJob(provider, evaluator=Hook, hook=Hook)
        Client->>ACP: setBudget(closeJobId, closeAmount, abi.encode(closeCommit{parentJobId}))
        ACP->>Hook: beforeAction(closeJobId, setBudget, data)
        Hook-->>ACP: validate same actors, same underwriter, parent AwaitingClose, and lazily clear stale close linkage if needed

        Client->>ACP: fund(closeJobId, closeAmount, "")
        Provider->>ACP: submit(closeJobId, closeBundleHash, abi.encode(closeEvidence))
        ACP->>Hook: afterAction(closeJobId, submit, data)
        Hook-->>ACP: verify close evidence against the close commit

        Underwriter-->>Client: sign close CompleteDecision or RejectDecision
        Client->>Hook: completeBySig(...) or rejectBySig(...)
        Hook->>ACP: complete(closeJobId, ...) or reject(closeJobId, ...)

        alt Close approved
            ACP->>Hook: afterAction(closeJobId, complete, data)
            Note over Hook: clear activeClose linkage and clear AwaitingClose

        else Close rejected
            ACP->>Hook: afterAction(closeJobId, reject, data)
            Note over Hook: clear activeClose only; parent stays AwaitingClose

        else Close expires
            Client->>ACP: claimRefund(closeJobId)
            Note over Hook: claimRefund is not hookable; the next close commit lazily clears the stale activeClose slot
        end
    end
```

## Reading The Diagram

- The first committed job decides whether the flow is:
  - `SingleStage`, or
  - `ParentPlusClose` via `allowCloseJob = true`
- `AwaitingClose` only exists inside `UnderwritingHook`; ACP itself does not
  know about parent/close lineage.
- The underwriter decision is signature-based:
  the signer decides off-chain, and a caller relays that signature on-chain.
- Compared with the full MCU system in `ERC-ACP`, this example stops at the
  underwriting policy layer and does not include collateral, principal
  deployment, dispute windows, or settlement sidecars.
