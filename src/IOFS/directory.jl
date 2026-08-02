# TDirectoryFile: the record that holds a directory's own metadata, and the
# separate record that holds its list of keys.
#
# A directory is two records, not one. The header record — at `seekdir` — says
# where the key list lives and how big it is; the key list record, at
# `seekkeys`, is a count followed by the key headers themselves. Reading them
# is therefore two seeks, and writing a directory means writing the key list
# first so the header can point at it.

"Current `TDirectoryFile` class version."
const DIRECTORY_VERSION = Int16(5)

"""
    Directory

A directory inside a ROOT file.

The root directory is a `Directory` too, distinguished only by its class being
`TFile` and by living at the file's `fbegin`. Its keys are the file's top-level
contents.
"""
mutable struct Directory
    name::String
    title::String
    class::String
    rvers::Int16
    ctime::DateTime
    mtime::DateTime
    nbyteskeys::Int32
    nbytesname::Int32
    seekdir::Int64
    seekparent::Int64
    seekkeys::Int64
    uuid::UUID
    keys::Vector{Key}
    file::Any                       # the owning ROOTFile; `Any` breaks the type cycle
end

function Directory(
    name::AbstractString="",
    title::AbstractString="";
    class::AbstractString="TDirectoryFile",
    file=nothing,
)
    now = _now_utc()
    return Directory(
        String(name),
        String(title),
        String(class),
        DIRECTORY_VERSION,
        now,
        now,
        Int32(0),
        Int32(0),
        Int64(0),
        Int64(0),
        Int64(0),
        uuid4(),
        Key[],
        file,
    )
end

"Whether this directory's record stores 64-bit seek fields."
dir_is_bigfile(d::Directory) = d.rvers > 1000

"""
    dir_record_size(version::Integer) -> Int

Size of a directory header record for a file written by ROOT `version`.

Used only to size the read buffer, and deliberately generous: ROOT 4 and later
always spend eight bytes per seek here, but the record actually read is decoded
according to its *own* version, so over-reading is harmless while
under-reading would truncate the record.
"""
function dir_record_size(version::Integer)
    n = 2 + 4 + 4 + 4 + 4               # version, ctime, mtime, nbyteskeys, nbytesname
    n += version >= 40000 ? 24 : 12     # seekdir, seekparent, seekkeys
    n += 18                             # TUUID: version plus sixteen bytes
    return n
end

"""
    read_directory_record!(d::Directory, r::RBuffer) -> d

Decode a `TDirectoryFile` header record into `d`.
"""
function read_directory_record!(d::Directory, r::RBuffer)
    d.rvers = readbe(r, Int16)
    d.ctime = datime_to_datetime(readbe(r, UInt32))
    d.mtime = datime_to_datetime(readbe(r, UInt32))
    d.nbyteskeys = readbe(r, Int32)
    d.nbytesname = readbe(r, Int32)
    if dir_is_bigfile(d)
        d.seekdir = readbe(r, Int64)
        d.seekparent = readbe(r, Int64)
        d.seekkeys = readbe(r, Int64)
    else
        d.seekdir = Int64(readbe(r, Int32))
        d.seekparent = Int64(readbe(r, Int32))
        d.seekkeys = Int64(readbe(r, Int32))
    end

    v = d.rvers % 1000
    if v == 2
        d.uuid = _read_uuid_v1(r)
    elseif v > 2
        d.uuid = _read_uuid(r)
    end
    return d
end

"""
    write_directory_record!(w::WBuffer, d::Directory) -> w

Encode a `TDirectoryFile` header record.
"""
function write_directory_record!(w::WBuffer, d::Directory)
    writebe!(w, d.rvers)
    writebe!(w, datetime_to_datime(d.ctime))
    writebe!(w, datetime_to_datime(d.mtime))
    writebe!(w, d.nbyteskeys)
    writebe!(w, d.nbytesname)
    if dir_is_bigfile(d)
        writebe!(w, d.seekdir)
        writebe!(w, d.seekparent)
        writebe!(w, d.seekkeys)
    else
        writebe!(w, Int32(d.seekdir))
        writebe!(w, Int32(d.seekparent))
        writebe!(w, Int32(d.seekkeys))
    end
    _write_uuid!(w, d.uuid)
    return w
