// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

struct Order {
    uint256 assets;
    uint256 shares;
    address owner;
    bool executed;
}

/**
 * @title YuzuILP
 */
contract YuzuILP is ERC4626, Ownable2Step, ReentrancyGuard {
    event RedeemOrderCreated(uint256 indexed orderId, address indexed owner, uint256 assets, uint256 shares);
    event RedeemFilled(
        uint256 indexed orderId, address indexed owner, address indexed filler, uint256 assets, uint256 shares
    );

    error WithdrawNotSupported();
    error InvalidAmount();
    error InvalidToken();
    error InvalidOrder();
    error RedeemNotSupported();
    error MaxRedeemExceeded();
    error OrderAlreadyExecuted();
    error OrderNotDue();

    mapping(uint256 => uint256) public mintedPerBlockInAssets;
    uint256 public maxMintPerBlockInAssets;

    mapping(uint256 => Order) internal redeemOrders;
    uint256 public redeemOrderCount;

    uint256 public poolSize;
    uint256 public withdrawAllowance;

    constructor(IERC20 _yzUSD, uint256 _maxMintPerBlockInAssets)
        ERC4626(_yzUSD)
        ERC20("Yuzu ILP", "yzILP")
        Ownable(_msgSender())
    {
        maxMintPerBlockInAssets = _maxMintPerBlockInAssets;
    }

    function setMaxMintPerBlockInAssets(uint256 newMax) external onlyOwner {
        maxMintPerBlockInAssets = newMax;
    }

    function updatePoolSize(uint256 newPoolSize, uint256 newWithdrawalAllowance) external onlyOwner {
        if (newWithdrawalAllowance > newPoolSize) revert InvalidAmount();
        poolSize = newPoolSize;
        withdrawAllowance = newWithdrawalAllowance;
    }

    function totalAssets() public view override returns (uint256) {
        return poolSize;
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

    function deposit(uint256 assets, address receiver) public override nonReentrant returns (uint256) {
        uint256 shares = super.deposit(assets, receiver);
        mintedPerBlockInAssets[block.number] += assets;
        return shares;
    }

    function mint(uint256 shares, address receiver) public override nonReentrant returns (uint256) {
        uint256 assets = super.mint(shares, receiver);
        mintedPerBlockInAssets[block.number] += assets;
        return shares;
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

    function fillRedeemOrder(uint256 orderId) public nonReentrant onlyOwner {
        Order storage order = redeemOrders[orderId];
        if (order.shares == 0) revert InvalidOrder();
        _fillRedeemOrder(order, _msgSender());
        emit RedeemFilled(orderId, order.owner, _msgSender(), order.assets, order.shares);
    }

    function rescueTokens(address token, address to, uint256 amount) external onlyOwner {
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
}
