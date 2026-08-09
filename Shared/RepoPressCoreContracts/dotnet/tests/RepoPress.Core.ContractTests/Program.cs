using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using RepoPress.Core;

internal static class Program
{
    private static readonly char[] NewlineSeparators =
    {
        '\r', '\n', '\v', '\f', '\u0085', '\u2028', '\u2029'
    };

    private static int Main()
    {
        var failures = new List<string>();
        try
        {
            var root = FindRepositoryRoot();
            RunContractSuite(root, failures);
        }
        catch (Exception exception)
        {
            failures.Add($"[harness] {exception.GetType().Name}: {exception.Message}");
        }

        if (failures.Count > 0)
        {
            Console.Error.WriteLine($"RepoPress Core contract harness failed ({failures.Count} failure(s)):");
            foreach (var failure in failures)
            {
                Console.Error.WriteLine(failure);
            }
            return 1;
        }

        Console.WriteLine("RepoPress Core contract harness passed: 40 cases (valid=33, invalid=7; repository-endpoint=16, front-matter-document=12, publish-conflict-diff=12).");
        return 0;
    }

    private static string FindRepositoryRoot()
    {
        var startingPoints = new[]
        {
            AppContext.BaseDirectory,
            Environment.CurrentDirectory
        };

        foreach (var startingPoint in startingPoints)
        {
            var directory = new DirectoryInfo(Path.GetFullPath(startingPoint));
            for (var depth = 0; directory is not null && depth < 12; depth++, directory = directory.Parent)
            {
                var manifest = Path.Combine(directory.FullName, "contracts", "fixtures", "v1", "manifest.json");
                if (File.Exists(manifest))
                {
                    return directory.FullName;
                }
            }
        }

        throw new InvalidOperationException(
            "Unable to locate repository root: searched bounded ancestors from AppContext.BaseDirectory and Environment.CurrentDirectory for contracts/fixtures/v1/manifest.json.");
    }

    private static void RunContractSuite(string root, List<string> failures)
    {
        var fixturesRoot = Path.Combine(root, "contracts", "fixtures", "v1");
        var manifestPath = Path.Combine(fixturesRoot, "manifest.json");
        using var manifest = JsonDocument.Parse(File.ReadAllBytes(manifestPath));
        var manifestObject = manifest.RootElement;

        Check(manifestObject.GetProperty("formatVersion").GetInt32() == 1, failures, "manifest formatVersion must be 1");
        Check(manifestObject.GetProperty("minimumReaderVersion").GetInt32() == 1, failures, "manifest minimumReaderVersion must be 1");

        var entries = new List<ManifestEntry>();
        foreach (var entryElement in manifestObject.GetProperty("cases").EnumerateArray())
        {
            entries.Add(new ManifestEntry(
                entryElement.GetProperty("id").GetString() ?? "",
                entryElement.GetProperty("path").GetString() ?? "",
                entryElement.GetProperty("sha256").GetString() ?? ""));
        }

        Check(entries.Count == 40, failures, $"manifest case count expected 40, got {entries.Count}");
        Check(entries.Select(entry => entry.Id).Distinct(StringComparer.Ordinal).Count() == entries.Count, failures, "manifest IDs must be unique");
        Check(entries.Select(entry => entry.Path).Distinct(StringComparer.Ordinal).Count() == entries.Count, failures, "manifest paths must be unique");

        var cases = new List<FixtureCase>();
        foreach (var entry in entries)
        {
            try
            {
                var fixturePath = ResolveFixturePath(fixturesRoot, entry.Path);
                var bytes = File.ReadAllBytes(fixturePath);
                var actualHash = Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();
                Check(actualHash == entry.Sha256, failures, $"fixture {entry.Id}: manifest SHA-256 mismatch");

                var document = JsonDocument.Parse(bytes);
                var rootElement = document.RootElement;
                var fixture = new FixtureCase(
                    entry.Id,
                    entry.Path,
                    rootElement.GetProperty("capability").GetString() ?? "",
                    rootElement.GetProperty("validity").GetString() ?? "",
                    rootElement.GetProperty("description").GetString() ?? "",
                    rootElement.GetProperty("input"),
                    rootElement.GetProperty("expected"),
                    document);
                Check(fixture.Id == rootElement.GetProperty("id").GetString(), failures, $"fixture {entry.Id}: manifest ID/path case ID mismatch");
                cases.Add(fixture);
            }
            catch (Exception exception)
            {
                failures.Add($"[fixture {entry.Id}] unable to load case: {exception.Message}");
            }
        }

        Check(cases.Count == 40, failures, $"loaded case count expected 40, got {cases.Count}");
        Check(cases.Count(fixture => fixture.Validity == "valid") == 33, failures, "valid case count expected 33");
        Check(cases.Count(fixture => fixture.Validity == "invalid") == 7, failures, "invalid case count expected 7");
        Check(cases.Count(fixture => fixture.Capability == "repository-endpoint") == 16, failures, "repository-endpoint case count expected 16");
        Check(cases.Count(fixture => fixture.Capability == "front-matter-document") == 12, failures, "front-matter-document case count expected 12");
        Check(cases.Count(fixture => fixture.Capability == "publish-conflict-diff") == 12, failures, "publish-conflict-diff case count expected 12");

        foreach (var fixture in cases)
        {
            try
            {
                if (fixture.Validity == "valid")
                {
                    VerifyValid(fixture, failures);
                }
                else if (fixture.Validity == "invalid")
                {
                    VerifyInvalid(fixture, failures);
                }
                else
                {
                    failures.Add($"[fixture {fixture.Id}] unknown validity {fixture.Validity}");
                }
            }
            catch (Exception exception)
            {
                failures.Add($"[fixture {fixture.Id}] unexpected {exception.GetType().Name}: {exception.Message}");
            }
        }

        VerifyPublicApiSmoke(failures);
    }

