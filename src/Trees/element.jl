# Branches that hold objects.
#
# A branch of numbers is described by its leaves; a branch of objects is not.
# What a `TBranchElement` holds is settled by three numbers it carries — the
# class it was made from, which member of that class it is (`fID`), and how it
# was split (`fType`) — read against the file's own description of that class.
#
# Those three combine into four cases, and every object branch is one of them:
#
#   - the whole object (`fID` = -1), its members written one after another;
#   - one member of it (`fID` >= 0), the rest living in sibling branches;
#   - one member of *every element* of a split collection (`fType` 31 or 41) —
#     the same plan, read as many times as the entry's collection is long;
#   - nothing at all: a branch that was split holds only its children, and its
#     value is theirs put back together.
#
# Splitting is why this is worth doing rather than reading whole objects and
# discarding what was not asked for: ROOT wrote each member to baskets of its
# own precisely so that a reader could touch one and leave the rest on disk.

"""
    ElementReader

How to read one entry of a branch that holds objects.

`framing` says whether the entry carries a header — see the note in
`Objects/values.jl` on why that cannot be read off the plan. `:sniff` is the one
case the file leaves ambiguous: a top-level `std::string`, written bare by some
ROOT versions and framed by others.
"""
struct ElementReader{P<:ValuePlan}
    plan::P
    framing::Symbol
    named::Bool
    run::Bool
end

"""
    CompositeReader

A branch whose value is assembled from its children's.

`collection` separates a split object, whose children each give one value per
entry, from a split collection, whose children each give as many values per
entry as the collection is long.
"""
struct CompositeReader
    subs::Vector{Any}
    names::Vector{Symbol}
    collection::Bool
end

"""
    isobjectbranch(b) -> Bool

Whether `b` holds streamed objects rather than plain numbers.

A `TBranchElement` that was split holds no leaves at all, so the leaves alone
cannot answer this.
"""
isobjectbranch(b::AnyBranch) = any(l -> l isa Union{TLeafElement,TLeafObject}, leaves(b))
isobjectbranch(::TBranchElement) = true
isobjectbranch(::TBranchObject) = true

"""
    streamerdb(b) -> Union{StreamerDB,Nothing}

The description of the classes in the file `b` was read from, or `nothing` for a
branch with no file behind it.
"""
function streamerdb(b::AnyBranch)
    f = branchcore(b).file
    f === nothing && return nothing
    return IOFS.streamers(f)
end

# ---------------------------------------------------------------------------
# Working out what a branch holds.

"""
    objectreader(b) -> ElementReader or CompositeReader

Settle, once for the branch, how one of its entries is to be read.
"""
function objectreader(b::TBranchElement)
    db = streamerdb(b)
    id = Int(b.id)
    ty = Int(b.btype)
    kids = branches(b)

    # A split branch holds nothing of its own. `fID` = -2 is an object taken
    # apart into its members, `fType` 2 a member that was itself an object, and
    # `fType` 3 and 4 a `TClonesArray` or an STL collection taken apart into its
    # elements' members.
    if !isempty(kids) && (id == -2 || ty == 2 || ty == 3 || ty == 4)
        return composite_reader(b, kids, ty == 3 || ty == 4)
    end

    id >= 0 && return member_reader(b, db, id, ty)

    # The whole value. A container carries a header; a class ROOT streams by
    # hand carries whatever its streamer writes, which for `TDatime` is nothing;
    # a class ROOT streams from its description is written bare here, its
    # members following one another as they would inside any other object.
    cls = String(b.classname)
    t = parse_typename(cls)
    if is_container(t)
        p = type_plan(db, t)
        return ElementReader(p, p isa StringPlan ? :sniff : :framed, false, false)
    end
    p = class_plan(db, cls, Int(b.classversion))
    framed = ty == -1 && !(p isa DatimePlan) && !(p isa StringPlan)
    return ElementReader(p, framed ? :framed : :bare, false, false)
end

function objectreader(b::TBranchObject)
    p = class_plan(streamerdb(b), String(b.classname), -1)
    ls = leaves(b)
    # Before `fVirtual` existed the class was always written; reading a
    # `TLeafObject` fills that in, so this only has to ask.
    named = isempty(ls) || !(ls[1] isa TLeafObject) || ls[1].virt
    return ElementReader(p, :framed, named, false)
