# TFile: the outermost container.
#
# The first `FILE_BEGIN` bytes are the header — magic, version, and the offsets
# of everything the reader needs to find. Immediately after it sits the root
# directory's record, and after that a flat sequence of key records. Two of the
# header's offsets point at records written near the end: the streamer info,
# and the free-segment list.
#
# The header is written twice when creating a file: once up front so the file
# is well-formed while it is being built, and again on close once the trailing
# records exist and the final size is known.

"Offset of the first data record; the header occupies everything below it."
const FILE_BEGIN = 100

"ROOT release this package writes into file and class version fields."
const ROOT_VERSION = Int32(63602)

const ROOT_MAGIC = (UInt8('r'), UInt8('o'), UInt8('o'), UInt8('t'))

"""
    ROOTFile

An open ROOT file.

The same type serves reading and writing; `source` is set when the file can be
read and `sink` when it can be written, and a file created for writing has
both so that objects can be read back before it is closed.

`streamers` is parsed on first use rather than at open: a reader that only
wants a `TTree`'s numeric branches never needs the class dictionary, and
parsing it eagerly would make opening a file with hundreds of streamers
noticeably slower for no gain.
"""
mutable struct ROOTFile
    id::String
    source::Union{Nothing,AbstractSource}
    sink::Union{Nothing,AbstractSink}
    version::Int32
    fbegin::Int64
    fend::Int64
    seekfree::Int64
    nbytesfree::Int32
    nfree::Int32
    nbytesname::Int32
    units::UInt8
    compression::Int32
    seekinfo::Int64
    nbytesinfo::Int32
    uuid::UUID
    dir::Directory
    spans::Vector{FreeSegment}
    streamers::Any
    closed::Bool
end

"""
    OBJECT_FACTORY

Hook by which the object layer registers itself with the file layer.

The file layer must be able to turn a class name into an instance in order to
read a key, but it cannot depend on the classes themselves without a cycle —
`TStreamerInfo` is an object that lives in a file. ROOT solves the same problem
with `TClass::GetClass`; this is the same seam, set once at load time by
[`TTree`](@ref)'s top-level module.
"""
const OBJECT_FACTORY = Ref{Any}(nothing)

"Register the class factory used to materialise objects read out of keys."
register_factory!(f) = (OBJECT_FACTORY[] = f)

"The registered class factory, or `nothing` if the object layer is not loaded."
factory() = OBJECT_FACTORY[]

"""
    ROOTFile(target; kwargs...) -> ROOTFile

Open `target` for reading. It may be a path, a `root://` or `http(s)://` URL,
an `IO`, a byte vector, or an already-open [`AbstractSource`](@ref); keyword
arguments are forwarded to the source (credentials, for instance).

    ROOTFile(f -> ..., target; kwargs...)

Open, apply the function, and close even if it throws.
"""
function ROOTFile(target; kwargs...)
    src = open_source(target; kwargs...)
    f = _empty_file(target isa AbstractString ? String(target) : "<memory>")
    f.source = src
    try
        read_file_header!(f)
        read_dir_info!(f)
        f.seekfree > 0 && read_free_segments!(f)
        read_keys!(f.dir, src)
    catch
        close(src)
        rethrow()
    end
    return f
end

function ROOTFile(fn::Function, target; kwargs...)
    f = ROOTFile(target; kwargs...)
    try
        return fn(f)
    finally
        close(f)
    end
end

function _empty_file(id::AbstractString)
    return ROOTFile(
        String(id),
        nothing,
        nothing,
        ROOT_VERSION,
        Int64(FILE_BEGIN),
        Int64(FILE_BEGIN),
        Int64(0),
        Int32(0),
        Int32(0),
        Int32(0),
        UInt8(4),
        compression_code(Compress.DEFAULT_SETTINGS),
        Int64(0),
        Int32(0),
        uuid4(),
        Directory(),
        FreeSegment[],
        nothing,
        false,
    )
end

