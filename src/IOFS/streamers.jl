# The streamer info: a file's self-description.
#
# A ROOT file carries the layout of every class it contains, so that a reader
# with no knowledge of the writing program's C++ can still decode its objects.
# The descriptions live in one `TList` of `TStreamerInfo`, written near the end
# of the file and pointed at by the header's `seekinfo` — deliberately outside
# the directory's key list, since it describes the file rather than being part
# of its contents.
#
# This file owns only the record: finding it, decompressing it, and writing it
# back. What a `TStreamerInfo` *is* belongs to the object layer, and is reached
# through the factory seam.

"Name of the key holding the streamer info; fixed by the format."
const STREAMER_INFO_NAME = "StreamerInfo"
const STREAMER_INFO_TITLE = "Doubly linked list"

"""
    StreamerDB

The class descriptions a file carries, indexed for the two questions the
decoder actually asks: "how did *this* file lay out class `C`", and — when an
object's own version word disagrees — "how did it lay out version `v` of it".

`order` preserves the sequence the descriptions were read or recorded in, so a
file rewritten by this package lists its classes as ROOT would: base classes
before the classes that inherit them.
"""
struct StreamerDB
    byname::Dict{String,Any}
    byversion::Dict{Tuple{String,Int16},Any}
    order::Vector{Any}
end

StreamerDB() = StreamerDB(Dict{String,Any}(), Dict{Tuple{String,Int16},Any}(), Any[])

Base.length(db::StreamerDB) = length(db.order)
Base.isempty(db::StreamerDB) = isempty(db.order)
Base.keys(db::StreamerDB) = collect(keys(db.byname))
Base.haskey(db::StreamerDB, class::AbstractString) = haskey(db.byname, class)

"""
    getindex(db::StreamerDB, class) -> TStreamerInfo
    getindex(db::StreamerDB, class, version) -> TStreamerInfo

The description of `class`, optionally of a specific class version.

Asking for a version the file does not carry falls back to the one it does: a
file usually stores a single version per class, and an object whose version
word names another is far more often a `TObject`-style class whose layout did
not change than a genuinely missing description.
"""
Base.getindex(db::StreamerDB, class::AbstractString) = db.byname[class]

function Base.getindex(db::StreamerDB, class::AbstractString, version::Integer)
    si = get(db.byversion, (String(class), Int16(version)), nothing)
    si === nothing || return si
    return db.byname[class]
end

function Base.get(db::StreamerDB, class::AbstractString, default)
    return get(db.byname, class, default)
end

"""
    Bytes.streamer_info(db::StreamerDB, class, version) -> Union{Any,Nothing}

The lookup [`read_header`](@ref) uses to resolve a class written before ROOT
had version numbers. A negative `version` asks for the latest.

Unlike `db[class]` this returns `nothing` rather than throwing: an unversioned
class the file does not describe is a fact about the file, and the caller
recovers by treating the four bytes it peeked at as payload.
"""
function Bytes.streamer_info(db::StreamerDB, class::AbstractString, version::Integer)
    if version >= 0
        si = get(db.byversion, (String(class), Int16(version)), nothing)
        si === nothing || return si
    end
    return get(db.byname, class, nothing)
end

"""
    record!(db::StreamerDB, si) -> db

Add a class description, replacing any earlier one for the same class and
version. Recording is idempotent so that writing many objects of one class
does not multiply its description.
"""
function record!(db::StreamerDB, si)
    name = String(Bytes.described_class(si))
    vers = Int16(Bytes.class_version(si))
    key = (name, vers)
    if haskey(db.byversion, key)
        i = findfirst(x -> x === db.byversion[key], db.order)
        i === nothing || (db.order[i] = si)
    else
        push!(db.order, si)
    end
    db.byversion[key] = si
    # A later version wins the unqualified lookup; that is the layout a reader
    # with no version information should assume.
    old = get(db.byname, name, nothing)
    if old === nothing || Bytes.class_version(old) <= vers
        db.byname[name] = si
    end
    return db
