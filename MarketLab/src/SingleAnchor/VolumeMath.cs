using System;

namespace MarketLab.SingleAnchor
{
    /// <summary>
    /// Broker volume arithmetic in exact decimal.
    /// </summary>
    public static class VolumeMath
    {
        /// <summary>
        /// Rounds upward to the next whole step: ceil(volume / step) * step (specification section 8).
        /// </summary>
        public static decimal CeilToStep(decimal volume, decimal step)
        {
            if (step <= 0m) throw new ArgumentOutOfRangeException(nameof(step), step, "Volume step must be positive.");
            return Math.Ceiling(volume / step) * step;
        }

        /// <summary>
        /// Rounds to the nearest whole step, midpoints away from zero (used for trades 1..Nnormal,
        /// where the specification asks only for "a valid broker volume step").
        /// </summary>
        public static decimal RoundToNearestStep(decimal volume, decimal step)
        {
            if (step <= 0m) throw new ArgumentOutOfRangeException(nameof(step), step, "Volume step must be positive.");
            return Math.Round(volume / step, 0, MidpointRounding.AwayFromZero) * step;
        }
    }
}