"""
    create(target; compression=Compress.DEFAULT_SETTINGS, kwargs...) -> ROOTFile

Create `target` and return it open for writing.

The file is left valid at every point after this call returns: the header and
the root directory record are already on disk, so a process that dies before
[`close`](@ref) leaves a readable — if empty — ROOT file rather than a
truncated one.
"""
function create(target; compression=Compress.DEFAULT_SETTINGS, kwargs...)
    sink = open_sink(target; kwargs...)
    id = target isa AbstractString ? String(target) : "<memory>"
    f = _empty_file(id)
    f.sink = sink
    f.compression = if compression isa Compress.Settings
        compression_code(compression)
    else
        Int32(compression)
    end
    name = basename(id)
    f.dir = Directory(name, ""; class="TFile", file=f)
    free_add!(f.spans, f.fbegin, START_BIG_FILE)

    # Reserve the root directory record: its size is fixed by the name and
    # title, so it can be placed before its contents are known.
    namelen = Int32(tstring_sizeof(name) + tstring_sizeof(""))
    objlen = namelen + Int32(dir_record_size(f.version))
    keylen = keylen_for(name, "", "TFile"; bigfile=false)
    seekkey = allocate!(f, Int64(keylen) + Int64(objlen))

    f.nbytesname = keylen + namelen
    f.dir.nbytesname = keylen + namelen
    f.dir.seekdir = seekkey

    write_file_header!(f)
    _write_root_dir_record!(f, seekkey, keylen, objlen, name)
    return f
end

function create(fn::Function, target; kwargs...)
    f = create(target; kwargs...)
    try
        return fn(f)
    finally
        close(f)
    end
end

function _write_root_dir_record!(
    f::ROOTFile, seekkey::Int64, keylen::Int32, objlen::Int32, name::AbstractString
)
    k = Key(;
        name=name,
        title="",
        class="TFile",
        cycle=1,
        objlen=objlen,
        nbytes=Int32(keylen) + objlen,
        keylen=keylen,
        seekkey=seekkey,
        seekpdir=f.fbegin,
    )
    w = WBuffer()
    write_key!(w, k)
    write_tstring!(w, name)
    write_tstring!(w, "")
    write_directory_record!(w, f.dir)
    pwrite!(f.sink::AbstractSink, bytes(w), seekkey)
    return f
end

"""
    read_file_header!(f::ROOTFile) -> f

Decode the file header.

A version of a million or more is ROOT's flag for a file over 2 GB: the seek
fields widen to eight bytes and `units` becomes 8. The million is stripped
afterwards, so `f.version` is always the plain ROOT release.
"""
function read_file_header!(f::ROOTFile)
    src = f.source::AbstractSource
    length(src) >= 64 ||
        throw(ArgumentError("TTree: $(f.id) is too short to be a ROOT file"))
    r = RBuffer(collect(read_at(src, 0, min(length(src), 76))))

    magic = ntuple(_ -> readbe(r, UInt8), 4)
    magic == ROOT_MAGIC ||
        throw(ArgumentError("TTree: $(f.id) is not a ROOT file (bad magic)"))

    f.version = readbe(r, Int32)
    f.fbegin = Int64(readbe(r, Int32))
    if f.version < 1_000_000
        f.fend = Int64(readbe(r, Int32))
        f.seekfree = Int64(readbe(r, Int32))
        f.nbytesfree = readbe(r, Int32)
        f.nfree = readbe(r, Int32)
        f.nbytesname = readbe(r, Int32)
        f.units = readbe(r, UInt8)
        f.compression = readbe(r, Int32)
        f.seekinfo = Int64(readbe(r, Int32))
        f.nbytesinfo = readbe(r, Int32)
    else
        f.fend = readbe(r, Int64)
        f.seekfree = readbe(r, Int64)
        f.nbytesfree = readbe(r, Int32)
        f.nfree = readbe(r, Int32)
        f.nbytesname = readbe(r, Int32)
        f.units = readbe(r, UInt8)
        f.compression = readbe(r, Int32)
        f.seekinfo = readbe(r, Int64)
        f.nbytesinfo = readbe(r, Int32)
    end
    f.version %= 1_000_000
    f.uuid = UUID(_be128(read_bytes(r, 16)))
    return f
end

