// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {LibBytes} from "solady/utils/LibBytes.sol";
import {EfficientHashLib} from "solady/utils/EfficientHashLib.sol";
import {FixedPointMathLib as Math} from "solady/utils/FixedPointMathLib.sol";
import {DateTimeLib} from "solady/utils/DateTimeLib.sol";
import {LibZip} from "solady/utils/LibZip.sol";
import {LibSort} from "solady/utils/LibSort.sol";
import {SSTORE2} from "solady/utils/SSTORE2.sol";
import {DynamicBufferLib} from "solady/utils/DynamicBufferLib.sol";
import {DynamicArrayLib} from "solady/utils/DynamicArrayLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {ERC7821} from "solady/accounts/ERC7821.sol";
import {TokenTransferLib} from "./TokenTransferLib.sol";
import {IDelegateRegistry} from "./IDelegateRegistry.sol";

/// @title CircuitAccount
/// @notice A simple 7702 delegation for agents.
/// @author Modified from Ithaca Account (https://github.com/ithacaxyz/account)
/// @dev There are two ways to use this account:
/// 1. As a sub account delegated via an ephemeral EOA secp256k1 key.
/// 2. Directly on your main EOA (super degen mode).
/// We shall assume that the bot is willing to foot the gas fees
/// and willing to call this contract directly.
contract CircuitAccount is ERC7821 {
    using DynamicBufferLib for *;
    using DynamicArrayLib for *;
    using LibBytes for LibBytes.BytesStorage;
    using LibZip for *;

    ////////////////////////////////////////////////////////////////////////
    // Enums
    ////////////////////////////////////////////////////////////////////////

    enum SpendPeriod {
        Minute,
        Hour,
        Day,
        Week,
        Month,
        Year,
        Forever
    }

    ////////////////////////////////////////////////////////////////////////
    // Structs
    ////////////////////////////////////////////////////////////////////////

    /// @dev For passing in spend limit configurations.
    struct SpendConfig {
        /// @dev Address of the token. `address(0)` denotes native token.
        address token;
        /// @dev The type of period.
        SpendPeriod period;
        /// @dev The maximum spend limit for the period.
        uint256 limit;
        /// @dev Whether to reset the existing spend limit if one exists.
        bool resetExisting;
    }

    /// @dev For grouping spend variables for temporary internal use (loading, updating, saving).
    struct SpendState {
        /// @dev Address of the token. `address(0)` denotes native token.
        address token;
        /// @dev The type of period.
        SpendPeriod period;
        /// @dev The maximum spend limit for the period.
        uint256 limit;
        /// @dev The amount spent in the last updated period.
        uint256 spent;
        /// @dev The start of the last updated period (unix timestamp).
        uint256 lastUpdated;
    }

    /// @dev Information about a spend.
    /// All timestamp related values are Unix timestamps in seconds.
    struct SpendInfo {
        /// @dev Address of the token. `address(0)` denotes native token.
        address token;
        /// @dev The type of period.
        SpendPeriod period;
        /// @dev The maximum spend limit for the period.
        uint256 limit;
        /// @dev The amount spent in the last updated period.
        uint256 spent;
        /// @dev The start of the last updated period.
        uint256 lastUpdated;
        /// @dev The amount spent in the current period.
        uint256 currentSpent;
        /// @dev The start of the current period.
        uint256 current;
    }

    ////////////////////////////////////////////////////////////////////////
    // Storage
    ////////////////////////////////////////////////////////////////////////

    struct AccountStorage {
        /// @dev The address of the master.
        address master;
        /// @dev Whether the storage has already been initialized.
        bool initialized;
        /// @dev The address of the bot.
        address bot;
        /// @dev Whether the current call is within a bot's execute.
        bool isBotContext;
        /// @dev Mapping of `bot` to the a SSTORE2 contract for the encoded
        /// `<token,period>,<token,period>,...`.
        mapping(address => address) activeSpendLimitsStore;
        /// @dev Mapping of `<bot,token,period>` to the encoded spends.
        mapping(bytes32 => LibBytes.BytesStorage) spends;
    }

    /// @dev Returns the storage pointer.
    function _getAccountStorage() internal pure returns (AccountStorage storage $) {
        // Truncate to 9 bytes to reduce bytecode size.
        uint256 s = uint72(bytes9(keccak256("CIRCUIT_ACCOUNT_STORAGE")));
        assembly ("memory-safe") {
            $.slot := s
        }
    }

    ////////////////////////////////////////////////////////////////////////
    // Errors
    ////////////////////////////////////////////////////////////////////////

    /// @dev Not authorized to perform the action.
    error Unauthorized();

    /// @dev The bot cannot be the master.
    error BotCannotBeMaster();

    /// @dev The bot cannot be this EOA.
    error BotCannotBeThis();

    /// @dev Cannot perform the action if the bot is set to `address(0)`.
    error BotIsZeroAddress();

    /// @dev Cannot double initialize.
    error AlreadyInitialized();

    /// @dev The spend configs cannot have a duplicated `<token,period>` pair.
    error DuplicatedSpendConfig();

    /// @dev Exceeded the spend limit of `token`.
    error ExceededSpendLimit(address token);

    ////////////////////////////////////////////////////////////////////////
    // Constants
    ////////////////////////////////////////////////////////////////////////

    /// @dev Address of the delegate registry.
    address internal constant _DELEGATE_REGISTRY_V2 = 0x00000000000000447e69651d841bD8D104Bed493;

    /// @dev The canonical Permit2 address.
    address internal constant _PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    ////////////////////////////////////////////////////////////////////////
    // Initializer
    ////////////////////////////////////////////////////////////////////////

    /// @dev Initializes the master and the bot. This can only be used once per account.
    /// You can use an ephemeral secp256k1 EOA for this.
    /// If this account is on a
    function initialize(address initialMaster, address initialBot) public virtual {
        if (msg.sender != address(this)) revert Unauthorized();
        AccountStorage storage $ = _getAccountStorage();
        if ($.initialized) revert AlreadyInitialized();
        $.initialized = true;
        if (initialBot != address(0)) {
            if (initialBot == initialMaster) revert BotCannotBeMaster();
            if (initialBot == address(this)) revert BotCannotBeThis();
        }
        $.bot = initialBot;
        $.master = initialMaster;
    }

    ////////////////////////////////////////////////////////////////////////
    // View functions
    ////////////////////////////////////////////////////////////////////////

    /// @dev Returns the bot account.
    function bot() public view virtual returns (address) {
        return _getAccountStorage().bot;
    }

    /// @dev Returns the master account.
    function master() public view virtual returns (address) {
        return _getAccountStorage().master;
    }

    /// @dev Returns an array containing information on all the spends.
    function spendInfos() public view virtual returns (SpendInfo[] memory results) {
        SpendState[] memory spendStates = _loadSpends();
        results = new SpendInfo[](spendStates.length);
        for (uint256 i; i < results.length; ++i) {
            SpendState memory s = spendStates[i];
            SpendInfo memory info = results[i];
            info.token = s.token;
            info.period = s.period;
            info.limit = s.limit;
            info.spent = s.spent;
            info.lastUpdated = s.lastUpdated;
            info.current = startOfSpendPeriod(block.timestamp, s.period);
            info.currentSpent = Math.ternary(info.lastUpdated < info.current, 0, info.spent);
        }
    }

    ////////////////////////////////////////////////////////////////////////
    // Admin functions
    ////////////////////////////////////////////////////////////////////////

    /// @dev Updates the bot.
    function setBot(address newBot) public virtual onlyThisOrMaster {
        AccountStorage storage $ = _getAccountStorage();
        if (newBot != address(0)) {
            if (newBot == address(this)) revert BotCannotBeThis();
            if (newBot == $.master) revert BotCannotBeMaster();
        }
        $.bot = newBot;
    }

    /// @dev Updates the master.
    function setMaster(address newMaster) public virtual onlyThisOrMaster {
        AccountStorage storage $ = _getAccountStorage();
        if (newMaster != address(0)) {
            if (newMaster == $.bot) revert BotCannotBeMaster();
        }
        $.master = newMaster;
    }

    /// @dev Sets the active spend limits for the current bot.
    /// Due to performance limitations, removing and adding back a spend limit
    /// will not reset the existing spend.
    function setActiveSpendLimits(SpendConfig[] calldata configs) public virtual onlyThisOrMaster {
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

    /// @dev Rounds the unix timestamp down to the period.
    function startOfSpendPeriod(uint256 unixTimestamp, SpendPeriod period)
        public
        pure
        virtual
        returns (uint256)
    {
        if (period == SpendPeriod.Minute) return Math.rawMul(Math.rawDiv(unixTimestamp, 60), 60);
        if (period == SpendPeriod.Hour) return Math.rawMul(Math.rawDiv(unixTimestamp, 3600), 3600);
        if (period == SpendPeriod.Day) return Math.rawMul(Math.rawDiv(unixTimestamp, 86400), 86400);
        if (period == SpendPeriod.Week) return DateTimeLib.mondayTimestamp(unixTimestamp);
        (uint256 year, uint256 month,) = DateTimeLib.timestampToDate(unixTimestamp);
        // Note: DateTimeLib's months and month-days start from 1.
        if (period == SpendPeriod.Month) return DateTimeLib.dateToTimestamp(year, month, 1);
        if (period == SpendPeriod.Year) return DateTimeLib.dateToTimestamp(year, 1, 1);
        if (period == SpendPeriod.Forever) return 1; // Non-zero to differentiate from not set.
        revert(); // We shouldn't hit here.
    }

    ////////////////////////////////////////////////////////////////////////
    // ERC7821
    ////////////////////////////////////////////////////////////////////////

    /// @dev To avoid stack-too-deep.
    struct _ExecuteTemps {
        DynamicArrayLib.DynamicArray approvedERC20s;
        DynamicArrayLib.DynamicArray approvalSpenders;
        DynamicArrayLib.DynamicArray erc20s;
        DynamicArrayLib.DynamicArray transferAmounts;
        DynamicArrayLib.DynamicArray permit2ERC20s;
        DynamicArrayLib.DynamicArray permit2Spenders;
    }

    /// @dev For ERC7821.
    function _execute(Call[] calldata calls, bytes32) internal virtual override {
        AccountStorage storage $ = _getAccountStorage();

        if (msg.sender == address(this) || msg.sender == $.master) {
            if ($.isBotContext) revert Unauthorized();
            ERC7821._execute(calls, bytes32(0));
        } else if (msg.sender == $.bot) {
            _botExecute(calls);
        } else {
            revert Unauthorized();
        }
    }

    /// @dev Special execute workflow for bots.
    function _botExecute(Call[] calldata calls) internal virtual {
        AccountStorage storage $ = _getAccountStorage();

        if ($.isBotContext) revert Unauthorized();
        $.isBotContext = true;

        SpendState[] memory spendStates = _loadSpends();

        _ExecuteTemps memory t;

        // Collect all ERC20 tokens that need to be guarded,
        // and initialize their transfer amounts as zero.
        // Used for the check on their before and after balances, in case the batch calls
        // some contract that is authorized to transfer out tokens on behalf of the eoa.
        for (uint256 i; i < spendStates.length; ++i) {
            address token = spendStates[i].token;
            if (token != address(0)) {
                t.erc20s.p(token);
                t.transferAmounts.p(uint256(0));
            }
        }

        // We will only filter based on functions that are known to use `msg.sender`.
        // For signature-based approvals (e.g. permit), we can't do anything
        // to guard, as anyone else can directly submit the calldata and the signature.
        uint256 totalNativeSpend;
        for (uint256 i; i < calls.length; ++i) {
            (address target, uint256 value, bytes calldata data) = _get(calls, i);
            if (value != 0) totalNativeSpend += value;
            if (data.length < 4) continue;
            uint32 fnSel = uint32(bytes4(LibBytes.loadCalldata(data, 0x00)));
            // `transfer(address,uint256)`.
            if (fnSel == 0xa9059cbb) {
                t.erc20s.p(target);
                t.transferAmounts.p(LibBytes.loadCalldata(data, 0x24)); // `amount`.
            }
            // `approve(address,uint256)`.
            // We have to revoke any new approvals after the batch, else a bad app can
            // leave an approval to let them drain unlimited tokens after the batch.
            if (fnSel == 0x095ea7b3) {
                if (LibBytes.loadCalldata(data, 0x24) == 0) continue; // `amount == 0`.
                t.approvedERC20s.p(target);
                t.approvalSpenders.p(LibBytes.loadCalldata(data, 0x04)); // `spender`.
            }
            // The only Permit2 method that requires `msg.sender` to approve.
            // `approve(address,address,uint160,uint48)`.
            // For ERC20 tokens giving Permit2 infinite approvals by default,
            // the approve method on Permit2 acts like a approve method on the ERC20.
            if (fnSel == 0x87517c45) {
                if (target != _PERMIT2) continue;
                if (LibBytes.loadCalldata(data, 0x44) == 0) continue; // `amount == 0`.
                t.permit2ERC20s.p(LibBytes.loadCalldata(data, 0x04)); // `token`.
                t.permit2Spenders.p(LibBytes.loadCalldata(data, 0x24)); // `spender`.
            }
        }

        // Sum transfer amounts, grouped by the ERC20s. In-place.
        LibSort.groupSum(t.erc20s.data, t.transferAmounts.data);

        // Collect the ERC20 balances before the batch execution.
        uint256[] memory balancesBefore = DynamicArrayLib.malloc(t.erc20s.length());
        for (uint256 i; i < t.erc20s.length(); ++i) {
            address token = t.erc20s.getAddress(i);
            balancesBefore.set(i, SafeTransferLib.balanceOf(token, address(this)));
        }

        // Perform the batch execution.
        ERC7821._execute(calls, bytes32(0));

        // Increments the spent amounts.
        for (uint256 j; j < spendStates.length; ++j) {
            SpendState memory s = spendStates[j];
            if (s.token == address(0)) {
                _incrementSpent(s, totalNativeSpend);
                continue;
            }
            (bool found, uint256 i) = LibSort.searchSorted(t.erc20s.asAddressArray(), s.token);
            if (!found) continue;
            _incrementSpent(
                s,
                // While we can actually just use the difference before and after,
                // we also want to let the sum of the transfer amounts in the calldata to be capped.
                // This prevents tokens to be used as flash loans, and also handles cases
                // where the actual token transfers might not match the calldata amounts.
                // There is no strict definition on what constitutes spending,
                // and we want to be as conservative as possible.
                Math.max(
                    t.transferAmounts.get(i),
                    Math.saturatingSub(
                        balancesBefore.get(i), SafeTransferLib.balanceOf(s.token, address(this))
                    )
                )
            );
        }
        // Revoke all non-zero approvals that have been made, if there's a spend limit.
        for (uint256 i; i < t.approvedERC20s.length(); ++i) {
            address token = t.approvedERC20s.getAddress(i);
            SafeTransferLib.safeApprove(token, t.approvalSpenders.getAddress(i), 0);
        }
        // Revoke all non-zero Permit2 direct approvals that have been made, if there's a spend limit.
        for (uint256 i; i < t.permit2ERC20s.length(); ++i) {
            address token = t.permit2ERC20s.getAddress(i);
            SafeTransferLib.permit2Lockdown(token, t.permit2Spenders.getAddress(i));
        }

        $.isBotContext = false;
    }

    ////////////////////////////////////////////////////////////////////////
    // Internal helpers
    ////////////////////////////////////////////////////////////////////////

    /// @dev Ensures a function can only be called by the EOA itself, or the master,
    /// and that the current call context is not within a bot's `execute` call.
    modifier onlyThisOrMaster() virtual {
        if (msg.sender != address(this)) {
            if (msg.sender != _getAccountStorage().master) revert Unauthorized();
        }
        if (_getAccountStorage().isBotContext) revert Unauthorized();
        _;
    }

    /// @dev Load the spends from the storage and the delegate registry.
    function _loadSpends() internal view virtual returns (SpendState[] memory result) {
        AccountStorage storage $ = _getAccountStorage();
        address spender = $.bot;
        if (spender == address(0)) return result;
        address store = $.activeSpendLimitsStore[spender];
        if (store == address(0)) return result;
        bytes memory buffer = SSTORE2.read(store);
        result = new SpendState[](buffer.length / 21);
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

    /// @dev Increments the spent amount and update the storage.
    function _incrementSpent(SpendState memory s, uint256 amount) internal virtual {
        AccountStorage storage $ = _getAccountStorage();
        address spender = $.bot;
        uint256 current = startOfSpendPeriod(block.timestamp, s.period);
        if (s.lastUpdated < current) {
            s.lastUpdated = current;
            s.spent = 0;
        }
        if ((s.spent += amount) > s.limit) revert ExceededSpendLimit(s.token);

        bytes memory c = abi.encode(s.spent, s.lastUpdated).cdCompress();
        $.spends[_hash(spender, s.token, s.period)].set(c);
    }

    /// @dev Equivalent to `keccak256(abi.encodePacked(spender,token,period))`.
    function _hash(address spender, address token, SpendPeriod period)
        internal
        pure
        virtual
        returns (bytes32 result)
    {
        assembly ("memory-safe") {
            mstore(0x15, period)
            mstore(0x14, token)
            mstore(0x00, spender)
            result := keccak256(0x0c, 0x29)
        }
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
