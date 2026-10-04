-- Signing.luau specs, run by scripts/test-ed25519.luau (`lune run scripts/test-ed25519.luau`).
-- Vectors: plans/03 "Signed prod messages" (throwaway test keys whose seeds are public: never use them for real).
--   main      seed +YR5DRjMHSBmbLgmt3LewYocFNfHgl5nKv+CepjNM8Y=                                public ErlwbCHD...
--   fallback  seed SHA-256("TypeTorch test vector: fallback key (public, never use)")         public mb6ZhKXQ...
--   rotated   seed SHA-256("tt-test-rotated-main-key") (kernel tests only)                     public 3Kvcf4gI...
-- The signatures were made with node:crypto over the canonical strings below.

local Signing = require("../src/server/Signing")

local MAIN = "ErlwbCHDCN4WvDHY6l3plaeihIONuatx2jjqoqXZiq4="
local FALLBACK = "mb6ZhKXQSzn2N+Xzle+xv1IuOLNWfQrtvifYYBknu0E="
local ROTATED = "3Kvcf4gIFRT+mcefCGeN+CNctoEb/DJK+YO9EfF4TEI="

local VECTORS = {
	deploy = {
		fields = { b = "dev", a = 134192491895548, i = "12b63b9-3fa91c", s = 17, c = "12b63b9", ch = "dev", t = 1759580000000 },
		canonical = "tt1\ndev\n134192491895548\n12b63b9-3fa91c\n17\n12b63b9\ndev\n1759580000000\n",
		sig = "PGUNDeXnLquAaE67z6rObJxcbYEWFgHPFxqb4EM93auudYqZtTEYUc0yF4K4gJQn0nKr+bTBv2QjArxSUSHRAw==",
		sigF = "hmsNvZOG4myGw9fKa/JxDH44tWzFrRxMbmFXpn338kEGLenb7hewIS8PoAs2/wu+ulB2cjHaZR6p7c01mcGyAQ==",
		sigR = "zsY29/TP6iS59Ai0apSzcOn05g/WjSxlfZ5L8Uctsrh0q3NtDkcMWpabPmaumxJQY40Ap/qZHQGnJZFMMb2sAg==",
	},
	rollback = {
		fields = { b = "prod", a = 138576381221184, i = "12b63b9-8be210", s = 18, c = "12b63b9", ch = "prod", t = 1759580060000, r = 1 },
		canonical = "tt1\nprod\n138576381221184\n12b63b9-8be210\n18\n12b63b9\nprod\n1759580060000\n1",
		sig = "h4D9wxKwyj9ZiZEgEeje5bLXd62iH1Zqqbi6UCzNnGBu1SAPQq38g1zFWizogRTVumLr3OTz4T2hlSx/6fl9AQ==",
		sigF = "SJG++3eiXGCYmu35ADj79qI7M0n/NxlRS61uZXqa6V2ahdN0pMZHBc2OB31r//ve87pKEY8AUvTH/lbz4fx7Bw==",
	},
	prodDeploy = { -- plans/03 vector 3
		fields = { b = "prod", a = 138576381221184, i = "12b63b9-8be210", s = 19, c = "12b63b9", ch = "prod", t = 1759580120000 },
		canonical = "tt1\nprod\n138576381221184\n12b63b9-8be210\n19\n12b63b9\nprod\n1759580120000\n",
		sig = "phgDB7FGF1wuRZolNMKItmsUYwJzqFmvIFVOmlmWOxyDRG4lpk06KBQbBUkhczHktk+a7lUGGZjjy83liqK7Dw==",
		sigF = "ozGBMMk3xtBREeQkcP596zVthaJNtkdbjE+AlG9pD80kxNn6GzGNowGmyzwMtwpZ8SkXr+g/LBR9X5bPkaeSBQ==",
	},
	pinRandom = {
		fields = { pct = 10, a = 134192491895548, b = "prod", by = 12345, t = 1759580000000 },
		canonical = "tt1pin\nprod\n134192491895548\n\n10\n12345\n1759580000000\n",
		sig = "Vbr7YSmWuWG/OIhUDlYJatHEemFnQo0MFbVWIRpWgplMGYyqP+5fxJvgSXCUSr6XpV4hrozN0wMPQxv+O2gHCQ==",
		sigF = "FyqmF2+suPUaPyINGtoaGfxO2JBB0+hgur2SPFM3pzDe0T9iqUbYRBvqRJTLvr1FaZlCLU1aVqUmxHTIXN0SBQ==",
	},
	unpinJobs = {
		fields = { j = { "abc-1", "def-2" }, b = "prod", by = 12345, t = 1759580000000, unpin = true },
		canonical = "tt1pin\nprod\n\nabc-1,def-2\n\n12345\n1759580000000\n1",
		sig = "WQtaQvTf+SWqkFmU/uVK64YDlWoVH9uPFcGZXfsX5lqjp1GnSpeIkmFsc+NdypJ7TaQqkR8bXQx9VdT3cinGCw==",
		sigF = "KZ9wjqB/hOte47FJtJH6Pr/qFybcJ1b/hWQO044HC0mgA0MudJv1b6hgcIjCWkb3mND9aR0/OC/lE53UdIT7DA==",
	},
	resign = { -- a head the CLI re-signed after `keys rotate`: same asset, new seq, r = "resign"
		fields = { b = "prod", a = 138576381221184, i = "12b63b9-8be210", s = 20, c = "12b63b9", ch = "prod", t = 1759580180000, r = "resign" },
		canonical = "tt1\nprod\n138576381221184\n12b63b9-8be210\n20\n12b63b9\nprod\n1759580180000\nresign",
		sig = "HHni5U92bF9gQOYzm4/yPHi2fw0d6kqEt/zem9XHGOBcdfDnh9ty8Djl1NDPVuzlNx9xr60dzQNogtNyoa+pAw==",
		sigF = "YTwE+4JbN9R63AxJCSjmfp/rNKCqV6ORZjvcr5lYB9Zv7FLg09jofDDYodkKjyYfKLCurS1G9oRlKPPDqMIoAw==",
	},
}

