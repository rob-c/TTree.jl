# ROOT's leaves: what a branch's bytes mean.
#
# A leaf names one member of the entry a branch stores, and says how wide it is
# — a scalar, a fixed-size array, or an array whose length is another leaf's
# value. Everything the data reader needs to turn a basket back into values is
# here; the branch itself only knows where the baskets are.
#
# As with the streamer elements, the part every leaf class shares is factored
# into one struct that each concrete class wraps, because that is exactly how
# ROOT streams them: `TLeaf` inline, then the subclass's own two fields.

"""
    Leaf

ROOT's `TLeaf`: the part every leaf shares.

`len` is the number of values in one entry, which for a variable-length leaf is
its *maximum* rather than its actual length — `count` then points at the leaf
holding the real length, entry by entry. `lentype` is the width of one value in
bytes.
"""
mutable struct Leaf
    named::TNamed
    len::Int32
    lentype::Int32
    offset::Int32
    isrange::Bool
    isunsigned::Bool
    count::Any
end

function Leaf(
    name::AbstractString="",
    title::AbstractString="";
    len::Integer=1,
    lentype::Integer=0,
    isunsigned::Bool=false,
)
    return Leaf(
        TNamed(name, title),
        Int32(len),
        Int32(lentype),
        Int32(0),
        false,
        isunsigned,
        nothing,
    )
end

Bytes.classname(::Leaf) = "TLeaf"
rversion(::Leaf) = Int16(2)

function Bytes.unmarshal!(l::Leaf, r::RBuffer)
    hdr = read_header(r, "TLeaf")
    Bytes.unmarshal!(l.named, r)
    l.len = readbe(r, Int32)
    l.lentype = readbe(r, Int32)
    l.offset = readbe(r, Int32)
    l.isrange = readbe(r, Bool)
    l.isunsigned = readbe(r, Bool)
    l.count = read_object_any(r)
    check_header(r, hdr)
    return l
end

function Bytes.marshal!(w::WBuffer, l::Leaf)
    hdr = write_header!(w, "TLeaf", rversion(l))
    Bytes.marshal!(w, l.named)
    writebe!(w, l.len)
    writebe!(w, l.lentype)
    writebe!(w, l.offset)
    writebe!(w, l.isrange)
    writebe!(w, l.isunsigned)
    write_object_any!(w, l.count)
    set_header!(w, hdr)
    return w
end

# ---------------------------------------------------------------------------
# The concrete leaves.
#
# Each adds a minimum and a maximum in its own type, which ROOT fills in only
# when the branch was given a range; the rest is the `TLeaf` above. The type of
# the two bounds is not always the type of the data — a `TLeafC` holds strings
# but bounds their length with an `int` — so the table carries both. The two
# packed leaves are at class version 2, the rest at 1: ROOT versioned them again
# when it moved their range out of the object and into the title.

for (cls, R, T, V) in (
    (:TLeafO, Bool, Bool, 1),
    (:TLeafB, Int8, Int8, 1),
    (:TLeafS, Int16, Int16, 1),
    (:TLeafI, Int32, Int32, 1),
    (:TLeafL, Int64, Int64, 1),
    (:TLeafG, Int64, Int64, 1),
    (:TLeafF, Float32, Float32, 1),
    (:TLeafD, Float64, Float64, 1),
    (:TLeafF16, Float32, Float32, 2),
    (:TLeafD32, Float64, Float64, 2),
    (:TLeafC, Int32, String, 1),
)
    cls_str = String(cls)
    @eval begin
        """
            $($cls_str)()

        ROOT's `$($cls_str)`: a leaf holding `$($T)` values.

        `min` and `max` are the range the branch was declared with, and are both
        zero — ROOT's default — unless [`Leaf`](@ref)`.isrange` says otherwise.
        """
        mutable struct $cls <: ROOTObject
            leaf::Leaf
            min::$R
            max::$R
        end

        $cls() = $cls(Leaf(), zero($R), zero($R))
        Bytes.classname(::$cls) = $cls_str
        rversion(::$cls) = Int16($V)

        "The Julia type of the values this leaf holds."
        Base.eltype(::Type{$cls}) = $T
    end
end

