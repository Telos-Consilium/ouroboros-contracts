// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "./interfaces/IStakedYuzuUSD.sol";
import "./interfaces/IStakedYuzuUSDDefinitions.sol";

/**
 * @title StakedYuzuUSD
 */
contract StakedYuzuUSD is ERC4626, Ownable2Step, ReentrancyGuard, IStakedYuzuUSDDefinitions {
    uint256 public currentRedeemAssetCommitment;

    mapping(uint256 => uint256) public depositedPerBlock;
    mapping(uint256 => uint256) public withdrawnPerBlock;
    uint256 public maxDepositPerBlock;
    uint256 public maxWithdrawPerBlock;

    mapping(uint256 => Order) internal redeemOrders;
    uint256 public redeemOrderCount;

    uint256 public redeemWindow = 1 days;

    constructor(IERC20 _yzUSD, uint256 _maxDepositPerBlock, uint256 _maxWithdrawPerBlock)
        ERC4626(_yzUSD)
        ERC20("Staked Yuzu USD", "st-yzUSD")
        Ownable(_msgSender())
    {
        maxDepositPerBlock = _maxDepositPerBlock;
        maxWithdrawPerBlock = _maxWithdrawPerBlock;
    }

    function setMaxDepositPerBlock(uint256 newMax) external onlyOwner {
        maxDepositPerBlock = newMax;
    }

    function setMaxWithdrawPerBlock(uint256 newMax) external onlyOwner {
        maxWithdrawPerBlock = newMax;
    }

    function setRedeemWindow(uint256 newWindow) external onlyOwner {
        redeemWindow = newWindow;
    }

    function totalAssets() public view override returns (uint256) {
        return super.totalAssets() - currentRedeemAssetCommitment;
    }

    function maxDeposit(address) public view override returns (uint256) {
        uint256 mintedThisBlock = depositedPerBlock[block.number];
        if (mintedThisBlock >= maxDepositPerBlock) return 0;
        return maxDepositPerBlock - mintedThisBlock;
    }

    function maxMint(address) public view override returns (uint256) {
        return convertToShares(maxDeposit(_msgSender()));
    }

    function maxWithdraw(address owner) public view override returns (uint256) {
        uint256 redeemedThisBlock = withdrawnPerBlock[block.number];
        if (redeemedThisBlock >= maxWithdrawPerBlock) return 0;
        return Math.min(super.maxWithdraw(owner), maxWithdrawPerBlock - redeemedThisBlock);
    }

    function maxRedeem(address owner) public view override returns (uint256) {
        uint256 redeemedThisBlock = withdrawnPerBlock[block.number];
        if (redeemedThisBlock >= maxWithdrawPerBlock) return 0;
        return Math.min(super.maxRedeem(owner), convertToShares(maxWithdrawPerBlock - redeemedThisBlock));
    }

    function deposit(uint256 assets, address receiver) public override nonReentrant returns (uint256) {
        uint256 shares = super.deposit(assets, receiver);
        depositedPerBlock[block.number] += assets;
        return shares;
    }

    function mint(uint256 shares, address receiver) public override nonReentrant returns (uint256) {
        uint256 assets = super.mint(shares, receiver);
        depositedPerBlock[block.number] += assets;
        return shares;
    }

    function withdraw(uint256 assets, address receiver, address owner) public override returns (uint256) {
        revert WithdrawNotSupported();
    }

    function redeem(uint256 shares, address receiver, address owner) public override returns (uint256) {
        revert RedeemNotSupported();
    }

    function initiateRedeem(uint256 shares) public nonReentrant returns (uint256, uint256) {
        if (shares == 0) revert InvalidAmount();
        uint256 maxShares = maxRedeem(_msgSender());
        if (shares > maxShares) revert MaxRedeemExceeded();
        uint256 assets = convertToAssets(shares);
        withdrawnPerBlock[block.number] += assets;
        uint256 orderId = _initiateRedeem(_msgSender(), assets, shares);
        emit RedeemInitiated(orderId, _msgSender(), assets, shares);
        return (orderId, assets);
    }

    function finalizeRedeem(uint256 orderId) public nonReentrant {
        Order storage order = redeemOrders[orderId];
        if (order.shares == 0) revert InvalidOrder();
        _finalizeRedeem(order);
        emit RedeemFinalized(orderId, order.owner, order.assets, order.shares);
    }

    function rescueTokens(address token, address to, uint256 amount) external onlyOwner {
        if (amount == 0) revert InvalidAmount();
        if (token == asset()) revert InvalidToken();
        SafeERC20.safeTransfer(IERC20(token), to, amount);
    }

    function getRedeemOrder(uint256 orderId) external view returns (Order memory) {
        return redeemOrders[orderId];
    }

    function _initiateRedeem(address owner, uint256 assets, uint256 shares) internal returns (uint256) {
        _burn(owner, shares);
        uint256 orderId = redeemOrderCount;
        redeemOrders[orderId] = Order({
            assets: assets,
            shares: shares,
            owner: owner,
            dueTime: uint40(block.timestamp + redeemWindow),
            executed: false
        });
        redeemOrderCount++;
        currentRedeemAssetCommitment += assets;
        return orderId;
    }

    function _finalizeRedeem(Order storage order) internal {
        if (order.executed) revert OrderAlreadyExecuted();
        if (block.timestamp < order.dueTime) revert OrderNotDue();
        order.executed = true;
        currentRedeemAssetCommitment -= order.assets;
        SafeERC20.safeTransfer(IERC20(asset()), order.owner, order.assets);
    }
}
