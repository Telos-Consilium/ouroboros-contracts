// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ContextUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IYuzuIssuerDefinitions} from "../interfaces/proto/IYuzuIssuerDefinitions.sol";

abstract contract YuzuIssuer is ContextUpgradeable, IYuzuIssuerDefinitions {
    struct YuzuIssuerStorage {
        uint256 _supplyCap;
    }

    // keccak256(abi.encode(uint256(keccak256("yuzu.storage.issuer")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant YuzuIssuerStorageLocation =
        0x542408f99cbd5a3e32919127cd9d8984eb4635c3ab0f9f17273c636c42e08d00;

    function __YuzuIssuer_init(uint256 _supplyCap) internal onlyInitializing {
        __YuzuIssuer_init_unchained(_supplyCap);
    }

    function __YuzuIssuer_init_unchained(uint256 _supplyCap) internal onlyInitializing {
        YuzuIssuerStorage storage $ = _getYuzuIssuerStorage();
        $._supplyCap = _supplyCap;
    }

    /// @dev See {IERC4626-asset}
    function asset() public view virtual returns (address);

    /// @dev See {IERC20}
    function __yuzu_totalSupply() internal view virtual returns (uint256);
    function __yuzu_balanceOf(address account) internal view virtual returns (uint256);
    function __yuzu_mint(address account, uint256 amount) internal virtual;
    function __yuzu_burn(address account, uint256 amount) internal virtual;

    function __yuzu_spendAllowance(address owner, address spender, uint256 amount) internal virtual;

    function _convertToShares(uint256 assets, Math.Rounding rounding) internal view virtual returns (uint256);
    function _convertToAssets(uint256 shares, Math.Rounding rounding) internal view virtual returns (uint256);

    function treasury() public view virtual returns (address) {
        return address(this);
    }

    /// @notice See {IERC4626-totalAssets}
    function totalAssets() public view virtual returns (uint256) {
        return _convertToAssets(__yuzu_totalSupply(), Math.Rounding.Floor);
    }

    /// @notice See {IERC4626-convertToShares}
    function convertToShares(uint256 assets) public view virtual returns (uint256) {
        return _convertToShares(assets, Math.Rounding.Floor);
    }

    /// @notice See {IERC4626-convertToAssets}
    function convertToAssets(uint256 shares) public view virtual returns (uint256) {
        return _convertToAssets(shares, Math.Rounding.Floor);
    }

    /// @notice See {IERC4626-maxDeposit}
    function maxDeposit(address receiver) public view virtual returns (uint256) {
        return _convertToAssets(maxMint(receiver), Math.Rounding.Floor);
    }

    /// @notice See {IERC4626-maxMint}
    function maxMint(address) public view virtual returns (uint256) {
        return _getRemainingMintAllowance();
    }

    /// @notice See {IERC4626-maxWithdraw}
    function maxWithdraw(address _owner) public view virtual returns (uint256) {
        return Math.min(previewRedeem(_maxRedeem(_owner)), _maxWithdraw(_owner));
    }

    /// @notice See {IERC4626-maxRedeem}
    function maxRedeem(address _owner) public view virtual returns (uint256) {
        return Math.min(_convertToShares(_maxWithdraw(_owner), Math.Rounding.Floor), _maxRedeem(_owner));
    }

    /// @notice See {IERC4626-previewDeposit}
    function previewDeposit(uint256 assets) public view virtual returns (uint256) {
        return _convertToShares(assets, Math.Rounding.Floor);
    }

    /// @notice See {IERC4626-previewMint}
    function previewMint(uint256 tokens) public view virtual returns (uint256) {
        return _convertToAssets(tokens, Math.Rounding.Ceil);
    }

    /// @notice See {IERC4626-previewWithdraw}
    function previewWithdraw(uint256 assets) public view returns (uint256) {
        (uint256 tokens,) = _previewWithdraw(assets);
        return tokens;
    }

    /// @notice See {IERC4626-previewRedeem}
    function previewRedeem(uint256 tokens) public view returns (uint256) {
        (uint256 assets,) = _previewRedeem(tokens);
        return assets;
    }

    /// @notice See {IERC4626-deposit}
    function deposit(uint256 assets, address receiver) public virtual returns (uint256) {
        uint256 maxAssets = maxDeposit(receiver);
        if (assets > maxAssets) {
            revert ExceededMaxDeposit(receiver, assets, maxAssets);
        }

        uint256 tokens = previewDeposit(assets);
        _deposit(_msgSender(), receiver, assets, tokens);

        return tokens;
    }

    /// @notice See {IERC4626-mint}
    function mint(uint256 tokens, address receiver) public virtual returns (uint256) {
        uint256 maxTokens = maxMint(receiver);
        if (tokens > maxTokens) {
            revert ExceededMaxMint(receiver, tokens, maxTokens);
        }

        uint256 assets = previewMint(tokens);
        _deposit(_msgSender(), receiver, assets, tokens);

        return assets;
    }

    /// @notice See {IERC4626-withdraw}
    function withdraw(uint256 assets, address receiver, address owner) public virtual returns (uint256) {
        uint256 maxAssets = maxWithdraw(owner);
        if (assets > maxAssets) {
            revert ExceededMaxWithdraw(owner, assets, maxAssets);
        }

        (uint256 tokens, uint256 fee) = _previewWithdraw(assets);
        _withdraw(_msgSender(), receiver, owner, assets, tokens, fee);

        return tokens;
    }

    /// @notice Withdraw assets and revert if slippage is exceeded
    function withdrawWithSlippage(uint256 assets, address receiver, address owner, uint256 maxTokens)
        public
        returns (uint256)
    {
        uint256 tokens = withdraw(assets, receiver, owner);
        if (tokens > maxTokens) {
            revert RedeemedMoreThanMaxTokens(tokens, maxTokens);
        }
        return tokens;
    }

    /// @notice See {IERC4626-redeem}
    function redeem(uint256 tokens, address receiver, address owner) public virtual returns (uint256) {
        uint256 maxTokens = maxRedeem(owner);
        if (tokens > maxTokens) {
            revert ExceededMaxRedeem(owner, tokens, maxTokens);
        }

        (uint256 assets, uint256 fee) = _previewRedeem(tokens);
        _withdraw(_msgSender(), receiver, owner, assets, tokens, fee);

        return assets;
    }

    /// @notice Redeem tokens and revert if slippage is exceeded
    function redeemWithSlippage(uint256 tokens, address receiver, address owner, uint256 minAssets)
        public
        virtual
        returns (uint256)
    {
        uint256 assets = redeem(tokens, receiver, owner);
        if (assets < minAssets) {
            revert WithdrewLessThanMinAssets(assets, minAssets);
        }
        return assets;
    }

    function withdrawCollateral(uint256 assets, address receiver) public virtual {
        uint256 liquidityBuffer = liquidityBufferSize();
        if (assets == type(uint256).max) {
            assets = liquidityBuffer;
        } else if (assets > liquidityBuffer) {
            revert ExceededLiquidityBuffer(assets, liquidityBuffer);
        }
        SafeERC20.safeTransfer(IERC20(asset()), receiver, assets);
        emit WithdrawnCollateral(receiver, assets);
    }

    function cap() public view returns (uint256) {
        YuzuIssuerStorage storage $ = _getYuzuIssuerStorage();
        return $._supplyCap;
    }

    function liquidityBufferSize() public view virtual returns (uint256) {
        return IERC20(asset()).balanceOf(address(this));
    }

    function _maxWithdraw(address) internal view virtual returns (uint256) {
        return liquidityBufferSize();
    }

    function _maxRedeem(address owner) internal view virtual returns (uint256) {
        return __yuzu_balanceOf(owner);
    }

    function _previewWithdraw(uint256 assets) internal view virtual returns (uint256, uint256) {
        return (_convertToShares(assets, Math.Rounding.Ceil), 0);
    }

    function _previewRedeem(uint256 tokens) internal view virtual returns (uint256, uint256) {
        return (_convertToAssets(tokens, Math.Rounding.Floor), 0);
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 tokens) internal virtual {
        SafeERC20.safeTransferFrom(IERC20(asset()), caller, treasury(), assets);
        __yuzu_mint(receiver, tokens);
        emit Deposit(caller, receiver, assets, tokens);
    }

    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 tokens, uint256 fee)
        internal
        virtual
    {
        if (caller != owner) {
            __yuzu_spendAllowance(owner, caller, tokens);
        }
        __yuzu_burn(owner, tokens);

        SafeERC20.safeTransfer(IERC20(asset()), receiver, assets);

        emit Withdraw(caller, receiver, owner, assets, tokens);
    }

    function _getRemainingMintAllowance() internal view virtual returns (uint256) {
        uint256 supplyCap = cap();
        uint256 totalSupply = __yuzu_totalSupply();
        if (totalSupply >= supplyCap) {
            return 0;
        }
        return supplyCap - totalSupply;
    }

    function _getYuzuIssuerStorage() private pure returns (YuzuIssuerStorage storage $) {
        // slither-disable-next-line assembly
        assembly {
            $.slot := YuzuIssuerStorageLocation
        }
    }

    function _setSupplyCap(uint256 newCap) internal {
        YuzuIssuerStorage storage $ = _getYuzuIssuerStorage();
        uint256 oldCap = $._supplyCap;
        $._supplyCap = newCap;
        emit UpdatedSupplyCap(oldCap, newCap);
    }
}
