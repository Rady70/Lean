using System;
using System.Globalization;

namespace MarketLab.SingleAnchor
{
    /// <summary>
    /// Parsers for the string-valued LEAN parameters of <see cref="SingleAnchorVNextAlgorithm"/>.
    /// Invariant culture throughout; every failure names the parameter and the accepted forms.
    /// </summary>
    public static class ParameterParsing
    {
        /// <summary>A calendar date in yyyy-MM-dd form.</summary>
        public static DateTime ParseDate(string value, string name)
        {
            if (value != null && DateTime.TryParseExact(value.Trim(), "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out var date))
            {
                return date;
            }
            throw new ArgumentException($"{name} must be a date in yyyy-MM-dd form (got '{value}').");
        }

        /// <summary>
        /// A decimal in invariant culture, or null when the value is empty (not supplied). An
        /// unparsable value is an error naming the parameter.
        /// </summary>
        public static decimal? ParseOptionalDecimal(string value, string name)
        {
            if (string.IsNullOrWhiteSpace(value))
            {
                return null;
            }
            if (decimal.TryParse(value.Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out var parsed))
            {
                return parsed;
            }
            throw new ArgumentException($"{name} must be a decimal number (got '{value}').");
        }
    }
}
