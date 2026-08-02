# ROOT's histograms.
#
# A histogram is an axis — or two, or three — and an array of cell counts, and
# almost everything else it carries is either drawing style or the running sums
# that let it report a mean and an RMS without keeping the entries it was filled
# with.
#
# The inheritance is deeper here than anywhere else in the format. `TH1` holds
# the axes and the statistics but no cells; the cells live in a `TArray` base
# that decides their width, so `TH1F` is `TH1` plus `TArrayF` and nothing more.
# `TH2` adds the sums that involve `y` and `TH3` those that involve `z`, and
# each of those has its own family of `TArray`-typed leaves. `TProfile` is a
# `TH1D` that keeps a second array of per-bin entry counts.
#
# All of it is streamed from the description ROOT compiled rather than from a
# hand-written `Streamer`, and the descriptions have moved: `TAxis` gained
# labels between versions 6 and 10, `TH1` an entry buffer and two statistics
# options between 3 and 8. So reading follows the file's own description — see
# `layout` — while writing emits the current version.

"""
    TAxis

One axis of a histogram: how many bins, where they start and end, and — when
they are not evenly spaced — every edge.

`xbins` is empty for the usual fixed-width axis, in which case the edges are
implied by `nbins`, `xmin` and `xmax`; [`binedges`](@ref) returns them either
way. `labels` is set only on an axis whose bins are named rather than numeric.
"""
mutable struct TAxis <: ROOTObject
    named::TNamed
    att::TAttAxis
    nbins::Int32
    xmin::Float64
    xmax::Float64
    xbins::Vector{Float64}
    first::Int32
    last::Int32
    bits2::UInt16
    timedisplay::Bool
    timeformat::String
    labels::Any
    modlabs::Any
end

function TAxis(name::AbstractString="", title::AbstractString="")
    return TAxis(
        TNamed(name, title),
        TAttAxis(),
        Int32(0),
        0.0,
        0.0,
        Float64[],
        Int32(0),
        Int32(0),
        UInt16(0),
        false,
        "",
        nothing,
        nothing,
    )
end

"""
    TAxis(nbins, xmin, xmax; name="", title="")
    TAxis(edges::AbstractVector; name="", title="")

An axis of `nbins` equal bins spanning `xmin` to `xmax`, or one whose bin edges
are given outright — `length(edges) - 1` bins, low edge first.
"""
function TAxis(
    nbins::Integer,
    xmin::Real,
    xmax::Real;
    name::AbstractString="",
    title::AbstractString="",
)
    nbins > 0 || throw(ArgumentError("TTree: an axis needs at least one bin, got $nbins"))
    xmin < xmax ||
        throw(ArgumentError("TTree: axis limits must increase, got $xmin to $xmax"))
    a = TAxis(name, title)
    a.nbins = Int32(nbins)
    a.xmin = Float64(xmin)
    a.xmax = Float64(xmax)
    return a
end

function TAxis(
    edges::AbstractVector{<:Real}; name::AbstractString="", title::AbstractString=""
)
    length(edges) >= 2 || throw(
        ArgumentError("TTree: an axis needs at least two edges, got $(length(edges))")
    )
    issorted(edges) || throw(ArgumentError("TTree: axis bin edges must increase"))
    a = TAxis(name, title)
    a.nbins = Int32(length(edges) - 1)
    a.xmin = Float64(first(edges))
    a.xmax = Float64(last(edges))
    a.xbins = Float64[Float64(x) for x in edges]
    return a
end

Bytes.classname(::TAxis) = "TAxis"
rversion(::TAxis) = Int16(10)

function Bytes.unmarshal!(a::TAxis, r::RBuffer)
    hdr = read_header(r, "TAxis")
    for e in layout(r, "TAxis", hdr.vers)
        m = name(e)
        if m == "TNamed"
            Bytes.unmarshal!(a.named, r)
        elseif m == "TAttAxis"
            Bytes.unmarshal!(a.att, r)
        elseif m == "fNbins"
            a.nbins = read_scalar(r, e)
        elseif m == "fXmin"
            a.xmin = read_real(r, e)
        elseif m == "fXmax"
            a.xmax = read_real(r, e)
        elseif m == "fXbins"
            read_tarray!(a.xbins, r)
        elseif m == "fFirst"
            a.first = read_scalar(r, e)
        elseif m == "fLast"
            a.last = read_scalar(r, e)
        elseif m == "fBits2"
            a.bits2 = read_scalar(r, e)
        elseif m == "fTimeDisplay"
            a.timedisplay = read_scalar(r, e) != 0
        elseif m == "fTimeFormat"
            a.timeformat = read_tstring(r)
        elseif m == "fLabels"
            a.labels = read_object_member(r, e, THashList)
        elseif m == "fModLabs"
            a.modlabs = read_object_member(r, e, TList)
        else
            unknown_member("TAxis", hdr.vers, m)
        end
    end
    check_header(r, hdr)
    return a
end

function Bytes.marshal!(w::WBuffer, a::TAxis)
    hdr = write_header!(w, "TAxis", rversion(a))
    Bytes.marshal!(w, a.named)
    Bytes.marshal!(w, a.att)
    writebe!(w, a.nbins)
    writebe!(w, a.xmin)
    writebe!(w, a.xmax)
    write_tarray!(w, a.xbins)
    writebe!(w, a.first)
    writebe!(w, a.last)
    writebe!(w, a.bits2)
    writebe!(w, a.timedisplay)
    write_tstring!(w, a.timeformat)
    write_object_any!(w, a.labels)
    write_object_any!(w, a.modlabs)
    set_header!(w, hdr)
    return w
