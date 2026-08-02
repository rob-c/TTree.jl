# The read side of ROOT's serialization: a cursor over a decompressed record,
# with the big-endian accessors and the framing rules (byte-count headers,
# class tags, back-references) that ROOT's TBufferFile applies.

"""
    ROOTPrimitive

The scalar types ROOT streams directly, with no framing of their own. These are
the element types [`read_array!`](@ref) may bulk-copy.
"""
const ROOTPrimitive = Union{
    Bool,Int8,UInt8,Int16,UInt16,Int32,UInt32,Int64,UInt64,Float32,Float64
}

"""
    RBuffer(data; offset=0, sinfos=nothing, factory=nothing)

A read cursor over `data`, the *decompressed* bytes of one ROOT record.

`offset` is the position of `data[1]` within the record ROOT itself numbered —
for a key payload, the key length. It matters because object back-references
are recorded by absolute buffer position: decode a payload with `offset` unset
and every reference lands `keylen` bytes early.

`sinfos` is the streamer-info context used to resolve class versions;
`factory` maps a class name to a fresh instance for [`read_object_any`](@ref).
Both are optional — buffers that only carry primitives (a `TBasket`'s payload,
say) need neither.
"""
mutable struct RBuffer
    data::Vector{UInt8}
    cursor::Int                        # 0-based index of the next byte in `data`
    offset::Int
    refs::Union{Nothing,Dict{Int64,Any}}
    sinfos::Any
    factory::Any
end

function RBuffer(data::Vector{UInt8}; offset::Integer=0, sinfos=nothing, factory=nothing)
    return RBuffer(data, 0, Int(offset), nothing, sinfos, factory)
end

"""
    pos(r::RBuffer) -> Int64

Cursor position in the coordinates ROOT uses — the offset within `data` plus
the buffer's own displacement. This, not the raw index, is what reference tags
are keyed on.
"""
pos(r::RBuffer) = Int64(r.cursor + r.offset)

"""
    seek!(r::RBuffer, p::Integer) -> RBuffer

Move the cursor to ROOT-coordinate position `p` (see [`pos`](@ref)).
"""
function seek!(r::RBuffer, p::Integer)
    r.cursor = Int(p) - r.offset
    return r
end

"Advance the cursor by `n` bytes without decoding them."
skip!(r::RBuffer, n::Integer) = (r.cursor += Int(n); r)

"Bytes left between the cursor and the end of the buffer."
remaining(r::RBuffer) = length(r.data) - r.cursor

Base.eof(r::RBuffer) = remaining(r) <= 0

"Lazily materialise the reference map; buffers without back-references never pay for it."
function refmap!(r::RBuffer)
    if r.refs === nothing
        r.refs = Dict{Int64,Any}()
    end
    return r.refs::Dict{Int64,Any}
end

@inline function _need(r::RBuffer, n::Int)
    if r.cursor < 0 || r.cursor + n > length(r.data)
        throw(
            BoundsError(
                r.data, "RBuffer: need $n bytes at $(r.cursor) of $(length(r.data))"
            ),
        )
    end
    return nothing
end

# Assembled byte-by-byte rather than loaded and byte-swapped: ROOT records are
# packed with no regard for alignment, and an unaligned `unsafe_load` is not
# portable. `sizeof(U)` is a compile-time constant, so the loop unrolls.
@inline function _load_be(r::RBuffer, ::Type{U}) where {U<:Unsigned}
    n = sizeof(U)
    _need(r, n)
    v = zero(U)
    c = r.cursor
    @inbounds for i in 1:n
        v = (v << 8) | U(r.data[c + i])
    end
    r.cursor = c + n
    return v
end

"""
    readbe(r::RBuffer, T) -> T

Read one big-endian value of type `T`. ROOT is big-endian on the wire and on
disk regardless of the host.
"""
readbe(r::RBuffer, ::Type{UInt8}) = _load_be(r, UInt8)
readbe(r::RBuffer, ::Type{Int8}) = reinterpret(Int8, _load_be(r, UInt8))
readbe(r::RBuffer, ::Type{UInt16}) = _load_be(r, UInt16)
readbe(r::RBuffer, ::Type{Int16}) = reinterpret(Int16, _load_be(r, UInt16))
readbe(r::RBuffer, ::Type{UInt32}) = _load_be(r, UInt32)
readbe(r::RBuffer, ::Type{Int32}) = reinterpret(Int32, _load_be(r, UInt32))
readbe(r::RBuffer, ::Type{UInt64}) = _load_be(r, UInt64)
readbe(r::RBuffer, ::Type{Int64}) = reinterpret(Int64, _load_be(r, UInt64))
readbe(r::RBuffer, ::Type{Float32}) = reinterpret(Float32, _load_be(r, UInt32))
readbe(r::RBuffer, ::Type{Float64}) = reinterpret(Float64, _load_be(r, UInt64))
readbe(r::RBuffer, ::Type{Bool}) = _load_be(r, UInt8) != 0x00

