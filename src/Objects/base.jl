# The base of ROOT's class hierarchy, and the attribute mix-ins that almost
# every drawable object inherits.
#
# C++ inheritance is modelled by composition: a class that derives from TNamed
# holds a `TNamed` field and streams it where ROOT streams the base class. The
# byte layout is identical — ROOT writes base classes inline — and it keeps the
# Julia types concrete, which matters for a package whose inner loops are
# decoding.

"""
    ROOTObject

Supertype of every class this package can read from or write to a ROOT file.

A subtype must provide [`classname`](@ref), [`rversion`](@ref),
`Bytes.unmarshal!` and `Bytes.marshal!`, and register itself with
[`register_class!`](@ref) so that [`read_object_any`](@ref) can instantiate it.
"""
abstract type ROOTObject end

"""
    rversion(obj) -> Int16

The class version `obj` is streamed as — ROOT's `Class_Version()`.

This is the version written into an object's header, and is distinct from
[`class_version`](@ref TTree.Bytes.class_version), which is the version of the
class a `TStreamerInfo` *describes*.
"""
function rversion end

"""
    TObject

ROOT's universal base class: a unique id and a bit field.

It is the one class streamed without a byte count — just a version word — which
is why it is read through [`skip_version!`](@ref) rather than the usual header
machinery.
"""
mutable struct TObject <: ROOTObject
    id::UInt32
    bits::UInt32
end

TObject() = TObject(UInt32(0), UInt32(0x03000000))

Bytes.classname(::TObject) = "TObject"
rversion(::TObject) = Int16(1)

"""
    skip_version!(r::RBuffer) -> Int16

Read and discard a bare version word, handling the case where ROOT prefixed it
with a byte count.

`KBYTE_COUNT_VMASK` set in the version means the two bytes just read were the
top half of a four-byte count, so the real version is two words further on.
"""
function skip_version!(r::RBuffer)
    v = readbe(r, Int16)
    if (Int64(v) & KBYTE_COUNT_VMASK) != 0
        skip!(r, 2)
        v = readbe(r, Int16)
    end
    return v
end

function Bytes.unmarshal!(o::TObject, r::RBuffer)
    skip_version!(r)
    o.id = readbe(r, UInt32)
    o.bits = readbe(r, UInt32) | UInt32(Bytes.KIS_ON_HEAP)
    # A referenced object carries the id of the process that owns its
    # TRefTable. Nothing here resolves references, but the two bytes are part
    # of the record and must be consumed.
    if (o.bits & UInt32(Bytes.KIS_REFERENCED)) != 0
        skip!(r, 2)
    end
    return o
end

function Bytes.marshal!(w::WBuffer, o::TObject)
    # `kIsOnHeap` and `kNotDeleted` describe how C++ owns the object, not
    # anything about the file, and current ROOT masks both out as it writes.
    # Doing the same is what makes a file this package writes byte-identical to
    # one ROOT would have written from the same objects.
    bits = o.bits & ~(UInt32(Bytes.KIS_ON_HEAP) | UInt32(Bytes.KNOT_DELETED))
    writebe!(w, UInt16(rversion(o)))
    if (bits & UInt32(Bytes.KIS_REFERENCED)) != 0
        writebe!(w, o.id & 0x00ffffff)
        writebe!(w, bits)
        writebe!(w, UInt16(0))
    else
        writebe!(w, o.id)
        writebe!(w, bits)
    end
    return w
end

"""
    TNamed

A [`TObject`](@ref) with a name and a title — the base of almost everything a
file stores by name.
"""
mutable struct TNamed <: ROOTObject
    obj::TObject
    name::String
    title::String
end

function TNamed(name::AbstractString="", title::AbstractString="")
    return TNamed(TObject(), String(name), String(title))
end

Bytes.classname(::TNamed) = "TNamed"
rversion(::TNamed) = Int16(1)

function Bytes.unmarshal!(n::TNamed, r::RBuffer)
    hdr = read_header(r, "TNamed")
    Bytes.unmarshal!(n.obj, r)
    n.name = read_tstring(r)
    n.title = read_tstring(r)
    check_header(r, hdr)
    return n
