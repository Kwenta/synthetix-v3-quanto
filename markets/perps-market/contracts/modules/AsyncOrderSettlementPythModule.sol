//SPDX-License-Identifier: MIT
pragma solidity >=0.8.11 <0.9.0;

import {ERC2771Context} from "@synthetixio/core-contracts/contracts/utils/ERC2771Context.sol";
import {FeatureFlag} from "@synthetixio/core-modules/contracts/storage/FeatureFlag.sol";
import {IAsyncOrderSettlementPythModule} from "../interfaces/IAsyncOrderSettlementPythModule.sol";
import {PerpsAccount} from "../storage/PerpsAccount.sol";
import {MathUtil} from "../utils/MathUtil.sol";
import {Flags} from "../utils/Flags.sol";
import {PerpsMarket} from "../storage/PerpsMarket.sol";
import {AsyncOrder} from "../storage/AsyncOrder.sol";
import {Position} from "../storage/Position.sol";
import {GlobalPerpsMarket} from "../storage/GlobalPerpsMarket.sol";
import {SettlementStrategy} from "../storage/SettlementStrategy.sol";
import {PerpsMarketFactory} from "../storage/PerpsMarketFactory.sol";
import {GlobalPerpsMarketConfiguration} from "../storage/GlobalPerpsMarketConfiguration.sol";
import {PerpsMarketConfiguration} from "../storage/PerpsMarketConfiguration.sol";
import {PerpsPrice} from "../storage/PerpsPrice.sol";
import {IMarketEvents} from "../interfaces/IMarketEvents.sol";
import {IAccountEvents} from "../interfaces/IAccountEvents.sol";
import {KeeperCosts} from "../storage/KeeperCosts.sol";
import {IPythERC7412Wrapper} from "../interfaces/external/IPythERC7412Wrapper.sol";
import {SafeCastU256, SafeCastI256} from "@synthetixio/core-contracts/contracts/utils/SafeCast.sol";
import {USDUint256, USDPerBaseUint256, QuantoUint256, QuantoInt256, USDPerQuantoUint256, InteractionsQuantoUint256, InteractionsQuantoInt256} from '@kwenta/quanto-dimensions/src/UnitTypes.sol';

/**
 * @title Module for settling async orders using pyth as price feed.
 * @dev See IAsyncOrderSettlementPythModule.
 */
