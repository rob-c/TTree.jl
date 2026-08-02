# Reading a class ROOT streams automatically.
#
# Some classes here are written by a hand-written `Streamer` — `TNamed` and
# `TObjString` are — and their layout is fixed for all time, so the code reads
# them member by member. Most are not. `TH1`, `TAxis`, `TTree` and `TBranch` are
# streamed from the class description ROOT compiled, which means the bytes on
# disk follow the description the *writing* program stored in the file rather
# than any layout fixed here. Members have been added over the years — `TAxis`
# gained its labels between versions 6 and 10, `TH1` its entry buffer between 3
# and 7 — and some have changed width, `fEntries` having been a `double` when it
# merely counted rows and a `Long64_t` since. A reader that hard-codes one
# ordering can read files from one era.
#
# So this layer does what ROOT does: it reads the file's own description and
# follows it. Each class knows how to read each of *its* members by name; what
# follows supplies which members are present, in what order, and how wide.
# The write side needs none of this — it emits one version, the current one —
# which is the one place in this package where the two directions are not
# mirror images.

"""
    layout(r::RBuffer, class, vers) -> Vector

The description to decode `class` version `vers` by: the file's own if it
describes exactly that version, and otherwise this package's.

The fallback is not a guess about an unfamiliar file. A file holding a
histogram always describes `TH1`, because ROOT could not have written it
otherwise; the fallback is for a buffer with no file behind it, which is how a
record written by `marshal!` reads back.
"""
function layout(r::RBuffer, class::AbstractString, vers::Integer)
    if r.sinfos !== nothing
        si = Bytes.streamer_info(r.sinfos, class, vers)
        if si !== nothing && Int(Bytes.class_version(si)) == Int(vers)
            return elements(si)
        end
    end
    si = streamer_info(class)
    si === nothing && throw(
        ArgumentError(
            "TTree: nothing describes $class version $vers, so its bytes cannot be read"
        ),
    )
    return elements(si)
end

"""
    unknown_member(class, vers, member)

Refuse to guess at a member this package does not know.

Members are read in the order the description lists them, so one that cannot be
consumed leaves every member after it misaligned. Stopping here costs the
object; carrying on would cost the object *and* hide that anything went wrong.
"""
function unknown_member(class::AbstractString, vers::Integer, member::AbstractString)
    return throw(
        ArgumentError(
            "TTree: $class version $vers has a member $(repr(member)) this package does not know",
        ),
    )
end

"""
    scalar_type(e) -> DataType

The width and signedness one value of member `e` is stored with, taken from the
member's own description rather than assumed.
"""
function scalar_type(e)
    T = julia_type(base_type(etype(e)))
    T === nothing && throw(
        ArgumentError(
            "TTree: member $(name(e)) has streamer type $(etype(e)), which is not a number",
        ),
    )
    return T
end

"""
    read_scalar(r::RBuffer, e) -> Number

One numeric member, at the width its description gives it.
"""
read_scalar(r::RBuffer, e) = readbe(r, scalar_type(e))

"""
    read_count(r::RBuffer, e) -> Int64

A member that counts things — entries, bytes, baskets.

ROOT spelled these `Stat_t` until it admitted they were integers, so a file
written before that stores a `double` where one written since stores a
`Long64_t`. Both mean the same number.
"""
function read_count(r::RBuffer, e)
    v = read_scalar(r, e)
    return v isa AbstractFloat ? round(Int64, v) : Int64(v)
end

"""
    read_real(r::RBuffer, e) -> Float64

One member that is a real number, whatever width the description gives it.

`Stat_t` was a `Float32` in ROOT 3 and a `Float64` after, and the two are the
same quantity — so unlike [`read_scalar`](@ref) this converts, and the field it
lands in can be a plain `Float64`.
"""
read_real(r::RBuffer, e) = Float64(read_scalar(r, e))

"""
    read_pointer_array(r::RBuffer, e, n, T) -> Vector{T}

A `[count]`-style member: the `n` values of a variable-length array, converted
to `T`.

ROOT precedes them with a byte saying the pointer was not null. That byte is
also where an old-format branch says its basket offsets outgrew four bytes —
the value 2 rather than 1 — which is the only way to tell a pre-`Long64_t`
`TBranch` written against a file over 2 GB from one written against a small
file.
"""
function read_pointer_array(r::RBuffer, e, n::Integer, ::Type{T}) where {T<:Number}
    flag = readbe(r, UInt8)
    n = Int(n)
    n <= 0 && return T[]
    S = scalar_type(e)
    flag == 0x02 && S === Int32 && (S = Int64)
    S === T && return read_array(r, T, n)
    return T[T(x) for x in read_array(r, S, n)]
end

"""
    write_pointer_array!(w::WBuffer, v::AbstractVector) -> w

The inverse of [`read_pointer_array`](@ref) for the widths this package writes.
"""
function write_pointer_array!(w::WBuffer, v::AbstractVector)
    writebe!(w, UInt8(1))
    isempty(v) || write_array!(w, v)
    return w
end

"""
    read_object_member(r::RBuffer, e, ctor) -> Any

An object-valued member, read the way its description says it was written.

ROOT has two kinds of object pointer and they are not interchangeable. One is
marked `//->` in the class declaration, promises never to be null, and is
written inline exactly as an embedded object would be; the other may be null,
and is written with the tag that lets a second reference to the same object be
a back-reference instead of a copy. `TH1` holds its list of fitted functions
the first way and `TGraph` holds the same list the second way, so this cannot
be decided per class — only per member, from the codes `RMETA_OBJECTP` and
`RMETA_OBJECT_P`.
"""
function read_object_member(r::RBuffer, e, ctor)
    etype(e) == RMETA_OBJECTP || return read_object_any(r)
    o = ctor()
    Bytes.unmarshal!(o, r)
    return o
end

"""
    read_objarray!(dst::Vector{Any}, r::RBuffer) -> dst

Read a `TObjArray` member into a plain vector.

The array's own name and lower bound are ROOT's defaults everywhere a tree uses
one, so nothing is lost by keeping only the contents — and a branch list is far
easier to work with as a `Vector` than as an object that happens to hold one.
"""
function read_objarray!(dst::Vector{Any}, r::RBuffer)
    a = TObjArray()
    Bytes.unmarshal!(a, r)
    resize!(dst, length(a.objs))
    copyto!(dst, a.objs)
    return dst
end

"Write a plain vector back as the `TObjArray` member it was read from."
write_objarray!(w::WBuffer, v::AbstractVector) = Bytes.marshal!(w, TObjArray("", v))

"""
    read_tarray!(dst::Vector, r::RBuffer) -> dst

Read a `TArray*` member into a plain vector.

A `TArray` is streamed bare — a count and that many values, with no header of
its own — so the class it is written as says nothing that the element type does
not, and there is nothing to keep hold of but the numbers.
"""
function read_tarray!(dst::Vector{T}, r::RBuffer) where {T<:Number}
    n = Int(readbe(r, Int32))
    length(dst) == n || resize!(dst, n)
    read_array!(r, dst)
    return dst
end

"Write a plain vector back as the bare `TArray` member it was read from."
function write_tarray!(w::WBuffer, v::AbstractVector)
    writebe!(w, Int32(length(v)))
    write_array!(w, v)
    return w
end