"""
    write_file_header!(f::ROOTFile) -> f

Write the file header, promoting the file to its 64-bit form if anything it
must point at now lies past [`START_BIG_FILE`](@ref).

The whole header area is zeroed first: it is rewritten on close, and a shorter
header written over a longer one would otherwise leave the tail of the old one
behind.
"""
function write_file_header!(f::ROOTFile)
    w = WBuffer()
    for b in ROOT_MAGIC
        writebe!(w, b)
    end

    version = f.version
    big =
        f.fend > START_BIG_FILE ||
        f.seekfree > START_BIG_FILE ||
        f.seekinfo > START_BIG_FILE
    if big
        version < 1_000_000 && (version += Int32(1_000_000))
        f.units = 0x08
    end

    writebe!(w, version)
    writebe!(w, Int32(f.fbegin))
    if version < 1_000_000
        writebe!(w, Int32(f.fend))
        writebe!(w, Int32(f.seekfree))
        writebe!(w, f.nbytesfree)
        writebe!(w, Int32(length(f.spans)))
        writebe!(w, f.nbytesname)
        writebe!(w, f.units)
        writebe!(w, f.compression)
        writebe!(w, Int32(f.seekinfo))
        writebe!(w, f.nbytesinfo)
    else
        writebe!(w, f.fend)
        writebe!(w, f.seekfree)
        writebe!(w, f.nbytesfree)
        writebe!(w, Int32(length(f.spans)))
        writebe!(w, f.nbytesname)
        writebe!(w, f.units)
        writebe!(w, f.compression)
        writebe!(w, f.seekinfo)
        writebe!(w, f.nbytesinfo)
    end
    write_bytes!(w, _uuid_bytes(f.uuid))

    sink = f.sink::AbstractSink
    pwrite!(sink, zeros(UInt8, FILE_BEGIN), 0)
    pwrite!(sink, bytes(w), 0)
    return f
end

"""
    read_dir_info!(f::ROOTFile) -> f

Read the root directory: its name and title, which live in the key at
`fbegin`, and its header record, which follows them.

The two are read in one request. They are adjacent and both small, and opening
a remote file should not cost two round trips where one will do.
"""
function read_dir_info!(f::ROOTFile)
    src = f.source::AbstractSource
    nbytes = Int(f.nbytesname) + dir_record_size(f.version)
    f.fbegin + nbytes <= length(src) || throw(
        ArgumentError(
            "TTree: $(f.id) claims a $(f.nbytesname)-byte name record that runs past its end",
        ),
    )
    data = collect(read_at(src, f.fbegin, nbytes))

    f.dir.file = f
    read_directory_record!(f.dir, RBuffer(data[(Int(f.nbytesname) + 1):end]))

    # The name and title sit inside the key that opens the record, after the
    # fixed fields. Their offset depends on whether that key is 64-bit, which
    # its own version word says.
    rk = RBuffer(data)
    skip!(rk, 4)                                    # fNbytes
    keyvers = readbe(rk, Int16)
    nk = 4 + 2 + 2 * 4 + 2 * 2 + (keyvers > 1000 ? 2 * 8 : 2 * 4)

    rn = RBuffer(data[(nk + 1):end])
    f.dir.class = read_tstring(rn)
    f.dir.name = read_tstring(rn)
    f.dir.title = read_tstring(rn)

    (10 <= f.dir.nbytesname <= 1000) || throw(
        ArgumentError(
            "TTree: $(f.id) has an implausible directory name length ($(f.dir.nbytesname))",
        ),
    )
    return f
end

"""
    read_free_segments!(f::ROOTFile) -> f

Load the free-segment list from the record at `seekfree`.
"""
function read_free_segments!(f::ROOTFile)
    src = f.source::AbstractSource
    f.nbytesfree > 0 || return f
    hdr = read_key(RBuffer(collect(read_at(src, f.seekfree, Int(f.nbytesfree)))))
    r = RBuffer(key_payload(src, hdr); offset=hdr.keylen)
    empty!(f.spans)
    while remaining(r) >= 10
        push!(f.spans, read_free_segment(r))
    end
    return f
end

