# ROOT's branches: where a tree's data actually is.
#
# A branch owns a column of the tree. It holds none of the values itself — what
# it stores is the list of file offsets where its baskets were written, one
# entry range per basket. Reading a branch means reading its baskets; reading a
# tree means doing that for the branches you asked for and no others, which is
# the whole reason the format is shaped this way.
#
# The four branch classes differ only in what they say about the values: a plain
# `TBranch` defers to its leaves, a `TBranchElement` names a class and a place
# within its streamer info, a `TBranchObject` names a class outright, and a
# `TBranchRef` carries the table that resolves cross-references.

"""
    TBranch

ROOT's `TBranch`: a column of a tree, stored as a sequence of baskets.

`basketseek[i]` is where basket `i` was written and `basketbytes[i]` how large
it is on disk; `basketentry[i]` is the first entry it holds, so the table is
also the index that turns an entry number into a seek. Only the first
`writebasket` of them are on the file — the rest are slots ROOT reserved.
"""
mutable struct TBranch <: ROOTObject
    named::TNamed
    attfill::TAttFill
    compress::Int32
    basketsize::Int32
    entryoffsetlen::Int32
    writebasket::Int32
    entrynumber::Int64
    iofeatures::TIOFeatures
    offset::Int32
    maxbaskets::Int32
    splitlevel::Int32
    entries::Int64
    firstentry::Int64
    totbytes::Int64
    zipbytes::Int64
    branches::Vector{Any}
    leaves::Vector{Any}
    baskets::Vector{Any}
    basketbytes::Vector{Int32}
    basketentry::Vector{Int64}
    basketseek::Vector{Int64}
    filename::String
    # Not streamed: the file the branch was read from, without which its seek
    # offsets point at nothing, and the tree it belongs to, without which a
    # variable-length leaf cannot find the leaf that counts it.
    file::Any
    tree::Any
end

function TBranch(name::AbstractString="", title::AbstractString="")
    return TBranch(
        TNamed(name, title),
        TAttFill(Int16(0), Int16(1001)),
        Int32(0),
        Int32(32000),
        Int32(0),
        Int32(0),
        Int64(0),
        TIOFeatures(),
        Int32(0),
        Int32(0),
        Int32(0),
        Int64(0),
        Int64(0),
        Int64(0),
        Int64(0),
        Any[],
        Any[],
        Any[],
        Int32[],
        Int64[],
        Int64[],
        "",
        nothing,
        nothing,
    )
end

Bytes.classname(::TBranch) = "TBranch"
rversion(::TBranch) = Int16(13)

"The member order this package writes a `TBranch` in — ROOT's version 13."
function Bytes.unmarshal!(b::TBranch, r::RBuffer)
    hdr = read_header(r, "TBranch")
    read_branch!(b, r, hdr.vers)
    check_header(r, hdr)
    return b
end

"""
    read_branch!(b::TBranch, r::RBuffer, vers) -> b

Read the `TBranch` part of a branch of any class, following the file's own
description of version `vers` — see [`layout`](@ref).

Split out from `unmarshal!` because the version is not always the one in the
header just read: a `TTree` version 5 file holds branches at version 8, and the
member list differs.
"""
function read_branch!(b::TBranch, r::RBuffer, vers::Integer)
    for e in layout(r, "TBranch", vers)
        m = name(e)
        if m == "TNamed"
            Bytes.unmarshal!(b.named, r)
        elseif m == "TAttFill"
            Bytes.unmarshal!(b.attfill, r)
        elseif m == "fCompress"
            b.compress = read_scalar(r, e)
        elseif m == "fBasketSize"
            b.basketsize = read_scalar(r, e)
        elseif m == "fEntryOffsetLen"
            b.entryoffsetlen = read_scalar(r, e)
        elseif m == "fWriteBasket"
            b.writebasket = read_scalar(r, e)
        elseif m == "fEntryNumber"
            b.entrynumber = read_count(r, e)
        elseif m == "fIOFeatures"
            Bytes.unmarshal!(b.iofeatures, r)
        elseif m == "fOffset"
            b.offset = read_scalar(r, e)
        elseif m == "fMaxBaskets"
            b.maxbaskets = read_scalar(r, e)
        elseif m == "fSplitLevel"
            b.splitlevel = read_scalar(r, e)
        elseif m == "fEntries"
            b.entries = read_count(r, e)
        elseif m == "fFirstEntry"
            b.firstentry = read_count(r, e)
        elseif m == "fTotBytes"
            b.totbytes = read_count(r, e)
        elseif m == "fZipBytes"
            b.zipbytes = read_count(r, e)
        elseif m == "fBranches"
            read_objarray!(b.branches, r)
        elseif m == "fLeaves"
            read_objarray!(b.leaves, r)
        elseif m == "fBaskets"
            read_objarray!(b.baskets, r)
        elseif m == "fBasketBytes"
            b.basketbytes = read_pointer_array(r, e, b.maxbaskets, Int32)
        elseif m == "fBasketEntry"
            b.basketentry = read_pointer_array(r, e, b.maxbaskets, Int64)
        elseif m == "fBasketSeek"
            b.basketseek = read_pointer_array(r, e, b.maxbaskets, Int64)
        elseif m == "fFileName"
            b.filename = read_tstring(r)
        else
            unknown_member("TBranch", vers, m)
        end
    end
    return b
