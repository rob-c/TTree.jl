# TStreamerInfo and its elements: a file's description of the C++ classes it
# contains.
#
# One `TStreamerInfo` per class version, holding an ordered list of elements —
# one per data member, plus one per base class. The element's `etype` says how
# to decode the member, and is the enumeration in `rmeta.jl`.
#
# Every element class is `TStreamerElement` plus a few extra fields, so the
# common part is factored into a `StreamerElement` value that each wraps.

"""
    StreamerElement

The part every `TStreamerElement` subclass shares: what the member is called,
what type it has, how big it is, and its array dimensions.

`xmin`/`xmax`/`factor` describe the packing of a `Double32_t` or `Float16_t`
member. From class version 4 on ROOT stopped storing them and instead spells
the range in the member's title, so they are recovered by
[`parse_range`](@ref) rather than read.
"""
mutable struct StreamerElement
    named::TNamed
    etype::Int32
    esize::Int32
    arrlen::Int32
    arrdim::Int32
    maxidx::Vector{Int32}
    ename::String
    xmin::Float64
    xmax::Float64
    factor::Float64
end

function StreamerElement(;
    name::AbstractString="",
    title::AbstractString="",
    etype::Integer=0,
    esize::Integer=0,
    arrlen::Integer=0,
    arrdim::Integer=0,
    maxidx::AbstractVector{<:Integer}=zeros(Int32, 5),
    ename::AbstractString="",
    xmin::Real=0.0,
    xmax::Real=0.0,
    factor::Real=0.0,
)
    idx = zeros(Int32, 5)
    copyto!(idx, 1, Int32.(maxidx), 1, min(5, length(maxidx)))
    return StreamerElement(
        TNamed(name, title),
        Int32(etype),
        Int32(esize),
        Int32(arrlen),
        Int32(arrdim),
        idx,
        String(ename),
        Float64(xmin),
        Float64(xmax),
        Float64(factor),
    )
end

Bytes.classname(::StreamerElement) = "TStreamerElement"
rversion(::StreamerElement) = Int16(4)
name(e::StreamerElement) = e.named.name
title(e::StreamerElement) = e.named.title

function Bytes.unmarshal!(e::StreamerElement, r::RBuffer)
    hdr = read_header(r, "TStreamerElement")
    Bytes.unmarshal!(e.named, r)
    e.etype = readbe(r, Int32)
    e.esize = readbe(r, Int32)
    e.arrlen = readbe(r, Int32)
    e.arrdim = readbe(r, Int32)
    if hdr.vers == 1
        # Version 1 wrote the dimensions as a counted array rather than a
        # fixed five, so the count has to be honoured.
        n = Int(readbe(r, Int32))
        fill!(e.maxidx, Int32(0))
        for i in 1:min(n, 5)
            e.maxidx[i] = readbe(r, Int32)
        end
        n > 5 && skip!(r, 4 * (n - 5))
    else
        read_array!(r, e.maxidx)
    end
    e.ename = read_tstring(r)

    # ROOT wrote `bool` members as unsigned char before it had a type code for
    # them; the type name is the only thing that distinguishes the two.
    if e.etype == RMETA_UCHAR && (e.ename == "Bool_t" || e.ename == "bool")
        e.etype = RMETA_BOOL
    end

    if hdr.vers == 3
        e.xmin = readbe(r, Float64)
        e.xmax = readbe(r, Float64)
        e.factor = readbe(r, Float64)
    elseif hdr.vers > 3
        e.xmin, e.xmax, e.factor = parse_range(title(e))
    else
        e.xmin = e.xmax = e.factor = 0.0
    end

    check_header(r, hdr)
    return e
end

function Bytes.marshal!(w::WBuffer, e::StreamerElement)
    hdr = write_header!(w, "TStreamerElement", rversion(e))
    Bytes.marshal!(w, e.named)
    writebe!(w, e.etype)
    writebe!(w, e.esize)
    writebe!(w, e.arrlen)
    writebe!(w, e.arrdim)
    write_array!(w, e.maxidx)
    write_tstring!(w, e.ename)
    # Version 4 carries the range in the title, so nothing more is written.
    set_header!(w, hdr)
    return w
end

