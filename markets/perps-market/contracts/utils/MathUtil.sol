//SPDX-License-Identifier: MIT
pragma solidity >=0.8.11 <0.9.0;

import {SafeCastI256, SafeCastI128, SafeCastU256} from "@synthetixio/core-contracts/contracts/utils/SafeCast.sol";

library MathUtil {
    using SafeCastI256 for int256;
    using SafeCastI128 for int128;
    using SafeCastU256 for uint256;

    function abs(int256 x) internal pure returns (uint256) {
        return x >= 0 ? x.toUint() : (-x).toUint();
    }

    function abs128(int128 x) internal pure returns (uint128) {
        return x >= 0 ? x.toUint() : (-x).toUint();
    }

    function max(int x, int y) internal pure returns (int) {
        return x < y ? y : x;
    }

    function max(uint x, uint y) internal pure returns (uint) {
        return x < y ? y : x;
    }

    function min(int x, int y) internal pure returns (int) {
        return x < y ? x : y;
    }

    function min128(int128 x, int128 y) internal pure returns (int128) {
        return x < y ? x : y;
    }

    function min(uint x, uint y) internal pure returns (uint) {
        return x < y ? x : y;
    }

    function min128(uint128 x, uint128 y) internal pure returns (uint128) {
        return x < y ? x : y;
    }

    function sameSide(int a, int b) internal pure returns (bool) {
        return (a == 0) || (b == 0) || (a > 0) == (b > 0);
    }

    function isSameSideReducing(int128 a, int128 b) internal pure returns (bool) {
        return sameSide(a, b) && abs(b) < abs(a);
    }

    function ceilDivide(uint a, uint b) internal pure returns (uint) {
        if (b == 0) return 0;
        return a / b + (a % b == 0 ? 0 : 1);
    }
}
