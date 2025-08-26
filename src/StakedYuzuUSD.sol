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
     * @param __name The name of the staked token
     * @param __symbol The symbol of the staked token
     * @param _owner The owner of the contract
     * @param _redeemDelay The delay in seconds before a redeem order can be finalized
     */
    // slither-disable-next-line pess-arbitrary-call-destination-tainted
    function initialize(
        IERC20 _asset,
        string memory __name,
        string memory __symbol,
        address _owner,
        uint256 _redeemDelay
    ) external initializer {
        __ERC4626_init(_asset);
        __ERC20_init(__name, __symbol);
        __Ownable_init(_owner);
        __Ownable2Step_init();
        __EIP712_init(__name, "1");

        if (address(_asset) == address(0)) {
            revert InvalidZeroAddress();
        }

        redeemDelay = _redeemDelay;
    }

    /// @notice See {IERC4626-totalAssets}
    function totalAssets() public view override returns (uint256) {
        return super.totalAssets() - totalPendingOrderValue;
    }

    /// @notice See {IERC4626-maxWithdraw}
    function maxWithdraw(address _owner) public view override returns (uint256) {
        return previewRedeem(super.maxRedeem(_owner));
    }

    /// @notice See {IERC4626-previewWithdraw}
    function previewWithdraw(uint256 assets) public view override returns (uint256) {
        uint256 fee = _feeOnRaw(assets, redeemFeePpm);
        return super.previewWithdraw(assets + fee);
    }

    /// @notice See {IERC4626-previewRedeem}
    function previewRedeem(uint256 shares) public view override returns (uint256) {
        uint256 assets = super.previewRedeem(shares);
        return assets - _feeOnTotal(assets, redeemFeePpm);
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

    /// @notice Initiates a 2-step redemption of `shares`
    // slither-disable-next-line pess-unprotected-initialize
    function initiateRedeem(uint256 shares, address receiver, address _owner) external returns (uint256, uint256) {
        if (receiver == address(0)) {
            revert InvalidZeroAddress();
        }
        uint256 maxShares = maxRedeem(_owner);
        if (shares > maxShares) {
            revert ERC4626ExceededMaxRedeem(_owner, shares, maxShares);
        }

        uint256 assets = previewRedeem(shares);
        address caller = _msgSender();
        uint256 orderId = _initiateRedeem(caller, receiver, _owner, assets, shares);

        emit InitiatedRedeem(caller, receiver, _owner, orderId, assets, shares);

        return (orderId, assets);
    }

    /// @notice Finalizes a 2-step redemption order by `orderId`
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

    /// @notice Pauses all minting and redeeming functions
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpauses all minting and redeeming functions
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice See {IERC20Permit-permit}.
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

    // slither-disable-next-line dead-code
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares)
        internal
        override
        whenNotPaused
    {
        super._deposit(caller, receiver, assets, shares);
    }

    // slither-disable-next-line dead-code
    function _withdraw(address caller, address receiver, address _owner, uint256 assets, uint256 shares)
        internal
        virtual
        override
        whenNotPaused
    {
        super._withdraw(caller, receiver, _owner, assets, shares);
    }

    // slither-disable-next-line pess-unprotected-initialize
    function _initiateRedeem(address caller, address receiver, address _owner, uint256 assets, uint256 shares)
        internal
        whenNotPaused
        returns (uint256)
    {
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

        return orderId;
    }

    function _finalizeRedeem(Order storage order) internal whenNotPaused {
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
    // slither-disable-next-line unused-state
    uint256[50] private __gap;
}
