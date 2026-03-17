# Underwriting Hook Example Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a minimal-core underwriting example to `hook-contracts` that demonstrates underwriter-gated admission and finalization, including an optional two-stage open/close flow whose lineage stays in the hook rather than the core.

**Architecture:** Keep this example much smaller than the MCU prototype. Do not port `MCUCoordinator`, `MCUSettlementEscrow`, collateral locking, dispute windows, or slash settlement. Add only the smallest core extension needed to represent an open-stage job, then keep parent/close linkage, active close exclusivity, underwriter registry, evidence matching, and open-to-close gating inside the hook and evaluator.

**Tech Stack:** Solidity `^0.8.20`, `AgenticCommerceHooked`, `BaseACPHook`, OpenZeppelin `EIP712` + `ECDSA`, Foundry.

---

## Design Rules

- Preserve current `createJob()` behavior for all existing hooks.
- Do not add a native core `Close` job type in v1.
- Do not add parent/close lineage mappings to the core in v1.
- Keep refund semantics unchanged: `claimRefund()` stays non-hookable.
- Keep underwriting settlement out of scope: no coordinator, no sidecar escrow, no collateral manager integration.
- Treat the example as **Profile C / Experimental** because it changes lifecycle shape and depends on off-chain underwriter signatures.

## Current Baseline

- `BaseACPHook` already dispatches `fund(uint256,uint256,bytes)` correctly.
- `test/BaseACPHookFundDispatch.t.sol` is the regression guard for fund hook routing.
- This plan assumes that selector fix stays in place.

## Proposed Contract Shape

### Minimal Core Additions

Modify `contracts/AgenticCommerceHooked.sol` only enough to support an open-stage underwriting leg:

- add `JobKind { Standalone, Open }`
- add `mapping(uint256 => JobKind) jobKindByJobId`
- keep `createJob(...)` as the existing standalone path
- add `createOpenJob(provider, evaluator, expiredAt, description, hook)`
- add `getJobKind(jobId)`
- block `submit()` for `JobKind.Open`
- allow `complete()` on `JobKind.Open` directly from `Funded`

Do **not** add:

- `JobKind.Close`
- `createCloseJob(...)`
- `getParentJobId(...)`
- `getCloseJobId(...)`

The close leg remains a normal `createJob(...)` call whose hook opt params include `parentJobId`.

### New Example Contracts

- `contracts/hooks/UnderwritingTypes.sol`
- `contracts/hooks/UnderwritingHook.sol`
- `contracts/hooks/UnderwriterDecisionEvaluator.sol`

### Hook Data Model

`UnderwritingTypes.sol`

```solidity
library UnderwritingTypes {
    enum FlowKind {
        SingleStage,
        TwoStageOpen,
        TwoStageClose
    }

    enum HookState {
        None,
        Committed,
        Funded,
        EvidenceSubmitted,
        AwaitingClose
    }

    struct UnderwriteCommit {
        uint256 parentJobId;
        address underwriter;
        uint64 validUntil;
        bytes32 policyHash;
        bytes32 quoteIdHash;
        bytes32 termsHash;
    }

    struct SubmitEvidence {
        bytes32 bundleHash;
        bytes32 policyHash;
        bytes32 quoteIdHash;
    }
}
```

`HookState` intentionally stays small. Core `JobStatus` already tells us whether a job is `Open`, `Funded`, `Submitted`, `Completed`, `Rejected`, or `Expired`; the hook only needs to track underwriting-specific state and whether an open leg is parked in `AwaitingClose`.

### Hook Responsibilities

`contracts/hooks/UnderwritingHook.sol`

- inherit `BaseACPHook`
- keep an `admin` and underwriter registry
- store one `UnderwriteCommit` per `jobId`
- resolve `FlowKind` from `(core job kind, commit.parentJobId)`
- keep hook-managed lineage:
  - `parentJobIdByCloseJobId`
  - `activeCloseJobIdByParentJobId`
- require close jobs to match the parent job on:
  - client
  - provider
  - evaluator
  - hook
  - underwriter
