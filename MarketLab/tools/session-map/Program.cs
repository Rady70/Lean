using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using MarketLab.SingleAnchor;
using Newtonsoft.Json;
using NodaTime;

namespace MarketLab.SessionMapTool
{
    /// <summary>
    /// Derives the SingleAnchor source-session map from the immutable Dukascopy JForex XAUUSD
    /// monthly CSV history. The junction rule, the session types and the five-minute availability
    /// rule are the same C# types the strategy replay uses
    /// (<see cref="SessionJunctionRule"/>, <see cref="HistoricalSessionMap"/>,
    /// <see cref="HistoricalTradingAvailability"/>): the generator does not re-implement them.
    ///
    /// Two passes over the source, both streaming and deterministic:
    /// <list type="number">
    /// <item>scan every monthly file in order (in parallel per file) into junction-split segments
    /// and derive the session map plus its source provenance (SHA-256 per file, aggregate, row
    /// counts, first/last quote);</item>
    /// <item>classify every source row with the runtime classifier to count the quote-only and
    /// tradable rows per session and in total.</item>
    /// </list>
    ///
    /// The source is never modified. The map and the optional stats file are written outside Git
    /// and are reproducible byte for byte from the same source.
    /// </summary>
    internal static class Program
    {
        private const string Header = "timestamp,bid,ask,bidVolume,askVolume";
        private const string TimestampFormat = "yyyy-MM-dd'T'HH:mm:ss.fff'Z'";
        private const string SourceFileNamePattern = @"^(?<symbol>[A-Z]+)_(?<year>\d{4})_(?<month>\d{2})_";
        private static readonly Regex SourceFileName = new Regex(SourceFileNamePattern, RegexOptions.Compiled);

        private static int Main(string[] args)
        {
            try
            {
                return Run(args);
            }
            catch (Exception error)
            {
                Console.Error.WriteLine("ERROR: " + error.Message);
                if (error is AggregateException aggregate && aggregate.InnerException != null)
                {
                    Console.Error.WriteLine("ERROR: " + aggregate.InnerException.Message);
                }
                return 1;
            }
        }

        private static int Run(string[] args)
        {
            string? sourceDirectory = null;
            string? outPath = null;
            string? statsPath = null;
            var jobs = Math.Min(Environment.ProcessorCount, 8);
            for (var i = 0; i < args.Length; i++)
            {
                switch (args[i])
                {
                    case "--source":
                        sourceDirectory = Next(args, ref i);
                        break;
                    case "--out":
                        outPath = Next(args, ref i);
                        break;
                    case "--stats":
                        statsPath = Next(args, ref i);
                        break;
                    case "--jobs":
                        jobs = int.Parse(Next(args, ref i), CultureInfo.InvariantCulture);
                        if (jobs < 1) throw new ArgumentException("--jobs must be at least 1");
                        break;
                    default:
                        throw new ArgumentException(
                            $"unknown argument '{args[i]}'. Usage: MarketLab.SessionMapTool --source <csv directory> " +
                            "--out <map.json> [--stats <stats.json>] [--jobs <n>]");
                }
            }
            if (sourceDirectory == null || outPath == null)
            {
                throw new ArgumentException(
                    "Usage: MarketLab.SessionMapTool --source <csv directory> --out <map.json> [--stats <stats.json>] [--jobs <n>]");
            }
            if (!Directory.Exists(sourceDirectory))
            {
                throw new ArgumentException($"source directory does not exist: {sourceDirectory}");
            }

            var files = FindSourceFiles(sourceDirectory);
            Console.WriteLine($"source: {files.Count} monthly files in {sourceDirectory}");

            var scans = ScanFiles(files, jobs);
            ValidateContiguity(scans);
            var totalRows = scans.Sum(scan => scan.Rows);
            var firstQuote = scans[0].FirstQuoteUtc;
            var lastQuote = scans[scans.Length - 1].LastQuoteUtc;
            var aggregate = AggregateHash(scans);
            var sourceIdentity = new HistoricalSessionMapSource(
                Path.GetFullPath(sourceDirectory), scans.Length, totalRows, aggregate, firstQuote, lastQuote);
            var map = HistoricalSessionMap.Derive(
                scans.SelectMany(scan => scan.Segments), "XAUUSD", SessionJunctionRule.TimeZoneId, sourceIdentity);
            map.Save(outPath!);

            var counts = CountAvailability(files, map, jobs);
            var stats = BuildStats(map, counts, totalRows);
            if (statsPath != null)
            {
                File.WriteAllText(statsPath, JsonConvert.SerializeObject(stats, Formatting.Indented), new UTF8Encoding(false));
            }

            Console.WriteLine($"rows: {totalRows} quote rows ({scans.Length} files); first {Format(firstQuote)}, last {Format(lastQuote)}");
            Console.WriteLine($"sessions: {map.Sessions.Count}; junctions: {map.Sessions.Count - 1}; observable ends: {map.Sessions.Count - 1}");
            Console.WriteLine(
                $"quote-only rows: {stats.QuoteOnlyRows} ({stats.QuoteOnlyPercentOfSourceRows.ToString("0.######", CultureInfo.InvariantCulture)}% of source rows); " +
                $"complete sessions {stats.CompleteSessionQuoteOnlyRows}, final session opening buffer {stats.FinalSessionOpenBufferRows}");
            Console.WriteLine($"map written: {Path.GetFullPath(outPath!)}");
            if (statsPath != null)
            {
                Console.WriteLine($"stats written: {Path.GetFullPath(statsPath)}");
            }
            return 0;
        }

