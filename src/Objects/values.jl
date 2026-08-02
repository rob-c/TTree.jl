# Decoding a streamed value.
#
# A branch that holds objects holds whatever the class's streamer wrote, and
# what that is comes from the file's own description of the class — the same
# `TStreamerInfo` list ROOT reads it back with. Working it out per entry would
# mean re-deciding, for every one of a hundred million rows, questions whose
# answers are fixed by the file: what the members are, how wide, in what order.
#
# So it is worked out once. A `ValuePlan` is that answer — a tree of small
# immutable descriptions mirroring the shape of one value — and reading is then
# a walk over the plan rather than over the metadata.
#
# The one thing a plan does not settle is framing: whether a value is preceded
# by the byte count and version ROOT calls a header. That is not a property of
# the type. `std::string` is written with a header as a class member and
# without one as a container's element; an object is written with a header
# where it is nested and without one where it is a branch's whole payload. So
# framing belongs to the slot a value sits in — `MemberPlan.framed` for a class
# member, an argument for a branch — and never to the value itself.

"""
    ValuePlan

How to read one value: its type, and its parts if it has any.

Built once per branch by [`class_plan`](@ref) or [`type_plan`](@ref) and walked
per entry by [`read_value`](@ref).
"""
abstract type ValuePlan end

"""
    ScalarPlan{T}

A number of `T`, big-endian, exactly as wide as `T`.
"""
struct ScalarPlan{T} <: ValuePlan end

ScalarPlan(::Type{T}) where {T} = ScalarPlan{T}()

"""
    PackedPlan{T}

A `Double32_t` or `Float16_t`: a real stored in fewer bits than `T` has.

The three numbers are what [`parse_range`](@ref) recovers from the member's
title, and mean to the readers here exactly what they mean to a leaf's: a
`factor` of zero is an unscaled value, and a bit count asked for without a
range is folded into `xmin`.
"""
struct PackedPlan{T} <: ValuePlan
    xmin::Float64
    xmax::Float64
    factor::Float64
end

"""
    StringPlan

A string as ROOT writes one: a length and that many bytes.

`std::string` and `TString` share this body and differ only in whether a header
precedes it, which is the enclosing slot's business.
"""
struct StringPlan <: ValuePlan end

"""
    CharStarPlan

A `char*` member: a four-byte count and that many characters.
"""
struct CharStarPlan <: ValuePlan end

"""
    TObjectPlan

`TObject`, which is streamed by hand: a bare version word, a unique id and a
bit field, and — for an object that has been referenced — the id of the process
that owns the table it is referenced through.
"""
struct TObjectPlan <: ValuePlan end

"""
    DatimePlan

`TDatime`, whose streamer writes its four packed bytes and nothing else. It is
the reason a class with a custom streamer cannot be assumed to carry a header.
"""
struct DatimePlan <: ValuePlan end

"""
    FixedPlan{P}

A fixed-size array member, `x[3]` or `x[2][4]`, stored as its values end to
end. C's dimensions run slowest-first and Julia's fastest-first, so a
multi-dimensional member is transposed on the way out and `a[i,j]` means what
C's `a[i][j]` does.
"""
struct FixedPlan{P<:ValuePlan} <: ValuePlan
    element::P
    dims::Vector{Int}
end

"""
    CountedPlan{P}

A `x[n]`-style member: a flag byte saying the pointer was not null, then as
many values as the member named by `countidx` holds — times `per` for the fixed
dimensions of an `x[n][3]`.

The count is another member of the same class, so it is kept as the position it
occupies rather than its name: by the time this one is read, that one's value
is already in hand.
"""
struct CountedPlan{P<:ValuePlan} <: ValuePlan
    element::P
    countidx::Int
    per::Int
end

