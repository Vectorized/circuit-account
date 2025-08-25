// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../../../src/CircuitAccount.sol";
import "../Brutalizer.sol";
import "../../../src/IDelegateRegistry.sol";

contract MockCircuitAccountWithDelegateRegistry is CircuitAccount, Brutalizer {
    using DynamicBufferLib for *;
    using DynamicArrayLib for *;
    using LibBytes for LibBytes.BytesStorage;
    using LibZip for *;

    address internal constant _DELEGATE_REGISTRY_V2 = 0x00000000000000447e69651d841bD8D104Bed493;

    function hash(address spender, address token, SpendPeriod period)
        public
        view
        returns (bytes32)
    {
        _brutalizeScratchSpace();
        return _hash(_brutalized(spender), _brutalized(token), period);
    }

    /// @dev Load the spends from the storage and the delegate registry.
    function _loadSpends() internal view virtual override returns (SpendState[] memory result) {
        AccountStorage storage $ = _getAccountStorage();
        address spender = $.bot;
        if (spender == address(0)) return result;
        address store = $.activeSpendLimitsStore[spender];
        if (store == address(0)) return result;
        bytes memory buffer = SSTORE2.read(store);
        result = new SpendState[](buffer.length / 21); // Token: 20 bytes. SpendPeriod: 1 byte.
        unchecked {
            for (uint256 i; i != result.length; ++i) {
                uint256 packed = uint168(bytes21(LibBytes.load(buffer, i * 21)));
                SpendState memory s = result[i];
                s.token = address(uint160(packed >> 8));
                s.period = SpendPeriod(uint8(packed));
                bytes memory c = $.spends[_hash(spender, s.token, s.period)].get().cdDecompress();
                if (c.length == 0x40) {
                    s.spent = uint256(LibBytes.load(c, 0x00));
                    s.lastUpdated = uint256(LibBytes.load(c, 0x20));
                }
                s.limit = IDelegateRegistry(_DELEGATE_REGISTRY_V2).checkDelegateForERC20(
                    spender, address(this), s.token, _getDelegateRegistryRights(s.period)
                );
            }
        }
    }

    /// @dev Sets the active spend limits for the current bot.
    /// Due to performance limitations, removing and adding back a spend limit
    /// will not reset the existing spend.
    function setActiveSpendLimits(SpendConfig[] calldata configs)
        public
        virtual
        override
        onlyThisOrMaster
    {
        AccountStorage storage $ = _getAccountStorage();
        address spender = $.bot;
        if (spender == address(0)) revert BotIsZeroAddress();

        DynamicBufferLib.DynamicBuffer memory b;

        uint256[] memory packedConfigs = DynamicArrayLib.malloc(configs.length);
        for (uint256 i; i < configs.length; ++i) {
            SpendConfig calldata c = configs[i];
            address token = c.token;
            SpendPeriod period = c.period;
            IDelegateRegistry(_DELEGATE_REGISTRY_V2).delegateERC20(
                spender, token, _getDelegateRegistryRights(period), c.limit
            );
            uint256 packed = (uint256(uint160(token)) << 8) | uint8(period);
            b.pUint168(uint168(packed));
            packedConfigs.set(i, packed);
            if (c.resetExisting) $.spends[_hash(spender, token, period)].clear();
        }
        if (LibSort.hasDuplicate(packedConfigs)) revert DuplicatedSpendConfig();

        $.activeSpendLimitsStore[spender] = SSTORE2.write(b.data);
    }

    /// @dev Returns the `rights` for the delegate registry.
    function _getDelegateRegistryRights(SpendPeriod period)
        internal
        pure
        virtual
        returns (bytes32)
    {
        // Instead of keccak256 hashes, we chose to use readable bytes32 short strings.
        if (period == SpendPeriod.Minute) return "CIRCUIT_SPEND_PERIOD_MINUTE";
        if (period == SpendPeriod.Hour) return "CIRCUIT_SPEND_PERIOD_HOUR";
        if (period == SpendPeriod.Day) return "CIRCUIT_SPEND_PERIOD_DAY";
        if (period == SpendPeriod.Week) return "CIRCUIT_SPEND_PERIOD_WEEK";
        if (period == SpendPeriod.Month) return "CIRCUIT_SPEND_PERIOD_MONTH";
        if (period == SpendPeriod.Year) return "CIRCUIT_SPEND_PERIOD_YEAR";
        if (period == SpendPeriod.Forever) return "CIRCUIT_SPEND_PERIOD_FOREVER";
        revert();
    }
}
