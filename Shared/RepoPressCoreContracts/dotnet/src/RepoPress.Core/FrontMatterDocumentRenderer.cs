using System;
using System.Collections.Generic;

namespace RepoPress.Core
{
    public enum FrontMatterDocumentSyntax
    {
        Yaml,
        Toml
    }

    public enum FrontMatterTaxonomyLayout
    {
        InlineTable,
        Table
    }

    public sealed class FrontMatterDocument
    {
        public FrontMatterDocument(
            FrontMatterDocumentSyntax syntax,
            string title,
            string formattedDate,
            string? slug,
            bool? draftFlag,
            string? summaryField,
            string? summary,
            IReadOnlyList<string> authors,
            IReadOnlyList<string> tags,
            IReadOnlyList<string> categories,
            FrontMatterTaxonomyLayout taxonomyLayout,
            string? coverField,
            string? coverPath,
            bool writesCoverInExtraTable,
            string bodyMarkdown)
        {
            Syntax = syntax;
            Title = title ?? throw new ArgumentNullException(nameof(title));
            FormattedDate = formattedDate ?? throw new ArgumentNullException(nameof(formattedDate));
            Slug = slug;
            DraftFlag = draftFlag;
            SummaryField = summaryField;
            Summary = summary;
            Authors = CopyCollection(authors, nameof(authors));
            Tags = CopyCollection(tags, nameof(tags));
            Categories = CopyCollection(categories, nameof(categories));
            TaxonomyLayout = taxonomyLayout;
            CoverField = coverField;
            CoverPath = coverPath;
            WritesCoverInExtraTable = writesCoverInExtraTable;
            BodyMarkdown = bodyMarkdown ?? throw new ArgumentNullException(nameof(bodyMarkdown));
        }

        public FrontMatterDocumentSyntax Syntax { get; }

        public string Title { get; }

        public string FormattedDate { get; }

        public string? Slug { get; }

        public bool? DraftFlag { get; }

        public string? SummaryField { get; }

        public string? Summary { get; }

        public IReadOnlyList<string> Authors { get; }

        public IReadOnlyList<string> Tags { get; }

        public IReadOnlyList<string> Categories { get; }

        public FrontMatterTaxonomyLayout TaxonomyLayout { get; }

        public string? CoverField { get; }

        public string? CoverPath { get; }

        public bool WritesCoverInExtraTable { get; }

        public string BodyMarkdown { get; }

        private static IReadOnlyList<string> CopyCollection(
            IReadOnlyList<string> values,
            string parameterName)
        {
            if (values == null)
            {
                throw new ArgumentNullException(parameterName);
            }

            var copy = new List<string>(values.Count);
            for (int index = 0; index < values.Count; index++)
            {
                copy.Add(values[index] ?? throw new ArgumentNullException(parameterName));
            }

            return copy.AsReadOnly();
        }
    }

    public sealed class FrontMatterDocumentRenderer
    {
        public string Render(FrontMatterDocument document)
        {
            if (document == null)
            {
                throw new ArgumentNullException(nameof(document));
            }

            return document.Syntax == FrontMatterDocumentSyntax.Yaml
                ? RenderYaml(document)
                : RenderToml(document);
        }

        public string MarkdownDocument(FrontMatterDocument document)
        {
            if (document == null)
            {
                throw new ArgumentNullException(nameof(document));
            }

            return Render(document) + "\n\n" + document.BodyMarkdown.Trim() + "\n";
        }

        private static string RenderYaml(FrontMatterDocument document)
        {
            var lines = new List<string>
            {
                "---",
                "title: " + Quoted(document.Title),
                "date: " + Quoted(document.FormattedDate)
            };
            AppendCommonScalarFields(lines, document, ":");
            AppendYamlCollections(lines, document);
            if (document.DraftFlag.HasValue)
            {
                lines.Add("draft: " + (document.DraftFlag.Value ? "true" : "false"));
            }

            AppendSummary(lines, document, ":");
            AppendCover(lines, document, ":");
            lines.Add("---");
            return string.Join("\n", lines);
        }