"""
    SequencePlan{P}

An STL container: a count, then that many elements.

A map is one of these too, its element a plan for `pair<K,V>` — which is what
ROOT makes of it, and what makes member-wise streaming of a map and of a
`vector` of objects the same operation.
"""
struct SequencePlan{P<:ValuePlan} <: ValuePlan
    class::String
    element::P
    framed_element::Bool
end

function SequencePlan(class::AbstractString, element::ValuePlan)
    return SequencePlan(String(class), element, element isa ObjectPlan)
end

"""
    BitsetPlan

A `std::bitset<N>`: a count, then one byte per bit.
"""
struct BitsetPlan <: ValuePlan
    class::String
    nbits::Int
end

"""
    MemberPlan

One member of a class: what to call it, how to read it, and whether it is
framed — wrapped in a header of its own, as ROOT wraps every member that is a
container and no member that is a number.
"""
struct MemberPlan
    name::Symbol
    class::String
    plan::ValuePlan
    framed::Bool
end

"""
    ObjectPlan

A class: its members in the order they were written, including its base
classes, which ROOT writes inline and this reads as members named for the base.

The result is a `NamedTuple`, so a base class nests rather than merges — a
name cannot then be claimed twice, and `p4.TObject.fBits` says where it came
from.
"""
struct ObjectPlan <: ValuePlan
    class::String
    names::Tuple{Vararg{Symbol}}
    members::Vector{MemberPlan}
end

function ObjectPlan(class::AbstractString, members::Vector{MemberPlan})
    return ObjectPlan(String(class), Tuple(m.name for m in members), members)
end

"""
    PointerPlan

A member holding a pointer that may be null and may point at an object already
written, so it carries ROOT's object tag rather than being written inline.
"""
struct PointerPlan <: ValuePlan
    class::String
end

"""
    OpaquePlan

A member this package cannot decode, kept so that the ones around it still can
be.

A framed member is skipped by its byte count and comes back as `nothing`, which
is what ROOT does with a class it has no dictionary for. An unframed one has no
byte count and cannot be stepped over, so reading it is refused — everything
after it in the entry would be misaligned, and a wrong answer is worse than
none.
"""
struct OpaquePlan <: ValuePlan
    class::String
    why::String
end

# ---------------------------------------------------------------------------
# What a plan gives back.

"""
    value_eltype(plan) -> Type

The Julia type one value of `plan` comes back as.

Containers are allocated at this type, so it is what keeps a `vector<float>`
a `Vector{Float32}` rather than a vector of boxes.
"""
value_eltype(::ScalarPlan{T}) where {T} = T
value_eltype(::PackedPlan{T}) where {T} = T
value_eltype(::StringPlan) = String
value_eltype(::CharStarPlan) = String
value_eltype(::DatimePlan) = DateTime
value_eltype(::TObjectPlan) = NamedTuple{(:fUniqueID, :fBits),Tuple{UInt32,UInt32}}
value_eltype(::BitsetPlan) = Vector{Bool}
value_eltype(::PointerPlan) = Any
value_eltype(::OpaquePlan) = Nothing
value_eltype(p::CountedPlan) = Vector{value_eltype(p.element)}
value_eltype(p::SequencePlan) = Vector{value_eltype(p.element)}

function value_eltype(p::FixedPlan)
    T = value_eltype(p.element)
    return length(p.dims) == 1 ? Vector{T} : Array{T,length(p.dims)}
end

function value_eltype(p::ObjectPlan)
    isempty(p.members) && return NamedTuple{(),Tuple{}}
    return NamedTuple{p.names,Tuple{(value_eltype(m.plan) for m in p.members)...}}
end

"""
    headerclass(plan) -> String

The class name to match a header's checksum against when `plan`'s value is
framed. Empty where a header could not name a class this package would find.
"""
headerclass(p::ValuePlan) = ""
headerclass(p::SequencePlan) = p.class
headerclass(p::BitsetPlan) = p.class
headerclass(p::ObjectPlan) = p.class
headerclass(p::OpaquePlan) = p.class
headerclass(::StringPlan) = "string"

