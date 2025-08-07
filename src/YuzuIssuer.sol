// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {ContextUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from  "@openzeppelin/contracts/utils/math/Math.sol";

abstract contract YuzuIssuer is ContextUpgradeable {
    error ExceededMaxDeposit(address receiver, uint256 assets, uint256 max);
    error ExceededMaxMint(address receiver, uint256 token, uint256 max);
    error ExceededMaxWithdraw(address owner, uint256 assets, uint256 max);
    error ExceededMaxRedeem(address owner, uint256 token, uint256 max);

    event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 token);

    event Withdraw(
        address indexed sender,
        address indexed receiver,
        address indexed owner,
        uint256 assets,
        uint256 token
    );

    function asset() public view virtual returns (address);
    
    function previewDeposit(uint256 assets) public view virtual returns (uint256 tokens);
    function previewMint(uint256 tokens) public view virtual returns (uint256 assets);
    function previewWithdraw(uint256 assets) public view virtual returns (uint256 tokens);
    function previewRedeem(uint256 tokens) public view virtual returns (uint256 assets);

    function __YuzuIssuer_token_balanceOf(address account) internal view virtual returns (uint256 balance);
    function __YuzuIssuer_token_mint(address account, uint256 amount) internal virtual;
    function __YuzuIssuer_token_burnFrom(address account, uint256 value) internal virtual;

    function treasury() public view virtual returns (address) {
        return address(this);
    }

    function maxDeposit(address) public view virtual returns (uint256) {
        return type(uint256).max;
    }

    function maxMint(address) public view virtual returns (uint256) {
        return type(uint256).max;
    }

    function maxWithdraw(address owner) public view virtual returns (uint256) {
        return Math.min(
            previewRedeem(__YuzuIssuer_token_balanceOf(owner)),
            _getLiquidityBufferSize()
        );
    }

    function maxRedeem(address owner) public view virtual returns (uint256) {
        return Math.min(
            __YuzuIssuer_token_balanceOf(owner),
            previewWithdraw(_getLiquidityBufferSize())
        );
    }

    function deposit(uint256 assets, address receiver) public virtual returns (uint256) {
        uint256 maxAssets = maxDeposit(receiver);
        if (assets > maxAssets) {
            revert ExceededMaxDeposit(receiver, assets, maxAssets);
        }

        uint256 tokens = previewDeposit(assets);
        _deposit(_msgSender(), receiver, assets, tokens);

        return tokens;
    }

    function mint(uint256 tokens, address receiver) public virtual returns (uint256) {
        uint256 maxTokens = maxMint(receiver);
        if (tokens > maxTokens) {
            revert ExceededMaxMint(receiver, tokens, maxTokens);
        }

        uint256 assets = previewMint(tokens);
        _deposit(_msgSender(), receiver, assets, tokens);

        return assets;
    }

    function withdraw(uint256 assets, address receiver, address owner) public virtual returns (uint256) {
        uint256 maxAssets = maxWithdraw(owner);
        if (assets > maxAssets) {
            revert ExceededMaxWithdraw(owner, assets, maxAssets);
        }

        uint256 tokens = previewWithdraw(assets);
        _withdraw(_msgSender(), receiver, owner, assets, tokens);

        return tokens;
    }

    function redeem(uint256 tokens, address receiver, address owner) public virtual returns (uint256) {
        uint256 maxTokens = maxRedeem(owner);
        if (tokens > maxTokens) {
            revert ExceededMaxRedeem(owner, tokens, maxTokens);
        }

        uint256 assets = previewRedeem(tokens);
        _withdraw(_msgSender(), receiver, owner, assets, tokens);

        return assets;
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 tokens) internal virtual {
        // If asset() is ERC-777, `transferFrom` can trigger a reentrancy BEFORE the transfer happens through the
        // `tokensToSend` hook. On the other hand, the `tokenReceived` hook, that is triggered after the transfer,
        // calls the vault, which is assumed not malicious.
        //
        // Conclusion: we need to do the transfer before we mint so that any reentrancy would happen before the
        // assets are transferred and before the tokens are minted, which is a valid state.
        // slither-disable-next-line reentrancy-no-eth
        SafeERC20.safeTransferFrom(IERC20(asset()), caller, treasury(), assets);
        __YuzuIssuer_token_mint(receiver, tokens);

        emit Deposit(caller, receiver, assets, tokens);
    }

    function _withdraw(
        address caller,
        address receiver,
        address owner,
        uint256 assets,
        uint256 tokens
    ) internal virtual {
        // If asset() is ERC-777, `transfer` can trigger a reentrancy AFTER the transfer happens through the
        // `tokensReceived` hook. On the other hand, the `tokensToSend` hook, that is triggered before the transfer,
        // calls the vault, which is assumed not malicious.
        //
        // Conclusion: we need to do the transfer after the burn so that any reentrancy would happen after the
        // tokens are burned and after the assets are transferred, which is a valid state.
        __YuzuIssuer_token_burnFrom(owner, tokens);
        SafeERC20.safeTransfer(IERC20(asset()), receiver, assets);

        emit Withdraw(caller, receiver, owner, assets, tokens);
    }

    function _getLiquidityBufferSize() internal view virtual returns (uint256) {
        return IERC20(asset()).balanceOf(address(this));
    }
}
