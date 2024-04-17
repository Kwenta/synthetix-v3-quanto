//SPDX-License-Identifier: MIT
pragma solidity >=0.8.11 <0.9.0;

import {DecimalMath} from "@synthetixio/core-contracts/contracts/utils/DecimalMath.sol";
import {SafeCastI128} from "@synthetixio/core-contracts/contracts/utils/SafeCast.sol";
import {OrderFee} from "./OrderFee.sol";
import {SettlementStrategy} from "./SettlementStrategy.sol";
import {MathUtil} from "../utils/MathUtil.sol";
import {BaseQuantoPerUSDUint256, BaseQuantoPerUSDInt128, USDPerBaseUint256, BaseQuantoPerUSDInt256, QuantoUint256, InteractionsBaseQuantoPerUSDUint256, InteractionsBaseQuantoPerUSDInt128, InteractionsQuantoUint256} from '@kwenta/quanto-dimensions/src/UnitTypes.sol';

library PerpsMarketConfiguration {
    using DecimalMath for int256;
    using DecimalMath for uint256;
    using SafeCastI128 for int128;
    using InteractionsBaseQuantoPerUSDUint256 for BaseQuantoPerUSDUint256;
    using InteractionsBaseQuantoPerUSDInt128 for BaseQuantoPerUSDInt128;

    error MaxOpenInterestReached(uint128 marketId, BaseQuantoPerUSDUint256 maxMarketSize, BaseQuantoPerUSDInt256 newSideSize);

    error MaxUSDOpenInterestReached(
        uint128 marketId,
        QuantoUint256 maxMarketValue,
        BaseQuantoPerUSDInt256 newSideSize,
        USDPerBaseUint256 price
    );

    error InvalidSettlementStrategy(uint256 settlementStrategyId);

    struct Data {
        OrderFee.Data orderFees;
        SettlementStrategy.Data[] settlementStrategies;
        BaseQuantoPerUSDUint256 maxMarketSize; // oi cap in base*quanto/usd
        uint256 maxFundingVelocity;
        BaseQuantoPerUSDUint256 skewScale;
        /**
         * @dev the initial margin requirements for this market when opening a position
         * @dev this fraction is multiplied by the impact of the position on the skew (open position size / skewScale)
         */
        uint256 initialMarginRatioD18;
        /**
         * @dev This scalar is applied to the calculated initial margin ratio
         * @dev this generally will be lower than initial margin but is used to determine when to liquidate a position
         * @dev this fraction is multiplied by the impact of the position on the skew (position size / skewScale)
         */
        uint256 maintenanceMarginScalarD18;
        /**
         * @dev This ratio is multiplied by the market's notional size (size * currentPrice) to determine how much credit is required for the market to be sufficiently backed by the LPs
         */
        uint256 lockedOiRatioD18;
        /**
         * @dev This multiplier is applied to the max liquidation value when calculating max liquidation for a given market
         */
        uint256 maxLiquidationLimitAccumulationMultiplier;
        /**
         * @dev This configured window is the max liquidation amount that can be accumulated.
         * @dev If you multiply maxLiquidationPerSecond * this window in seconds, you get the max liquidation amount that can be accumulated within this window
         */
        uint256 maxSecondsInLiquidationWindow;
        /**
         * @dev This value is multiplied by the notional value of a position to determine flag reward
         */
        uint256 flagRewardRatioD18;
        /**
         * @dev minimum position value in the quanto asset, this is a constant value added to position margin requirements (initial/maintenance)
         */
        QuantoUint256 minimumPositionMargin;
        /**
         * @dev This value gets applied to the initial margin ratio to ensure there's a cap on the max leverage regardless of position size
         */
        uint256 minimumInitialMarginRatioD18;
        /**
         * @dev Threshold for allowing further liquidations when max liquidation amount is reached
         */
        uint256 maxLiquidationPd;
        /**
         * @dev if the msg.sender is this endorsed liquidator during an account liquidation, the max liquidation amount doesn't apply.
         * @dev this address is allowed to fully liquidate any account eligible for liquidation.
         */
        address endorsedLiquidator;
        /**
         * @dev OI cap in quanto denominated.
         * @dev If set to zero then there is no cap with value, just units
         */
        QuantoUint256 maxMarketValue;
        /**
         * @dev The Synth Market Id for the quanto asset for this market
         */
        uint128 quantoSynthMarketId;
    }

    function load(uint128 marketId) internal pure returns (Data storage store) {
        bytes32 s = keccak256(
            abi.encode("io.synthetix.perps-market.PerpsMarketConfiguration", marketId)
        );
        assembly {
            store.slot := s
        }
    }

    function maxLiquidationAmountInWindow(Data storage self) internal view returns (BaseQuantoPerUSDUint256) {
        OrderFee.Data storage orderFeeData = self.orderFees;
        return
            self.skewScale.mulDecimal(orderFeeData.makerFee + orderFeeData.takerFee).mulDecimal(
                self.maxLiquidationLimitAccumulationMultiplier
            ).mul(self.maxSecondsInLiquidationWindow);
    }

    function numberOfLiquidationWindows(
        Data storage self,
        BaseQuantoPerUSDUint256 positionSize
    ) internal view returns (uint256) {
        BaseQuantoPerUSDUint256 maxLiquidation = maxLiquidationAmountInWindow(self);
        if (maxLiquidation.isZero()) return 0;
        return positionSize.ceilDivide(maxLiquidation);
    }

    function calculateFlagReward(
        Data storage self,
        QuantoUint256 notionalValue
    ) internal view returns (QuantoUint256) {
        return notionalValue.mulDecimal(self.flagRewardRatioD18);
    }

    function calculateRequiredMargins(
        Data storage self,
        BaseQuantoPerUSDInt128 size,
        USDPerBaseUint256 price
    )
        internal
        view
        returns (
            uint256 initialMarginRatio,
            uint256 maintenanceMarginRatio,
            QuantoUint256 initialMargin,
            QuantoUint256 maintenanceMargin
        )
    {
        if (size.isZero()) {
            return (0, 0, InteractionsQuantoUint256.zero(), InteractionsQuantoUint256.zero());
        }
        BaseQuantoPerUSDUint256 sizeAbs = size.abs();
        uint256 impactOnSkew = self.skewScale.isZero() ? 0 : sizeAbs.divDecimalToDimensionless(self.skewScale);

        initialMarginRatio =
            impactOnSkew.mulDecimal(self.initialMarginRatioD18) +
            self.minimumInitialMarginRatioD18;
        maintenanceMarginRatio = initialMarginRatio.mulDecimal(self.maintenanceMarginScalarD18);

        QuantoUint256 notional = sizeAbs.mulDecimalToQuanto(price);

        initialMargin = notional.mulDecimal(initialMarginRatio) + self.minimumPositionMargin;
        maintenanceMargin =
            notional.mulDecimal(maintenanceMarginRatio) +
            self.minimumPositionMargin;
    }

    /**
     * @notice given a strategy id, returns the entire settlement strategy struct
     */
    function loadValidSettlementStrategy(
        uint128 marketId,
        uint256 settlementStrategyId
    ) internal view returns (SettlementStrategy.Data storage strategy) {
        Data storage self = load(marketId);
        validateStrategyExists(self, settlementStrategyId);

        strategy = self.settlementStrategies[settlementStrategyId];
        if (strategy.disabled) {
            revert InvalidSettlementStrategy(settlementStrategyId);
        }
    }

    function validateStrategyExists(
        Data storage config,
        uint256 settlementStrategyId
    ) internal view {
        if (settlementStrategyId >= config.settlementStrategies.length) {
            revert InvalidSettlementStrategy(settlementStrategyId);
        }
    }
}
