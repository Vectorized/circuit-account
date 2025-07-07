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

    struct _SpendLimitUpdatedForBotExecuteTemps {
        MockERC20 erc20;
        uint256 mintAmount;
        uint256 transferAmount;
        ERC7821.Call[] calls;
        address dst;
        CircuitAccount.SpendConfig[] spendConfigs;
        CircuitAccount.SpendInfo[] spendInfos;
        uint256 executeTimestamp;
    }

    function testSpendLimitUpdatedForBotExecute(bytes32) public {
        _SpendLimitUpdatedForBotExecuteTemps memory t;
        (t.dst,) = _randomUniqueSigner();
        CircuitAccountSet memory d = _randomCircuitAccountSet();

        vm.warp(t.executeTimestamp = _bound(_random(), 86400 * 1, 86400 * 100));

        CircuitAccount.SpendConfig memory spendConfig;
        spendConfig.token = LibClone.clone(address(_mockERC20));
        spendConfig.limit = 10 ether;
        spendConfig.period = CircuitAccount.SpendPeriod.Day;

        t.erc20 = MockERC20(spendConfig.token);
        t.erc20.mint(d.eoa, t.mintAmount = _bound(_random(), 5 ether, 25 ether));

        t.calls = new ERC7821.Call[](1);
        t.calls[0].to = address(t.erc20);
        t.calls[0].data = abi.encodeWithSignature(
            "anotherTransfer(address,uint256)",
            t.dst,
            t.transferAmount = _bound(_random(), 1, t.mintAmount)
        );

        t.spendConfigs = new CircuitAccount.SpendConfig[](1);
        t.spendConfigs[0] = spendConfig;
        vm.prank(d.eoa);
        d.d.setActiveSpendLimits(t.spendConfigs);

        if (t.transferAmount > spendConfig.limit) {
            vm.startPrank(d.bot);
            vm.expectRevert(
                abi.encodeWithSignature("ExceededSpendLimit(address)", address(t.erc20))
            );
            d.d.execute(_ERC7821_BATCH_EXECUTION_MODE, abi.encode(t.calls));
            vm.stopPrank();
            return;
        }

        vm.startPrank(d.bot);
        d.d.execute(_ERC7821_BATCH_EXECUTION_MODE, abi.encode(t.calls));
        vm.stopPrank();

        t.spendInfos = d.d.spendInfos();
        assertEq(t.spendInfos.length, 1);
        assertEq(t.spendInfos[0].lastUpdated, t.executeTimestamp / 86400 * 86400);
        assertEq(t.spendInfos[0].spent, t.transferAmount);
        assertEq(t.spendInfos[0].current, vm.getBlockTimestamp() / 86400 * 86400);
        assertEq(t.spendInfos[0].currentSpent, t.transferAmount);

        vm.warp(t.executeTimestamp + 86400 * _bound(_randomUniform(), 1, 3));

        t.spendInfos = d.d.spendInfos();
        assertEq(t.spendInfos.length, 1);
        assertEq(t.spendInfos[0].lastUpdated, t.executeTimestamp / 86400 * 86400);
        assertEq(t.spendInfos[0].spent, t.transferAmount);
        assertEq(t.spendInfos[0].current, vm.getBlockTimestamp() / 86400 * 86400);
        assertEq(t.spendInfos[0].currentSpent, 0);
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
