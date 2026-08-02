"""
    TTree.Compress

Layer 2: ROOT's compression envelope.

A compressed ROOT payload is not a single compressed stream. It is a sequence
of independently compressed blocks, each at most 16 MiB uncompressed, each
introduced by a nine-byte header naming the algorithm and giving both the
compressed and uncompressed block lengths. Readers walk the sequence until the
known uncompressed total is reached; a payload whose blocks were written by
different algorithms is legal and does occur, so the algorithm is taken from
each block header rather than from the file's compression setting.

The file-level setting is only a *request*: ROOT stores a payload uncompressed
whenever compression would not have made it smaller, and the key layer detects
that case by comparing lengths rather than by inspecting these headers.
"""
module Compress

using CodecZlib: ZlibDecompressor, ZlibCompressor
using CodecXz: XzDecompressor, XzCompressor
using CodecZstd: ZstdDecompressor, ZstdCompressor
using CodecLz4: lz4_compress, lz4_hc_compress, lz4_decompress
using TranscodingStreams: TranscodingStreams, transcode

export Settings,
    compression_code,
    settings_from,
    compress,
    decompress,
    decompress!,
    xxhash64,
    ALG_INHERIT,
    ALG_GLOBAL,
    ALG_ZLIB,
    ALG_LZMA,
    ALG_OLD,
    ALG_LZ4,
    ALG_ZSTD

include("xxhash.jl")

"Compression algorithm: use whatever the enclosing file or tree specifies."
const ALG_INHERIT = -1
"Compression algorithm: use ROOT's global default."
const ALG_GLOBAL = 0
"Compression algorithm: zlib (`ZL`)."
const ALG_ZLIB = 1
"Compression algorithm: LZMA, carried in an xz container (`XZ`)."
const ALG_LZMA = 2
"Compression algorithm: ROOT's pre-2000 scheme (`CS`). Read support only, and not implemented."
const ALG_OLD = 3
"Compression algorithm: LZ4 raw blocks with an xxHash64 prefix (`L4`)."
const ALG_LZ4 = 4
"Compression algorithm: Zstandard (`ZS`)."
const ALG_ZSTD = 5

"Bytes in a block header: two of magic, one of method, three of compressed size, three of uncompressed size."
const HEADER_SIZE = 9

"""
    MAX_BLOCK_SIZE

Largest block ROOT will emit. The block header spends only three bytes on each
length, so neither the compressed nor the uncompressed size of a block can
exceed this.
"""
const MAX_BLOCK_SIZE = 0xffffff

"Below this many bytes ROOT does not attempt compression at all."
const MIN_COMPRESS_SIZE = 512

"The eight-byte xxHash64 that precedes the payload of every LZ4 block."
const LZ4_CHECKSUM_SIZE = 8

"""
    Settings(alg, lvl)

A compression algorithm and level. ROOT packs the pair into a single integer as
`alg * 100 + lvl`; see [`compression_code`](@ref) and [`settings_from`](@ref).
"""
struct Settings
    alg::Int
    lvl::Int
end

"ROOT's default: zlib at level 1, chosen for speed over ratio."
const DEFAULT_SETTINGS = Settings(ALG_ZLIB, 1)

"""
    settings_from(code::Integer) -> Settings

Unpack a `fCompress` field.
"""
settings_from(code::Integer) = Settings(Int(code) ÷ 100, Int(code) % 100)

"""
    compression_code(s::Settings) -> Int32

Pack `s` into the integer form stored in a file or tree header.
"""
compression_code(s::Settings) = Int32(s.alg * 100 + s.lvl)

"Algorithm named by a block header's two magic bytes."
function kind_of(b::AbstractVector{UInt8}, i::Int)
    m1 = b[i]
    m2 = b[i + 1]
    m1 == UInt8('Z') && m2 == UInt8('L') && return ALG_ZLIB
    m1 == UInt8('X') && m2 == UInt8('Z') && return ALG_LZMA
    m1 == UInt8('L') && m2 == UInt8('4') && return ALG_LZ4
    m1 == UInt8('Z') && m2 == UInt8('S') && return ALG_ZSTD
    m1 == UInt8('C') && m2 == UInt8('S') && return ALG_OLD
    return -1
