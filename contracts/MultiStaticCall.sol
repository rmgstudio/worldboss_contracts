// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

contract MultiStaticCall {
    function multiStaticCall(
        bytes[] calldata data
    ) external view returns (bool[] memory bools, bytes[] memory results) {
        bools = new bool[](data.length);
        results = new bytes[](data.length);
        for (uint256 i = 0; i < data.length; i++) {
            (bool success, bytes memory result) = address(this).staticcall(data[i]);
            bools[i] = success;
            if (success) results[i] = result;
        }
    }
}
