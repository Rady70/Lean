using System.Globalization;
using System.IO;
using System.Text;
using NUnit.Framework;
using QuantConnect.Util;

namespace MarketLab.HistoricalDataProbe.Tests
{
    /// <summary>
    /// Direct boundary tests against the unchanged LEAN reader the native tick
    /// format is written for (`Common/Util/StreamReaderExtensions.GetDecimal`).
    /// The Python converter's representability gate is aligned with this behavior.
    /// </summary>
    [TestFixture]
    public class NativeReaderBoundaryTests
    {
        private static decimal Parse(string text)
        {
            using var reader = new StreamReader(new MemoryStream(Encoding.UTF8.GetBytes(text + ",")));
            return reader.GetDecimal();
        }

        [TestCase("0")]
        [TestCase("1900.00")]
        [TestCase("9223372036854775807")]
        [TestCase("9223372036854775808")]
        [TestCase("18446744073709551615")]
        public void NativeReader_RoundTripsCoefficientsThroughUnsigned64BitMax(string text)
        {
            Assert.That(
                Parse(text).ToString(CultureInfo.InvariantCulture),
                Is.EqualTo(text),
                "the reader preserves every coefficient up to unsigned 64-bit max");
        }

        [Test]
        public void NativeReader_WrapsAboveUnsigned64BitMax()
        {
            Assert.That(
                Parse("18446744073709551616").ToString(CultureInfo.InvariantCulture),
                Is.EqualTo("0"),
                "2^64 wraps in the unchecked long accumulator");
        }
    }
}
