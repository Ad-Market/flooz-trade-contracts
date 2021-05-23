pragma solidity 0.7.6;

// SPDX-License-Identifier: LGPL-3.0-or-newer
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract ERC20Mintable is ERC20 {
    constructor(string memory name, string memory symbol) public ERC20(symbol, name) {}

    function mint(address account, uint256 amount) public {
        _mint(account, amount);
    }
}
