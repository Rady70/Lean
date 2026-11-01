/*
 * Prints every QQQ minute trade bar of the given days from a LEAN data folder, read with LEAN's own
 * LeanDataReader (ToolBox, unchanged):
 *   dotnet MarketLab.LeanMinuteReadback.dll <data-folder> <yyyyMMdd> [<yyyyMMdd> ...]
 * One line per bar: yyyy-MM-dd HH:mm (bar start, New York), open, high, low, close, volume.
 */
using System;
using System.Globalization;
using QuantConnect;
using QuantConnect.Configuration;
using QuantConnect.Data;
using QuantConnect.Data.Market;
using QuantConnect.ToolBox;

namespace MarketLab.LeanMinuteReadback
{
    public static class Program
    {
        public static int Main(string[] args)
        {
            if (args.Length < 2)
            {
                Console.Error.WriteLine("usage: MarketLab.LeanMinuteReadback <data-folder> <yyyyMMdd> [...]");
                return 2;
            }
            Config.Set("data-folder", args[0]);
            var c = CultureInfo.InvariantCulture;
            // an unmapped identifier: no map-file provider is needed to name the files (QQQ's ticker is "qqq" here)
            var sid = SecurityIdentifier.GenerateEquity(new DateTime(1999, 3, 10), "QQQ", Market.USA);
            var symbol = new Symbol(sid, "QQQ");
            var config = new SubscriptionDataConfig(typeof(TradeBar), symbol, Resolution.Minute, TimeZones.NewYork,
                TimeZones.NewYork, fillForward: false, extendedHours: true, isInternalFeed: true);
            for (var i = 1; i < args.Length; i++)
            {
                var day = DateTime.ParseExact(args[i], "yyyyMMdd", c);
                foreach (var d in new LeanDataReader(config, symbol, Resolution.Minute, day, args[0]).Parse())
                {
                    var b = (TradeBar)d;
                    Console.WriteLine(string.Join(",", b.Time.ToString("yyyy-MM-dd HH:mm", c), b.Open.ToString(c),
                        b.High.ToString(c), b.Low.ToString(c), b.Close.ToString(c), b.Volume.ToString(c)));
                }
            }
            return 0;
        }
    }
}
