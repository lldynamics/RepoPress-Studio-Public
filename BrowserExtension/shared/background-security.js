const ARCHIVE_RESOURCE_PEER_GUARD_TTL_MS = 8_000;
const archiveResourcePeerGuards = [];

function archiveResourcePolicyError(message, code = "archive-resource-blocked") {
  const error = new Error(message);
  error.code = code;
  return error;
}

function normalizedArchiveResourceURL(value) {
  let url;
  try {
    url = new URL(String(value || ""));
  } catch {
    throw archiveResourcePolicyError("离线资源网址无效。");
  }
  if (!['http:', 'https:'].includes(url.protocol.toLowerCase())
      || !url.hostname
      || url.username
      || url.password) {
    throw archiveResourcePolicyError("离线资源只允许无凭据的 HTTP 或 HTTPS 网址。");
  }
  url.hash = "";
  return url;
}

function parsedArchiveIPv4(value) {
  const parts = String(value || "").split(".");
  if (parts.length !== 4 || parts.some((part) => !/^\d{1,3}$/.test(part))) return null;
  const numbers = parts.map(Number);
  return numbers.every((part) => part >= 0 && part <= 255) ? numbers : null;
}

function parsedArchiveIPv6(value) {
  let input = String(value || "").toLowerCase();
  if (input.startsWith("[") && input.endsWith("]")) input = input.slice(1, -1);
  if (!input.includes(":") || input.includes("%")) return null;
  let ipv4Words = [];
  const ipv4Match = input.match(/(?:^|:)(\d{1,3}(?:\.\d{1,3}){3})$/);
  if (ipv4Match) {
    const ipv4 = parsedArchiveIPv4(ipv4Match[1]);
    if (!ipv4) return null;
    ipv4Words = [(ipv4[0] << 8) | ipv4[1], (ipv4[2] << 8) | ipv4[3]];
    input = input.slice(0, -ipv4Match[1].length).replace(/:$/, "");
  }
  if ((input.match(/::/g) || []).length > 1) return null;
  const [leftText, rightText] = input.split("::");
  const parseSide = (text) => text
    ? text.split(":").map((part) => /^[0-9a-f]{1,4}$/.test(part) ? Number.parseInt(part, 16) : NaN)
    : [];
  const left = parseSide(leftText);
  const right = parseSide(rightText);
  if ([...left, ...right].some((part) => !Number.isInteger(part))) return null;
  const expectedHextets = 8 - ipv4Words.length;
  let words;
  if (input.includes("::")) {
    const zeros = expectedHextets - left.length - right.length;
    if (zeros < 1) return null;
    words = [...left, ...Array(zeros).fill(0), ...right, ...ipv4Words];
  } else {
    words = [...left, ...ipv4Words];
  }
  return words.length === 8 ? words : null;
}

function isBlockedArchiveIPv4(parts) {
  if (!parts) return true;
  const [a, b, c] = parts;
  return a === 0
    || a === 10
    || a === 127
    || (a === 100 && b >= 64 && b <= 127)
    || (a === 169 && b === 254)
    || (a === 172 && b >= 16 && b <= 31)
    || (a === 192 && b === 0)
    || (a === 192 && b === 168)
    || (a === 192 && b === 88 && c === 99)
    || (a === 198 && (b === 18 || b === 19))
    || (a === 198 && b === 51 && c === 100)
    || (a === 203 && b === 0 && c === 113)
    || a >= 224;
}

function isBlockedArchiveIPv6(words) {
  if (!words) return true;
  const isUnspecified = words.every((word) => word === 0);
  const isLoopback = words.slice(0, 7).every((word) => word === 0) && words[7] === 1;
  if (isUnspecified || isLoopback) return true;
  const isIPv4Mapped = words.slice(0, 5).every((word) => word === 0)
    && words[5] === 0xffff;
  if (isIPv4Mapped) {
    return isBlockedArchiveIPv4([
      words[6] >> 8,
      words[6] & 0xff,
      words[7] >> 8,
      words[7] & 0xff
    ]);
  }
  const first = words[0];
  if ((first & 0xfe00) === 0xfc00
      || (first & 0xffc0) === 0xfe80
      || (first & 0xffc0) === 0xfec0
      || (first & 0xff00) === 0xff00) return true;
  if (words[0] === 0x2001
      && [0x0000, 0x0002, 0x0010, 0x0020, 0x0db8].includes(words[1])) return true;
  if (words[0] === 0x2002) return true;
  return (first & 0xe000) !== 0x2000;
}

function isBlockedArchiveHostname(value) {
  let hostname = String(value || "").trim().toLowerCase();
  if (hostname.startsWith("[") && hostname.endsWith("]")) hostname = hostname.slice(1, -1);
  hostname = hostname.replace(/\.$/, "");
  if (!hostname || hostname === "localhost") return true;
  const ipv4 = parsedArchiveIPv4(hostname);
  if (ipv4) return isBlockedArchiveIPv4(ipv4);
  if (hostname.includes(":")) return isBlockedArchiveIPv6(parsedArchiveIPv6(hostname));
  if (!hostname.includes(".")
      || [".localhost", ".local", ".internal", ".home", ".lan", ".onion"]
        .some((suffix) => hostname.endsWith(suffix))) return true;
  return false;
}

function archiveAddressKey(value) {
  const hostname = String(value || "").trim().toLowerCase().replace(/^\[|\]$/g, "");
  const ipv4 = parsedArchiveIPv4(hostname);
  if (ipv4) return `4:${ipv4.join(".")}`;
  const ipv6 = parsedArchiveIPv6(hostname);
  if (ipv6) return `6:${ipv6.map((word) => word.toString(16)).join(":")}`;
  return null;
}

