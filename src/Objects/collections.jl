# ROOT's container classes, and the fixed-type arrays that histograms are built
# from.
#
# The polymorphic containers hold `Any`: a `TList` read out of a file may mix
# classes freely, and narrowing the element type would mean giving up on files
# that do. The `TArray*` family is the opposite case — each has exactly one
# element type, so each gets its own concrete Julia type and its contents are
# read with the bulk path.

"""
    TList

ROOT's doubly linked list. Each element carries an option string, which ROOT
uses for drawing instructions and which is usually empty.

Iterating a `TList` yields its objects; the options are reachable through
[`options`](@ref).
"""
mutable struct TList <: ROOTObject
    obj::TObject
    name::String
    objs::Vector{Any}
    opts::Vector{String}
end

function TList(name::AbstractString="", objs::AbstractVector=Any[])
    v = collect(Any, objs)
    return TList(TObject(), String(name), v, fill("", length(v)))
end

Bytes.classname(::TList) = "TList"
rversion(::TList) = Int16(5)
name(l::TList) = l.name
title(::TList) = "Doubly linked list"

"""
    THashList

A [`TList`](@ref) with a hash table for lookup by name. The hash is rebuilt
from the elements, so nothing of it is stored and the streaming is identical.
"""
mutable struct THashList <: ROOTObject
    list::TList
end

function THashList(name::AbstractString="", objs::AbstractVector=Any[])
    return THashList(TList(name, objs))
end

Bytes.classname(::THashList) = "THashList"
rversion(::THashList) = Int16(0)
name(l::THashList) = l.list.name
title(::THashList) = "Doubly linked list with hashtable for lookup"

const AnyList = Union{TList,THashList}

_list(l::TList) = l
_list(l::THashList) = l.list

Base.length(l::AnyList) = length(_list(l).objs)
Base.getindex(l::AnyList, i::Integer) = _list(l).objs[i]
Base.setindex!(l::AnyList, v, i::Integer) = (_list(l).objs[i]=v; l)
Base.iterate(l::AnyList, s::Int=1) = s > length(l) ? nothing : (l[s], s + 1)
Base.eltype(::Type{<:AnyList}) = Any
Base.firstindex(::AnyList) = 1
Base.lastindex(l::AnyList) = length(l)
Base.isempty(l::AnyList) = isempty(_list(l).objs)

"Drawing option strings, one per element."
options(l::AnyList) = _list(l).opts

"""
    push!(l::TList, obj, opt="") -> l

Append `obj`, with an optional drawing option.
"""
function Base.push!(l::AnyList, obj, opt::AbstractString="")
    ll = _list(l)
    push!(ll.objs, obj)
    push!(ll.opts, String(opt))
    return l
end

function _unmarshal_list!(l::TList, r::RBuffer)
    hdr = read_header(r, "TList")
    hdr.vers <= 3 && throw(
        ArgumentError("TTree: TList version $(hdr.vers) is older than this package reads"),
    )
    Bytes.unmarshal!(l.obj, r)
    l.name = read_tstring(r)
    n = Int(readbe(r, Int32))
    resize!(l.objs, n)
    resize!(l.opts, n)
    for i in 1:n
        l.objs[i] = read_object_any(r)
        l.opts[i] = read_tstring(r)
    end
    check_header(r, hdr)
    return l
end

function _marshal_list!(w::WBuffer, l::TList, class::AbstractString, vers::Integer)
    hdr = write_header!(w, class, vers)
    Bytes.marshal!(w, l.obj)
    write_tstring!(w, l.name)
    writebe!(w, Int32(length(l.objs)))
    for (obj, opt) in zip(l.objs, l.opts)
        write_object_any!(w, obj)
        write_tstring!(w, opt)
    end
    set_header!(w, hdr)
    return w
end

Bytes.unmarshal!(l::TList, r::RBuffer) = _unmarshal_list!(l, r)
Bytes.marshal!(w::WBuffer, l::TList) = _marshal_list!(w, l, "TList", rversion(l))

Bytes.unmarshal!(l::THashList, r::RBuffer) = (_unmarshal_list!(l.list, r); l)

# The version written is `TList`'s, not this class's own. ROOT has no
# `THashList::Streamer`: it inherits `TList`'s, which writes
# `WriteVersion(TList::IsA())` whatever the object really is. Writing
# `THashList`'s version — which is zero — would produce a record ROOT reads as
# a pre-versioned list.
function Bytes.marshal!(w::WBuffer, l::THashList)
    return _marshal_list!(w, l.list, "THashList", rversion(l.list))
end

function Base.show(io::IO, l::AnyList)
    print(io, Bytes.classname(l), "(", repr(name(l)), ", ", length(l), " elements)")
    return nothing
end

"""
    TObjArray

An array of object pointers with a settable lower bound.

Slots may be empty — a `nothing` element is a null pointer ROOT wrote, not a
decoding failure — so `last` records the highest occupied index.
"""
mutable struct TObjArray <: ROOTObject
    obj::TObject
    name::String
    low::Int32
    last::Int32
    objs::Vector{Any}
