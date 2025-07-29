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
 * Withdraws are executed by an external order filler.
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
     * @dev Sets the values for {asset}, {name}, {symbol}, {admin}, {treasury}, and {maxDepositPerBlock}.
     */
    function initialize(
        IERC20 asset_,
        string memory name_,
        string memory symbol_,
        address _admin,
        address _treasury,
        uint256 _maxDepositPerBlock
    ) external initializer {
        __AccessControlDefaultAdminRules_init(0, _admin);
        __ReentrancyGuard_init();
        __ERC20_init(name_, symbol_);

        if (_admin == address(0)) revert InvalidZeroAddress();
        if (_treasury == address(0)) revert InvalidZeroAddress();

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
     * @dev Sets {maxDepositPerBlock}.
     *
     * Only callable by the limit manager.
     */
    function setMaxDepositPerBlock(uint256 newMax) external onlyRole(LIMIT_MANAGER_ROLE) {
        maxDepositPerBlock = newMax;
    }

    /**
     * @dev Sets {treasury}.
     *
     * Only callable by the admin.
     */
    function setTreasury(address newTreasury) external onlyRole(ADMIN_ROLE) {
        if (newTreasury == address(0)) revert InvalidZeroAddress();
        treasury = newTreasury;
    }

    /**
     * @dev Sets {poolSize}, {withdrawAllowance}, and {dailyLinearYieldRatePpm}.
     *
     * Only callable by the pool manager.
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
    }

    /**
     * @dev Returns the underlying asset of the vault.
     *
     * Implements the IERC4626 interface.
     */
    function asset() public view returns (address) {
        return address(_asset);
    }

    /**
     * @dev Returns the total assets managed by the vault.
     *
     * Includes the pool size and the yield accrued since the last update.
     */
    function totalAssets() public view returns (uint256) {
        uint256 yieldSinceUpdate = _yieldSinceUpdate(Math.Rounding.Floor);
        return poolSize + yieldSinceUpdate;
    }

    /**
     * @dev Returns the amount of assets required to mint a given number of shares.
     */
    function convertToAssets(uint256 shares) public view returns (uint256) {
        return previewMint(shares);
    }

    /**
     * @dev Returns the number of shares minted for a given amount of assets.
     */
    function convertToShares(uint256 assets) public view returns (uint256) {
        return previewDeposit(assets);
    }

    /**
     * @dev Returns the maximum amount of assets that can be deposited.
     *
     * Takes an address as input for ERC4626 compatibility.
     * Deposit size is only limited by the maximum deposit per block.
     */
    function maxDeposit(address) public view returns (uint256) {
        uint256 deposited = depositedPerBlock[block.number];
        if (deposited >= maxDepositPerBlock) return 0;
        return maxDepositPerBlock - deposited;
    }

    /**
     * @dev Returns the maximum number of shares that can be minted.
     *
     * Takes an address as input for ERC4626 compatibility.
     * Mint size is only limited by the maximum deposit per block.
     */
    function maxMint(address receiver) public view returns (uint256) {
        return previewMint(maxDeposit(receiver));
    }

    /**
     * @dev Returns the maximum withdraw by an owner.
     *
     * Max withdraw is limited by the maximum withdrawal per block and the owner's balance.
     */
    function maxWithdraw(address owner) public view returns (uint256) {
        return Math.min(previewRedeem(balanceOf(owner)), withdrawAllowance);
    }

    /**
     * @dev Returns the maximum redeem by an owner.
     *
     * Max redeem is limited by the maximum withdrawal per block and the owner's shares.
     */
    function maxRedeem(address owner) public view returns (uint256) {
        return Math.min(balanceOf(owner), previewWithdraw(withdrawAllowance));
    }

    /**
     * @dev Returns the number of shares minted for a given amount of assets.
     */
    function previewDeposit(uint256 assets) public view returns (uint256) {
        return _convertToSharesMinted(assets);
    }

    /**
     * @dev Returns the amount of assets required to mint a given number of shares.
     */
    function previewMint(uint256 shares) public view returns (uint256) {
        return _convertToAssetsDeposited(shares);
    }

    /**
     * @dev Returns the number of shares that would be redeemed for a given amount of assets.
     */
    function previewWithdraw(uint256 assets) public view returns (uint256) {
        return _convertToSharesRedeemed(assets);
    }

    /**
     * @dev Returns the amount of assets that would be redeemed for a given number of shares.
     */
    function previewRedeem(uint256 shares) public view returns (uint256) {
        return _convertToAssetsWithdrawn(shares);
    }

    /**
     * @dev Deposits assets into the vault and mints shares to the receiver.
     *
     * Takes the amount of assets to deposit as input.
     * Returns the number of shares minted.
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
     * @dev Deposits assets into the vault and mints shares to the receiver.
     *
     * Takes the number of shares to mint as input.
     * Returns the amount of assets deposited.
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
     * @dev Reverting ERC4626 withdraw function.
     *
     * Instant withdrawals are not supported.
     */
    function withdraw(uint256 assets, address receiver, address owner) public pure returns (uint256) {
        revert WithdrawNotSupported();
    }

    /**
     * @dev Reverting ERC4626 redeem function.
     *
     * Instant redemptions are not supported.
     */
    function redeem(uint256 shares, address receiver, address owner) public pure returns (uint256) {
        revert RedeemNotSupported();
    }

    /**
     * @dev Creates a redeem order for the caller.
     *
     * Takes the number of shares to redeem as input.
     * Returns the order ID and the amount of assets to be redeemed.
     */
    function createRedeemOrder(uint256 shares) public nonReentrant returns (uint256, uint256) {
        if (shares == 0) revert InvalidZeroShares();
        uint256 maxShares = maxRedeem(_msgSender());
        if (shares > maxShares) revert MaxRedeemExceeded(shares, maxShares);
        uint256 assets = previewRedeem(shares);
        uint256 orderId = _createRedeemOrder(_msgSender(), assets, shares);
        emit RedeemOrderCreated(orderId, _msgSender(), assets, shares);
        return (orderId, assets);
    }

    /**
     * @dev Fills a redeem order by transferring assets to the owner.
     *
     * Only callable by the order filler.
     */
    function fillRedeemOrder(uint256 orderId) public nonReentrant onlyRole(ORDER_FILLER_ROLE) {
        Order storage order = redeemOrders[orderId];
        if (order.shares == 0) revert InvalidOrder(orderId);
        if (order.executed) revert OrderAlreadyExecuted();
        _fillRedeemOrder(order, _msgSender());
        emit RedeemOrderFilled(orderId, order.owner, _msgSender(), order.assets, order.shares);
    }

    /**
     * @dev Rescues tokens from the contract.
     *
     * Only callable by the admin.
     * Tokens that are the underlying asset of the vault cannot be rescued.
     */
    function rescueTokens(address token, address to, uint256 amount) external onlyRole(ADMIN_ROLE) {
        if (token == asset()) revert InvalidToken(token);
        SafeERC20.safeTransfer(IERC20(token), to, amount);
    }

    /**
     * @dev Returns a redeem order by its ID.
     */
    function getRedeemOrder(uint256 orderId) external view returns (Order memory) {
        return redeemOrders[orderId];
    }

    /**
     * @dev Converts assets to shares for minting.
     *
     * Internal function used to calculate shares minted from assets.
     */
    function _convertToSharesMinted(uint256 assets) internal view returns (uint256) {
        if (poolSize == 0) return assets;
        uint256 _totalAssets = poolSize + _yieldSinceUpdate(Math.Rounding.Ceil);
        return Math.mulDiv(totalSupply(), assets, _totalAssets, Math.Rounding.Floor);
    }

    /**
     * @dev Converts shares to assets for deposits.
     *
     * Internal function used to calculate assets deposited from shares.
     */
    function _convertToSharesRedeemed(uint256 assets) internal view returns (uint256) {
        if (poolSize == 0) return assets;
        return Math.mulDiv(assets, totalSupply(), poolSize, Math.Rounding.Ceil);
    }

    /**
     * @dev Converts shares to assets for withdrawals.
     *
     * Internal function used to calculate assets withdrawn from shares.
     */
    function _convertToAssetsDeposited(uint256 shares) internal view returns (uint256) {
        if (poolSize == 0) return shares;
        uint256 _totalAssets = poolSize + _yieldSinceUpdate(Math.Rounding.Ceil);
        return Math.mulDiv(_totalAssets, shares, totalSupply(), Math.Rounding.Ceil);
    }

    /**
     * @dev Converts assets to shares for withdrawals.
     *
     * Internal function used to calculate shares withdrawn from assets.
     */
    function _convertToAssetsWithdrawn(uint256 shares) internal view returns (uint256) {
        if (poolSize == 0) return shares;
        return Math.mulDiv(poolSize, shares, totalSupply(), Math.Rounding.Floor);
    }

    /**
     * @dev Internal function to handle deposits.
     *
     * Transfers assets from the caller to the treasury, mints shares to the receiver,
     * and updates the deposited per block and pool size.
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
     * Reduces the withdraw allowance and pool size, burns shares, and creates a redeem order.
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
     * would have accrued yield making it worth `assets` now.
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
