// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IStakedYuzuUSD} from "./interfaces/IStakedYuzuUSD.sol";
import {IStakedYuzuUSDDefinitions, Order, OrderStatus} from "./interfaces/IStakedYuzuUSDDefinitions.sol";

/**
 * @title StakedYuzuUSD
 * @notice ERC-4626 tokenized vault for staking yzUsd with 2-step delayed redemptions.
 */
contract StakedYuzuUSD is ERC4626Upgradeable, Ownable2StepUpgradeable, IStakedYuzuUSDDefinitions {
    mapping(uint256 => uint256) public depositedPerBlock;
    mapping(uint256 => uint256) public withdrawnPerBlock;
    uint256 public maxDepositPerBlock;
    uint256 public maxWithdrawPerBlock;

    uint256 public redeemDelay;
    uint256 public redeemFeePpm;

    uint256 public currentPendingOrderValue;

    mapping(uint256 => Order) internal orders;
    uint256 public orderCount;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the StakedYuzuUSD contract with the specified parameters.
     * @param _yzUsd The underlying ERC-20 token (yzUsd) for the vault
     * @param name_ The name of the staked token, e.g. "Staked YuzuUSD"
     * @param symbol_ The symbol of the staked token, e.g. "st-yzUsd"
     * @param _owner The owner of the contract
     * @param _maxDepositPerBlock Maximum assets that can be deposited per block
     * @param _maxWithdrawPerBlock Maximum assets that can be withdrawn per block
     * @param _redeemDelay The delay in seconds before a redeem order can be finalized
     *
     * Redemption delay is set to 1 day by default.
     */
    function initialize(
        IERC20 _yzUsd,
        string memory name_,
        string memory symbol_,
        address _owner,
        uint256 _maxDepositPerBlock,
        uint256 _maxWithdrawPerBlock,
        uint256 _redeemDelay
    ) external initializer {
        if (address(_yzUsd) == address(0)) revert InvalidZeroAddress();
        if (_owner == address(0)) revert InvalidZeroAddress();

        __ERC4626_init(_yzUsd);
        __ERC20_init(name_, symbol_);
        __Ownable_init(_owner);
        __Ownable2Step_init();

        maxDepositPerBlock = _maxDepositPerBlock;
        maxWithdrawPerBlock = _maxWithdrawPerBlock;
        redeemDelay = _redeemDelay;
    }

    /**
     * @notice Returns the total amount of underlying asset deposits in the vault.
     *
     * Assets in pending redemptions are not included in total assets.
     */
    function totalAssets() public view override returns (uint256) {
        return super.totalAssets() - currentPendingOrderValue;
    }

    /// @dev Preview adding an exit fee on withdraw. See {IERC4626-previewWithdraw}.
    function previewWithdraw(uint256 assets) public view virtual override returns (uint256) {
        uint256 fee = _feeOnRaw(assets, redeemFeePpm);
        return super.previewWithdraw(assets + fee);
    }

    /// @dev Preview taking an exit fee on redeem. See {IERC4626-previewRedeem}.
    function previewRedeem(uint256 shares) public view virtual override returns (uint256) {
        uint256 assets = super.previewRedeem(shares);
        return assets - _feeOnTotal(assets, redeemFeePpm);
    }

    /**
     * @notice Returns the maximum deposit.
     *
     * Takes an address as input for ERC-4626 compatibility.
     * Deposit size is only limited by the maximum deposit per block.
     */
    function maxDeposit(address) public view override returns (uint256) {
        uint256 deposited = depositedPerBlock[block.number];
        if (deposited >= maxDepositPerBlock) return 0;
        return maxDepositPerBlock - deposited;
    }

    /**
     * @notice Returns the maximum mint.
     *
     * Takes an address as input for ERC-4626 compatibility.
     * Mint size is only limited by the maximum deposit per block.
     */
    function maxMint(address receiver) public view override returns (uint256) {
        uint256 _maxDeposit = maxDeposit(receiver);
        if (_maxDeposit == type(uint256).max) {
            return type(uint256).max;
        }
        return convertToShares(_maxDeposit);
    }

    /**
     * @notice Returns the maximum withdrawal by {owner}.
     *
     * Maximum withdrawal is limited by the maximum withdrawal per block and {owner}'s shares.
     */
    function maxWithdraw(address owner) public view override returns (uint256) {
        uint256 withdrawn = withdrawnPerBlock[block.number];
        if (withdrawn >= maxWithdrawPerBlock) return 0;
        return Math.min(super.maxWithdraw(owner), maxWithdrawPerBlock - withdrawn);
    }

    /**
     * @notice Returns the maximum redemption by {owner}.
     *
     * Maximum redemption is limited by the maximum withdrawal per block and {owner}'s shares.
     */
    function maxRedeem(address owner) public view override returns (uint256) {
        uint256 withdrawn = withdrawnPerBlock[block.number];
        if (withdrawn >= maxWithdrawPerBlock) return 0;
        return Math.min(super.maxRedeem(owner), previewDeposit(maxWithdrawPerBlock - withdrawn));
    }

    /**
     * @notice Withdraw function is disabled. Instant withdrawals are not supported.
     * @dev Use initiateRedeem() and finalizeRedeem() for delayed redemptions instead.
     */
    function withdraw(uint256 assets, address receiver, address owner) public override returns (uint256) {
        revert WithdrawNotSupported();
    }

    /**
     * @notice Redeem function is disabled. Instant redemptions are not supported.
     * @dev Use initiateRedeem() and finalizeRedeem() for delayed redemptions instead.
     */
    function redeem(uint256 shares, address receiver, address owner) public override returns (uint256) {
        revert RedeemNotSupported();
    }

    /**
     * @notice Initiates a 2-step redemption of {shares}.
     *
     * Shares are burned now, assets are redeemable after the redemption delay elapses.
     * Returns the order ID and the amount of assets to be redeemed.
     * Emits a `RedeemInitiated` event with the order ID, order owner, assets, and shares.
     * Reverts if {shares} is zero or exceeds the maximum redemption allowed.
     */
    function initiateRedeem(uint256 shares, address receiver, address owner) external returns (uint256, uint256) {
        uint256 maxShares = maxRedeem(owner);
        if (shares > maxShares) {
            revert ERC4626ExceededMaxRedeem(owner, shares, maxShares);
        }

        uint256 assets = previewRedeem(shares);
        address caller = _msgSender();
        uint256 orderId = _initiateRedeem(caller, receiver, owner, assets, shares);

        emit InitiatedRedeem(caller, receiver, owner, orderId, assets, shares);

        return (orderId, assets);
    }

    /**
     * @notice Finalizes a 2-step redemption order by {orderId}.
     *
     * Can be called by anyone, not just the order owner.
     * Emits a `RedeemFinalized` event with caller, the order ID, order owner, assets, and shares.
     * Emits a `Withdraw` event with the caller, receiver, order owner, assets, and shares for ERC-4626 compatibility.
     * Reverts if the order does not exist.
     * Reverts if the order is already executed.
     * Reverts if the order is not due yet.
     */
    function finalizeRedeem(uint256 orderId) external {
        Order storage order = orders[orderId];
        if (order.status != OrderStatus.Pending) {
            revert OrderNotPending(orderId);
        }
        if (block.timestamp < order.dueTime) {
            revert OrderNotDue(orderId);
        }

        address caller = _msgSender();
        _finalizeRedeem(caller, order);

        emit FinalizedRedeem(caller, order.receiver, order.owner, orderId, order.assets, order.shares);
        emit Withdraw(caller, order.owner, order.owner, order.assets, order.shares);
    }

    /**
     * @notice Transfers {amount} of {token} held by the vault to {receiver}.
     *
     * Reverts if called by anyone but the contract owner.
     * Reverts if {token} is the underlying asset of the vault.
     */
    function rescueTokens(address token, address receiver, uint256 amount) external onlyOwner {
        if (token == asset()) revert InvalidToken(token);
        SafeERC20.safeTransfer(IERC20(token), receiver, amount);
    }

    /**
     * @notice Returns a redeem order by {orderId}.
     */
    function getRedeemOrder(uint256 orderId) external view returns (Order memory) {
        return orders[orderId];
    }

    /**
     * @notice Sets the maximum deposit per block to {newMaxDepositPerBlock}.
     *
     * Emits a `UpdatedMaxDepositPerBlock` event with the old and new limits.
     * Reverts if called by anyone but the contract owner.
     */
    function setMaxDepositPerBlock(uint256 newMaxDepositPerBlock) external onlyOwner {
        uint256 oldMaxDepositPerBlock = maxDepositPerBlock;
        maxDepositPerBlock = newMaxDepositPerBlock;
        emit UpdatedMaxDepositPerBlock(oldMaxDepositPerBlock, newMaxDepositPerBlock);
    }

    /**
     * @notice Sets the maximum withdrawal per block to {newMaxWithdrawPerBlock}.
     *
     * Emits a `UpdatedMaxWithdrawPerBlock` event with the old and new limits.
     * Reverts if called by anyone but the contract owner.
     */
    function setMaxWithdrawPerBlock(uint256 newMaxWithdrawPerBlock) external onlyOwner {
        uint256 oldMaxWithdrawPerBlock = maxWithdrawPerBlock;
        maxWithdrawPerBlock = newMaxWithdrawPerBlock;
        emit UpdatedMaxWithdrawPerBlock(oldMaxWithdrawPerBlock, newMaxWithdrawPerBlock);
    }

    /**
     * @notice Sets the redemption delay to {newRedeemDelay}.
     *
     * Emits a `UpdatedRedeemDelay` event with the old and new delay durations.
     * Reverts if called by anyone but the contract owner.
     */
    function setRedeemDelay(uint256 newRedeemDelay) external onlyOwner {
        uint256 oldRedeemDelay = redeemDelay;
        redeemDelay = newRedeemDelay;
        emit UpdatedRedeemDelay(oldRedeemDelay, newRedeemDelay);
    }

    function setRedeemFee(uint256 newRedeemFeePpm) external onlyOwner {
        uint256 oldRedeemFeePpm = redeemFeePpm;
        redeemFeePpm = newRedeemFeePpm;
        emit UpdatedRedeemFee(oldRedeemFeePpm, newRedeemFeePpm);
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        depositedPerBlock[block.number] += assets;
        super._deposit(caller, receiver, assets, shares);
    }

    /**
     * @dev Internal function to initiate a redeem order.
     *
     * Burns the shares and creates a redeem order for {assets} and {shares}.
     * Returns the order ID.
     */
    function _initiateRedeem(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        returns (uint256)
    {
        withdrawnPerBlock[block.number] += assets;
        currentPendingOrderValue += assets;

        uint256 orderId = orderCount;
        orders[orderId] = Order({
            assets: assets,
            shares: shares,
            owner: owner,
            receiver: receiver,
            dueTime: uint40(block.timestamp + redeemDelay),
            status: OrderStatus.Pending
        });
        orderCount++;

        if (caller != owner) {
            _spendAllowance(owner, caller, shares);
        }
        _burn(owner, shares);

        return orderId;
    }

    /**
     * @dev Internal function to finalize a redeem order.
     *
     * Marks the order as executed, updates the current redeem asset commitment,
     * and transfers the assets to the order owner.
     */
    function _finalizeRedeem(address caller, Order storage order) internal {
        order.status = OrderStatus.Executed;
        currentPendingOrderValue -= order.assets;
        SafeERC20.safeTransfer(IERC20(asset()), order.owner, order.assets);
    }

    /// @dev Calculates the fees that should be added to an amount `assets` that does not already include fees.
    function _feeOnRaw(uint256 assets, uint256 feePpm) internal pure returns (uint256) {
        return Math.mulDiv(assets, feePpm, 1e6, Math.Rounding.Ceil);
    }

    /// @dev Calculates the fee part of an amount `assets` that already includes fees.
    function _feeOnTotal(uint256 assets, uint256 feePpm) internal pure returns (uint256) {
        return Math.mulDiv(assets, feePpm, feePpm + 1e6, Math.Rounding.Ceil);
    }

    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     */
    uint256[50] private __gap;
}
