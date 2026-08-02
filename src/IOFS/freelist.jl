# TFree: the list of gaps in a ROOT file.
#
# ROOT never truncates. Deleting an object turns its record into a gap, and the
# gaps are tracked in a linked list written as its own record near the end of
# the file. The list always ends with a segment running from the current end of
# file to `START_BIG_FILE`, which is what makes "allocate at the end" and
# "allocate from a gap" the same operation.

"""
    FreeSegment(first, last)

A gap in the file, inclusive of both bounds — so a segment of one byte has
`first == last`, and its length is `last - first + 1`.
"""
struct FreeSegment
    first::Int64
    last::Int64
end

Base.length(s::FreeSegment) = s.last - s.first + 1

"Bytes the record for this segment occupies; 64-bit bounds cost eight more."
segment_sizeof(s::FreeSegment) = s.last > START_BIG_FILE ? Int32(18) : Int32(10)

function read_free_segment(r::RBuffer)
    vers = readbe(r, Int16)
    if vers > 1000
        return FreeSegment(readbe(r, Int64), readbe(r, Int64))
    end
    return FreeSegment(Int64(readbe(r, Int32)), Int64(readbe(r, Int32)))
end

function write_free_segment!(w::WBuffer, s::FreeSegment)
    vers = s.last > START_BIG_FILE ? Int16(1001) : Int16(1)
    writebe!(w, vers)
    if vers > 1000
        writebe!(w, s.first)
        writebe!(w, s.last)
    else
        writebe!(w, Int32(s.first))
        writebe!(w, Int32(s.last))
    end
    return w
end

"""
    free_add!(spans, first, last) -> spans

Record `[first, last]` as free, coalescing with any segment it touches.

Merging matters for more than tidiness: the trailing segment is identified by
its `last` being [`START_BIG_FILE`](@ref), and a freed record adjacent to the
end of file must join that segment rather than sit beside it, or the file's
notion of where it ends stops being a single place.
"""
function free_add!(spans::Vector{FreeSegment}, first::Integer, last::Integer)
    push!(spans, FreeSegment(Int64(first), Int64(last)))
    sort!(spans; by=s -> (s.first, s.last))
    out = FreeSegment[]
    for s in spans
        if !isempty(out) && s.first <= out[end].last + 1
            out[end] = FreeSegment(out[end].first, max(out[end].last, s.last))
        else
            push!(out, s)
        end
    end
    resize!(spans, length(out))
    copyto!(spans, out)
    return spans
end

"""
    free_tail(spans) -> Union{FreeSegment,Nothing}

The segment that runs to the end of the addressable file — the one every
append comes out of.
"""
function free_tail(spans::Vector{FreeSegment})
    for s in spans
        s.last == START_BIG_FILE && return s
    end
    return nothing
end

"Total bytes recorded as free, excluding the open-ended trailing segment."
function free_bytes(spans::Vector{FreeSegment})
    n = Int64(0)
    for s in spans
        s.last == START_BIG_FILE || (n += length(s))
    end
    return n
end
