// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {SeatLease} from "../../src/SeatLease.sol";
import {SeatHolder} from "../../src/SeatHolder.sol";

/// @dev ERC-20 that charges a fee on every transfer so received amounts differ from requested amounts.
contract FeeOnTransferToken is ERC20 {
    uint256 public constant FEE_BPS = 100; // 1%

    constructor() ERC20("Fee", "FEE") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 fee = (value * FEE_BPS) / 10_000;
            super._update(from, address(0xFEE), fee);
            value -= fee;
        }
        super._update(from, to, value);
    }
}

/// @dev ERC-20 whose `transfer` behaviour to a given recipient can be tuned to exercise every branch of the bond
///      push in SeatLease: revert, return false, return short data, or return nothing.
contract TunableToken is ERC20 {
    enum Behaviour {
        Normal,
        Revert,
        ReturnFalse,
        ReturnShort,
        ReturnNothing
    }

    mapping(address => Behaviour) public behaviour;
    /// @dev anyone may burn from anyone; used to make a booked balance decrease during claim().
    bool public openBurn = true;

    constructor() ERC20("Tunable", "TUNE") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setBehaviour(address to, Behaviour b) external {
        behaviour[to] = b;
    }

    function burnFrom(address from, uint256 amount) external {
        require(openBurn, "closed");
        _burn(from, amount);
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        Behaviour b = behaviour[to];
        if (b == Behaviour.Revert) revert("blocked");
        if (b == Behaviour.ReturnFalse) return false;
        _transfer(msg.sender, to, amount);
        if (b == Behaviour.ReturnShort) {
            assembly {
                mstore(0, 1)
                return(0, 1)
            }
        }
        if (b == Behaviour.ReturnNothing) {
            assembly {
                return(0, 0)
            }
        }
        return true;
    }
}

/// @dev ERC-20 whose `transferFrom` reports success but moves nothing.
contract ZeroMoveToken is ERC20 {
    constructor() ERC20("Zero", "ZERO") {}

    function transferFrom(address, address, uint256) public pure override returns (bool) {
        return true;
    }
}

/// @dev ERC-20 that calls back into SeatLease from `transferFrom`, to probe reentrancy through the bond pull.
contract ReentrantBondToken is ERC20 {
    SeatLease public lease;
    uint256 public tokenId;
    bool public armed;

    constructor() ERC20("Reentrant", "RE") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function arm(SeatLease lease_, uint256 tokenId_) external {
        lease = lease_;
        tokenId = tokenId_;
        armed = true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (armed) {
            armed = false;
            lease.take(tokenId);
        }
        return super.transferFrom(from, to, amount);
    }
}

/// @dev A contract that refuses ETH.
contract EthRejecter {
    receive() external payable {
        revert("no eth");
    }
}

/// @dev Sweep recipient that reenters `sweep` when paid in ETH and records whether the inner call succeeded.
contract ReentrantSweeper {
    SeatLease public lease;
    uint256 public tokenId;
    bool public reentered;
    bool public innerOk;

    constructor(SeatLease lease_, uint256 tokenId_) {
        lease = lease_;
        tokenId = tokenId_;
    }

    receive() external payable {
        if (!reentered) {
            reentered = true;
            (innerOk,) = address(lease).call(abi.encodeCall(SeatLease.sweep, (tokenId, address(0))));
        }
    }
}

/// @dev Distributor that reenters the registry with arbitrary calldata when claimed from (by a seat's holder).
contract ReentrantDistributor {
    address public immutable registry;
    bytes public payload;

    constructor(address registry_) {
        registry = registry_;
    }

    function setPayload(bytes calldata p) external {
        payload = p;
    }

    function claim() external {
        (bool ok, bytes memory ret) = registry.call(payload);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
    }
}

/// @dev Helper that moves a token out of the registry through a malicious NFT, to exercise the post-claim guard.
contract Thief {
    function steal(EvilNFT nft, uint256 tokenId, address to) external {
        nft.forceTransfer(tokenId, to);
    }
}

