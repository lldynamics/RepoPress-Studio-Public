using System;
using System.Collections.Generic;

namespace RepoPress.Core
{
    public enum PublishConflictDiffLineKind
    {
        Same,
        Remote,
        Local
    }

    public sealed class PublishConflictDiffLine
    {
        public PublishConflictDiffLine(
            int id,
            PublishConflictDiffLineKind kind,
            string text)
        {
            if (id < 0)
            {
                throw new ArgumentOutOfRangeException(nameof(id));
            }

            Id = id;
            Kind = kind;
            Text = text ?? throw new ArgumentNullException(nameof(text));
        }

        public int Id { get; }

        public PublishConflictDiffLineKind Kind { get; }

        public string Text { get; }

        public string Marker
        {
            get
            {
                switch (Kind)
                {
                    case PublishConflictDiffLineKind.Same:
                        return " ";
                    case PublishConflictDiffLineKind.Remote:
                        return "-";
                    case PublishConflictDiffLineKind.Local:
                        return "+";
                    default:
                        throw new ArgumentOutOfRangeException();
                }
            }
        }
    }

    public sealed class PublishConflictDiffBuilder
    {
        public IReadOnlyList<PublishConflictDiffLine> Diff(string remote, string local)
        {
            if (remote == null)
            {
                throw new ArgumentNullException(nameof(remote));
            }

            if (local == null)
            {
                throw new ArgumentNullException(nameof(local));
            }

            List<string> remoteLines = SplitLines(remote);
            List<string> localLines = SplitLines(local);
            long cellCount = (long)remoteLines.Count * localLines.Count;
            if (cellCount > 250000L)
            {
                return CoarseDiff(remoteLines, localLines);
            }

            int[,] table = new int[remoteLines.Count + 1, localLines.Count + 1];
            for (int remoteIndex = remoteLines.Count - 1; remoteIndex >= 0; remoteIndex--)
            {
                for (int localIndex = localLines.Count - 1; localIndex >= 0; localIndex--)
                {
                    if (remoteLines[remoteIndex] == localLines[localIndex])
                    {
                        table[remoteIndex, localIndex] = table[remoteIndex + 1, localIndex + 1] + 1;
                    }
                    else
                    {
                        table[remoteIndex, localIndex] = Math.Max(
                            table[remoteIndex + 1, localIndex],
                            table[remoteIndex, localIndex + 1]);
                    }
                }
            }

            var result = new List<PublishConflictDiffLine>();
            int remotePosition = 0;
            int localPosition = 0;
            while (remotePosition < remoteLines.Count && localPosition < localLines.Count)
            {
                if (remoteLines[remotePosition] == localLines[localPosition])
                {
                    Append(result, PublishConflictDiffLineKind.Same, remoteLines[remotePosition]);
                    remotePosition++;
                    localPosition++;
                }
                else if (table[remotePosition + 1, localPosition]
                    >= table[remotePosition, localPosition + 1])
                {
                    Append(result, PublishConflictDiffLineKind.Remote, remoteLines[remotePosition]);
                    remotePosition++;
                }
                else
                {
                    Append(result, PublishConflictDiffLineKind.Local, localLines[localPosition]);
                    localPosition++;
                }
            }

            while (remotePosition < remoteLines.Count)
            {
                Append(result, PublishConflictDiffLineKind.Remote, remoteLines[remotePosition]);
                remotePosition++;
            }

            while (localPosition < localLines.Count)
            {
                Append(result, PublishConflictDiffLineKind.Local, localLines[localPosition]);
                localPosition++;
            }

            return result;
        }

        private static IReadOnlyList<PublishConflictDiffLine> CoarseDiff(
            IReadOnlyList<string> remoteLines,
            IReadOnlyList<string> localLines)
        {
            var result = new List<PublishConflictDiffLine>(remoteLines.Count + localLines.Count);
            for (int index = 0; index < remoteLines.Count; index++)
            {
                Append(result, PublishConflictDiffLineKind.Remote, remoteLines[index]);
            }

            for (int index = 0; index < localLines.Count; index++)
            {
                Append(result, PublishConflictDiffLineKind.Local, localLines[index]);
            }

            return result;
        }

        private static void Append(
            List<PublishConflictDiffLine> result,
            PublishConflictDiffLineKind kind,
            string text)
        {
            result.Add(new PublishConflictDiffLine(result.Count, kind, text));
        }

        private static List<string> SplitLines(string value)
        {
            var result = new List<string>();
            int start = 0;
            for (int index = 0; index < value.Length; index++)
            {
                if (!IsNewline(value[index]))
                {
                    continue;
                }

                result.Add(value.Substring(start, index - start));
                start = index + 1;
            }

            result.Add(value.Substring(start));
            return result;
        }

        private static bool IsNewline(char value)
        {
            return value == '\u000A'
                || value == '\u000B'
                || value == '\u000C'
                || value == '\u000D'
                || value == '\u0085'
                || value == '\u2028'
                || value == '\u2029';
        }
    }
}
