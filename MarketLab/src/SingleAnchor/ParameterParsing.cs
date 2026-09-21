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
        /// A time of day. Accepts HH:mm, HH:mm:ss and, because LEAN's command-line --parameters
        /// option splits on ':', the colon-free forms HHmm and HHmmss (for example 1700 or 170000).
        /// </summary>
        public static TimeSpan ParseTimeOfDay(string value, string name)
        {
            var text = value?.Trim() ?? string.Empty;
            string[] formats = { "hh\\:mm\\:ss", "hh\\:mm", "hhmmss", "hhmm" };
            foreach (var format in formats)
            {
                if (TimeSpan.TryParseExact(text, format, CultureInfo.InvariantCulture, out var time) && time >= TimeSpan.Zero && time < TimeSpan.FromDays(1))
                {
                    return time;
                }
            }
            throw new ArgumentException($"{name} must be a time of day as HH:mm, HH:mm:ss, HHmm or HHmmss (got '{value}'); use a colon-free form with -Parameters.");
        }

        /// <summary>A day name (any case), or null for 'none' / empty.</summary>
        public static DayOfWeek? ParseOptionalDayOfWeek(string value, string name)
        {
            if (string.IsNullOrWhiteSpace(value) || string.Equals(value.Trim(), "none", StringComparison.OrdinalIgnoreCase))
            {
                return null;
            }
            if (Enum.TryParse<DayOfWeek>(value.Trim(), true, out var day))
            {
                return day;
            }
            throw new ArgumentException($"{name} must be a day name or 'none' (got '{value}').");
        }
    }
}
