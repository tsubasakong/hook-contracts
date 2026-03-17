# Underwriting Hook Example Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a concise underwriting example to `hook-contracts` that supports underwriter-signed single-stage jobs and an optional hook-linked follow-on close job without changing `AgenticCommerceHooked`.

**Architecture:** Keep `contracts/AgenticCommerceHooked.sol` untouched and preserve the standard ACP lifecycle for every job. Implement a single `contracts/hooks/UnderwritingHook.sol` contract that inherits `BaseACPHook` and also serves as the ACP evaluator for those jobs via `completeBySig()` and `rejectBySig()`. Track parent/close linkage and one extra hook-specific phase bit (`AwaitingClose`) entirely inside the hook; do not port MCU coordinator, escrow, collateral, or dispute logic.

**Tech Stack:** Solidity `^0.8.20`, Foundry, `forge-std`, OpenZeppelin `ECDSA` + `EIP712`, `AgenticCommerceHooked`, `BaseACPHook`.

---

## Scope Guardrails

- Do not modify `contracts/AgenticCommerceHooked.sol`.
- Do not add `createOpenJob`, `JobKind`, or native parent/close getters to the core.
- Do not create a separate `UnderwriterDecisionEvaluator.sol`.
- Every underwritten job must use the existing ACP rail: `createJob -> setBudget -> fund -> submit -> complete/reject`.
- The hook contract itself must be passed as both `hook` and `evaluator` at job creation time.
- Keep refund semantics unchanged: `claimRefund()` remains non-hookable.
- Keep settlement, collateral, and dispute logic out of scope.
- Treat the example as `Profile C - Experimental`.

## Flow Summary

### Single-stage

```text
client
  -> createJob(provider, evaluator=hook, hook=hook)
  -> setBudget(jobId, fee, abi.encode(commit{parentJobId=0, allowCloseJob=false}))
  -> fund(jobId, fee, "")
provider
  -> submit(jobId, bundleHash, abi.encode(evidence))
underwriter
  -> sign CompleteDecision or RejectDecision
caller
  -> hook.completeBySig(...) or hook.rejectBySig(...)
hook/evaluator
  -> acp.complete(...) or acp.reject(...)
```

### Parent + close

```text
parent job
  createJob -> setBudget(commit{parentJobId=0, allowCloseJob=true}) -> fund -> submit -> completeBySig
  hook marks parent AwaitingClose

close job
  createJob -> setBudget(commit{parentJobId=parentJobId, allowCloseJob=false}) -> fund -> submit -> completeBySig/rejectBySig
  hook clears linkage on success, and clears only the active close slot on reject/expiry
```

## Proposed Contract Shape

### `contracts/hooks/UnderwritingHook.sol`

Responsibilities:

- inherit `BaseACPHook`
- store admin and underwriter registry
- store one immutable underwriting commit per job
- store the budget committed with the first underwriting commit
- validate that the first `setBudget()` happens only after `provider` is already set
- validate that `job.hook == address(this)` and `job.evaluator == address(this)` for underwritten jobs
- classify jobs from the committed payload:
  - `SingleStage`: `parentJobId == 0 && allowCloseJob == false`
  - `ParentStage`: `parentJobId == 0 && allowCloseJob == true`
  - `CloseStage`: `parentJobId != 0`
- track hook-only lineage:
  - `awaitingCloseByJobId[parentJobId]`
  - `parentJobIdByCloseJobId[closeJobId]`
  - `activeCloseJobIdByParentJobId[parentJobId]`
- lazily reclaim a stale close slot when a replacement close job is committed and the old close job is already `Rejected` or `Expired`
- validate submit evidence against committed `bundleHash`, `policyHash`, and `quoteIdHash`
- expose evaluator entrypoints:
  - `completeBySig(CompleteDecision, bytes)`
  - `rejectBySig(RejectDecision, bytes)`

Minimal data shape:

```solidity
struct UnderwriteCommit {
    uint256 parentJobId;
    address underwriter;
    uint64 validUntil;
    bytes32 policyHash;
    bytes32 quoteIdHash;
    bytes32 termsHash;
    bool allowCloseJob;
}

struct SubmitEvidence {
    bytes32 bundleHash;
    bytes32 policyHash;
    bytes32 quoteIdHash;
}

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
```

Notes:

- `termsHash` is committed for auditability but does not need a separate submit-time payload in v1.
- `Committed`, `Funded`, and `EvidenceSubmitted` do not need hook-local enums; ACP `JobStatus` plus successful hook callbacks already cover them.
- The only extra phase bit this example should own is `AwaitingClose`.

## Task 1: Normalize Foundry Setup

**Files:**
- Create: `foundry.toml`
- Create: `lib/openzeppelin-contracts/` via `forge install`
- Create: `lib/forge-std/` via `forge install`
- Verify: `test/BaseACPHookFundDispatch.t.sol`

