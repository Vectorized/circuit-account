// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../src/CircuitAccount.sol";
import "./Base.t.sol";

contract CircuitAccountTest is BaseTest {
    function testHash(address spender, address token, uint8 period) public view {
        if (period > uint8(CircuitAccount.SpendPeriod.Forever)) period = 0;

        bytes32 expected = keccak256(abi.encodePacked(spender, token, period));
        assertEq(ca.hash(spender, token, CircuitAccount.SpendPeriod(period)), expected);
    }
}
