// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";

struct Order {
    uint256 assets;
    uint256 shares;
    address owner;
    uint40 dueTime;
    bool executed;
}

/**
 * @title StackedYuzuUSD
 */
contract StackedYuzuUSD is ERC4626, Ownable2Step {
    error WithdrawNotSupported();
    error InvalidAmount();
    error RedeemNotSupported();
    error MaxRedeemExceeded();
    error InvalidOrder();
    error OrderAlreadyExecuted();
    error OrderNotDue();

    event RedeemInitiated(
        uint256 indexed orderId,
        address indexed owner,
        uint256 assets,
        uint256 shares
    );

    event RedeemFinalized(
        uint256 indexed orderId,
        address indexed owner,
        uint256 assets,
        uint256 shares
    );

    uint256 public currentRedeemAssetCommitment;

    mapping(uint256 => uint256) public mintedPerBlockInAssets;
    mapping(uint256 => uint256) public redeemedPerBlockInAssets;
    uint256 public maxMintPerBlockInAssets;
    uint256 public maxRedeemPerBlockInAssets;

    mapping(uint256 => Order) public redeemOrders;
    uint256 public redeemOrderCount;

    uint256 public redeemWindow = 1 days;

    constructor(
        IERC20 _yzUSD,
        uint256 _maxMintPerBlockInAssets,
        uint256 _maxRedeemPerBlockInAssets
    )
        ERC4626(_yzUSD)
        ERC20("Stacked Yuzu USD", "st-yzUSD")
        Ownable(_msgSender())
    {
        maxMintPerBlockInAssets = _maxMintPerBlockInAssets;
        maxRedeemPerBlockInAssets = _maxRedeemPerBlockInAssets;
    }

    function setMaxMintPerBlockInAssets(uint256 newMax) external onlyOwner {
        maxMintPerBlockInAssets = newMax;
    }

    function setMaxRedeemPerBlockInAssets(uint256 newMax) external onlyOwner {
        maxRedeemPerBlockInAssets = newMax;
    }

    function setRedeemWindow(uint256 newWindow) external onlyOwner {
        redeemWindow = newWindow;
    }

    function totalAssets() public view override returns (uint256) {
        return super.totalAssets() - currentRedeemAssetCommitment;
    }

    function maxDeposit(address) public view override returns (uint256) {
        return maxMintPerBlockInAssets - mintedPerBlockInAssets[block.number];
    }

    function maxMint(address) public view override returns (uint256) {
        return convertToShares(maxDeposit(_msgSender()));
    }

    function maxWithdraw(address owner) public view override returns (uint256) {
        return
            Math.min(
                super.maxWithdraw(owner),
                maxRedeemPerBlockInAssets -
                    redeemedPerBlockInAssets[block.number]
            );
    }

    /** @dev See {IERC4626-maxRedeem}. */
    function maxRedeem(address owner) public view override returns (uint256) {
        return
            Math.min(
                super.maxRedeem(owner),
                convertToShares(
                    maxRedeemPerBlockInAssets -
                        redeemedPerBlockInAssets[block.number]
                )
            );
    }

    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) public override returns (uint256) {
        revert WithdrawNotSupported();
    }

    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) public override returns (uint256) {
        revert RedeemNotSupported();
    }

    function initiateRedeem(uint256 shares) external {
        if (shares == 0) revert InvalidAmount();
        uint256 maxShares = maxRedeem(_msgSender());
        if (shares > maxShares) revert MaxRedeemExceeded();
        uint256 assets = convertToAssets(shares);
        redeemedPerBlockInAssets[block.number] += assets;
        uint256 orderId = _initiateRedeem(_msgSender(), assets, shares);
        emit RedeemInitiated(orderId, _msgSender(), assets, shares);
    }

    function finalizeRedeem(uint256 orderId) external {
        Order storage order = redeemOrders[orderId];
        if (order.shares == 0) revert InvalidOrder();
        _finalizeRedeem(order);
        emit RedeemFinalized(orderId, order.owner, order.assets, order.shares);
    }

    function getRedeemOrder(
        uint256 orderId
    ) external view returns (Order memory) {
        return redeemOrders[orderId];
    }

    function _initiateRedeem(
        address owner,
        uint256 assets,
        uint256 shares
    ) internal returns (uint256) {
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
        _transfer(address(this), order.owner, order.assets);
    }
}
