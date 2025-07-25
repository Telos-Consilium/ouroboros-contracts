// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/access/extensions/AccessControlDefaultAdminRules.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/interfaces/IERC4626.sol";
import "./interfaces/IYuzuILP.sol";
import "./interfaces/IYuzuILPDefinitions.sol";

/**
 * @title YuzuILP
 */
contract YuzuILP is AccessControlDefaultAdminRules, ReentrancyGuard, ERC20, IERC4626, IYuzuILPDefinitions {
    bytes32 private constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 private constant LIMIT_MANAGER_ROLE = keccak256("LIMIT_MANAGER_ROLE");
    bytes32 private constant ORDER_FILLER_ROLE = keccak256("ORDER_FILLER_ROLE");
    bytes32 private constant POOL_MANAGER_ROLE = keccak256("POOL_MANAGER_ROLE");

    IERC20 private immutable _asset;

    mapping(uint256 => uint256) public depositedPerBlock;
    uint256 public maxDepositPerBlock;

    mapping(uint256 => Order) internal redeemOrders;
    uint256 public redeemOrderCount;

    address public treasury;
    uint256 public poolSize;
    uint256 public withdrawAllowance;
    uint256 public dailyLinearYieldRatePpm;
    uint256 public lastPoolUpdateTimestamp;

    constructor(IERC20 asset_, address _admin, address _treasury, uint256 _maxDepositPerBlock)
        ERC20("Yuzu ILP", "yzILP")
        AccessControlDefaultAdminRules(0, _admin)
    {
        if (_admin == address(0)) revert InvalidZeroAddress();
        if (_treasury == address(0)) revert InvalidZeroAddress();

        _asset = asset_;
        treasury = _treasury;
        maxDepositPerBlock = _maxDepositPerBlock;

        _grantRole(ADMIN_ROLE, _admin);
        _setRoleAdmin(LIMIT_MANAGER_ROLE, ADMIN_ROLE);
        _setRoleAdmin(POOL_MANAGER_ROLE, ADMIN_ROLE);
        _setRoleAdmin(ORDER_FILLER_ROLE, ADMIN_ROLE);
    }

    function setMaxDepositPerBlock(uint256 newMax) external onlyRole(LIMIT_MANAGER_ROLE) {
        maxDepositPerBlock = newMax;
    }

    function setTreasury(address newTreasury) external onlyRole(ADMIN_ROLE) {
        if (newTreasury == address(0)) revert InvalidZeroAddress();
        treasury = newTreasury;
    }

    function updatePool(uint256 newPoolSize, uint256 newWithdrawalAllowance, uint256 newDailyLinearYieldRatePpm)
        external
        onlyRole(POOL_MANAGER_ROLE)
    {
        if (newPoolSize > type(uint128).max) revert InvalidAmount(); // 2^128 > 10^38s
        if (newWithdrawalAllowance > newPoolSize) revert InvalidAmount();
        if (newDailyLinearYieldRatePpm > 1e6) revert InvalidYield(); // Max 1e6 ppm = 100% yield per day

        poolSize = newPoolSize;
        withdrawAllowance = newWithdrawalAllowance;
        dailyLinearYieldRatePpm = newDailyLinearYieldRatePpm;
        lastPoolUpdateTimestamp = block.timestamp;
    }

    function asset() public view returns (address) {
        return address(_asset);
    }

    function totalAssets() public view returns (uint256) {
        uint256 yieldSinceUpdate = _yieldSinceUpdate(Math.Rounding.Floor);
        return poolSize + yieldSinceUpdate;
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        return previewMint(shares);
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        return previewDeposit(assets);
    }

    function maxDeposit(address) public view returns (uint256) {
        uint256 deposited = depositedPerBlock[block.number];
        if (deposited >= maxDepositPerBlock) return 0;
        return maxDepositPerBlock - deposited;
    }

    function maxMint(address) public view returns (uint256) {
        return previewMint(maxDeposit(_msgSender()));
    }

    function maxWithdraw(address owner) public view returns (uint256) {
        return Math.min(previewRedeem(balanceOf(owner)), withdrawAllowance);
    }

    function maxRedeem(address owner) public view returns (uint256) {
        return Math.min(balanceOf(owner), previewWithdraw(withdrawAllowance));
    }

    function previewDeposit(uint256 assets) public view returns (uint256) {
        return _convertToSharesMinted(assets);
    }

    function previewMint(uint256 shares) public view returns (uint256) {
        return _convertToAssetsDeposited(shares);
    }

    function previewWithdraw(uint256 assets) public view returns (uint256) {
        return _convertToSharesRedeemed(assets);
    }

    function previewRedeem(uint256 shares) public view returns (uint256) {
        return _convertToAssetsWithdrawn(shares);
    }

    function deposit(uint256 assets, address receiver) public nonReentrant returns (uint256) {
        uint256 maxAssets = maxDeposit(receiver);
        if (assets > maxAssets) {
            revert MaxDepositExceeded();
        }

        uint256 shares = previewDeposit(assets);
        _deposit(_msgSender(), receiver, assets, shares);

        return shares;
    }

    function mint(uint256 shares, address receiver) public nonReentrant returns (uint256) {
        uint256 maxShares = maxMint(receiver);
        if (shares > maxShares) {
            revert MaxMintExceeded();
        }

        uint256 assets = previewMint(shares);
        _deposit(_msgSender(), receiver, assets, shares);

        return assets;
    }

    function withdraw(uint256 assets, address receiver, address owner) public pure returns (uint256) {
        revert WithdrawNotSupported();
    }

    function redeem(uint256 shares, address receiver, address owner) public pure returns (uint256) {
        revert RedeemNotSupported();
    }

    function createRedeemOrder(uint256 shares) public nonReentrant returns (uint256, uint256) {
        if (shares == 0) revert InvalidAmount();
        uint256 maxShares = maxRedeem(_msgSender());
        if (shares > maxShares) revert MaxRedeemExceeded();

        uint256 assets = previewRedeem(shares);
        uint256 orderId = _createRedeemOrder(_msgSender(), assets, shares);
        emit RedeemOrderCreated(orderId, _msgSender(), assets, shares);
        return (orderId, assets);
    }

    function fillRedeemOrder(uint256 orderId) public nonReentrant onlyRole(ORDER_FILLER_ROLE) {
        Order storage order = redeemOrders[orderId];
        if (order.shares == 0) revert InvalidOrder();

        _fillRedeemOrder(order, _msgSender());
        emit RedeemOrderFilled(orderId, order.owner, _msgSender(), order.assets, order.shares);
    }

    function rescueTokens(address token, address to, uint256 amount) external onlyRole(ADMIN_ROLE) {
        if (amount == 0) revert InvalidAmount();
        if (token == asset()) revert InvalidToken();
        SafeERC20.safeTransfer(IERC20(token), to, amount);
    }

    function getRedeemOrder(uint256 orderId) external view returns (Order memory) {
        return redeemOrders[orderId];
    }

    function _convertToSharesMinted(uint256 assets) internal view returns (uint256) {
        if (poolSize == 0) return assets;
        uint256 _totalAssets = poolSize + _yieldSinceUpdate(Math.Rounding.Ceil);
        return Math.mulDiv(totalSupply(), assets, _totalAssets, Math.Rounding.Floor);
    }

    function _convertToSharesRedeemed(uint256 assets) internal view returns (uint256) {
        if (poolSize == 0) return assets;
        return Math.mulDiv(assets, totalSupply(), poolSize, Math.Rounding.Ceil);
    }

    function _convertToAssetsDeposited(uint256 shares) internal view returns (uint256) {
        if (poolSize == 0) return shares;
        uint256 _totalAssets = poolSize + _yieldSinceUpdate(Math.Rounding.Ceil);
        return Math.mulDiv(_totalAssets, shares, totalSupply(), Math.Rounding.Ceil);
    }

    function _convertToAssetsWithdrawn(uint256 shares) internal view returns (uint256) {
        if (poolSize == 0) return shares;
        return Math.mulDiv(poolSize, shares, totalSupply(), Math.Rounding.Floor);
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal {
        SafeERC20.safeTransferFrom(IERC20(asset()), caller, treasury, assets);
        _mint(receiver, shares);
        depositedPerBlock[block.number] += assets;
        withdrawAllowance += assets;
        poolSize += _discountYield(assets, Math.Rounding.Floor);
        emit Deposit(caller, receiver, assets, shares);
    }

    function _createRedeemOrder(address owner, uint256 assets, uint256 shares) internal returns (uint256) {
        withdrawAllowance -= assets;
        poolSize -= assets;
        _burn(owner, shares);
        uint256 orderId = redeemOrderCount;
        redeemOrders[orderId] = Order({assets: assets, shares: shares, owner: owner, executed: false});
        redeemOrderCount++;
        return orderId;
    }

    function _fillRedeemOrder(Order storage order, address filler) internal {
        if (order.executed) revert OrderAlreadyExecuted();
        order.executed = true;
        SafeERC20.safeTransferFrom(IERC20(asset()), filler, order.owner, order.assets);
    }

    function _timeSinceUpdate() internal view returns (uint256) {
        return block.timestamp - lastPoolUpdateTimestamp;
    }

    function _yieldSinceUpdate(Math.Rounding rounding) internal view returns (uint256) {
        uint256 elapsedTime = _timeSinceUpdate();
        if (poolSize == 0 || dailyLinearYieldRatePpm == 0 || elapsedTime == 0) {
            return 0;
        }
        uint256 yieldSinceUpdate = Math.mulDiv(poolSize * dailyLinearYieldRatePpm, elapsedTime, 1e6 days, rounding);
        return yieldSinceUpdate;
    }

    function _discountYield(uint256 assets, Math.Rounding rounding) internal view returns (uint256) {
        // Return the size of a deposit such that, if deposited at the time of the last pool update,
        // would have accrued yield making it worth `assets` now.
        uint256 elapsedTime = _timeSinceUpdate();
        if (poolSize == 0 || dailyLinearYieldRatePpm == 0 || elapsedTime == 0) {
            return assets;
        }
        return Math.mulDiv(assets, 1e6 days, 1e6 days + dailyLinearYieldRatePpm * elapsedTime, rounding);
    }
}
