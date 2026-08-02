# ROOT's graphs: a list of points, and optionally the uncertainty on each.
#
# Where a histogram bins its entries and keeps only the counts, a graph keeps
# every point it was given. The three classes here differ only in how much they
# say about the error on a point: none, one number per axis, or one on each
# side of it.
#
# `fX` and `fY` are `//[fNpoints]` members — a count followed by that many
# values, the same encoding a variable-length branch uses — so they are read
# with `read_pointer_array` and the count member has to arrive first, which the
# description guarantees it does.

"""
    TGraph

A set of `(x, y)` points, drawn as a curve or a scatter.

`histogram` is the invisible `TH1F` ROOT builds to draw the axes and is usually
`nothing` in a file written for data rather than for a picture; `functions`
holds any fits made to the graph.
"""
mutable struct TGraph <: ROOTObject
    named::TNamed
    attline::TAttLine
    attfill::TAttFill
    attmarker::TAttMarker
    x::Vector{Float64}
    y::Vector{Float64}
    functions::Any
    histogram::Any
    minimum::Float64
    maximum::Float64
    option::String
end

function TGraph(name::AbstractString="", title::AbstractString="")
    return TGraph(
        TNamed(name, title),
        TAttLine(),
        TAttFill(),
        TAttMarker(),
        Float64[],
        Float64[],
        nothing,
        nothing,
        -1111.0,
        -1111.0,
        "",
    )
end

"""
    TGraph(name, title, x, y)

A graph of the given points. `x` and `y` must be the same length.
"""
function TGraph(
    name::AbstractString,
    title::AbstractString,
    x::AbstractVector{<:Real},
    y::AbstractVector{<:Real},
)
    g = TGraph(name, title)
    _setpoints!(g, x, y)
    return g
end

Bytes.classname(::TGraph) = "TGraph"
rversion(::TGraph) = Int16(5)

function Bytes.unmarshal!(g::TGraph, r::RBuffer)
    hdr = read_header(r, "TGraph")
    npoints = 0
    for e in layout(r, "TGraph", hdr.vers)
        m = name(e)
        if m == "TNamed"
            Bytes.unmarshal!(g.named, r)
        elseif m == "TAttLine"
            Bytes.unmarshal!(g.attline, r)
        elseif m == "TAttFill"
            Bytes.unmarshal!(g.attfill, r)
        elseif m == "TAttMarker"
            Bytes.unmarshal!(g.attmarker, r)
        elseif m == "fNpoints"
            npoints = Int(read_scalar(r, e))
        elseif m == "fX"
            g.x = read_pointer_array(r, e, npoints, Float64)
        elseif m == "fY"
            g.y = read_pointer_array(r, e, npoints, Float64)
        elseif m == "fFunctions"
            g.functions = read_object_member(r, e, TList)
        elseif m == "fHistogram"
            g.histogram = read_object_member(r, e, TH1F)
        elseif m == "fMinimum"
            g.minimum = read_real(r, e)
        elseif m == "fMaximum"
            g.maximum = read_real(r, e)
        elseif m == "fOption"
            g.option = read_tstring(r)
        else
            unknown_member("TGraph", hdr.vers, m)
        end
    end
    check_header(r, hdr)
    return g
end

function Bytes.marshal!(w::WBuffer, g::TGraph)
    hdr = write_header!(w, "TGraph", rversion(g))
    Bytes.marshal!(w, g.named)
    Bytes.marshal!(w, g.attline)
    Bytes.marshal!(w, g.attfill)
    Bytes.marshal!(w, g.attmarker)
    writebe!(w, Int32(length(g.x)))
    write_pointer_array!(w, g.x)
    write_pointer_array!(w, g.y)
    write_object_any!(w, g.functions)
    write_object_any!(w, g.histogram)
    writebe!(w, g.minimum)
    writebe!(w, g.maximum)
    write_tstring!(w, g.option)
    set_header!(w, hdr)
    return w
