// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {EIP712Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import {NoncesUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/NoncesUpgradeable.sol";

import {IStakedYuzuUSDDefinitions, Order, OrderStatus} from "./interfaces/IStakedYuzuUSDDefinitions.sol";

/**
 * @title StakedYuzuUSD
 * @notice ERC-4626 tokenized vault for staking yzUSD with 2-step delayed redemptions
 */
contract StakedYuzuUSD is
    ERC4626Upgradeable,
    Ownable2StepUpgradeable,
    PausableUpgradeable,
    EIP712Upgradeable,
    NoncesUpgradeable,
    IStakedYuzuUSDDefinitions,
    IERC20Permit
{
    bytes32 private constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    error ERC2612ExpiredSignature(uint256 deadline);
    error ERC2612InvalidSigner(address signer, address owner);

    uint256 public redeemDelay;
    uint256 public redeemFeePpm;
    address public feeReceiver;

    uint256 public lastDistributedAmount;
    uint256 public lastDistributionPeriod;
    uint256 public lastDistributionTime;

    uint256 public totalPendingOrderValue;

    mapping(uint256 => Order) internal orders;
    uint256 public orderCount;

    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the StakedYuzuUSD contract
     * @param _asset The underlying ERC-20 token for the vault
     * @param __name The name of the staked token
     * @param __symbol The symbol of the staked token
     * @param _owner The owner of the contract
     * @param _feeReceiver The address that receives redemption fees
     * @param _redeemDelay The delay in seconds before a redeem order can be finalized
     */
    // slither-disable-next-line pess-arbitrary-call-destination-tainted
    function initialize(
        IERC20 _asset,
        string memory __name,
        string memory __symbol,
        address _owner,
        address _feeReceiver,
        uint256 _redeemDelay
    ) external initializer {
        __ERC4626_init(_asset);
        __ERC20_init(__name, __symbol);
        __Ownable_init(_owner);
        __Ownable2Step_init();
        __Pausable_init();
        __EIP712_init(__name, "1");
        __Nonces_init();

        if (address(_asset) == address(0)) {
            revert InvalidZeroAddress();
        }
        if (_feeReceiver == address(0)) {
            revert InvalidZeroAddress();
        }

        feeReceiver = _feeReceiver;
        redeemDelay = _redeemDelay;
        lastDistributionPeriod = 1;
    }

    /// @notice See {IERC4626-totalAssets}
    function totalAssets() public view override returns (uint256) {
        uint256 distributed = Math.min(
            lastDistributedAmount,
            Math.mulDiv(
                block.timestamp - lastDistributionTime,
                lastDistributedAmount,
                lastDistributionPeriod,
                Math.Rounding.Floor
            )
        );
        uint256 notDistributed = lastDistributedAmount - distributed;
        return super.totalAssets() - totalPendingOrderValue - notDistributed;
    }

    /// @notice Transfer `amount` of assets from the caller into the vault and schedule it for
    // gradual distribution
    function distribute(uint256 assets, uint256 period) external onlyOwner {
        if (period < 1) {
            revert DistributionPeriodTooLow(period, 1);
        }
        if (period > 7 days) {
            revert DistributionPeriodTooHigh(period, 7 days);
        }
        if (lastDistributionTime > 0 && block.timestamp < lastDistributionTime + lastDistributionPeriod) {
            revert DistributionInProgress();
        }
        lastDistributedAmount = assets;
        lastDistributionPeriod = period;
        lastDistributionTime = block.timestamp;
        SafeERC20.safeTransferFrom(IERC20(asset()), _msgSender(), address(this), assets);
        emit Distributed(assets, period);
    }

    /// @notice See {IERC4626-maxDeposit}
    function maxDeposit(address receiver) public view virtual override returns (uint256) {
        if (paused()) {
            return 0;
        }
        return super.maxDeposit(receiver);
    }

    /// @notice See {IERC4626-maxMint}
    function maxMint(address receiver) public view virtual override returns (uint256) {
        if (paused()) {
            return 0;
        }
        return super.maxMint(receiver);
    }

    /// @notice See {IERC4626-maxWithdraw}
    function maxWithdraw(address _owner) public view override returns (uint256) {
        return 0;
    }

    /// @notice See {IERC4626-maxRedeem}
    function maxRedeem(address _owner) public view virtual override returns (uint256) {
        return 0;
    }

    /// @notice Returns the maximum amount of shares that can be redeemed by `_owner` in a single order
    function maxRedeemOrder(address _owner) public view virtual returns (uint256) {
        if (paused()) {
            return 0;
        }
        return super.maxRedeem(_owner);
    }

    /// @notice See {IERC4626-previewWithdraw}
    function previewWithdraw(uint256 assets) public view override returns (uint256) {
        (uint256 shares,) = _previewWithdraw(assets);
        return shares;
    }

    /// @notice See {IERC4626-previewRedeem}
    function previewRedeem(uint256 shares) public view override returns (uint256) {
        (uint256 assets,) = _previewRedeem(shares);
        return assets;
    }

    /**
     * @notice Withdraw function is disabled - instant withdrawals are not supported
     * @dev Use initiateRedeem() and finalizeRedeem() for delayed redemptions instead
     */
    function withdraw(uint256, address, address) public pure override returns (uint256) {
        revert WithdrawNotSupported();
    }

    /**
     * @notice Redeem function is disabled - instant redemptions are not supported
     * @dev Use initiateRedeem() and finalizeRedeem() for delayed redemptions instead
     */
    function redeem(uint256, address, address) public pure override returns (uint256) {
        revert RedeemNotSupported();
    }

    /// @notice Initiate a 2-step redemption of `shares`
    // slither-disable-next-line pess-unprotected-initialize
    function initiateRedeem(uint256 shares, address receiver, address _owner) public returns (uint256, uint256) {
        if (receiver == address(0)) {
            revert InvalidZeroAddress();
        }
        uint256 maxShares = maxRedeemOrder(_owner);
        if (shares > maxShares) {
            revert ExceededMaxRedeemOrder(_owner, shares, maxShares);
        }

        (uint256 assets, uint256 fee) = _previewRedeem(shares);
        address caller = _msgSender();
        uint256 orderId = _initiateRedeem(caller, receiver, _owner, assets, shares, fee);

        emit InitiatedRedeem(caller, receiver, _owner, orderId, assets, shares, fee);

        return (orderId, assets);
    }

    /// @notice Initiate a 2-step redemption of `shares` and revert if slippage is exceeded
    // slither-disable-next-line pess-unprotected-initialize
    function initiateRedeemWithSlippage(uint256 shares, address receiver, address _owner, uint256 minAssets)
        external
        returns (uint256, uint256)
    {
        (uint256 orderId, uint256 assets) = initiateRedeem(shares, receiver, _owner);
        if (assets < minAssets) {
            revert WithdrewLessThanMinAssets(assets, minAssets);
        }
        return (orderId, assets);
    }

    /// @notice Finalize a 2-step redemption order by `orderId`
    function finalizeRedeem(uint256 orderId) external {
        address caller = _msgSender();
        Order storage order = orders[orderId];
        if (caller != order.receiver && caller != order.controller) {
            revert UnauthorizedOrderFinalizer(caller, order.receiver, order.controller);
        }
        if (order.status != OrderStatus.Pending) {
            revert OrderNotPending(orderId);
        }
        if (block.timestamp < order.dueTime) {
            revert OrderNotDue(orderId);
        }

        _finalizeRedeem(order);

        emit FinalizedRedeem(caller, order.receiver, order.owner, orderId, order.assets, order.shares);
        emit Withdraw(caller, order.receiver, order.owner, order.assets, order.shares);
    }

    /// @notice Transfer `amount` of `token` held by the vault to `receiver`
    function rescueTokens(address token, address receiver, uint256 amount) external onlyOwner {
        if (token == asset()) {
            revert InvalidAssetRescue(token);
        }
        SafeERC20.safeTransfer(IERC20(token), receiver, amount);
    }

    /// @notice Returns a redeem order by `orderId`
    function getRedeemOrder(uint256 orderId) external view returns (Order memory) {
        return orders[orderId];
    }

    /// @notice Set the redemption delay to `newDelay`
    function setRedeemDelay(uint256 newDelay) external onlyOwner {
        if (newDelay > 365 days) {
            revert RedeemDelayTooHigh(newDelay, 365 days);
        }
        uint256 oldDelay = redeemDelay;
        redeemDelay = newDelay;
        emit UpdatedRedeemDelay(oldDelay, newDelay);
    }

    /// @notice Set the redeem fee to `newFeePpm`
    function setRedeemFee(uint256 newFeePpm) external onlyOwner {
        if (newFeePpm > 1e6) {
            revert FeeTooHigh(newFeePpm, 1e6);
        }
        uint256 oldFeePpm = redeemFeePpm;
        redeemFeePpm = newFeePpm;
        emit UpdatedRedeemFee(oldFeePpm, newFeePpm);
    }

    /// @notice Set the fee receiver to `newFeeReceiver`
    function setFeeReceiver(address newFeeReceiver) external onlyOwner {
        if (newFeeReceiver == address(0)) {
            revert InvalidZeroAddress();
        }
        address oldFeeReceiver = feeReceiver;
        feeReceiver = newFeeReceiver;
        emit UpdatedFeeReceiver(oldFeeReceiver, newFeeReceiver);
    }

    /// @notice Pause all mint and redeem functions
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpause all mint and redeem functions
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice See {IERC20Permit-permit}
    function permit(address _owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        public
    {
        if (block.timestamp > deadline) {
            revert ERC2612ExpiredSignature(deadline);
        }

        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, _owner, spender, value, _useNonce(_owner), deadline));

        bytes32 hash = _hashTypedDataV4(structHash);

        address signer = ECDSA.recover(hash, v, r, s);
        if (signer != _owner) {
            revert ERC2612InvalidSigner(signer, _owner);
        }

        _approve(_owner, spender, value);
    }

    /// @notice See {IERC20Permit-nonces}
    function nonces(address _owner) public view override(IERC20Permit, NoncesUpgradeable) returns (uint256) {
        return super.nonces(_owner);
    }

    /// @notice See {IERC20Permit-DOMAIN_SEPARATOR}
    // solhint-disable-next-line func-name-mixedcase
    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    function _previewWithdraw(uint256 assets) public view returns (uint256, uint256) {
        uint256 fee = _feeOnRaw(assets, redeemFeePpm);
        uint256 shares = super.previewWithdraw(assets + fee);
        return (shares, fee);
    }

    function _previewRedeem(uint256 shares) public view returns (uint256, uint256) {
        uint256 assets = super.previewRedeem(shares);
        uint256 fee = _feeOnTotal(assets, redeemFeePpm);
        return (assets - fee, fee);
    }

    // slither-disable-next-line pess-unprotected-initialize
    function _initiateRedeem(
        address caller,
        address receiver,
        address _owner,
        uint256 assets,
        uint256 shares,
        uint256 fee
    ) internal returns (uint256) {
        totalPendingOrderValue += assets;

        uint256 orderId = orderCount;
        orders[orderId] = Order({
            assets: assets,
            shares: shares,
            owner: _owner,
            receiver: receiver,
            controller: caller,
            dueTime: SafeCast.toUint40(block.timestamp + redeemDelay),
            status: OrderStatus.Pending
        });
        orderCount++;

        if (caller != _owner) {
            _spendAllowance(_owner, caller, shares);
        }
        _burn(_owner, shares);
        SafeERC20.safeTransfer(IERC20(asset()), feeReceiver, fee);

        return orderId;
    }

    function _finalizeRedeem(Order storage order) internal whenNotPaused {
        order.status = OrderStatus.Executed;
        totalPendingOrderValue -= order.assets;
        SafeERC20.safeTransfer(IERC20(asset()), order.receiver, order.assets);
    }

    /// @dev Calculates the fees that should be added to an amount `assets` that does not already include fees
    function _feeOnRaw(uint256 assets, uint256 feePpm) internal pure returns (uint256) {
        return Math.mulDiv(assets, feePpm, 1e6, Math.Rounding.Ceil);
    }

    /// @dev Calculates the fee part of an amount `assets` that already includes fees
    function _feeOnTotal(uint256 assets, uint256 feePpm) internal pure returns (uint256) {
        return Math.mulDiv(assets, feePpm, feePpm + 1e6, Math.Rounding.Ceil);
    }

    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     */
    // slither-disable-next-line unused-state
    uint256[50] private __gap;
}
