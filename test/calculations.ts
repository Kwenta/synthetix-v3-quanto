import { BigNumber } from 'ethers';
import Wei, { wei } from '@synthetixio/wei';
import type { Bs } from './typed';
import { PerpMarketConfiguration } from './generated/typechain/MarketConfigurationModule';
import { bn } from './generators';

// --- Primitives --- //

const divDecimalAndCeil = (a: Wei, b: Wei) => {
  const x = wei(a).toNumber() / wei(b).toNumber();
  return wei(Math.ceil(x));
};

// --- Domain --- //

/** Calculates whether two numbers are the same sign. */
export const isSameSide = (a: Wei | BigNumber, b: Wei | BigNumber) => a.eq(0) || b.eq(0) || a.gt(0) == b.gt(0);

// --- Calcs --- //

/** Calculates a position's unrealised PnL (no funding or fees) given the current and previous price. */
export const calcPnl = (size: BigNumber, currentPrice: BigNumber, previousPrice: BigNumber) =>
  wei(size).mul(wei(currentPrice).sub(previousPrice)).toBN();

/** Calculates the fillPrice (pd adjusted market price) given market params and the size of next order. */
export const calcFillPrice = (skew: BigNumber, skewScale: BigNumber, size: BigNumber, price: BigNumber) => {
  const calcPD = (skew: Wei, skewScale: Wei) => skew.div(skewScale);
  const calcAdjustedPrice = (price: Wei, pd: Wei) => price.add(price.mul(pd));

  if (skewScale.eq(0)) {
    return price;
  }
  const pdBefore = calcPD(wei(skew), wei(skewScale));
  const pdAfter = calcPD(wei(skew).add(size), wei(skewScale));

  const priceBefore = calcAdjustedPrice(wei(price), pdBefore);
  const priceAfter = calcAdjustedPrice(wei(price), pdAfter);

  return priceBefore.add(priceAfter).div(2).toBN();
};

/** Calculates order fees and keeper fees associated to settle the order. */
export const calcOrderFees = async (
  bs: Bs,
  marketId: BigNumber,
  sizeDelta: BigNumber,
  keeperFeeBufferUsd: BigNumber
) => {
  if (sizeDelta.eq(0)) {
    throw new Error('A sizeDelta of 0 will result in a NilOrder revert');
  }

  const { systems, ethOracleNode } = bs;
  const { PerpMarketProxy } = systems();

  const fillPrice = await PerpMarketProxy.getFillPrice(marketId, sizeDelta);
  const { skew } = await PerpMarketProxy.getMarketDigest(marketId);
  const { makerFee, takerFee } = await PerpMarketProxy.getMarketConfigurationById(marketId);

  let [makerSizeRatio, takerSizeRatio] = [wei(0), wei(0)];
  const marketSkewBefore = wei(skew);
  const marketSkewAfter = marketSkewBefore.add(sizeDelta);

  if (isSameSide(marketSkewAfter, marketSkewBefore)) {
    // Either a full maker or taker fee is charged on the entire size.
    if (isSameSide(sizeDelta, skew)) {
      [takerSizeRatio, makerSizeRatio] = [wei(1), wei(0)];
    } else {
      [takerSizeRatio, makerSizeRatio] = [wei(0), wei(1)];
    }
  } else {
    // Mixed. Reduced skew to 0 and then a bit more causing it to expand in the other dierction. Infer
    // the portion of size that is maker vs taker and calculate fees appropriately.
    takerSizeRatio = marketSkewBefore.add(sizeDelta).div(sizeDelta);
    makerSizeRatio = wei(1).sub(takerSizeRatio);
  }

  const notional = wei(sizeDelta).abs().mul(fillPrice);
  const orderFee = notional.mul(takerSizeRatio).mul(takerFee).add(notional.mul(makerSizeRatio).mul(makerFee)).toBN();

  // Get the current ETH price.
  const { answer: ethPrice } = await ethOracleNode().agg.latestRoundData();
  // Grab market configuration to infer price.
  const { keeperSettlementGasUnits, keeperProfitMarginPercent, minKeeperFeeUsd, maxKeeperFeeUsd } =
    await PerpMarketProxy.getMarketConfiguration();

  const calcKeeperOrderSettlementFee = (blockBaseFeePerGas: BigNumber) => {
    // Perform calc bounding by min/max to prevent going over/under.
    const baseKeeperFeeUsd = wei(keeperSettlementGasUnits.mul(blockBaseFeePerGas)).mul(1e9).mul(ethPrice);

    // Base keeperFee + profit margin and asmall user specified buffer.
    const baseKeeperFeePlusProfit = baseKeeperFeeUsd.mul(wei(1).add(keeperProfitMarginPercent).add(keeperFeeBufferUsd));

    // Ensure keeper fee doesn't exceed min/max bounds.
    const boundedKeeperFeeUsd = Wei.min(
      Wei.max(wei(minKeeperFeeUsd), baseKeeperFeePlusProfit),
      wei(maxKeeperFeeUsd)
    ).toBN();

    return boundedKeeperFeeUsd;
  };

  return { notional, orderFee, calcKeeperOrderSettlementFee };
};