end

"Three-byte little-endian length, as block headers store both of their sizes."
@inline function _len24(b::AbstractVector{UInt8}, i::Int)
    return Int(b[i]) | (Int(b[i + 1]) << 8) | (Int(b[i + 2]) << 16)
end

@inline function _set_len24!(b::AbstractVector{UInt8}, i::Int, v::Integer)
    b[i] = v % UInt8
    b[i + 1] = (v >> 8) % UInt8
    b[i + 2] = (v >> 16) % UInt8
    return b
end

"""
    decompress!(dst::Vector{UInt8}, src::AbstractVector{UInt8}) -> dst

Expand the block sequence in `src` into `dst`, which must already be sized to
the payload's known uncompressed length.

That length is the loop's terminating condition, deliberately: it comes from
the key header, which ROOT wrote, rather than from the block stream itself.
A truncated or mis-sized payload therefore fails here with a bounds error
instead of silently yielding a short object.
"""
function decompress!(dst::Vector{UInt8}, src::AbstractVector{UInt8})
    total = length(dst)
    beg = 0
    s = firstindex(src)
    send = s + length(src)

    while beg < total
        s + HEADER_SIZE - 1 < send || throw(
            ArgumentError(
                "TTree: compressed payload ended after $beg of $total bytes " *
                "(no room for a block header)",
            ),
        )
        alg = kind_of(src, s)
        csz = _len24(src, s + 3)
        usz = _len24(src, s + 6)
        alg == -1 && throw(
            ArgumentError(
                "TTree: unknown compression magic $(repr(Char(src[s])))$(repr(Char(src[s+1])))",
            ),
        )
        beg + usz <= total || throw(
            ArgumentError(
                "TTree: compressed block expands to $usz bytes, past the $total-byte payload",
            ),
        )
        s + HEADER_SIZE + csz - 1 < send || throw(
            ArgumentError("TTree: compressed block of $csz bytes runs past the payload")
        )

        blk = @view src[(s + HEADER_SIZE):(s + HEADER_SIZE + csz - 1)]
        _decompress_block!(dst, beg, usz, alg, blk)

        beg += usz
        s += HEADER_SIZE + csz
    end
    return dst
end

"""
    decompress(src, objlen) -> Vector{UInt8}

Allocate a buffer of `objlen` bytes and [`decompress!`](@ref) `src` into it.
"""
function decompress(src::AbstractVector{UInt8}, objlen::Integer)
    return decompress!(Vector{UInt8}(undef, Int(objlen)), src)
end

function _decompress_block!(
    dst::Vector{UInt8}, beg::Int, usz::Int, alg::Int, blk::AbstractVector{UInt8}
)
    if alg == ALG_LZ4
        length(blk) > LZ4_CHECKSUM_SIZE ||
            throw(ArgumentError("TTree: LZ4 block too short to hold its checksum"))
        want = UInt64(0)
        @inbounds for k in 0:7
            want = (want << 8) | UInt64(blk[firstindex(blk) + k])
        end
        body = @view blk[(firstindex(blk) + LZ4_CHECKSUM_SIZE):end]
        got = xxhash64(body)
        got == want || throw(
            ArgumentError(
                "TTree: LZ4 block checksum mismatch " *
                "(stored 0x$(string(want; base=16)), computed 0x$(string(got; base=16)))",
            ),
        )
        out = lz4_decompress(collect(body), usz)
        length(out) == usz || throw(
            ArgumentError("TTree: LZ4 block yielded $(length(out)) bytes, expected $usz"),
        )
        copyto!(dst, beg + 1, out, 1, usz)
        return dst
    end

    if alg == ALG_OLD
        throw(
            ArgumentError(
                "TTree: ROOT's pre-2000 compression (`CS`) is not supported; " *
                "rewrite the file with a current ROOT",
            ),
        )
    end

    codec = if alg == ALG_ZLIB
        ZlibDecompressor
    elseif alg == ALG_LZMA
        XzDecompressor
    elseif alg == ALG_ZSTD
        ZstdDecompressor
    else
        throw(ArgumentError("TTree: unsupported compression algorithm $alg"))
    end

    out = transcode(codec, collect(blk))
    length(out) >= usz ||
        throw(ArgumentError("TTree: block yielded $(length(out)) bytes, expected $usz"))
    copyto!(dst, beg + 1, out, 1, usz)
    return dst