    private static string ResolveFixturePath(string fixturesRoot, string relativePath)
    {
        var root = Path.GetFullPath(fixturesRoot);
        var candidate = Path.GetFullPath(Path.Combine(root, relativePath));
        var prefix = root.EndsWith(Path.DirectorySeparatorChar) ? root : root + Path.DirectorySeparatorChar;
        var comparison = OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;
        if (!candidate.StartsWith(prefix, comparison))
        {
            throw new InvalidOperationException("manifest path escapes contracts/fixtures/v1");
        }
        return candidate;
    }

    private static void VerifyValid(FixtureCase fixture, List<string> failures)
    {
        switch (fixture.Capability)
        {
            case "repository-endpoint":
                VerifyEndpoint(fixture, failures);
                break;
            case "front-matter-document":
                VerifyFrontMatter(fixture, failures);
                break;
            case "publish-conflict-diff":
                VerifyDiff(fixture, failures);
                break;
            default:
                failures.Add($"[fixture {fixture.Id}] unknown capability {fixture.Capability}");
                break;
        }
    }

    private static void VerifyInvalid(FixtureCase fixture, List<string> failures)
    {
        var expectedCode = RequiredString(fixture.Expected, "errorCode");
        try
        {
            switch (fixture.Capability)
            {
                case "repository-endpoint":
                {
                    var request = FixtureAdapter.DecodeEndpoint(fixture.Input);
                    try
                    {
                        _ = RepositoryEndpoint.Validate(request.BaseUrl);
                        failures.Add($"[fixture {fixture.Id}] invalid endpoint was accepted");
                    }
                    catch (RepositoryEndpointException exception)
                    {
                        Check(exception.ErrorCode == expectedCode, failures, $"fixture {fixture.Id}: endpoint ErrorCode {exception.ErrorCode} != {expectedCode}");
                    }
                    break;
                }
                case "front-matter-document":
                    _ = FixtureAdapter.DecodeFrontMatter(fixture.Input);
                    failures.Add($"[fixture {fixture.Id}] invalid front matter was accepted");
                    break;
                default:
                    failures.Add($"[fixture {fixture.Id}] unsupported invalid capability {fixture.Capability}");
                    break;
            }
        }
        catch (InvalidInputException exception)
        {
            Check(exception.ErrorCode == expectedCode, failures, $"fixture {fixture.Id}: adapter ErrorCode {exception.ErrorCode} != {expectedCode}");
        }
    }

    private static void VerifyEndpoint(FixtureCase fixture, List<string> failures)
    {
        var request = FixtureAdapter.DecodeEndpoint(fixture.Input);
        var endpoint = RepositoryEndpoint.Validate(request.BaseUrl);
        var expectedValue = fixture.Expected.GetProperty("value");

        if (request.Operation == "validate")
        {
            Check(endpoint.BaseUrl == RequiredString(expectedValue, "baseURL"), failures, $"fixture {fixture.Id}: BaseUrl mismatch");
        }
        else
        {
            var actual = endpoint.BuildUrl(request.Path, request.QueryItems);
            Check(actual == RequiredString(expectedValue, "absoluteURL"), failures, $"fixture {fixture.Id}: BuildUrl mismatch");
        }
    }

