using System;

namespace MarketLab.SingleAnchor
{
    /// <summary>
    /// Broker volume arithmetic in exact decimal.
    /// </summary>
    public static class VolumeMath
    {
        /// <summary>
        /// Rounds upward to the next whole step: ceil(volume / step) * step. Used for every lot the
        /// strategy places: broker normalization never reduces a requested volume (specification
        /// section 8 for the tail; the same conservative rule for trades 1..Nnormal).
        /// </summary>
        public static decimal CeilToStep(decimal volume, decimal step)
        {
            if (step <= 0m) throw new ArgumentOutOfRangeException(nameof(step), step, "Volume step must be positive.");
            return Math.Ceiling(volume / step) * step;
        }
    }
}