# ROOT does not spell an unsigned leaf with a class of its own: the leaf class
# gives the width and `fIsUnsigned` gives the sign, so the element type is only
# settled once both are known.
for (cls, U) in (
    (:TLeafB, UInt8),
    (:TLeafS, UInt16),
    (:TLeafI, UInt32),
    (:TLeafL, UInt64),
    (:TLeafG, UInt64),
)
    @eval elementtype(l::$cls) = l.leaf.isunsigned ? $U : eltype($cls)
end

"""
    elementtype(leaf) -> Type

The Julia type of one value in `leaf`.

Distinct from `eltype` on the class, which cannot see whether the leaf was
declared unsigned.
"""
elementtype(l) = eltype(typeof(l))

"""
    TLeafElement

The leaf of a branch whose entries are streamed by their class's streamer info
rather than as plain numbers. It carries no data description of its own: `id`
indexes the element inside that streamer info, and `ltype` repeats the branch's
streamer type.
"""
mutable struct TLeafElement <: ROOTObject
    leaf::Leaf
    id::Int32
    ltype::Int32
end

TLeafElement() = TLeafElement(Leaf(), Int32(-1), Int32(0))
Bytes.classname(::TLeafElement) = "TLeafElement"
rversion(::TLeafElement) = Int16(1)
Base.eltype(::Type{TLeafElement}) = Any

"""
    TLeafObject

The leaf of a branch holding a whole object per entry, written before ROOT had
`TBranchElement`. `virt` records whether the object's class was written with
each entry.
"""
mutable struct TLeafObject <: ROOTObject
    leaf::Leaf
    virt::Bool
end

TLeafObject() = TLeafObject(Leaf(), false)
Bytes.classname(::TLeafObject) = "TLeafObject"
rversion(::TLeafObject) = Int16(4)
Base.eltype(::Type{TLeafObject}) = Any

"""
    AnyLeaf

Any of ROOT's leaf classes. They all wrap a [`Leaf`](@ref), which
[`leafcore`](@ref) reaches uniformly.
"""
const AnyLeaf = Union{
    TLeafO,
    TLeafB,
    TLeafS,
    TLeafI,
    TLeafL,
    TLeafG,
    TLeafF,
    TLeafD,
    TLeafF16,
    TLeafD32,
    TLeafC,
    TLeafElement,
    TLeafObject,
}

"""
    PlainLeaf

The leaf classes whose values are stored exactly as their element type, one
after another with nothing in between.

The others each need reading value by value: a `TLeafC` carries its own length,
a `TLeafF16` or `TLeafD32` is packed into fewer bytes than its type says, and a
`TLeafElement` or `TLeafObject` holds a streamed object.
"""
const PlainLeaf = Union{TLeafO,TLeafB,TLeafS,TLeafI,TLeafL,TLeafG,TLeafF,TLeafD}

"""
    leafcore(leaf) -> Leaf

The common `TLeaf` part of any leaf.
"""
leafcore(l::AnyLeaf) = l.leaf
leafcore(l::Leaf) = l

Objects.name(l::AnyLeaf) = Objects.name(leafcore(l).named)
Objects.title(l::AnyLeaf) = Objects.title(leafcore(l).named)
Objects.name(l::Leaf) = Objects.name(l.named)
Objects.title(l::Leaf) = Objects.title(l.named)

"Number of values in one entry — the maximum, for a variable-length leaf."
Base.length(l::AnyLeaf) = Int(leafcore(l).len)

"The leaf holding this one's per-entry length, or `nothing` when it is fixed."
countleaf(l::AnyLeaf) = leafcore(l).count

"True when each entry of this leaf may be a different length."
isjagged(l::AnyLeaf) = countleaf(l) !== nothing

"Width in bytes of one value, as ROOT recorded it."
valuesize(l::AnyLeaf) = Int(leafcore(l).lentype)

# The bounds of a `Float16_t`/`Double32_t` leaf are packed the same way its data
# would be, so reading them needs the leaf's own title — which is where ROOT
# spells the range.
_leaf_range(l) = Objects.parse_range(Objects.title(leafcore(l)))