        private static string Next(string[] args, ref int index)
        {
            if (index + 1 >= args.Length)
            {
                throw new ArgumentException($"missing value after {args[index]}");
            }
            index++;
            return args[index];
        }

        private static List<SourceFile> FindSourceFiles(string directory)
        {
            var files = new List<SourceFile>();
            foreach (var path in Directory.EnumerateFiles(directory, "*.csv", SearchOption.TopDirectoryOnly))
            {
                var match = SourceFileName.Match(Path.GetFileName(path));
                if (!match.Success)
                {
                    throw new InvalidDataException(
                        $"source file name does not match the expected '<SYMBOL>_<YYYY>_<MM>_...' pattern: {path}");
                }
                var symbol = match.Groups["symbol"].Value;
                var year = int.Parse(match.Groups["year"].Value, CultureInfo.InvariantCulture);
                var month = int.Parse(match.Groups["month"].Value, CultureInfo.InvariantCulture);
                if (month < 1 || month > 12)
                {
                    throw new InvalidDataException($"source file name has an invalid month: {path}");
                }
                if (files.Count > 0 && files[0].Symbol != symbol)
                {
                    throw new InvalidDataException($"source directory mixes symbols: {files[0].Path} and {path}");
                }
                files.Add(new SourceFile(path, symbol, year, month));
            }
            if (files.Count == 0)
            {
                throw new InvalidDataException($"no monthly CSV source files found in {directory}");
            }
            files.Sort((left, right) => left.Year != right.Year
                ? left.Year.CompareTo(right.Year)
                : left.Month.CompareTo(right.Month));
            for (var i = 1; i < files.Count; i++)
            {
                var expected = files[i - 1].Year * 12 + (files[i - 1].Month - 1) + 1;
                var actual = files[i].Year * 12 + (files[i].Month - 1);
                if (actual != expected)
                {
                    throw new InvalidDataException(
                        $"source months are not contiguous: {files[i - 1].Path} is followed by {files[i].Path}");
                }
            }
            return files;
        }

        private static FileScan[] ScanFiles(List<SourceFile> files, int jobs)
        {
            var scans = new FileScan[files.Count];
            try
            {
                Parallel.For(0, files.Count, new ParallelOptions { MaxDegreeOfParallelism = jobs }, index =>
                {
                    scans[index] = ScanFile(files[index].Path);
                    Console.WriteLine($"  scanned {files[index].Path} ({scans[index].Rows} rows)");
                });
            }
            catch (AggregateException error)
            {
                throw error.InnerException ?? error;
            }
            return scans;
        }

        private static FileScan ScanFile(string path)
        {
            var segments = new List<HistoricalSegment>();
            long rows;
            DateTime first;
            DateTime last;
            string hash;
            using (var raw = File.OpenRead(path))
            using (var sha = SHA256.Create())
            {
                using (var crypto = new CryptoStream(raw, sha, CryptoStreamMode.Read))
                using (var reader = new StreamReader(crypto, new UTF8Encoding(false), detectEncodingFromByteOrderMarks: true))
                {
                    var header = reader.ReadLine();
                    if (header == null)
                    {
                        throw new InvalidDataException($"source file is empty: {path}");
                    }
                    if (header != Header)
                    {
                        throw new InvalidDataException($"unexpected header in {path}: '{header}'");
                    }
                    rows = ScanQuoteRows(reader, path, segments, out first, out last);
                }
                hash = Convert.ToHexString(sha.Hash!).ToLowerInvariant();
            }
            if (rows == 0)
            {
                throw new InvalidDataException($"source file has no quote rows: {path}");
            }
            return new FileScan(path, hash, rows, first, last, segments);
        }

