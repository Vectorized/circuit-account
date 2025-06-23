// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "./utils/SoladyTest.sol";
import "./utils/mocks/MockCircuitAccount.sol";

contract BaseTest is SoladyTest {
    MockCircuitAccount ca;

    function setUp() public {
        ca = new MockCircuitAccount();
    }
}
