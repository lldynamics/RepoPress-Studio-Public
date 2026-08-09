using System;
using System.Collections.Generic;
using System.Text;

namespace RepoPress.Core
{
    public sealed class RepositoryQueryItem
    {
        public RepositoryQueryItem(string name, string? value)
        {
            Name = name ?? throw new ArgumentNullException(nameof(name));
            Value = value;
        }

        public string Name { get; }

        public string? Value { get; }
    }

    public sealed class RepositoryEndpointException : ArgumentException
    {
        public const string InvalidUrlErrorCode = "repository_endpoint.invalid_url";

        public RepositoryEndpointException()
            : base(InvalidUrlErrorCode)
        {
            ErrorCode = InvalidUrlErrorCode;
        }

        public string ErrorCode { get; }
    }

    public sealed class RepositoryEndpoint
    {
        private RepositoryEndpoint(string baseUrl)
        {
            BaseUrl = baseUrl;
        }

        public string BaseUrl { get; }

        public static RepositoryEndpoint Validate(string baseUrl)
        {
            if (baseUrl == null)
            {
                throw new RepositoryEndpointException();
            }

            string trimmed = baseUrl.Trim();
            if (!Uri.TryCreate(trimmed, UriKind.Absolute, out Uri? uri)
                || !string.Equals(uri.Scheme, Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase)
                || string.IsNullOrEmpty(uri.Host)
                || !string.IsNullOrEmpty(uri.UserInfo)
                || !string.IsNullOrEmpty(uri.Query)
                || !string.IsNullOrEmpty(uri.Fragment))
            {
                throw new RepositoryEndpointException();
            }

            return new RepositoryEndpoint(trimmed);
        }

        public string BuildUrl(
            string path,
            IReadOnlyList<RepositoryQueryItem>? queryItems = null)
        {
            if (path == null)
            {
                throw new ArgumentNullException(nameof(path));
            }

            string authority = GetAuthority(BaseUrl);
            string basePath = GetRawPath(BaseUrl).Trim('/');
            string requestPath = path.Trim('/');
            var pathParts = new List<string>(2);
            if (basePath.Length > 0)
            {
                pathParts.Add(basePath);
            }

            if (requestPath.Length > 0)
            {
                pathParts.Add(requestPath);
            }

            // URLComponents in the Swift implementation always assigns a
            // slash-prefixed percent-encoded path, including for an empty join.
            string joinedPath = "/" + EncodePath(string.Join("/", pathParts));
            if (joinedPath.Length == 1 && pathParts.Count == 0)
            {
                joinedPath = "/";
            }

            var result = new StringBuilder(authority.Length + joinedPath.Length + 1);
            result.Append(authority);
            result.Append(joinedPath);

            if (queryItems != null && queryItems.Count > 0)
            {
                result.Append('?');
                for (int index = 0; index < queryItems.Count; index++)
                {
                    if (index > 0)
                    {
                        result.Append('&');
                    }

                    RepositoryQueryItem item = queryItems[index]
                        ?? throw new ArgumentNullException(nameof(queryItems));
                    result.Append(PercentEncode(item.Name));
                    if (item.Value != null)
                    {
                        result.Append('=');
                        result.Append(PercentEncode(item.Value));
                    }
                }
            }

            return result.ToString();
        }

        private static string GetAuthority(string baseUrl)
        {
            int schemeSeparator = baseUrl.IndexOf("://", StringComparison.Ordinal);
            if (schemeSeparator < 0)
            {
                throw new RepositoryEndpointException();
            }

            int authorityStart = schemeSeparator + 3;
            int pathStart = baseUrl.IndexOf('/', authorityStart);
            return pathStart < 0 ? baseUrl : baseUrl.Substring(0, pathStart);
        }

        private static string GetRawPath(string baseUrl)
        {
            int schemeSeparator = baseUrl.IndexOf("://", StringComparison.Ordinal);
            int authorityStart = schemeSeparator < 0 ? 0 : schemeSeparator + 3;
            int pathStart = baseUrl.IndexOf('/', authorityStart);
            return pathStart < 0 ? string.Empty : baseUrl.Substring(pathStart);
        }

        private static string EncodePath(string value)
        {
            byte[] bytes = Encoding.UTF8.GetBytes(value);
            var builder = new StringBuilder(value.Length);
            for (int index = 0; index < bytes.Length; index++)
            {
                byte current = bytes[index];
                if (current == (byte)'%' && index + 2 < bytes.Length
                    && IsHex(bytes[index + 1]) && IsHex(bytes[index + 2]))
                {
                    builder.Append('%');
                    builder.Append((char)bytes[index + 1]);
                    builder.Append((char)bytes[index + 2]);
                    index += 2;
                }
                else if (IsPathCharacter(current))
                {
                    builder.Append((char)current);
                }
                else
                {
                    AppendPercentByte(builder, current);
                }
            }

            return builder.ToString();
        }

        private static string PercentEncode(string value)
        {
            byte[] bytes = Encoding.UTF8.GetBytes(value);
            var builder = new StringBuilder(value.Length);
            foreach (byte current in bytes)
            {
                if (IsUnreserved(current))
                {
                    builder.Append((char)current);
                }
                else
                {
                    AppendPercentByte(builder, current);
                }
            }

            return builder.ToString();
        }

        private static bool IsPathCharacter(byte value)
        {
            return IsUnreserved(value)
                || value == (byte)'/'
                || value == (byte)':'
                || value == (byte)'@'
                || value == (byte)'!'
                || value == (byte)'$'
                || value == (byte)'&'
                || value == (byte)'\''
                || value == (byte)'('
                || value == (byte)')'
                || value == (byte)'*'
                || value == (byte)'+'
                || value == (byte)','
                || value == (byte)';'
                || value == (byte)'=';
        }

        private static bool IsUnreserved(byte value)
        {
            return value >= (byte)'A' && value <= (byte)'Z'
                || value >= (byte)'a' && value <= (byte)'z'
                || value >= (byte)'0' && value <= (byte)'9'
                || value == (byte)'-'
                || value == (byte)'.'
                || value == (byte)'_'
                || value == (byte)'~';
        }

        private static bool IsHex(byte value)
        {
            return value >= (byte)'0' && value <= (byte)'9'
                || value >= (byte)'A' && value <= (byte)'F'
                || value >= (byte)'a' && value <= (byte)'f';
        }

        private static void AppendPercentByte(StringBuilder builder, byte value)
        {
            const string Hex = "0123456789ABCDEF";
            builder.Append('%');
            builder.Append(Hex[value >> 4]);
            builder.Append(Hex[value & 0x0F]);
        }
    }
}