end

function TObjArray(name::AbstractString="", objs::AbstractVector=Any[]; low::Integer=0)
    v = collect(Any, objs)
    return TObjArray(TObject(), String(name), Int32(low), Int32(length(v) - 1), v)
end

Bytes.classname(::TObjArray) = "TObjArray"
rversion(::TObjArray) = Int16(3)
name(a::TObjArray) = a.name
title(::TObjArray) = "An array of objects"

Base.length(a::TObjArray) = length(a.objs)
Base.getindex(a::TObjArray, i::Integer) = a.objs[i]
Base.setindex!(a::TObjArray, v, i::Integer) = (a.objs[i]=v; a)
Base.iterate(a::TObjArray, s::Int=1) = s > length(a) ? nothing : (a[s], s + 1)
Base.eltype(::Type{TObjArray}) = Any
Base.firstindex(::TObjArray) = 1
Base.lastindex(a::TObjArray) = length(a.objs)
Base.isempty(a::TObjArray) = isempty(a.objs)

function Base.push!(a::TObjArray, obj)
    push!(a.objs, obj)
    a.last = Int32(length(a.objs) - 1)
    return a
end

function Bytes.unmarshal!(a::TObjArray, r::RBuffer)
    hdr = read_header(r, "TObjArray")
    hdr.vers > 2 && Bytes.unmarshal!(a.obj, r)
    hdr.vers > 1 && (a.name = read_tstring(r))
    n = Int(readbe(r, Int32))
    a.low = readbe(r, Int32)
    resize!(a.objs, n)
    a.last = Int32(-1)
    for i in 1:n
        obj = read_object_any(r)
        a.objs[i] = obj
        obj === nothing || (a.last = Int32(i - 1))
    end
    check_header(r, hdr)
    return a
end

function Bytes.marshal!(w::WBuffer, a::TObjArray)
    hdr = write_header!(w, "TObjArray", rversion(a))
    Bytes.marshal!(w, a.obj)
    write_tstring!(w, a.name)
    writebe!(w, Int32(length(a.objs)))
    writebe!(w, a.low)
    for obj in a.objs
        write_object_any!(w, obj)
    end
    set_header!(w, hdr)
    return w
end

function Base.show(io::IO, a::TObjArray)
    return print(io, "TObjArray(", repr(a.name), ", ", length(a.objs), " slots)")
end

# ---------------------------------------------------------------------------
# TArray*
#
# One Julia type per ROOT class rather than a single parametric one: TArrayL and
# TArrayL64 are both arrays of 64-bit integers, so the element type alone cannot
# say which class to write back.

for (cls, T) in (
    (:TArrayC, Int8),
    (:TArrayS, Int16),
    (:TArrayI, Int32),
    (:TArrayL, Int64),
    (:TArrayL64, Int64),
    (:TArrayF, Float32),
    (:TArrayD, Float64),
)
    cls_str = String(cls)
    @eval begin
        """
            $($cls_str)(n)
            $($cls_str)(v::AbstractVector)

        ROOT's `$($cls_str)`: a length followed by that many packed `$($T)`
        values, with no object header of its own. `data` is the underlying
        `Vector`, and the type forwards enough of the iteration interface to be
        used as one.
        """
        mutable struct $cls <: ROOTObject
            data::Vector{$T}
        end

        $cls() = $cls($T[])
        $cls(n::Integer) = $cls(zeros($T, Int(n)))
        $cls(v::AbstractVector) = $cls(convert(Vector{$T}, v))

        Bytes.classname(::$cls) = $cls_str
        rversion(::$cls) = Int16(1)

        Base.length(a::$cls) = length(a.data)
        Base.getindex(a::$cls, i) = a.data[i]
        Base.setindex!(a::$cls, v, i) = (a.data[i]=v; a)
        Base.iterate(a::$cls, s::Int=1) = iterate(a.data, s)
        Base.eltype(::Type{$cls}) = $T
        Base.firstindex(::$cls) = 1
        Base.lastindex(a::$cls) = length(a.data)
        Base.isempty(a::$cls) = isempty(a.data)
        Base.Vector(a::$cls) = a.data

        function Bytes.unmarshal!(a::$cls, r::RBuffer)
            n = Int(readbe(r, Int32))
            length(a.data) == n || resize!(a.data, n)
            read_array!(r, a.data)
            return a
        end

        function Bytes.marshal!(w::WBuffer, a::$cls)
            writebe!(w, Int32(length(a.data)))
            write_array!(w, a.data)
            return w
        end

        Base.show(io::IO, a::$cls) = print(io, $cls_str, "(", length(a.data), " elements)")
    end
end

"Any of ROOT's fixed-element-type array classes."
const TArray = Union{TArrayC,TArrayS,TArrayI,TArrayL,TArrayL64,TArrayF,TArrayD}
