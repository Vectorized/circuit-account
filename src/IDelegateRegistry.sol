// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

interface IDelegateRegistry {
    function delegateERC20(address to, address contract_, bytes32 rights, uint256 amount)
        external
        payable
        returns (bytes32);
    function checkDelegateForERC20(address to, address from, address contract_, bytes32 rights)
        external
        view
        returns (uint256);
}