end

"""
    nbins(axis) -> Int
    nbins(hist[, which]) -> Int

The number of bins the axis divides its range into, not counting the underflow
and overflow bins that sit outside it.
"""
nbins(a::TAxis) = Int(a.nbins)

"""
    binedges(axis) -> Vector{Float64}

Every bin edge, low to high: `nbins(axis) + 1` of them.

A fixed-width axis stores only its limits, so the edges are computed; one with
variable bins stores them and they are returned as they were read.
"""
function binedges(a::TAxis)
    isempty(a.xbins) || return copy(a.xbins)
    n = nbins(a)
    n == 0 && return Float64[]
    w = (a.xmax - a.xmin) / n
    return Float64[a.xmin + w * i for i in 0:n]
end

"""
    binlowedge(axis, i) -> Float64
    binwidth(axis, i) -> Float64

The low edge and the width of bin `i`, counted from one as ROOT counts them.
"""
function binlowedge(a::TAxis, i::Integer)
    isempty(a.xbins) || return a.xbins[i]
    return a.xmin + (a.xmax - a.xmin) * (i - 1) / nbins(a)
end

function binwidth(a::TAxis, i::Integer)
    isempty(a.xbins) || return a.xbins[i + 1] - a.xbins[i]
    return (a.xmax - a.xmin) / nbins(a)
end

"The midpoint of every bin."
function bincenters(a::TAxis)
    e = binedges(a)
    return Float64[(e[i] + e[i + 1]) / 2 for i in 1:(length(e) - 1)]
end

"""
    binlabels(axis) -> Vector{String}

The names of an axis whose bins are labelled, or empty for an ordinary one.
"""
function binlabels(a::TAxis)
    l = a.labels
    l === nothing && return String[]
    return String[name(o) for o in l if o !== nothing]
end

"""
    findbin(axis, x) -> Int

ROOT's bin numbering for the value `x`: `0` below the axis, `nbins + 1` above
it, and otherwise the bin containing `x`, counted from one.
"""
function findbin(a::TAxis, x::Real)
    n = nbins(a)
    x < a.xmin && return 0
    x >= a.xmax && return n + 1
    if isempty(a.xbins)
        return 1 + Int(floor(n * (x - a.xmin) / (a.xmax - a.xmin)))
    end
    # searchsortedlast gives the last edge not greater than x, which is the
    # bin's own number once the edges are counted from one.
    i = searchsortedlast(a.xbins, Float64(x))
    return clamp(i, 1, n)
end

function Base.show(io::IO, a::TAxis)
    print(io, "TAxis(", repr(name(a)), ", ", nbins(a), " bins, ", a.xmin, " to ", a.xmax)
    isempty(a.xbins) || print(io, ", variable")
    print(io, ")")
    return nothing
end

# ---------------------------------------------------------------------------
# TH1: the axes, the statistics, and everything a histogram has that is not its
# cells.

"""
    TH1

The part every histogram has: three axes, the running sums that give the mean
and RMS, and the drawing attributes.

It holds no cell contents — those live in the `TArray` base of the concrete
class, and are reached with [`bincontents`](@ref). `sumw2` is empty unless the
histogram was asked to track the sum of squared weights; see [`sumw2!`](@ref).
"""
mutable struct TH1 <: ROOTObject
    named::TNamed
    attline::TAttLine
    attfill::TAttFill
    attmarker::TAttMarker
    ncells::Int32
    xaxis::TAxis
    yaxis::TAxis
    zaxis::TAxis
    baroffset::Int16
    barwidth::Int16
    entries::Float64
    tsumw::Float64
    tsumw2::Float64
    tsumwx::Float64
    tsumwx2::Float64
    maximum::Float64
    minimum::Float64
    normfactor::Float64
    contour::Vector{Float64}
    sumw2::Vector{Float64}
    option::String
    functions::Any
    buffersize::Int32
    buffer::Vector{Float64}
    binstaterropt::Int32
    statoverflows::Int32
end

function TH1(name::AbstractString="", title::AbstractString="")
    return TH1(
        TNamed(name, title),
        TAttLine(),
        TAttFill(),
        TAttMarker(),
        Int32(0),
        TAxis("xaxis"),
        TAxis("yaxis"),
        TAxis("zaxis"),
        Int16(0),
        Int16(0),
        0.0,
        0.0,
        0.0,
        0.0,
        0.0,
        # ROOT's "unset" sentinels for the plotting range, not real extrema.
        -1111.0,
        -1111.0,
        0.0,
        Float64[],
        Float64[],
        "",
        TList(),
        Int32(0),
        Float64[],
        Int32(0),
        Int32(0),
    )
end

Bytes.classname(::TH1) = "TH1"
rversion(::TH1) = Int16(8)

