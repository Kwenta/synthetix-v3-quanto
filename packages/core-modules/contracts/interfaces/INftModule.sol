//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@synthetixio/core-contracts/contracts/interfaces/IERC721Enumerable.sol";

/// @title NFT token identifying an Account
interface INftModule is IERC721Enumerable {
    /// @notice Returns if `initialize` has been called by the owner
    function isInitialized() external returns (bool);

    /// @notice Allows owner to initialize the token after attaching a proxy
    function initialize(
        string memory tokenName,
        string memory tokenSymbol,
        string memory uri
    ) external;
}