# ---------------------------------------------------------------------------
# Reading.

"""
    read_value(r::RBuffer, plan, framed=false) -> Any

One value of `plan` from the cursor.

`framed` says the value is preceded by a header, which is how ROOT writes a
container, a nested object, and nothing else — see the note at the top of this
file on why that cannot be decided from the plan alone.
"""
function read_value(r::RBuffer, plan::ValuePlan, framed::Bool=false)
    framed || return readbody(r, plan)
    hdr = read_header(r, headerclass(plan))
    v = readbody(r, plan, hdr.memberwise)
    check_header(r, hdr)
    return v
end

"""
    readbody(r::RBuffer, plan, memberwise=false) -> Any

One value of `plan`, its header — if it had one — already consumed.

`memberwise` is carried in the header of a container whose elements were
written a member at a time rather than an element at a time, so it can only be
passed in from where the header was read.
"""
readbody(r::RBuffer, ::ScalarPlan{T}, ::Bool=false) where {T} = readbe(r, T)

function readbody(r::RBuffer, p::PackedPlan{Float64}, ::Bool=false)
    return read_double32(r, p.xmin, p.xmax, p.factor)
end

function readbody(r::RBuffer, p::PackedPlan{Float32}, ::Bool=false)
    return read_float16(r, p.xmin, p.xmax, p.factor)
end

readbody(r::RBuffer, ::StringPlan, ::Bool=false) = read_tstring(r)

function readbody(r::RBuffer, ::CharStarPlan, ::Bool=false)
    n = Int(readbe(r, Int32))
    n <= 0 && return ""
    return String(read_bytes(r, n))
end

function readbody(r::RBuffer, ::DatimePlan, ::Bool=false)
    return Bytes.datime_to_datetime(readbe(r, UInt32))
end

function readbody(r::RBuffer, ::TObjectPlan, ::Bool=false)
    skip_version!(r)
    id = readbe(r, UInt32)
    bits = readbe(r, UInt32) | UInt32(Bytes.KIS_ON_HEAP)
    (bits & UInt32(Bytes.KIS_REFERENCED)) != 0 && skip!(r, 2)
    return (fUniqueID=id, fBits=bits)
end

function readbody(r::RBuffer, p::BitsetPlan, ::Bool=false)
    n = Int(readbe(r, Int32))
    return Bool[readbe(r, UInt8) != 0 for _ in 1:n]
end

function readbody(r::RBuffer, p::FixedPlan, ::Bool=false)
    v = read_many(r, p.element, prod(p.dims), false)
    length(p.dims) == 1 && return v
    nd = length(p.dims)
    return permutedims(reshape(v, reverse(p.dims)...), ntuple(i -> nd - i + 1, nd))
end

function readbody(r::RBuffer, p::SequencePlan, memberwise::Bool=false)
    memberwise && return read_memberwise(r, p)
    n = Int(readbe(r, Int32))
    return read_many(r, p.element, n, p.framed_element)
end

readbody(r::RBuffer, ::PointerPlan, ::Bool=false) = read_object_any(r)

function readbody(r::RBuffer, p::OpaquePlan, ::Bool=false)
    return throw(
        ArgumentError(
            "TTree: $(p.class) cannot be decoded ($(p.why)), and it was written without a byte count to step over",
        ),
    )
end

function readbody(r::RBuffer, p::CountedPlan, ::Bool=false)
    return throw(
        ArgumentError(
            "TTree: a variable-length member is counted by another member, so it cannot be read on its own",
        ),
    )
end

function readbody(r::RBuffer, p::ObjectPlan, ::Bool=false)
    vals = Vector{Any}(undef, length(p.members))
    for (i, m) in enumerate(p.members)
        vals[i] = read_member(r, m, vals)
    end
    return NamedTuple{p.names}(Tuple(vals))
end

