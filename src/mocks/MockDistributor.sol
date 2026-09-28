// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Stand-in for a per-launch reward distributor that pays `msg.sender`, the seat holder.
/// @dev `claim()` pays whatever `reward` and `rewardEth` were configured for the caller, once.
contract MockDistributor {
    using SafeERC20 for IERC20;

    IERC20 public immutable token;
    mapping(address account => uint256 amount) public reward;
    mapping(address account => uint256 amount) public rewardEth;

    event Paid(address indexed to, uint256 tokenAmount, uint256 ethAmount);

    constructor(address token_) {
        token = IERC20(token_);
    }

    /// @notice Fund the distributor's ETH pot.
    receive() external payable {}

    /// @notice Set what `account` will receive on its next `claim()`.
    function setReward(address account, uint256 tokenAmount, uint256 ethAmount) external {
        reward[account] = tokenAmount;
        rewardEth[account] = ethAmount;
    }

    /// @notice Pay the caller its configured reward.
    function claim() external {
        uint256 tokenAmount = reward[msg.sender];
        uint256 ethAmount = rewardEth[msg.sender];
        reward[msg.sender] = 0;
        rewardEth[msg.sender] = 0;
        if (tokenAmount != 0) token.safeTransfer(msg.sender, tokenAmount);
        if (ethAmount != 0) {
            (bool ok,) = msg.sender.call{value: ethAmount}("");
            require(ok, "eth payout failed");
        }
        emit Paid(msg.sender, tokenAmount, ethAmount);
    }
}