"Host-order value from a big-endian one; identity for single-byte types."
@inline _from_be(v::T) where {T<:Union{Int16,UInt16,Int32,UInt32,Int64,UInt64}} = ntoh(v)
@inline _from_be(v::T) where {T<:Union{Float32,Float64}} = ntoh(v)
@inline _from_be(v::T) where {T<:Union{Bool,Int8,UInt8}} = v

"""
    read_array!(r::RBuffer, dst::AbstractVector{T}) -> dst

Fill `dst` from the buffer. The bytes are copied in bulk and byte-swapped in
place rather than decoded one value at a time — this is the path every
`TBasket` payload takes, so the difference is measurable.
"""
function read_array!(r::RBuffer, dst::Vector{T}) where {T<:ROOTPrimitive}
    nb = length(dst) * sizeof(T)
    _need(r, nb)
    GC.@preserve dst begin
        unsafe_copyto!(Ptr{UInt8}(pointer(dst)), pointer(r.data, r.cursor + 1), UInt(nb))
    end
    r.cursor += nb
    if sizeof(T) > 1
        @inbounds for i in eachindex(dst)
            dst[i] = _from_be(dst[i])
        end
    end
    return dst
end

"""
    read_array(r::RBuffer, T, n) -> Vector{T}

Allocate and fill a vector of `n` values of type `T`.
"""
function read_array(r::RBuffer, ::Type{T}, n::Integer) where {T<:ROOTPrimitive}
    return read_array!(r, Vector{T}(undef, Int(n)))
end

"""
    read_bytes(r::RBuffer, n) -> Vector{UInt8}

Copy the next `n` raw bytes out of the buffer.
"""
function read_bytes(r::RBuffer, n::Integer)
    n = Int(n)
    _need(r, n)
    out = r.data[(r.cursor + 1):(r.cursor + n)]
    r.cursor += n
    return out
end

"""
    read_tstring(r::RBuffer) -> String

Read a `TString`: a one-byte length, or `0xFF` followed by a four-byte length
for strings of 255 bytes or more, then that many bytes of content.
"""
function read_tstring(r::RBuffer)
    n = Int(readbe(r, UInt8))
    if n == 255
        n = Int(readbe(r, UInt32))
    end
    n == 0 && return ""
    _need(r, n)
    s = String(@view r.data[(r.cursor + 1):(r.cursor + n)])
    r.cursor += n
    return s
end

"""
    read_cstring(r::RBuffer, nmax=80) -> String

Read a NUL-terminated string of at most `nmax` bytes, consuming the terminator.
This is the framing ROOT uses for class names inside object tags, which is a
different encoding from [`read_tstring`](@ref).
"""
function read_cstring(r::RBuffer, nmax::Integer=80)
    io = IOBuffer()
    for _ in 1:nmax
        c = readbe(r, UInt8)
        c == 0x00 && break
        write(io, c)
    end
    return String(take!(io))
end

"""
    read_stdstring(r::RBuffer) -> String

Read a `std::string` as ROOT streams it — a version header wrapping a
`TString`-encoded body.
"""
function read_stdstring(r::RBuffer)
    hdr = read_header(r, "string")
    s = read_tstring(r)
    check_header(r, hdr)
    return s
end

"""
    read_float16(r::RBuffer, nbits=12) -> Float32
    read_float16(r::RBuffer, xmin, xmax, factor) -> Float32

Read a `Float16_t` — a `float` ROOT stores in fewer than four bytes.

With a range, the value is an unsigned integer to be scaled back into
`[xmin, xmax]`. Without one it is the float's exponent and the top `nbits` of
its mantissa, three bytes in all, and the low mantissa bits are simply lost.
"""
function read_float16(r::RBuffer, nbits::Integer=12)
    exp = readbe(r, UInt8)
    man = readbe(r, UInt16)
    ix = UInt32(exp) << 23
    ix |= (UInt32(man) & ((UInt32(1) << (nbits + 1)) - UInt32(1))) << (23 - nbits)
    x = reinterpret(Float32, ix)
    return (UInt32(man) & (UInt32(1) << (nbits + 1))) == 0 ? x : -x