function Bytes.unmarshal!(h::TH1, r::RBuffer)
    hdr = read_header(r, "TH1")
    hdr.vers > 2 || throw(
        ArgumentError(
            "TTree: TH1 version $(hdr.vers) predates automatic streaming and is not read",
        ),
    )
    for e in layout(r, "TH1", hdr.vers)
        m = name(e)
        if m == "TNamed"
            Bytes.unmarshal!(h.named, r)
        elseif m == "TAttLine"
            Bytes.unmarshal!(h.attline, r)
        elseif m == "TAttFill"
            Bytes.unmarshal!(h.attfill, r)
        elseif m == "TAttMarker"
            Bytes.unmarshal!(h.attmarker, r)
        elseif m == "fNcells"
            h.ncells = read_scalar(r, e)
        elseif m == "fXaxis"
            Bytes.unmarshal!(h.xaxis, r)
        elseif m == "fYaxis"
            Bytes.unmarshal!(h.yaxis, r)
        elseif m == "fZaxis"
            Bytes.unmarshal!(h.zaxis, r)
        elseif m == "fBarOffset"
            h.baroffset = read_scalar(r, e)
        elseif m == "fBarWidth"
            h.barwidth = read_scalar(r, e)
        elseif m == "fEntries"
            h.entries = read_real(r, e)
        elseif m == "fTsumw"
            h.tsumw = read_real(r, e)
        elseif m == "fTsumw2"
            h.tsumw2 = read_real(r, e)
        elseif m == "fTsumwx"
            h.tsumwx = read_real(r, e)
        elseif m == "fTsumwx2"
            h.tsumwx2 = read_real(r, e)
        elseif m == "fMaximum"
            h.maximum = read_real(r, e)
        elseif m == "fMinimum"
            h.minimum = read_real(r, e)
        elseif m == "fNormFactor"
            h.normfactor = read_real(r, e)
        elseif m == "fContour"
            read_tarray!(h.contour, r)
        elseif m == "fSumw2"
            read_tarray!(h.sumw2, r)
        elseif m == "fOption"
            h.option = read_tstring(r)
        elseif m == "fFunctions"
            h.functions = read_object_member(r, e, TList)
        elseif m == "fBufferSize"
            h.buffersize = read_scalar(r, e)
        elseif m == "fBuffer"
            h.buffer = read_pointer_array(r, e, h.buffersize, Float64)
        elseif m == "fBinStatErrOpt"
            h.binstaterropt = read_scalar(r, e)
        elseif m == "fStatOverflows"
            h.statoverflows = read_scalar(r, e)
        else
            unknown_member("TH1", hdr.vers, m)
        end
    end
    check_header(r, hdr)
    return h
end

function Bytes.marshal!(w::WBuffer, h::TH1)
    hdr = write_header!(w, "TH1", rversion(h))
    Bytes.marshal!(w, h.named)
    Bytes.marshal!(w, h.attline)
    Bytes.marshal!(w, h.attfill)
    Bytes.marshal!(w, h.attmarker)
    writebe!(w, h.ncells)
    Bytes.marshal!(w, h.xaxis)
    Bytes.marshal!(w, h.yaxis)
    Bytes.marshal!(w, h.zaxis)
    writebe!(w, h.baroffset)
    writebe!(w, h.barwidth)
    writebe!(w, h.entries)
    writebe!(w, h.tsumw)
    writebe!(w, h.tsumw2)
    writebe!(w, h.tsumwx)
    writebe!(w, h.tsumwx2)
    writebe!(w, h.maximum)
    writebe!(w, h.minimum)
    writebe!(w, h.normfactor)
    write_tarray!(w, h.contour)
    write_tarray!(w, h.sumw2)
    write_tstring!(w, h.option)
    # `fFunctions` is declared `//->` and is written inline, without the tag an
    # object that might be null would carry.
    Bytes.marshal!(w, h.functions === nothing ? TList() : h.functions)
    # The buffer's own length, not the stored `fBufferSize`: the two disagreeing
    # would make the record unreadable.
    writebe!(w, Int32(length(h.buffer)))
    write_pointer_array!(w, h.buffer)
    writebe!(w, h.binstaterropt)
    writebe!(w, h.statoverflows)
    set_header!(w, hdr)
    return w
end

# ---------------------------------------------------------------------------
# TH2 and TH3: the extra statistics the further axes need.

"""
    TH2

A `TH1` and the running sums that involve `y`. Like `TH1` it holds no cells of
its own; `TH2F` is this plus a `TArrayF`.
"""
mutable struct TH2 <: ROOTObject
    h::TH1
    scalefactor::Float64
    tsumwy::Float64
    tsumwy2::Float64
    tsumwxy::Float64
end

function TH2(name::AbstractString="", title::AbstractString="")
    return TH2(TH1(name, title), 0.0, 0.0, 0.0, 0.0)
end

Bytes.classname(::TH2) = "TH2"
rversion(::TH2) = Int16(5)

function Bytes.unmarshal!(h::TH2, r::RBuffer)
    hdr = read_header(r, "TH2")
    for e in layout(r, "TH2", hdr.vers)
        m = name(e)
        if m == "TH1"
            Bytes.unmarshal!(h.h, r)
        elseif m == "fScalefactor"
            h.scalefactor = read_real(r, e)
        elseif m == "fTsumwy"
            h.tsumwy = read_real(r, e)
        elseif m == "fTsumwy2"
            h.tsumwy2 = read_real(r, e)
        elseif m == "fTsumwxy"
            h.tsumwxy = read_real(r, e)
        else
            unknown_member("TH2", hdr.vers, m)
        end
    end
    check_header(r, hdr)
    return h
end

function Bytes.marshal!(w::WBuffer, h::TH2)
    hdr = write_header!(w, "TH2", rversion(h))
    Bytes.marshal!(w, h.h)
    writebe!(w, h.scalefactor)
    writebe!(w, h.tsumwy)
    writebe!(w, h.tsumwy2)
    writebe!(w, h.tsumwxy)
    set_header!(w, hdr)
    return w
