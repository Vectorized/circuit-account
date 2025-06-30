// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../src/CircuitAccount.sol";
import "./Base.t.sol";

contract CircuitAccountTest is BaseTest {
    function testSpendsHash(address spender, address token, uint8 period) public {
        CircuitAccountSet memory d = _randomCircuitAccountSet();
        if (period > uint8(CircuitAccount.SpendPeriod.Forever)) period = 0;

        bytes32 expected = keccak256(abi.encodePacked(spender, token, period));
        assertEq(d.d.hash(spender, token, CircuitAccount.SpendPeriod(period)), expected);
    }

    struct _SetAndGetSpendsTemps {
        bool hasNativeToken;
        CircuitAccount.SpendConfig[] spendConfigs;
        CircuitAccount.SpendInfo[] spendInfos;
    }

    function testSetAndGetSpends(bytes32) public {
        CircuitAccountSet memory d = _randomCircuitAccountSet();
        _SetAndGetSpendsTemps memory t;
        t.spendConfigs = new CircuitAccount.SpendConfig[](_bound(_random(), 0, 8));

        for (uint256 i; i < t.spendConfigs.length; ++i) {
            if (!t.hasNativeToken && _randomChance(8)) {
                t.spendConfigs[i].token = address(0);
                t.hasNativeToken = true;
            } else {
                t.spendConfigs[i].token = LibClone.clone(address(_mockERC20));
            }
            t.spendConfigs[i].period = _randomSpendPeriod();
            t.spendConfigs[i].limit = _random();
        }

        vm.prank(d.master);
        d.d.setActiveSpendLimits(t.spendConfigs);

        t.spendInfos = d.d.spendInfos();
        for (uint256 i; i < t.spendConfigs.length; ++i) {
            assertEq(t.spendInfos[i].token, t.spendConfigs[i].token);
            assertEq(t.spendInfos[i].limit, t.spendConfigs[i].limit);
            assertEq(uint8(t.spendInfos[i].period), uint8(t.spendConfigs[i].period));
        }
    }

    function testSetAndGetSpendsGas() public {
        vm.pauseGasMetering();
        _SetAndGetSpendsTemps memory t;
        CircuitAccountSet memory d = _randomCircuitAccountSet();
        t.spendConfigs = new CircuitAccount.SpendConfig[](10);

        for (uint256 i; i < t.spendConfigs.length; ++i) {
            t.spendConfigs[i].token = LibClone.clone(address(_mockERC20));
            t.spendConfigs[i].period = _randomSpendPeriod();
            t.spendConfigs[i].limit = _random();
        }
        vm.resumeGasMetering();

        vm.prank(d.master);
        d.d.setActiveSpendLimits(t.spendConfigs);

        assertEq(d.d.spendInfos().length, t.spendConfigs.length);
    }

    function testSetAndGetSpendsWithDelegateRegistryGas() public {
        vm.pauseGasMetering();
        _SetAndGetSpendsTemps memory t;
        CircuitAccountSet memory d = _randomCircuitAccountSet(true);
        t.spendConfigs = new CircuitAccount.SpendConfig[](10);

        for (uint256 i; i < t.spendConfigs.length; ++i) {
            t.spendConfigs[i].token = LibClone.clone(address(_mockERC20));
            t.spendConfigs[i].period = _randomSpendPeriod();
            t.spendConfigs[i].limit = _random();
        }
        vm.resumeGasMetering();

        vm.prank(d.master);
        d.d.setActiveSpendLimits(t.spendConfigs);

        assertEq(d.d.spendInfos().length, t.spendConfigs.length);
    }
}