"""
    write_free_segments!(f::ROOTFile) -> f

Write the free-segment list as its own record and point the header at it.

The record being written is itself allocated out of the file, so the previous
list's space is released first and the new list is serialized only after its
home is known — the list therefore describes the file as it will be once this
record lands, not as it was.
"""
function write_free_segments!(f::ROOTFile)
    if f.seekfree != 0
        free_add!(f.spans, f.seekfree, f.seekfree + Int64(f.nbytesfree) - 1)
    end

    nbytes = Int32(sum(segment_sizeof, f.spans; init=Int32(0)))
    nbytes == 0 && return f

    keylen = keylen_for(f.dir.name, f.dir.title, "TFile"; bigfile=f.fend > START_BIG_FILE)
    seekkey = allocate!(f, Int64(keylen) + Int64(nbytes))

    w = WBuffer()
    for s in f.spans
        write_free_segment!(w, s)
    end
    # Taking this record's own space out of the list can shorten it by one
    # segment. The key was already sized for the longer list, so pad rather
    # than move it — a short payload would leave the key's length lying.
    payload = bytes(w)
    length(payload) < nbytes && append!(payload, zeros(UInt8, nbytes - length(payload)))
    length(payload) > nbytes &&
        throw(ArgumentError("TTree: free-segment list outgrew its reserved record"))

    k = Key(;
        name=f.dir.name,
        title=f.dir.title,
        class="TFile",
        objlen=nbytes,
        nbytes=Int32(keylen) + nbytes,
        keylen=keylen,
        seekkey=seekkey,
        seekpdir=f.fbegin,
    )
    _emit_key!(f, k, payload)

    f.seekfree = seekkey
    f.nbytesfree = Int32(keylen) + nbytes
    f.nfree = Int32(length(f.spans))
    return f
end

"""
    allocate!(f::ROOTFile, nbytes) -> Int64

Reserve `nbytes` contiguous bytes and return their offset.

Space is always taken from the end of the file. ROOT can also reuse a gap left
by a deleted object, but this package does not delete, so no gap it did not
inherit ever exists — and reusing an inherited one would mean writing the
partial-gap marker ROOT expects, for no benefit on a file being built fresh.
"""
function allocate!(f::ROOTFile, nbytes::Integer)
    off = f.fend
    f.fend = off + Int64(nbytes)
    tail = free_tail(f.spans)
    if tail !== nothing
        i = findfirst(==(tail), f.spans)
        f.spans[i] = FreeSegment(f.fend, tail.last)
    else
        free_add!(f.spans, f.fend, START_BIG_FILE)
    end
    return off
end

"""
    _emit_key!(f, k, payload, header=UInt8[]) -> k

Write a key header and its already-encoded payload at the key's own offset.

`header` is the class-specific tail some records keep *inside* the key rather
than in the payload — a `TBasket`'s bookkeeping — and is counted in `keylen`,
which is what makes the payload start where the key says it does.
"""
function _emit_key!(
    f::ROOTFile,
    k::Key,
    payload::AbstractVector{UInt8},
    header::AbstractVector{UInt8}=UInt8[],
)
    sink = f.sink::AbstractSink
    w = WBuffer()
    write_key!(w, k)
    isempty(header) || write_bytes!(w, header)
    hdr = bytes(w)
    length(hdr) == k.keylen || throw(
        ArgumentError(
            "TTree: key header for $(repr(k.name)) is $(length(hdr)) bytes, declared $(k.keylen)",
        ),
    )
    pwrite!(sink, hdr, k.seekkey)
    isempty(payload) || pwrite!(sink, payload, k.seekkey + Int64(k.keylen))
    return k
end