for (cls, R) in (
    (:TLeafO, Bool),
    (:TLeafB, Int8),
    (:TLeafS, Int16),
    (:TLeafI, Int32),
    (:TLeafL, Int64),
    (:TLeafG, Int64),
    (:TLeafF, Float32),
    (:TLeafD, Float64),
    (:TLeafC, Int32),
)
    cls_str = String(cls)
    @eval begin
        function Bytes.unmarshal!(l::$cls, r::RBuffer)
            hdr = read_header(r, $cls_str)
            Bytes.unmarshal!(l.leaf, r)
            l.min = readbe(r, $R)
            l.max = readbe(r, $R)
            check_header(r, hdr)
            return l
        end

        function Bytes.marshal!(w::WBuffer, l::$cls)
            hdr = write_header!(w, $cls_str, rversion(l))
            Bytes.marshal!(w, l.leaf)
            writebe!(w, l.min)
            writebe!(w, l.max)
            set_header!(w, hdr)
            return w
        end
    end
end

function Bytes.unmarshal!(l::TLeafF16, r::RBuffer)
    hdr = read_header(r, "TLeafF16")
    Bytes.unmarshal!(l.leaf, r)
    xmin, xmax, factor = _leaf_range(l)
    l.min = read_float16(r, xmin, xmax, factor)
    l.max = read_float16(r, xmin, xmax, factor)
    check_header(r, hdr)
    return l
end

function Bytes.marshal!(w::WBuffer, l::TLeafF16)
    hdr = write_header!(w, "TLeafF16", rversion(l))
    Bytes.marshal!(w, l.leaf)
    xmin, xmax, factor = _leaf_range(l)
    write_float16!(w, l.min, xmin, xmax, factor)
    write_float16!(w, l.max, xmin, xmax, factor)
    set_header!(w, hdr)
    return w
end

function Bytes.unmarshal!(l::TLeafD32, r::RBuffer)
    hdr = read_header(r, "TLeafD32")
    Bytes.unmarshal!(l.leaf, r)
    xmin, xmax, factor = _leaf_range(l)
    l.min = read_double32(r, xmin, xmax, factor)
    l.max = read_double32(r, xmin, xmax, factor)
    check_header(r, hdr)
    return l
end

function Bytes.marshal!(w::WBuffer, l::TLeafD32)
    hdr = write_header!(w, "TLeafD32", rversion(l))
    Bytes.marshal!(w, l.leaf)
    xmin, xmax, factor = _leaf_range(l)
    write_double32!(w, l.min, xmin, xmax, factor)
    write_double32!(w, l.max, xmin, xmax, factor)
    set_header!(w, hdr)
    return w
end

function Bytes.unmarshal!(l::TLeafElement, r::RBuffer)
    hdr = read_header(r, "TLeafElement")
    Bytes.unmarshal!(l.leaf, r)
    l.id = readbe(r, Int32)
    l.ltype = readbe(r, Int32)
    check_header(r, hdr)
    return l
end

function Bytes.marshal!(w::WBuffer, l::TLeafElement)
    hdr = write_header!(w, "TLeafElement", rversion(l))
    Bytes.marshal!(w, l.leaf)
    writebe!(w, l.id)
    writebe!(w, l.ltype)
    set_header!(w, hdr)
    return w
end

function Bytes.unmarshal!(l::TLeafObject, r::RBuffer)
    hdr = read_header(r, "TLeafObject")
    Bytes.unmarshal!(l.leaf, r)
    # `fVirtual` arrived with version 4; before that an object was always
    # written with its class.
    l.virt = hdr.vers > 3 ? readbe(r, Bool) : true
    check_header(r, hdr)
    return l
end

function Bytes.marshal!(w::WBuffer, l::TLeafObject)
    hdr = write_header!(w, "TLeafObject", rversion(l))
    Bytes.marshal!(w, l.leaf)
    writebe!(w, l.virt)
    set_header!(w, hdr)
    return w
end

function Base.show(io::IO, l::AnyLeaf)
    print(io, Bytes.classname(l), "(", repr(Objects.name(l)))
    n = length(l)
    c = countleaf(l)
    if c !== nothing
        print(io, "[", Objects.name(c), "]")
    elseif n != 1
        print(io, "[", n, "]")
    end
    return print(io, ")")
end