"""
    parse_range(title) -> (xmin, xmax, factor)

Recover a `Double32_t`/`Float16_t` packing range from a member's title.

ROOT spells it `[xmin, xmax]` or `[xmin, xmax, nbits]` at the end of the
comment, optionally after a `/` type-specifier. Anything that does not match
means the member is not packed, which is the common case — hence the early
returns rather than an error.
"""
function parse_range(title::AbstractString)
    none = (0.0, 0.0, 0.0)
    isempty(title) && return none
    beg = findlast('[', title)
    beg === nothing && return none
    if beg > firstindex(title)
        # A range is only a range when it directly follows a `/x` specifier;
        # otherwise the brackets are part of an ordinary comment.
        slash = findlast('/', title[firstindex(title):prevind(title, beg)])
        slash === nothing && return none
        nextind(title, slash, 2) == beg || return none
    end
    fin = findlast(']', title)
    (fin === nothing || fin <= beg) && return none

    body = title[nextind(title, beg):prevind(title, fin)]
    ',' in body || return none
    toks = lowercase.(strip.(split(body, ',')))
    length(toks) in (2, 3) || return none

    nbits = UInt32(32)
    if length(toks) == 3
        n = tryparse(UInt32, toks[3])
        (n === nothing || n < 2 || n > 32) && return none
        nbits = n
    end

    xmin = _range_value(toks[1])
    xmax = _range_value(toks[2])
    (xmin === nothing || xmax === nothing) && return none

    bigint = nbits < 32 ? Float64(UInt64(1) << nbits) : Float64(0xffffffff)
    factor = xmin < xmax ? bigint / (xmax - xmin) : 0.0
    if xmin >= xmax && nbits < 15
        xmin = Float64(nbits) + 0.1
    end
    return (xmin, xmax, factor)
end

"A range bound, which ROOT allows to be written in terms of π."
function _range_value(s::AbstractString)
    if occursin("pi", s)
        f = if occursin("2pi", s) || occursin("2*pi", s) || occursin("twopi", s)
            2π
        elseif occursin("pi/2", s)
            π / 2
        elseif occursin("pi/4", s)
            π / 4
        else
            float(π)
        end
        return occursin('-', s) ? -f : f
    end
    return tryparse(Float64, s)
end

# ---------------------------------------------------------------------------
# The element subclasses.
#
# Most add nothing to `TStreamerElement` but a distinct class name, which is
# how ROOT records what kind of member it is. Those are generated; the ones
# with extra fields are written out.

for (cls, vers) in (
    (:TStreamerBasicType, 2),
    (:TStreamerObject, 2),
    (:TStreamerObjectPointer, 2),
    (:TStreamerObjectAny, 2),
    (:TStreamerObjectAnyPointer, 1),
    (:TStreamerString, 2),
    (:TStreamerArtificial, 0),
)
    cls_str = String(cls)
    @eval begin
        """
            $($cls_str)(elem::StreamerElement)

        ROOT's `$($cls_str)`, which adds nothing to
        [`StreamerElement`](@ref) beyond the class name that identifies what
        kind of member it describes.
        """
        mutable struct $cls <: ROOTObject
            elem::StreamerElement
        end

        $cls() = $cls(StreamerElement())
        Bytes.classname(::$cls) = $cls_str
        rversion(::$cls) = Int16($vers)

        function Bytes.unmarshal!(e::$cls, r::RBuffer)
            hdr = read_header(r, $cls_str)
            Bytes.unmarshal!(e.elem, r)
            check_header(r, hdr)
            return e
        end

        function Bytes.marshal!(w::WBuffer, e::$cls)
            hdr = write_header!(w, $cls_str, rversion(e))
            Bytes.marshal!(w, e.elem)
            set_header!(w, hdr)
            return w
        end
    end
end

"""
    TStreamerBase

A base class of the class being described. `vbase` is the base's own class
version, which the decoder needs in order to pick the right streamer for it.
"""
mutable struct TStreamerBase <: ROOTObject
    elem::StreamerElement
    vbase::Int32
end

TStreamerBase() = TStreamerBase(StreamerElement(), Int32(0))
Bytes.classname(::TStreamerBase) = "TStreamerBase"
rversion(::TStreamerBase) = Int16(3)

function Bytes.unmarshal!(e::TStreamerBase, r::RBuffer)
    hdr = read_header(r, "TStreamerBase")
    Bytes.unmarshal!(e.elem, r)
    hdr.vers > 2 && (e.vbase = readbe(r, Int32))
    check_header(r, hdr)
    return e
end

function Bytes.marshal!(w::WBuffer, e::TStreamerBase)
    hdr = write_header!(w, "TStreamerBase", rversion(e))
    Bytes.marshal!(w, e.elem)
    writebe!(w, e.vbase)
    set_header!(w, hdr)
    return w
end

"""
    TStreamerBasicPointer

A variable-length array of a basic type. Its length is not stored with it: it
comes from another member, named by `cname` in the class `ccls` at version
`cvers` — this is what a branch's `n[fN]` leaf title compiles down to.
"""
mutable struct TStreamerBasicPointer <: ROOTObject
    elem::StreamerElement
    cvers::Int32
    cname::String
    ccls::String
end

TStreamerBasicPointer() = TStreamerBasicPointer(StreamerElement(), Int32(0), "", "")
Bytes.classname(::TStreamerBasicPointer) = "TStreamerBasicPointer"
rversion(::TStreamerBasicPointer) = Int16(2)

