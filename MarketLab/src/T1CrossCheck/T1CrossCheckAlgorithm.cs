/*
 * MarketLab T1 cross-check: L02's 5-minute opening-range breakout on QQQ, written again from the frozen T1 record
 * (Rady70/Market_Lab docs/QQQ_STAGE1_T1_T3_PARAMETERS.md §2) and run with LEAN's own orders, fills and portfolio,
 * so that Market_Lab's Python engine can be compared with LEAN day by day (docs/LEAN_T1_CROSSCHECK_PLAN.md).
 *
 * Rule: first candle = the minute bars 09:30-09:34; long if its close > its open, short if <, none on a doji. A market
 * entry when the 09:34 bar has arrived (09:35). Stop (stop-market) at the candle's low (long) / high (short); target
 * (limit) at fill + 10R, R = the positive fill-to-stop distance; otherwise a market-on-close exit. A fill at or beyond
 * the stop is "invalid": LEAN only knows the price after the fill, so the position is closed at once and the day is
 * recorded as invalid. Exposure 1x: whole shares of a USD 100,000 account.
 *
 * Costs (parameter t1-costs): "gross" = no fee and no slippage; "base" = USD 0.005 per share (linear, no minimum)
 * and a slippage of half the spread (half of 1 tick) on market and market-on-close fills, plus 1 tick on stop fills.
 * The plan's doubling of the spread in the first 5 minutes never applies to T1 (its first fill is at 09:35).
 *
 * The minimum price variation is set to 0.0001 (the data's price grid), so LEAN does not round the target and stop
 * prices to the cent as it would by default; Market_Lab's engine does not round them either.
 *
 * Output: t1_crosscheck_days.csv in the run's working directory, one row per day that had bars.
 * Engine source is unchanged; this file only uses LEAN's public algorithm and model interfaces.
 */
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using QuantConnect;
using QuantConnect.Algorithm;
using QuantConnect.Data;
using QuantConnect.Data.Market;
using QuantConnect.Orders;
using QuantConnect.Orders.Fees;
using QuantConnect.Orders.Slippage;
using QuantConnect.Securities;

namespace MarketLab.T1CrossCheck
{
    public class T1CrossCheckAlgorithm : QCAlgorithm
    {
        private const decimal Account = 100000m;
        private const decimal TargetR = 10m;
        private const int FirstCandleMinutes = 5;
        public const string OutputFile = "t1_crosscheck_days.csv";

        private static readonly string[] Columns =
        {
            "day", "decision", "first_bar", "o1", "c1", "level", "qty", "entry_time", "entry_price", "target",
            "stop_order_price", "limit_order_price", "exit_kind", "exit_time", "exit_price", "fees", "market_close",
            "flags"
        };

        private Symbol _qqq = null!;
        private bool _gross;
        private readonly List<string> _rows = new();
        private DayState? _d;

        private sealed class DayState
        {
            public DateTime Day;
            public readonly List<TradeBar> First = new();
            public bool Decided;
            public string Decision = "";
            public int Side;
            public decimal Level, Qty, EntryPrice, Target, Fees;
            public string EntryTime = "";
            public OrderTicket? Stop, Limit, Moc;
            public readonly List<(string Kind, string Time, decimal Price)> Exits = new();
            public readonly List<string> Flags = new();
        }

        public override void Initialize()
        {
            var start = DateTime.ParseExact(GetParameter("t1-start"), "yyyyMMdd", CultureInfo.InvariantCulture);
            var end = DateTime.ParseExact(GetParameter("t1-end"), "yyyyMMdd", CultureInfo.InvariantCulture);
            var costs = GetParameter("t1-costs");
            if (costs != "gross" && costs != "base")
            {
                throw new ArgumentException($"t1-costs must be gross or base, got '{costs}'");
            }
            _gross = costs == "gross";
            SetTimeZone(TimeZones.NewYork);
            SetStartDate(start);
            SetEndDate(end);
            SetCash(Account);
            var eq = AddEquity("QQQ", Resolution.Minute, Market.USA, fillForward: false, leverage: 2m,
                extendedMarketHours: false, dataNormalizationMode: DataNormalizationMode.Raw);
            eq.SetFeeModel(new LinearPerShareFeeModel(_gross ? 0m : 0.005m));
            eq.SetSlippageModel(new HalfSpreadSlippageModel(_gross ? 0m : 0.005m, _gross ? 0m : 0.01m));
            eq.PriceVariationModel = new FixedPriceVariationModel(0.0001m);
            _qqq = eq.Symbol;
            // a constant benchmark: LEAN would otherwise load SPY daily data, which this data folder does not have
            SetBenchmark(_ => 0m);
        }

