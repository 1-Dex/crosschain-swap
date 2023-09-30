// SPDX-License-Identifier: MIT
pragma solidity 0.8.7;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@zetachain/protocol-contracts/contracts/zevm/SystemContract.sol";
import "@zetachain/protocol-contracts/contracts/zevm/interfaces/zContract.sol";
import "@zetachain/protocol-contracts/contracts/evm/Zeta.eth.sol";
import "@zetachain/protocol-contracts/contracts/evm/tools/ZetaInteractor.sol";
import "@zetachain/protocol-contracts/contracts/evm/interfaces/ZetaInterfaces.sol";
import "@zetachain/toolkit/contracts/SwapHelperLib.sol";
import "@zetachain/toolkit/contracts/BytesHelperLib.sol";

interface MultiChainValueErrors {
    error ErrorTransferringZeta();

    error ChainIdAlreadyEnabled();

    error ChainIdNotAvailable();

    error InvalidZetaValueAndGas();
}

contract MultiChainValue is ZetaInteractor, MultiChainValueErrors {
    address public zetaToken;
    // @dev map of valid chains to send Zeta
    mapping(uint256 => bool) public availableChainIds;

    // @dev Constructor calls ZetaInteractor's constructor to setup Connector address and current chain
    constructor(address connectorAddress_, address zetaToken_) ZetaInteractor(connectorAddress_) {
        if (zetaToken_ == address(0)) revert ZetaCommonErrors.InvalidAddress();
        zetaToken = zetaToken_;
    }

    /**
     * @dev Whitelist a chain to send Zeta
     */
    function addAvailableChainId(uint256 destinationChainId) external onlyOwner {
        if (availableChainIds[destinationChainId]) {
            revert ChainIdAlreadyEnabled();
        }

        availableChainIds[destinationChainId] = true;
    }

    /**
     * @dev Blacklist a chain to send Zeta
     */
    function removeAvailableChainId(uint256 destinationChainId) external onlyOwner {
        if (!availableChainIds[destinationChainId]) {
            revert ChainIdNotAvailable();
        }

        delete availableChainIds[destinationChainId];
    }

    /**
     * @dev If the destination chain is a valid chain, send the Zeta tokens to that chain
     */
    function send(uint256 destinationChainId, bytes calldata destinationAddress, uint256 zetaValueAndGas) external {
        if (!availableChainIds[destinationChainId]) {
            revert InvalidDestinationChainId();
        }
        if (zetaValueAndGas == 0) revert InvalidZetaValueAndGas();

        bool success1 = ZetaEth(zetaToken).approve(address(connector), zetaValueAndGas);
        bool success2 = ZetaEth(zetaToken).transferFrom(msg.sender, address(this), zetaValueAndGas);
        if (!(success1 && success2)) revert ErrorTransferringZeta();

        connector.send(
            ZetaInterfaces.SendInput({
                destinationChainId: destinationChainId,
                destinationAddress: destinationAddress,
                destinationGasLimit: 300000,
                message: abi.encode(),
                zetaValueAndGas: zetaValueAndGas,
                zetaParams: abi.encode("")
            })
        );
    }
}

contract Swap is zContract {
    error SenderNotSystemContract();
    error WrongGasContract();
    error NotEnoughToPayGasFee();

    SystemContract public immutable systemContract;
    uint256 constant BITCOIN = 18332;

    constructor(address systemContractAddress) {
        systemContract = SystemContract(systemContractAddress);
    }

    function bytesToBech32Bytes(bytes calldata data, uint256 offset) internal pure returns (bytes memory) {
        bytes memory bech32Bytes = new bytes(42);
        for (uint256 i = 0; i < 42; i++) {
            bech32Bytes[i] = data[i + offset];
        }

        return bech32Bytes;
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
            recipient = bytesToBech32Bytes(message, 4);
        } else {
            (uint32 targetChainID_, bytes32 recipient_, uint256 minAmountOut_) =
                abi.decode(message, (uint32, bytes32, uint256));
            targetChainID = targetChainID_;
            recipient = abi.encodePacked(recipient_);
            minAmountOut = minAmountOut_;
        }

        address targetZRC20 = systemContract.gasCoinZRC20ByChainId(targetChainID);

        uint256 outputAmount = SwapHelperLib._doSwap(
            systemContract.wZetaContractAddress(),
            systemContract.uniswapv2FactoryAddress(),
            systemContract.uniswapv2Router02Address(),
            zrc20,
            amount,
            targetZRC20,
            minAmountOut
        );

        (address gasZRC20, uint256 gasFee) = IZRC20(targetZRC20).withdrawGasFee();

        if (gasZRC20 != targetZRC20) revert WrongGasContract();
        if (gasFee >= outputAmount) revert NotEnoughToPayGasFee();

        IZRC20(targetZRC20).approve(targetZRC20, gasFee);
        IZRC20(targetZRC20).withdraw(recipient, outputAmount - gasFee);
    }
}