**Step 1: Write the failing build expectation**

Run:

```bash
forge build
```

Expected: FAIL with unresolved `@openzeppelin` imports in the current checkout.

**Step 2: Add Foundry config**

Create `foundry.toml`:

```toml
[profile.default]
src = "contracts"
test = "test"
out = "out"
libs = ["lib"]
solc_version = "0.8.20"
remappings = [
    "@openzeppelin/contracts/=lib/openzeppelin-contracts/contracts/",
    "forge-std/=lib/forge-std/src/"
]
```

**Step 3: Install dependencies**

Run:

```bash
forge install --no-git OpenZeppelin/openzeppelin-contracts
forge install --no-git foundry-rs/forge-std
```

**Step 4: Re-run the existing regression test**

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

## Task 2: Add the Hook Contract and Admission Rules

**Files:**
- Create: `contracts/hooks/UnderwritingHook.sol`
- Create: `test/helpers/UnderwritingHookTestBase.sol`
- Create: `test/UnderwritingHookAdmission.t.sol`

**Step 1: Write the failing admission tests**

Create tests for:

- first underwriting commit requires a registered underwriter
- first underwriting commit requires `provider` already set
- first underwriting commit requires `job.hook == address(hook)` and `job.evaluator == address(hook)`
- first commit locks both `amount` and `UnderwriteCommit`
- same `setBudget()` replay with identical payload is allowed
- close commit requires parent job to have been committed as `allowCloseJob = true`
- close commit requires parent job to be `Completed` and hook-marked `AwaitingClose`
- close commit requires same client, provider, evaluator, and hook as the parent
- close commit requires same underwriter as the parent
- second active close job is blocked while the first one is still live

Key test shapes:

```solidity
function testFirstCommitLocksBudgetAndPayload() public {
    uint256 jobId = _createBaseJob(address(hook), address(hook));
    UnderwritingHook.UnderwriteCommit memory commit = _singleStageCommit();

    vm.prank(client);
    acp.setBudget(jobId, 100e6, abi.encode(commit));

    vm.prank(client);
    vm.expectRevert(UnderwritingHook.CommitLocked.selector);
    acp.setBudget(jobId, 101e6, abi.encode(commit));
}

function testCloseCommitStoresParentLinkage() public {
    uint256 parentJobId = _completeParentStageJob();

    uint256 closeJobId = _createBaseJob(address(hook), address(hook));
    UnderwritingHook.UnderwriteCommit memory closeCommit = _closeStageCommit(parentJobId);

    vm.prank(client);
    acp.setBudget(closeJobId, 25e6, abi.encode(closeCommit));

    assertEq(hook.getParentJobId(closeJobId), parentJobId);
    assertEq(hook.getActiveCloseJobId(parentJobId), closeJobId);
}
```

**Step 2: Run the new test file**

Run:

```bash
forge test --match-path "test/UnderwritingHookAdmission.t.sol"
```

Expected: FAIL because `UnderwritingHook.sol` and the test base do not exist yet.

**Step 3: Create the shared test base**

Create `test/helpers/UnderwritingHookTestBase.sol` with:

- `forge-std/Test.sol` import
- a tiny mintable ERC20 test token
- ACP + hook deployment helpers
- reusable addresses and private keys for client, provider, underwriter
- helper methods for:
  - `_createBaseJob(hook, evaluator)`
  - `_singleStageCommit()`
  - `_parentStageCommit()`
  - `_closeStageCommit(parentJobId)`
  - `_fundJob(jobId, amount)`
  - `_submitEvidence(jobId, evidence)`
  - signing `CompleteDecision` and `RejectDecision`

**Step 4: Implement the admission half of the hook**

Create `contracts/hooks/UnderwritingHook.sol` and implement:

- constructor: `constructor(address acpContract_, address admin_) BaseACPHook(acpContract_)`
- admin-gated `registerUnderwriter()` and `unregisterUnderwriter()`
- view getters:
  - `getCommit(uint256 jobId)`
  - `isAwaitingClose(uint256 jobId)`
  - `getParentJobId(uint256 closeJobId)`
  - `getActiveCloseJobId(uint256 parentJobId)`
- `_preSetBudget(...)` to:
  - decode `UnderwriteCommit`
  - validate `provider` is already set
  - validate `job.hook == address(this)` and `job.evaluator == address(this)`
  - enforce `validUntil > block.timestamp`
  - classify the flow from `parentJobId` and `allowCloseJob`
  - register the first commit
  - on later calls, require exact same `(amount, commit)` or revert

Use this exact shape for the lock check:

```solidity
bytes32 newCommitHash = keccak256(abi.encode(commit));

if (commitHashByJobId[jobId] == bytes32(0)) {
    commitHashByJobId[jobId] = newCommitHash;
    committedBudgetByJobId[jobId] = amount;
    commits[jobId] = commit;
} else {
    if (commitHashByJobId[jobId] != newCommitHash) revert CommitLocked();
    if (committedBudgetByJobId[jobId] != amount) revert CommitLocked();
    return;
}
```

For close-stage validation:

```solidity
_clearStaleCloseIfTerminal(commit.parentJobId);

if (!awaitingCloseByJobId[commit.parentJobId]) revert ParentNotAwaitingClose();
if (activeCloseJobIdByParentJobId[commit.parentJobId] != 0) revert ActiveCloseExists();
if (parentCommit.underwriter != commit.underwriter) revert ParentMismatch();
```

Then add the actor checks against the parent ACP job:

- same `client`
- same `provider`
- same `evaluator`
- same `hook`

**Step 5: Re-run the admission tests**

Run:

```bash
forge test --match-path "test/UnderwritingHookAdmission.t.sol"
```

Expected: PASS.

**Step 6: Commit**

```bash
git add contracts/hooks/UnderwritingHook.sol test/helpers/UnderwritingHookTestBase.sol test/UnderwritingHookAdmission.t.sol
git commit -m "feat: add underwriting hook admission rules"
```

## Task 3: Add Submit Validation and Underwriter-Signed Decisions

**Files:**
- Modify: `contracts/hooks/UnderwritingHook.sol`
- Modify: `test/helpers/UnderwritingHookTestBase.sol`
- Create: `test/UnderwritingHookDecisions.t.sol`

**Step 1: Write the failing decision/lifecycle tests**

Create tests for:

- `submit()` reverts if `SubmitEvidence.bundleHash` does not match `deliverable`
- `submit()` reverts if `policyHash` or `quoteIdHash` differs from the committed profile
- `completeBySig()` succeeds for a submitted single-stage job
- `rejectBySig()` succeeds for a submitted close-stage job
- invalid signer reverts
- used nonce reverts
- expired signature reverts
- completing a parent-stage job sets `AwaitingClose = true`
- completing a close-stage job clears:
  - `activeCloseJobIdByParentJobId[parentJobId]`
  - `awaitingCloseByJobId[parentJobId]`
- rejecting a close-stage job clears only the active close slot and leaves the parent in `AwaitingClose`
- an expired close job can be replaced because stale linkage is cleared lazily on the next close commit

Key test shapes:

```solidity
function testParentStageCompletionMarksAwaitingClose() public {
    uint256 parentJobId = _createCommittedParentStageJob();
    _fundJob(parentJobId, 100e6);
    _submitEvidence(parentJobId, _matchingEvidence());

    (UnderwritingHook.CompleteDecision memory decision, bytes memory sig) =
        _signedCompleteDecision(parentJobId, underwriterPk);

    hook.completeBySig(decision, sig);

    assertTrue(hook.isAwaitingClose(parentJobId));
}

function testCloseRejectClearsOnlyActiveCloseSlot() public {
    uint256 parentJobId = _completeParentStageJob();
    uint256 closeJobId = _createAndSubmitCloseJob(parentJobId);

    (UnderwritingHook.RejectDecision memory decision, bytes memory sig) =
        _signedRejectDecision(closeJobId, underwriterPk);

    hook.rejectBySig(decision, sig);

    assertEq(hook.getActiveCloseJobId(parentJobId), 0);
    assertTrue(hook.isAwaitingClose(parentJobId));
}
```

**Step 2: Run the decision test file**

Run:

```bash
forge test --match-path "test/UnderwritingHookDecisions.t.sol"
```

Expected: FAIL because submit-time evidence validation and signature decision methods are not implemented yet.

**Step 3: Implement the lifecycle + evaluator half**

In `contracts/hooks/UnderwritingHook.sol` add:

- `_postSubmit(...)` to decode `SubmitEvidence` and require:
  - `deliverable == evidence.bundleHash`
  - `evidence.policyHash == commit.policyHash`
  - `evidence.quoteIdHash == commit.quoteIdHash`
- `EIP712` domain setup and `ECDSA` recovery
- `mapping(address => mapping(uint256 => bool)) usedNonces`
- `completeBySig(...)`
- `rejectBySig(...)`
- `_postComplete(...)`:
  - if `parentJobId == 0 && allowCloseJob == true`, mark `awaitingCloseByJobId[jobId] = true`
  - if `parentJobId != 0`, clear the parent’s active close slot and set `awaitingCloseByJobId[parentJobId] = false`
- `_postReject(...)`:
  - if `parentJobId != 0`, clear only the active close slot
- `_clearStaleCloseIfTerminal(...)` helper:
  - if there is no active close job, return
  - if the current active close job is `Rejected` or `Expired`, delete `activeCloseJobIdByParentJobId[parentJobId]`
  - do not add a public `clearExpiredCloseJob()` function