end

function Bytes.marshal!(w::WBuffer, n::TNamed)
    hdr = write_header!(w, "TNamed", rversion(n))
    Bytes.marshal!(w, n.obj)
    write_tstring!(w, n.name)
    write_tstring!(w, n.title)
    set_header!(w, hdr)
    return w
end

function Base.show(io::IO, n::TNamed)
    print(io, "TNamed(", repr(n.name))
    isempty(n.title) || print(io, ", ", repr(n.title))
    print(io, ")")
    return nothing
end

# The id is ROOT's unique-object number, which is zero in every file this
# package has seen; the bits are the status flags. Both are shown in hex
# because that is how ROOT's own `kIsOnHeap`-style constants are written.
function Base.show(io::IO, o::TObject)
    return print(
        io,
        "TObject(id=0x",
        string(o.id; base=16, pad=8),
        ", bits=0x",
        string(o.bits; base=16, pad=8),
        ")",
    )
end

"""
    name(obj) -> String
    title(obj) -> String

The name and title of a ROOT object.

A class that derives from `TNamed` carries both itself. One that does not has
no name, and its title is the fixed description its C++ dictionary holds — the
string ROOT's `GetTitle` returns and writes into the key. Classes supply that
as a method; the fallback for one that has neither is empty.
"""
name(n::TNamed) = n.name
title(n::TNamed) = n.title
name(o::ROOTObject) = hasproperty(o, :named) ? name(o.named) : ""
title(o::ROOTObject) = hasproperty(o, :named) ? title(o.named) : ""

title(::TObject) = "Basic ROOT object"

"""
    entries(obj) -> Number

How many things went into `obj` — rows for a tree or a branch, fills for a
histogram.

One function rather than one per layer, because the question is the same
question: a histogram's `fEntries` counts exactly what a tree's does. It is a
whole number for a tree and a `Float64` for a histogram, which is ROOT's doing —
a weighted fill can add a fraction of an entry.
"""
function entries end

"""
    TObjString

A `TString` wrapped as an object, so that it can be stored in a file or a
collection on its own.
"""
mutable struct TObjString <: ROOTObject
    obj::TObject
    str::String
end

TObjString(s::AbstractString="") = TObjString(TObject(), String(s))

Bytes.classname(::TObjString) = "TObjString"
rversion(::TObjString) = Int16(1)
name(s::TObjString) = s.str
title(::TObjString) = "Collectable string class"

function Bytes.unmarshal!(s::TObjString, r::RBuffer)
    hdr = read_header(r, "TObjString")
    Bytes.unmarshal!(s.obj, r)
    s.str = read_tstring(r)
    check_header(r, hdr)
    return s
end

function Bytes.marshal!(w::WBuffer, s::TObjString)
    hdr = write_header!(w, "TObjString", rversion(s))
    Bytes.marshal!(w, s.obj)
    write_tstring!(w, s.str)
    set_header!(w, hdr)
    return w
end

Base.String(s::TObjString) = s.str
Base.show(io::IO, s::TObjString) = print(io, "TObjString(", repr(s.str), ")")

# ---------------------------------------------------------------------------
# Attribute mix-ins.
#
# These carry no data of their own beyond drawing style, but they are streamed
# inline inside every histogram and graph, so reading one means reading them.

"""
    TAttLine

Line colour, style and width.
"""
mutable struct TAttLine <: ROOTObject
    color::Int16
    style::Int16
    width::Int16
end

TAttLine() = TAttLine(Int16(1), Int16(1), Int16(1))
Bytes.classname(::TAttLine) = "TAttLine"
rversion(::TAttLine) = Int16(2)

function Bytes.unmarshal!(a::TAttLine, r::RBuffer)
    hdr = read_header(r, "TAttLine")
    a.color = readbe(r, Int16)
    a.style = readbe(r, Int16)
    a.width = readbe(r, Int16)
    check_header(r, hdr)
    return a
end

function Bytes.marshal!(w::WBuffer, a::TAttLine)
    hdr = write_header!(w, "TAttLine", rversion(a))
    writebe!(w, a.color)
    writebe!(w, a.style)
    writebe!(w, a.width)
    set_header!(w, hdr)
    return w
