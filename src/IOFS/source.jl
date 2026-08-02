# Where a ROOT file's bytes come from, and where they go.
#
# ROOT access is random access: opening a file touches the header, the root
# directory record, the streamer info and the key list, all at scattered
# offsets, and reading a tree then jumps between baskets. Everything above this
# file is written against `pread!` alone, so a local file, an mmap, an in-memory
# buffer and a remote XRootD file are interchangeable.

"""
    AbstractSource

A random-access, read-only byte source. Implementations provide
[`pread!`](@ref) and `Base.length`; everything else has a default.
"""
abstract type AbstractSource end

"""
    pread!(src::AbstractSource, buf::Vector{UInt8}, offset::Integer) -> buf

Fill `buf` with `length(buf)` bytes starting at the zero-based `offset`.

Short reads are an error, not a partial result: every caller in this package
knows exactly how many bytes the format says are there, so a source that
returns fewer has hit a truncated file or a failed transfer, and continuing
would decode adjacent data as though it were the object asked for.
"""
function pread! end

"""
    read_at(src::AbstractSource, offset::Integer, n::Integer) -> AbstractVector{UInt8}

`n` bytes at `offset`, without copying when the source is memory-backed.

The result may alias the source and must be treated as read-only. Callers that
retain the bytes — as opposed to decompressing or decoding them immediately —
should `collect` the result.
"""
function read_at(src::AbstractSource, offset::Integer, n::Integer)
    return pread!(src, Vector{UInt8}(undef, Int(n)), offset)
end

"""
    AbstractSink

A random-access byte sink. Implementations provide [`pwrite!`](@ref).
"""
abstract type AbstractSink end

"""
    pwrite!(sink::AbstractSink, buf::AbstractVector{UInt8}, offset::Integer) -> Int

Write `buf` at the zero-based `offset`, returning the byte count.

ROOT files are written out of order — a key's payload goes down before the
header that describes it, and the file header is rewritten last — so a sink
must support positioned writes rather than a stream of appends.
"""
function pwrite! end

# ---------------------------------------------------------------------------
# In-memory

"""
    MemorySource(data::Vector{UInt8})

A source over a byte vector. Used for round-trip tests and for files small
enough to have been fetched whole.
"""
struct MemorySource <: AbstractSource
    data::Vector{UInt8}
end

Base.length(s::MemorySource) = length(s.data)
Base.close(::MemorySource) = nothing

function pread!(s::MemorySource, buf::Vector{UInt8}, offset::Integer)
    off = Int(offset)
    n = length(buf)
    _check_range(off, n, length(s.data))
    copyto!(buf, 1, s.data, off + 1, n)
    return buf
end

function read_at(s::MemorySource, offset::Integer, n::Integer)
    return (
        _check_range(Int(offset), Int(n), length(s.data));
        @view s.data[(Int(offset) + 1):(Int(offset) + Int(n))]
    )
end

"""
    MemorySink()

A sink that accumulates into a byte vector, growing to accommodate positioned
writes past its current end.
"""
struct MemorySink <: AbstractSink
    data::Vector{UInt8}
end

MemorySink() = MemorySink(UInt8[])

function pwrite!(sink::MemorySink, buf::AbstractVector{UInt8}, offset::Integer)
    off = Int(offset)
    need = off + length(buf)
    if need > length(sink.data)
        old = length(sink.data)
        resize!(sink.data, need)
        # Positioned writes can leave gaps — the space a key will occupy is
        # reserved before its payload is known. Zero them so the result does
        # not depend on whatever the allocator handed back.
        fill!(@view(sink.data[(old + 1):need]), 0x00)
    end
    copyto!(sink.data, off + 1, buf, firstindex(buf), length(buf))
    return length(buf)
end

Base.close(::MemorySink) = nothing
Base.length(s::MemorySink) = length(s.data)

# ---------------------------------------------------------------------------
# Local files

"""
    MmapSource(path)

A source over a memory-mapped local file — the fastest way to read one, and
the only source for which [`read_at`](@ref) never copies.
"""
struct MmapSource <: AbstractSource
    path::String
    io::IOStream
    data::Vector{UInt8}
end

function MmapSource(path::AbstractString)
    io = Base.open(path, "r")
    data = Mmap.mmap(io, Vector{UInt8})
    return MmapSource(String(path), io, data)
end

Base.length(s::MmapSource) = length(s.data)
Base.close(s::MmapSource) = close(s.io)

