# TKey: the record header every object in a ROOT file is wrapped in.
#
# A ROOT file is a flat sequence of these records. The key gives the object's
# class, name, title and cycle, its compressed and uncompressed lengths, and —
# redundantly — its own offset, which is what makes a damaged file partially
# recoverable by scanning.

"""
    START_BIG_FILE

Offset past which ROOT switches to 64-bit pointers. A key or directory written
at or beyond this offset stores its seek fields in eight bytes rather than four
and adds 1000 to its version to say so.
"""
const START_BIG_FILE = 2_000_000_000

"""
    Key

A `TKey` record header.

`nbytes` counts the key *and* its payload on disk; `objlen` is the payload's
size once decompressed. The two being equal, after `keylen` is taken off
`nbytes`, is exactly how ROOT records "this object was stored uncompressed" —
see [`is_compressed`](@ref).

A negative `nbytes` does not describe an object at all: it marks a gap left by
a deleted record, and the rest of the header is not present.
"""
mutable struct Key
    nbytes::Int32
    rvers::Int16
    objlen::Int32
    datetime::DateTime
    keylen::Int32
    cycle::Int16
    seekkey::Int64
    seekpdir::Int64
    class::String
    name::String
    title::String
end

"Current `TKey` class version."
const KEY_VERSION = Int16(4)

function Key(;
    name::AbstractString="",
    title::AbstractString="",
    class::AbstractString="",
    cycle::Integer=1,
    objlen::Integer=0,
    nbytes::Integer=0,
    keylen::Integer=0,
    seekkey::Integer=0,
    seekpdir::Integer=0,
    rvers::Integer=KEY_VERSION,
    datetime::DateTime=_now_utc(),
)
    return Key(
        Int32(nbytes),
        Int16(rvers),
        Int32(objlen),
        datetime,
        Int32(keylen),
        Int16(cycle),
        Int64(seekkey),
        Int64(seekpdir),
        String(class),
        String(name),
        String(title),
    )
end

_now_utc() = Dates.now(Dates.UTC)

"Whether this key's seek fields are 64-bit."
is_bigfile(k::Key) = k.rvers > 1000

"""
    is_compressed(k::Key) -> Bool

Whether the payload on disk is compressed. ROOT stores no flag for this: the
payload occupies `nbytes - keylen` bytes on disk and `objlen` bytes in memory,
and compression is precisely the case where those differ.
"""
is_compressed(k::Key) = k.objlen != k.nbytes - k.keylen

"Whether this key marks a gap left by a deleted record rather than an object."
is_gap(k::Key) = k.nbytes < 0

"Bytes a `TString` of `s` occupies, including its length prefix."
function tstring_sizeof(s::AbstractString)
    return ncodeunits(s) < 255 ? 1 + ncodeunits(s) : 5 + ncodeunits(s)
end

"""
    keylen_for(name, title, class; bigfile=false) -> Int32

Size of the key header for an object with these names.

The header is variable-length because the three names are inline, so this must
be computed before a key can be placed — the payload starts `keylen` bytes
after the key. `TBasket` is special: ROOT extends the key itself with the
basket's own bookkeeping rather than putting it in the payload.
"""
function keylen_for(
    name::AbstractString, title::AbstractString, class::AbstractString; bigfile::Bool=false
)
    n = 22                                  # fixed fields, 32-bit seeks
    bigfile && (n += 8)                     # 64-bit seekkey and seekpdir
    n += 4                                  # fDatime
    n += tstring_sizeof(class)
    n += tstring_sizeof(name)
    n += tstring_sizeof(title)
    if class == "TBasket"
        n += 2 + 4 + 4 + 4 + 4 + 1          # version, bufsize, nevsize, nevbuf, last, flag
    end
    return Int32(n)
end

"""
    read_key(r::RBuffer) -> Key

Decode a key header at the cursor.
"""
function read_key(r::RBuffer)
    k = Key()
    k.nbytes = readbe(r, Int32)
    if k.nbytes < 0
        # A gap record: only the length is meaningful.
        k.class = "[GAP]"
        return k
    end
    k.rvers = readbe(r, Int16)
    k.objlen = readbe(r, Int32)
    k.datetime = datime_to_datetime(readbe(r, UInt32))
    k.keylen = Int32(readbe(r, Int16))
    k.cycle = readbe(r, Int16)
    if is_bigfile(k)
        k.seekkey = readbe(r, Int64)
        k.seekpdir = readbe(r, Int64)
    else
        k.seekkey = Int64(readbe(r, Int32))
        k.seekpdir = Int64(readbe(r, Int32))
    end
    k.class = read_tstring(r)
    k.name = read_tstring(r)
    k.title = read_tstring(r)
    # ROOT 4 and earlier wrote sub-directories under the class name
    # "TDirectory"; every reader since treats the two as the same thing.
    k.class == "TDirectory" && (k.class = "TDirectoryFile")
    return k
end

"""
    write_key!(w::WBuffer, k::Key) -> w

Encode a key header. A key placed past [`START_BIG_FILE`](@ref) is promoted to
the 64-bit form here rather than at construction, because its offset is not
settled until the file makes room for it.
"""
function write_key!(w::WBuffer, k::Key)
    writebe!(w, k.nbytes)
    k.nbytes < 0 && return w

    if k.seekkey > START_BIG_FILE && k.rvers < 1000
        k.rvers += Int16(1000)
    end

    writebe!(w, k.rvers)
    writebe!(w, k.objlen)
    writebe!(w, datetime_to_datime(k.datetime))
    writebe!(w, Int16(k.keylen))
    writebe!(w, k.cycle)
    if is_bigfile(k)
        writebe!(w, k.seekkey)
        writebe!(w, k.seekpdir)
    else
        writebe!(w, Int32(k.seekkey))
        writebe!(w, Int32(k.seekpdir))
    end
    write_tstring!(w, k.class)
    write_tstring!(w, k.name)
    write_tstring!(w, k.title)
    return w
end

"""
    key_payload(src::AbstractSource, k::Key) -> Vector{UInt8}

The key's object bytes, decompressed if need be.

The uncompressed length comes from the key, not from the compressed stream, so
a payload that does not expand to exactly `objlen` bytes is rejected rather
than returned short.
"""
function key_payload(src::AbstractSource, k::Key)
    is_gap(k) && throw(ArgumentError("TTree: cannot read the payload of a gap record"))
    k.objlen == 0 && return UInt8[]
    start = k.seekkey + Int64(k.keylen)
    n = Int(k.nbytes) - Int(k.keylen)
    raw = read_at(src, start, n)
    is_compressed(k) && return Compress.decompress(raw, k.objlen)
    return raw isa Vector{UInt8} ? raw : collect(raw)
end

"""
    key_buffer(src::AbstractSource, k::Key; sinfos=nothing, factory=nothing) -> RBuffer

An [`RBuffer`](@ref) over the key's payload, with its `offset` set to the key
length so that object back-references inside the payload resolve to the
positions ROOT recorded.
"""
function key_buffer(src::AbstractSource, k::Key; sinfos=nothing, factory=nothing)
    return RBuffer(key_payload(src, k); offset=k.keylen, sinfos=sinfos, factory=factory)
end

function Base.show(io::IO, k::Key)
    if is_gap(k)
        return print(io, "Key([GAP], ", -k.nbytes, " bytes)")
    end
    print(io, "Key(", repr(k.name), ";", k.cycle, ", class=", k.class)
    print(io, ", ", k.objlen, " bytes")
    is_compressed(k) && print(io, " (", k.nbytes - k.keylen, " on disk)")
    return print(io, " @", k.seekkey, ")")
end