end

"""
    TAtt3D

The 3D drawing attributes. ROOT's class has no members at all, but it is a base
of `TH3` and so is written — as a header with nothing after it.
"""
mutable struct TAtt3D <: ROOTObject end

Bytes.classname(::TAtt3D) = "TAtt3D"
rversion(::TAtt3D) = Int16(1)
title(::TAtt3D) = "3D attributes"

function Bytes.unmarshal!(a::TAtt3D, r::RBuffer)
    hdr = read_header(r, "TAtt3D")
    check_header(r, hdr)
    return a
end

function Bytes.marshal!(w::WBuffer, a::TAtt3D)
    hdr = write_header!(w, "TAtt3D", rversion(a))
    set_header!(w, hdr)
    return w
end

"""
    TH3

A `TH1`, the 3D attributes, and the running sums that involve `y` and `z`.
"""
mutable struct TH3 <: ROOTObject
    h::TH1
    att3d::TAtt3D
    tsumwy::Float64
    tsumwy2::Float64
    tsumwxy::Float64
    tsumwz::Float64
    tsumwz2::Float64
    tsumwxz::Float64
    tsumwyz::Float64
end

function TH3(name::AbstractString="", title::AbstractString="")
    return TH3(TH1(name, title), TAtt3D(), 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0)
end

Bytes.classname(::TH3) = "TH3"
rversion(::TH3) = Int16(6)

function Bytes.unmarshal!(h::TH3, r::RBuffer)
    hdr = read_header(r, "TH3")
    for e in layout(r, "TH3", hdr.vers)
        m = name(e)
        if m == "TH1"
            Bytes.unmarshal!(h.h, r)
        elseif m == "TAtt3D"
            Bytes.unmarshal!(h.att3d, r)
        elseif m == "fTsumwy"
            h.tsumwy = read_real(r, e)
        elseif m == "fTsumwy2"
            h.tsumwy2 = read_real(r, e)
        elseif m == "fTsumwxy"
            h.tsumwxy = read_real(r, e)
        elseif m == "fTsumwz"
            h.tsumwz = read_real(r, e)
        elseif m == "fTsumwz2"
            h.tsumwz2 = read_real(r, e)
        elseif m == "fTsumwxz"
            h.tsumwxz = read_real(r, e)
        elseif m == "fTsumwyz"
            h.tsumwyz = read_real(r, e)
        else
            unknown_member("TH3", hdr.vers, m)
        end
    end
    check_header(r, hdr)
    return h
end

function Bytes.marshal!(w::WBuffer, h::TH3)
    hdr = write_header!(w, "TH3", rversion(h))
    Bytes.marshal!(w, h.h)
    Bytes.marshal!(w, h.att3d)
    writebe!(w, h.tsumwy)
    writebe!(w, h.tsumwy2)
    writebe!(w, h.tsumwxy)
    writebe!(w, h.tsumwz)
    writebe!(w, h.tsumwz2)
    writebe!(w, h.tsumwxz)
    writebe!(w, h.tsumwyz)
    set_header!(w, hdr)
    return w
end

# ---------------------------------------------------------------------------
# The concrete histograms.
#
# Each is its dimensional base plus a `TArray` that fixes the cell type, and
# nothing else at all — so each is generated rather than written out eighteen
# times. The `TArray` base carries no header of its own, which is why the cells
# are read with `read_tarray!` rather than as an object.

for (cls, super, arr, T, vers, what, dims) in (
    (:TH1C, :TH1, :TArrayC, Int8, 3, "one char per channel", 1),
    (:TH1S, :TH1, :TArrayS, Int16, 3, "one short per channel", 1),
    (:TH1I, :TH1, :TArrayI, Int32, 3, "one int per channel", 1),
    (:TH1L, :TH1, :TArrayL64, Int64, 0, "one long64 per channel", 1),
    (:TH1F, :TH1, :TArrayF, Float32, 3, "one float per channel", 1),
    (:TH1D, :TH1, :TArrayD, Float64, 3, "one double per channel", 1),
    (:TH2C, :TH2, :TArrayC, Int8, 4, "one char per channel", 2),
    (:TH2S, :TH2, :TArrayS, Int16, 4, "one short per channel", 2),
    (:TH2I, :TH2, :TArrayI, Int32, 4, "one int per channel", 2),
    (:TH2L, :TH2, :TArrayL64, Int64, 0, "one long64 per channel", 2),
    (:TH2F, :TH2, :TArrayF, Float32, 4, "one float per channel", 2),
    (:TH2D, :TH2, :TArrayD, Float64, 4, "one double per channel", 2),
    (:TH3C, :TH3, :TArrayC, Int8, 4, "one char per channel", 3),
    (:TH3S, :TH3, :TArrayS, Int16, 4, "one short per channel", 3),
    (:TH3I, :TH3, :TArrayI, Int32, 4, "one int per channel", 3),
    (:TH3L, :TH3, :TArrayL64, Int64, 0, "one long64 per channel", 3),
    (:TH3F, :TH3, :TArrayF, Float32, 4, "one float per channel", 3),
    (:TH3D, :TH3, :TArrayD, Float64, 4, "one double per channel", 3),
)
    cls_str = String(cls)
    super_str = String(super)
    arr_str = String(arr)
    @eval begin
        """
            $($cls_str)(name, title, args...)

        ROOT's `$($cls_str)`: a $($dims)-dimensional histogram with $($what),
        streamed as a `$($super_str)` followed by a bare `$($arr_str)`.

        `data` holds every cell, underflow and overflow included; reach it as an
        array of the histogram's own shape with [`bincontents`](@ref).
        """
        mutable struct $cls <: ROOTObject
            h::$super
            data::Vector{$T}
        end

        $cls(name::AbstractString="", title::AbstractString="") =
            $cls($super(name, title), $T[])

        Bytes.classname(::$cls) = $cls_str
        rversion(::$cls) = Int16($vers)
        _cells(x::$cls) = x.data

        function Bytes.unmarshal!(x::$cls, r::RBuffer)
            hdr = read_header(r, $cls_str)
            for e in layout(r, $cls_str, hdr.vers)
                m = name(e)
                if m == $super_str
                    Bytes.unmarshal!(x.h, r)
                elseif m == $arr_str
                    read_tarray!(x.data, r)
                else
                    unknown_member($cls_str, hdr.vers, m)
                end
            end
            check_header(r, hdr)
            return x
        end

        function Bytes.marshal!(w::WBuffer, x::$cls)
            hdr = write_header!(w, $cls_str, rversion(x))
            Bytes.marshal!(w, x.h)
            write_tarray!(w, x.data)
            set_header!(w, hdr)
            return w
        end
    end