end

"""
    compress(src::AbstractVector{UInt8}, s::Settings) -> Vector{UInt8}

Compress `src` into ROOT's block format, or return it unchanged.

`src` is returned as-is — and the caller is expected to notice, by comparing
lengths — when compression is disabled, when the payload is below
[`MIN_COMPRESS_SIZE`](@ref), or when the compressed form would not actually be
smaller. That last case is not an optimisation but a format requirement: ROOT
signals "stored uncompressed" by making the key's object length equal its
on-disk length, and a payload that grew under compression could not be
described that way.
"""
function compress(src::AbstractVector{UInt8}, s::Settings)
    src = src isa Vector{UInt8} ? src : collect(src)
    if s.alg <= 0 || s.lvl <= 0 || length(src) < MIN_COMPRESS_SIZE
        return src
    end

    out = UInt8[]
    beg = firstindex(src)
    last = beg + length(src)
    while beg < last
        stop = min(beg + MAX_BLOCK_SIZE, last)
        blk = @view src[beg:(stop - 1)]
        enc = _compress_block(s, blk)
        # Not compressible, or not compressible within a block header's three
        # byte lengths: give up on the whole payload rather than emit a mix.
        (enc === nothing || length(out) + length(enc) >= length(src)) && return src
        append!(out, enc)
        beg = stop
    end
    length(out) < length(src) || return src
    return out
end

"Encode one block, or `nothing` if the result would not be smaller than the input."
function _compress_block(s::Settings, blk::AbstractVector{UInt8})
    body, method = if s.alg == ALG_ZLIB
        transcode(ZlibCompressor(; level=s.lvl), collect(blk)), UInt8(8)
    elseif s.alg == ALG_LZMA
        transcode(XzCompressor(; level=s.lvl), collect(blk)), UInt8(0)
    elseif s.alg == ALG_ZSTD
        transcode(ZstdCompressor(; level=s.lvl), collect(blk)), UInt8(1)
    elseif s.alg == ALG_LZ4
        raw = if s.lvl >= 4
            lz4_hc_compress(collect(blk), min(s.lvl, 9))
        else
            lz4_compress(collect(blk))
        end
        isempty(raw) && return nothing
        # ROOT stores the hash of the *compressed* bytes, big-endian, ahead of
        # them; see `_decompress_block!` for the verifying counterpart.
        h = xxhash64(raw)
        pre = Vector{UInt8}(undef, LZ4_CHECKSUM_SIZE + length(raw))
        @inbounds for k in 1:LZ4_CHECKSUM_SIZE
            pre[k] = (h >> (8 * (LZ4_CHECKSUM_SIZE - k))) % UInt8
        end
        copyto!(pre, LZ4_CHECKSUM_SIZE + 1, raw, 1, length(raw))
        pre, UInt8(1)
    else
        throw(ArgumentError("TTree: cannot compress with algorithm $(s.alg)"))
    end

    (length(body) >= length(blk) || length(body) > MAX_BLOCK_SIZE) && return nothing

    magic = _magic(s.alg)
    out = Vector{UInt8}(undef, HEADER_SIZE + length(body))
    out[1] = magic[1]
    out[2] = magic[2]
    out[3] = method
    _set_len24!(out, 4, length(body))
    _set_len24!(out, 7, length(blk))
    copyto!(out, HEADER_SIZE + 1, body, 1, length(body))
    return out
end

function _magic(alg::Int)
    alg == ALG_ZLIB && return (UInt8('Z'), UInt8('L'))
    alg == ALG_LZMA && return (UInt8('X'), UInt8('Z'))
    alg == ALG_LZ4 && return (UInt8('L'), UInt8('4'))
    alg == ALG_ZSTD && return (UInt8('Z'), UInt8('S'))
    return throw(ArgumentError("TTree: no block magic for algorithm $alg"))
end

end # module Compress