function pread!(s::MmapSource, buf::Vector{UInt8}, offset::Integer)
    off = Int(offset)
    n = length(buf)
    _check_range(off, n, length(s.data))
    copyto!(buf, 1, s.data, off + 1, n)
    return buf
end

function read_at(s::MmapSource, offset::Integer, n::Integer)
    return (
        _check_range(Int(offset), Int(n), length(s.data));
        @view s.data[(Int(offset) + 1):(Int(offset) + Int(n))]
    )
end

"""
    IOSource(io::IO)

A source over any seekable `IO`. Slower than [`MmapSource`](@ref) but works for
streams that cannot be mapped, and for `IOBuffer`s in tests.

Access is serialised on a lock: `seek` and `read` are two operations on shared
state, and this package reads baskets from several tasks at once.
"""
struct IOSource <: AbstractSource
    io::IO
    size::Int64
    lock::ReentrantLock
end

function IOSource(io::IO)
    seekend(io)
    n = position(io)
    seekstart(io)
    return IOSource(io, Int64(n), ReentrantLock())
end

Base.length(s::IOSource) = Int(s.size)
Base.close(s::IOSource) = close(s.io)

function pread!(s::IOSource, buf::Vector{UInt8}, offset::Integer)
    off = Int(offset)
    n = length(buf)
    _check_range(off, n, Int(s.size))
    @lock s.lock begin
        seek(s.io, off)
        readbytes!(s.io, buf, n) == n || throw(EOFError())
    end
    return buf
end

"""
    FileSink(path)

A sink over a local file opened for positioned writes.
"""
struct FileSink <: AbstractSink
    path::String
    io::IOStream
    lock::ReentrantLock
end

function FileSink(path::AbstractString)
    return FileSink(String(path), Base.open(path, "w+"), ReentrantLock())
end

function pwrite!(sink::FileSink, buf::AbstractVector{UInt8}, offset::Integer)
    @lock sink.lock begin
        seek(sink.io, Int(offset))
        write(sink.io, buf)
    end
    return length(buf)
end

Base.close(s::FileSink) = close(s.io)

# ---------------------------------------------------------------------------
# Remote

"""
    XRootDSource(url; kwargs...)

A source over a remote file held open across reads.

Reading a tree means thousands of small positioned reads, so the `XrdCl.File`
is opened once and reused. Going through `XRootD.Storage` instead would reopen
the file — and re-authenticate — on every basket.

Keyword arguments are passed to `XrdCl.File`, which is where credentials go.
"""
mutable struct XRootDSource <: AbstractSource
    url::String
    file::XrdCl.File
    size::Int64
end

function XRootDSource(url::AbstractString; kwargs...)
    f = XrdCl.File(String(url), XrdCl.OpenFlags.Read; kwargs...)
    f === nothing && throw(ArgumentError("TTree: could not open $(url)"))
    st, info = XrdCl.stat(f)
    XrdCl.isOK(st) || throw(ArgumentError("TTree: could not stat $(url): $(st)"))
    return XRootDSource(String(url), f, Int64(info.size))
end

Base.length(s::XRootDSource) = Int(s.size)
Base.close(s::XRootDSource) = (XrdCl.close(s.file); nothing)

function pread!(s::XRootDSource, buf::Vector{UInt8}, offset::Integer)
    off = Int64(offset)
    want = length(buf)
    _check_range(Int(off), want, Int(s.size))
    got = 0
    while got < want
        st, n = GC.@preserve buf XrdCl.unsafe_read(
            s.file, pointer(buf, got + 1), want - got, off + got
        )
        XrdCl.isOK(st) || throw(
            IOError("TTree: read of $(want - got) bytes at $(off + got) failed: $(st)")
        )
        # A server may satisfy a read short; only zero bytes means it will not
        # make progress, and looping on that would spin forever.
        n == 0 && throw(EOFError())
        got += n
    end
    return buf
end

"""
    XRootDSink(url; kwargs...)

A sink over a remote file opened for writing, held open across writes for the
same reason [`XRootDSource`](@ref) holds its file open.
"""
mutable struct XRootDSink <: AbstractSink
    url::String
    file::XrdCl.File
end

function XRootDSink(url::AbstractString; kwargs...)
    flags = XrdCl.OpenFlags.Update | XrdCl.OpenFlags.New | XrdCl.OpenFlags.MakePath
    f = XrdCl.File(String(url), flags; kwargs...)
    f === nothing && throw(ArgumentError("TTree: could not create $(url)"))
    return XRootDSink(String(url), f)
