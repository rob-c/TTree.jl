# The class descriptions this package writes into a file.
#
# A ROOT file describes the classes it contains, so that a reader with no C++
# dictionary for them can still decode their bytes. A writer that omits the
# descriptions produces a file only a program that already knows the classes
# can read — which for ROOT's own classes happens to be ROOT, but is exactly
# the dependency the format exists to remove.
#
# The descriptions themselves are ROOT's, read out of a file ROOT wrote and
# emitted as Julia by `dev/gen_streamers.jl`; this file is the machinery around
# them.

"""
    _el(name, ename, etype, esize, title; arrlen=0, arrdim=0, maxidx=())

Build a [`StreamerElement`](@ref) from the fields the generator emits.

Only used by `streamers_gen.jl`, where the argument order is what keeps the
generated table readable.
"""
function _el(
    name::AbstractString,
    ename::AbstractString,
    etype::Integer,
    esize::Integer,
    title::AbstractString;
    arrlen::Integer=0,
    arrdim::Integer=0,
    maxidx=(),
)
    return StreamerElement(;
        name=name,
        title=title,
        etype=etype,
        esize=esize,
        arrlen=arrlen,
        arrdim=arrdim,
        maxidx=Int32[Int32(i) for i in maxidx],
        ename=ename,
    )
end

const BUILTIN_STREAMERS = Dict{String,Any}()

function _builtin_table()
    isempty(BUILTIN_STREAMERS) || return BUILTIN_STREAMERS
    for si in _builtin_streamers()
        BUILTIN_STREAMERS[Bytes.described_class(si)] = si
    end
    return BUILTIN_STREAMERS
end

"""
    streamer_info(class) -> Union{TStreamerInfo,Nothing}

This package's description of `class`, or `nothing` for a class it cannot
describe.

The descriptions are ROOT's own, so a file written with them is one ROOT reads
without falling back to its compiled dictionary — and one a reader that has no
dictionary at all, such as this package, can decode from the file alone.
"""
streamer_info(class::AbstractString) = get(_builtin_table(), String(class), nothing)

"""
    streamer_closure(class) -> Vector{Any}

`class`'s description together with those of every class it needs — its bases,
and the classes its members are — each listed before the class that uses it.

Writing a description on its own would leave the file self-describing only as
far as the first inherited or contained member, so the closure is what a writer
actually has to store. It is the same set ROOT's `ForceWriteInfo` produces,
which is why a `TObjString` written here brings `TString` with it just as one
written by ROOT does.
"""
function streamer_closure(class::AbstractString)
    out = Any[]
    seen = Set{String}()
    _closure!(out, seen, String(class))
    return out
end

function _closure!(out::Vector{Any}, seen::Set{String}, class::String)
    class in seen && return out
    push!(seen, class)
    si = streamer_info(class)
    si === nothing && return out
    for e in elements(si)
        _closure!(out, seen, _member_class(e))
    end
    push!(out, si)
    return out
end

"""
    _member_class(e) -> String

The class an element's type names.

A base class is named by the element itself, anything else by its C++ type with
the pointer decoration removed. No filtering by element kind is needed: a
member of a basic type yields a name the table has never heard of, which
the closure walk already treats as nothing to write.
"""
function _member_class(e)
    el = element(e)
    e isa TStreamerBase && return el.named.name
    t = el.ename
    startswith(t, "const ") && (t = t[(ncodeunits("const ") + 1):end])
    return String(rstrip(t, ['*', ' ']))
end

"""
    describable_classes() -> Vector{String}

Every class this package can describe in a file's streamer info.
"""
describable_classes() = sort!(collect(keys(_builtin_table())))
