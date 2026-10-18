// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC721Lite} from "./base/ERC721Lite.sol";
import {Encoding} from "./libs/Encoding.sol";
import {IArtHouse} from "./interfaces/Interfaces.sol";

/// @notice A plain SVG collection: ERC-721 + ERC-2981 runtime copy, minted only by ArtHouse, with on-chain base64 JSON metadata.
contract ArtCollection is ERC721Lite {
    IArtHouse public house;

    error AlreadyInitialized();
    error NotHouse();

    constructor() {
        // Lock the implementation itself: only independent runtime copies can be initialised.
        house = IArtHouse(address(this));
    }

    function initialize(address house_, string calldata name_, string calldata symbol_) external {
        if (address(house) != address(0)) revert AlreadyInitialized();
        if (msg.sender != house_ || house_.code.length == 0) revert NotHouse();
        house = IArtHouse(house_);
        _name = name_;
        _symbol = symbol_;
    }

    function mint(address to, uint256 tokenId) external {
        if (msg.sender != address(house)) revert NotHouse();
        _mint(to, tokenId);
    }

    function royaltyInfo(uint256, uint256 salePrice) external view returns (address, uint256) {
        return house.royaltyFor(address(this), salePrice);
    }

    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return interfaceId == 0x2a55205a || super.supportsInterface(interfaceId);
    }

    function tokenURI(uint256 tokenId) external view returns (string memory) {
        ownerOf(tokenId);
        (string memory title, string memory description, bytes memory svg) = house.pieceMetadata(address(this), tokenId);
        bytes memory json = abi.encodePacked(
            '{"name":"',
            title,
            '","description":"',
            description,
            '","image":"data:image/svg+xml;base64,',
            Encoding.base64(svg),
            '"}'
        );
        return string.concat("data:application/json;base64,", Encoding.base64(json));
    }
}