end

function Bytes.marshal!(w::WBuffer, b::TBranch)
    hdr = write_header!(w, "TBranch", rversion(b))
    write_branch!(w, b)
    set_header!(w, hdr)
    return w
end

"Write the `TBranch` part of a branch of any class, in ROOT's version 13 order."
function write_branch!(w::WBuffer, b::TBranch)
    Bytes.marshal!(w, b.named)
    Bytes.marshal!(w, b.attfill)
    writebe!(w, b.compress)
    writebe!(w, b.basketsize)
    writebe!(w, b.entryoffsetlen)
    writebe!(w, b.writebasket)
    writebe!(w, b.entrynumber)
    Bytes.marshal!(w, b.iofeatures)
    writebe!(w, b.offset)
    writebe!(w, b.maxbaskets)
    writebe!(w, b.splitlevel)
    writebe!(w, b.entries)
    writebe!(w, b.firstentry)
    writebe!(w, b.totbytes)
    writebe!(w, b.zipbytes)
    write_objarray!(w, b.branches)
    write_objarray!(w, b.leaves)
    write_objarray!(w, b.baskets)
    write_pointer_array!(w, b.basketbytes)
    write_pointer_array!(w, b.basketentry)
    write_pointer_array!(w, b.basketseek)
    write_tstring!(w, b.filename)
    return w
end

"""
    TBranchElement

A branch of a split object: `classname` is the class it came from and `id` the
member of that class's streamer info it holds, or `-1` when the branch holds the
object as a whole.

`btype` is ROOT's `fType`, which says how the branch was split — a plain member,
the size of a `TClonesArray`, an element of one, and so on.
"""
mutable struct TBranchElement <: ROOTObject
    branch::TBranch
    classname::String
    parentname::String
    clonesname::String
    checksum::UInt32
    classversion::Int16
    id::Int32
    btype::Int32
    streamertype::Int32
    maximum::Int32
    branchcount::Any
    branchcount2::Any
end

function TBranchElement(name::AbstractString="", title::AbstractString="")
    return TBranchElement(
        TBranch(name, title),
        "",
        "",
        "",
        UInt32(0),
        Int16(-1),
        Int32(-1),
        Int32(0),
        Int32(-1),
        Int32(0),
        nothing,
        nothing,
    )
end

Bytes.classname(::TBranchElement) = "TBranchElement"
rversion(::TBranchElement) = Int16(10)

function Bytes.unmarshal!(b::TBranchElement, r::RBuffer)
    hdr = read_header(r, "TBranchElement")
    for e in layout(r, "TBranchElement", hdr.vers)
        m = name(e)
        if m == "TBranch"
            Bytes.unmarshal!(b.branch, r)
        elseif m == "fClassName"
            b.classname = read_tstring(r)
        elseif m == "fParentName"
            b.parentname = read_tstring(r)
        elseif m == "fClonesName"
            b.clonesname = read_tstring(r)
        elseif m == "fCheckSum"
            b.checksum = read_scalar(r, e)
        elseif m == "fClassVersion"
            b.classversion = read_scalar(r, e)
        elseif m == "fID"
            b.id = read_scalar(r, e)
        elseif m == "fType"
            b.btype = read_scalar(r, e)
        elseif m == "fStreamerType"
            b.streamertype = read_scalar(r, e)
        elseif m == "fMaximum"
            b.maximum = read_scalar(r, e)
        elseif m == "fBranchCount"
            b.branchcount = read_object_any(r)
        elseif m == "fBranchCount2"
            b.branchcount2 = read_object_any(r)
        else
            unknown_member("TBranchElement", hdr.vers, m)
        end
    end
    check_header(r, hdr)
    return b
end

function Bytes.marshal!(w::WBuffer, b::TBranchElement)
    hdr = write_header!(w, "TBranchElement", rversion(b))
    Bytes.marshal!(w, b.branch)
    write_tstring!(w, b.classname)
    write_tstring!(w, b.parentname)
    write_tstring!(w, b.clonesname)
    writebe!(w, b.checksum)
    writebe!(w, b.classversion)
    writebe!(w, b.id)
    writebe!(w, b.btype)
    writebe!(w, b.streamertype)
    writebe!(w, b.maximum)
    write_object_any!(w, b.branchcount)
    write_object_any!(w, b.branchcount2)
    set_header!(w, hdr)
    return w