end

function objectreader(b::AnyBranch)
    return throw(
        ArgumentError(
            "TTree: branch $(repr(Objects.name(b))) holds objects but is a $(Bytes.classname(b)), which does not name their class",
        ),
    )
end

"""
    member_reader(b, db, id, ty) -> ElementReader

A branch holding one member of a class: `fID` indexes the member list of
`fClassName`'s streamer info, which is where the member's plan and its framing
both come from.
"""
function member_reader(b::TBranchElement, db, id::Int, ty::Int)
    cls = String(b.classname)
    p = class_plan(db, cls, Int(b.classversion))
    p isa ObjectPlan || throw(
        ArgumentError(
            "TTree: branch $(repr(Objects.name(b))) holds a member of $cls, which this file does not describe as a class",
        ),
    )
    checkbounds(Bool, p.members, id + 1) || throw(
        ArgumentError(
            "TTree: branch $(repr(Objects.name(b))) is member $id of $cls, which has $(length(p.members))",
        ),
    )
    m = p.members[id + 1]
    return ElementReader(m.plan, m.framed ? :framed : :bare, false, ty == 31 || ty == 41)
end

"""
    composite_reader(b, kids, collection) -> CompositeReader

The children of a split branch, and what each is called in the value they make.
"""
function composite_reader(b::AnyBranch, kids::AbstractVector, collection::Bool)
    subs = Any[]
    names = Symbol[]
    for k in kids
        k === nothing && continue
        push!(subs, k)
        push!(names, submembername(b, k))
    end
    isempty(subs) && throw(
        ArgumentError(
            "TTree: branch $(repr(Objects.name(b))) was split but has no sub-branches"
        ),
    )
    return CompositeReader(subs, names, collection)
end

"""
    submembername(parent, kid) -> Symbol

The member name to give a sub-branch's column.

ROOT names a sub-branch for the member it holds, prefixed by its parent and
suffixed by its dimensions — `evt.P3.Px`, `fArray[10]` — so the member's own
name has to be cut back out of it.
"""
function submembername(parent::AnyBranch, kid::AnyBranch)
    nm = String(Objects.name(kid))
    prefix = String(Objects.name(parent)) * "."
    startswith(nm, prefix) && (nm = nm[(ncodeunits(prefix) + 1):end])
    i = findlast('.', nm)
    i === nothing || (nm = nm[nextind(nm, i):end])
    j = findfirst('[', nm)
    j === nothing || (nm = nm[1:prevind(nm, j)])
    isempty(nm) && (nm = String(Objects.name(kid)))
    return Symbol(nm)
end

"The Julia type one entry read by `rd` comes back as."
function reader_eltype(rd::ElementReader)
    return rd.run ? Vector{value_eltype(rd.plan)} : value_eltype(rd.plan)
end

# ---------------------------------------------------------------------------
# How long an entry is.
#
# Two kinds of entry do not say their own length. A `[count]` member is as long
# as another leaf says, and one member of a split collection is repeated as many
# times as the collection's own branch says. Both counts are columns of their
# own, and both are read from the branch that holds them rather than recovered
# by dividing an entry's size by the width of a value.

"""
    entry_lengths(b, rd, n) -> Union{Nothing,Vector{Int}}

How many values each of `b`'s `n` entries holds, or `nothing` where the entry
settles that itself.
"""
function entry_lengths(b::AnyBranch, rd::ElementReader, n::Int)
    rd.plan isa CountedPlan && return counted_lengths(b, n)
    rd.run && return run_lengths(b, n)
    return nothing
end

entry_lengths(::AnyBranch, ::CompositeReader, ::Int) = nothing

"The per-entry length of a `[count]` member, from the leaf that counts it."
function counted_lengths(b::AnyBranch, n::Int)
    ls = leaves(b)
    isempty(ls) && return nothing
    l = ls[1]
    countleaf(l) === nothing && return nothing
    counts = _entrycounts(b, [l], n)
    return Int[_entrycount(l, counts, e) for e in 1:n]
end

