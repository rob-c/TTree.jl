"""
    TTree.Bytes

Layer 1: ROOT's serialization format as pure byte codecs, with no I/O of its
own.

Everything here operates on a `Vector{UInt8}` already in memory — a
decompressed key payload, a basket, a streamer record. Keeping the layer free
of file handles is what lets the same codecs serve local files, remote XRootD
reads, and in-memory round-trip tests without a seam between them.

The read and write sides ([`RBuffer`](@ref) / [`WBuffer`](@ref)) are written as
mirror images: each framing rule — byte counts, class tags, back-references,
string lengths — appears once in each, so an encoding bug shows up as an
asymmetry between two adjacent files rather than as a corrupt file.
"""
module Bytes

using Dates: Dates, DateTime

export RBuffer,
    WBuffer,
    Header,
    ROOTPrimitive,
    pos,
    seek!,
    skip!,
    remaining,
    readbe,
    writebe!,
    read_array,
    read_array!,
    write_array!,
    read_bytes,
    write_bytes!,
    read_tstring,
    write_tstring!,
    read_cstring,
    write_cstring!,
    read_stdstring,
    write_stdstring!,
    read_float16,
    write_float16!,
    read_double32,
    write_double32!,
    read_header,
    write_header!,
    check_header,
    set_header!,
    read_object_any,
    write_object_any!,
    unmarshal!,
    marshal!,
    classname,
    bytes,
    datime_to_datetime,
    datetime_to_datime

include("constants.jl")
include("datime.jl")
include("rbuffer.jl")
include("wbuffer.jl")

end # module Bytes