export const calcTransactionCostInUsd = (
  baseFeePerGas: BigNumber, // in gwei
  gasUnitsForTx: BigNumber, // in gwei
  ethPrice: BigNumber // in ether
) => {
  const costInGwei = baseFeePerGas.mul(gasUnitsForTx);
  return costInGwei.mul(ethPrice).div(BigNumber.from(10).pow(18));
};

/** Calculates the in USD, the reward to flag a position for liquidation. */
export const calcFlagReward = (
  ethPrice: BigNumber,
  baseFeePerGas: BigNumber, // in gwei
  sizeAbs: Wei,
  price: Wei,
  globalConfig: PerpMarketConfiguration.GlobalDataStructOutput,
  marketConfig: PerpMarketConfiguration.DataStructOutput
) => {
  const flagExecutionCostInUsd = calcTransactionCostInUsd(baseFeePerGas, globalConfig.keeperFlagGasUnits, ethPrice);

  const flagFeeInUsd = Wei.max(
    wei(flagExecutionCostInUsd).mul(wei(1).add(globalConfig.keeperProfitMarginPercent)),
    wei(flagExecutionCostInUsd).add(wei(globalConfig.keeperProfitMarginUsd))
  );

  const flagFeeWithRewardInUsd = flagFeeInUsd.add(sizeAbs.mul(price).mul(marketConfig.liquidationRewardPercent));

  return {
    result: Wei.min(flagFeeWithRewardInUsd, wei(globalConfig.maxKeeperFeeUsd)),
    flagExecutionCostInUsd,
    sizeReward: sizeAbs.mul(price).mul(marketConfig.liquidationRewardPercent),
    flagFeeWithRewardInUsd,
    flagFeeInUsd,
  };
};

/** Calculates the liquidation fees in USD given price of ETH, gas, size of position and capacity. */
export const calcLiquidationKeeperFee = (
  ethPrice: BigNumber,
  baseFeePerGas: BigNumber, // in gwei
  sizeAbs: Wei,
  maxLiqCapacity: Wei,
  globalConfig: PerpMarketConfiguration.GlobalDataStructOutput
) => {
  if (sizeAbs.eq(0)) return wei(0);
  const iterations = divDecimalAndCeil(sizeAbs, maxLiqCapacity);

  const totalGasUnitsToLiquidate = wei(globalConfig.keeperLiquidationGasUnits).toBN();
  const flagExecutionCostInUsd = calcTransactionCostInUsd(baseFeePerGas, totalGasUnitsToLiquidate, ethPrice);

  const liquidationFeeInUsd = Wei.max(
    wei(flagExecutionCostInUsd).mul(wei(1).add(globalConfig.keeperProfitMarginPercent)),
    wei(flagExecutionCostInUsd).add(wei(globalConfig.keeperProfitMarginUsd))
  );

  return Wei.min(liquidationFeeInUsd, wei(globalConfig.maxKeeperFeeUsd)).mul(iterations);
};

/** Calculates the discounted collateral price given the size, spot market skew scale, and min/max discounts. */
export const calcDiscountedCollateralPrice = (
  collateralPrice: BigNumber,
  amount: BigNumber,
  spotMarketSkewScale: BigNumber,
  min: BigNumber,
  max: BigNumber
) => {
  const w_collateralPrice = wei(collateralPrice);
  const w_amount = wei(amount);
  const w_spotMarketSkewScale = wei(spotMarketSkewScale);
  const w_min = wei(min);
  const w_max = wei(max);

  // price = oraclePrice * (1 - min(max(size / (skewScale * 2), minCollateralDiscount), maxCollateralDiscount))
  const discount = Wei.min(Wei.max(w_amount.div(w_spotMarketSkewScale.mul(wei(2))), w_min), w_max);
  return w_collateralPrice.mul(wei(1).sub(discount)).toBN();
};