function normalizedArchivePeerGuardURL(value) {
  try {
    return normalizedArchiveResourceURL(value).href;
  } catch {
    return null;
  }
}

function purgeArchiveResourcePeerGuards(now = Date.now()) {
  for (let index = archiveResourcePeerGuards.length - 1; index >= 0; index -= 1) {
    if (archiveResourcePeerGuards[index].expiresAt <= now) {
      archiveResourcePeerGuards.splice(index, 1);
    }
  }
}

function guardArchiveResourcePeer(url, tabID, addresses) {
  purgeArchiveResourcePeerGuards();
  const guardID = newOperationID();
  archiveResourcePeerGuards.push({
    guardID,
    url,
    tabID,
    addresses: new Set(addresses),
    consumed: false,
    verified: false,
    expiresAt: Date.now() + ARCHIVE_RESOURCE_PEER_GUARD_TTL_MS
  });
  return guardID;
}

function handleArchiveResourceResponseHeaders(details) {
  purgeArchiveResourcePeerGuards();
  const url = normalizedArchivePeerGuardURL(details?.url);
  const tabID = Number(details?.tabId);
  if (!url || !Number.isInteger(tabID)) return {};
  const pending = archiveResourcePeerGuards.find(
    (guard) => guard.url === url && guard.tabID === tabID && !guard.consumed
  );
  if (pending) {
    pending.consumed = true;
    const peerAddress = archiveAddressKey(details?.ip);
    pending.verified = Boolean(peerAddress && pending.addresses.has(peerAddress));
    return pending.verified ? {} : { cancel: true };
  }
  const alreadyConsumed = archiveResourcePeerGuards.some(
    (guard) => guard.url === url && guard.tabID === tabID && guard.consumed
  );
  return alreadyConsumed ? { cancel: true } : {};
}

function installArchiveResourcePeerGuard() {
  const responseEvent = extensionAPI.webRequest?.onHeadersReceived;
  if (!extensionAPI.dns?.resolve || !responseEvent?.addListener) return false;
  try {
    responseEvent.addListener(
      handleArchiveResourceResponseHeaders,
      {
        urls: ["http://*/*", "https://*/*"],
        types: ["xmlhttprequest"]
      },
      ["blocking"]
    );
    return true;
  } catch {
    return false;
  }
}

const archiveResourcePeerGuardAvailable = installArchiveResourcePeerGuard();

async function confirmArchiveResourcePeer(value, guardIDValue, sender = null) {
  purgeArchiveResourcePeerGuards();
  const url = normalizedArchivePeerGuardURL(value);
  const guardID = normalizedOperationID(guardIDValue);
  const tabID = Number(sender?.tab?.id);
  const guardIndex = archiveResourcePeerGuards.findIndex(
    (guard) => guard.guardID === guardID && guard.url === url && guard.tabID === tabID
  );
  if (guardIndex < 0) {
    throw archiveResourcePolicyError(
      "离线资源的对端校验回执无效，已停止读取。",
      "archive-resource-peer-unverified"
    );
  }
  const guard = archiveResourcePeerGuards[guardIndex];
  archiveResourcePeerGuards.splice(guardIndex, 1);
  if (!guard.consumed || !guard.verified) {
    throw archiveResourcePolicyError(
      "浏览器未能核对离线资源的真实对端，已停止读取。",
      "archive-resource-peer-unverified"
    );
  }
  return { verified: true };
}

async function validateArchiveResourceURL(value, sender = null) {
  const url = normalizedArchiveResourceURL(value);
  if (isBlockedArchiveHostname(url.hostname)) {
    throw archiveResourcePolicyError("离线归档已阻止私网、回环或保留地址。");
  }
  const literalHostname = url.hostname.replace(/^\[|\]$/g, "");
  if (parsedArchiveIPv4(literalHostname) || parsedArchiveIPv6(literalHostname)) {
    return {
      allowed: true,
      url: url.href,
      validationMode: "literal",
      peerGuarded: false
    };
  }
  const dnsAPI = extensionAPI.dns;
  const tabID = Number(sender?.tab?.id);
  if (!dnsAPI?.resolve || !archiveResourcePeerGuardAvailable || !Number.isInteger(tabID)) {
    throw archiveResourcePolicyError(
      "当前浏览器无法核对离线资源的真实对端，已停止下载。",
      "archive-resource-peer-unavailable"
    );
  }
  let record;
  try {
    record = await dnsAPI.resolve(url.hostname, ["bypass_cache"]);
  } catch {
    throw archiveResourcePolicyError(
      "Firefox 无法验证离线资源的 DNS 地址，已停止下载。",
      "archive-resource-dns-failed"
    );
  }
  const addresses = Array.isArray(record?.addresses) ? record.addresses : [];
  const addressKeys = addresses.map(archiveAddressKey);
  if (!addressKeys.length
      || addressKeys.some((address) => !address)
      || addresses.some((address) => isBlockedArchiveHostname(address))) {
    throw archiveResourcePolicyError("离线归档已阻止解析到私网或保留地址的资源。");
  }
  const guardID = guardArchiveResourcePeer(url.href, tabID, addressKeys);
  return {
    allowed: true,
    url: url.href,
    validationMode: "resolved",
    peerGuarded: true,
    peerGuardID: guardID
  };
}
