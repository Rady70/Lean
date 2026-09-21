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

        [TestCase("17:00:00", 17, 0, 0)]
        [TestCase("17:00", 17, 0, 0)]
        [TestCase("1700", 17, 0, 0)]
        [TestCase("170030", 17, 0, 30)]
        [TestCase("0000", 0, 0, 0)]
        [TestCase("23:59:59", 23, 59, 59)]
        public void TimesOfDayAcceptColonAndColonFreeForms(string text, int h, int m, int s)
        {
            Assert.That(ParameterParsing.ParseTimeOfDay(text, "t"), Is.EqualTo(new TimeSpan(h, m, s)));
        }

        [TestCase("24:00")]
        [TestCase("2400")]
        [TestCase("17")]
        [TestCase("5pm")]
        [TestCase("")]
        public void InvalidTimesOfDayAreRejectedWithTheParameterName(string text)
        {
            var error = Assert.Throws<ArgumentException>(() => ParameterParsing.ParseTimeOfDay(text, "single-anchor-swap-rollover-time"));
            Assert.That(error!.Message, Does.Contain("single-anchor-swap-rollover-time"));
        }

        [Test]
        public void TripleSwapDayAcceptsNamesAnyCaseAndNone()
        {
            Assert.That(ParameterParsing.ParseOptionalDayOfWeek("Wednesday", "d"), Is.EqualTo(DayOfWeek.Wednesday));
            Assert.That(ParameterParsing.ParseOptionalDayOfWeek("friday", "d"), Is.EqualTo(DayOfWeek.Friday));
            Assert.That(ParameterParsing.ParseOptionalDayOfWeek("none", "d"), Is.Null);
            Assert.That(ParameterParsing.ParseOptionalDayOfWeek("", "d"), Is.Null);
            Assert.Throws<ArgumentException>(() => ParameterParsing.ParseOptionalDayOfWeek("midweek", "d"));
        }
    }
}