"""
    run_lengths(b, n) -> Union{Nothing,Vector{Int}}

How many elements the collection behind a `fType` 31 or 41 branch holds in each
entry, taken from the branch ROOT points it at.

`nothing` when there is no such branch to read, in which case the length is
recovered from where the entry ends — which the basket's offset table gives
exactly, an entry of such a branch holding this member and nothing else.
"""
function run_lengths(b::AnyBranch, n::Int)
    cb = countbranch(b)
    cb === nothing && return nothing
    return count_column(cb, n)
end

countbranch(b::TBranchElement) = b.branchcount
countbranch(::AnyBranch) = nothing

"""
    count_column(cb, n) -> Union{Nothing,Vector{Int}}

The collection sizes a split collection's own branch holds: one `Int32` per
entry and nothing else.

`nothing` if the branch turns out not to be that shape, so that the caller falls
back rather than reading something else as lengths.
"""
function count_column(cb::AnyBranch, n::Int)
    out = Vector{Int}(undef, 0)
    sizehint!(out, n)
    e = 0
    for i in 1:nbaskets(cb)
        bk = basket(cb, i)
        m = min(length(bk), n - e)
        m > 0 || continue
        (isjagged(bk) || length(bk.data) < 4 * m) && return nothing
        append!(out, Int.(read_array(RBuffer(bk.data), Int32, m)))
        e += m
        e == n && break
    end
    return length(out) >= n ? out : nothing
end

# ---------------------------------------------------------------------------
# Reading.

"""
    object_array(b) -> Vector

Every entry of a branch that holds objects, in order.

The shapes are the ones the C++ types have: a class comes back as a
`NamedTuple`, its base classes nested under their own names; an STL sequence as
a `Vector`; a map as a `Vector` of `first`/`second` pairs; a string as a
`String`. A fixed-size member gives one array per entry rather than a column of
a matrix, because it is a member of an object and not a column of the tree.
"""
function object_array(b::AnyBranch)
    rd = objectreader(b)
    rd isa CompositeReader && return assemble(b, rd)
    n = _nentries(b)
    lens = entry_lengths(b, rd, n)
    out = Vector{reader_eltype(rd)}(undef, 0)
    sizehint!(out, n)
    _foreachbasket(b, n) do bk, e0, m
        return append!(out, object_chunk(bk, b, rd, lens, e0, m))
    end
    return out
end

"""
    object_chunk(bk, b, rd, lens, e0, m) -> Vector

One basket's worth of entries.

The buffer is given the file's streamer database and class factory, without
which a class written before versioning — identified by a checksum rather than a
version — could not be recognised at all.
"""
function object_chunk(bk::Basket, b::AnyBranch, rd::ElementReader, lens, e0::Int, m::Int)
    r = RBuffer(bk.data; sinfos=streamerdb(b), factory=CLASS_FACTORY)
    out = Vector{reader_eltype(rd)}(undef, m)
    jag = isjagged(bk)
    for i in 1:m
        stop = length(bk.data)
        if jag
            seek!(r, bk.offsets[i] - 1)
            stop = Int(bk.offsets[i + 1]) - 1
        end
        k = lens === nothing ? -1 : lens[e0 + i]
        out[i] = read_entry(r, rd, k, stop)
    end
    return out
end

"""
    read_entry(r::RBuffer, rd, count, stop) -> Any

One entry from the cursor.

`count` is how many values a variable-length entry holds, or `-1` where that is
not known in advance, and `stop` is where the entry ends — the two ways an
entry's length can be settled.
"""
function read_entry(r::RBuffer, rd::ElementReader, count::Int, stop::Int)
    rd.named && skip_leafclass!(r)
    p = rd.plan
    rd.run && return read_entry_run(r, rd, count, stop)
    if p isa CountedPlan
        count >= 0 || throw(
            ArgumentError(
                "TTree: this branch holds a variable-length member but nothing in the tree counts it",
            ),
        )
        return read_counted(r, p, count)
    end
    return read_value(r, p, entry_framed(r, rd, stop))
end

"""
    entry_framed(r, rd, stop) -> Bool

Whether this entry's value is preceded by a header.

Only the `:sniff` case looks: a top-level `std::string`, which some files write
bare and others frame. A header begins with a byte count and a bare string with
its own length, so the two are told apart by asking whether what would be the
count is a length this entry could possibly have.
"""
function entry_framed(r::RBuffer, rd::ElementReader, stop::Int)
    rd.framing === :framed && return true
    rd.framing === :bare && return false
    p = pos(r)
    stop - p >= 6 || return false
    bcnt = readbe(r, UInt32)
    seek!(r, p)
    (UInt64(bcnt) & Bytes.KBYTE_COUNT_MASK) == 0 && return false
    len = Int64(UInt64(bcnt) & ~UInt64(Bytes.KBYTE_COUNT_MASK))
    return 0 < len <= stop - p - 4
