// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

import {IERC20} from "@uniswap/v2-core/contracts/interfaces/IERC20.sol";
import {ILogAutomation, Log} from "@chainlink/contracts/src/v0.8/automation/interfaces/ILogAutomation.sol";
import {StreamsLookupCompatibleInterface} from "@chainlink/contracts/src/v0.8/automation/interfaces/StreamsLookupCompatibleInterface.sol";
import {ISwapRouter} from "./interfaces/ISwapRouter.sol";
import {IVerifierProxy} from "./interfaces/IVerifierProxy.sol";

/**
 * @title DataStreamsConsumer
 * @dev This contract is a Chainlink Data Streams consumer.
 * This contract provides low-latency delivery of low-latency delivery of market data.
 * These reports can be verified onchain to verify their integrity.
 */
contract DataStreamsConsumer is
    ILogAutomation,
    StreamsLookupCompatibleInterface
{
    // ================================================================
    // |                        CONSTANTS                             |
    // ================================================================

    string public constant STRING_DATASTREAMS_FEEDLABEL = "feedIDs";
    string public constant STRING_DATASTREAMS_QUERYLABEL = "timestamp";
    uint24 public constant FEE = 3000;

    // ================================================================
    // |                            STATE                             |
    // ================================================================

    string[] public s_feedsHex;

    // ================================================================
    // |                         IMMUTABLES                           |
    // ================================================================

    address public i_linkToken;
    ISwapRouter public i_router;
    IVerifierProxy public i_verifier;

    // ================================================================
    // |                         STRUCTS                              |
    // ================================================================

    struct Report {
        bytes32 feedId;
        uint32 lowerTimestamp;
        uint32 observationsTimestamp;
        uint192 nativeFee;
        uint192 linkFee;
        uint64 upperTimestamp;
        int192 benchmark;
    }

    struct TradeParamsStruct {
        address recipient;
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        string feedId;
    }

    struct Quote {
        address quoteAddress;
    }

    // ================================================================
    // |                          Events                              |
    // ================================================================

    event InitiateTrade(
        address msgSender,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        string feedId
    );

    event TradeExecuted(uint256 tokensAmount);

    // ================================================================
    // |                          Errors                              |
    // ================================================================

    error InvalidFeedId(string feedId);

    /**
     * @dev Initializes the contract with necessary parameters.
     * @param router The address of the swap router contract.
     * @param verifier The address of the verifier contract.
     * @param linkToken The address of the LINK token contract.
     * @param feedsHex An array of hexadecimal feed IDs.
     */

    function initializer(
        address router,
        address payable verifier,
        address linkToken,
        string[] memory feedsHex
    ) public {
        i_router = ISwapRouter(router);
        i_verifier = IVerifierProxy(verifier);
        i_linkToken = linkToken;
        s_feedsHex = feedsHex;
    }

    // ================================================================
    // |                        Chainlink DON                          |
    // ================================================================

    /**
     * @dev Initiates a trade by emitting a InitiateTrade event.
     * When emitted Data Streams will trigger the checkLog function
     * indicating that the network should initiate a trade.
     * @param tokenIn The input token address.
     * @param tokenOut The output token address.
     * @param amount The amount to trade.
     * @param feedId data feed of the id you are trading
     */
    function trade(
        address tokenIn,
        address tokenOut,
        uint256 amount,
        string memory feedId
    ) external {
        emit InitiateTrade(msg.sender, tokenIn, tokenOut, amount, feedId);
    }

    /**
     * @dev Checks the log data using Chainlink Data Streams via the StreamsLookup error.
     * Note: To be compatible with CCIP EIP the log function must return in such format as StreamLookup error.
     * Once StreamsLookUp error is emitted the data in the error is passed
     * to the checkCallback function. Which afterwards executes performUpkeep.
     * @param log The log data to be checked.
     * @return A boolean indicating if performUpkeep is needed.
     */

    function checkLog(
        Log calldata log,
        bytes memory
    ) external view returns (bool, bytes memory) {
        revert StreamsLookup(
            STRING_DATASTREAMS_FEEDLABEL,
            s_feedsHex,
            STRING_DATASTREAMS_QUERYLABEL,
            log.timestamp,
            log.data
        );
    }

    /**
     * @dev Checks if upkeep is needed and returns the corresponding performData.
     * @param values An array of values for the upkeep check.
     * @param extraData Additional data for the upkeep.
     * @return upkeepNeeded A boolean indicating whether upkeep is needed
     * @return performData Bytes that include the signed reports and the extra data
     * that is passed in StreamsLookup error.
     */
    function checkCallback(
        bytes[] memory values,
        bytes memory extraData
    ) external pure returns (bool upkeepNeeded, bytes memory performData) {
        return (true, abi.encode(values, extraData));
    }

    /**
     * @dev 1. Decodes the report and extraData.
     * 2. Verifies the integrity of the data.
     * 3. Performs a swap between tokens using the verified report data.
     * This function is executed by Chainlink's Automation Registry.
     * @notice This contract needs to have the networks native token to verify the report.
     * @param performData The data needed to perform the upkeep.
     */
    function performUpkeep(bytes calldata performData) external {
        (
            Report memory unverifiedReport,
            TradeParamsStruct memory tradeParams,
            bytes memory bundledReport
        ) = _decodeData(performData);

        // verify tokens
        bytes memory verifiedReportData = i_verifier.verify{
            value: unverifiedReport.nativeFee
        }(bundledReport, abi.encode(i_linkToken));
        Report memory verifiedReport = abi.decode(verifiedReportData, (Report));

        // swap tokens
        uint256 successfullyTradedTokens = _swapTokens(
            verifiedReport,
            tradeParams
        );
        emit TradeExecuted(successfullyTradedTokens);
    }

    // ================================================================
    // |                    REPORT MANIPULATION                       |
    // ================================================================

    /**
     * @dev Decodes and extracts relevant data from the provided `performData`.
     * It decodes the `performData` into signed reports, swap parameters,
     * and a bundled report.
     * @param performData The data needed for the decoding process.
     * @return signedReport The decoded report from the bundled report data.
     * @return tradeParams The decoded swap parameters.
     * @return bundledReport The bundled report data for verification.
     */
    function _decodeData(
        bytes memory performData
    )
        private
        view
        returns (
            Report memory signedReport,
            TradeParamsStruct memory tradeParams,
            bytes memory bundledReport
        )
    {
        (bytes[] memory signedReports, bytes memory extraData) = abi.decode(
            performData,
            (bytes[], bytes)
        );

        (
            address sender,
            address tokenIn,
            address tokenOut,
            uint256 amountIn,
            string memory feedId
        ) = abi.decode(extraData, (address, address, address, uint256, string));

        tradeParams = TradeParamsStruct({
            recipient: sender,
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            amountIn: amountIn,
            feedId: feedId
        });

        uint256 feedIdIndex = getIdFromFeed(feedId);
        bundledReport = _bundleReport(signedReports[feedIdIndex]);
        signedReport = _getReportData(bundledReport);
    }

    /**
     * @dev Bundles a report with a quote and returns the bundled report.
     * @param report The report to be bundled.
     * @return The bundled report.
     */

    function _bundleReport(
        bytes memory report
    ) private view returns (bytes memory) {
        Quote memory quote;
        quote.quoteAddress = i_linkToken;
        (
            bytes32[3] memory reportContext,
            bytes memory reportData,
            bytes32[] memory rs,
            bytes32[] memory ss,
            bytes32 raw
        ) = abi.decode(
                report,
                (bytes32[3], bytes, bytes32[], bytes32[], bytes32)
            );
        bytes memory bundledReport = abi.encode(
            reportContext,
            reportData,
            rs,
            ss,
            raw,
            abi.encode(quote)
        );
        return bundledReport;
    }

    /**
     * @dev Extracts and decodes the report data from a signed report.
     * @param signedReport The signed report.
     * @return The decoded report data.
     */
    function _getReportData(
        bytes memory signedReport
    ) internal pure returns (Report memory) {
        (, bytes memory reportData, , , ) = abi.decode(
            signedReport,
            (bytes32[3], bytes, bytes32[], bytes32[], bytes32)
        );

        Report memory report = abi.decode(reportData, (Report));
        return report;
    }

    /**
     * @dev Returns the index of a feed ID in the array of feed IDs.
     * @param feedId The feed id that you are looking for its index
     * @return The index of the feed ID in the array, or reverts with an error if not found.
     */
    function getIdFromFeed(string memory feedId) public view returns (uint256) {
        uint256 result;
        string[] storage feeds = s_feedsHex;

        for (uint256 i = 0; i < feeds.length; i++) {
            if (
                keccak256(abi.encode(feeds[i])) == keccak256(abi.encode(feedId))
            ) {
                result = i;
                break;
            }
            if (i == feeds.length - 1) {
                revert InvalidFeedId(feedId);
            }
        }

        return result;
    }

    // ================================================================
    // |                             SWAP                             |
    // ================================================================

    /**
     * @dev Scales the price from a report to match the token's decimals.
     * @param tokenOut The output token for which the price should be scaled.
     * @param priceFromReport The price from the report to be scaled.
     * @return The scaled price with the appropriate token decimals.
     */
    function _scalePriceToTokenDecimals(
        IERC20 tokenOut,
        int192 priceFromReport
    ) private view returns (uint256) {
        uint256 pricefeedDecimals = 18;
        uint8 tokenOutDecimals = tokenOut.decimals();
        if (tokenOutDecimals < pricefeedDecimals) {
            uint256 difference = pricefeedDecimals - tokenOutDecimals;
            return uint256(uint192(priceFromReport)) / 10 ** difference;
        } else {
            uint256 difference = tokenOutDecimals - pricefeedDecimals;
            return uint256(uint192(priceFromReport)) * 10 ** difference;
        }
    }

    /**
     * @dev Swaps tokens using the verified report data and swap parameters.
     * It first decodes the verified report data to obtain the benchmark price,
     * then transfers tokens from the recipient to this contract, approves the
     * token transfer, and executes the swap using the provided parameters.
     * @param verifiedReport The verified report data containing price information.
     * @param tradeParams The parameters for the token swap.
     * @return The amount of tokens received after the swap.
     */
    function _swapTokens(
        Report memory verifiedReport,
        TradeParamsStruct memory tradeParams
    ) private returns (uint256) {
        uint8 inputTokenDecimals = IERC20(tradeParams.tokenIn).decimals();
        uint256 priceForOneToken = _scalePriceToTokenDecimals(
            IERC20(tradeParams.tokenOut),
            verifiedReport.benchmark
        );

        uint256 outputAmount = (priceForOneToken * tradeParams.amountIn) /
            10 ** inputTokenDecimals;

        IERC20(tradeParams.tokenIn).transferFrom(
            tradeParams.recipient,
            address(this),
            tradeParams.amountIn
        );
        IERC20(tradeParams.tokenIn).approve(
            address(i_router),
            tradeParams.amountIn
        );

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter
            .ExactInputSingleParams(
                tradeParams.tokenIn,
                tradeParams.tokenOut,
                FEE,
                tradeParams.recipient,
                tradeParams.amountIn,
                outputAmount,
                0
            );

        return i_router.exactInputSingle(params);
    }

    /**
     * @dev Extracts and decodes the report data from a signed report.
     * This function is needed because the contract needs native tokens
     * to verify reports.
     **/
    receive() external payable {}
}