        private static string RenderToml(FrontMatterDocument document)
        {
            var lines = new List<string>
            {
                "+++",
                "title = " + Quoted(document.Title),
                "date = " + document.FormattedDate
            };
            AppendCommonScalarFields(lines, document, "=");
            if (document.DraftFlag.HasValue)
            {
                lines.Add("draft = " + (document.DraftFlag.Value ? "true" : "false"));
            }

            AppendSummary(lines, document, "=");
            if (document.Authors.Count > 0)
            {
                lines.Add("authors = [" + QuotedList(document.Authors) + "]");
            }

            if (!document.WritesCoverInExtraTable)
            {
                AppendCover(lines, document, "=");
            }

            AppendTomlTaxonomies(lines, document);
            if (document.WritesCoverInExtraTable && document.CoverPath != null)
            {
                lines.Add("[extra]");
                lines.Add("og_preview_img = " + Quoted(document.CoverPath));
            }

            lines.Add("+++");
            return string.Join("\n", lines);
        }

        private static void AppendCommonScalarFields(
            List<string> lines,
            FrontMatterDocument document,
            string separator)
        {
            if (document.Slug != null)
            {
                lines.Add(Assignment("slug", Quoted(document.Slug), separator));
            }
        }

        private static void AppendYamlCollections(
            List<string> lines,
            FrontMatterDocument document)
        {
            if (document.Tags.Count > 0)
            {
                lines.Add("tags: [" + QuotedList(document.Tags) + "]");
            }

            if (document.Categories.Count > 0)
            {
                lines.Add("categories: [" + QuotedList(document.Categories) + "]");
            }

            if (document.Authors.Count > 0)
            {
                lines.Add("authors: [" + QuotedList(document.Authors) + "]");
            }
        }

        private static void AppendSummary(
            List<string> lines,
            FrontMatterDocument document,
            string separator)
        {
            if (document.SummaryField != null && document.Summary != null)
            {
                lines.Add(Assignment(document.SummaryField, Quoted(document.Summary), separator));
            }
        }

        private static void AppendCover(
            List<string> lines,
            FrontMatterDocument document,
            string separator)
        {
            if (document.CoverField != null && document.CoverPath != null)
            {
                lines.Add(Assignment(document.CoverField, Quoted(document.CoverPath), separator));
            }
        }

        private static void AppendTomlTaxonomies(
            List<string> lines,
            FrontMatterDocument document)
        {
            if (document.Tags.Count == 0 && document.Categories.Count == 0)
            {
                return;
            }

            if (document.TaxonomyLayout == FrontMatterTaxonomyLayout.InlineTable)
            {
                var entries = new List<string>();
                if (document.Tags.Count > 0)
                {
                    entries.Add("tags = [" + QuotedList(document.Tags) + "]");
                }

                if (document.Categories.Count > 0)
                {
                    entries.Add("categories = [" + QuotedList(document.Categories) + "]");
                }

                lines.Add("taxonomies = { " + string.Join(", ", entries) + " }");
            }
            else
            {
                lines.Add("[taxonomies]");
                if (document.Tags.Count > 0)
                {
                    lines.Add("tags = [" + QuotedList(document.Tags) + "]");
                }

                if (document.Categories.Count > 0)
                {
                    lines.Add("categories = [" + QuotedList(document.Categories) + "]");
                }
            }
        }

        private static string QuotedList(IReadOnlyList<string> values)
        {
            var quoted = new string[values.Count];
            for (int index = 0; index < values.Count; index++)
            {
                quoted[index] = Quoted(values[index]);
            }

            return string.Join(", ", quoted);
        }

        private static string Assignment(string field, string value, string separator)
        {
            return separator == ":"
                ? field + ": " + value
                : field + " = " + value;
        }

        private static string Quoted(string value)
        {
            return "\""
                + value
                    .Replace("\\", "\\\\")
                    .Replace("\"", "\\\"")
                    .Replace("\n", "\\n")
                    .Replace("\r", "\\r")
                    .Replace("\t", "\\t")
                + "\"";
        }
    }
}