    private static void VerifyFrontMatter(FixtureCase fixture, List<string> failures)
    {
        var request = FixtureAdapter.DecodeFrontMatter(fixture.Input);
        var actual = request.Operation == "render"
            ? new FrontMatterDocumentRenderer().Render(request.Document)
            : new FrontMatterDocumentRenderer().MarkdownDocument(request.Document);
        var expected = RequiredString(fixture.Expected.GetProperty("value"), "text");
        var actualBytes = Encoding.UTF8.GetBytes(actual);
        var expectedBytes = Encoding.UTF8.GetBytes(expected);
        Check(actualBytes.AsSpan().SequenceEqual(expectedBytes), failures, $"fixture {fixture.Id}: front matter UTF-8 output mismatch");
    }

    private static void VerifyDiff(FixtureCase fixture, List<string> failures)
    {
        var request = FixtureAdapter.DecodeDiff(fixture.Input);
        var remoteLines = SplitSwiftNewlines(request.Remote);
        var localLines = SplitSwiftNewlines(request.Local);
        var expectedValue = fixture.Expected.GetProperty("value");
        var expectedStrategy = (long)remoteLines.Length * localLines.Length <= 250_000 ? "lcs" : "coarse";
        Check(RequiredString(expectedValue, "strategy") == expectedStrategy, failures, $"fixture {fixture.Id}: diff strategy mismatch");

        var expectedLines = expectedValue.GetProperty("lines").EnumerateArray().ToArray();
        var actualLines = new PublishConflictDiffBuilder().Diff(request.Remote, request.Local);
        Check(actualLines.Count == expectedLines.Length, failures, $"fixture {fixture.Id}: diff line count mismatch");
        var count = Math.Min(actualLines.Count, expectedLines.Length);
        for (var index = 0; index < count; index++)
        {
            var expectedLine = expectedLines[index];
            var actualLine = actualLines[index];
            var expectedKind = ParseKind(RequiredString(expectedLine, "kind"));
            Check(actualLine.Id == expectedLine.GetProperty("id").GetInt32(), failures, $"fixture {fixture.Id}[{index}]: id mismatch");
            Check(actualLine.Kind == expectedKind, failures, $"fixture {fixture.Id}[{index}]: kind mismatch");
            Check(actualLine.Marker == RequiredString(expectedLine, "marker"), failures, $"fixture {fixture.Id}[{index}]: marker mismatch");
            Check(actualLine.Text == RequiredString(expectedLine, "text"), failures, $"fixture {fixture.Id}[{index}]: text mismatch");
        }
    }

    private static string[] SplitSwiftNewlines(string value) => value.Split(NewlineSeparators, StringSplitOptions.None);

    private static PublishConflictDiffLineKind ParseKind(string value) => value switch
    {
        "same" => PublishConflictDiffLineKind.Same,
        "remote" => PublishConflictDiffLineKind.Remote,
        "local" => PublishConflictDiffLineKind.Local,
        _ => throw new InvalidInputException($"unknown diff line kind {value}")
    };

