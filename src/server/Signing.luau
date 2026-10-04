--!nonstrict
-- Signed prod messages (kernel 0.3; plans/01 "Signed deploys", format in plans/03 "Signed prod messages").
--
-- Trust roots, read ONCE at boot from the kernel folder's attributes (stamped by `typetorch kernel deploy`), before any
-- payload runs, so game code can't change them later:
--   * KeyAssetId: a group-owned Model whose attributes PublicKeys / RevokedKeys are comma-separated base64 Ed25519
--     public keys. Re-read on a rekey hint, about every 10 minutes and once after a failed signature (rate-limited);
--     the last good lists stay in memory, and a failed read keeps them.
--   * FallbackPublicKey: one base64 Ed25519 public key baked into the place.
--   * BootstrapHeads: JSON {"<branch>": {"a": assetId, "s": seq, "i": "artifactId"}}, the prod heads at the time of the
--     kernel deploy. A prod server trusts an UNSIGNED head only when it matches one exactly (branch, asset, seq), and
--     boots the bootstrap head itself when it has no verified one; anything newer must be signed.
-- The rule (user decision 2026-10-04, strict):
--   * once the key asset has loaded on this server, only `sig` counts, checked against PublicKeys minus RevokedKeys
--     (`sigF` is ignored);
--   * until then, only `sigF` counts, checked against FallbackPublicKey (the key asset, once readable, can revoke it,
--     and from then on `sig` is required anyway).
-- Signatures are base64 of the 64-byte Ed25519 signature of a canonical string (UTF-8, fields joined by "\n"):
--   deploy messages and branch heads: tt1 \n b \n a \n i \n s \n c \n ch \n t \n r
--   pin messages (TypeTorch/pin):     tt1pin \n b \n a \n jobs \n pct \n by \n t \n unpin
-- Integers in base 10 (string.format("%d"): no sign, exponent, leading zeros or fraction); `r` is "1" (rollback),
-- "resign" (the CLI re-signed the head after `keys rotate`: same asset, new seq) or ""; `unpin` is "1" or ""; absent
-- optional fields are ""; `jobs` is the job ids joined by "," in message order.
--
-- The Roblox parts (attributes, InsertService) are injected through Signing.init / Signing.configure, so the pure
-- parts run under Lune: scripts/test-ed25519.luau and scripts/test-signing.luau.

local Ed25519 = require("./vendor/ed25519/Ed25519")
local SHA256 = require("./vendor/ed25519/SHA256")

local Signing = {}

local DEPLOY_TAG = "tt1"
local PIN_TAG = "tt1pin"

-- Minimum seconds between two key asset reads, by reason. Rekey hints are unsigned (anyone in the universe can send
-- one) and failed signatures can be provoked, so both are rate-limited; a hint inside the window is not lost (the
-- kernel retries it when the window ends, see Signing.hintDue).
local MIN_INTERVAL = { boot = 0, hint = 30, failure = 60, periodic = 300, manual = 30 }
Signing.PERIODIC_SECONDS = 600
Signing.MIN_INTERVAL = MIN_INTERVAL

-- Base64 (standard alphabet, padded) ---------------------------------------------------------------------------------

local DECODE = {}
do
	local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
	for index = 1, #alphabet do
		DECODE[string.byte(alphabet, index)] = index - 1
	end
end

-- Strict decode: length a multiple of 4, padding only at the end. Returns nil for anything else.
function Signing.base64Decode(text: any): buffer?
	if typeof(text) ~= "string" or #text == 0 or #text % 4 ~= 0 then
		return nil
	end
	local padding = 0
	if string.sub(text, -2) == "==" then
		padding = 2
	elseif string.sub(text, -1) == "=" then
		padding = 1
	end
	local length = #text // 4 * 3 - padding
	local out = buffer.create(length)
	local written = 0
	for index = 1, #text, 4 do
		local a, b, c, d = string.byte(text, index, index + 3)
		local last = index + 3 == #text
		local va, vb = DECODE[a], DECODE[b]
		local vc = if last and padding == 2 then 0 else DECODE[c]
		local vd = if last and padding >= 1 then 0 else DECODE[d]
		if va == nil or vb == nil or vc == nil or vd == nil then
			return nil
		end
		local triple = va * 262144 + vb * 4096 + vc * 64 + vd
		for shift = 16, 0, -8 do
			if written < length then
				buffer.writeu8(out, written, bit32.band(bit32.rshift(triple, shift), 0xFF))
				written += 1
			end
		end
	end
	return out
