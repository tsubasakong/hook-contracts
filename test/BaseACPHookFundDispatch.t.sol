// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../contracts/BaseACPHook.sol";

contract TestableFundHook is BaseACPHook {
    bool public preFundCalled;
    bool public postFundCalled;
    bytes public lastPreFundData;
    bytes public lastPostFundData;

    constructor(address acpContract_) BaseACPHook(acpContract_) {}

    function _preFund(uint256, bytes memory optParams) internal override {
        preFundCalled = true;
        lastPreFundData = optParams;
    }

    function _postFund(uint256, bytes memory optParams) internal override {
        postFundCalled = true;
        lastPostFundData = optParams;
    }
}

contract BaseACPHookFundDispatchTest {
    bytes4 private constant SEL_FUND = bytes4(keccak256("fund(uint256,uint256,bytes)"));

    function testFundSelectorDispatchesPreAndPostHooks() public {
        TestableFundHook hook = new TestableFundHook(address(this));
        bytes memory optParams = abi.encode(uint256(123), bytes32("payload"));

        hook.beforeAction(7, SEL_FUND, optParams);
        hook.afterAction(7, SEL_FUND, optParams);

        require(hook.preFundCalled(), "preFund not called");
        require(hook.postFundCalled(), "postFund not called");
        require(keccak256(hook.lastPreFundData()) == keccak256(optParams), "preFund data mismatch");
        require(keccak256(hook.lastPostFundData()) == keccak256(optParams), "postFund data mismatch");
    }
}