"""
    put_record!(f, name, title, class, obj::Vector{UInt8}; cycle=1, header=UInt8[], keylen=nothing, compression=nothing, seekpdir=nothing) -> Key

Place an already-serialized object on the file as a record of its own.

`obj` is compressed according to `compression` — the file's setting by default
— and stored uncompressed if that would not have made it smaller.

Nothing lists the result. That is what a record is for: a `TBasket` is found
through the seek its branch recorded, not by name, and putting it in a
directory would make it show up as an object of the file. [`put_key!`](@ref) is
this plus the directory entry.

`keylen` is the size of the header the payload was serialized against, and
`header` the part of that header which is not the key itself — see
[`_emit_key!`](@ref).
"""
function put_record!(
    f::ROOTFile,
    name::AbstractString,
    title::AbstractString,
    class::AbstractString,
    obj::Vector{UInt8};
    cycle::Integer=1,
    header::AbstractVector{UInt8}=UInt8[],
    keylen=nothing,
    compression=nothing,
    seekpdir=nothing,
)
    f.sink === nothing && throw(ArgumentError("TTree: $(f.id) is open for reading only"))

    settings = if compression === nothing
        settings_from(f.compression)
    else
        (compression isa Compress.Settings ? compression : settings_from(compression))
    end
    payload = Compress.compress(obj, settings)

    if keylen === nothing
        keylen = keylen_for(name, title, class; bigfile=f.fend > START_BIG_FILE)
    end
    nbytes = Int32(keylen) + Int32(length(payload))
    seekkey = allocate!(f, Int64(nbytes))

    k = Key(;
        name=name,
        title=title,
        class=class,
        cycle=cycle,
        objlen=Int32(length(obj)),
        nbytes=nbytes,
        keylen=keylen,
        seekkey=seekkey,
        seekpdir=seekpdir === nothing ? f.fbegin : Int64(seekpdir),
    )
    _emit_key!(f, k, payload, header)
    return k
end

"""
    put_key!(f, dir, name, title, class, obj::Vector{UInt8}; cycle=nothing, compression=nothing, keylen=nothing) -> Key

Place an already-serialized object into `dir` as a new key.

The cycle defaults to one past the highest already present under `name`, which
is how ROOT keeps successive writes of the same object addressable; the rest is
[`put_record!`](@ref).

`keylen` is the size of the header the payload was serialized against. It is
computable from the names alone, and is a keyword only so that a caller which
had to know it *before* serializing — see [`write!`](@ref) — can hand back the
same value rather than trust two computations to agree.
"""
function put_key!(
    f::ROOTFile,
    dir::Directory,
    name::AbstractString,
    title::AbstractString,
    class::AbstractString,
    obj::Vector{UInt8};
    cycle=nothing,
    compression=nothing,
    keylen=nothing,
)
    if cycle === nothing
        cycle = Int16(1)
        for k in dir.keys
            k.name == name && k.cycle >= cycle && (cycle = Int16(k.cycle + 1))
        end
    end

    k = put_record!(
        f,
        name,
        title,
        class,
        obj;
        cycle=cycle,
        keylen=keylen,
        compression=compression,
        seekpdir=dir.seekdir == 0 ? f.fbegin : dir.seekdir,
    )
    append_key!(dir, k)
    return k
end

"""
    write!(f::ROOTFile, name, obj; kwargs...) -> Key
    write!(dir::Directory, name, obj; kwargs...) -> Key

Store `obj` in the file under `name`, and return the key that now holds it.

Writing the same name twice does not replace anything: the new copy gets the
next cycle and becomes what the name resolves to, exactly as `TObject::Write`
does. `title` defaults to the object's own, `class` to the name it streams
under, and `compression` to the file's setting.
"""
function write!(
    f::ROOTFile,
    name::AbstractString,
    obj;
    title=nothing,
    class=nothing,
    cycle=nothing,
    compression=nothing,
)
    return write!(f, f.dir, name, obj; title, class, cycle, compression)
end

function write!(d::Directory, name::AbstractString, obj; kwargs...)
    return write!(_owner(d), d, name, obj; kwargs...)
end

function write!(
    f::ROOTFile,
    dir::Directory,
    name::AbstractString,
    obj;
    title=nothing,
    class=nothing,
    cycle=nothing,
    compression=nothing,
)
    cls = class === nothing ? String(Bytes.classname(obj)) : String(class)
    ttl = title === nothing ? String(Bytes.object_title(obj)) : String(title)

    # ROOT numbers buffer positions from the start of the key, so the object
    # has to be serialized against a header whose size is already known — which
    # it is, since the header is only the three names and a fixed part.
    keylen = keylen_for(name, ttl, cls; bigfile=f.fend > START_BIG_FILE)
    w = WBuffer(; offset=keylen)
    Bytes.marshal!(w, obj)
    _note_streamers!(f, w, cls)

    return put_key!(f, dir, name, ttl, cls, bytes(w); cycle, compression, keylen)
