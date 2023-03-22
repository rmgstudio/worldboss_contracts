// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.0;
import "./OwnableUpgradeable.sol";

abstract contract Pauseable is OwnableUpgradeable {
    event Paused(address account);
    event Unpaused(address account);
    bool public isPausing;
    uint256 public pauseTime;
    uint256 public unpauseTime;
    uint256 internal _pauseDuration;

    modifier whenNotPaused() {
        require(!isPausing, "Pausable: paused");
        _;
    }

    function setPause(bool pause_) external onlyAdmin {
        require(isPausing != pause_);
        isPausing = pause_;
        if (isPausing) {
            pauseTime = block.timestamp;
            emit Paused(address(this));
        } else {
            unpauseTime = block.timestamp;
            _pauseDuration = unpauseTime - pauseTime;
            emit Unpaused(address(this));
        }
    }
}