end

-- Canonical strings ------------------------------------------------------------------------------------------------

local function decimal(value: any): string?
	if typeof(value) ~= "number" or value ~= value or value < 0 or value % 1 ~= 0 or value > 2 ^ 53 then
		return nil
	end
	return string.format("%d", value)
end

local function plain(value: any): string?
	if typeof(value) ~= "string" or string.find(value, "\n", 1, true) then
		return nil
	end
	return value
end

-- The signed string of a deploy message ({b, a, i, s, c, ch, t, r?}); nil and a reason when a field is missing or bad.
function Signing.deployCanonical(fields): (string?, string?)
	local b, a, i, s, c, ch, t = plain(fields.b), decimal(fields.a), plain(fields.i), decimal(fields.s), plain(fields.c), plain(fields.ch), decimal(fields.t)
	if not (b and a and i and s and c and ch and t) then
		return nil, "missing or bad signed field (b, a, i, s, c, ch, t)"
	end
	-- `r`: 1 for a rollback, "resign" for a head the CLI re-signed after `keys rotate` (same asset, new seq), else absent.
	local r = if fields.r == "resign" then "resign" elseif fields.r == 1 or fields.r == true then "1" elseif fields.r == nil then "" else nil
	if not r then
		return nil, "bad r"
	end
	return table.concat({ DEPLOY_TAG, b, a, i, s, c, ch, t, r }, "\n"), nil
end

-- The deploy fields of a stored branch head ({assetId, artifactId, seq, commit, channel, t, rollback?}) on `branch`.
function Signing.headFields(branch: string, head)
	return {
		b = branch,
		a = head.assetId,
		i = head.artifactId,
		s = head.seq,
		c = head.commit,
		ch = head.channel,
		t = head.t,
		r = if head.r == "resign" then "resign" elseif head.r == 1 or head.rollback == true then 1 else nil,
	}
end

-- The signed string of a pin message ({j?, pct?, a?, b, by, t, unpin?}).
function Signing.pinCanonical(fields): (string?, string?)
	local jobs = ""
	if fields.j ~= nil then
		if typeof(fields.j) ~= "table" then
			return nil, "bad j"
		end
		local list = {}
		for index, jobId in fields.j do
			if typeof(index) ~= "number" or typeof(jobId) ~= "string" or string.find(jobId, "[,\n]") then
				return nil, "bad j"
			end
			list[index] = jobId
		end
		jobs = table.concat(list, ",")
	end
	local pct = if fields.pct == nil then "" else decimal(fields.pct)
	local a = if fields.a == nil then "" else decimal(fields.a)
	local b, by, t = plain(fields.b), decimal(fields.by), decimal(fields.t)
	local unpin = if fields.unpin == true then "1" elseif fields.unpin == nil or fields.unpin == false then "" else nil
	if not (pct and a and b and by and t and unpin) then
		return nil, "missing or bad signed field (pct, a, b, by, t, unpin)"
	end
	-- The user's format (2026-10-04): tt1pin \n b \n a \n jobs \n pct \n by \n t \n unpin.
	return table.concat({ PIN_TAG, b, a, jobs, pct, by, t, unpin }, "\n"), nil
end

-- A key's short fingerprint: the first 8 hex digits of the SHA-256 of its raw 32 bytes (the CLI prints the same).
function Signing.fingerprint(key: buffer): string
	return string.sub((SHA256(key)), 1, 8)
end

-- Trust roots and the key asset -------------------------------------------------------------------------------------

local keyAssetId: number? = nil
local fallbackKey: buffer? = nil
local fallbackText: string? = nil
local configError: string? = nil

local loaded = false -- the key asset has loaded on this server at least once
local activeKeys: { { bytes: buffer, text: string } } = {} -- PublicKeys minus RevokedKeys
local publicTexts: { string } = {} -- normalized, sorted
local revokedTexts: { string } = {}
local revokedSet: { [string]: boolean } = {} -- raw key bytes (as a string) -> true
local loadedVersion: number? = nil
local loadedAt: number? = nil -- unix seconds
local lastReadAt = -math.huge -- clock of the last read attempt
local lastReadOk: boolean? = nil
local lastReadError: string? = nil
local lastReadErrorAt: number? = nil -- unix seconds
local lastHintAt: number? = nil -- unix seconds of the last rekey hint heard
local reads = 0
local changes: { any } = {} -- newest last, at most 10
local invalidKeys: { string } = {}
local fallbackRevoked = false
local hintPending = false
local fingerprints: { [string]: string } = {} -- base64 text -> fingerprint