end

"""
    TProfile

A `TH1D` that remembers, per bin, how many entries went in and what they summed
to — so each bin reports the mean of a second quantity rather than a count.
"""
mutable struct TProfile <: ROOTObject
    h::TH1D
    binentries::Vector{Float64}
    errormode::Int32
    ymin::Float64
    ymax::Float64
    tsumwy::Float64
    tsumwy2::Float64
    binsumw2::Vector{Float64}
end

function TProfile(name::AbstractString="", title::AbstractString="")
    return TProfile(TH1D(name, title), Float64[], Int32(0), 0.0, 0.0, 0.0, 0.0, Float64[])
end

Bytes.classname(::TProfile) = "TProfile"
rversion(::TProfile) = Int16(7)

function Bytes.unmarshal!(p::TProfile, r::RBuffer)
    hdr = read_header(r, "TProfile")
    for e in layout(r, "TProfile", hdr.vers)
        m = name(e)
        if m == "TH1D"
            Bytes.unmarshal!(p.h, r)
        elseif m == "fBinEntries"
            read_tarray!(p.binentries, r)
        elseif m == "fErrorMode"
            p.errormode = read_scalar(r, e)
        elseif m == "fYmin"
            p.ymin = read_real(r, e)
        elseif m == "fYmax"
            p.ymax = read_real(r, e)
        elseif m == "fTsumwy"
            p.tsumwy = read_real(r, e)
        elseif m == "fTsumwy2"
            p.tsumwy2 = read_real(r, e)
        elseif m == "fBinSumw2"
            read_tarray!(p.binsumw2, r)
        else
            unknown_member("TProfile", hdr.vers, m)
        end
    end
    check_header(r, hdr)
    return p
end

function Bytes.marshal!(w::WBuffer, p::TProfile)
    hdr = write_header!(w, "TProfile", rversion(p))
    Bytes.marshal!(w, p.h)
    write_tarray!(w, p.binentries)
    writebe!(w, p.errormode)
    writebe!(w, p.ymin)
    writebe!(w, p.ymax)
    writebe!(w, p.tsumwy)
    writebe!(w, p.tsumwy2)
    write_tarray!(w, p.binsumw2)
    set_header!(w, hdr)
    return w
end

"""
    TProfile2D

The two-dimensional [`TProfile`](@ref): a `TH2D` with per-bin entry counts.
"""
mutable struct TProfile2D <: ROOTObject
    h::TH2D
    binentries::Vector{Float64}
    errormode::Int32
    zmin::Float64
    zmax::Float64
    tsumwz::Float64
    tsumwz2::Float64
    binsumw2::Vector{Float64}
end

function TProfile2D(name::AbstractString="", title::AbstractString="")
    return TProfile2D(TH2D(name, title), Float64[], Int32(0), 0.0, 0.0, 0.0, 0.0, Float64[])
end

Bytes.classname(::TProfile2D) = "TProfile2D"
rversion(::TProfile2D) = Int16(8)

function Bytes.unmarshal!(p::TProfile2D, r::RBuffer)
    hdr = read_header(r, "TProfile2D")
    for e in layout(r, "TProfile2D", hdr.vers)
        m = name(e)
        if m == "TH2D"
            Bytes.unmarshal!(p.h, r)
        elseif m == "fBinEntries"
            read_tarray!(p.binentries, r)
        elseif m == "fErrorMode"
            p.errormode = read_scalar(r, e)
        elseif m == "fZmin"
            p.zmin = read_real(r, e)
        elseif m == "fZmax"
            p.zmax = read_real(r, e)
        elseif m == "fTsumwz"
            p.tsumwz = read_real(r, e)
        elseif m == "fTsumwz2"
            p.tsumwz2 = read_real(r, e)
        elseif m == "fBinSumw2"
            read_tarray!(p.binsumw2, r)
        else
            unknown_member("TProfile2D", hdr.vers, m)
        end
    end
    check_header(r, hdr)
    return p
end