end

"""
    TBranchObject

A branch holding whole objects of one class, from before `TBranchElement`
existed. Nothing is split: each entry is the object, streamed as ROOT would
stream it anywhere else.
"""
mutable struct TBranchObject <: ROOTObject
    branch::TBranch
    classname::String
end

function TBranchObject(name::AbstractString="", title::AbstractString="")
    return TBranchObject(TBranch(name, title), "")
end

Bytes.classname(::TBranchObject) = "TBranchObject"
rversion(::TBranchObject) = Int16(1)

"""
    TBranchRef

The branch a tree uses to resolve `TRef`s. It holds no data of its own, only the
table naming the branches referenced objects live in.
"""
mutable struct TBranchRef <: ROOTObject
    branch::TBranch
    reftable::Any
end

TBranchRef() = TBranchRef(TBranch("TRefTable", "TRefTable"), nothing)

Bytes.classname(::TBranchRef) = "TBranchRef"
rversion(::TBranchRef) = Int16(1)

for (cls, member, field) in
    ((:TBranchObject, "fClassName", :classname), (:TBranchRef, "fRefTable", :reftable))
    cls_str = String(cls)
    @eval begin
        function Bytes.unmarshal!(b::$cls, r::RBuffer)
            hdr = read_header(r, $cls_str)
            for e in layout(r, $cls_str, hdr.vers)
                m = name(e)
                if m == "TBranch"
                    Bytes.unmarshal!(b.branch, r)
                elseif m == $member
                    b.$field = $(
                        if member == "fClassName"
                            :(read_tstring(r))
                        else
                            :(read_object_any(r))
                        end
                    )
                else
                    unknown_member($cls_str, hdr.vers, m)
                end
            end
            check_header(r, hdr)
            return b
        end

        function Bytes.marshal!(w::WBuffer, b::$cls)
            hdr = write_header!(w, $cls_str, rversion(b))
            Bytes.marshal!(w, b.branch)
            $(
                if member == "fClassName"
                    :(write_tstring!(w, b.$field))
                else
                    :(write_object_any!(w, b.$field))
                end
            )
            set_header!(w, hdr)
            return w
        end
    end
end

"""
    AnyBranch

Any of ROOT's branch classes. Each wraps a [`TBranch`](@ref), which
[`branchcore`](@ref) reaches uniformly.
"""
const AnyBranch = Union{TBranch,TBranchElement,TBranchObject,TBranchRef}

"""
    branchcore(b) -> TBranch

The common `TBranch` part of any branch.
"""
branchcore(b::TBranch) = b
branchcore(b::Union{TBranchElement,TBranchObject,TBranchRef}) = b.branch

Objects.name(b::AnyBranch) = Objects.name(branchcore(b).named)
Objects.title(b::AnyBranch) = Objects.title(branchcore(b).named)

"The branches nested inside this one, empty for an unsplit branch."
branches(b::AnyBranch) = branchcore(b).branches

"The leaves describing this branch's values."
leaves(b::AnyBranch) = branchcore(b).leaves

"Number of entries this branch holds."
entries(b::AnyBranch) = branchcore(b).entries

"The tree this branch belongs to, or `nothing` for one not read from a tree."
owner(b::AnyBranch) = branchcore(b).tree

"Compression algorithm and level this branch's baskets were written with."
compression(b::AnyBranch) = Compress.settings_from(branchcore(b).compress)

function Bytes.bind!(b::AnyBranch, file)
    core = branchcore(b)
    core.file = file
    for sub in core.branches
        sub === nothing || Bytes.bind!(sub, file)
    end
    return b
end

"""
    adopt!(b, tree) -> b

Point `b` and every branch nested in it at the tree they belong to.

A branch is read knowing only itself, but a variable-length leaf is counted by
a leaf that usually lives in a *different* branch, and only the tree lists
both.
"""
function adopt!(b::AnyBranch, tree)
    core = branchcore(b)
    core.tree = tree
    for sub in core.branches
        sub === nothing || adopt!(sub, tree)
    end
    return b
end

function Base.show(io::IO, b::AnyBranch)
    core = branchcore(b)
    print(io, Bytes.classname(b), "(", repr(Objects.name(b)))
    print(io, ", ", core.entries, " entries")
    isempty(core.branches) || print(io, ", ", length(core.branches), " sub-branches")
    return print(io, ", ", core.writebasket, " baskets)")
end
