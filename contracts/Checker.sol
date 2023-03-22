// SPDX-License-Identifier: CC0-1.0

pragma solidity ^0.8.0;

abstract contract Checker {

    modifier onlyEOA() {
        require(msg.sender.code.length == 0, "only EOA");
        _;
    }
}