function Bytes.marshal!(w::WBuffer, p::TProfile2D)
    hdr = write_header!(w, "TProfile2D", rversion(p))
    Bytes.marshal!(w, p.h)
    write_tarray!(w, p.binentries)
    writebe!(w, p.errormode)
    writebe!(w, p.zmin)
    writebe!(w, p.zmax)
    writebe!(w, p.tsumwz)
    writebe!(w, p.tsumwz2)
    write_tarray!(w, p.binsumw2)
    set_header!(w, hdr)
    return w
end

# ---------------------------------------------------------------------------
# The interface every histogram shares.

"Any one-dimensional histogram."
const AnyTH1 = Union{TH1,TH1C,TH1S,TH1I,TH1L,TH1F,TH1D,TProfile}

"Any two-dimensional histogram."
const AnyTH2 = Union{TH2,TH2C,TH2S,TH2I,TH2L,TH2F,TH2D,TProfile2D}

"Any three-dimensional histogram."
const AnyTH3 = Union{TH3,TH3C,TH3S,TH3I,TH3L,TH3F,TH3D}

"Any histogram this package reads."
const AnyHist = Union{AnyTH1,AnyTH2,AnyTH3}

"""
    histcore(h) -> TH1

The `TH1` part of any histogram: its axes, its statistics and its name.

Every histogram class derives from `TH1` however many dimensions it has, so
this is where the members they share are actually kept.
"""
histcore(h::TH1) = h
histcore(h::AnyHist) = histcore(h.h)

name(h::AnyHist) = name(histcore(h).named)
title(h::AnyHist) = title(histcore(h).named)

"How many entries were filled into the histogram."
entries(h::AnyHist) = histcore(h).entries

"""
    axis(h, which=:x) -> TAxis

One of the histogram's axes, named `:x`, `:y` or `:z`.
"""
function axis(h::AnyHist, which::Symbol=:x)
    c = histcore(h)
    which === :x && return c.xaxis
    which === :y && return c.yaxis
    which === :z && return c.zaxis
    return throw(
        ArgumentError("TTree: a histogram has axes :x, :y and :z, not $(repr(which))")
    )
end

nbins(h::AnyHist, which::Symbol=:x) = nbins(axis(h, which))
binedges(h::AnyHist, which::Symbol=:x) = binedges(axis(h, which))
bincenters(h::AnyHist, which::Symbol=:x) = bincenters(axis(h, which))
binlabels(h::AnyHist, which::Symbol=:x) = binlabels(axis(h, which))

"""
    bincontents(h) -> Array

The cell contents, shaped like the histogram.

ROOT keeps the underflow and overflow bins in the same array as the rest, one
of each per axis, and so does this: a histogram of `n` bins gives `n + 2`
values, the first being everything that fell below the axis and the last
everything above. The array shares its memory with the histogram, so writing
into it changes the histogram.

`TH1` itself has no cells — only the concrete classes that add a `TArray` base
do — so this is an error on one.
"""
bincontents(h::AnyHist) = _shape(h, _cells(h))

# `TH1`, `TH2` and `TH3` are where the axes and the statistics live; the cells
# are added by the concrete classes below them, so asking one of the three for
# its contents is a mistake rather than an empty answer.
function _nocells(cls)
    return throw(
        ArgumentError(
            "TTree: $cls holds no cell contents; only its subclasses, such as $(cls)F, do"
        ),
    )
end

_cells(::TH1) = _nocells("TH1")
_cells(::TH2) = _nocells("TH2")
_cells(::TH3) = _nocells("TH3")
_cells(p::TProfile) = _cells(p.h)
_cells(p::TProfile2D) = _cells(p.h)

_shape(h::AnyTH1, v) = v

function _shape(h::AnyTH2, v)
    nx, ny = nbins(h, :x) + 2, nbins(h, :y) + 2
    length(v) == nx * ny || _badshape(h, length(v), (nx, ny))
    return reshape(v, nx, ny)
end

function _shape(h::AnyTH3, v)
    nx, ny, nz = nbins(h, :x) + 2, nbins(h, :y) + 2, nbins(h, :z) + 2
    length(v) == nx * ny * nz || _badshape(h, length(v), (nx, ny, nz))
    return reshape(v, nx, ny, nz)
end

function _badshape(h, got, want)
    return throw(
        ArgumentError(
            "TTree: histogram $(repr(name(h))) holds $got cells, but its axes call for $(join(want, "×")) = $(prod(want))",
        ),
    )
end

"""
    binerrors(h) -> Array{Float64}

The uncertainty on every cell, shaped like [`bincontents`](@ref).

A histogram that tracks the sum of squared weights reports the root of it;
one that does not is taken to have been filled with unit weights, so the error
is the root of the count — which is what ROOT's `GetBinError` returns in each
case.
"""
function binerrors(h::AnyHist)
    c = histcore(h)
    v = _cells(h)
    e = if isempty(c.sumw2)
        Float64[sqrt(abs(Float64(x))) for x in v]
    else
        length(c.sumw2) == length(v) || throw(
            ArgumentError(
                "TTree: histogram $(repr(name(h))) has $(length(c.sumw2)) squared weights for $(length(v)) cells",
            ),
        )
        Float64[sqrt(x) for x in c.sumw2]
    end
    return _shape(h, e)
end