end

function read_float16(r::RBuffer, xmin::Real, xmax::Real, factor::Real)
    factor == 0 && return read_float16(r, _range_bits(xmin, xmax))
    return Float32(readbe(r, UInt32) / factor + xmin)
end

"""
    read_double32(r::RBuffer, nbits=0) -> Float64
    read_double32(r::RBuffer, xmin, xmax, factor) -> Float64

Read a `Double32_t` — a `double` ROOT stores in four bytes or fewer.

Without a range it is a plain `float`, which is what the type is for; with one
it is a scaled integer, as for [`read_float16`](@ref).
"""
read_double32(r::RBuffer) = Float64(readbe(r, Float32))

function read_double32(r::RBuffer, xmin::Real, xmax::Real, factor::Real)
    factor == 0 && return read_double32(r)
    return readbe(r, UInt32) / factor + xmin
end

"""
    _range_bits(xmin, xmax) -> Int

Mantissa width of an unscaled `Float16_t`.

A member's title may ask for a bit count without a range — `[0, 0, 8]` — which
the object layer folds into `xmin`, and this recovers. Twelve is ROOT's default
when the title says nothing.
"""
function _range_bits(xmin::Real, xmax::Real)
    (xmin >= xmax && 0 < xmin < 15) && return Int(floor(xmin))
    return 12
end

"""
    Header

The framing that precedes a streamed object: its byte count (`len`, zero when
the object was written without one), class version, and the buffer position the
header began at. `memberwise` records that a collection's elements were
streamed member-wise rather than object-wise.
"""
struct Header
    class::String
    vers::Int16
    len::Int32
    pos::Int64
    memberwise::Bool
end

"""
    read_header(r::RBuffer, class="", vmax=-1) -> Header

Read an object's framing header.

ROOT writes most objects as `(nbytes | KBYTE_COUNT_MASK, version, …)`, but
some — notably members of a class streamed without its own byte count — carry a
bare version. The two are told apart by [`KBYTE_COUNT_MASK`](@ref); when it is
absent the four bytes just read were *not* a count, so the cursor rewinds and
re-reads them as a version.

A non-positive version means the class was written before versioning, and is
identified instead by a checksum which is matched against `class`'s streamer
info when a context is available.
"""
function read_header(r::RBuffer, class::AbstractString="", vmax::Integer=-1)
    p = pos(r)
    bcnt = readbe(r, UInt32)
    local len::Int32
    local vers::Int16
    if (UInt64(bcnt) & KBYTE_COUNT_MASK) != 0
        len = Int32(UInt64(bcnt) & ~UInt64(KBYTE_COUNT_MASK))
        vers = reinterpret(Int16, readbe(r, UInt16))
    else
        seek!(r, p)
        len = Int32(0)
        vers = reinterpret(Int16, readbe(r, UInt16))
    end

    memberwise = (vers & Int16(KSTREAMED_MEMBERWISE)) != 0
    if memberwise
        vers &= ~Int16(KSTREAMED_MEMBERWISE)
    end

    if vers <= 0 && !isempty(class) && r.sinfos !== nothing
        si = streamer_info(r.sinfos, class, -1)
        if si !== nothing
            chksum = readbe(r, UInt32)
            if UInt32(class_checksum(si)) == chksum
                vers = Int16(class_version(si))
            else
                # Not our checksum: the four bytes belong to the payload.
                skip!(r, -4)
            end
        end
    end

    return Header(String(class), vers, len, p, memberwise)
end

"""
    check_header(r::RBuffer, hdr::Header) -> Bool

Reposition the cursor to the end of the object `hdr` framed, returning whether
it was already there.

This is ROOT's `CheckByteCount`, and it is what makes partial decoding safe: a
class we understand only in part still leaves the cursor where the *next*
object begins, so one unknown member does not desynchronise the whole record.
A zero `len` means the object was written without a count and nothing can be
checked.
"""
function check_header(r::RBuffer, hdr::Header)
    hdr.len <= 0 && return true
    want = hdr.pos + Int64(hdr.len) + 4
    ok = pos(r) == want
    ok || seek!(r, want)
    return ok