"""
    read_many(r::RBuffer, plan, n, framed) -> Vector

`n` values of `plan` one after another, which is what a container's body is and
what one member of a member-wise container's run is.
"""
function read_many(r::RBuffer, plan::ValuePlan, n::Int, framed::Bool)
    out = Vector{value_eltype(plan)}(undef, n)
    for i in 1:n
        out[i] = framed ? read_value(r, plan, true) : readbody(r, plan)
    end
    return out
end

# Numbers are stored the way an array of them is laid out, so a run of them is
# one copy and a byte swap rather than a loop.
function read_many(r::RBuffer, ::ScalarPlan{T}, n::Int, ::Bool) where {T<:ROOTPrimitive}
    return read_array(r, T, n)
end

"""
    read_member(r::RBuffer, m::MemberPlan, vals) -> Any

One member of a class, given the members before it — which a variable-length
one needs, its count being one of them.
"""
function read_member(r::RBuffer, m::MemberPlan, vals::Vector{Any})
    p = m.plan
    p isa CountedPlan && return read_counted(r, p, Int(vals[p.countidx]) * p.per)
    m.framed || return readbody(r, p)
    hdr = read_header(r, m.class)
    v = if p isa OpaquePlan
        nothing
    else
        readbody(r, p, hdr.memberwise)
    end
    check_header(r, hdr)
    return v
end

"""
    read_counted(r::RBuffer, p::CountedPlan, n) -> Vector

The `n` values of a `[count]`-style member, after the byte ROOT writes to say
the pointer was not null.
"""
function read_counted(r::RBuffer, p::CountedPlan, n::Int)
    skip!(r, 1)
    return read_many(r, p.element, max(n, 0), false)
end

"""
    read_memberwise(r::RBuffer, p::SequencePlan) -> Vector

A container whose elements were written a member at a time: all the first
members, then all the second, and so on.

ROOT streams every map this way, and every `vector` of a class it can take
apart — at any split level, since this is the collection's own encoding and not
a property of the branch. The elements must therefore be objects; a container
of numbers has nothing to take apart and is never written like this.

A member that is itself a container is framed, and the one header covers the
whole run rather than each element of it.
"""
function read_memberwise(r::RBuffer, p::SequencePlan)
    el = p.element
    el isa ObjectPlan || throw(
        ArgumentError(
            "TTree: $(p.class) was streamed member-wise, which only a container of objects can be",
        ),
    )
    skip_valueversion!(r, el.class)
    n = Int(readbe(r, Int32))
    cols = Vector{Any}(undef, length(el.members))
    for (i, m) in enumerate(el.members)
        cols[i] = read_run(r, m, n, cols)
    end
    T = value_eltype(el)
    out = Vector{T}(undef, n)
    nm = length(cols)
    for i in 1:n
        out[i] = NamedTuple{el.names}(ntuple(j -> cols[j][i], nm))
    end
    return out
end

"""
    read_run(r::RBuffer, m::MemberPlan, n, cols) -> Vector

Member `m` of every element of a member-wise container.
"""
function read_run(r::RBuffer, m::MemberPlan, n::Int, cols::Vector{Any})
    p = m.plan
    if p isa CountedPlan
        return [read_counted(r, p, Int(cols[p.countidx][i]) * p.per) for i in 1:n]
    end
    m.framed || return read_many(r, p, n, false)
    hdr = read_header(r, m.class)
    v = if p isa OpaquePlan
        Any[nothing for _ in 1:n]
    else
        [readbody(r, p, hdr.memberwise) for _ in 1:n]
    end
    check_header(r, hdr)
    return v
end

"""
    skip_valueversion!(r::RBuffer, class) -> Int16

Step over the version of the class a member-wise container holds.

It is written bare — no byte count — and a class old enough to predate
versioning writes zero and then its checksum, which identifies it just as well
and is just as long a thing to step over.
"""
function skip_valueversion!(r::RBuffer, class::AbstractString)
    v = readbe(r, Int16)
    v == 0 && skip!(r, 4)
    return v
end