- allow single-stage and open commits only if the chosen underwriter is currently registered
- allow close commits to reuse the parent underwriter even if that signer was later removed from the registry
- validate submit evidence against the committed `policyHash` and `quoteIdHash`
- move open jobs into `AwaitingClose` on successful completion
- clear active close linkage when a close attempt is rejected or expires

### Evaluator Responsibilities

`contracts/hooks/UnderwriterDecisionEvaluator.sol`

- verify EIP-712 `CompleteDecision` and `RejectDecision` signatures from the committed underwriter
- check nonce replay protection
- allow:
  - `TwoStageOpen` completion/rejection while the core job is still `Funded`
  - `SingleStage` and `TwoStageClose` completion/rejection only after `Submitted`
- call core `complete()` / `reject()` after successful signature verification

This keeps the example focused on underwriting approval and evidence validation, not settlement.

---

### Task 1: Normalize Foundry Project Setup

**Files:**
- Create: `foundry.toml`
- Create: `lib/openzeppelin-contracts/` via `forge install`
- Verify: `test/BaseACPHookFundDispatch.t.sol`

**Step 1: Write the failing build expectation**

Run:

```bash
forge build
```

Expected: FAIL because `@openzeppelin` imports are unresolved in the current repo checkout.

**Step 2: Add minimal Foundry config**

Create `foundry.toml`:

```toml
[profile.default]
src = "contracts"
test = "test"
out = "out"
libs = ["lib"]
solc_version = "0.8.20"
```

**Step 3: Install OpenZeppelin**

Run:

```bash
forge install OpenZeppelin/openzeppelin-contracts
```

**Step 4: Re-run the scoped regression test**

Run:

```bash
forge test --match-path "test/BaseACPHookFundDispatch.t.sol"
```

Expected: PASS.

**Step 5: Commit**

```bash
git add foundry.toml lib/ test/BaseACPHookFundDispatch.t.sol
git commit -m "chore: set up foundry for hook examples"
```

### Task 2: Add Minimal Open-Job Support to the Core

**Files:**
- Modify: `contracts/AgenticCommerceHooked.sol`
- Create: `test/AgenticCommerceHookedOpenJobs.t.sol`

**Step 1: Write the failing tests**

Create tests covering only the minimal new behavior:

```solidity
function testCreateOpenJobMarksKindOpen() public {
    uint256 jobId = acp.createOpenJob(provider, evaluator, block.timestamp + 1 days, "open job", hook);
    assertEq(uint256(acp.getJobKind(jobId)), uint256(AgenticCommerceHooked.JobKind.Open));
}

function testOpenJobCannotSubmit() public {
    uint256 jobId = _createAndFundOpenJob();
    vm.prank(provider);
    vm.expectRevert(AgenticCommerceHooked.SubmitNotAllowedForOpenJob.selector);
    acp.submit(jobId, keccak256("bundle"), "");
}

function testOpenJobCanCompleteDirectlyFromFunded() public {
    uint256 jobId = _createAndFundOpenJob();
    vm.prank(evaluator);
    acp.complete(jobId, keccak256("ok"), "");
    assertEq(uint256(acp.getJob(jobId).status), uint256(AgenticCommerceHooked.JobStatus.Completed));
}
```

**Step 2: Run the new test file**

Run:

```bash
forge test --match-path "test/AgenticCommerceHookedOpenJobs.t.sol"
```

Expected: FAIL because `createOpenJob()` and `getJobKind()` do not exist yet.

**Step 3: Implement the smallest possible core delta**

Modify `contracts/AgenticCommerceHooked.sol`:

- add:

```solidity
enum JobKind {
    Standalone,
    Open
}
```

- add:

```solidity
mapping(uint256 => JobKind) internal jobKindByJobId;
```

- keep `createJob(...)` as:

```solidity
jobKindByJobId[jobId] = JobKind.Standalone;
```

- add:

```solidity
function createOpenJob(
    address provider,
    address evaluator,
    uint256 expiredAt,
    string calldata description,
    address hook
) external returns (uint256 jobId)
```

- add:

```solidity
function getJobKind(uint256 jobId) external view returns (JobKind)
```

- change `submit()`:

```solidity
if (jobKindByJobId[jobId] == JobKind.Open) revert SubmitNotAllowedForOpenJob();
```

- change `complete()`:

```solidity
if (jobKindByJobId[jobId] == JobKind.Open) {
    if (job.status != JobStatus.Funded) revert WrongStatus();
} else {
    if (job.status != JobStatus.Submitted) revert WrongStatus();
}
```

**Step 4: Re-run the open-job tests**

Run:

```bash
forge test --match-path "test/AgenticCommerceHookedOpenJobs.t.sol"
```

Expected: PASS.

**Step 5: Commit**

```bash
git add contracts/AgenticCommerceHooked.sol test/AgenticCommerceHookedOpenJobs.t.sol
git commit -m "feat: add minimal open job support"
```

### Task 3: Add Underwriting Types and Hook Admission Logic

**Files:**
- Create: `contracts/hooks/UnderwritingTypes.sol`
- Create: `contracts/hooks/UnderwritingHook.sol`
- Create: `test/UnderwritingHookAdmission.t.sol`

**Step 1: Write the failing admission tests**

Create tests for:

- single-stage commit requires a registered underwriter
- open-job commit resolves to `TwoStageOpen`
- standalone job with nonzero `parentJobId` resolves to `TwoStageClose`
- close commit reuses the parent underwriter
- close commit fails if the parent open leg is not yet `AwaitingClose`
- close commit fails if another active close job already exists

Key test shape:

```solidity
function testTwoStageCloseCommitStoresParentLinkage() public {
    _registerUnderwriter();
    _commitOpenJob();
    _markOpenJobAwaitingClose();

    acp.callBeforeAction(address(hook), closeJobId, SEL_SET_BUDGET, _setBudgetData(_closeCommit(openJobId)));

    assertEq(hook.getParentJobId(closeJobId), openJobId);
    assertEq(hook.getCloseJobId(openJobId), closeJobId);
    assertEq(uint256(hook.jobFlowKind(closeJobId)), uint256(UnderwritingTypes.FlowKind.TwoStageClose));
}
```

**Step 2: Run the failing tests**

Run:

```bash
forge test --match-path "test/UnderwritingHookAdmission.t.sol"
```

Expected: FAIL because the new types and hook do not exist yet.

**Step 3: Implement the shared types**

Create `contracts/hooks/UnderwritingTypes.sol` with:

- `FlowKind`
- `HookState`
- `UnderwriteCommit`
- `SubmitEvidence`

**Step 4: Implement the admission half of the hook**

Create `contracts/hooks/UnderwritingHook.sol` and implement:

- constructor with `acpContract` and `admin`
- underwriter registry
- commit storage keyed by `jobId`
- flow resolution:

```solidity
if (jobKind == AgenticCommerceHooked.JobKind.Open) {
    require(commit.parentJobId == 0, "invalid open commit");
    return FlowKind.TwoStageOpen;
}
if (commit.parentJobId == 0) return FlowKind.SingleStage;
return FlowKind.TwoStageClose;
```

- close-leg validation against the parent job
- active close tracking in the hook, not the core

**Step 5: Re-run the admission tests**

Run:

```bash
forge test --match-path "test/UnderwritingHookAdmission.t.sol"
```

Expected: PASS.

**Step 6: Commit**

```bash
git add contracts/hooks/UnderwritingTypes.sol contracts/hooks/UnderwritingHook.sol test/UnderwritingHookAdmission.t.sol
git commit -m "feat: add underwriting hook admission logic"
```

### Task 4: Add Hook Lifecycle and Evidence Validation

**Files:**
- Modify: `contracts/hooks/UnderwritingHook.sol`
- Create: `test/UnderwritingHookLifecycle.t.sol`

**Step 1: Write the failing lifecycle tests**

Create tests for:

- `fund()` moves hook state from `Committed` to `Funded`
- open jobs can complete from `Funded` and move to `AwaitingClose`
- single-stage and close jobs cannot complete until evidence has been submitted
- `submit()` must match `bundleHash`, `policyHash`, and `quoteIdHash`
- rejecting an active close job clears the parent-to-close linkage
- expiring an active close job clears the parent-to-close linkage

Key test shape:

```solidity
function testOpenJobCompleteTransitionsToAwaitingClose() public {
    _registerUnderwriter();
    _commitAndFundOpenJob();

    acp.callAfterAction(openJobId, SEL_COMPLETE, abi.encode(bytes32("ok"), bytes("")));

    assertEq(uint256(hook.jobHookState(openJobId)), uint256(UnderwritingTypes.HookState.AwaitingClose));
}
```

**Step 2: Run the lifecycle tests**

Run:

```bash
forge test --match-path "test/UnderwritingHookLifecycle.t.sol"
```

Expected: FAIL because the hook has not implemented the lifecycle gates yet.

**Step 3: Implement the minimal lifecycle state machine**

In `contracts/hooks/UnderwritingHook.sol`:

- `_preSetBudget(...)`: decode and validate `UnderwriteCommit`
- `_preFund(...)`: require a committed profile; require parent open leg is `AwaitingClose` for close jobs
- `_postFund(...)`: mark hook state `Funded`
- `_preSubmit(...)`: reject `TwoStageOpen`; require hook state `Funded`
- `_postSubmit(...)`: decode `SubmitEvidence`; require hashes match the committed profile; mark `EvidenceSubmitted`
- `_preComplete(...)`:
  - for `TwoStageOpen`, require hook state `Funded`
  - otherwise require hook state `EvidenceSubmitted`
- `_postComplete(...)`:
  - for `TwoStageOpen`, set `AwaitingClose`
  - otherwise leave lineage cleared or unchanged
- `_postReject(...)`: clear active close linkage if this job is a close leg
- add a direct expiry cleanup method:

```solidity
function clearExpiredCloseJob(uint256 jobId) external
```

This method should be permissionless but only succeed if the core job status is `Expired` and the hook flow is `TwoStageClose`.

**Step 4: Re-run the lifecycle tests**

Run:

```bash
forge test --match-path "test/UnderwritingHookLifecycle.t.sol"
```

Expected: PASS.

**Step 5: Commit**

```bash
git add contracts/hooks/UnderwritingHook.sol test/UnderwritingHookLifecycle.t.sol
git commit -m "feat: add underwriting hook lifecycle checks"
```

### Task 5: Add the Underwriter Signature Evaluator

**Files:**
- Create: `contracts/hooks/UnderwriterDecisionEvaluator.sol`
- Create: `test/UnderwriterDecisionEvaluator.t.sol`

**Step 1: Write the failing evaluator tests**

Create tests for:

- open jobs can be completed by signature while the core job is `Funded`
- open jobs can be rejected by signature while the core job is `Funded`
- single-stage jobs require `Submitted`
- close jobs require `Submitted`
- invalid signer reverts
- used nonce reverts
- expired signature reverts

Key test shape:

```solidity
function testCompleteBySigAllowsOpenJobsFromFunded() public {
    _seedOpenJobInFundedState();
    (decision, sig) = _signedCompleteDecision(openJobId, underwriterPk);

    evaluator.completeBySig(decision, sig);

    assertEq(uint256(acp.getJob(openJobId).status), uint256(AgenticCommerceHooked.JobStatus.Completed));
}
```

**Step 2: Run the evaluator tests**

Run:

```bash
forge test --match-path "test/UnderwriterDecisionEvaluator.t.sol"
```

Expected: FAIL because the evaluator contract does not exist yet.

**Step 3: Implement the evaluator**

Create `contracts/hooks/UnderwriterDecisionEvaluator.sol`:

```solidity
contract UnderwriterDecisionEvaluator is EIP712 {
    struct CompleteDecision {
        uint256 jobId;
        bytes32 reason;
        uint64 deadline;
        uint256 nonce;
    }

    struct RejectDecision {
        uint256 jobId;
        bytes32 reason;
        uint64 deadline;
        uint256 nonce;
    }
}
```

Implement:

- typed-data hashing for complete and reject decisions
- `usedNonces[underwriter][nonce]`
- flow-aware status checks:

```solidity
if (hook.jobFlowKind(jobId) == FlowKind.TwoStageOpen) {
    require(job.status == JobStatus.Funded, "wrong open status");
} else {
    require(job.status == JobStatus.Submitted, "wrong submitted status");
}
```

- `acp.complete(...)` and `acp.reject(...)` forwarding on success

**Step 4: Re-run the evaluator tests**

Run:

```bash
forge test --match-path "test/UnderwriterDecisionEvaluator.t.sol"
```

Expected: PASS.

**Step 5: Commit**

```bash
git add contracts/hooks/UnderwriterDecisionEvaluator.sol test/UnderwriterDecisionEvaluator.t.sol
git commit -m "feat: add underwriter signature evaluator"
```

### Task 6: Publish the Example in Repo Docs

**Files:**
- Modify: `README.md`
- Modify: `hook-profiles.md`
- Modify: `contracts/hooks/UnderwritingHook.sol`

**Step 1: Write the doc assertions as failing review checks**

Before editing, verify the repo docs do not yet mention the underwriting example:

```bash
rg "UnderwritingHook|UnderwriterDecisionEvaluator" README.md hook-profiles.md contracts/hooks/UnderwritingHook.sol
```

Expected: no matches.

**Step 2: Add the README example row**

Update `README.md`:

```markdown
| [UnderwritingHook.sol](./contracts/hooks/UnderwritingHook.sol) | C — Experimental | Underwriter-gated job flow with a minimal open/close lifecycle and signed evaluator decisions. |
```

**Step 3: Add profile guidance**

Update `hook-profiles.md` under Profile C:

```markdown
- Example: `UnderwritingHook.sol`
  - Uses an `Open` job for admission and a hook-linked standalone close job for final evidence.
  - Keeps parent/close linkage in hook state rather than extending the core with native close lineage.
  - Omits collateral settlement, coordinator, and slash flows from the MCU prototype.
```

**Step 4: Add NatSpec to the hook**

At the top of `contracts/hooks/UnderwritingHook.sol`, include:

- **USE CASE**
- **FLOW**
- **TRUST MODEL**

The `FLOW` section should explicitly describe:

1. `createJob(...)` for single-stage
2. `createOpenJob(...)` for open-stage admission
3. `createJob(...)` with `parentJobId` for close-stage finalization
4. evaluator-complete from `Funded` for open jobs
5. evaluator-complete from `Submitted` for single-stage and close jobs

**Step 5: Re-run focused tests and scans**

Run:

```bash
forge test --match-path "test/UnderwritingHookAdmission.t.sol"
forge test --match-path "test/UnderwritingHookLifecycle.t.sol"
forge test --match-path "test/UnderwriterDecisionEvaluator.t.sol"
rg "fund\\(uint256,bytes\\)|fund\\(jobId, \\\"\\\"\\)" .
```

Expected:

- all three test files PASS
- ripgrep returns no old fund-signature references

**Step 6: Commit**

```bash
git add README.md hook-profiles.md contracts/hooks/UnderwritingHook.sol
git commit -m "docs: publish underwriting hook example"
```

## Notes for the Implementer

- Prefer a mock ACP kernel in hook-unit tests when testing hook callbacks directly.
- Use full end-to-end ACP tests only where core lifecycle behavior matters.
- Do not reintroduce the full MCU surface by stealth. If you need:
  - dispute windows
  - collateral release requests
  - slashing
  - settlement identity beyond `parentJobId`

stop and write a separate plan for a larger experimental settlement system.

## Execution Handoff

Plan complete and saved to `docs/plans/2026-03-17-underwriting-hook-example.md`. Two execution options:

**1. Subagent-Driven (this session)** - dispatch a fresh subagent per task, review between tasks, faster iteration.

**2. Parallel Session (separate)** - open a new session with `superpowers:executing-plans`, then execute the plan with checkpoints.

Choose the option only after the repo is ready to install dependencies and compile the full hook set.
