// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title LaunchToken
/// @notice Fixed-supply ERC20 for a single launched coin. The entire supply is minted once, at
/// construction, to the coin's bonding curve. There is no owner and no way to mint, burn, pause,
/// block or tax transfers, so every coin from the factory behaves identically.
contract LaunchToken is ERC20 {
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 ether;

    constructor(string memory name_, string memory symbol_, address curve) ERC20(name_, symbol_) {
        _mint(curve, TOTAL_SUPPLY);
    }
}
