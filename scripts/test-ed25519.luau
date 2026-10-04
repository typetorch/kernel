-- Tests for the kernel's signature checks: `lune run scripts/test-ed25519.luau` (from kernel/; Lune pinned in rokit.toml).
--   1. The vendored Ed25519 verifier (src/server/vendor/ed25519) against RFC 8032 section 7.1 test vectors, extra
--      vectors made with node:crypto from throwaway seeds, and tampered/malformed inputs.
--   2. Its SHA-512 against Lune's own (serde.hash) for message lengths 0..300.
--   3. Signing.luau: base64, the canonical strings and the plans/03 test vectors (deploy, rollback, pin), key sets,
--      revocation and the fallback rule.
--   4. Timing: one verify, averaged (the number goes in plans/01).
-- Every key here is a throwaway test key (RFC 8032's published keys, or seeds that are SHA-256 of public labels).

local process = require("@lune/process")
local serde = require("@lune/serde")

local requireStarted = os.clock()
local Ed25519 = require("../src/server/vendor/ed25519/Ed25519")
local requireSeconds = os.clock() - requireStarted
local Signing = require("../src/server/Signing")

local failures, passes = 0, 0
local function check(name: string, condition: boolean)
	if condition then
		passes += 1
	else
		failures += 1
		print(`FAIL  {name}`)
	end
end

local function fromHex(hex: string): buffer
	assert(#hex % 2 == 0, "odd hex")
	local out = buffer.create(#hex // 2)
	for index = 0, #hex // 2 - 1 do
		buffer.writeu8(out, index, tonumber(string.sub(hex, index * 2 + 1, index * 2 + 2), 16) :: number)
	end
	return out
end

local function toHex(data: buffer): string
	local parts = table.create(buffer.len(data))
	for index = 0, buffer.len(data) - 1 do
		parts[index + 1] = string.format("%02x", buffer.readu8(data, index))
	end
	return table.concat(parts)
end

local function copyWith(data: buffer, index: number, xor: number): buffer
	local copy = buffer.create(buffer.len(data))
	buffer.copy(copy, 0, data, 0, buffer.len(data))
	buffer.writeu8(copy, index, bit32.bxor(buffer.readu8(copy, index), xor))
	return copy
end

-- 1. RFC 8032 section 7.1 (Ed25519): TEST 1, 2, 3 and SHA(abc). Checked against node:crypto (sign with the secret key
-- reproduces each signature).
local RFC = {
	{
		name = "RFC 8032 TEST 1 (empty message)",
		publicKey = "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a",
		message = "",
		signature = "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b",
	},
	{
		name = "RFC 8032 TEST 2 (1 byte)",
		publicKey = "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c",
		message = "72",
		signature = "92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00",
	},
	{
		name = "RFC 8032 TEST 3 (2 bytes)",
		publicKey = "fc51cd8e6218a1a38da47ed00230f0580816ed13ba3303ac5deb911548908025",
		message = "af82",
		signature = "6291d657deec24024827e69c3abe01a30ce548a284743a445e3680d7db5ac3ac18ff9b538d16f290ae67f760984dc6594a7c15e9716ed28dc027beceea1ec40a",
	},
	{
		name = "RFC 8032 TEST SHA(abc) (64 bytes)",
		publicKey = "ec172b93ad5e563bf4932c70e1245034c35467ef2efd4d64ebf819683467e2bf",
		message = "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f",
		signature = "dc2a4459e7369633a52b1bf277839a00201009a3efbf3ecb69bea2186c26b58909351fc9ac90b3ecfdfbc7c66431e0303dca179c138ac17ad9bef1177331a704",
	},
}

-- node:crypto signatures of bytes (i % 251) for i = 0..len-1, seed = SHA-256(label).
local function counting(length: number): string
	local parts = table.create(length)
	for index = 0, length - 1 do
		parts[index + 1] = string.format("%02x", index % 251)
	end
	return table.concat(parts)
end
local EXTRA = {
	{
		name = "node:crypto, seed SHA-256('tt-test-ed25519-a'), 111 bytes",
		publicKey = "bb9c4bcb95442c37cacba454691be8b54b46ffd2d07222206dce73f63291e3c5",
		message = counting(111),
		signature = "bb4e1a16ecdee3aedc2158013036451bee7e5c56b3cb1a712d006266b9dfea22822790c1d66c5d2618d50767947537ed952613be5fbccf48c4aca8bbb748d20c",
	},
	{
		name = "node:crypto, seed SHA-256('tt-test-ed25519-b'), 200 bytes",
		publicKey = "25662bcab79b89621ec996ae3989a60b983d41577045f5c50c591b63549fd41e",
		message = counting(200),
		signature = "bc217894baefb75040a7c6c15c7269dc843cad16e0ca1a94632809eb30271de3d51096ab316fae52cfe501d9544e5a6ad65b0ab73a170b4344264b5b8342de02",
	},
	{
		name = "node:crypto, seed SHA-256('tt-test-ed25519-c'), 1000 bytes",
		publicKey = "3f9ad80fe45a118a78f0627649955e5b47b8e3d441282a33434c12eab15dac49",
		message = counting(1000),
		signature = "e3c69323c9d004b30ba9d61cbe304191b16ffab72a48fd24e13c064d12ee7b2cb0baebcf9a7b3d3e1868853c1a91a7d008018a468abef05d35eb2a2d8169e900",
	},
}

-- L, the group order, little endian (for the S >= L malleability check).
local ORDER = fromHex("edd3f55c1a631258d69cf7a2def9de1400000000000000000000000000000010")

local function addOrder(signature: buffer): buffer
	local out = buffer.create(64)
	buffer.copy(out, 0, signature, 0, 64)
	local carry = 0
	for index = 0, 31 do
		local sum = buffer.readu8(signature, 32 + index) + buffer.readu8(ORDER, index) + carry
		buffer.writeu8(out, 32 + index, sum % 256)
		carry = sum // 256
	end
	return out
end

for _, list in { RFC, EXTRA } do
	for _, vector in list do
		local publicKey, message, signature = fromHex(vector.publicKey), fromHex(vector.message), fromHex(vector.signature)
		check(`{vector.name}: valid`, Ed25519.verify(message, publicKey, signature))
		for _, index in { 0, 31, 32, 63 } do
			check(`{vector.name}: signature byte {index} flipped`, not Ed25519.verify(message, publicKey, copyWith(signature, index, 0x01)))
		end
		check(`{vector.name}: public key flipped`, not Ed25519.verify(message, copyWith(publicKey, 5, 0x10), signature))
		if buffer.len(message) > 0 then
			check(`{vector.name}: message flipped`, not Ed25519.verify(copyWith(message, buffer.len(message) - 1, 0x80), publicKey, signature))
		else
			check(`{vector.name}: message added`, not Ed25519.verify(fromHex("00"), publicKey, signature))
		end
		check(`{vector.name}: S + L refused`, not Ed25519.verify(message, publicKey, addOrder(signature)))
	end
end

-- Cross: one vector's signature under another key, and malformed input (never throws).
check("signature under another key", not Ed25519.verify(fromHex(RFC[2].message), fromHex(RFC[3].publicKey), fromHex(RFC[2].signature)))
check("short signature", not Ed25519.verify(buffer.create(0), fromHex(RFC[1].publicKey), buffer.create(63)))
check("short key", not Ed25519.verify(buffer.create(0), buffer.create(31), fromHex(RFC[1].signature)))
check("non-buffer input", not Ed25519.verify("" :: any, fromHex(RFC[1].publicKey), fromHex(RFC[1].signature)))
check("all-zero key and signature", not Ed25519.verify(buffer.create(0), buffer.create(32), buffer.create(64)))
-- Small-order keys: with R = identity and S = 0, cofactored verification alone would accept any message.
local IDENTITY = "0100000000000000000000000000000000000000000000000000000000000000"
local ORDER2 = "ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f" -- (0, -1)
local ZERO_S = string.rep("0", 64)
check("identity key, R = identity, S = 0", not Ed25519.verify(fromHex("72"), fromHex(IDENTITY), fromHex(IDENTITY .. ZERO_S)))
check("order-2 key, R = identity, S = 0", not Ed25519.verify(fromHex("72"), fromHex(ORDER2), fromHex(IDENTITY .. ZERO_S)))
check("valid key, small-order R refused", not Ed25519.verify(fromHex(RFC[2].message), fromHex(RFC[2].publicKey), fromHex(IDENTITY .. string.sub(RFC[2].signature, 65))))

-- 2. SHA-512 against Lune's implementation.
local shaMismatch = nil
for length = 0, 300 do
	local text = string.rep("\xa5tt", length // 3 + 1):sub(1, length)
	local mine = toHex(Ed25519.sha512(buffer.fromstring(text)))
	local theirs = serde.hash("sha512", text)
	if mine ~= theirs then
		shaMismatch = length
		break
	end
end
check(`SHA-512 matches Lune for lengths 0..300{if shaMismatch then ` (first mismatch at {shaMismatch})` else ""}`, shaMismatch == nil)
check(
	"SHA-512('abc')",
	toHex(Ed25519.sha512(buffer.fromstring("abc"))) == "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f"
)

-- 3. Signing.luau (pure parts; the Roblox parts are stubbed through Signing.configure).
local testsOk, testsError = pcall(function()
	require("./test-signing")(check, { fromHex = fromHex, toHex = toHex })
end)
check(`scripts/test-signing.luau ran{if testsOk then "" else `: {testsError}`}`, testsOk)

-- 4. Timing.
local publicKey, message, signature = fromHex(EXTRA[1].publicKey), fromHex(EXTRA[1].message), fromHex(EXTRA[1].signature)
Ed25519.verify(message, publicKey, signature) -- warm up
local rounds = 30
local started = os.clock()
for _ = 1, rounds do
	Ed25519.verify(message, publicKey, signature)
end
local perVerify = (os.clock() - started) / rounds
print(string.format("timing: require %.1f ms, verify %.2f ms (mean of %d, 111-byte message)", requireSeconds * 1000, perVerify * 1000, rounds))

print(`{passes} passed, {failures} failed`)
process.exit(if failures == 0 then 0 else 1)