# ---------------------------------------------------------------------------
# Profiles, where a bin is a mean rather than a count.
#
# A profile stores three numbers per bin — the sum of the weights, the sum of
# `w*y` and the sum of `w*y²` — in the same three arrays a histogram uses for
# one. So its cell array is not its contents, and reporting it as such would
# give a bin that was filled with 10 and 12 a content of 22. ROOT resolves this
# in `GetBinContent`, which divides; the methods below do the same, which is why
# a profile is the one histogram whose contents are computed rather than shared.

"Any histogram whose bins hold a mean."
const AnyProfile = Union{TProfile,TProfile2D}

"""
    ERRORMEAN, ERRORSPREAD, ERRORSPREADI, ERRORSPREADG

ROOT's `EErrorType`: what a profile's `errormode` means. See
[`binerrors`](@ref).
"""
const ERRORMEAN = Int32(0)
const ERRORSPREAD = Int32(1)
const ERRORSPREADI = Int32(2)
const ERRORSPREADG = Int32(3)

"""
    binentries(p) -> Array{Float64}

The sum of the weights that went into each bin of a profile, shaped like
[`bincontents`](@ref). ROOT's `GetBinEntries`.
"""
binentries(p::AnyProfile) = _shape(p, p.binentries)

"""
    bineffentries(p) -> Array{Float64}

The effective number of entries per bin — `(Σw)² / Σw²`, which is `Σw` when the
fills were unweighted. ROOT's `GetBinEffectiveEntries`.

A profile written before ROOT tracked `fBinSumw2`, or one filled with unit
weights, carries no squared weights at all; ROOT then takes the sum of the
weights itself, and so does this.
"""
function bineffentries(p::AnyProfile)
    n = p.binentries
    w2 = p.binsumw2
    length(w2) == length(n) || return _shape(p, copy(n))
    return _shape(p, Float64[w2[i] > 0 ? n[i]^2 / w2[i] : 0.0 for i in eachindex(n)])
end

bincontents(p::AnyProfile) = _shape(p, _profile_contents(p))

function _profile_contents(p::AnyProfile)
    sums = _cells(p)
    n = p.binentries
    length(n) == length(sums) || _badentries(p, length(n), length(sums))
    return Float64[n[i] == 0 ? 0.0 : sums[i] / n[i] for i in eachindex(sums)]
end

"""
    binerrors(p::AnyProfile) -> Array{Float64}

The uncertainty on each bin's mean, by whichever of ROOT's four error modes the
profile was given.

The default is the error on the mean, `σ/√neff`. `kERRORSPREAD` reports the
spread `σ` itself, `kERRORSPREADI` the error on the mean but with a bin whose
entries were all equal treated as an integer quantity, and `kERRORSPREADG` the
`1/√Σw` that holds when the fills were `1/σ²`-weighted Gaussians.

ROOT has a fifth behaviour, `TProfile::Approximate`, which fills a bin with no
spread of its own from the whole histogram's. It is off by default and is not
implemented here; a bin with no spread reports zero.
"""
function binerrors(p::AnyProfile)
    sums = _cells(p)
    n = p.binentries
    w2 = histcore(p).sumw2
    length(n) == length(sums) || _badentries(p, length(n), length(sums))
    e = Vector{Float64}(undef, length(sums))
    for i in eachindex(sums)
        e[i] = _profile_error(p, Float64(sums[i]), n[i], i <= length(w2) ? w2[i] : 0.0, i)
    end
    return _shape(p, e)
end

function _profile_error(p::AnyProfile, cont::Float64, sumw::Float64, sumw2::Float64, i::Int)
    sumw == 0 && return 0.0
    # The weights are 1/σ², so the error on their mean is fixed by them alone
    # and the spread of the y values does not come into it.
    p.errormode == ERRORSPREADG && return 1 / sqrt(sumw)

    mean = cont / sumw
    # `abs` because the two terms are of the same size when the spread is zero,
    # and rounding can leave the difference just below it.
    spread = sqrt(abs(sumw2 / sumw - mean * mean))
    p.errormode == ERRORSPREAD && return spread

    w2 = p.binsumw2
    neff = if length(w2) == length(p.binentries)
        w2[i] > 0 ? sumw * sumw / w2[i] : 0.0
    else
        sumw
    end
    neff <= 0 && return 0.0
    if p.errormode == ERRORSPREADI && spread == 0
        # Every entry in the bin was the same, which for an integer quantity
        # means the mean is uniform over a unit interval rather than exact.
        return 1 / sqrt(12 * neff)
    end
    return spread / sqrt(neff)
end

function _badentries(p, got, want)
    return throw(
        ArgumentError(
            "TTree: profile $(repr(name(p))) has $got bin entry counts for $want cells"
        ),
    )
end

"""
    sumw2!(h) -> h

Start tracking the sum of squared weights, so that [`binerrors`](@ref) reports
weighted uncertainties. ROOT's `TH1::Sumw2`.

The existing contents are taken to have been filled with unit weights, which is
what ROOT assumes when `Sumw2` is called on a histogram that has already been
filled.
"""
function sumw2!(h::AnyHist)
    c = histcore(h)
    v = _cells(h)
    c.sumw2 = Float64[abs(Float64(x)) for x in v]
    return h
end

function Base.show(io::IO, h::AnyHist)
    print(io, Bytes.classname(h), "(", repr(name(h)), ", ")
    print(io, nbins(h, :x))
    h isa AnyTH1 || print(io, "×", nbins(h, :y))
    h isa AnyTH3 && print(io, "×", nbins(h, :z))
    print(io, " bins, ", entries(h), " entries)")
    return nothing