    private static void VerifyPublicApiSmoke(List<string> failures)
    {
        const string smokeId = "api-smoke";
        try
        {
            var endpoint = RepositoryEndpoint.Validate("https://github.example.test/api/v3");
            Check(endpoint.BuildUrl("/repos/owner/repo/contents/docs%2Findex.md", new[] { new RepositoryQueryItem("ref", "main") }) == "https://github.example.test/api/v3/repos/owner/repo/contents/docs%2Findex.md?ref=main", failures, $"[{smokeId}] enterprise endpoint mismatch");

            var remoteLine = new PublishConflictDiffLine(3, PublishConflictDiffLineKind.Remote, "old");
            Check(remoteLine.Marker == "-" && remoteLine.Kind == PublishConflictDiffLineKind.Remote, failures, $"[{smokeId}] diff line marker/kind mismatch");

            var boundaryRemote = string.Join("\n", Enumerable.Repeat("remote", 500));
            var boundaryLocal = string.Join("\n", Enumerable.Repeat("local", 500));
            var boundary = new PublishConflictDiffBuilder().Diff(boundaryRemote, boundaryLocal);
            Check(boundary.Count == 1_000, failures, $"[{smokeId}] exact threshold count mismatch");
            var coarseRemote = string.Join("\n", Enumerable.Repeat("remote", 501));
            var coarseLocal = string.Join("\n", Enumerable.Repeat("local", 500));
            var coarse = new PublishConflictDiffBuilder().Diff(coarseRemote, coarseLocal);
            Check(coarse.Count == 1_001 && coarse[500].Kind == PublishConflictDiffLineKind.Remote && coarse[501].Kind == PublishConflictDiffLineKind.Local, failures, $"[{smokeId}] coarse threshold mismatch");

            var unicode = new PublishConflictDiffBuilder().Diff("标题\n😀", "标题\n🧪");
            Check(unicode.Any(line => line.Text == "😀") && unicode.Any(line => line.Text == "🧪"), failures, $"[{smokeId}] Unicode diff mismatch");
            var crlf = new PublishConflictDiffBuilder().Diff("a\r\nb", "a\nb");
            Check(crlf.Count == 3 && crlf[1].Text == "" && crlf[1].Kind == PublishConflictDiffLineKind.Remote, failures, $"[{smokeId}] newline split mismatch");
            var control = new PublishConflictDiffBuilder().Diff("a\u001cb", "a\u001cb");
            Check(control.Count == 1 && control[0].Text == "a\u001cb", failures, $"[{smokeId}] U+001C must remain in line text");
        }
        catch (Exception exception)
        {
            failures.Add($"[{smokeId}] {exception.GetType().Name}: {exception.Message}");
        }
    }

    private static string RequiredString(JsonElement objectElement, string property)
    {
        if (!objectElement.TryGetProperty(property, out var value) || value.ValueKind != JsonValueKind.String)
        {
            throw new InvalidInputException($"{property} must be a string");
        }
        return value.GetString() ?? throw new InvalidInputException($"{property} must not be null");
    }

    private static void Check(bool condition, List<string> failures, string message)
    {
        if (!condition)
        {
            failures.Add(message.StartsWith("[", StringComparison.Ordinal) ? message : $"[harness] {message}");
        }
    }

    private sealed record ManifestEntry(string Id, string Path, string Sha256);

    private sealed record FixtureCase(
        string Id,
        string RelativePath,
        string Capability,
        string Validity,
        string Description,
        JsonElement Input,
        JsonElement Expected,
        JsonDocument Document);

    private sealed class InvalidInputException : Exception
    {
        public InvalidInputException(string message) : base(message) { }
        public string ErrorCode => "contract.invalid_input";
    }

    private static class FixtureAdapter
    {
        internal sealed record EndpointRequest(string Operation, string BaseUrl, string Path, IReadOnlyList<RepositoryQueryItem> QueryItems);
        internal sealed record FrontMatterRequest(string Operation, FrontMatterDocument Document);
        internal sealed record DiffRequest(string Remote, string Local);

        internal static EndpointRequest DecodeEndpoint(JsonElement input)
        {
            if (input.ValueKind != JsonValueKind.Object)
            {
                throw new InvalidInputException("endpoint input must be an object");
            }
            var operation = RequiredString(input, "operation");
            if (operation is not ("validate" or "build-url"))
            {
                throw new InvalidInputException($"unknown endpoint operation {operation}");
            }
            var baseUrl = RequiredString(input, "baseURL");
            var path = OptionalString(input, "path") ?? "";
            var queryItems = new List<RepositoryQueryItem>();
            if (input.TryGetProperty("queryItems", out var rawItems))
            {
                if (rawItems.ValueKind != JsonValueKind.Array)
                {
                    throw new InvalidInputException("queryItems must be an array");
                }
                var index = 0;
                foreach (var rawItem in rawItems.EnumerateArray())
                {
                    if (rawItem.ValueKind != JsonValueKind.Object)
                    {
                        throw new InvalidInputException($"queryItems[{index}] must be an object");
                    }
                    var name = RequiredString(rawItem, "name");
                    string? value = null;
                    if (rawItem.TryGetProperty("value", out var rawValue) && rawValue.ValueKind != JsonValueKind.Null)
                    {
                        value = RequiredString(rawItem, "value");
                    }
                    queryItems.Add(new RepositoryQueryItem(name, value));
                    index++;
                }
            }
            return new EndpointRequest(operation, baseUrl, path, queryItems);
        }