end

function Base.show(io::IO, db::StreamerDB)
    return print(io, "StreamerDB(", length(db.order), " classes)")
end

"""
    streamers(f::ROOTFile) -> StreamerDB

The file's class descriptions, parsed on first use.

Most reads never need them — a branch of `Float64` is decoded from its leaf,
not from a streamer — so a file with hundreds of classes should not pay to
parse them all just to be opened.
"""
function streamers(f::ROOTFile)
    db = f.streamers
    db === nothing || return db::StreamerDB
    db = read_streamer_info(f)
    f.streamers = db
    return db
end

"""
    read_streamer_info(f::ROOTFile) -> StreamerDB

Read and decode the streamer info record.

Returns an empty database when the file has none, which is normal for a file
containing only histograms or only numeric trees.
"""
function read_streamer_info(f::ROOTFile)
    db = StreamerDB()
    (f.seekinfo > 0 && f.nbytesinfo > 0) || return db
    src = f.source
    src === nothing && return db

    fac = factory()
    fac === nothing && throw(
        ArgumentError(
            "TTree: the object layer is not loaded, so streamer info cannot be decoded"
        ),
    )

    k = read_key(RBuffer(collect(read_at(src, f.seekinfo, Int(f.nbytesinfo)))))
    # The payload is the list itself, streamed with no class tag in front of
    # it: the key header already named the class.
    list = fac(k.class)
    list === nothing && return db
    Bytes.unmarshal!(list, key_buffer(src, k; sinfos=db, factory=fac))

    for si in list
        si === nothing && continue
        # The list also carries schema-evolution rules — nested lists of
        # strings — which describe no class and so have no version to file
        # them under.
        applicable(Bytes.described_class, si) || continue
        record!(db, si)
    end
    return db
end

"""
    record_streamer!(f::ROOTFile, si) -> f

Note that `si` must be described in this file's streamer info.

Called by the object layer as objects are written. A file that stores a class
without describing it is readable only by a program that already knows the
class, which defeats the point of the format.
"""
function record_streamer!(f::ROOTFile, si)
    db = f.streamers
    if db === nothing
        db = StreamerDB()
        f.streamers = db
    end
    record!(db::StreamerDB, si)
    return f
end

"""
    write_streamer_info!(f::ROOTFile) -> f

Write the streamer info record and point the file header at it.

The record is a standalone key: it is reachable through `seekinfo` alone and is
deliberately absent from the directory's key list, so `keys(f)` shows what was
stored rather than the file's own bookkeeping.
"""
function write_streamer_info!(f::ROOTFile)
    db = f.streamers
    (db isa StreamerDB && !isempty(db)) || return f

    fac = factory()
    fac === nothing && throw(
        ArgumentError(
            "TTree: the object layer is not loaded, so streamer info cannot be written"
        ),
    )

    bigfile = f.fend > START_BIG_FILE
    keylen = keylen_for(STREAMER_INFO_NAME, STREAMER_INFO_TITLE, "TList"; bigfile=bigfile)

    # The buffer is offset by the key length because ROOT numbers positions
    # from the start of the *key*, not of the payload: the back-references
    # written into the record have to agree with what a reader computes.
    w = WBuffer(; offset=keylen)
    Bytes.marshal!(w, fac(:list, db.order, STREAMER_INFO_NAME))
    obj = bytes(w)

    payload = Compress.compress(obj, settings_from(f.compression))
    nbytes = Int32(keylen) + Int32(length(payload))
    seekkey = allocate!(f, Int64(nbytes))

    k = Key(;
        name=STREAMER_INFO_NAME,
        title=STREAMER_INFO_TITLE,
        class="TList",
        objlen=Int32(length(obj)),
        nbytes=nbytes,
        keylen=keylen,
        seekkey=seekkey,
        seekpdir=f.fbegin,
    )
    _emit_key!(f, k, payload)

    f.seekinfo = seekkey
    f.nbytesinfo = nbytes
    return f
end