end

function pwrite!(sink::XRootDSink, buf::AbstractVector{UInt8}, offset::Integer)
    data = buf isa Vector{UInt8} ? buf : collect(buf)
    st, _ = XrdCl.write(sink.file, data, length(data), Int64(offset))
    XrdCl.isOK(st) ||
        throw(IOError("TTree: write of $(length(data)) bytes at $offset failed: $(st)"))
    return length(data)
end

Base.close(s::XRootDSink) = (XrdCl.close(s.file); nothing)

"""
    StorageSource(url; kwargs...)

A source over any scheme `XRootD.Storage` understands that is not `root://` —
`http(s)://`, `dav(s)://`, `s3(s)://`. Each read is an independent ranged
request, which suits HTTP and S3 but is why `root://` gets a dedicated source.
"""
struct StorageSource <: AbstractSource
    url::String
    backend::Any
    size::Int64
end

function StorageSource(url::AbstractString; kwargs...)
    b = Storage.storage_for(String(url); kwargs...)
    info = Storage.storage_stat(b)
    info === nothing && throw(ArgumentError("TTree: could not stat $(url)"))
    return StorageSource(String(url), b, Int64(info.size))
end

Base.length(s::StorageSource) = Int(s.size)
Base.close(::StorageSource) = nothing

function pread!(s::StorageSource, buf::Vector{UInt8}, offset::Integer)
    n = length(buf)
    _check_range(Int(offset), n, Int(s.size))
    io = IOBuffer(; sizehint=n)
    res = Storage.storage_read(s.backend, io; offset=Int(offset), length=n)
    res === :ok ||
        throw(IOError("TTree: ranged read of $n bytes at $offset from $(s.url) failed"))
    data = take!(io)
    length(data) == n || throw(EOFError())
    copyto!(buf, 1, data, 1, n)
    return buf
end

# ---------------------------------------------------------------------------

"""
    open_source(target; kwargs...) -> AbstractSource

Open `target` for reading, choosing a source by what it is: an existing
`AbstractSource` is returned unchanged, a byte vector becomes a
[`MemorySource`](@ref), an `IO` an [`IOSource`](@ref), a `root://` URL an
[`XRootDSource`](@ref), any other URL a [`StorageSource`](@ref), and a plain
path an [`MmapSource`](@ref).
"""
open_source(src::AbstractSource; kwargs...) = src
open_source(data::Vector{UInt8}; kwargs...) = MemorySource(data)
open_source(io::IO; kwargs...) = IOSource(io)

function open_source(target::AbstractString; kwargs...)
    scheme = _scheme(target)
    scheme === nothing && return MmapSource(target)
    (scheme == "root" || scheme == "roots") && return XRootDSource(target; kwargs...)
    scheme == "file" && return MmapSource(_file_path(target))
    return StorageSource(target; kwargs...)
end

"""
    open_sink(target; kwargs...) -> AbstractSink

Open `target` for writing, by the same scheme dispatch as
[`open_source`](@ref).
"""
open_sink(sink::AbstractSink; kwargs...) = sink

function open_sink(target::AbstractString; kwargs...)
    scheme = _scheme(target)
    scheme === nothing && return FileSink(target)
    (scheme == "root" || scheme == "roots") && return XRootDSink(target; kwargs...)
    scheme == "file" && return FileSink(_file_path(target))
    return throw(ArgumentError("TTree: writing to $(scheme):// is not supported"))
end

"Scheme of `s`, or `nothing` when it is a plain path. A Windows drive letter is not a scheme."
function _scheme(s::AbstractString)
    i = findfirst("://", s)
    i === nothing && return nothing
    return lowercase(s[1:(first(i) - 1)])
end

_file_path(url::AbstractString) = url[(first(findfirst("://", url)) + 2):end]

function _check_range(offset::Int, n::Int, total::Int)
    (offset >= 0 && n >= 0 && offset + n <= total) || throw(
        BoundsError(
            "TTree: request for $n bytes at offset $offset lies outside a $total-byte source",
        ),
    )
    return nothing
end

"Raised when a source or sink fails for a reason the format layer cannot act on."
struct IOError <: Exception
    msg::String
end

Base.showerror(io::IO, e::IOError) = print(io, e.msg)
