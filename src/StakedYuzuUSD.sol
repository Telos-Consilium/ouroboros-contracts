// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
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
    EIP712Upgradeable,
    NoncesUpgradeable,
    IStakedYuzuUSDDefinitions,
    IERC20Permit
{
    bytes32 private constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    error ERC2612ExpiredSignature(uint256 deadline);
    error ERC2612InvalidSigner(address signer, address owner);

    mapping(uint256 => uint256) public depositedPerBlock;
    mapping(uint256 => uint256) public withdrawnPerBlock;
    uint256 public maxDepositPerBlock;
    uint256 public maxWithdrawPerBlock;

    uint256 public redeemDelay;
    uint256 public redeemFeePpm;

    uint256 public totalPendingOrderValue;

    mapping(uint256 => Order) internal orders;
    uint256 public orderCount;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the StakedYuzuUSD contract
     * @param _asset The underlying ERC-20 token for the vault
     * @param name_ The name of the staked token
     * @param symbol_ The symbol of the staked token
     * @param _owner The owner of the contract
     * @param _maxDepositPerBlock Maximum assets that can be deposited per block
     * @param _maxWithdrawPerBlock Maximum assets that can be withdrawn per block
     * @param _redeemDelay The delay in seconds before a redeem order can be finalized
     */
    function initialize(
        IERC20 _asset,
        string memory name_,
        string memory symbol_,
        address _owner,
        uint256 _maxDepositPerBlock,
        uint256 _maxWithdrawPerBlock,
        uint256 _redeemDelay
    ) external initializer {
        __ERC4626_init(_asset);
        __ERC20_init(name_, symbol_);
        __Ownable_init(_owner);
        __Ownable2Step_init();
        __EIP712_init(name_, "1");

        if (address(_asset) == address(0)) {
            revert InvalidZeroAddress();
        }

        maxDepositPerBlock = _maxDepositPerBlock;
        maxWithdrawPerBlock = _maxWithdrawPerBlock;
        redeemDelay = _redeemDelay;
    }

    /// @notice See {IERC4626-totalAssets}
    function totalAssets() public view override returns (uint256) {
        return super.totalAssets() - totalPendingOrderValue;
    }

    /// @notice See {IERC4626-maxDeposit}
    function maxDeposit(address) public view override returns (uint256) {
        uint256 deposited = depositedPerBlock[block.number];
        if (deposited >= maxDepositPerBlock) return 0;
        return maxDepositPerBlock - deposited;
    }

    /// @notice See {IERC4626-maxMint}
    function maxMint(address receiver) public view override returns (uint256) {
        uint256 _maxDeposit = Math.min(maxDeposit(receiver), type(uint256).max - 10 ** _decimalsOffset());
        return convertToShares(_maxDeposit);
    }

    /// @notice See {IERC4626-maxWithdraw}
    function maxWithdraw(address owner) public view override returns (uint256) {
        uint256 withdrawn = withdrawnPerBlock[block.number];
        if (withdrawn >= maxWithdrawPerBlock) return 0;
        return Math.min(super.maxWithdraw(owner), maxWithdrawPerBlock - withdrawn);
    }

    /// @notice See {IERC4626-maxRedeem}
    function maxRedeem(address owner) public view override returns (uint256) {
        uint256 withdrawn = withdrawnPerBlock[block.number];
        if (withdrawn >= maxWithdrawPerBlock) return 0;

        uint256 inheritedMaxRedeem = super.maxRedeem(owner);
        if (inheritedMaxRedeem == 0) {
            return 0;
        }

        uint256 remainingAllowance = maxWithdrawPerBlock - withdrawn;
        /// @dev If redeeming the inherited max redeem would not exceed the remaining allowance, don't
        /// calculate the asset value of the allowance to prevent a possible overflow in previewWithdraw.
        if (previewRedeem(inheritedMaxRedeem) < remainingAllowance) {
            return inheritedMaxRedeem;
        } else {
            return previewWithdraw(remainingAllowance);
        }
    }

    /// @notice See {IERC4626-previewWithdraw}
    function previewWithdraw(uint256 assets) public view virtual override returns (uint256) {
        uint256 fee = _feeOnRaw(assets, redeemFeePpm);
        return super.previewWithdraw(assets + fee);
    }

    /// @notice See {IERC4626-previewRedeem}
    function previewRedeem(uint256 shares) public view virtual override returns (uint256) {
        uint256 assets = super.previewRedeem(shares);
        return assets - _feeOnTotal(assets, redeemFeePpm);
    }

    /**
     * @notice Withdraw function is disabled - instant withdrawals are not supported
     * @dev Use initiateRedeem() and finalizeRedeem() for delayed redemptions instead
     */
    function withdraw(uint256 assets, address receiver, address owner) public pure override returns (uint256) {
        revert WithdrawNotSupported();
    }

    /**
     * @notice Redeem function is disabled - instant redemptions are not supported
     * @dev Use initiateRedeem() and finalizeRedeem() for delayed redemptions instead
     */
    function redeem(uint256 shares, address receiver, address owner) public pure override returns (uint256) {
        revert RedeemNotSupported();
    }

    /// @notice Initiates a 2-step redemption of `shares`
    // slither-disable-next-line pess-unprotected-initialize
    function initiateRedeem(uint256 shares, address receiver, address owner) external returns (uint256, uint256) {
        if (receiver == address(0)) {
            revert InvalidZeroAddress();
        }
        uint256 maxShares = maxRedeem(owner);
        if (shares > maxShares) {
            revert ERC4626ExceededMaxRedeem(owner, shares, maxShares);
        }

        uint256 assets = previewRedeem(shares);
        address caller = _msgSender();
        uint256 orderId = _initiateRedeem(caller, receiver, owner, assets, shares);

        emit InitiatedRedeem(caller, receiver, owner, orderId, assets, shares);

        return (orderId, assets);
    }

    /// @notice Finalizes a 2-step redemption order by `orderId`
    function finalizeRedeem(uint256 orderId) external {
        Order storage order = orders[orderId];
        if (order.status != OrderStatus.Pending) {
            revert OrderNotPending(orderId);
        }
        if (block.timestamp < order.dueTime) {
            revert OrderNotDue(orderId);
        }

        address caller = _msgSender();
        _finalizeRedeem(order);

        emit FinalizedRedeem(caller, order.receiver, order.owner, orderId, order.assets, order.shares);
        emit Withdraw(caller, order.receiver, order.owner, order.assets, order.shares);
    }

    /// @notice Transfers `amount` of `token` held by the vault to `receiver`
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

    /// @notice Sets the maximum deposit per block to `newMax`
    function setMaxDepositPerBlock(uint256 newMax) external onlyOwner {
        uint256 oldMax = maxDepositPerBlock;
        maxDepositPerBlock = newMax;
        emit UpdatedMaxDepositPerBlock(oldMax, newMax);
    }

    /// @notice Sets the maximum withdrawal per block to `newMax`
    function setMaxWithdrawPerBlock(uint256 newMax) external onlyOwner {
        uint256 oldMax = maxWithdrawPerBlock;
        maxWithdrawPerBlock = newMax;
        emit UpdatedMaxWithdrawPerBlock(oldMax, newMax);
    }

    /// @notice Sets the redemption delay to `newDelay`
    function setRedeemDelay(uint256 newDelay) external onlyOwner {
        if (newDelay > type(uint32).max) {
            revert RedeemDelayTooHigh(newDelay, type(uint32).max);
        }
        uint256 oldDelay = redeemDelay;
        redeemDelay = newDelay;
        emit UpdatedRedeemDelay(oldDelay, newDelay);
    }

    /// @notice Sets the redeem fee to `newFeePpm`
    function setRedeemFee(uint256 newFeePpm) external onlyOwner {
        if (newFeePpm > 1e6) {
            revert FeeTooHigh(newFeePpm, 1e6);
        }
        uint256 oldFeePpm = redeemFeePpm;
        redeemFeePpm = newFeePpm;
        emit UpdatedRedeemFee(oldFeePpm, newFeePpm);
    }

    /// @notice See {IERC20Permit-permit}.
    function permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        public
        virtual
    {
        if (block.timestamp > deadline) {
            revert ERC2612ExpiredSignature(deadline);
        }

        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, _useNonce(owner), deadline));

        bytes32 hash = _hashTypedDataV4(structHash);

        address signer = ECDSA.recover(hash, v, r, s);
        if (signer != owner) {
            revert ERC2612InvalidSigner(signer, owner);
        }

        _approve(owner, spender, value);
    }

    /// @notice See {IERC20Permit-nonces}
    function nonces(address owner) public view virtual override(IERC20Permit, NoncesUpgradeable) returns (uint256) {
        return super.nonces(owner);
    }

    /// @notice See {IERC20Permit-DOMAIN_SEPARATOR}
    // solhint-disable-next-line func-name-mixedcase
    function DOMAIN_SEPARATOR() external view virtual returns (bytes32) {
        return _domainSeparatorV4();
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        depositedPerBlock[block.number] += assets;
        super._deposit(caller, receiver, assets, shares);
    }

    // slither-disable-next-line pess-unprotected-initialize
    function _initiateRedeem(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        returns (uint256)
    {
        withdrawnPerBlock[block.number] += assets;
        totalPendingOrderValue += assets;

        uint256 orderId = orderCount;
        orders[orderId] = Order({
            assets: assets,
            shares: shares,
            owner: owner,
            receiver: receiver,
            dueTime: SafeCast.toUint40(block.timestamp + redeemDelay),
            status: OrderStatus.Pending
        });
        orderCount++;

        if (caller != owner) {
            _spendAllowance(owner, caller, shares);
        }
        _burn(owner, shares);

        return orderId;
    }

    function _finalizeRedeem(Order storage order) internal {
        order.status = OrderStatus.Executed;
        totalPendingOrderValue -= order.assets;
        SafeERC20.safeTransfer(IERC20(asset()), order.receiver, order.assets);
    }

    /// @dev Calculates the fees that should be added to an amount `assets` that does not already include fees.
    function _feeOnRaw(uint256 assets, uint256 feePpm) internal pure returns (uint256) {
        return Math.mulDiv(assets, feePpm, 1e6, Math.Rounding.Ceil);
    }

    /// @dev Calculates the fee part of an amount `assets` that already includes fees.
    function _feeOnTotal(uint256 assets, uint256 feePpm) internal pure returns (uint256) {
        return Math.mulDiv(assets, feePpm, feePpm + 1e6, Math.Rounding.Ceil);
    }

    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     */
    uint256[50] private __gap;
}