"""
    TStreamerLoop

A variable-length array of a non-basic type, counted the same way a
[`TStreamerBasicPointer`](@ref) is.
"""
mutable struct TStreamerLoop <: ROOTObject
    elem::StreamerElement
    cvers::Int32
    cname::String
    ccls::String
end

TStreamerLoop() = TStreamerLoop(StreamerElement(), Int32(0), "", "")
Bytes.classname(::TStreamerLoop) = "TStreamerLoop"
rversion(::TStreamerLoop) = Int16(2)

const CountedStreamer = Union{TStreamerBasicPointer,TStreamerLoop}

"Name of the member holding this array's length."
count_name(e::CountedStreamer) = e.cname

function Bytes.unmarshal!(e::CountedStreamer, r::RBuffer)
    cls = Bytes.classname(e)
    hdr = read_header(r, cls)
    Bytes.unmarshal!(e.elem, r)
    e.cvers = readbe(r, Int32)
    e.cname = read_tstring(r)
    e.ccls = read_tstring(r)
    check_header(r, hdr)
    return e
end

function Bytes.marshal!(w::WBuffer, e::CountedStreamer)
    hdr = write_header!(w, Bytes.classname(e), rversion(e))
    Bytes.marshal!(w, e.elem)
    writebe!(w, e.cvers)
    write_tstring!(w, e.cname)
    write_tstring!(w, e.ccls)
    set_header!(w, hdr)
    return w
end

"""
    TStreamerSTL

An STL container member. `vtype` is which container (see the `ESTL_*`
constants) and `ctype` the type it contains.
"""
mutable struct TStreamerSTL <: ROOTObject
    elem::StreamerElement
    vtype::Int32
    ctype::Int32
end

TStreamerSTL() = TStreamerSTL(StreamerElement(), Int32(0), Int32(0))
Bytes.classname(::TStreamerSTL) = "TStreamerSTL"
rversion(::TStreamerSTL) = Int16(3)

function Bytes.unmarshal!(e::TStreamerSTL, r::RBuffer)
    hdr = read_header(r, "TStreamerSTL")
    Bytes.unmarshal!(e.elem, r)
    e.vtype = readbe(r, Int32)
    e.ctype = readbe(r, Int32)
    # `multimap` and `set` share a code in some files; the spelled-out type
    # name is authoritative where they disagree.
    if e.vtype == ESTL_MULTIMAP || e.vtype == ESTL_SET
        en = e.elem.ename
        if startswith(en, "std::set") || startswith(en, "set")
            e.vtype = Int32(ESTL_SET)
        elseif startswith(en, "std::multimap") || startswith(en, "multimap")
            e.vtype = Int32(ESTL_MULTIMAP)
        end
    end
    check_header(r, hdr)
    return e
end

function Bytes.marshal!(w::WBuffer, e::TStreamerSTL)
    hdr = write_header!(w, "TStreamerSTL", rversion(e))
    Bytes.marshal!(w, e.elem)
    writebe!(w, e.vtype)
    writebe!(w, e.ctype)
    set_header!(w, hdr)
    return w
end

"""
    TStreamerSTLstring

A `std::string` member, which ROOT treats as an STL container special case.
"""
mutable struct TStreamerSTLstring <: ROOTObject
    stl::TStreamerSTL
end

TStreamerSTLstring() = TStreamerSTLstring(TStreamerSTL())
Bytes.classname(::TStreamerSTLstring) = "TStreamerSTLstring"
rversion(::TStreamerSTLstring) = Int16(2)

function Bytes.unmarshal!(e::TStreamerSTLstring, r::RBuffer)
    hdr = read_header(r, "TStreamerSTLstring")
    Bytes.unmarshal!(e.stl, r)
    check_header(r, hdr)
    return e
end

function Bytes.marshal!(w::WBuffer, e::TStreamerSTLstring)
    hdr = write_header!(w, "TStreamerSTLstring", rversion(e))
    Bytes.marshal!(w, e.stl)
    set_header!(w, hdr)
    return w
end

"""
    AbstractStreamerElement

Any of the `TStreamer*` element classes. They all wrap a
[`StreamerElement`](@ref), directly or through one more level, so
[`element`](@ref) reaches it uniformly.
"""
const AbstractStreamerElement = Union{
    TStreamerBase,
    TStreamerBasicType,
    TStreamerBasicPointer,
    TStreamerLoop,
    TStreamerObject,
    TStreamerObjectPointer,
    TStreamerObjectAny,
    TStreamerObjectAnyPointer,
    TStreamerString,
    TStreamerSTL,
    TStreamerSTLstring,
    TStreamerArtificial,
}