end

"""
    read_entry_run(r::RBuffer, rd, count, stop) -> Vector

A `fType` 31 or 41 entry: one member of every element of a split collection.

A framed member is framed once for the whole run rather than once per element,
exactly as it is when the collection is streamed member-wise into a single
basket — it is the same encoding, spread over branches.
"""
function read_entry_run(r::RBuffer, rd::ElementReader, count::Int, stop::Int)
    p = rd.plan
    rd.framing === :framed || return run_values(r, p, count, stop, false)
    hdr = read_header(r, headerclass(p))
    hdr.len > 0 && (stop = Int(hdr.pos + Int64(hdr.len) + 4))
    v = run_values(r, p, count, stop, hdr.memberwise)
    check_header(r, hdr)
    return v
end

function run_values(r::RBuffer, p::ValuePlan, count::Int, stop::Int, memberwise::Bool)
    count >= 0 && return read_many(r, p, count, false)
    out = Vector{value_eltype(p)}(undef, 0)
    while pos(r) < stop
        push!(out, readbody(r, p, memberwise))
    end
    return out
end

"""
    skip_leafclass!(r::RBuffer) -> nothing

Step over the class name a `TBranchObject` writes before each object: a length
byte, then that many characters and a terminator.
"""
function skip_leafclass!(r::RBuffer)
    n = Int(readbe(r, UInt8))
    skip!(r, n + 1)
    return nothing
end

"""
    assemble(b, rd::CompositeReader) -> Vector

Put a split branch's children back together, one value per entry.

Reading the children *is* reading the branch: ROOT split it so that this could
be done a member at a time, and each child is read by exactly the path that
would read it if it had been asked for by name.
"""
function assemble(b::AnyBranch, rd::CompositeReader)
    cols = Any[array(s) for s in rd.subs]
    n = minimum(length, cols)
    names = Tuple(rd.names)
    nc = length(cols)
    rd.collection || return [NamedTuple{names}(ntuple(j -> cols[j][i], nc)) for i in 1:n]
    return [
        [NamedTuple{names}(ntuple(j -> cols[j][i][k], nc)) for k in eachindex(cols[1][i])]
        for i in 1:n
    ]
end

# ---------------------------------------------------------------------------
# Streaming.

"""
    ObjectChunks

A branch of objects a basket at a time — what [`eachchunk`](@ref) gives for the
values [`object_array`](@ref) reads.

A split branch has no baskets of its own, so there is nothing to hand over a
basket at a time; its one chunk is its children put back together, and it is the
single shape here that materialises a whole column.
"""
struct ObjectChunks{B<:AnyBranch,R}
    branch::B
    reader::R
    lengths::Union{Nothing,Vector{Int}}
    n::Int
end

function object_chunks(b::AnyBranch)
    rd = objectreader(b)
    n = _nentries(b)
    return ObjectChunks(b, rd, entry_lengths(b, rd, n), n)
end

Base.IteratorSize(::Type{<:ObjectChunks}) = Base.SizeUnknown()
Base.IteratorEltype(::Type{<:ObjectChunks}) = Base.EltypeUnknown()

function Base.iterate(c::ObjectChunks{B,CompositeReader}, state::Int=1) where {B}
    state == 1 || return nothing
    return assemble(c.branch, c.reader), 2
end

function Base.iterate(c::ObjectChunks{B,<:ElementReader}, state=(1, 0)) where {B}
    i, e = state
    nb = nbaskets(c.branch)
    while i <= nb && e < c.n
        bk = basket(c.branch, i)
        m = min(length(bk), c.n - e)
        if m == 0
            i += 1
            continue
        end
        return object_chunk(bk, c.branch, c.reader, c.lengths, e, m), (i + 1, e + m)
    end
    return nothing
end

function Base.show(io::IO, c::ObjectChunks)
    return print(io, "ObjectChunks(", repr(Objects.name(c.branch)), ", ", c.n, " entries)")
end
