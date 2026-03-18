// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../../contracts/AgenticCommerceHooked.sol";
import "../../contracts/hooks/UnderwritingHook.sol";
import "../../contracts/hooks/UnderwritingCoordinator.sol";
import "../../contracts/hooks/UnderwritingEvaluator.sol";
import "../../contracts/hooks/UnderwritingTypes.sol";

contract MintableToken is ERC20 {
    constructor() ERC20("Mock USD", "mUSD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

abstract contract UnderwritingHookTestBase is Test {
    bytes32 internal constant COMPLETE_TYPEHASH =
        keccak256("CompleteDecision(uint256 jobId,bytes32 reason,uint64 deadline,uint256 nonce)");
    bytes32 internal constant REJECT_TYPEHASH =
        keccak256("RejectDecision(uint256 jobId,bytes32 reason,uint64 deadline,uint256 nonce)");
    bytes32 internal constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    uint256 internal constant CLIENT_PK = 0xA11CE;
    uint256 internal constant PROVIDER_PK = 0xB0B;
    uint256 internal constant UNDERWRITER_PK = 0xCAFE;
    uint256 internal constant OUTSIDER_PK = 0xD00D;

    uint256 internal constant DEFAULT_BUDGET = 100e6;
    uint256 internal constant CLOSE_BUDGET = 25e6;

    bytes4 internal constant ERR_ZERO_ADDRESS = bytes4(keccak256("ZeroAddress()"));
    bytes4 internal constant ERR_UNDERWRITER_NOT_REGISTERED = bytes4(keccak256("UnderwriterNotRegistered()"));
    bytes4 internal constant ERR_PROVIDER_REQUIRED = bytes4(keccak256("ProviderRequired()"));
    bytes4 internal constant ERR_EVALUATOR_MISMATCH = bytes4(keccak256("EvaluatorMismatch()"));
    bytes4 internal constant ERR_COMMIT_EXPIRED = bytes4(keccak256("CommitExpired()"));
    bytes4 internal constant ERR_COMMIT_LOCKED = bytes4(keccak256("CommitLocked()"));
    bytes4 internal constant ERR_PARENT_NOT_AWAITING_CLOSE = bytes4(keccak256("ParentNotAwaitingClose()"));
    bytes4 internal constant ERR_ACTIVE_CLOSE_EXISTS = bytes4(keccak256("ActiveCloseExists()"));
    bytes4 internal constant ERR_PARENT_MISMATCH = bytes4(keccak256("ParentMismatch()"));
    bytes4 internal constant ERR_EVIDENCE_MISMATCH = bytes4(keccak256("EvidenceMismatch()"));
    bytes4 internal constant ERR_INVALID_STATE = bytes4(keccak256("InvalidState()"));

    bytes32 internal constant DEFAULT_POLICY_HASH = keccak256("policy");
    bytes32 internal constant DEFAULT_QUOTE_ID_HASH = keccak256("quote");
    bytes32 internal constant DEFAULT_TERMS_HASH = keccak256("terms");
    bytes32 internal constant DEFAULT_REASON = keccak256("approved");
    bytes32 internal constant DEFAULT_REJECT_REASON = keccak256("rejected");

    address internal client;
    address internal provider;
    address internal underwriter;
    address internal outsider;
    address internal treasury;

    MintableToken internal token;
    AgenticCommerceHooked internal acp;
    UnderwritingHook internal hook;
    UnderwritingEvaluator internal evaluator;
    UnderwritingCoordinator internal coordinator;

    function setUp() public virtual {
        client = vm.addr(CLIENT_PK);
        provider = vm.addr(PROVIDER_PK);
        underwriter = vm.addr(UNDERWRITER_PK);
        outsider = vm.addr(OUTSIDER_PK);
        treasury = makeAddr("treasury");

        token = new MintableToken();
        acp = new AgenticCommerceHooked(address(token), treasury);
        hook = new UnderwritingHook(address(acp), address(this));
        evaluator = new UnderwritingEvaluator(address(acp), address(hook));
        coordinator = new UnderwritingCoordinator(address(acp), address(hook));
        hook.setWiring(address(evaluator), address(coordinator));

        token.mint(client, 1_000_000e6);

        vm.prank(client);
        token.approve(address(acp), type(uint256).max);
    }

    function _registerUnderwriter() internal {
        hook.registerUnderwriter(underwriter);
    }

    function _createBaseJob(address hookAddress, address evaluatorAddress) internal returns (uint256 jobId) {
        vm.prank(client);
        jobId = acp.createJob(provider, evaluatorAddress, block.timestamp + 1 days, "job", hookAddress);
    }

    function _createJobWithoutProvider(address hookAddress, address evaluatorAddress) internal returns (uint256 jobId) {
        vm.prank(client);
        jobId = acp.createJob(address(0), evaluatorAddress, block.timestamp + 1 days, "job", hookAddress);
    }

    function _createJobWithProvider(address providerAddress, address hookAddress, address evaluatorAddress)
        internal
        returns (uint256 jobId)
    {
        vm.prank(client);
        jobId = acp.createJob(providerAddress, evaluatorAddress, block.timestamp + 1 days, "job", hookAddress);
    }

    function _singleStageCommit() internal view returns (UnderwritingTypes.UnderwriteCommit memory) {
        return UnderwritingTypes.UnderwriteCommit({
            parentJobId: 0,
            underwriter: underwriter,
            validUntil: uint64(block.timestamp + 1 days),
            policyHash: DEFAULT_POLICY_HASH,
            quoteIdHash: DEFAULT_QUOTE_ID_HASH,
            termsHash: DEFAULT_TERMS_HASH,
            allowCloseJob: false
        });
    }

    function _parentStageCommit() internal view returns (UnderwritingTypes.UnderwriteCommit memory) {
        return UnderwritingTypes.UnderwriteCommit({
            parentJobId: 0,
            underwriter: underwriter,
            validUntil: uint64(block.timestamp + 1 days),
            policyHash: DEFAULT_POLICY_HASH,
            quoteIdHash: DEFAULT_QUOTE_ID_HASH,
            termsHash: DEFAULT_TERMS_HASH,
            allowCloseJob: true
        });
    }

    function _closeStageCommit(uint256 parentJobId) internal view returns (UnderwritingTypes.UnderwriteCommit memory) {
        return UnderwritingTypes.UnderwriteCommit({
            parentJobId: parentJobId,
            underwriter: underwriter,
            validUntil: uint64(block.timestamp + 1 days),
            policyHash: DEFAULT_POLICY_HASH,
            quoteIdHash: DEFAULT_QUOTE_ID_HASH,
            termsHash: DEFAULT_TERMS_HASH,
            allowCloseJob: false
        });
    }

    function _matchingEvidence() internal pure returns (UnderwritingTypes.SubmitEvidence memory) {
        return UnderwritingTypes.SubmitEvidence({
            bundleHash: keccak256("bundle"),
            policyHash: DEFAULT_POLICY_HASH,
            quoteIdHash: DEFAULT_QUOTE_ID_HASH
        });
    }

    function _mismatchedEvidence() internal pure returns (UnderwritingTypes.SubmitEvidence memory) {
        return UnderwritingTypes.SubmitEvidence({
            bundleHash: keccak256("other-bundle"),
            policyHash: DEFAULT_POLICY_HASH,
            quoteIdHash: DEFAULT_QUOTE_ID_HASH
        });
    }

    function _commitBudget(uint256 jobId, uint256 amount, UnderwritingTypes.UnderwriteCommit memory commit) internal {
        vm.prank(client);
        acp.setBudget(jobId, amount, abi.encode(commit));
    }

    function _fundJob(uint256 jobId, uint256 amount) internal {
        vm.prank(client);
        acp.fund(jobId, amount, "");
    }

    function _protectJob(uint256 jobId) internal {
        vm.prank(client);
        coordinator.orchestrateFunding(jobId);
    }

    function _submitEvidence(uint256 jobId, UnderwritingTypes.SubmitEvidence memory evidence) internal {
        vm.prank(provider);
        acp.submit(jobId, evidence.bundleHash, abi.encode(evidence));
    }

    function _createCommittedParentStageJob() internal returns (uint256 parentJobId) {
        _registerUnderwriter();
        parentJobId = _createBaseJob(address(hook), address(evaluator));
        _commitBudget(parentJobId, DEFAULT_BUDGET, _parentStageCommit());
    }

    function _completeParentStageJob() internal returns (uint256 parentJobId) {
        parentJobId = _createCommittedParentStageJob();
        _fundJob(parentJobId, DEFAULT_BUDGET);
        _protectJob(parentJobId);
        _submitEvidence(parentJobId, _matchingEvidence());

        (UnderwritingTypes.CompleteDecision memory decision, bytes memory signature) =
            _signedCompleteDecision(parentJobId, UNDERWRITER_PK);
        evaluator.completeBySig(decision, signature);
    }

    function _createAndSubmitCloseJob(uint256 parentJobId) internal returns (uint256 closeJobId) {
        closeJobId = _createBaseJob(address(hook), address(evaluator));
        _commitBudget(closeJobId, CLOSE_BUDGET, _closeStageCommit(parentJobId));
        _fundJob(closeJobId, CLOSE_BUDGET);
        _protectJob(closeJobId);
        _submitEvidence(closeJobId, _matchingEvidence());
    }

    function _signedCompleteDecision(uint256 jobId, uint256 signerPk)
        internal
        view
        returns (UnderwritingTypes.CompleteDecision memory decision, bytes memory signature)
    {
        decision = UnderwritingTypes.CompleteDecision({
            jobId: jobId,
            reason: DEFAULT_REASON,
            deadline: uint64(block.timestamp + 1 days),
            nonce: jobId * 2
        });

        bytes32 structHash =
            keccak256(abi.encode(COMPLETE_TYPEHASH, decision.jobId, decision.reason, decision.deadline, decision.nonce));
        signature = _signDigest(signerPk, _hashTypedDataV4(structHash));
    }

    function _signedRejectDecision(uint256 jobId, uint256 signerPk)
        internal
        view
        returns (UnderwritingTypes.RejectDecision memory decision, bytes memory signature)
    {
        decision = UnderwritingTypes.RejectDecision({
            jobId: jobId,
            reason: DEFAULT_REJECT_REASON,
            deadline: uint64(block.timestamp + 1 days),
            nonce: (jobId * 2) + 1
        });

        bytes32 structHash =
            keccak256(abi.encode(REJECT_TYPEHASH, decision.jobId, decision.reason, decision.deadline, decision.nonce));
        signature = _signDigest(signerPk, _hashTypedDataV4(structHash));
    }

    function _hashTypedDataV4(bytes32 structHash) internal view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
    }

    function _domainSeparator() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256(bytes("Underwriting Evaluator")),
                keccak256(bytes("1")),
                block.chainid,
                address(evaluator)
            )
        );
    }

    function _signDigest(uint256 signerPk, bytes32 digest) internal pure returns (bytes memory signature) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, digest);
        signature = abi.encodePacked(r, s, v);
    }
}
