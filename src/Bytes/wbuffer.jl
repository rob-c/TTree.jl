# The write side of ROOT's serialization. Deliberately the mirror image of
# `rbuffer.jl`: every framing rule appears once as a reader and once as a
# writer, so a round-trip discrepancy shows up as a visible asymmetry here
# rather than as a corrupt file at the far end.

"""
    WBuffer(; offset=0)
    WBuffer(data::Vector{UInt8}; offset=0)

A growable big-endian byte sink for one ROOT record.

`offset` plays the same role as it does for [`RBuffer`](@ref): it is the
position of `data[1]` within the record ROOT numbers, so that back-references
written into the buffer agree with the positions a reader will compute.

The cursor can move backwards — [`set_header!`](@ref) relies on it to patch a
byte count once the object's length is known — so writes overwrite rather than
append whenever the cursor is not at the end.
"""
mutable struct WBuffer
    data::Vector{UInt8}
    cursor::Int                        # 0-based write position within `data`
    offset::Int
    refs::Union{Nothing,Dict{Any,Int64}}
end

function WBuffer(data::Vector{UInt8}=UInt8[]; offset::Integer=0)
    return WBuffer(data, length(data), Int(offset), nothing)
end

pos(w::WBuffer) = Int64(w.cursor + w.offset)

function seek!(w::WBuffer, p::Integer)
    w.cursor = Int(p) - w.offset
    return w
end

"""
    bytes(w::WBuffer) -> Vector{UInt8}

The bytes written so far. The buffer is never truncated by a backwards seek,
so this is the high-water mark, not the cursor.
"""
bytes(w::WBuffer) = w.data

Base.length(w::WBuffer) = length(w.data)

"""
    written_classes(w::WBuffer) -> Vector{String}

Every class name [`write_object_any!`](@ref) emitted into `w`.

The reference map already holds them — a class is entered the first time it is
named, so that the second mention can be a back-reference — which makes this an
exact record of what the buffer contains, rather than a guess from walking the
object graph again.
"""
function written_classes(w::WBuffer)
    w.refs === nothing && return String[]
    return String[k for k in keys(w.refs::Dict{Any,Int64}) if k isa String]
end

function refmap!(w::WBuffer)
    if w.refs === nothing
        w.refs = Dict{Any,Int64}()
    end
    return w.refs::Dict{Any,Int64}
end

@inline function _ensure!(w::WBuffer, n::Int)
    need = w.cursor + n
    if need > length(w.data)
        resize!(w.data, need)
    end
    return nothing
end

@inline function _store_be!(w::WBuffer, v::U) where {U<:Unsigned}
    n = sizeof(U)
    _ensure!(w, n)
    c = w.cursor
    @inbounds for i in 1:n
        w.data[c + i] = (v >> (8 * (n - i))) % UInt8
    end
    w.cursor = c + n
    return w
end

"""
    writebe!(w::WBuffer, v) -> w

Append `v` big-endian.
"""
writebe!(w::WBuffer, v::UInt8) = _store_be!(w, v)
writebe!(w::WBuffer, v::Int8) = _store_be!(w, reinterpret(UInt8, v))
writebe!(w::WBuffer, v::UInt16) = _store_be!(w, v)
writebe!(w::WBuffer, v::Int16) = _store_be!(w, reinterpret(UInt16, v))
writebe!(w::WBuffer, v::UInt32) = _store_be!(w, v)
writebe!(w::WBuffer, v::Int32) = _store_be!(w, reinterpret(UInt32, v))
writebe!(w::WBuffer, v::UInt64) = _store_be!(w, v)
writebe!(w::WBuffer, v::Int64) = _store_be!(w, reinterpret(UInt64, v))
writebe!(w::WBuffer, v::Float32) = _store_be!(w, reinterpret(UInt32, v))
writebe!(w::WBuffer, v::Float64) = _store_be!(w, reinterpret(UInt64, v))
writebe!(w::WBuffer, v::Bool) = _store_be!(w, UInt8(v))

