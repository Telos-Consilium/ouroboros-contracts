// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./interfaces/IStakedYuzuUSD.sol";
import "./interfaces/IStakedYuzuUSDDefinitions.sol";

/**
 * @title StakedYuzuUSD
 */
contract StakedYuzuUSD is
    Initializable,
    ERC4626Upgradeable,
    Ownable2StepUpgradeable,
    ReentrancyGuardUpgradeable,
    IStakedYuzuUSDDefinitions
{
    uint256 public currentRedeemAssetCommitment;

    mapping(uint256 => uint256) public depositedPerBlock;
    mapping(uint256 => uint256) public withdrawnPerBlock;
    uint256 public maxDepositPerBlock;
    uint256 public maxWithdrawPerBlock;

    mapping(uint256 => Order) internal redeemOrders;
    uint256 public redeemOrderCount;

    uint256 public redeemWindow;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        IERC20 _yzUSD,
        string memory name_,
        string memory symbol_,
        address _owner,
        uint256 _maxDepositPerBlock,
        uint256 _maxWithdrawPerBlock
    ) external initializer {
        __ERC4626_init(_yzUSD);
        __ERC20_init(name_, symbol_);
        __Ownable_init(_owner);
        __Ownable2Step_init();
        __ReentrancyGuard_init();

        maxDepositPerBlock = _maxDepositPerBlock;
        maxWithdrawPerBlock = _maxWithdrawPerBlock;
        redeemOrderCount = 0;
        currentRedeemAssetCommitment = 0;
        redeemWindow = 1 days;
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
        uint256 deposited = depositedPerBlock[block.number];
        if (deposited >= maxDepositPerBlock) return 0;
        return maxDepositPerBlock - deposited;
    }

    function maxMint(address receiver) public view override returns (uint256) {
        return convertToShares(maxDeposit(receiver));
    }

    function maxWithdraw(address owner) public view override returns (uint256) {
        uint256 withdrawn = withdrawnPerBlock[block.number];
        if (withdrawn >= maxWithdrawPerBlock) return 0;
        return Math.min(super.maxWithdraw(owner), maxWithdrawPerBlock - withdrawn);
    }

    function maxRedeem(address owner) public view override returns (uint256) {
        uint256 withdrawn = withdrawnPerBlock[block.number];
        if (withdrawn >= maxWithdrawPerBlock) return 0;
        return Math.min(super.maxRedeem(owner), previewWithdraw(maxWithdrawPerBlock - withdrawn));
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
        if (shares == 0) revert InvalidZeroShares();
        uint256 maxShares = maxRedeem(_msgSender());
        if (shares > maxShares) revert MaxRedeemExceeded(shares, maxShares);
        uint256 assets = previewRedeem(shares);
        withdrawnPerBlock[block.number] += assets;
        uint256 orderId = _initiateRedeem(_msgSender(), assets, shares);
        emit RedeemInitiated(orderId, _msgSender(), assets, shares);
        return (orderId, assets);
    }

    function finalizeRedeem(uint256 orderId) public nonReentrant {
        Order storage order = redeemOrders[orderId];
        if (order.shares == 0) revert InvalidOrder(orderId);
        if (order.executed) revert OrderAlreadyExecuted(orderId);
        if (block.timestamp < order.dueTime) revert OrderNotDue(orderId);
        _finalizeRedeem(order);
        emit RedeemFinalized(orderId, order.owner, order.assets, order.shares);
    }

    function rescueTokens(address token, address to, uint256 amount) external onlyOwner {
        if (token == asset()) revert InvalidToken(token);
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
        order.executed = true;
        currentRedeemAssetCommitment -= order.assets;
        SafeERC20.safeTransfer(IERC20(asset()), order.owner, order.assets);
    }

    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     */
    uint256[50] private __gap;
}