/// @dev Non-token claim target that burns a token balance held by its caller, to make a listed balance decrease.
contract Burner {
    function burn(TunableToken token, uint256 amount) external {
        token.burnFrom(msg.sender, amount);
    }
}

/// @dev Non-token claim target that pays a fixed reward but also answers `balanceOf`, like a token would.
contract BalanceOfAnswerer {
    function balanceOf(address) external pure returns (uint256) {
        return 0;
    }

    function claim() external {}
}

/// @dev Distributor keyed by account and callable by anyone, like a Merkle distributor: pays `account`, not the caller.
contract ClaimForDistributor {
    ERC20 public immutable token;

    constructor(ERC20 token_) {
        token = token_;
    }

    receive() external payable {}

    function claimFor(address account, uint256 tokenAmount, uint256 ethAmount) external {
        if (tokenAmount != 0) token.transfer(account, tokenAmount);
        if (ethAmount != 0) {
            (bool ok,) = account.call{value: ethAmount}("");
            require(ok, "eth payout failed");
        }
    }
}

/// @dev Distributor with a recipient parameter: whoever calls picks where the reward goes.
contract ClaimToDistributor {
    ERC20 public immutable token;

    constructor(ERC20 token_) {
        token = token_;
    }

    function claimTo(address to, uint256 amount) external {
        token.transfer(to, amount);
    }
}

/// @dev Contract wallet with no `onERC721Received`: it can hold a seat it was minted or plainly transferred, but a
///      `safeTransferFrom` to it reverts.
contract PlainWallet {
    function exec(address target, bytes calldata data) external returns (bytes memory) {
        (bool ok, bytes memory ret) = target.call(data);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
        return ret;
    }
}

/// @dev Stands in for the registry to drive a holder directly. It cannot receive ETH.
contract HolderDriver {
    SeatHolder public immutable holder;

    constructor(IERC721 nft, uint256 tokenId) {
        holder = new SeatHolder(nft, tokenId);
    }

    function release(address token, uint256 amount) external {
        holder.release(token, amount);
    }
}

/// @dev ETH recipient that burns every unit of gas it is given.
contract GasBurner {
    receive() external payable {
        while (true) {}
    }
}

/// @dev Distributor that just pays ETH.
contract EthPayer {
    receive() external payable {}

    function pay(uint256 amount) external {
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "pay failed");
    }
}

/// @dev Minimal ERC-721-like contract with switchable misbehaviour, used as the seat NFT of a separate registry.
contract EvilNFT {
    enum Behaviour {
        Normal,
        WrongTokenIdHook,
        KeepOwnership,
        HookFromStranger
    }

    mapping(uint256 => address) private _owners;
    Behaviour public behaviour;
    Stranger public stranger;

    constructor() {
        stranger = new Stranger();
    }

    function setBehaviour(Behaviour b) external {
        behaviour = b;
    }

    function mint(address to, uint256 tokenId) external {
        _owners[tokenId] = to;
    }

    function ownerOf(uint256 tokenId) external view returns (address) {
        return _owners[tokenId];
    }

    function forceTransfer(uint256 tokenId, address to) external {
        _owners[tokenId] = to;
    }

    function safeTransferFrom(address from, address to, uint256 tokenId) external {
        require(_owners[tokenId] == from, "not owner");
        if (behaviour == Behaviour.HookFromStranger) {
            stranger.hook(to, from, tokenId);
            return;
        }
        if (behaviour != Behaviour.KeepOwnership) _owners[tokenId] = to;
        uint256 hookId = behaviour == Behaviour.WrongTokenIdHook ? tokenId + 1 : tokenId;
        if (to.code.length != 0) {
            bytes4 sel = IERC721Receiver(to).onERC721Received(msg.sender, from, hookId, "");
            require(sel == IERC721Receiver.onERC721Received.selector, "bad receiver");
        }
    }
}

/// @dev Calls the registry's receiver hook from an address that is not the seat NFT.
contract Stranger {
    function hook(address to, address from, uint256 tokenId) external {
        IERC721Receiver(to).onERC721Received(msg.sender, from, tokenId, "");
    }
}
