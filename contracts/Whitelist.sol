// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import "./OwnableUpgradeable.sol";

abstract contract Whitelist is OwnableUpgradeable {
    struct MerkleParam {
        uint256 index;
        uint256 limit;
        bytes32[] merkleProof;
    }

    bytes32 public merkle_root;
    bool public is_on;

    modifier onlyWhitlist(MerkleParam calldata merkleParam) {
        require(inWhitelist(msg.sender, merkleParam), "not in whitelist");
        _;
    }

    function inWhitelist(
        address user,
        MerkleParam calldata merkleParam
    ) public view returns (bool) {
        if (!is_on) return true;
        bytes32 leaf = keccak256(abi.encodePacked(merkleParam.index, user, merkleParam.limit));
        return MerkleProof.verify(merkleParam.merkleProof, merkle_root, leaf);
    }

    function setWhitelistMerkleRoot(bytes32 merkle_root_) public onlyAdmin {
        merkle_root = merkle_root_;
    }

    function setWhitelistIsOn(bool value) public onlyAdmin {
        is_on = value;
    }
}