-- A rekey hint within this many seconds before a detected change marks it as "hinted" (likely the user's rotation:
-- `typetorch keys rotate` sends one). Hints are unsigned, so this is a hint for people, not a security check.
local HINT_WINDOW = 900

-- Verify results by message, so re-checking the same stored head every poll costs nothing. Cleared on key changes.
local verdicts: { [string]: { ok: boolean, why: string?, by: string? } } = {}
local verdictCount = 0
-- Signing.signatures results (dev menu badges), same lifetime as the verdicts.
local badgeCache: { [string]: any } = {}
local badgeCount = 0

-- Injected for Lune tests; Roblox defaults in Signing.init.
local hooks = {
	now = os.clock,
	unixNow = os.time,
	warn = function(text: string)
		print(text)
	end,
	print = print,
	logEvent = function(_entry) end,
	-- loadKeys(assetId, knownVersion) -> (true, {publicKeys: string, revokedKeys: string, version: number?,
	-- unchanged: boolean?}) or (false, error)
	loadKeys = nil :: any,
}

function Signing.configure(overrides)
	for key, value in overrides do
		hooks[key] = value
	end
end

-- BootstrapHeads, parsed: branch -> { assetId, seq, artifactId? }.
local bootstrapHeads: { [string]: { assetId: number, seq: number, artifactId: string? } } = {}

local function wholeNumber(value): boolean
	return typeof(value) == "number" and value == value and value >= 0 and value % 1 == 0 and value <= 2 ^ 53
end

-- Reads the trust roots from the kernel folder's attributes. Call once, at boot, before any payload runs.
-- `folder` is anything with GetAttribute (a table in tests); `decodeJson` parses BootstrapHeads (HttpService in Roblox).
function Signing.init(folder, decodeJson: ((string) -> any)?)
	bootstrapHeads = {}
	local rawBootstrap = folder:GetAttribute("BootstrapHeads")
	local bootstrapError = nil
	if typeof(rawBootstrap) == "string" and rawBootstrap ~= "" and decodeJson then
		local ok, decoded = pcall(decodeJson, rawBootstrap)
		if ok and typeof(decoded) == "table" then
			for branch, entry in decoded do
				if typeof(branch) == "string" and typeof(entry) == "table" and wholeNumber(entry.a) and entry.a > 0 and wholeNumber(entry.s) then
					bootstrapHeads[branch] = {
						assetId = entry.a,
						seq = entry.s,
						artifactId = if typeof(entry.i) == "string" then entry.i else nil,
					}
				else
					bootstrapError = `BootstrapHeads entry {tostring(branch)} is not {"{"}a, s, i{"}"}`
				end
			end
		else
			bootstrapError = "BootstrapHeads is not JSON"
		end
	end
	local rawId = folder:GetAttribute("KeyAssetId")
	local id = if typeof(rawId) == "number" then rawId elseif typeof(rawId) == "string" and rawId ~= "" then tonumber(rawId) else nil
	if id ~= nil and (id <= 0 or id % 1 ~= 0) then
		id = nil
	end
	keyAssetId = id
	local rawFallback = folder:GetAttribute("FallbackPublicKey")
	fallbackKey, fallbackText = nil, nil
	configError = nil
	if typeof(rawFallback) == "string" and rawFallback ~= "" then
		local text = string.gsub(rawFallback, "%s", "")
		local decoded = Signing.base64Decode(text)
		if decoded and buffer.len(decoded) == 32 then
			fallbackKey, fallbackText = decoded, text
			fingerprints[text] = Signing.fingerprint(decoded)
		else
			configError = "FallbackPublicKey is not base64 of a 32-byte key"
		end
	end
	if rawId ~= nil and rawId ~= "" and not keyAssetId then
		configError = (if configError then configError .. "; " else "") .. "KeyAssetId is not an asset id"
	end
	if bootstrapError then
		configError = (if configError then configError .. "; " else "") .. bootstrapError
	end
	return keyAssetId, fallbackText
