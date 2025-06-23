// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../../../src/CircuitAccount.sol";
import "../Brutalizer.sol";

contract MockCircuitAccount is CircuitAccount, Brutalizer {
    function hash(address spender, address token, SpendPeriod period)
        public
        view
        returns (bytes32)
    {
        _brutalizeScratchSpace();
        return _hash(_brutalized(spender), _brutalized(token), period);
    }
}
