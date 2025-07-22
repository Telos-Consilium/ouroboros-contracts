// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "@openzeppelin/contracts/access/extensions/AccessControlDefaultAdminRules.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "./interfaces/IYuzuILPDefinitions.sol";

struct Order {
    uint256 assets;
    uint256 shares;
    address owner;
    bool executed;
}

/**
 * @title YuzuILP
 */
contract YuzuILP is ERC4626, AccessControlDefaultAdminRules, ReentrancyGuard, IYuzuILPDefinitions {
    bytes32 private constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 private constant LIMIT_MANAGER_ROLE = keccak256("LIMIT_MANAGER_ROLE");
    bytes32 private constant ORDER_FILLER_ROLE = keccak256("ORDER_FILLER_ROLE");
    bytes32 private constant POOL_MANAGER_ROLE = keccak256("POOL_MANAGER_ROLE");

    mapping(uint256 => uint256) public mintedPerBlockInAssets;
    uint256 public maxMintPerBlockInAssets;

    mapping(uint256 => Order) internal redeemOrders;
    uint256 public redeemOrderCount;

    address public treasury;
    uint256 public poolSize;
    uint256 public withdrawAllowance;
    uint256 public dailyLinearYieldRatePpm;
    uint256 public lastPoolUpdateTimestamp;

    constructor(IERC20 asset_, address _admin, uint256 _maxMintPerBlockInAssets)
        ERC4626(asset_)
        ERC20("Yuzu ILP", "yzILP")
        AccessControlDefaultAdminRules(0, _admin)
    {
        maxMintPerBlockInAssets = _maxMintPerBlockInAssets;

        _grantRole(ADMIN_ROLE, _admin);
        _setRoleAdmin(LIMIT_MANAGER_ROLE, ADMIN_ROLE);
        _setRoleAdmin(POOL_MANAGER_ROLE, ADMIN_ROLE);
        _setRoleAdmin(ORDER_FILLER_ROLE, ADMIN_ROLE);
    }

    function setMaxMintPerBlockInAssets(uint256 newMax) external onlyRole(LIMIT_MANAGER_ROLE) {
        maxMintPerBlockInAssets = newMax;
    }

    function setTreasury(address newTreasury) external onlyRole(ADMIN_ROLE) {
        if (newTreasury == address(0)) revert InvalidAddress();
        treasury = newTreasury;
    }

    function updatePool(uint256 newPoolSize, uint256 newWithdrawalAllowance, uint256 newDailyLinearYieldRatePpm)
        external
        onlyRole(POOL_MANAGER_ROLE)
    {
        if (newWithdrawalAllowance > newPoolSize) revert InvalidAmount();
        poolSize = newPoolSize;
        withdrawAllowance = newWithdrawalAllowance;
        dailyLinearYieldRatePpm = newDailyLinearYieldRatePpm;
        lastPoolUpdateTimestamp = block.timestamp;
    }

    function totalAssets() public view override returns (uint256) {
        uint256 yieldSinceUpdate = _yieldSinceUpdate(Math.Rounding.Floor);
        return poolSize + yieldSinceUpdate;
    }

    function maxDeposit(address) public view override returns (uint256) {
        uint256 mintedThisBlock = mintedPerBlockInAssets[block.number];
        if (mintedThisBlock >= maxMintPerBlockInAssets) return 0;
        return maxMintPerBlockInAssets - mintedThisBlock;
    }

    function maxMint(address) public view override returns (uint256) {
        return convertToShares(maxDeposit(_msgSender()));
    }

    function maxWithdraw(address owner) public view override returns (uint256) {
        return Math.min(super.maxWithdraw(owner), withdrawAllowance);
    }

    function maxRedeem(address owner) public view override returns (uint256) {
        return Math.min(super.maxRedeem(owner), convertToShares(withdrawAllowance));
    }

    function withdraw(uint256 assets, address receiver, address owner) public override returns (uint256) {
        revert WithdrawNotSupported();
    }

    function redeem(uint256 shares, address receiver, address owner) public override returns (uint256) {
        revert RedeemNotSupported();
    }

    function createRedeemOrder(uint256 shares) public nonReentrant returns (uint256, uint256) {
        if (shares == 0) revert InvalidAmount();
        uint256 maxShares = maxRedeem(_msgSender());
        if (shares > maxShares) revert MaxRedeemExceeded();
        uint256 assets = convertToAssets(shares);
        uint256 orderId = _createRedeemOrder(_msgSender(), assets, shares);
        emit RedeemOrderCreated(orderId, _msgSender(), assets, shares);
        return (orderId, assets);
    }

    function fillRedeemOrder(uint256 orderId) public nonReentrant onlyRole(ORDER_FILLER_ROLE) {
        Order storage order = redeemOrders[orderId];
        if (order.shares == 0) revert InvalidOrder();
        _fillRedeemOrder(order, _msgSender());
        emit RedeemFilled(orderId, order.owner, _msgSender(), order.assets, order.shares);
    }

    function rescueTokens(address token, address to, uint256 amount) external onlyRole(ADMIN_ROLE) {
        if (amount == 0) revert InvalidAmount();
        if (token == asset()) revert InvalidToken();
        SafeERC20.safeTransfer(IERC20(token), to, amount);
    }

    function getRedeemOrder(uint256 orderId) external view returns (Order memory) {
        return redeemOrders[orderId];
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

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        SafeERC20.safeTransferFrom(IERC20(asset()), caller, treasury, assets);
        _mint(receiver, shares);
        mintedPerBlockInAssets[block.number] += assets;
        withdrawAllowance += assets;
        poolSize += _discountYieldSinceLastUpdate(assets);
        emit Deposit(caller, receiver, assets, shares);
    }

    function _yieldSinceUpdate(Math.Rounding rounding) internal view returns (uint256) {
        if (dailyLinearYieldRatePpm == 0 || poolSize == 0 || block.timestamp <= lastPoolUpdateTimestamp) {
            return 0;
        }
        uint256 dailyYield = Math.mulDiv(poolSize, dailyLinearYieldRatePpm, 1e6, rounding);
        uint256 elapsedTime = block.timestamp - lastPoolUpdateTimestamp;
        uint256 yieldSinceUpdate = Math.mulDiv(dailyYield, elapsedTime, 1 days, rounding);
        return yieldSinceUpdate;
    }

    function _discountYieldSinceLastUpdate(uint256 assets) internal view returns (uint256) {
        // Return the size of a deposit at the time of the last update that would
        // have resulted in the current value of the deposit being equal to assets
        uint256 yieldSinceUpdate = _yieldSinceUpdate(Math.Rounding.Ceil);
        if (yieldSinceUpdate == 0) return assets;
        uint256 discountedAssets =
            Math.mulDiv(yieldSinceUpdate, assets, poolSize + yieldSinceUpdate, Math.Rounding.Floor);
        return discountedAssets;
    }
}