end

# ---------------------------------------------------------------------------
# Building and filling.

"""
    _setup!(h, axes...) -> h

Give a freshly constructed histogram its axes and a zeroed cell for each,
including the underflow and overflow ROOT keeps alongside them.
"""
function _setup!(h::AnyHist, axes::TAxis...)
    c = histcore(h)
    n = 1
    for (i, a) in enumerate(axes)
        if i == 1
            a.named.name = "xaxis"
            c.xaxis = a
        elseif i == 2
            a.named.name = "yaxis"
            c.yaxis = a
        else
            a.named.name = "zaxis"
            c.zaxis = a
        end
        n *= nbins(a) + 2
    end
    # Only the axes the histogram actually uses count: a 1-D histogram has
    # `nbins + 2` cells, and the y and z axes it leaves empty add nothing.
    c.ncells = Int32(n)
    v = _cells(h)
    resize!(v, n)
    fill!(v, 0)
    return h
end

for cls in (:TH1C, :TH1S, :TH1I, :TH1L, :TH1F, :TH1D)
    @eval begin
        """
            $($(String(cls)))(name, title, nbins, xmin, xmax)
            $($(String(cls)))(name, title, edges::AbstractVector)

        A histogram with the given binning and every cell zero.
        """
        function $cls(
            name::AbstractString, title::AbstractString, n::Integer, xmin::Real, xmax::Real
        )
            return _setup!($cls(name, title), TAxis(n, xmin, xmax))
        end

        function $cls(
            name::AbstractString, title::AbstractString, edges::AbstractVector{<:Real}
        )
            return _setup!($cls(name, title), TAxis(edges))
        end
    end
end

for cls in (:TH2C, :TH2S, :TH2I, :TH2L, :TH2F, :TH2D)
    @eval begin
        """
            $($(String(cls)))(name, title, nx, xmin, xmax, ny, ymin, ymax)

        A two-dimensional histogram with the given binning and every cell zero.
        """
        function $cls(
            name::AbstractString,
            title::AbstractString,
            nx::Integer,
            xmin::Real,
            xmax::Real,
            ny::Integer,
            ymin::Real,
            ymax::Real,
        )
            return _setup!($cls(name, title), TAxis(nx, xmin, xmax), TAxis(ny, ymin, ymax))
        end
    end
end

"""
    findbin(h, x) -> Int
    findbin(h, x, y) -> Int
    findbin(h, x, y, z) -> Int

The index into [`bincontents`](@ref) — counted from one, so the underflow bin is
`1` — of the cell a point falls in.
"""
findbin(h::AnyTH1, x::Real) = findbin(axis(h, :x), x) + 1

function findbin(h::AnyTH2, x::Real, y::Real)
    nx = nbins(h, :x) + 2
    return findbin(axis(h, :x), x) + nx * findbin(axis(h, :y), y) + 1
end

function findbin(h::AnyTH3, x::Real, y::Real, z::Real)
    nx, ny = nbins(h, :x) + 2, nbins(h, :y) + 2
    bx = findbin(axis(h, :x), x)
    by = findbin(axis(h, :y), y)
    bz = findbin(axis(h, :z), z)
    return bx + nx * (by + ny * bz) + 1
end

"""
    push!(h, x[, w])
    push!(h::AnyTH2, x, y[, w])

Add one entry, optionally weighted — ROOT's `Fill`.

The running sums that give the mean and the RMS are updated the way ROOT
updates them, which means an entry landing in the underflow or overflow bin is
counted but left out of the statistics.
"""
function Base.push!(h::AnyTH1, x::Real, w::Real=1)
    c = histcore(h)
    b = findbin(h, x)
    _addcell!(h, b, w)
    c.entries += 1
    if 1 < b < length(_cells(h))
        c.tsumw += w
        c.tsumw2 += w * w
        c.tsumwx += w * x
        c.tsumwx2 += w * x * x
    end
    return h
end

function Base.push!(h::AnyTH2, x::Real, y::Real, w::Real=1)
    c = histcore(h)
    b = findbin(h, x, y)
    _addcell!(h, b, w)
    c.entries += 1
    bx, by = findbin(axis(h, :x), x), findbin(axis(h, :y), y)
    if 0 < bx <= nbins(h, :x) && 0 < by <= nbins(h, :y)
        c.tsumw += w
        c.tsumw2 += w * w
        c.tsumwx += w * x
        c.tsumwx2 += w * x * x
        h2 = _h2core(h)
        h2.tsumwy += w * y
        h2.tsumwy2 += w * y * y
        h2.tsumwxy += w * x * y
    end
    return h
end

# One method per class rather than one over `AnyTH2`, because `TH2` holds a
# `TH1` in the same `h` field its subclasses hold a `TH2` in. Dispatch would
# never take a `TH2` down the general path, but nothing about the general path
# says so — and a method that can only be read as correct by knowing which
# calls reach it is one an analyser is right to complain about.
_h2core(h::TH2) = h
_h2core(h::Union{TH2C,TH2S,TH2I,TH2L,TH2F,TH2D}) = h.h
_h2core(p::TProfile2D) = _h2core(p.h)

function _addcell!(h::AnyHist, b::Integer, w::Real)
    v = _cells(h)
    v[b] += w
    c = histcore(h)
    isempty(c.sumw2) || (c.sumw2[b] += w * w)
    return nothing
end