        public override void OnData(Slice slice)
        {
            if (!slice.Bars.TryGetValue(_qqq, out var bar))
            {
                return;
            }
            var day = bar.Time.Date;
            if (_d == null || _d.Day != day)
            {
                Finish();
                _d = new DayState { Day = day };
            }
            if (_d.Decided)
            {
                return;
            }
            var k = (int)Math.Round((bar.Time - day.AddHours(9.5)).TotalMinutes);
            if (k < FirstCandleMinutes)
            {
                _d.First.Add(bar);
            }
            if (k >= FirstCandleMinutes - 1)
            {
                Decide(bar);
            }
        }

        private void Decide(TradeBar bar)
        {
            var d = _d!;
            d.Decided = true;
            if (d.First.Count == 0)
            {
                d.Decision = "no_first_candle";
                return;
            }
            var o1 = d.First[0].Open;
            var c1 = d.First[^1].Close;
            if (c1 == o1)
            {
                d.Decision = "doji";
                return;
            }
            d.Side = c1 > o1 ? 1 : -1;
            d.Level = d.Side > 0 ? d.First.Min(b => b.Low) : d.First.Max(b => b.High);
            d.Qty = d.Side * Math.Floor(Account / bar.Close);
            var entry = MarketOrder(_qqq, d.Qty, tag: "entry");
            if (entry.Status != OrderStatus.Filled)
            {
                d.Decision = d.Side > 0 ? "long" : "short";
                d.Flags.Add("entry_unfilled");
                return;
            }
            d.EntryPrice = entry.AverageFillPrice;
            if (d.Side * (d.EntryPrice - d.Level) <= 0)
            {
                d.Decision = "invalid";
                MarketOrder(_qqq, -d.Qty, tag: "invalid_exit");
                return;
            }
            d.Decision = d.Side > 0 ? "long" : "short";
            var r = d.Side * (d.EntryPrice - d.Level);
            d.Target = d.EntryPrice + d.Side * TargetR * r;
            // ids ascend in this order, and LEAN's backtesting brokerage scans pending orders by id: the stop is
            // checked before the target in the same bar, as in MarketLab's engine (stop first)
            d.Stop = StopMarketOrder(_qqq, -d.Qty, d.Level, tag: "stop");
            d.Limit = LimitOrder(_qqq, -d.Qty, d.Target, tag: "target");
            d.Moc = MarketOnCloseOrder(_qqq, -d.Qty, tag: "close");
        }

        public override void OnOrderEvent(OrderEvent e)
        {
            if (_d == null)
            {
                return;
            }
            _d.Fees += e.OrderFee.Value.Amount;
            if (e.Status != OrderStatus.Filled)
            {
                return;
            }
            var d = _d;
            // orders are told apart by their tag; a market entry fills inside MarketOrder(), before its ticket returns
            var tag = Transactions.GetOrderById(e.OrderId)?.Tag ?? "";
            switch (tag)
            {
                case "entry":
                    d.EntryTime = Hhmm(e.UtcTime);
                    break;
                case "invalid_exit":
                    d.Exits.Add(("invalid", Hhmm(e.UtcTime), e.FillPrice));
                    break;
                case "stop":
                case "target":
                case "close":
                    if (d.Exits.Count > 0)
                    {
                        // LEAN has no one-cancels-other here: a cancel sent from this handler takes effect only
                        // after the brokerage's scan of the same minute, so a second exit order can fill in that
                        // minute. The first exit (lower order id, so the stop before the target) is the day's
                        // exit; the second fill is undone at once and recorded.
                        var same = d.Exits[0].Time == Hhmm(e.UtcTime);
                        d.Flags.Add(same ? $"oco_same_minute_{tag}" : $"second_exit_{tag}");
                        MarketOrder(_qqq, -e.FillQuantity, tag: "undo_second_exit");
                        break;
                    }
                    d.Exits.Add((tag, Hhmm(e.UtcTime), e.FillPrice));
                    foreach (var t in new[] { d.Stop, d.Limit, d.Moc })
                    {
                        if (t != null && t.OrderId != e.OrderId && !t.Status.IsClosed())
                        {
                            t.Cancel();
                        }
                    }
                    break;
            }
        }

