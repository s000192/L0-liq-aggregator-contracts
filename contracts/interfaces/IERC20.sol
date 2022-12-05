// SPDX-License-Identifier: MIT

pragma solidity ^0.8.17;

// Minimal ERC20 interface.
interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
}
