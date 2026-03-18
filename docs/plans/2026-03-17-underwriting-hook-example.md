# Historical Underwriting Hook Example Plan

This file is kept only as historical context for the original underwriting
example design.

It is **not** the current implementation reference.

The underwriting scaffold in `hook-contracts` has since moved to a split
topology:

- `UnderwritingHook.sol` is the ACP-facing hook shell and admin/view surface.
- `UnderwritingWorkflowCore.sol` owns commit, sidecar, and parent/close state.
- `UnderwritingEvaluator.sol` relays EIP-712 underwriter decisions into ACP.
- `UnderwritingCoordinator.sol` advances funded jobs into the `Protected` phase.

For the current behavior and sequence diagrams, use:

- `docs/underwriting-hook-example-sequence.md`
- `docs/underwriting-hook-acp-core-sequence.md`
- `hook-profiles.md`
- `README.md`
