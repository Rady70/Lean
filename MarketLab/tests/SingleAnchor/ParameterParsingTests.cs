using System;
using NUnit.Framework;

namespace MarketLab.SingleAnchor.Tests
{
    [TestFixture]
    public class ParameterParsingTests
    {
        [Test]
        public void DatesAreIsoOnly()
        {
            Assert.That(ParameterParsing.ParseDate("2014-05-02", "d"), Is.EqualTo(new DateTime(2014, 5, 2)));
            Assert.That(ParameterParsing.ParseDate(" 2014-05-02 ", "d"), Is.EqualTo(new DateTime(2014, 5, 2)));
            Assert.Throws<ArgumentException>(() => ParameterParsing.ParseDate("05/02/2014", "d"));
            Assert.Throws<ArgumentException>(() => ParameterParsing.ParseDate("", "d"));
        }

        [Test]
        public void OptionalDecimalsDistinguishAbsentFromZero()
        {
            Assert.That(ParameterParsing.ParseOptionalDecimal("", "p"), Is.Null);
            Assert.That(ParameterParsing.ParseOptionalDecimal("  ", "p"), Is.Null);
            Assert.That(ParameterParsing.ParseOptionalDecimal("0", "p"), Is.EqualTo(0m));
            Assert.That(ParameterParsing.ParseOptionalDecimal("0.5", "p"), Is.EqualTo(0.5m));
            Assert.That(ParameterParsing.ParseOptionalDecimal(" 100 ", "p"), Is.EqualTo(100m));
            var error = Assert.Throws<ArgumentException>(() => ParameterParsing.ParseOptionalDecimal("0,5", "single-anchor-projected-spread"));
            Assert.That(error!.Message, Does.Contain("single-anchor-projected-spread"));
        }
    }
}