end

"""
    TGraphErrors

A [`TGraph`](@ref) with one uncertainty per axis per point, the same on both
sides of it.
"""
mutable struct TGraphErrors <: ROOTObject
    g::TGraph
    ex::Vector{Float64}
    ey::Vector{Float64}
end

function TGraphErrors(name::AbstractString="", title::AbstractString="")
    return TGraphErrors(TGraph(name, title), Float64[], Float64[])
end

Bytes.classname(::TGraphErrors) = "TGraphErrors"
rversion(::TGraphErrors) = Int16(3)

function Bytes.unmarshal!(x::TGraphErrors, r::RBuffer)
    hdr = read_header(r, "TGraphErrors")
    for e in layout(r, "TGraphErrors", hdr.vers)
        m = name(e)
        if m == "TGraph"
            Bytes.unmarshal!(x.g, r)
        elseif m == "fEX"
            x.ex = read_pointer_array(r, e, length(x.g.x), Float64)
        elseif m == "fEY"
            x.ey = read_pointer_array(r, e, length(x.g.x), Float64)
        else
            unknown_member("TGraphErrors", hdr.vers, m)
        end
    end
    check_header(r, hdr)
    return x
end

function Bytes.marshal!(w::WBuffer, x::TGraphErrors)
    hdr = write_header!(w, "TGraphErrors", rversion(x))
    Bytes.marshal!(w, x.g)
    write_pointer_array!(w, x.ex)
    write_pointer_array!(w, x.ey)
    set_header!(w, hdr)
    return w
end

"""
    TGraphAsymmErrors

A [`TGraph`](@ref) with an uncertainty on each side of each point, so four
arrays rather than two.
"""
mutable struct TGraphAsymmErrors <: ROOTObject
    g::TGraph
    exlow::Vector{Float64}
    exhigh::Vector{Float64}
    eylow::Vector{Float64}
    eyhigh::Vector{Float64}
end

function TGraphAsymmErrors(name::AbstractString="", title::AbstractString="")
    return TGraphAsymmErrors(
        TGraph(name, title), Float64[], Float64[], Float64[], Float64[]
    )
end

Bytes.classname(::TGraphAsymmErrors) = "TGraphAsymmErrors"
rversion(::TGraphAsymmErrors) = Int16(3)

function Bytes.unmarshal!(x::TGraphAsymmErrors, r::RBuffer)
    hdr = read_header(r, "TGraphAsymmErrors")
    for e in layout(r, "TGraphAsymmErrors", hdr.vers)
        m = name(e)
        n = length(x.g.x)
        if m == "TGraph"
            Bytes.unmarshal!(x.g, r)
        elseif m == "fEXlow"
            x.exlow = read_pointer_array(r, e, n, Float64)
        elseif m == "fEXhigh"
            x.exhigh = read_pointer_array(r, e, n, Float64)
        elseif m == "fEYlow"
            x.eylow = read_pointer_array(r, e, n, Float64)
        elseif m == "fEYhigh"
            x.eyhigh = read_pointer_array(r, e, n, Float64)
        else
            unknown_member("TGraphAsymmErrors", hdr.vers, m)
        end
    end
    check_header(r, hdr)
    return x
end

function Bytes.marshal!(w::WBuffer, x::TGraphAsymmErrors)
    hdr = write_header!(w, "TGraphAsymmErrors", rversion(x))
    Bytes.marshal!(w, x.g)
    write_pointer_array!(w, x.exlow)
    write_pointer_array!(w, x.exhigh)
    write_pointer_array!(w, x.eylow)
    write_pointer_array!(w, x.eyhigh)
    set_header!(w, hdr)
    return w
end

"Any graph this package reads."
const AnyGraph = Union{TGraph,TGraphErrors,TGraphAsymmErrors}

