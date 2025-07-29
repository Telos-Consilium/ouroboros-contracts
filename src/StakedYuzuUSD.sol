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
 * @notice ERC-4625 tokenized vault for staking yzUSD with 2-step delayed redemptions.
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
     * @notice Initializes the StakedYuzuUSD contract with the specified parameters.
     * @param _yzUSD The underlying ERC-20 token (yzUSD) for the vault
     * @param name_ The name of the staked token, e.g. "Staked YuzuUSD"
     * @param symbol_ The symbol of the staked token, e.g. "st-yzUSD"
     * @param _owner The owner of the contract
     * @param _maxDepositPerBlock Maximum assets that can be deposited per block
     * @param _maxWithdrawPerBlock Maximum assets that can be withdrawn per block
     *
     * Sets the redeem window to 1 day by default.
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

        redeemWindow = 1 days;

        redeemOrderCount = 0;
        currentRedeemAssetCommitment = 0;
    }

    /**
     * @notice Sets the maximum deposit per block to {newMaxDepositPerBlock}.
     *
     * Emits a `MaxDepositPerBlockUpdated` event with the old and new limits.
     * Reverts if called by anyone but the owner.
     */
    function setMaxDepositPerBlock(uint256 newMaxDepositPerBlock) external onlyOwner {
        uint256 oldMaxDepositPerBlock = maxDepositPerBlock;
        maxDepositPerBlock = newMaxDepositPerBlock;
        emit MaxDepositPerBlockUpdated(oldMaxDepositPerBlock, newMaxDepositPerBlock);
    }

    /**
     * @notice Sets the maximum withdraw per block to {newMaxWithdrawPerBlock}.
     *
     * Emits a `MaxWithdrawPerBlockUpdated` event with the old and new limits.
     * Reverts if called by anyone but the owner.
     */
    function setMaxWithdrawPerBlock(uint256 newMaxWithdrawPerBlock) external onlyOwner {
        uint256 oldMaxWithdrawPerBlock = maxWithdrawPerBlock;
        maxWithdrawPerBlock = newMaxWithdrawPerBlock;
        emit MaxWithdrawPerBlockUpdated(oldMaxWithdrawPerBlock, newMaxWithdrawPerBlock);
    }

    /**
     * @notice Sets the redeem window to {newRedeemWindow}.
     *
     * Emits a `RedeemWindowUpdated` event with the old and new window durations.
     * Reverts if called by anyone but the owner.
     */
    function setRedeemWindow(uint256 newRedeemWindow) external onlyOwner {
        uint256 oldRedeemWindow = redeemWindow;
        redeemWindow = newRedeemWindow;
        emit RedeemWindowUpdated(oldRedeemWindow, newRedeemWindow);
    }

    /**
     * @notice Returns the total amount of underlying asset deposits in vault.
     *
     * Assets in pending redemptions are not included in total assets.
     */
    function totalAssets() public view override returns (uint256) {
        return super.totalAssets() - currentRedeemAssetCommitment;
    }

    /**
     * @notice Returns the maximum deposit.
     *
     * Takes an address as input for ERC-4625 compatibility.
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
     * Takes an address as input for ERC-4625 compatibility.
     * Mint size is only limited by the maximum deposit per block.
     */
    function maxMint(address receiver) public view override returns (uint256) {
        return convertToShares(maxDeposit(receiver));
    }

    /**
     * @notice Returns the maximum withdraw by {owner}.
     *
     * Max withdraw is limited by the maximum withdrawal per block and the owner's shares.
     */
    function maxWithdraw(address owner) public view override returns (uint256) {
        uint256 withdrawn = withdrawnPerBlock[block.number];
        if (withdrawn >= maxWithdrawPerBlock) return 0;
        return Math.min(super.maxWithdraw(owner), maxWithdrawPerBlock - withdrawn);
    }

    /**
     * @notice Returns the maximum redeem by {owner}.
     *
     * Max redeem is limited by the maximum withdrawal per block and the owner's shares.
     */
    function maxRedeem(address owner) public view override returns (uint256) {
        uint256 withdrawn = withdrawnPerBlock[block.number];
        if (withdrawn >= maxWithdrawPerBlock) return 0;
        return Math.min(super.maxRedeem(owner), previewWithdraw(maxWithdrawPerBlock - withdrawn));
    }

    /**
     * @notice Deposits {assets} into the vault and mints shares to {receiver}.
     *
     * Takes the amount of assets to deposit as input.
     * Returns the number of shares minted.
     * Emits a `Deposit` event with the sender, owner, assets, and shares.
     */
    function deposit(uint256 assets, address receiver) public override nonReentrant returns (uint256) {
        uint256 shares = super.deposit(assets, receiver);
        depositedPerBlock[block.number] += assets;
        return shares;
    }

    /**
     * @notice Deposits assets into the vault and mints {shares} to {receiver}.
     *
     * Takes the number of shares to mint as input.
     * Returns the amount of assets deposited.
     * Emits a `Deposit` event with the sender, owner, assets, and shares.
     */
    function mint(uint256 shares, address receiver) public override nonReentrant returns (uint256) {
        uint256 assets = super.mint(shares, receiver);
        depositedPerBlock[block.number] += assets;
        return assets;
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
     * The assets will be redeemable after the redeem window elapses.
     * Returns the order ID and the amount of assets to be redeemed.
     * Emits a `RedeemInitiated` event with the order ID, owner, assets, and shares.
     * Reverts if {shares} is zero or exceeds the maximum redeem allowed.
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
     * @notice Finalizes a 2-step redemption order by {orderId}.
     *
     * Can be called by anyone, not just the owner.
     * Emits a `RedeemFinalized` event with caller, the order ID, owner, assets, and shares.
     * Emits a `Withdraw` event with the sender, receiver, owner, assets, and shares for ERC-4626 compatibility.
     * Reverts if the order is already executed or not due yet.
     */
    function finalizeRedeem(uint256 orderId) public nonReentrant {
        Order storage order = redeemOrders[orderId];
        if (order.shares == 0) revert InvalidOrder(orderId);
        if (order.executed) revert OrderAlreadyExecuted(orderId);
        if (block.timestamp < order.dueTime) revert OrderNotDue(orderId);
        _finalizeRedeem(order);
        emit RedeemFinalized(_msgSender(), orderId, order.owner, order.assets, order.shares);
        emit Withdraw(_msgSender(), order.owner, order.owner, order.assets, order.shares);
    }

    /**
     * @notice Transfers {amount} of {token} held by the vault to {to}.
     *
     * Reverts if called by anyone but the owner.
     * Reverts if {token} is the underlying asset of the vault.
     */
    function rescueTokens(address token, address to, uint256 amount) external onlyOwner {
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
     * @dev Internal function to initiate a redeem order.
     *
     * Burns the shares and creates a redeem order for {assets} and {shares}.
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