        private static long ScanQuoteRows(
            StreamReader reader,
            string path,
            List<HistoricalSegment> segments,
            out DateTime first,
            out DateTime last)
        {
            long rows = 0;
            var segmentFirst = default(DateTime);
            var segmentLast = default(DateTime);
            first = default;
            last = default;
            string? line;
            while ((line = reader.ReadLine()) != null)
            {
                if (line.Length == 0)
                {
                    throw new InvalidDataException($"blank row {rows + 2} in {path}");
                }
                var comma = line.IndexOf(',');
                if (comma <= 0)
                {
                    throw new InvalidDataException($"malformed row {rows + 2} in {path}: '{line}'");
                }
                var text = line.Substring(0, comma);
                if (!DateTime.TryParseExact(
                        text,
                        TimestampFormat,
                        CultureInfo.InvariantCulture,
                        DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal,
                        out var timestamp)
                    || timestamp.Kind != DateTimeKind.Utc)
                {
                    throw new InvalidDataException(
                        $"row {rows + 2} in {path} has a non-canonical UTC timestamp: '{text}'");
                }
                if (rows > 0)
                {
                    if (timestamp < segmentLast)
                    {
                        throw new InvalidDataException(
                            $"row {rows + 2} in {path} is out of order: '{text}' follows '{Format(segmentLast)}'");
                    }
                    if (SessionJunctionRule.IsJunction(segmentLast, timestamp))
                    {
                        segments.Add(new HistoricalSegment(segmentFirst, segmentLast));
                        segmentFirst = timestamp;
                    }
                }
                else
                {
                    first = timestamp;
                    segmentFirst = timestamp;
                }
                segmentLast = timestamp;
                last = timestamp;
                rows++;
            }
            if (rows > 0)
            {
                segments.Add(new HistoricalSegment(segmentFirst, segmentLast));
            }
            return rows;
        }

        private static void ValidateContiguity(FileScan[] scans)
        {
            for (var i = 1; i < scans.Length; i++)
            {
                if (scans[i].FirstQuoteUtc < scans[i - 1].LastQuoteUtc)
                {
                    throw new InvalidDataException(
                        $"month files overlap or are out of order: {scans[i - 1].Path} ends {Format(scans[i - 1].LastQuoteUtc)} " +
                        $"and {scans[i].Path} starts {Format(scans[i].FirstQuoteUtc)}");
                }
            }
        }

        private static string AggregateHash(FileScan[] scans)
        {
            using var aggregate = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
            foreach (var scan in scans)
            {
                aggregate.AppendData(Encoding.UTF8.GetBytes($"{Path.GetFileName(scan.Path)}:{scan.Sha256}\n"));
            }
            return Convert.ToHexString(aggregate.GetHashAndReset()).ToLowerInvariant();
        }

        private static AvailabilityCounts CountAvailability(List<SourceFile> files, HistoricalSessionMap map, int jobs)
        {
            var open = new long[map.Sessions.Count];
            var close = new long[map.Sessions.Count];
            var perFile = new AvailabilityCounts[files.Count];
            try
            {
                Parallel.For(0, files.Count, new ParallelOptions { MaxDegreeOfParallelism = jobs }, index =>
                {
                    perFile[index] = CountFile(files[index].Path, map);
                });
            }
            catch (AggregateException error)
            {
                throw error.InnerException ?? error;
            }
            foreach (var counts in perFile)
            {
                for (var session = 0; session < map.Sessions.Count; session++)
                {
                    open[session] += counts.Open[session];
                    close[session] += counts.Close[session];
                }
            }
            return new AvailabilityCounts(open, close, perFile.Sum(counts => counts.Rows));
        }