"""
    graphcore(g) -> TGraph

The `TGraph` part of any graph: its points, its name and its drawing style.
"""
graphcore(g::TGraph) = g
graphcore(g::AnyGraph) = g.g

name(g::AnyGraph) = name(graphcore(g).named)
title(g::AnyGraph) = title(graphcore(g).named)

Base.length(g::AnyGraph) = length(graphcore(g).x)
Base.isempty(g::AnyGraph) = isempty(graphcore(g).x)

"""
    points(g) -> (x, y)

The graph's points, as two vectors of the same length.
"""
points(g::AnyGraph) = (graphcore(g).x, graphcore(g).y)

"""
    xerrors(g) -> (low, high)
    yerrors(g) -> (low, high)

The uncertainty on either side of every point.

The same pair of vectors comes back whatever the class, so code that plots a
graph need not ask which one it has: a `TGraphErrors` reports its one error on
both sides, and a plain `TGraph` — which carries none — reports zeros.

Zeros rather than ROOT's answer: `TGraph::GetErrorX` returns `-1` for a class
that has no errors, as a sentinel for "there is nothing to draw". A width is
more useful than a sentinel here, and zero is that width.
"""
xerrors(g::TGraph) = (zeros(length(g.x)), zeros(length(g.x)))
xerrors(g::TGraphErrors) = (g.ex, g.ex)
xerrors(g::TGraphAsymmErrors) = (g.exlow, g.exhigh)

yerrors(g::TGraph) = (zeros(length(g.y)), zeros(length(g.y)))
yerrors(g::TGraphErrors) = (g.ey, g.ey)
yerrors(g::TGraphAsymmErrors) = (g.eylow, g.eyhigh)

function _setpoints!(g::TGraph, x::AbstractVector{<:Real}, y::AbstractVector{<:Real})
    length(x) == length(y) || throw(
        ArgumentError(
            "TTree: a graph needs as many y values as x, got $(length(x)) and $(length(y))",
        ),
    )
    g.x = Float64[Float64(v) for v in x]
    g.y = Float64[Float64(v) for v in y]
    return g
end

"""
    TGraphErrors(name, title, x, y, ex, ey)

A graph of the given points with symmetric errors on each.
"""
function TGraphErrors(
    name::AbstractString,
    title::AbstractString,
    x::AbstractVector{<:Real},
    y::AbstractVector{<:Real},
    ex::AbstractVector{<:Real},
    ey::AbstractVector{<:Real},
)
    g = TGraphErrors(name, title)
    _setpoints!(g.g, x, y)
    g.ex = _matching(ex, length(x), "ex")
    g.ey = _matching(ey, length(x), "ey")
    return g
end

"""
    TGraphAsymmErrors(name, title, x, y, exlow, exhigh, eylow, eyhigh)

A graph of the given points with an error on each side of each.
"""
function TGraphAsymmErrors(
    name::AbstractString,
    title::AbstractString,
    x::AbstractVector{<:Real},
    y::AbstractVector{<:Real},
    exlow::AbstractVector{<:Real},
    exhigh::AbstractVector{<:Real},
    eylow::AbstractVector{<:Real},
    eyhigh::AbstractVector{<:Real},
)
    g = TGraphAsymmErrors(name, title)
    _setpoints!(g.g, x, y)
    n = length(x)
    g.exlow = _matching(exlow, n, "exlow")
    g.exhigh = _matching(exhigh, n, "exhigh")
    g.eylow = _matching(eylow, n, "eylow")
    g.eyhigh = _matching(eyhigh, n, "eyhigh")
    return g
end

function _matching(v::AbstractVector{<:Real}, n::Integer, what::AbstractString)
    length(v) == n ||
        throw(ArgumentError("TTree: $what has $(length(v)) values for $n points"))
    return Float64[Float64(x) for x in v]
end

function Base.show(io::IO, g::AnyGraph)
    return print(io, Bytes.classname(g), "(", repr(name(g)), ", ", length(g), " points)")
end
