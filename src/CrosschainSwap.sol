// SPDX-License-Identifier: MIT
pragma solidity 0.8.7;

import "@zetachain/protocol-contracts/contracts/zevm/SystemContract.sol";
import "@zetachain/protocol-contracts/contracts/zevm/interfaces/zContract.sol";
import "@zetachain/toolkit/contracts/SwapHelperLib.sol";
import "@zetachain/toolkit/contracts/BytesHelperLib.sol";

contract Swap is zContract {
    error SenderNotSystemContract();
    error WrongGasContract();
    error NotEnoughToPayGasFee();

    SystemContract public immutable systemContract;
    address public targetZRC20;
    uint256 constant BITCOIN = 18332;
    uint256 constant ZETACHAIN = 7001;

    constructor(address systemContractAddress) {
        systemContract = SystemContract(systemContractAddress);
    }

    function onCrossChainCall(zContext calldata context, address zrc20, uint256 amount, bytes calldata message)
        external
        virtual
        override
    {
        if (msg.sender != address(systemContract)) {
            revert SenderNotSystemContract();
        }

        uint32 targetChainID;
        bytes memory recipient;
        uint256 minAmountOut;

        if (context.chainID == BITCOIN) {
            targetChainID = BytesHelperLib.bytesToUint32(message, 0);
            recipient = BytesHelperLib.bytesToBech32Bytes(message, 4);
        } else {
            (uint32 targetChainID_, bytes32 recipient_, uint256 minAmountOut_) =
                abi.decode(message, (uint32, bytes32, uint256));
            targetChainID = targetChainID_;
            recipient = abi.encodePacked(recipient_);
            minAmountOut = minAmountOut_;
        }

        if (targetChainID == ZETACHAIN) {
            targetZRC20 = 0x5F0b1a82749cb4E2278EC87F8BF6B618dC71a8bf;
        } else {
            targetZRC20 = systemContract.gasCoinZRC20ByChainId(targetChainID);
        }

        uint256 outputAmount = SwapHelperLib._doSwap(
            systemContract.wZetaContractAddress(),
            systemContract.uniswapv2FactoryAddress(),
            systemContract.uniswapv2Router02Address(),
            zrc20,
            amount,
            targetZRC20,
            minAmountOut
        );

        if (targetChainID == ZETACHAIN) {
            address recipientAddr = BytesHelperLib.bytesToAddress(context.origin, 0);
            (, uint256 gasFee) = IZRC20(zrc20).withdrawGasFee();
            IWETH9(targetZRC20).approve(targetZRC20, gasFee);
            IWETH9(targetZRC20).transfer(recipientAddr, outputAmount - gasFee);
        } else {
            (address gasZRC20, uint256 gasFee) = IZRC20(targetZRC20).withdrawGasFee();

            if (gasZRC20 != targetZRC20) revert WrongGasContract();
            if (gasFee >= outputAmount) revert NotEnoughToPayGasFee();

            IZRC20(targetZRC20).approve(targetZRC20, gasFee);
            IZRC20(targetZRC20).withdraw(recipient, outputAmount - gasFee);
        }
    }
}

interface IWETH9 {
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Deposit(address indexed dst, uint256 wad);
    event Withdrawal(address indexed src, uint256 wad);

    function totalSupply() external view returns (uint256);

    function balanceOf(address owner) external view returns (uint256);

    function allowance(address owner, address spender) external view returns (uint256);

    function approve(address spender, uint256 wad) external returns (bool);

    function transfer(address to, uint256 wad) external returns (bool);

    function transferFrom(address from, address to, uint256 wad) external returns (bool);

    function deposit() external payable;

    function withdraw(uint256 wad) external;
}
