const fs = require('fs');
const path = require('path');
const logger = require('@synthetixio/core-js/utils/logger');
const { subtask } = require('hardhat/config');
const { SUBTASK_FINALIZE_DEPLOYMENT } = require('../task-names');

/*
 * Marks a deployment as completed, or deletes it if it didn't produce any changes.
 * */
subtask(SUBTASK_FINALIZE_DEPLOYMENT).setAction(async (_, hre) => {
  logger.subtitle('Finalizing deployment');

  if (hre.deployer.deployment.data.properties.totalGasUsed === '0') {
    logger.checked('Deployment did not produce any changes, deleting temp file');

    fs.unlinkSync(path.resolve(hre.config.paths.root, hre.deployer.deployment.file));
  } else {
    logger.complete('Deployment marked as completed');

    hre.deployer.deployment.data.properties.completed = true;
  }
});