        private static string Hhmm(DateTime utc) =>
            utc.ConvertFromUtc(TimeZones.NewYork).ToString("HH:mm", CultureInfo.InvariantCulture);

        private void Finish()
        {
            if (_d == null)
            {
                return;
            }
            var d = _d;
            if (d.Exits.Count > 1)
            {
                d.Flags.Add("double_exit");
            }
            if (Portfolio[_qqq].Quantity != 0)
            {
                d.Flags.Add("not_flat");
                Liquidate(symbol: _qqq, tag: "not_flat");
            }
            var close = Securities[_qqq].Exchange.Hours.GetNextMarketClose(d.Day.AddHours(9.5), false);
            var ex = d.Exits.Count > 0 ? d.Exits[0] : ("", "", 0m);
            string F(decimal x) => x.ToString(CultureInfo.InvariantCulture);
            var first = d.First.Count > 0 ? d.First[0].Time.ToString("HH:mm", CultureInfo.InvariantCulture) : "";
            _rows.Add(string.Join(",", new[]
            {
                d.Day.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture), d.Decision, first,
                d.First.Count > 0 ? F(d.First[0].Open) : "", d.First.Count > 0 ? F(d.First[^1].Close) : "",
                d.Side != 0 ? F(d.Level) : "", F(d.Qty), d.EntryTime, d.EntryTime != "" ? F(d.EntryPrice) : "",
                d.Target != 0 ? F(d.Target) : "",
                d.Stop != null ? F(d.Stop.Get(OrderField.StopPrice)) : "",
                d.Limit != null ? F(d.Limit.Get(OrderField.LimitPrice)) : "",
                ex.Item1, ex.Item2, ex.Item1 != "" ? F(ex.Item3) : "", F(d.Fees),
                close.ToString("HH:mm", CultureInfo.InvariantCulture), string.Join(";", d.Flags)
            }));
            _d = null;
        }

        public override void OnEndOfAlgorithm()
        {
            Finish();
            var path = Path.Combine(Directory.GetCurrentDirectory(), OutputFile);
            File.WriteAllLines(path, new[] { string.Join(",", Columns) }.Concat(_rows));
            Log($"T1 cross-check: {_rows.Count} days written to {path}");
        }
    }

    /// <summary>Linear commission per share, no minimum (Market_Lab's linear Fixed route).</summary>
    public sealed class LinearPerShareFeeModel : FeeModel
    {
        private readonly decimal _perShare;

        public LinearPerShareFeeModel(decimal perShare) => _perShare = perShare;

        public override OrderFee GetOrderFee(OrderFeeParameters parameters) =>
            new OrderFee(new CashAmount(_perShare * parameters.Order.AbsoluteQuantity, Currencies.USD));
    }

    /// <summary>Half the spread on every slipped fill, plus extra slippage on stop-market fills. LEAN applies no
    /// slippage to limit fills.</summary>
    public sealed class HalfSpreadSlippageModel : ISlippageModel
    {
        private readonly decimal _halfSpread, _stopExtra;

        public HalfSpreadSlippageModel(decimal halfSpread, decimal stopExtra)
        {
            _halfSpread = halfSpread;
            _stopExtra = stopExtra;
        }

        public decimal GetSlippageApproximation(Security asset, Order order) =>
            _halfSpread + (order.Type == OrderType.StopMarket ? _stopExtra : 0m);
    }

    /// <summary>A constant minimum price variation.</summary>
    public sealed class FixedPriceVariationModel : IPriceVariationModel
    {
        private readonly decimal _variation;

        public FixedPriceVariationModel(decimal variation) => _variation = variation;

        public decimal GetMinimumPriceVariation(GetMinimumPriceVariationParameters parameters) => _variation;
    }
}
