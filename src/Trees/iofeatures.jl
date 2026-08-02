# The one class in this layer that is not a tree, a branch, a leaf or a basket.
#
# The machinery for reading a class by the file's own description of it —
# `layout` and the member readers around it — lives in `TTree.Objects`, because
# trees are not the only classes ROOT streams that way. See `Objects/layout.jl`.

"""
    TIOFeatures

ROOT's `ROOT::TIOFeatures`: a bit per optional on-disk feature a tree's baskets
may use.

Nothing here acts on the bits — this package writes baskets in the format every
ROOT can read — but they are part of a tree's record and must survive a
round trip.
"""
mutable struct TIOFeatures <: ROOTObject
    bits::UInt8
end

TIOFeatures() = TIOFeatures(0x00)

Bytes.classname(::TIOFeatures) = "ROOT::TIOFeatures"
rversion(::TIOFeatures) = Int16(1)
Objects.title(::TIOFeatures) = "IO feature flags"

function Bytes.unmarshal!(x::TIOFeatures, r::RBuffer)
    hdr = read_header(r, "ROOT::TIOFeatures")
    x.bits = readbe(r, UInt8)
    check_header(r, hdr)
    return x
end

function Bytes.marshal!(w::WBuffer, x::TIOFeatures)
    hdr = write_header!(w, "ROOT::TIOFeatures", rversion(x))
    writebe!(w, x.bits)
    set_header!(w, hdr)
    return w
end

function Base.show(io::IO, x::TIOFeatures)
    return print(io, "TIOFeatures(0x", string(x.bits; base=16, pad=2), ")")
end
