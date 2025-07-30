// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlDefaultAdminRulesUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/interfaces/IERC4626.sol";

import "./interfaces/IYuzuILP.sol";
import "./interfaces/IYuzuILPDefinitions.sol";

/**
 * @title YuzuILP
 * @dev ERC4626 tokenized vault for the Yuzu Insurance Liquidity Pool.
 * Deposited assets are sent to an external treasury.
 * The size of the pool is tracked and periodically updated by an external pool manager.
 * A non-compounding yield is applied to the pool size to determine the value of the shares.
 * Withdrawals are executed by an external order filler.
 */
contract YuzuILP is
    Initializable,
    AccessControlDefaultAdminRulesUpgradeable,
    ReentrancyGuardUpgradeable,
    ERC20Upgradeable,
    IERC4626,
    IYuzuILPDefinitions
{
    bytes32 private constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 private constant LIMIT_MANAGER_ROLE = keccak256("LIMIT_MANAGER_ROLE");
    bytes32 private constant ORDER_FILLER_ROLE = keccak256("ORDER_FILLER_ROLE");
    bytes32 private constant POOL_MANAGER_ROLE = keccak256("POOL_MANAGER_ROLE");

    IERC20 private _asset;

    mapping(uint256 => uint256) public depositedPerBlock;
    uint256 public maxDepositPerBlock;

    mapping(uint256 => Order) internal redeemOrders;
    uint256 public redeemOrderCount;

    address public treasury;
    uint256 public poolSize;
    uint256 public withdrawAllowance;
    uint256 public dailyLinearYieldRatePpm;
    uint256 public lastPoolUpdateTimestamp;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the YuzuILP contract with the specified parameters.
     * @param asset_ The address of the underlying asset token.
     * @param name_ The name of the vault token, e.g. "Yuzu ILP".
     * @param symbol_ The symbol of the vault token, e.g. "yzILP".
     * @param _admin The admin of the contract.
     * @param _treasury The address of the treasury where assets are sent.
     * @param _maxDepositPerBlock Maximum assets that can be deposited per block.
     *
     * Pool size, withdrawal allowance, and yield rate are set to 0 by default.
     * Reverts if {_admin} or {_treasury} is the zero address.
     */
    function initialize(
        IERC20 asset_,
        string memory name_,
        string memory symbol_,
        address _admin,
        address _treasury,
        uint256 _maxDepositPerBlock
    ) external initializer {
        if (address(asset_) == address(0)) revert InvalidZeroAddress();
        if (_admin == address(0)) revert InvalidZeroAddress();
        if (_treasury == address(0)) revert InvalidZeroAddress();

        __AccessControlDefaultAdminRules_init(0, _admin);
        __ReentrancyGuard_init();
        __ERC20_init(name_, symbol_);

        _asset = asset_;
        treasury = _treasury;
        maxDepositPerBlock = _maxDepositPerBlock;
        redeemOrderCount = 0;
        poolSize = 0;
        withdrawAllowance = 0;
        dailyLinearYieldRatePpm = 0;
        lastPoolUpdateTimestamp = block.timestamp;

        _grantRole(ADMIN_ROLE, _admin);
        _setRoleAdmin(LIMIT_MANAGER_ROLE, ADMIN_ROLE);
        _setRoleAdmin(POOL_MANAGER_ROLE, ADMIN_ROLE);
        _setRoleAdmin(ORDER_FILLER_ROLE, ADMIN_ROLE);
    }

    /**
     * @notice Sets the maximum deposit per block to {newMaxDepositPerBlock}.
     *
     * Emits a `MaxDepositPerBlockUpdated` event with the old and new limits.
     * Reverts if called by anyone but a limit manager.
     */
    function setMaxDepositPerBlock(uint256 newMaxDepositPerBlock) external onlyRole(LIMIT_MANAGER_ROLE) {
        uint256 oldMaxDepositPerBlock = maxDepositPerBlock;
        maxDepositPerBlock = newMaxDepositPerBlock;
        emit MaxDepositPerBlockUpdated(oldMaxDepositPerBlock, newMaxDepositPerBlock);
    }

    /**
     * @notice Sets the treasury address to {newTreasury}.
     *
     * Emits a `TreasuryUpdated` event with the old and new treasury addresses.
     * Reverts if called by anyone but an admin.
     * Reverts if {newTreasury} is the zero address.
     */
    function setTreasury(address newTreasury) external onlyRole(ADMIN_ROLE) {
        if (newTreasury == address(0)) revert InvalidZeroAddress();
        address oldTreasury = treasury;
        treasury = newTreasury;
        emit TreasuryUpdated(oldTreasury, newTreasury);
    }

    /**
     * @notice Updates the pool parameters including size, withdrawal allowance, and yield rate.
     *
     * Sets poolSize to newPoolSize, withdrawAllowance to {newWithdrawalAllowance},
     * and {dailyLinearYieldRatePpm} to {newDailyLinearYieldRatePpm}.
     * Emits a `PoolUpdated` event with the new pool parameters.
     * Reverts if called by anyone but a pool manager.
     * Reverts if {newWithdrawalAllowance} exceeds {newPoolSize}.
     * Reverts if {newDailyLinearYieldRatePpm} exceeds 1e6 (100% daily yield).
     */
    function updatePool(uint256 newPoolSize, uint256 newWithdrawalAllowance, uint256 newDailyLinearYieldRatePpm)
        external
        onlyRole(POOL_MANAGER_ROLE)
    {
        if (newWithdrawalAllowance > newPoolSize) revert WithdrawalAllowanceExceedsPoolSize(newWithdrawalAllowance);
        if (newDailyLinearYieldRatePpm > 1e6) revert InvalidYield(newDailyLinearYieldRatePpm); // Max 1e6 ppm = 100% yield per day

        poolSize = newPoolSize;
        withdrawAllowance = newWithdrawalAllowance;
        dailyLinearYieldRatePpm = newDailyLinearYieldRatePpm;
        lastPoolUpdateTimestamp = block.timestamp;

        emit PoolUpdated(newPoolSize, newWithdrawalAllowance, newDailyLinearYieldRatePpm);
    }

    /**
     * @notice Returns the address of the underlying asset of the vault.
     */
    function asset() public view returns (address) {
        return address(_asset);
    }

    /**
     * @notice Returns the total assets managed by the vault.
     *
     * Includes the pool size and the yield accrued since the last update.
     */
    function totalAssets() public view returns (uint256) {
        uint256 yieldSinceUpdate = _yieldSinceUpdate(Math.Rounding.Floor);
        return poolSize + yieldSinceUpdate;
    }

    /**
     * @notice Returns the amount of assets equivalent to {shares}.
     *
     * Returns the amount of assets required to mint the given number of shares.
     */
    function convertToAssets(uint256 shares) public view returns (uint256) {
        return previewMint(shares);
    }

    /**
     * @notice Returns the number of shares equivalent to {assets}.
     *
     * Returns the number of shares minted for the given amount of assets.
     */
    function convertToShares(uint256 assets) public view returns (uint256) {
        return previewDeposit(assets);
    }

    /**
     * @notice Returns the maximum deposit.
     *
     * Deposit size is only limited by the maximum deposit per block.
     */
    function maxDeposit(address receiver) public view returns (uint256) {
        uint256 deposited = depositedPerBlock[block.number];
        if (deposited >= maxDepositPerBlock) return 0;
        return maxDepositPerBlock - deposited;
    }

    /**
     * @notice Returns the maximum mint.
     *
     * Mint size is only limited by the maximum deposit per block.
     */
    function maxMint(address receiver) public view returns (uint256) {
        return previewMint(maxDeposit(receiver));
    }

    /**
     * @notice Returns the maximum withdrawal by {owner}.
     *
     * Maximum withdrawal is limited by the maximum withdrawal per block and {owner}'s shares.
     */
    function maxWithdraw(address owner) public view returns (uint256) {
        return Math.min(previewRedeem(balanceOf(owner)), withdrawAllowance);
    }

    /**
     * @notice Returns the maximum redemption by {owner}.
     *
     * Maximum redemption is limited by the withdrawal allowance and {owner}'s shares.
     */
    function maxRedeem(address owner) public view returns (uint256) {
        return Math.min(balanceOf(owner), previewWithdraw(withdrawAllowance));
    }

    /**
     * @notice Returns the number of shares minted for {assets}.
     */
    function previewDeposit(uint256 assets) public view returns (uint256) {
        return _convertToSharesMinted(assets);
    }

    /**
     * @notice Returns the amount of assets required to mint {shares}.
     */
    function previewMint(uint256 shares) public view returns (uint256) {
        return _convertToAssetsDeposited(shares);
    }

    /**
     * @notice Returns the number of shares redeemed for {assets}.
     */
    function previewWithdraw(uint256 assets) public view returns (uint256) {
        return _convertToSharesRedeemed(assets);
    }

    /**
     * @notice Returns the amount of assets withdrawn for {shares}.
     */
    function previewRedeem(uint256 shares) public view returns (uint256) {
        return _convertToAssetsWithdrawn(shares);
    }

    /**
     * @notice Deposits {assets} into the vault and mints shares to {receiver}.
     *
     * Returns the number of shares minted.
     * Emits a `Deposit` event with the caller, receiver, assets, and shares.
     * Reverts if the deposit exceeds the maximum allowed per block.
     */
    function deposit(uint256 assets, address receiver) public nonReentrant returns (uint256) {
        uint256 maxAssets = maxDeposit(receiver);
        if (assets > maxAssets) {
            revert MaxDepositExceeded(assets, maxAssets);
        }

        uint256 shares = previewDeposit(assets);
        _deposit(_msgSender(), receiver, assets, shares);

        return shares;
    }

    /**
     * @notice Mints {shares} to {receiver} by depositing assets.
     *
     * Returns the amount of assets deposited.
     * Emits a `Deposit` event with the caller, receiver, assets, and shares.
     * Reverts if the shares amount exceeds the maximum allowed per block.
     */
    function mint(uint256 shares, address receiver) public nonReentrant returns (uint256) {
        uint256 maxShares = maxMint(receiver);
        if (shares > maxShares) {
            revert MaxMintExceeded(shares, maxShares);
        }

        uint256 assets = previewMint(shares);
        _deposit(_msgSender(), receiver, assets, shares);

        return assets;
    }

    /**
     * @notice Withdraw function is disabled. Instant withdrawals are not supported.
     * @dev Use createRedeemOrder() and fillRedeemOrder() for delayed redemptions instead.
     */
    function withdraw(uint256 assets, address receiver, address owner) public pure returns (uint256) {
        revert WithdrawNotSupported();
    }

    /**
     * @notice Redeem function is disabled. Instant redemptions are not supported.
     * @dev Use createRedeemOrder() and fillRedeemOrder() for delayed redemptions instead.
     */
    function redeem(uint256 shares, address receiver, address owner) public pure returns (uint256) {
        revert RedeemNotSupported();
    }

    /**
     * @notice Creates a redeem order for {shares}.
     *
     * Returns the order ID and the amount of assets to be redeemed.
     * Emits a `RedeemOrderCreated` event with order details.
     * Reverts if shares is zero.
     * Reverts if shares exceeds the maximum redeemable amount.
     */
    function createRedeemOrder(uint256 shares) external nonReentrant returns (uint256, uint256) {
        if (shares == 0) revert InvalidZeroShares();
        uint256 maxShares = maxRedeem(_msgSender());
        if (shares > maxShares) revert MaxRedeemExceeded(shares, maxShares);
        uint256 assets = previewRedeem(shares);
        uint256 orderId = _createRedeemOrder(_msgSender(), assets, shares);
        emit RedeemOrderCreated(orderId, _msgSender(), assets, shares);
        return (orderId, assets);
    }

    /**
     * @notice Fills a redeem order with {orderId} by transferring assets to the order owner.
     *
     * Emits a `RedeemOrderFilled` event with order details.
     * Reverts if called by anyone but an order filler.
     * Reverts if the order does not exist.
     * Reverts if the order is already executed.
     */
    function fillRedeemOrder(uint256 orderId) external nonReentrant onlyRole(ORDER_FILLER_ROLE) {
        Order storage order = redeemOrders[orderId];
        if (order.shares == 0) revert InvalidOrder(orderId);
        if (order.executed) revert OrderAlreadyExecuted();
        _fillRedeemOrder(order, _msgSender());
        emit RedeemOrderFilled(orderId, order.owner, _msgSender(), order.assets, order.shares);
        emit Withdraw(_msgSender(), order.owner, order.owner, order.assets, order.shares);
    }

    /**
     * @notice Transfers {amount} of {token} held by the vault to {to}.
     *
     * Reverts if called by anyone but an admin.
     * Reverts if {token} is the underlying asset of the vault.
     */
    function rescueTokens(address token, address to, uint256 amount) external onlyRole(ADMIN_ROLE) {
        if (token == asset()) revert InvalidToken(token);
        SafeERC20.safeTransfer(IERC20(token), to, amount);
    }

    /**
     * @notice Returns a redeem order by {orderId}.
     */
    function getRedeemOrder(uint256 orderId) external view returns (Order memory) {
        return redeemOrders[orderId];
    }

    /**
     * @dev Internal function to convert {assets} to shares minted.
     */
    function _convertToSharesMinted(uint256 assets) internal view returns (uint256) {
        if (poolSize == 0) return assets;
        uint256 _totalAssets = poolSize + _yieldSinceUpdate(Math.Rounding.Ceil);
        return Math.mulDiv(totalSupply(), assets, _totalAssets, Math.Rounding.Floor);
    }

    /**
     * @dev Internal function to convert {assets} to shares redeemed.
     */
    function _convertToSharesRedeemed(uint256 assets) internal view returns (uint256) {
        if (poolSize == 0) return assets;
        return Math.mulDiv(assets, totalSupply(), poolSize, Math.Rounding.Ceil);
    }

    /**
     * @dev Internal function to convert {shares} to assets deposited.
     */
    function _convertToAssetsDeposited(uint256 shares) internal view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return shares;
        uint256 _totalAssets = poolSize + _yieldSinceUpdate(Math.Rounding.Ceil);
        return Math.mulDiv(_totalAssets, shares, supply, Math.Rounding.Ceil);
    }

    /**
     * @dev Internal function to convert shares to assets withdrawn.
     */
    function _convertToAssetsWithdrawn(uint256 shares) internal view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return shares;
        return Math.mulDiv(poolSize, shares, supply, Math.Rounding.Floor);
    }

    /**
     * @dev Internal function to handle deposits.
     *
     * Transfers {assets} from {caller} to the treasury, mints {shares} to {receiver},
     * and increments the deposited per block, withdraw allowance, and pool size.
     */
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal {
        SafeERC20.safeTransferFrom(IERC20(asset()), caller, treasury, assets);
        _mint(receiver, shares);
        depositedPerBlock[block.number] += assets;
        withdrawAllowance += assets;
        poolSize += _discountYield(assets, Math.Rounding.Floor);
        emit Deposit(caller, receiver, assets, shares);
    }

    /**
     * @dev Internal function to create a redeem order.
     *
     * Decrements the withdraw allowance and pool size, burns {shares}, and creates a redeem order.
     * Returns the order ID.
     * Redemptions don't include the yield accrued since the last pool update.
     */
    function _createRedeemOrder(address owner, uint256 assets, uint256 shares) internal returns (uint256) {
        withdrawAllowance -= assets;
        poolSize -= assets;
        _burn(owner, shares);
        uint256 orderId = redeemOrderCount;
        redeemOrders[orderId] = Order({assets: assets, shares: shares, owner: owner, executed: false});
        redeemOrderCount++;
        return orderId;
    }

    /**
     * @dev Internal function to fill a redeem order.
     *
     * Transfers assets to the owner and marks the order as executed.
     */
    function _fillRedeemOrder(Order storage order, address filler) internal {
        order.executed = true;
        SafeERC20.safeTransferFrom(IERC20(asset()), filler, order.owner, order.assets);
    }

    /**
     * @dev Returns the number of seconds since the last pool update.
     */
    function _timeSinceUpdate() internal view returns (uint256) {
        return block.timestamp - lastPoolUpdateTimestamp;
    }

    /**
     * @dev Calculates the yield accrued since the last pool update.
     *
     * Uses the daily linear yield rate and the time since the last update.
     * Returns the yield amount, rounded according to the specified rounding mode.
     */
    function _yieldSinceUpdate(Math.Rounding rounding) internal view returns (uint256) {
        uint256 elapsedTime = _timeSinceUpdate();
        if (poolSize == 0 || dailyLinearYieldRatePpm == 0 || elapsedTime == 0) {
            return 0;
        }
        uint256 yieldSinceUpdate = Math.mulDiv(poolSize * dailyLinearYieldRatePpm, elapsedTime, 1e6 days, rounding);
        return yieldSinceUpdate;
    }

    /**
     * @dev Returns the size of a deposit such that, if deposited at the time of the last pool update,
     * would have accrued yield making it worth {assets} now.
     *
     * Uses the daily linear yield rate and the time since the last update.
     * Returns the size of the deposit, rounded according to the specified rounding mode.
     */
    function _discountYield(uint256 assets, Math.Rounding rounding) internal view returns (uint256) {
        uint256 elapsedTime = _timeSinceUpdate();
        if (poolSize == 0 || dailyLinearYieldRatePpm == 0 || elapsedTime == 0) {
            return assets;
        }
        return Math.mulDiv(assets, 1e6 days, 1e6 days + dailyLinearYieldRatePpm * elapsedTime, rounding);
    }

    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     */
    uint256[50] private __gap;
}