Use this exact status check in both decision methods:

```solidity
AgenticCommerceHooked.Job memory job = _getJob(jobId);
if (job.status != AgenticCommerceHooked.JobStatus.Submitted) revert WrongDecisionStatus();
```

Then call the core as the evaluator contract:

```solidity
acp.complete(decision.jobId, decision.reason, "");
acp.reject(decision.jobId, decision.reason, "");
```

**Step 4: Re-run the focused tests**

Run:

```bash
forge test --match-path "test/UnderwritingHookAdmission.t.sol"
forge test --match-path "test/UnderwritingHookDecisions.t.sol"
```

Expected: PASS.

**Step 5: Commit**

```bash
git add contracts/hooks/UnderwritingHook.sol test/helpers/UnderwritingHookTestBase.sol test/UnderwritingHookDecisions.t.sol
git commit -m "feat: add underwriting signature decisions"
```

## Task 4: Publish the Example in Repo Docs

**Files:**
- Modify: `README.md`
- Modify: `hook-profiles.md`
- Modify: `contracts/hooks/UnderwritingHook.sol`

**Step 1: Write the doc assertions as review checks**

Run:

```bash
rg "UnderwritingHook" README.md hook-profiles.md
rg "UnderwriterDecisionEvaluator|createOpenJob|TwoStageOpen" README.md hook-profiles.md contracts/hooks/UnderwritingHook.sol
```

Expected:

- first `rg` returns no matches before the docs are updated
- second `rg` returns no matches after the implementation is aligned to the v2 design

**Step 2: Add the README example row**

Update `README.md`:

```markdown
| [UnderwritingHook.sol](./contracts/hooks/UnderwritingHook.sol) | C - Experimental | Underwriter-signed job approval with immutable underwriting commits and an optional hook-linked follow-on close job, all on the unchanged ACP lifecycle. |
```

**Step 3: Add profile guidance**

Update `hook-profiles.md` under Profile C:

```markdown
- Example: `UnderwritingHook.sol`
  - Uses the standard ACP lifecycle for every job; it does not extend the core with `createOpenJob(...)`.
  - Supports both single-stage underwritten jobs and a hook-linked follow-on close job.
  - Keeps parent/close linkage and `AwaitingClose` state entirely inside the hook.
  - Omits coordinator, collateral, dispute, and settlement sidecars from the MCU prototype.
```

**Step 4: Add NatSpec to the hook**

At the top of `contracts/hooks/UnderwritingHook.sol`, include:

- **USE CASE**
- **FLOW**
- **TRUST MODEL**

The `FLOW` section should explicitly describe:

1. `createJob(..., evaluator = hook, hook = hook)` for a single-stage job
2. `setBudget(..., abi.encode(commit))` as the commit-once underwriting step
3. `submit(..., abi.encode(evidence))` as the evidence handoff step
4. `completeBySig(...)` and `rejectBySig(...)` as underwriter-signed evaluator actions
5. optional second `createJob(...)` with `parentJobId` for the close stage

**Step 5: Re-run focused tests and scans**

Run:

```bash
forge test --match-path "test/UnderwritingHookAdmission.t.sol"
forge test --match-path "test/UnderwritingHookDecisions.t.sol"
rg "UnderwriterDecisionEvaluator|createOpenJob|TwoStageOpen" README.md hook-profiles.md contracts/hooks/UnderwritingHook.sol
```

Expected:

- both test files PASS
- the final `rg` returns no matches

**Step 6: Commit**

```bash
git add README.md hook-profiles.md contracts/hooks/UnderwritingHook.sol
git commit -m "docs: publish underwriting hook example"
```

## Notes for the Implementer

- Prefer full ACP integration tests over callback-only mocks here, because the core lifecycle is intentionally unchanged and is part of what this example is proving.
- Keep the hook self-contained. If a helper type or struct is only used by `UnderwritingHook.sol`, define it there instead of creating a second source file.
- The hook is allowed to own additional metadata, but it should not become a coordinator.
- If implementation pressure starts pushing toward any of the following, stop and write a new protocol-variant plan:
  - `createOpenJob(...)`
  - `JobKind`
  - direct `complete()` from `Funded`
  - native core parent/close lineage
  - collateral or dispute settlement sidecars

## Execution Handoff

Plan complete and saved to `docs/plans/2026-03-17-underwriting-hook-example.md`. Two execution options:

**1. Subagent-Driven (this session)** - dispatch a fresh subagent per task, review between tasks, faster iteration.

**2. Parallel Session (separate)** - open a new session with `superpowers:executing-plans`, then execute the plan with checkpoints.

Choose the option after the Foundry bootstrap step is in place and the base hook regression test is passing.
