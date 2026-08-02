# xxHash64, needed only because ROOT prefixes every LZ4 block with one.
#
# Implemented here rather than pulled in as a dependency: it is sixty lines,
# the alternative packages are unmaintained or bring a JLL along, and having it
# in-tree means the LZ4 read path can *verify* the checksum instead of skipping
# it the way most ROOT readers do.

const _XXH_P1 = 0x9E3779B185EBCA87
const _XXH_P2 = 0xC2B2AE3D27D4EB4F
const _XXH_P3 = 0x165667B19E3779F9
const _XXH_P4 = 0x85EBCA77C2B2AE63
const _XXH_P5 = 0x27D4EB2F165667C5

@inline _rotl64(x::UInt64, r::Int) = (x << r) | (x >> (64 - r))
@inline _xxh_round(acc::UInt64, inp::UInt64) = _rotl64(acc + inp * _XXH_P2, 31) * _XXH_P1

@inline function _xxh_merge(acc::UInt64, val::UInt64)
    val = _rotl64(val * _XXH_P2, 31) * _XXH_P1
    return (acc ⊻ val) * _XXH_P1 + _XXH_P4
end

# xxHash reads its input little-endian on every platform, which is the one
# place in this package where the byte order is *not* ROOT's big-endian.
@inline function _le64(b::AbstractVector{UInt8}, i::Int)
    v = UInt64(0)
    @inbounds for k in 7:-1:0
        v = (v << 8) | UInt64(b[i + k])
    end
    return v
end

@inline function _le32(b::AbstractVector{UInt8}, i::Int)
    v = UInt32(0)
    @inbounds for k in 3:-1:0
        v = (v << 8) | UInt32(b[i + k])
    end
    return v
end

"""
    xxhash64(data, seed=0) -> UInt64

The 64-bit xxHash of `data`. ROOT stores this, big-endian, in the eight bytes
that precede every LZ4-compressed block.
"""
function xxhash64(data::AbstractVector{UInt8}, seed::UInt64=UInt64(0))
    len = length(data)
    p = firstindex(data)
    last = p + len

    local h::UInt64
    if len >= 32
        v1 = seed + _XXH_P1 + _XXH_P2
        v2 = seed + _XXH_P2
        v3 = seed
        v4 = seed - _XXH_P1
        while p + 31 < last
            v1 = _xxh_round(v1, _le64(data, p))
            p += 8
            v2 = _xxh_round(v2, _le64(data, p))
            p += 8
            v3 = _xxh_round(v3, _le64(data, p))
            p += 8
            v4 = _xxh_round(v4, _le64(data, p))
            p += 8
        end
        h = _rotl64(v1, 1) + _rotl64(v2, 7) + _rotl64(v3, 12) + _rotl64(v4, 18)
        h = _xxh_merge(h, v1)
        h = _xxh_merge(h, v2)
        h = _xxh_merge(h, v3)
        h = _xxh_merge(h, v4)
    else
        h = seed + _XXH_P5
    end

    h += UInt64(len)

    while p + 7 < last
        h = _rotl64(h ⊻ _xxh_round(UInt64(0), _le64(data, p)), 27) * _XXH_P1 + _XXH_P4
        p += 8
    end
    if p + 3 < last
        h = _rotl64(h ⊻ (UInt64(_le32(data, p)) * _XXH_P1), 23) * _XXH_P2 + _XXH_P3
        p += 4
    end
    while p < last
        @inbounds h = _rotl64(h ⊻ (UInt64(data[p]) * _XXH_P5), 11) * _XXH_P1
        p += 1
    end

    h ⊻= h >> 33
    h *= _XXH_P2
    h ⊻= h >> 29
    h *= _XXH_P3
    h ⊻= h >> 32
    return h
end