end

"""
    read_object_any(r::RBuffer) -> Any

Read a polymorphic object reference — ROOT's `ReadObjectAny`.

The leading tag is one of: a null marker; a back-reference to an object already
decoded in this buffer; [`KNEW_CLASS_TAG`](@ref), introducing a spelled-out
class name; or a back-reference to a class already named. Both kinds of
back-reference are keyed on buffer position plus [`KMAP_OFFSET`](@ref), which is
why an `RBuffer` must know its `offset` within the record.

Returns `nothing` for a null pointer, and for a class the buffer's factory does
not recognise — in the latter case the cursor is advanced past the object so
decoding can continue.
"""
function read_object_any(r::RBuffer)
    beg = pos(r)
    bcnt = readbe(r, UInt32)
    vers = 0
    start = Int64(0)
    local tag::UInt32

    if (UInt64(bcnt) & KBYTE_COUNT_MASK) == 0 || bcnt == KNEW_CLASS_TAG
        tag = bcnt
        bcnt = UInt32(0)
    else
        vers = 1
        bcnt &= ~UInt32(KBYTE_COUNT_MASK)
        start = pos(r)
        tag = readbe(r, UInt32)
    end

    refs = refmap!(r)
    tag64 = Int64(tag)

    if (tag64 & KCLASS_MASK) == 0
        # An object back-reference (or a null).
        tag64 == KNULL_TAG && return nothing
        if tag == 1
            # "Self" reference; ROOT emits it only for recursive structures we
            # do not model. Skip the object rather than mis-decode it.
            seek!(r, beg + Int64(bcnt) + 4)
            return nothing
        end
        obj = get(refs, tag64, nothing)
        if obj === nothing
            seek!(r, beg + Int64(bcnt) + 4)
            return nothing
        end
        return obj
    elseif tag == KNEW_CLASS_TAG
        cname = read_cstring(r, 80)
        if vers > 0
            refs[start + KMAP_OFFSET] = cname
        else
            refs[Int64(length(refs)) + 1] = cname
        end
        obj = _construct(r, cname, beg, bcnt)
        if vers > 0
            refs[beg + KMAP_OFFSET] = obj
        else
            refs[Int64(length(refs)) + 1] = obj
        end
        return obj
    else
        # A class back-reference: the class was named earlier in this buffer.
        ref = tag64 & ~Int64(KCLASS_MASK)
        cname = get(refs, ref, nothing)
        if !(cname isa AbstractString)
            seek!(r, beg + Int64(bcnt) + 4)
            return nothing
        end
        obj = _construct(r, cname, beg, bcnt)
        if vers > 0
            refs[beg + KMAP_OFFSET] = obj
        else
            refs[Int64(length(refs)) + 1] = obj
        end
        return obj
    end
end

"Instantiate `cname` via the buffer's factory and stream it, or skip it if unknown."
function _construct(r::RBuffer, cname::AbstractString, beg::Int64, bcnt::UInt32)
    obj = r.factory === nothing ? nothing : r.factory(cname)
    if obj === nothing
        # Unknown class. The byte count tells us exactly how much to step over;
        # without one there is nothing to do but fail loudly, since guessing
        # would desynchronise every object that follows.
        bcnt == 0 && throw(
            ArgumentError(
                "TTree: unknown class $(repr(cname)) written without a byte count"
            ),
        )
        seek!(r, beg + Int64(bcnt) + 4)
        return nothing
    end
    unmarshal!(obj, r)
    return obj
end

"""
    unmarshal!(obj, r::RBuffer) -> obj

Stream `obj` in from `r`. Concrete ROOT classes add methods; this is the hook
[`read_object_any`](@ref) calls once it has instantiated a class.
"""
function unmarshal! end

"""
    streamer_info(ctx, class, version) -> Any

Look up the streamer info for `class` at `version` (negative meaning "latest")
in a streamer context. Implemented by the file layer; declared here because
[`read_header`](@ref) needs it to resolve pre-versioning classes.
"""
function streamer_info end

"""
    described_class(si) -> AbstractString

Name of the C++ class a streamer info describes.

Distinct from [`classname`](@ref), which for a streamer info is always
`"TStreamerInfo"`: one is what the object *is*, the other what it is *about*.
"""
function described_class end

"Class version recorded in a streamer info."
function class_version end

"Checksum recorded in a streamer info, used to identify unversioned classes."
function class_checksum end