        internal static FrontMatterRequest DecodeFrontMatter(JsonElement input)
        {
            if (input.ValueKind != JsonValueKind.Object)
            {
                throw new InvalidInputException("front matter input must be an object");
            }
            var operation = RequiredString(input, "operation");
            if (operation is not ("render" or "markdown-document"))
            {
                throw new InvalidInputException($"unknown front matter operation {operation}");
            }
            if (!input.TryGetProperty("document", out var rawDocument) || rawDocument.ValueKind != JsonValueKind.Object)
            {
                throw new InvalidInputException("document must be an object");
            }

            foreach (var key in new[] { "slug", "draftFlag", "summaryField", "summary", "coverField", "coverPath" })
            {
                if (rawDocument.TryGetProperty(key, out var value) && value.ValueKind == JsonValueKind.Null)
                {
                    throw new InvalidInputException($"optional document field {key} must be omitted, not null");
                }
            }

            var syntax = ParseEnum<FrontMatterDocumentSyntax>(RequiredString(rawDocument, "syntax"), "syntax");
            var layout = ParseEnum<FrontMatterTaxonomyLayout>(RequiredString(rawDocument, "taxonomyLayout"), "taxonomyLayout");
            var document = new FrontMatterDocument(
                syntax,
                RequiredString(rawDocument, "title"),
                RequiredString(rawDocument, "formattedDate"),
                OptionalString(rawDocument, "slug"),
                OptionalBool(rawDocument, "draftFlag"),
                OptionalString(rawDocument, "summaryField"),
                OptionalString(rawDocument, "summary"),
                RequiredStringArray(rawDocument, "authors"),
                RequiredStringArray(rawDocument, "tags"),
                RequiredStringArray(rawDocument, "categories"),
                layout,
                OptionalString(rawDocument, "coverField"),
                OptionalString(rawDocument, "coverPath"),
                RequiredBool(rawDocument, "writesCoverInExtraTable"),
                RequiredString(rawDocument, "bodyMarkdown"));
            return new FrontMatterRequest(operation, document);
        }

        internal static DiffRequest DecodeDiff(JsonElement input)
        {
            if (input.ValueKind != JsonValueKind.Object)
            {
                throw new InvalidInputException("diff input must be an object");
            }
            return new DiffRequest(RequiredString(input, "remote"), RequiredString(input, "local"));
        }

        private static T ParseEnum<T>(string value, string property) where T : struct, Enum
        {
            object? result = typeof(T) == typeof(FrontMatterDocumentSyntax)
                ? value switch
                {
                    "yaml" => FrontMatterDocumentSyntax.Yaml,
                    "toml" => FrontMatterDocumentSyntax.Toml,
                    _ => null
                }
                : typeof(T) == typeof(FrontMatterTaxonomyLayout)
                    ? value switch
                    {
                        "inlineTable" => FrontMatterTaxonomyLayout.InlineTable,
                        "table" => FrontMatterTaxonomyLayout.Table,
                        _ => null
                    }
                    : null;
            if (result is null)
            {
                throw new InvalidInputException($"unknown {property} {value}");
            }
            return (T)result;
        }

        private static string? OptionalString(JsonElement objectElement, string property)
        {
            if (!objectElement.TryGetProperty(property, out var value))
            {
                return null;
            }
            if (value.ValueKind != JsonValueKind.String)
            {
                throw new InvalidInputException($"{property} must be a string when present");
            }
            return value.GetString();
        }

        private static bool? OptionalBool(JsonElement objectElement, string property)
        {
            if (!objectElement.TryGetProperty(property, out var value))
            {
                return null;
            }
            if (value.ValueKind != JsonValueKind.True && value.ValueKind != JsonValueKind.False)
            {
                throw new InvalidInputException($"{property} must be a boolean when present");
            }
            return value.GetBoolean();
        }

        private static bool RequiredBool(JsonElement objectElement, string property)
        {
            if (!objectElement.TryGetProperty(property, out var value) || (value.ValueKind != JsonValueKind.True && value.ValueKind != JsonValueKind.False))
            {
                throw new InvalidInputException($"{property} must be a boolean");
            }
            return value.GetBoolean();
        }

        private static List<string> RequiredStringArray(JsonElement objectElement, string property)
        {
            if (!objectElement.TryGetProperty(property, out var value) || value.ValueKind != JsonValueKind.Array)
            {
                throw new InvalidInputException($"{property} must be an array");
            }
            var result = new List<string>();
            foreach (var item in value.EnumerateArray())
            {
                if (item.ValueKind != JsonValueKind.String)
                {
                    throw new InvalidInputException($"{property} must contain only strings");
                }
                result.Add(item.GetString() ?? "");
            }
            return result;
        }
    }
}