end

"""
    _note_streamers!(f, w, class) -> f

Record the descriptions of every class the buffer contains, so that
[`write_streamer_info!`](@ref) can store them when the file is closed.

The nested classes come from the buffer's own reference map rather than from
walking the object again, which is what makes the list exact even for a
container holding objects this package did not put there.
"""
function _note_streamers!(f::ROOTFile, w::WBuffer, class::AbstractString)
    fac = factory()
    fac === nothing && return f
    for cls in push!(Bytes.written_classes(w), String(class))
        for si in fac(:streamers, cls)
            record_streamer!(f, si)
        end
    end
    return f
end

"""
    f[name] = obj

Store `obj` under `name` — [`write!`](@ref) with the defaults.
"""
Base.setindex!(f::ROOTFile, obj, name::AbstractString) = (write!(f, name, obj); obj)
Base.setindex!(d::Directory, obj, name::AbstractString) = (write!(d, name, obj); obj)

"""
    append_key!(dir::Directory, k::Key) -> dir

Add `k` to `dir`'s key list in the position ROOT expects.

ROOT resolves an unqualified name to the *first* key in the list bearing it,
not to the highest cycle, so a new cycle must go in front of the ones it
supersedes. Appending blindly would leave `TFile::Get("name")` handing back the
oldest copy.
"""
function append_key!(dir::Directory, k::Key)
    i = findfirst(x -> x.name == k.name, dir.keys)
    i === nothing ? push!(dir.keys, k) : insert!(dir.keys, i, k)
    return dir
end

"""
    write_keys!(f::ROOTFile, dir::Directory) -> dir

Write `dir`'s key list as a single record and point the directory at it.
"""
function write_keys!(f::ROOTFile, dir::Directory)
    nbytes = Int32(4)
    f.fend > START_BIG_FILE && (nbytes += Int32(8))
    for k in dir.keys
        nbytes += k.keylen
    end

    keylen = keylen_for(dir.name, dir.title, "TDirectory"; bigfile=f.fend > START_BIG_FILE)
    seekkey = allocate!(f, Int64(keylen) + Int64(nbytes))

    w = WBuffer()
    writebe!(w, Int32(length(dir.keys)))
    for k in dir.keys
        write_key!(w, k)
    end
    payload = bytes(w)
    length(payload) < nbytes && append!(payload, zeros(UInt8, nbytes - length(payload)))

    hdr = Key(;
        name=dir.name,
        title=dir.title,
        class="TDirectory",
        objlen=nbytes,
        nbytes=Int32(keylen) + nbytes,
        keylen=keylen,
        seekkey=seekkey,
        seekpdir=dir.seekdir == 0 ? f.fbegin : dir.seekdir,
    )
    _emit_key!(f, hdr, payload)

    dir.seekkeys = seekkey
    dir.nbyteskeys = hdr.nbytes
    return dir
end

"Rewrite a directory's header record in place, after its key list has moved."
function write_dir_header!(f::ROOTFile, dir::Directory)
    dir.mtime = _now_utc()
    w = WBuffer()
    write_directory_record!(w, dir)
    pwrite!(f.sink::AbstractSink, bytes(w), dir.seekdir + Int64(dir.nbytesname))
    return dir
end

"""
    close(f::ROOTFile)

Finish and close the file.

For a writable file this is where it becomes complete: the key list, the
streamer info, the free-segment list and finally the header are written, in
that order, because each records where the previous one landed.
"""
function Base.close(f::ROOTFile)
    f.closed && return nothing
    f.closed = true
    sink = f.sink
    if sink !== nothing
        write_keys!(f, f.dir)
        write_dir_header!(f, f.dir)
        write_streamer_info!(f)
        write_free_segments!(f)
        write_file_header!(f)
        close(sink)
    end
    f.source === nothing || close(f.source)
    return nothing