contract AsyncOrderSettlementPythModule is
    IAsyncOrderSettlementPythModule,
    IMarketEvents,
    IAccountEvents
{
    using SafeCastI256 for int256;
    using SafeCastU256 for uint256;
    using PerpsAccount for PerpsAccount.Data;
    using PerpsMarket for PerpsMarket.Data;
    using AsyncOrder for AsyncOrder.Data;
    using PerpsMarketFactory for PerpsMarketFactory.Data;
    using GlobalPerpsMarket for GlobalPerpsMarket.Data;
    using GlobalPerpsMarketConfiguration for GlobalPerpsMarketConfiguration.Data;
    using Position for Position.Data;
    using KeeperCosts for KeeperCosts.Data;
    using InteractionsQuantoUint256 for QuantoUint256;
    using InteractionsQuantoInt256 for QuantoInt256;

    /**
     * @inheritdoc IAsyncOrderSettlementPythModule
     */
    function settleOrder(uint128 accountId) external {
        FeatureFlag.ensureAccessToFeature(Flags.PERPS_SYSTEM);

        (
            AsyncOrder.Data storage asyncOrder,
            SettlementStrategy.Data storage settlementStrategy
        ) = AsyncOrder.loadValid(accountId);

        int256 offchainPrice = IPythERC7412Wrapper(settlementStrategy.priceVerificationContract)
            .getBenchmarkPrice(
                settlementStrategy.feedId,
                (asyncOrder.commitmentTime + settlementStrategy.commitmentPriceDelay).to64()
            );

        _settleOrder(USDPerBaseUint256.wrap(offchainPrice.toUint()), asyncOrder, settlementStrategy);
    }

    /**
     * @dev used for settleing an order.
     */
    function _settleOrder(
        USDPerBaseUint256 price,
        AsyncOrder.Data storage asyncOrder,
        SettlementStrategy.Data storage settlementStrategy
    ) private {
        SettleOrderRuntime memory runtime;
        runtime.accountId = asyncOrder.request.accountId;
        runtime.marketId = asyncOrder.request.marketId;
        // check if account is flagged
        GlobalPerpsMarket.load().checkLiquidation(runtime.accountId);

        Position.Data storage oldPosition;
        (runtime.newPosition, runtime.totalFees, runtime.fillPrice, oldPosition) = asyncOrder
            .validateRequest(settlementStrategy, price);

        runtime.amountToDeduct = runtime.totalFees;
        runtime.sizeDelta = asyncOrder.request.sizeDelta;

        PerpsMarketFactory.Data storage factory = PerpsMarketFactory.load();
        PerpsAccount.Data storage perpsAccount = PerpsAccount.load(runtime.accountId);

        // use fill price to calculate realized pnl
        (runtime.pnl, , runtime.chargedInterest, runtime.accruedFunding, , ) = oldPosition.getPnl(
            runtime.fillPrice
        );
        runtime.pnlUint = runtime.pnl.abs();

        if (runtime.pnl > InteractionsQuantoInt256.zero()) {
            PerpsMarketConfiguration.Data storage marketConfig = PerpsMarketConfiguration.load(
                runtime.marketId
            );
            perpsAccount.updateCollateralAmount(marketConfig.quantoSynthMarketId, runtime.pnl.unwrap());
        } else if (runtime.pnl < InteractionsQuantoInt256.zero()) {
            USDPerQuantoUint256 quantoPrice = PerpsPrice.getCurrentQuantoPrice(runtime.marketId, PerpsPrice.Tolerance.DEFAULT);
            runtime.amountToDeduct = runtime.amountToDeduct + runtime.pnlUint.mulDecimalToUSD(quantoPrice);
        }

        // after pnl is realized, update position
        runtime.updateData = PerpsMarket.loadValid(runtime.marketId).updatePositionData(
            runtime.accountId,
            runtime.newPosition
        );
        perpsAccount.updateOpenPositions(runtime.marketId, runtime.newPosition.size);

        emit MarketUpdated(
            runtime.updateData.marketId,
            price,
            runtime.updateData.skew,
            runtime.updateData.size,
            runtime.sizeDelta,
            runtime.updateData.currentFundingRate,
            runtime.updateData.currentFundingVelocity,
            runtime.updateData.interestRate
        );

        // since margin is deposited when trader deposits, as long as the owed collateral is deducted
        // from internal accounting, fees are automatically realized by the stakers
        if (runtime.amountToDeduct.unwrap() > 0) {
            (runtime.deductedSynthIds, runtime.deductedAmount) = perpsAccount.deductFromAccount(
                runtime.amountToDeduct
            );
            for (
                runtime.synthDeductionIterator = 0;
                runtime.synthDeductionIterator < runtime.deductedSynthIds.length;
                runtime.synthDeductionIterator++
            ) {
                if (runtime.deductedAmount[runtime.synthDeductionIterator] > 0) {
                    emit CollateralDeducted(
                        runtime.accountId,
                        runtime.deductedSynthIds[runtime.synthDeductionIterator],
                        runtime.deductedAmount[runtime.synthDeductionIterator]
                    );
                }
            }
        }
        runtime.settlementReward =
            settlementStrategy.settlementReward +
            KeeperCosts.load().getSettlementKeeperCosts();

        if (runtime.settlementReward.unwrap() > 0) {
            // pay keeper
            factory.withdrawMarketUsd(ERC2771Context._msgSender(), runtime.settlementReward);
        }

        (runtime.referralFees, runtime.feeCollectorFees) = GlobalPerpsMarketConfiguration
            .load()
            .collectFees(
                (runtime.totalFees - runtime.settlementReward), // totalFees includes settlement reward so we remove it
                asyncOrder.request.referrer,
                factory
            );

        // trader can now commit a new order
        asyncOrder.reset();

        // Note: new event for this due to stack too deep adding it to OrderSettled event
        emit InterestCharged(runtime.accountId, runtime.chargedInterest.unwrap());

        // emit event
        emit OrderSettled(
            runtime.marketId,
            runtime.accountId,
            runtime.fillPrice.unwrap(),
            runtime.pnl.unwrap(),
            runtime.accruedFunding.unwrap(),
            runtime.sizeDelta,
            runtime.newPosition.size.unwrap(),
            runtime.totalFees.unwrap(),
            runtime.referralFees,
            runtime.feeCollectorFees,
            runtime.settlementReward,
            asyncOrder.request.trackingCode,
            ERC2771Context._msgSender()
        );
    }
}