end

"TUUID as it appears in a directory record: a version word then sixteen raw bytes."
function _read_uuid(r::RBuffer)
    skip!(r, 2)
    return _read_uuid_v1(r)
end

_read_uuid_v1(r::RBuffer) = UUID(_be128(read_bytes(r, 16)))

function _write_uuid!(w::WBuffer, u::UUID)
    writebe!(w, UInt16(1))
    return write_bytes!(w, _uuid_bytes(u))
end

function _be128(b::AbstractVector{UInt8})
    v = UInt128(0)
    for x in b
        v = (v << 8) | UInt128(x)
    end
    return v
end

function _uuid_bytes(u::UUID)
    v = u.value
    return UInt8[(v >> (8 * (15 - i))) % UInt8 for i in 0:15]
end

"""
    read_keys!(d::Directory, src::AbstractSource) -> d

Load `d`'s key list from the record at `seekkeys`.

The record is itself a key, so this reads a key header, then the payload it
describes: a count followed by that many key headers.
"""
function read_keys!(d::Directory, src::AbstractSource)
    d.seekkeys <= 0 && return d
    hdr_bytes = read_at(src, d.seekkeys, min(Int(d.nbyteskeys), length(src) - d.seekkeys))
    hdr = read_key(RBuffer(collect(hdr_bytes)))

    r = RBuffer(key_payload(src, hdr); offset=hdr.keylen)
    nkeys = readbe(r, Int32)
    nkeys < 0 &&
        throw(ArgumentError("TTree: directory $(repr(d.name)) reports $nkeys keys"))
    empty!(d.keys)
    sizehint!(d.keys, Int(nkeys))
    for _ in 1:nkeys
        push!(d.keys, read_key(r))
    end
    return d
end

"""
    keyname(k::Key) -> String

The `name;cycle` spelling ROOT uses to disambiguate versions of an object.
"""
keyname(k::Key) = string(k.name, ';', k.cycle)

"""
    decode_namecycle(s) -> (name, cycle)

Split ROOT's `"name;cycle"` addressing. A missing or unparsable cycle means
"the highest", which ROOT spells 9999.
"""
function decode_namecycle(s::AbstractString)
    i = findlast(';', s)
    i === nothing && return String(s), Int16(9999)
    name = s[1:(i - 1)]
    rest = s[(i + 1):end]
    rest == "*" && return String(name), Int16(9999)
    c = tryparse(Int16, rest)
    c === nothing && return String(s), Int16(9999)
    return String(name), c
end

"""
    findkey(d::Directory, namecycle) -> Union{Key,Nothing}

The key named by `namecycle`, or `nothing`.

With no explicit cycle the *highest* cycle wins, which is ROOT's rule and the
reason rewriting an object under an existing name does not hide it: the new
copy simply gets a higher cycle.
"""
function findkey(d::Directory, namecycle::AbstractString)
    name, cycle = decode_namecycle(namecycle)
    best = nothing
    for k in d.keys
        k.name == name || continue
        if cycle != 9999
            k.cycle == cycle && return k
            continue
        end
        if best === nothing || k.cycle > best.cycle
            best = k
        end
    end
    return best
end

"""
    keys(d::Directory) -> Vector{String}

Names of the objects in `d`, without cycles and without duplicates.
"""
function Base.keys(d::Directory)
    out = String[]
    for k in d.keys
        k.name in out || push!(out, k.name)
    end
    return out
end

Base.haskey(d::Directory, name::AbstractString) = findkey(d, name) !== nothing

function Base.show(io::IO, d::Directory)
    print(io, "Directory(", repr(d.name))
    isempty(d.title) || print(io, ", ", repr(d.title))
    return print(io, ", ", length(d.keys), " keys)")
end