        private static AvailabilityCounts CountFile(string path, HistoricalSessionMap map)
        {
            var availability = map.ToAvailability(DateTimeZone.Utc);
            var open = new long[map.Sessions.Count];
            var close = new long[map.Sessions.Count];
            long rows = 0;
            using var reader = new StreamReader(path, new UTF8Encoding(false), detectEncodingFromByteOrderMarks: true);
            var header = reader.ReadLine();
            if (header != Header)
            {
                throw new InvalidDataException($"unexpected header in {path}: '{header}'");
            }
            string? line;
            while ((line = reader.ReadLine()) != null)
            {
                if (line.Length == 0)
                {
                    throw new InvalidDataException($"blank row in {path}");
                }
                var comma = line.IndexOf(',');
                if (comma <= 0
                    || !DateTime.TryParseExact(
                        line.Substring(0, comma),
                        TimestampFormat,
                        CultureInfo.InvariantCulture,
                        DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal,
                        out var timestamp)
                    || timestamp.Kind != DateTimeKind.Utc)
                {
                    throw new InvalidDataException($"malformed timestamp row {rows + 2} in {path}");
                }
                switch (availability.Classify(timestamp, out var session))
                {
                    case QuoteTradability.QuoteOnlyOpeningBuffer:
                        open[session]++;
                        break;
                    case QuoteTradability.QuoteOnlyClosingBuffer:
                        close[session]++;
                        break;
                }
                rows++;
            }
            return new AvailabilityCounts(open, close, rows);
        }

        private static SessionMapStats BuildStats(HistoricalSessionMap map, AvailabilityCounts counts, long totalRows)
        {
            var completeSessions = map.Sessions.Count - 1; // only the final session has no observable end
            long completeOpen = 0;
            long completeClose = 0;
            long allOpen = 0;
            long observableClose = 0;
            for (var session = 0; session < map.Sessions.Count; session++)
            {
                allOpen += counts.Open[session];
                observableClose += counts.Close[session];
                if (session < completeSessions)
                {
                    completeOpen += counts.Open[session];
                    completeClose += counts.Close[session];
                }
            }
            var completeQuoteOnly = completeOpen + completeClose;
            return new SessionMapStats
            {
                Sessions = map.Sessions.Count,
                Junctions = map.Sessions.Count - 1,
                CompleteSessions = completeSessions,
                FinalSessionEndObservable = false,
                SourceRows = totalRows,
                AllOpenBufferRows = allOpen,
                ObservableCloseBufferRows = observableClose,
                QuoteOnlyRows = allOpen + observableClose,
                TradableRows = totalRows - allOpen - observableClose,
                CompleteSessionOpenBufferRows = completeOpen,
                CompleteSessionCloseBufferRows = completeClose,
                CompleteSessionQuoteOnlyRows = completeQuoteOnly,
                FinalSessionOpenBufferRows = allOpen - completeOpen,
                QuoteOnlyPercentOfSourceRows = totalRows == 0 ? 0d : completeQuoteOnly * 100d / totalRows
            };
        }

        private static string Format(DateTime value)
        {
            return value.ToString(TimestampFormat, CultureInfo.InvariantCulture);
        }

        private sealed record SourceFile(string Path, string Symbol, int Year, int Month);

        private sealed record FileScan(
            string Path,
            string Sha256,
            long Rows,
            DateTime FirstQuoteUtc,
            DateTime LastQuoteUtc,
            IReadOnlyList<HistoricalSegment> Segments);

        private sealed record AvailabilityCounts(long[] Open, long[] Close, long Rows);

        private sealed class SessionMapStats
        {
            [JsonProperty("contract")] public string Contract { get; set; } = "marketlab-single-anchor-session-map-stats-v1";
            [JsonProperty("sessions")] public int Sessions { get; set; }
            [JsonProperty("junctions")] public int Junctions { get; set; }
            [JsonProperty("completeSessions")] public int CompleteSessions { get; set; }
            [JsonProperty("finalSessionEndObservable")] public bool FinalSessionEndObservable { get; set; }
            [JsonProperty("sourceRows")] public long SourceRows { get; set; }
            [JsonProperty("allOpenBufferRows")] public long AllOpenBufferRows { get; set; }
            [JsonProperty("observableCloseBufferRows")] public long ObservableCloseBufferRows { get; set; }
            [JsonProperty("quoteOnlyRows")] public long QuoteOnlyRows { get; set; }
            [JsonProperty("tradableRows")] public long TradableRows { get; set; }
            [JsonProperty("completeSessionOpenBufferRows")] public long CompleteSessionOpenBufferRows { get; set; }
            [JsonProperty("completeSessionCloseBufferRows")] public long CompleteSessionCloseBufferRows { get; set; }
            [JsonProperty("completeSessionQuoteOnlyRows")] public long CompleteSessionQuoteOnlyRows { get; set; }
            [JsonProperty("finalSessionOpenBufferRows")] public long FinalSessionOpenBufferRows { get; set; }
            [JsonProperty("quoteOnlyPercentOfSourceRows")] public double QuoteOnlyPercentOfSourceRows { get; set; }
        }
    }
}