"""
    element(e) -> StreamerElement

The common `TStreamerElement` part of any streamer element.
"""
element(e::AbstractStreamerElement) = e.elem
element(e::TStreamerSTLstring) = e.stl.elem
element(e::StreamerElement) = e

name(e::AbstractStreamerElement) = name(element(e))
title(e::AbstractStreamerElement) = title(element(e))

"The `rmeta` type code of the member this element describes."
etype(e) = element(e).etype

"The spelled-out C++ type name of the member this element describes."
typename(e) = element(e).ename

"Number of elements in a fixed-size array member; zero when it is not an array."
arraylen(e) = Int(element(e).arrlen)

"Dimensions of a fixed-size array member."
arraydims(e) = element(e).maxidx[1:Int(element(e).arrdim)]

function Base.show(io::IO, e::AbstractStreamerElement)
    el = element(e)
    print(io, Bytes.classname(e), "(", repr(el.named.name))
    print(io, ", type=", el.etype, ", ", repr(el.ename))
    el.arrlen > 0 && print(io, ", [", el.arrlen, "]")
    return print(io, ")")
end

# ---------------------------------------------------------------------------

"""
    KIS_COMPILED

`TVirtualStreamerInfo::kIsCompiled`, the bit ROOT sets on a description whose
members it has resolved into offsets.

Like `kIsOnHeap` it says something about ROOT's memory rather than about the
file, but unlike `kIsOnHeap` ROOT writes it out, and every description this
package can stream is compiled in exactly that sense. Carrying it is what makes
a record written here byte-identical to the one ROOT writes for the same class.
"""
const KIS_COMPILED = UInt32(1) << 16

"""
    TStreamerInfo

A file's description of one version of one C++ class.

The elements are held directly rather than in the `TObjArray` ROOT streams them
in: the array is a container detail, and every user of a streamer info wants
the ordered list.
"""
mutable struct TStreamerInfo <: ROOTObject
    named::TNamed
    checksum::UInt32
    clsver::Int32
    elems::Vector{Any}
end

function TStreamerInfo(
    name::AbstractString="",
    clsver::Integer=0;
    checksum::Integer=0,
    elems::AbstractVector=Any[],
)
    named = TNamed(name, "")
    named.obj.bits |= KIS_COMPILED
    return TStreamerInfo(named, UInt32(checksum), Int32(clsver), collect(Any, elems))
end

Bytes.classname(::TStreamerInfo) = "TStreamerInfo"
rversion(::TStreamerInfo) = Int16(10)

Bytes.described_class(si::TStreamerInfo) = si.named.name
Bytes.class_version(si::TStreamerInfo) = si.clsver
Bytes.class_checksum(si::TStreamerInfo) = si.checksum

"The elements of a streamer info, in the order ROOT wrote them."
elements(si::TStreamerInfo) = si.elems

Base.length(si::TStreamerInfo) = length(si.elems)
Base.getindex(si::TStreamerInfo, i::Integer) = si.elems[i]
function Base.iterate(si::TStreamerInfo, s::Int=1)
    return s > length(si.elems) ? nothing : (si.elems[s], s + 1)
end
Base.eltype(::Type{TStreamerInfo}) = Any

function Bytes.unmarshal!(si::TStreamerInfo, r::RBuffer)
    hdr = read_header(r, "TStreamerInfo")
    Bytes.unmarshal!(si.named, r)
    si.checksum = readbe(r, UInt32)
    si.clsver = readbe(r, Int32)
    arr = read_object_any(r)
    si.elems = arr === nothing ? Any[] : collect(Any, arr)
    check_header(r, hdr)
    return si
end

function Bytes.marshal!(w::WBuffer, si::TStreamerInfo)
    hdr = write_header!(w, "TStreamerInfo", rversion(si))
    Bytes.marshal!(w, si.named)
    writebe!(w, si.checksum)
    writebe!(w, si.clsver)
    write_object_any!(w, TObjArray("", si.elems))
    set_header!(w, hdr)
    return w
end

function Base.show(io::IO, si::TStreamerInfo)
    print(io, "TStreamerInfo(", repr(si.named.name), " v", si.clsver)
    return print(io, ", ", length(si.elems), " elements)")
end

"""
    describe(io::IO=stdout, si::TStreamerInfo)

Print a streamer info the way `TStreamerInfo::ls` does — one line per element,
with its type code, size and offset.
"""
describe(si::TStreamerInfo) = describe(stdout, si)

function describe(io::IO, si::TStreamerInfo)
    println(io, "StreamerInfo for ", repr(si.named.name), " version=", si.clsver)
    for e in si.elems
        el = element(e)
        println(
            io,
            "  ",
            rpad(el.ename, 28),
            rpad(el.named.name, 24),
            "type=",
            lpad(el.etype, 4),
            "  size=",
            lpad(el.esize, 4),
            "  ",
            el.named.title,
        )
    end
    return nothing
end