end

"""
    TAttFill

Fill colour and style.
"""
mutable struct TAttFill <: ROOTObject
    color::Int16
    style::Int16
end

TAttFill() = TAttFill(Int16(0), Int16(1001))
Bytes.classname(::TAttFill) = "TAttFill"
rversion(::TAttFill) = Int16(2)

function Bytes.unmarshal!(a::TAttFill, r::RBuffer)
    hdr = read_header(r, "TAttFill")
    a.color = readbe(r, Int16)
    a.style = readbe(r, Int16)
    check_header(r, hdr)
    return a
end

function Bytes.marshal!(w::WBuffer, a::TAttFill)
    hdr = write_header!(w, "TAttFill", rversion(a))
    writebe!(w, a.color)
    writebe!(w, a.style)
    set_header!(w, hdr)
    return w
end

"""
    TAttMarker

Marker colour, style and size.
"""
mutable struct TAttMarker <: ROOTObject
    color::Int16
    style::Int16
    size::Float32
end

TAttMarker() = TAttMarker(Int16(1), Int16(1), Float32(1))
Bytes.classname(::TAttMarker) = "TAttMarker"
rversion(::TAttMarker) = Int16(3)

function Bytes.unmarshal!(a::TAttMarker, r::RBuffer)
    hdr = read_header(r, "TAttMarker")
    a.color = readbe(r, Int16)
    a.style = readbe(r, Int16)
    a.size = readbe(r, Float32)
    check_header(r, hdr)
    return a
end

function Bytes.marshal!(w::WBuffer, a::TAttMarker)
    hdr = write_header!(w, "TAttMarker", rversion(a))
    writebe!(w, a.color)
    writebe!(w, a.style)
    writebe!(w, a.size)
    set_header!(w, hdr)
    return w
end

"""
    TAttAxis

Axis drawing attributes: divisions, colours, fonts and the offsets and sizes of
labels and titles.
"""
mutable struct TAttAxis <: ROOTObject
    ndivs::Int32
    axiscolor::Int16
    labelcolor::Int16
    labelfont::Int16
    labeloffset::Float32
    labelsize::Float32
    ticklength::Float32
    titleoffset::Float32
    titlesize::Float32
    titlecolor::Int16
    titlefont::Int16
end

function TAttAxis()
    return TAttAxis(
        Int32(510),
        Int16(1),
        Int16(1),
        Int16(42),
        Float32(0.005),
        Float32(0.035),
        Float32(0.03),
        Float32(1),
        Float32(0.035),
        Int16(1),
        Int16(42),
    )
end

Bytes.classname(::TAttAxis) = "TAttAxis"
rversion(::TAttAxis) = Int16(4)

function Bytes.unmarshal!(a::TAttAxis, r::RBuffer)
    hdr = read_header(r, "TAttAxis")
    a.ndivs = readbe(r, Int32)
    a.axiscolor = readbe(r, Int16)
    a.labelcolor = readbe(r, Int16)
    a.labelfont = readbe(r, Int16)
    a.labeloffset = readbe(r, Float32)
    a.labelsize = readbe(r, Float32)
    a.ticklength = readbe(r, Float32)
    a.titleoffset = readbe(r, Float32)
    a.titlesize = readbe(r, Float32)
    a.titlecolor = readbe(r, Int16)
    a.titlefont = readbe(r, Int16)
    check_header(r, hdr)
    return a
end

function Bytes.marshal!(w::WBuffer, a::TAttAxis)
    hdr = write_header!(w, "TAttAxis", rversion(a))
    writebe!(w, a.ndivs)
    writebe!(w, a.axiscolor)
    writebe!(w, a.labelcolor)
    writebe!(w, a.labelfont)
    writebe!(w, a.labeloffset)
    writebe!(w, a.labelsize)
    writebe!(w, a.ticklength)
    writebe!(w, a.titleoffset)
    writebe!(w, a.titlesize)
    writebe!(w, a.titlecolor)
    writebe!(w, a.titlefont)
    set_header!(w, hdr)
    return w
end