"""
    write_bytes!(w::WBuffer, v::AbstractVector{UInt8}) -> w

Append raw bytes verbatim, with no framing or byte-order change.
"""
function write_bytes!(w::WBuffer, v::AbstractVector{UInt8})
    n = length(v)
    _ensure!(w, n)
    @inbounds for i in 1:n
        w.data[w.cursor + i] = v[i]
    end
    w.cursor += n
    return w
end

"""
    write_array!(w::WBuffer, src::AbstractVector{T}) -> w

Append `src` as a packed big-endian array.

`hton` is applied elementwise into a temporary rather than swapped in place in
the output buffer: it is a no-op on a big-endian host, so the same code is
correct on both, and the one temporary per array is negligible against the
per-basket cost that dominates writing.
"""
function write_array!(w::WBuffer, src::AbstractVector{T}) where {T<:ROOTPrimitive}
    if sizeof(T) == 1
        return write_bytes!(w, reinterpret(UInt8, collect(src)))
    end
    tmp = map(hton, src)
    nb = length(tmp) * sizeof(T)
    _ensure!(w, nb)
    GC.@preserve tmp begin
        unsafe_copyto!(pointer(w.data, w.cursor + 1), Ptr{UInt8}(pointer(tmp)), UInt(nb))
    end
    w.cursor += nb
    return w
end

"""
    write_tstring!(w::WBuffer, s) -> w

Write `s` in `TString` framing — see [`read_tstring`](@ref) for the encoding.
"""
function write_tstring!(w::WBuffer, s::AbstractString)
    b = codeunits(s)
    n = length(b)
    if n < 255
        writebe!(w, UInt8(n))
    else
        writebe!(w, UInt8(255))
        writebe!(w, UInt32(n))
    end
    n > 0 && write_bytes!(w, b)
    return w
end

"""
    write_cstring!(w::WBuffer, s) -> w

Write `s` NUL-terminated, the framing used for class names in object tags.
"""
function write_cstring!(w::WBuffer, s::AbstractString)
    write_bytes!(w, codeunits(s))
    return writebe!(w, UInt8(0))
end

"""
    write_stdstring!(w::WBuffer, s) -> w

Write `s` as ROOT streams a `std::string`: a version header around a
`TString` body.
"""
function write_stdstring!(w::WBuffer, s::AbstractString)
    hdr = write_header!(w, "string", Int16(2))
    write_tstring!(w, s)
    set_header!(w, hdr)
    return w
end

"""
    write_float16!(w::WBuffer, x, nbits=12) -> w
    write_float16!(w::WBuffer, x, xmin, xmax, factor) -> w

Write a `Float16_t` — see [`read_float16`](@ref) for the encoding.

The unscaled form rounds the mantissa to `nbits` rather than truncating it,
which is what ROOT does and what makes the value that comes back the nearest
representable one rather than always the smaller.
"""
function write_float16!(w::WBuffer, x::Real, nbits::Integer=12)
    v = Float32(x)
    ix = reinterpret(UInt32, v)
    exp = UInt8((ix << 1) >> 24)
    man = UInt16(((UInt32(1) << (nbits + 1)) - UInt32(1)) & (ix >> (23 - nbits - 1)))
    man = (man + UInt16(1)) >> 1
    signbit(v) && (man |= UInt16(1) << (nbits + 1))
    writebe!(w, exp)
    return writebe!(w, man)
end

function write_float16!(w::WBuffer, x::Real, xmin::Real, xmax::Real, factor::Real)
    factor == 0 && return write_float16!(w, x, _range_bits(xmin, xmax))
    return writebe!(w, round(UInt32, (Float64(x) - xmin) * factor))
end

"""
    write_double32!(w::WBuffer, x) -> w
    write_double32!(w::WBuffer, x, xmin, xmax, factor) -> w

Write a `Double32_t` — see [`read_double32`](@ref) for the encoding.
"""
write_double32!(w::WBuffer, x::Real) = writebe!(w, Float32(x))