end

Base.isopen(f::ROOTFile) = !f.closed

"""
    keys(f::ROOTFile) -> Vector{String}

Names of the objects in the file's root directory.
"""
Base.keys(f::ROOTFile) = keys(f.dir)
Base.haskey(f::ROOTFile, name::AbstractString) = haskey(f.dir, name)

"""
    f[namecycle]

The object stored under `namecycle`, decoded.

`namecycle` may name a nested object with `/` and select a version with `;` —
`"hists/pt;2"` is the second cycle of `pt` inside the directory `hists`. With
no cycle the highest wins, as it does in ROOT.
"""
function Base.getindex(f::ROOTFile, namecycle::AbstractString)
    obj = _lookup(f, f.dir, namecycle)
    obj === nothing && throw(KeyError(namecycle))
    return obj
end

function Base.getindex(d::Directory, namecycle::AbstractString)
    obj = _lookup(_owner(d), d, namecycle)
    obj === nothing && throw(KeyError(namecycle))
    return obj
end

"""
    get(f::ROOTFile, namecycle, default)
    get(d::Directory, namecycle, default)

The object stored under `namecycle`, or `default` if there is no such key.
"""
function Base.get(f::ROOTFile, namecycle::AbstractString, default)
    obj = _lookup(f, f.dir, namecycle)
    return obj === nothing ? default : obj
end

function Base.get(d::Directory, namecycle::AbstractString, default)
    obj = _lookup(_owner(d), d, namecycle)
    return obj === nothing ? default : obj
end

function _owner(d::Directory)
    f = d.file
    f isa ROOTFile && return f
    return throw(
        ArgumentError("TTree: directory $(repr(d.name)) is not attached to a file")
    )
end

function _lookup(f::ROOTFile, d::Directory, path::AbstractString)
    i = findfirst('/', path)
    if i !== nothing
        head = path[1:(i - 1)]
        rest = path[(i + 1):end]
        isempty(head) && return _lookup(f, f.dir, rest)
        sub = _lookup(f, d, head)
        sub isa Directory || return nothing
        return _lookup(f, sub, rest)
    end
    k = findkey(d, path)
    k === nothing && return nothing
    return read_object(f, k)
end

"""
    read_object(f::ROOTFile, k::Key) -> Any

Decode the object a key holds.

A key of class `TDirectoryFile` yields a [`Directory`](@ref) with its own keys
already loaded, so that nested lookups work without a second round trip
through the file header.
"""
function read_object(f::ROOTFile, k::Key)
    src = f.source
    src === nothing && throw(ArgumentError("TTree: $(f.id) is open for writing only"))

    if k.class == "TDirectoryFile"
        d = Directory(k.name, k.title; class=k.class, file=f)
        read_directory_record!(d, RBuffer(key_payload(src, k)))
        read_keys!(d, src)
        return d
    end

    fac = factory()
    fac === nothing && throw(
        ArgumentError(
            "TTree: the object layer is not loaded, so objects cannot be decoded"
        ),
    )
    obj = fac(k.class)
    obj === nothing && throw(
        ArgumentError("TTree: no reader for class $(repr(k.class)) (key $(repr(k.name)))"),
    )
    r = key_buffer(src, k; sinfos=streamers(f), factory=fac)
    Bytes.unmarshal!(obj, r)
    # A tree is only half itself until it knows where its baskets are; every
    # other class ignores this.
    return Bytes.bind!(obj, f)
end

"Compression algorithm and level this file was written with."
compression(f::ROOTFile) = settings_from(f.compression)

"Whether the file uses 64-bit offsets."
is_bigfile(f::ROOTFile) = f.fend > START_BIG_FILE

function Base.show(io::IO, f::ROOTFile)
    print(io, "ROOTFile(", repr(f.id))
    f.closed && return print(io, ", closed)")
    print(io, ", ROOT ", f.version, ", ", length(f.dir.keys), " keys")
    return print(io, ", ", f.fend, " bytes)")
end