end

-- The bootstrap head of `branch` ({ assetId, seq, artifactId? }, a copy) or nil.
function Signing.bootstrapHead(branch: string)
	local entry = bootstrapHeads[branch]
	return if entry then table.clone(entry) else nil
end

-- Whether `head` is exactly `branch`'s bootstrap head (same asset, seq and, when the entry has one, artifact id; plans/03
-- "Bootstrap heads"): the only unsigned head a prod server takes.
function Signing.matchesBootstrap(branch: string, head): boolean
	local entry = bootstrapHeads[branch]
	return entry ~= nil
		and typeof(head) == "table"
		and head.assetId == entry.assetId
		and head.seq == entry.seq
		and (entry.artifactId == nil or head.artifactId == entry.artifactId)
end

-- Parses "k1, k2,k3" into (keys {bytes,text}, invalid texts).
local function parseKeys(text: string)
	local keys, invalid, seen = {}, {}, {}
	for _, part in string.split(text, ",") do
		local trimmed = string.gsub(part, "%s", "")
		if trimmed ~= "" then
			local decoded = Signing.base64Decode(trimmed)
			if decoded and buffer.len(decoded) == 32 then
				local raw = buffer.tostring(decoded)
				if not seen[raw] then
					seen[raw] = true
					fingerprints[trimmed] = fingerprints[trimmed] or Signing.fingerprint(decoded)
					table.insert(keys, { bytes = decoded, text = trimmed })
				end
			else
				table.insert(invalid, trimmed)
			end
		end
	end
	return keys, invalid
end

local function textsOf(keys): { string }
	local list = {}
	for _, key in keys do
		table.insert(list, key.text)
	end
	table.sort(list)
	return list
end

local function difference(a: { string }, b: { string }): { string }
	local inB = {}
	for _, text in b do
		inB[text] = true
	end
	local out = {}
	for _, text in a do
		if not inB[text] then
			table.insert(out, text)
		end
	end
	return out
end

local function sameList(a: { string }, b: { string }): boolean
	if #a ~= #b then
		return false
	end
	for index = 1, #a do
		if a[index] ~= b[index] then
			return false
		end
	end
	return true
end

local function fingerprintsOf(texts: { string }): { string }
	local list = {}
	for index, text in texts do
		list[index] = fingerprints[text] or "?"
	end
	return list
end