function write_double32!(w::WBuffer, x::Real, xmin::Real, xmax::Real, factor::Real)
    factor == 0 && return write_double32!(w, x)
    return writebe!(w, round(UInt32, (Float64(x) - xmin) * factor))
end

"""
    write_header!(w::WBuffer, class, vers) -> Header

Open an object's framing: a zeroed byte-count placeholder followed by the class
version. The returned header must be handed to [`set_header!`](@ref) once the
object's members have been written, which is when the count is finally known.
"""
function write_header!(w::WBuffer, class::AbstractString, vers::Integer)
    hdr = Header(String(class), Int16(vers), Int32(0), pos(w), false)
    writebe!(w, UInt32(0))
    writebe!(w, UInt16(vers % UInt16))
    return hdr
end

"""
    set_header!(w::WBuffer, hdr::Header) -> Int

Close the framing opened by [`write_header!`](@ref), patching in the number of
bytes written since the count field, and return the object's total size.
"""
function set_header!(w::WBuffer, hdr::Header)
    cur = pos(w)
    cnt = cur - hdr.pos - 4
    seek!(w, hdr.pos)
    writebe!(w, UInt32(cnt) | UInt32(KBYTE_COUNT_MASK))
    seek!(w, cur)
    return Int(cnt + 4)
end

"""
    write_object_any!(w::WBuffer, obj) -> w

Write a polymorphic object reference — ROOT's `WriteObjectAny`, the exact
inverse of [`read_object_any`](@ref).

An object written for the second time becomes a back-reference to its first
occurrence, and a class named for the second time becomes a back-reference to
its first mention. The object is registered *before* it is streamed so that a
structure containing itself terminates.
"""
function write_object_any!(w::WBuffer, obj)
    if obj === nothing
        writebe!(w, UInt32(0))
        return w
    end

    beg = pos(w)
    writebe!(w, UInt32(0))                 # byte-count placeholder
    bcnt = _write_class!(w, beg, obj)
    fin = pos(w)
    seek!(w, beg)
    writebe!(w, bcnt)
    seek!(w, fin)
    return w
end

function _write_class!(w::WBuffer, beg::Int64, obj)
    refs = refmap!(w)
    start = pos(w)

    key = objectid(obj)
    ref = get(refs, key, nothing)
    if ref !== nothing
        writebe!(w, UInt32(ref))
        return UInt32(pos(w) - start) | UInt32(KBYTE_COUNT_MASK)
    end

    class = classname(obj)
    cref = get(refs, class, nothing)
    if cref === nothing
        writebe!(w, UInt32(KNEW_CLASS_TAG))
        write_cstring!(w, class)
        refs[class] = (start + KMAP_OFFSET) | Int64(KCLASS_MASK)
    else
        writebe!(w, UInt32(cref) | UInt32(KCLASS_MASK))
    end

    refs[key] = beg + KMAP_OFFSET
    marshal!(w, obj)
    return UInt32(pos(w) - start) | UInt32(KBYTE_COUNT_MASK)
end

"""
    marshal!(w::WBuffer, obj) -> w

Stream `obj` out to `w`. The write-side counterpart of
[`unmarshal!`](@ref); concrete ROOT classes add methods.
"""
function marshal! end

"""
    classname(obj) -> String

The ROOT class name `obj` is persisted under. Concrete classes add methods.
"""
function classname end

"""
    object_title(obj) -> AbstractString

The title stored in the key that holds `obj` — ROOT's `TObject::GetTitle`.

A `TNamed` returns its own title; anything else returns its class's title from
the dictionary, which is why a `TObjString` key reads "Collectable string
class". The default here is empty, so a class that has no title simply gets
none.
"""
object_title(::Any) = ""

"""
    bind!(obj, file) -> obj

Attach a freshly read object to the file it came out of — ROOT's
`SetDirectory`.

Almost every object is complete once its bytes are decoded and the default here
does nothing. A tree is the exception: its branches hold seek offsets rather
than data, so it needs the file to be able to read anything at all.
"""
bind!(obj, file) = obj
