--!strict
--!optimize 2
--!native
-- Ed25519 signature verification (RFC 8032), verify only.
--
-- Vendored from Luau Cryptography (rbx-cryptography) by daily3014 and Xoifail, MIT License (see ./LICENSE):
--   https://github.com/daily3014/rbx-cryptography, version 3.1.4, commit 6147c4702726ab59c4b31ed9304dbe8bb843f05f,
--   src/Verification/EdDSA/{FieldPrime,FieldQuadratic,MultiPrecision,Edwards25519,SHA512}.luau, unmodified, and
--   src/Hashing/SHA2/SHA256.luau (unmodified; the kernel's key fingerprints).
-- This file is adapted from that release's src/Verification/EdDSA/init.luau (EDDSA.Verify): the same checks and math,
-- but bad input returns false instead of throwing, and the CSPRNG/X25519/signing parts are left out (the kernel only
-- verifies, and the CSPRNG gathers entropy when it is required).
--
-- Cofactored check: [8]([S]B - R - [k]A) = 0, with S < L (no malleable S) and R, A decoded as curve points.
-- Added here (like libsodium): small-order public keys and R are refused. Without it an all-zero key and signature
-- "verify" any message (cofactored verification accepts small-order points).
-- Kernel tests: kernel/scripts/test-ed25519.luau (RFC 8032 section 7.1 and plans/03 vectors).
--
-- The vendored files' license (copied here so it ships inside the place; the LICENSE file next to them is the same):
--   MIT License
--
--   Copyright (c) 2026 daily3014
--
--   Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated
--   documentation files (the "Software"), to deal in the Software without restriction, including without limitation
--   the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
--   permit persons to whom the Software is furnished to do so, subject to the following conditions:
--
--   The above copyright notice and this permission notice shall be included in all copies or substantial portions of
--   the Software.
--
--   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO
--   THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
--   AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF
--   CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
--   IN THE SOFTWARE.

local FieldQuadratic = require("./FieldQuadratic")
local FieldPrime = require("./FieldPrime")
local SHA512 = require("./SHA512")
local Edwards25519 = require("./Edwards25519")

local PUBLIC_KEY_SIZE = 32
local SIGNATURE_SIZE = 64

local function concat(a: buffer, b: buffer, c: buffer): buffer
	local lengthA, lengthB, lengthC = buffer.len(a), buffer.len(b), buffer.len(c)
	local result = buffer.create(lengthA + lengthB + lengthC)
	buffer.copy(result, 0, a, 0, lengthA)
	buffer.copy(result, lengthA, b, 0, lengthB)
	buffer.copy(result, lengthA + lengthB, c, 0, lengthC)
	return result
end

-- Whether [8]P is the identity (P has order 1, 2, 4 or 8). No point has order 16, so X = 0 after three doublings means
-- the identity.
local function isSmallOrder(point: buffer): boolean
	local times8 = Edwards25519.Double(Edwards25519.Double(Edwards25519.Double(point)))
	local x = buffer.create(104)
	buffer.copy(x, 0, times8, 0, 104)
	return FieldPrime.Eqz(x)
end

local Ed25519 = {}

-- Whether `signature` (64 bytes) is a valid Ed25519 signature of `message` by `publicKey` (32 bytes). Never throws on
-- bad input: wrong types or sizes are simply invalid.
function Ed25519.verify(message: buffer, publicKey: buffer, signature: buffer): boolean
	if typeof(message) ~= "buffer" or typeof(publicKey) ~= "buffer" or typeof(signature) ~= "buffer" then
		return false
	end
	if buffer.len(publicKey) ~= PUBLIC_KEY_SIZE or buffer.len(signature) ~= SIGNATURE_SIZE then
		return false
	end
	if bit32.band(buffer.readu8(signature, 63), 0xE0) ~= 0 then
		return false
	end

	local commitmentBytes = buffer.create(32)
	buffer.copy(commitmentBytes, 0, signature, 0, 32)
	local responseBytes = buffer.create(32)
	buffer.copy(responseBytes, 0, signature, 32, 32)
	if not FieldQuadratic.IsValidScalar(responseBytes) then
		return false
	end

	local publicPoint = Edwards25519.Decode(publicKey)
	if not publicPoint then
		return false
	end
	local commitmentPoint = Edwards25519.Decode(commitmentBytes)
	if not commitmentPoint then
		return false
	end
	if isSmallOrder(publicPoint) or isSmallOrder(commitmentPoint) then
		return false
	end

	-- SHA512 returns a shared buffer: decode it before the next hash.
	local challenge = FieldQuadratic.DecodeWide(SHA512(concat(commitmentBytes, publicKey, message)))

	local response = FieldQuadratic.Decode(responseBytes)
	local responseBits, responseBitCount = FieldQuadratic.Bits(response)
	local sB = Edwards25519.MulG(responseBits, responseBitCount)

	local challengeBits, challengeBitCount = FieldQuadratic.Bits(challenge)
	local kA = Edwards25519.Mul(publicPoint, challengeBits, challengeBitCount)

	local rkA = Edwards25519.Add(commitmentPoint, Edwards25519.Niels(kA))
	local difference = Edwards25519.Sub(rkA, Edwards25519.Niels(sB))
	difference = Edwards25519.Double(difference)
	difference = Edwards25519.Double(difference)
	difference = Edwards25519.Double(difference)

	local differenceX = buffer.create(104)
	local differenceT = buffer.create(104)
	buffer.copy(differenceX, 0, difference, 0 * 104, 104)
	buffer.copy(differenceT, 0, difference, 3 * 104, 104)
	return FieldPrime.Eqz(differenceX) and FieldPrime.Eqz(differenceT)
end

-- SHA-512 of `message`, as a fresh 64-byte buffer (the vendored SHA512 reuses one result buffer).
function Ed25519.sha512(message: buffer): buffer
	local digest = SHA512(message)
	local copy = buffer.create(64)
	buffer.copy(copy, 0, digest, 0, 64)
	return copy
end

return Ed25519