local function adopt(result, reason: string)
	local publicKeys, invalidPublic = parseKeys(result.publicKeys or "")
	local revoked, invalidRevoked = parseKeys(result.revokedKeys or "")
	local newRevokedSet = {}
	for _, key in revoked do
		newRevokedSet[buffer.tostring(key.bytes)] = true
	end
	local active = {}
	for _, key in publicKeys do
		if not newRevokedSet[buffer.tostring(key.bytes)] then
			table.insert(active, key)
		end
	end
	local newPublic, newRevoked = textsOf(publicKeys), textsOf(revoked)
	local changed = not loaded or not sameList(newPublic, publicTexts) or not sameList(newRevoked, revokedTexts)
	if loaded and changed then
		-- Detection (user decision 5): a rotation the user didn't do shows up here, in the events and in keys().
		local now = hooks.unixNow()
		local change = {
			at = now,
			reason = reason,
			-- A rekey hint came shortly before (likely the user's own `typetorch keys rotate`).
			hinted = lastHintAt ~= nil and now - lastHintAt <= HINT_WINDOW,
			version = result.version,
			previousVersion = loadedVersion,
			added = difference(newPublic, publicTexts),
			removed = difference(publicTexts, newPublic),
			revokedAdded = difference(newRevoked, revokedTexts),
			revokedRemoved = difference(revokedTexts, newRevoked),
			before = { publicKeys = fingerprintsOf(publicTexts), revokedKeys = fingerprintsOf(revokedTexts) },
			after = { publicKeys = fingerprintsOf(newPublic), revokedKeys = fingerprintsOf(newRevoked) },
		}
		table.insert(changes, change)
		while #changes > 10 do
			table.remove(changes, 1)
		end
		hooks.warn(
			`[TypeTorch] the key asset {keyAssetId} CHANGED (version {loadedVersion or "?"} -> {result.version or "?"}{if change.hinted then ", after a rekey hint" else ", NO rekey hint"}): public keys [{table.concat(change.before.publicKeys, " ")}] -> [{table.concat(change.after.publicKeys, " ")}], revoked [{table.concat(change.before.revokedKeys, " ")}] -> [{table.concat(change.after.revokedKeys, " ")}]. If you did not rotate keys, check who can edit asset {keyAssetId}.`
		)
		hooks.logEvent({
			action = "keys_changed",
			keyAssetId = keyAssetId,
			reason = reason,
			hinted = change.hinted,
			version = result.version,
			previousVersion = loadedVersion,
			before = change.before,
			after = change.after,
		})
	end
	if changed then
		table.clear(verdicts)
		table.clear(badgeCache)
		badgeCount = 0
		verdictCount = 0
	end
	activeKeys = active
	publicTexts, revokedTexts = newPublic, newRevoked
	revokedSet = newRevokedSet
	invalidKeys = {}
	for _, list in { invalidPublic, invalidRevoked } do
		for _, text in list do
			table.insert(invalidKeys, text)
		end
	end
	if #invalidKeys > 0 then
		hooks.warn(`[TypeTorch] key asset {keyAssetId}: {#invalidKeys} entries are not base64 Ed25519 keys and were skipped`)
	end
	fallbackRevoked = fallbackKey ~= nil and newRevokedSet[buffer.tostring(fallbackKey)] == true
	if not loaded then
		hooks.print(`[TypeTorch] key asset {keyAssetId} loaded (version {result.version or "?"}): {#active} trusted keys, {#revoked} revoked{if fallbackRevoked then ", the fallback key is revoked" else ""}`)
	end
	if #active == 0 then
		hooks.warn(`[TypeTorch] key asset {keyAssetId} lists no usable public key: prod servers refuse every deploy until it does`)
	end
	loaded = true
	loadedVersion = result.version
	loadedAt = hooks.unixNow()
	return changed
end

-- Re-reads the key asset (yields) unless `reason`'s rate limit says no. Returns (read, changed). A failed read keeps
-- the last good keys. Reasons: "boot", "hint", "failure", "periodic", "manual".
function Signing.refresh(reason: string): (boolean, boolean)
	if not keyAssetId or not hooks.loadKeys then
		return false, false
	end
	local now = hooks.now()
	if now - lastReadAt < (MIN_INTERVAL[reason] or 30) then
		if reason == "hint" then
			hintPending = true
		end
		return false, false
	end
	lastReadAt = now
	if reason == "hint" then
		hintPending = false
	end
	reads += 1
	local ok, result = pcall(hooks.loadKeys, keyAssetId, if loaded then loadedVersion else nil)
	if ok and typeof(result) ~= "table" then
		ok, result = false, "loader returned nothing"
	end
	if ok and result.ok == false then
		ok, result = false, result.error
	end
	if not ok then
		lastReadOk = false
		lastReadError = string.sub(tostring(result), 1, 160)
		lastReadErrorAt = hooks.unixNow()
		hooks.warn(`[TypeTorch] key asset {keyAssetId} read failed ({reason}): {lastReadError}; keeping the {if loaded then "last good keys" else "fallback key"}`)
		return true, false
	end
	lastReadOk = true
	if result.unchanged and loaded then
		loadedAt = hooks.unixNow()
		return true, false
	end
	if typeof(result.publicKeys) ~= "string" then
		lastReadOk = false
		lastReadError = "no PublicKeys attribute"
		lastReadErrorAt = hooks.unixNow()
		hooks.warn(`[TypeTorch] key asset {keyAssetId} has no PublicKeys attribute; keeping the {if loaded then "last good keys" else "fallback key"}`)
		return true, false
	end
	return true, adopt(result, reason)
end

-- The kernel heard a rekey hint (TypeTorch/rekey). Remembered so a change right after it reads as a planned rotation.
function Signing.noteHint()
	lastHintAt = hooks.unixNow()
end

-- A rekey hint arrived inside the rate-limit window: the kernel should call refresh("hint") again once it opens.
function Signing.hintDue(): number?
	if not hintPending then
		return nil
	end
	return math.max(0, MIN_INTERVAL.hint - (hooks.now() - lastReadAt))
end

-- Verification -------------------------------------------------------------------------------------------------------

local function signatureBytes(value: any): buffer?
	local decoded = Signing.base64Decode(value)
	if decoded and buffer.len(decoded) == 64 then
		return decoded
	end
	return nil
end

-- Checks `sig` / `sigF` over `canonical` with the rule above. Returns (ok, why, which = "sig" | "sigF").
function Signing.verify(canonical: string, sig: any, sigF: any): (boolean, string?, string?)
	local memoKey = `{canonical}\0{tostring(sig)}\0{tostring(sigF)}\0{if loaded then "L" else "F"}`
	local memo = verdicts[memoKey]
	if memo then
		return memo.ok, memo.why, memo.by
	end
	local message = buffer.fromstring(canonical)
	local ok, why, by = false, nil, nil
	if loaded then
		local signature = signatureBytes(sig)
		if #activeKeys == 0 then
			why = "the key asset lists no usable public key"
		elseif sig == nil then
			why = "unsigned (no sig)"
		elseif not signature then
			why = "malformed sig"
		else
			for _, key in activeKeys do
				if Ed25519.verify(message, key.bytes, signature) then
					ok, by = true, "sig"
					break
				end
			end
			if not ok then
				why = "sig matches no trusted key"
			end
		end
	elseif fallbackKey then
		local signature = signatureBytes(sigF)
		if sigF == nil then
			why = "unsigned (no sigF; the key asset has not loaded on this server)"
		elseif not signature then
			why = "malformed sigF"
		elseif Ed25519.verify(message, fallbackKey, signature) then
			ok, by = true, "sigF"
		else
			why = "sigF does not match the fallback key"
		end
	else
		why = if keyAssetId
			then "no keys yet: the key asset has not loaded and there is no FallbackPublicKey"
			else "this kernel has no KeyAssetId or FallbackPublicKey (run typetorch keys init, then kernel deploy)"
	end
	if verdictCount > 256 then
		table.clear(verdicts)
		table.clear(badgeCache)
		badgeCount = 0
		verdictCount = 0
	end
	verdicts[memoKey] = { ok = ok, why = why, by = by }
	verdictCount += 1
	return ok, why, by
end

-- A deploy message (or a head converted with headFields): canonical string + signatures.
function Signing.verifyDeploy(fields, sig: any, sigF: any): (boolean, string?, string?)
	local canonical, why = Signing.deployCanonical(fields)
	if not canonical then
		return false, why, nil
	end
	return Signing.verify(canonical, sig, sigF)
end

function Signing.verifyHead(branch: string, head): (boolean, string?, string?)
	if typeof(head) ~= "table" then
		return false, "no head", nil
	end
	return Signing.verifyDeploy(Signing.headFields(branch, head), head.sig, head.sigF)
end

-- For the dev menu's verified badges (0.3): each signature checked on its own, whatever the acceptance rule above.
-- `main`: `sig` against PublicKeys minus RevokedKeys (false until the key asset has loaded here); `fallback`: `sigF`
-- against FallbackPublicKey (false without one, or when the key asset revokes it). nil when neither signature is
-- there (dev deploys). Cached with the verify results.

function Signing.signatures(canonical: string?, sig: any, sigF: any): { main: boolean, fallback: boolean }?
	if sig == nil and sigF == nil then
		return nil
	end
	if not canonical then
		return { main = false, fallback = false }
	end
	local memoKey = `{canonical}\0{tostring(sig)}\0{tostring(sigF)}`
	local cached = badgeCache[memoKey]
	if cached then
		return table.clone(cached)
	end
	local message = buffer.fromstring(canonical)
	local main = false
	local signature = if loaded then signatureBytes(sig) else nil
	if signature then
		for _, key in activeKeys do
			if Ed25519.verify(message, key.bytes, signature) then
				main = true
				break
			end
		end
	end
	local fallback = false
	local fallbackSignature = signatureBytes(sigF)
	if fallbackKey and not fallbackRevoked and fallbackSignature then
		fallback = Ed25519.verify(message, fallbackKey, fallbackSignature)
	end
	if badgeCount > 512 then
		table.clear(badgeCache)
		badgeCount = 0
	end
	local result = { main = main, fallback = fallback }
	badgeCache[memoKey] = result
	badgeCount += 1
	return table.clone(result)
end

-- `verified` for a deployment entry or head on `branch` ({assetId, artifactId, seq, commit, channel, t, rollback?,
-- sig?, sigF?}).
function Signing.headSignatures(branch: string, head): { main: boolean, fallback: boolean }?
	if typeof(head) ~= "table" then
		return nil
	end
	return Signing.signatures((Signing.deployCanonical(Signing.headFields(branch, head))), head.sig, head.sigF)
end

function Signing.verifyPin(data): (boolean, string?, string?)
	local canonical, why = Signing.pinCanonical(data)
	if not canonical then
		return false, why, nil
	end
	return Signing.verify(canonical, data.sig, data.sigF)
end

-- Whether any trust root is configured (else prod servers can't accept anything).
function Signing.configured(): boolean
	return keyAssetId ~= nil or fallbackKey ~= nil
end

function Signing.loaded(): boolean
	return loaded
end

-- For status() and, later, heartbeats.
local function keyRows(texts: { string }, markRevoked: boolean)
	local rows = {}
	for index, text in texts do
		local decoded = Signing.base64Decode(text)
		rows[index] = {
			key = text,
			fingerprint = fingerprints[text] or "?",
			revoked = if markRevoked and decoded and revokedSet[buffer.tostring(decoded)] then true else nil,
		}
	end
	return rows
end

local function deepClone(value)
	if typeof(value) ~= "table" then
		return value
	end
	local copy = {}
	for key, inner in value do
		copy[key] = deepClone(inner)
	end
	return copy
end

-- The trust state for devs (api:keys(), the dev menu's Artifact > Signing). Public keys aren't secret.
--   mode: "key asset" (sig against PublicKeys minus RevokedKeys), "fallback only" (sigF against the baked key, until
--   the key asset loads) or "none" (no trust root: prod servers refuse everything).
function Signing.keys()
	return {
		keyAssetId = keyAssetId,
		loaded = loaded,
		mode = if loaded then "key asset" elseif fallbackKey then "fallback only" else "none",
		version = loadedVersion,
		loadedAt = loadedAt, -- last successful read (unix s)
		lastReadOk = lastReadOk,
		lastError = lastReadError, -- last failed read, short (kept after later successes; see lastErrorAt)
		lastErrorAt = lastReadErrorAt,
		reads = reads,
		configError = configError,
		publicKeys = keyRows(publicTexts, true), -- { key, fingerprint, revoked? }
		revokedKeys = keyRows(revokedTexts, false),
		trusted = #activeKeys,
		invalid = if #invalidKeys > 0 then table.clone(invalidKeys) else nil,
		fallback = if fallbackText
			then { key = fallbackText, fingerprint = fingerprints[fallbackText] or "?", revoked = fallbackRevoked }
			else nil,
		lastHintAt = lastHintAt,
		-- BootstrapHeads as stamped: { [branch] = { assetId, seq, artifactId? } }.
		bootstrap = (function()
			local copy = {}
			for branch, entry in bootstrapHeads do
				copy[branch] = table.clone(entry)
			end
			return copy
		end)(),
		lastChange = if #changes > 0 then deepClone(changes[#changes]) else nil, -- { at, reason, hinted, before, after, ... }
		changes = #changes,
	}
end

-- A small summary for status() (polled often by the dev menu).
function Signing.summary()
	local last = changes[#changes]
	return {
		mode = if loaded then "key asset" elseif fallbackKey then "fallback only" else "none",
		loaded = loaded,
		trusted = #activeKeys,
		fallbackRevoked = fallbackRevoked or nil,
		lastChangeAt = if last then last.at else nil,
		lastChangeHinted = if last then last.hinted else nil,
		lastReadOk = lastReadOk,
	}
end

-- Tests only: forget everything (keys, memo, rate limits).
function Signing._reset()
	keyAssetId, fallbackKey, fallbackText, configError = nil, nil, nil, nil
	loaded, activeKeys, publicTexts, revokedTexts, revokedSet = false, {}, {}, {}, {}
	loadedVersion, loadedAt, lastReadAt, lastReadOk, lastReadError = nil, nil, -math.huge, nil, nil
	reads, changes, invalidKeys, fallbackRevoked, hintPending = 0, {}, {}, false, false
	lastReadErrorAt, lastHintAt = nil, nil
	table.clear(fingerprints)
	bootstrapHeads = {}
	table.clear(verdicts)
	table.clear(badgeCache)
	badgeCount = 0
	verdictCount = 0
end

return Signing
