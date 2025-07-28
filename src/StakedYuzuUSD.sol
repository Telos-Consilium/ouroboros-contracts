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
 * @dev ERC4625 tokenized vault for staking yzUSD with 2-step delayed redemptions.
 */
contract StakedYuzuUSD is
    Initializable,
    ERC4626Upgradeable,
    Ownable2StepUpgradeable,
    ReentrancyGuardUpgradeable,
    IStakedYuzuUSDDefinitions
{
    uint256 public redeemWindow;

    uint256 public currentRedeemAssetCommitment;

    mapping(uint256 => uint256) public depositedPerBlock;
    mapping(uint256 => uint256) public withdrawnPerBlock;
    uint256 public maxDepositPerBlock;
    uint256 public maxWithdrawPerBlock;

    mapping(uint256 => Order) internal redeemOrders;
    uint256 public redeemOrderCount;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @dev Sets the values for {yzUSD}, {name}, {symbol}, {owner}, {maxDepositPerBlock}, and {maxWithdrawPerBlock}.
     *
     * {redeemWindow} is set to 1 day by default.
     */
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

    /**
     * @dev Sets {maxDepositPerBlock}.
     *
     * Only callable by the owner.
     */
    function setMaxDepositPerBlock(uint256 newMax) external onlyOwner {
        maxDepositPerBlock = newMax;
    }

    /**
     * @dev Sets {maxWithdrawPerBlock}.
     *
     * Only callable by the owner.
     */
    function setMaxWithdrawPerBlock(uint256 newMax) external onlyOwner {
        maxWithdrawPerBlock = newMax;
    }

    /**
     * @dev Sets {redeemWindow}.
     *
     * Only callable by the owner.
     */
    function setRedeemWindow(uint256 newWindow) external onlyOwner {
        redeemWindow = newWindow;
    }

    /**
     * @dev Returns the asset balance of the contract minus the balance already committed
     * to redemptions.
     *
     * Only callable by the owner.
     */
    function totalAssets() public view override returns (uint256) {
        return super.totalAssets() - currentRedeemAssetCommitment;
    }

    /**
     * @dev Returns the maximum deposit.
     *
     * Takes an address as input for ERC4625 compatibility.
     * Deposit size is only limited by the maximum deposit per block.
     */
    function maxDeposit(address) public view override returns (uint256) {
        uint256 deposited = depositedPerBlock[block.number];
        if (deposited >= maxDepositPerBlock) return 0;
        return maxDepositPerBlock - deposited;
    }

    /**
     * @dev Returns the maximum mint.
     *
     * Takes an address as input for ERC4625 compatibility.
     * Mint size is only limited by the maximum deposit per block.
     */
    function maxMint(address receiver) public view override returns (uint256) {
        return convertToShares(maxDeposit(receiver));
    }

    /**
     * @dev Returns the maximum withdraw by an owner.
     *
     * Max withdraw is limited by the maximum withdrawal per block and the owner's balance.
     */
    function maxWithdraw(address owner) public view override returns (uint256) {
        uint256 withdrawn = withdrawnPerBlock[block.number];
        if (withdrawn >= maxWithdrawPerBlock) return 0;
        return Math.min(super.maxWithdraw(owner), maxWithdrawPerBlock - withdrawn);
    }

    /**
     * @dev Returns the maximum redeem by an owner.
     *
     * Max redeem is limited by the maximum withdrawal per block and the owner's shares.
     */
    function maxRedeem(address owner) public view override returns (uint256) {
        uint256 withdrawn = withdrawnPerBlock[block.number];
        if (withdrawn >= maxWithdrawPerBlock) return 0;
        return Math.min(super.maxRedeem(owner), previewWithdraw(maxWithdrawPerBlock - withdrawn));
    }

    /**
     * @dev Deposits assets into the vault and mints shares to the receiver.
     *
     * Takes the amount of assets to deposit as input.
     * Returns the number of shares minted.
     */
    function deposit(uint256 assets, address receiver) public override nonReentrant returns (uint256) {
        uint256 shares = super.deposit(assets, receiver);
        depositedPerBlock[block.number] += assets;
        return shares;
    }

    /**
     * @dev Deposits assets into the vault and mints shares to the receiver.
     *
     * Takes the number of shares to mint as input.
     * Returns the amount of assets deposited.
     */
    function mint(uint256 shares, address receiver) public override nonReentrant returns (uint256) {
        uint256 assets = super.mint(shares, receiver);
        depositedPerBlock[block.number] += assets;
        return assets;
    }

    /**
     * @dev Overrides the ERC4626 withdraw function to revert.
     *
     * Instant withdrawals are not supported.
     */
    function withdraw(uint256 assets, address receiver, address owner) public override returns (uint256) {
        revert WithdrawNotSupported();
    }

    /**
     * @dev Overrides the ERC4626 redeem function to revert.
     *
     * Instant redemptions are not supported.
     */
    function redeem(uint256 shares, address receiver, address owner) public override returns (uint256) {
        revert RedeemNotSupported();
    }

    /**
     * @dev Initiates a 2-step redemption.
     *
     * Takes the number of shares to redeem as input.
     * The assets will redeemable after the redeem window elapses.
     * Returns the order ID and the amount of assets to be redeemed.
     */
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

    /**
     * @dev Finalizes a 2-step redemption.
     *
     * Can be called by anyone, not just the owner.
     */
    function finalizeRedeem(uint256 orderId) public nonReentrant {
        Order storage order = redeemOrders[orderId];
        if (order.shares == 0) revert InvalidOrder(orderId);
        if (order.executed) revert OrderAlreadyExecuted(orderId);
        if (block.timestamp < order.dueTime) revert OrderNotDue(orderId);
        _finalizeRedeem(order);
        emit RedeemFinalized(orderId, order.owner, order.assets, order.shares);
    }

    /**
     * @dev Rescues tokens from the contract.
     *
     * Only callable by the owner.
     * Tokens that are the underlying asset of the vault cannot be rescued.
     */
    function rescueTokens(address token, address to, uint256 amount) external onlyOwner {
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
     * @dev Internal function to initiate a redeem order.
     *
     * Burns the shares and creates a redeem order with the specified assets and shares.
     * Returns the order ID.
     */
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

    /**
     * @dev Internal function to finalize a redeem order.
     *
     * Marks the order as executed, updates the current redeem asset commitment,
     * and transfers the assets to the owner.
     */
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