local function folder(attributes)
	return {
		GetAttribute = function(_self, name)
			return attributes[name]
		end,
	}
end

return function(check: (string, boolean) -> (), helpers)
	local function b64(text: string): string?
		local decoded = Signing.base64Decode(text)
		return if decoded then buffer.tostring(decoded) else nil
	end

	-- Base64.
	check("base64 TWFu", b64("TWFu") == "Man")
	check("base64 TWE=", b64("TWE=") == "Ma")
	check("base64 TQ==", b64("TQ==") == "M")
	check("base64 32-byte key", (Signing.base64Decode(MAIN) and buffer.len(Signing.base64Decode(MAIN) :: buffer)) == 32)
	check("base64 refuses ''", b64("") == nil)
	check("base64 refuses bad length", b64("TWF") == nil)
	check("base64 refuses '=' inside", b64("TQ==TWFu") == nil)
	check("base64 refuses '-' (url alphabet)", b64("TW-u") == nil)
	check("base64 refuses non-strings", Signing.base64Decode(5) == nil)
	check("base64 key bytes", helpers.toHex(Signing.base64Decode(MAIN) :: buffer) == "12b9706c21c308de16bc31d8ea5de995a7a284838db9ab71da38eaa2a5d98aae")

	-- Canonical strings.
	check("deploy canonical", Signing.deployCanonical(VECTORS.deploy.fields) == VECTORS.deploy.canonical)
	check("rollback canonical", Signing.deployCanonical(VECTORS.rollback.fields) == VECTORS.rollback.canonical)
	check("pin canonical (pct)", Signing.pinCanonical(VECTORS.pinRandom.fields) == VECTORS.pinRandom.canonical)
	check("unpin canonical (j)", Signing.pinCanonical(VECTORS.unpinJobs.fields) == VECTORS.unpinJobs.canonical)
	local bad = table.clone(VECTORS.deploy.fields)
	bad.a = 1.5
	check("deploy canonical refuses a fraction", Signing.deployCanonical(bad) == nil)
	bad = table.clone(VECTORS.deploy.fields)
	bad.b = "a\nb"
	check("deploy canonical refuses a newline", Signing.deployCanonical(bad) == nil)
	bad = table.clone(VECTORS.deploy.fields)
	bad.t = nil
	check("deploy canonical needs t", Signing.deployCanonical(bad) == nil)
	bad = table.clone(VECTORS.deploy.fields)
	bad.s = -1
	check("deploy canonical refuses a negative seq", Signing.deployCanonical(bad) == nil)
	check("deploy canonical: large ids stay integers", string.find(Signing.deployCanonical({ b = "x", a = 1e14, i = "i", s = 1, c = "c", ch = "prod", t = 1 }) :: string, "\n100000000000000\n", 1, true) ~= nil)
	check("pin canonical refuses a comma in a job id", Signing.pinCanonical({ j = { "a,b" }, b = "prod", by = 1, t = 1 }) == nil)
	check("head fields = deploy fields", Signing.deployCanonical(Signing.headFields("prod", {
		assetId = 138576381221184,
		artifactId = "12b63b9-8be210",
		seq = 18,
		commit = "12b63b9",
		channel = "prod",
		t = 1759580060000,
		rollback = true,
	})) == VECTORS.rollback.canonical)

	-- Trust rules, with stubbed Roblox parts.
	local clock = 1000
	local warnings, events = {}, {}
	local nextRead: any = nil
	local readCalls = 0
	Signing._reset()
	Signing.configure({
		now = function()
			return clock
		end,
		unixNow = function()
			return 1759580000
		end,
		warn = function(text)
			table.insert(warnings, text)
		end,
		print = function() end,
		logEvent = function(entry)
			table.insert(events, entry)
		end,
		loadKeys = function(_assetId, _version)
			readCalls += 1
			if typeof(nextRead) == "function" then
				return nextRead()
			end
			return nextRead
		end,
	})

	local deploy = VECTORS.deploy
	local function verifyDeploy(sig, sigF)
		return Signing.verifyDeploy(deploy.fields, sig, sigF)
	end

	-- No trust roots at all: refuse.
	Signing.init(folder({}))
	local ok, why = verifyDeploy(deploy.sig, deploy.sigF)
	check("no KeyAssetId/FallbackPublicKey: refused", not ok and string.find(why or "", "keys init", 1, true) ~= nil)
	check("no trust roots: not configured", not Signing.configured())

	-- Fallback only (the key asset hasn't loaded): sigF counts, sig doesn't.
	Signing._reset()
	Signing.init(folder({ KeyAssetId = "99", FallbackPublicKey = FALLBACK }))
	check("configured", Signing.configured())
	local byWhich
	ok, why, byWhich = verifyDeploy(deploy.sig, deploy.sigF)
	check("before the key asset loads: sigF accepted", ok and byWhich == "sigF")
	ok = verifyDeploy(deploy.sig, nil)
	check("before the key asset loads: sig alone refused", not ok)
	ok = verifyDeploy(nil, deploy.rollbackSigF or VECTORS.rollback.sigF)
	check("before the key asset loads: another message's sigF refused", not ok)
	ok = verifyDeploy(nil, "AAAA")
	check("malformed sigF refused", not ok)

	-- Key asset loads: from now on only sig counts.
	nextRead = { publicKeys = MAIN, revokedKeys = "", version = 7 }
	local read, changed = Signing.refresh("boot")
	check("boot read", read and changed and Signing.loaded())
	ok, why, byWhich = verifyDeploy(deploy.sig, deploy.sigF)
	check("after load: sig accepted", ok and byWhich == "sig")
	ok = verifyDeploy(nil, deploy.sigF)
	check("after load: sigF alone refused", not ok)
	ok = verifyDeploy(deploy.sigR, nil)
	check("after load: a key not in PublicKeys refused", not ok)
	local rollbackFields = VECTORS.rollback.fields
	ok = Signing.verifyDeploy(rollbackFields, VECTORS.rollback.sig, nil)
	check("rollback vector: sig accepted", ok)
	local tampered = table.clone(rollbackFields)
	tampered.ch = "dev"
	ok = Signing.verifyDeploy(tampered, VECTORS.rollback.sig, nil)
	check("rollback vector with ch changed: refused", not ok)
	check("first load is not a change", #events == 0)

	-- Rate limits: a hint right away doesn't read, but stays due.
	local callsBefore = readCalls
	read = Signing.refresh("hint")
	check("hint inside 30 s: no read", not read and readCalls == callsBefore)
	check("hint is remembered", (Signing.hintDue() or -1) > 0)
	read = Signing.refresh("failure")
	check("failure inside 60 s: no read", not read)

	-- Rotation: the rotated key is added, main is revoked.
	clock += 31
	nextRead = { publicKeys = `{ROTATED}, {MAIN}`, revokedKeys = MAIN, version = 8 }
	read, changed = Signing.refresh("hint")
	check("hint after 30 s: read and changed", read and changed)
	check("hint no longer due", Signing.hintDue() == nil)
	local change = Signing.keys().lastChange
	check("change logged", #events == 1 and events[1].action == "keys_changed" and events[1].hinted == false)
	check("change recorded", change ~= nil and change.added[1] == ROTATED and change.revokedAdded[1] == MAIN and change.reason == "hint")
	check("change fingerprints", change ~= nil and change.before.publicKeys[1] == "dfe5449d" and #change.after.publicKeys == 2 and change.after.revokedKeys[1] == "dfe5449d")
	check("change warned", string.find(warnings[#warnings] or "", "CHANGED", 1, true) ~= nil)
	ok = verifyDeploy(deploy.sig, nil)
	check("revoked main key refused", not ok)
	ok = verifyDeploy(deploy.sigR, nil)
	check("rotated key accepted", ok)
	local status = Signing.keys()
	check("status: 2 public, 1 revoked, 1 trusted", #status.publicKeys == 2 and #status.revokedKeys == 1 and status.trusted == 1 and status.version == 8 and status.changes == 1 and status.mode == "key asset")

	-- A failed read keeps the last good keys.
	clock += 61
	nextRead = function()
		error("HTTP 500")
	end
	read, changed = Signing.refresh("failure")
	check("failed read: attempted, no change", read and not changed)
	ok = verifyDeploy(deploy.sigR, nil)
	check("failed read keeps the keys", ok and Signing.keys().lastReadOk == false)

	-- A read without the PublicKeys attribute is a failed read too.
	clock += 301
	nextRead = { revokedKeys = "" }
	Signing.refresh("periodic")
	ok = verifyDeploy(deploy.sigR, nil)
	check("missing PublicKeys keeps the keys", ok)

	-- "unchanged" (same asset version) keeps the keys without a load.
	clock += 301
	nextRead = { unchanged = true, version = 8 }
	read, changed = Signing.refresh("periodic")
	check("unchanged version: read, no change", read and not changed and Signing.keys().lastReadOk == true)

	-- Garbage entries are skipped; the fallback key can be revoked.
	clock += 301
	nextRead = { publicKeys = `not-a-key, {ROTATED}`, revokedKeys = `{MAIN},{FALLBACK}`, version = 9 }
	Signing.refresh("periodic")
	status = Signing.keys()
	check("garbage key skipped", status.trusted == 1 and status.invalid and status.invalid[1] == "not-a-key")
	check("fallback revoked shows in keys()", status.fallback ~= nil and status.fallback.revoked == true and status.fallback.fingerprint == "43f1e550")
	ok = verifyDeploy(nil, deploy.sigF)
	check("revoked fallback: sigF refused", not ok)

	check("periodic change without a hint", Signing.keys().lastChange.hinted == false and Signing.keys().lastChange.reason == "periodic")
	check("keys() rows: fingerprint and revoked flag", status.publicKeys[1].fingerprint == "fe58a9a8" and status.publicKeys[1].revoked == nil and status.revokedKeys[1].key == MAIN and status.revokedKeys[2].key == FALLBACK)

	-- An empty key list refuses everything (fail closed). A rekey hint just before marks the change as hinted.
	clock += 301
	Signing.noteHint()
	nextRead = { publicKeys = "", revokedKeys = "", version = 10 }
	Signing.refresh("periodic")
	ok, why = verifyDeploy(deploy.sigR, deploy.sigF)
	check("empty PublicKeys: refused", not ok and string.find(why or "", "no usable", 1, true) ~= nil)
	check("change after a hint is hinted", Signing.keys().lastChange.hinted == true and Signing.keys().changes == 3)

	-- plans/03 vector 3 (prod deploy), under the kernel's rule (user decision 2026-10-04): sigF counts only until the
	-- key asset loads. NOTE: plans/03 "The rule" (CLI side) also accepts sigF afterwards; the kernel does not.
	local prod = VECTORS.prodDeploy
	check("vector 3 canonical", Signing.deployCanonical(prod.fields) == prod.canonical)
	Signing._reset()
	Signing.init(folder({ KeyAssetId = 99, FallbackPublicKey = FALLBACK }))
	check("vector 3: sigF before the key asset loads", (Signing.verifyDeploy(prod.fields, nil, prod.sigF)))
	check("vector 3: sig alone before the key asset loads is refused", not (Signing.verifyDeploy(prod.fields, prod.sig, nil)))
	clock += 1000
	nextRead = { publicKeys = MAIN, revokedKeys = "", version = 1 }
	Signing.refresh("boot")
	check("vector 3: sig after load", (Signing.verifyDeploy(prod.fields, prod.sig, prod.sigF)))
	clock += 1000
	nextRead = { publicKeys = MAIN, revokedKeys = MAIN, version = 2 }
	Signing.refresh("periodic")
	check("vector 3 with main revoked: refused (sigF no longer counts once the key asset loaded)", not (Signing.verifyDeploy(prod.fields, prod.sig, prod.sigF)))
	local sigs = Signing.signatures(prod.canonical, prod.sig, prod.sigF)
	check("vector 3 badges with main revoked: fallback only", sigs ~= nil and not sigs.main and sigs.fallback)

	-- Re-signed heads (r = "resign", user decision 2026-10-04).
	local resign = VECTORS.resign
	check("resign canonical", Signing.deployCanonical(resign.fields) == resign.canonical)
	check("resign head fields", Signing.deployCanonical(Signing.headFields("prod", {
		assetId = 138576381221184,
		artifactId = "12b63b9-8be210",
		seq = 20,
		commit = "12b63b9",
		channel = "prod",
		t = 1759580180000,
		r = "resign",
	})) == resign.canonical)
	local badR = table.clone(resign.fields)
	badR.r = "later"
	check("unknown r refused", Signing.deployCanonical(badR) == nil)
	Signing._reset()
	Signing.init(folder({ KeyAssetId = 99, FallbackPublicKey = FALLBACK }))
	clock += 1000
	nextRead = { publicKeys = MAIN, revokedKeys = "", version = 1 }
	Signing.refresh("boot")
	check("resign: sig verifies", (Signing.verifyDeploy(resign.fields, resign.sig, nil)))
	local asRollback = table.clone(resign.fields)
	asRollback.r = 1
	check("resign signature is not a rollback signature", not (Signing.verifyDeploy(asRollback, resign.sig, nil)))

	-- BootstrapHeads (user decision 2026-10-04): the only unsigned heads a prod server takes.
	local serde = require("@lune/serde")
	local decodeJson = function(text)
		return serde.decode("json", text)
	end
	Signing._reset()
	Signing.init(folder({ KeyAssetId = 99, BootstrapHeads = '{"prod":{"a":1001,"s":10,"i":"aaaaaaa-111111"},"bad":{"a":"x"}}' }), decodeJson)
	local boot = Signing.bootstrapHead("prod")
	check("bootstrap parsed", boot ~= nil and boot.assetId == 1001 and boot.seq == 10 and boot.artifactId == "aaaaaaa-111111")
	check("bootstrap: a bad entry is reported, the good one kept", Signing.keys().configError ~= nil and Signing.keys().bootstrap.prod ~= nil and Signing.keys().bootstrap.bad == nil)
	check("bootstrap match (branch, asset, seq)", Signing.matchesBootstrap("prod", { assetId = 1001, seq = 10 }))
	check("bootstrap: another seq doesn't match", not Signing.matchesBootstrap("prod", { assetId = 1001, seq = 11 }))
	check("bootstrap: another asset doesn't match", not Signing.matchesBootstrap("prod", { assetId = 1002, seq = 10 }))
	check("bootstrap: another branch doesn't match", not Signing.matchesBootstrap("dev", { assetId = 1001, seq = 10 }))
	Signing._reset()
	Signing.init(folder({ BootstrapHeads = "not json" }), decodeJson)
	check("bootstrap: bad JSON is reported", Signing.keys().configError ~= nil and Signing.bootstrapHead("prod") == nil)

	-- Dev menu badges: each signature on its own.
	Signing._reset()
	Signing.init(folder({ KeyAssetId = 99, FallbackPublicKey = FALLBACK }))
	local function badges(sig, sigF)
		return Signing.signatures(Signing.deployCanonical(deploy.fields), sig, sigF)
	end
	check("badges: unsigned -> nil", badges(nil, nil) == nil)
	local before = badges(deploy.sig, deploy.sigF)
	check("badges before the key asset loads: fallback only", before ~= nil and before.main == false and before.fallback == true)
	clock += 1000
	nextRead = { publicKeys = MAIN, revokedKeys = "", version = 1 }
	Signing.refresh("boot")
	local both = badges(deploy.sig, deploy.sigF)
	check("badges after load: both", both ~= nil and both.main and both.fallback)
	local mainOnly = badges(deploy.sig, nil)
	check("badges: main only", mainOnly ~= nil and mainOnly.main and not mainOnly.fallback)
	local wrong = badges(deploy.sigR, VECTORS.rollback.sigF)
	check("badges: wrong signatures -> none verified", wrong ~= nil and not wrong.main and not wrong.fallback)
	local head = Signing.headSignatures("dev", { assetId = 134192491895548, artifactId = "12b63b9-3fa91c", seq = 17, commit = "12b63b9", channel = "dev", t = 1759580000000, sig = deploy.sig, sigF = deploy.sigF })
	check("headSignatures", head ~= nil and head.main and head.fallback)
	check("fingerprint", Signing.fingerprint(Signing.base64Decode(MAIN) :: buffer) == "dfe5449d")

	-- KeyAssetId set but never loaded, no fallback: refused.
	Signing._reset()
	Signing.init(folder({ KeyAssetId = 99 }))
	ok, why = verifyDeploy(deploy.sig, deploy.sigF)
	check("no fallback and no load yet: refused", not ok and string.find(why or "", "not loaded", 1, true) ~= nil)
	Signing._reset()
	Signing.init(folder({ KeyAssetId = "x", FallbackPublicKey = "AAAA" }))
	check("bad attributes reported", Signing.keys().configError ~= nil and not Signing.configured())

	-- Pins.
	Signing._reset()
	Signing.init(folder({ KeyAssetId = 99, FallbackPublicKey = FALLBACK }))
	local pin = table.clone(VECTORS.pinRandom.fields)
	pin.sigF = VECTORS.pinRandom.sigF
	check("pin: sigF before load", (Signing.verifyPin(pin)))
	local unpin = table.clone(VECTORS.unpinJobs.fields)
	unpin.sig = VECTORS.unpinJobs.sig
	unpin.sigF = VECTORS.unpinJobs.sigF
	clock += 1000
	nextRead = { publicKeys = MAIN, revokedKeys = "", version = 1 }
	Signing.refresh("boot")
	check("unpin: sig after load", (Signing.verifyPin(unpin)))
	unpin.j = { "abc-1" }
	check("unpin with another job list: refused", not (Signing.verifyPin(unpin)))
	local deployAsPin = table.clone(VECTORS.pinRandom.fields)
	deployAsPin.sig = deploy.sig
	check("a deploy signature is no pin signature", not (Signing.verifyPin(deployAsPin)))

	Signing._reset()
end
