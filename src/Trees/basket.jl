# TBasket: the unit a tree's data is actually stored and compressed in.
#
# A basket is a key like any other, with one twist: ROOT puts the basket's own
# bookkeeping inside the key header rather than in the payload, extending
# `fKeylen` to cover it. That is why a basket's payload is exactly its data and
# nothing else — and why `keylen_for` has a `TBasket` case.
#
# The payload holds one entry after another. When every entry is the same size
# nothing more is needed, and `fLast` marks the end. When they are not — a
# variable-length array, a string — ROOT appends a table of where each entry
# began, and `fLast` marks the boundary between the two.
#
# A basket is not always a record of its own. The one a branch is still filling
# when the tree is written has nowhere on the file to be, so ROOT streams it
# into the branch's own record instead, key header and all. Files written that
# way keep every byte of their data inside the tree, which is why a branch with
# no basket seeks at all can still have entries to give.

"Bytes of basket bookkeeping ROOT stores inside the key header."
const BASKET_HEADER_SIZE = 19

"""
    Basket

One basket, read.

`data` is the entry data with the offset table, if any, already taken off the
end; `offsets` is that table converted to 1-based indices into `data`, with a
final sentinel one past the last entry, so entry `i` is always
`data[offsets[i]:offsets[i + 1] - 1]`. A basket whose entries are all the same
size has no table and an empty `offsets`.

`head` is the key header ROOT reserved at the front of an embedded basket's
buffer, kept verbatim so that such a basket goes back out as it came in. A
basket read from a record of its own has none: there the key *is* the record
header, and `key` holds it.
"""
mutable struct Basket <: ROOTObject
    key::Key
    version::Int16
    bufsize::Int32
    nevbufsize::Int32
    nevbuf::Int32
    last::Int32
    flag::UInt8
    head::Vector{UInt8}
    data::Vector{UInt8}
    offsets::Vector{Int32}
    displacement::Vector{Int32}
end

function Basket()
    return Basket(
        Key(; class="TBasket"),
        Int16(0),
        Int32(0),
        Int32(0),
        Int32(0),
        Int32(0),
        0x00,
        UInt8[],
        UInt8[],
        Int32[],
        Int32[],
    )
end

Bytes.classname(::Basket) = "TBasket"
rversion(::Basket) = Int16(3)

"Number of entries in this basket."
Base.length(b::Basket) = Int(b.nevbuf)

"Whether the basket carries a table of where each entry begins."
isjagged(b::Basket) = !isempty(b.offsets)

"""
    entrybytes(b::Basket, i) -> SubArray{UInt8}

The bytes of the `i`-th entry of a basket that has an offset table.
"""
function entrybytes(b::Basket, i::Integer)
    isjagged(b) ||
        throw(ArgumentError("TTree: this basket has no entry offsets to index by"))
    return @view b.data[b.offsets[i]:(b.offsets[i + 1] - 1)]
end

"""
    read_basket(src::AbstractSource, seek, nbytes=0) -> Basket

Read the basket written at `seek`, `nbytes` long on disk.

`nbytes` comes from the owning branch's `basketbytes` table and saves a read;
pass zero — as for a branch that never recorded it — and the key is fetched
first to find out.
"""
function read_basket(src::AbstractSource, seek::Integer, nbytes::Integer=0)
    seek = Int64(seek)
    n = Int(nbytes)
    if n <= 0
        probe = collect(read_at(src, seek, min(1024, length(src) - Int(seek))))
        n = Int(read_key(RBuffer(probe)).nbytes)
        n > 0 || throw(ArgumentError("TTree: no basket at offset $seek"))
    end

    raw = collect(read_at(src, seek, n))
    r = RBuffer(raw)
    k = read_key(r)
    k.class == "TBasket" ||
        throw(ArgumentError("TTree: the record at $seek is a $(k.class), not a TBasket"))

    b = Basket()
    b.key = k
    b.version = readbe(r, Int16)
    b.bufsize = readbe(r, Int32)
    b.nevbufsize = readbe(r, Int32)
    b.nevbuf = readbe(r, Int32)
    b.last = readbe(r, Int32)
    b.flag = readbe(r, UInt8)

    payload = raw[(Int(k.keylen) + 1):end]
    is_compressed(k) && (payload = Compress.decompress(payload, k.objlen))

    # `fLast` is measured from the start of the key, where ROOT numbers buffer
    # positions from; the payload starts `fKeylen` further on.
    border = Int(b.last) - Int(k.keylen)
    (0 < border <= length(payload)) || (border = length(payload))

    if border < length(payload) && b.nevbuf > 0
        p = RBuffer(payload)
        seek!(p, border)
        b.offsets = _read_offsets(p, Int(b.nevbuf), Int(k.keylen), border)
    end
    resize!(payload, border)
    b.data = payload
    return b
end

"""
    _read_offsets(r::RBuffer, nevbuf, keylen, border) -> Vector{Int32}

The entry offset table at the cursor, converted from ROOT's absolute buffer
positions to 1-based indices into the entry data.

ROOT writes it as a count followed by that many positions. On a basket of its
own the count is one more than the number of entries — the last slot is a
scratch value, not an entry — so the sentinel this returns is computed from
`fLast` rather than taken from the table.
"""
function _read_offsets(r::RBuffer, nevbuf::Int, keylen::Int, border::Int)
    n = Int(readbe(r, Int32))
    n >= nevbuf ||
        throw(ArgumentError("TTree: a basket of $nevbuf entries offers only $n offsets"))
    raw = read_array(r, Int32, n)

    out = Vector{Int32}(undef, nevbuf + 1)
    @inbounds for i in 1:nevbuf
        out[i] = raw[i] - Int32(keylen) + Int32(1)
    end
    out[nevbuf + 1] = Int32(border + 1)
    return out
end

# ---------------------------------------------------------------------------
# The embedded form.
#
# ROOT streams an unflushed basket into the branch that owns it: the key header
# it would have been written with, then the bookkeeping, then — because a
# basket's buffer always begins with room for its own key — the whole buffer,
# key header included. `fLast` measures from the front of that buffer, exactly
# as it does on the file, so the two forms differ only in where the bytes came
# from.

"ROOT's `fFlag`, with the bit that says the offsets are to be recomputed taken off."
_basket_flag(b::Basket) = Int(b.flag) >= 80 ? Int(b.flag) - 80 : Int(b.flag)

"Whether this basket's flag says an offset table follows it."
function _has_offsets(b::Basket)
    return Int(b.flag) < 80 && _basket_flag(b) != 0 && _basket_flag(b) % 10 != 2
end

"Whether this basket's flag says its buffer follows it."
_has_buffer(b::Basket) = (f=_basket_flag(b); f == 1 || f > 10)

function Bytes.unmarshal!(b::Basket, r::RBuffer)
    b.key = read_key(r)
    hdr = read_header(r, "TBasket")
    b.version = hdr.vers
    b.bufsize = readbe(r, Int32)
    b.nevbufsize = readbe(r, Int32)
    b.nevbuf = readbe(r, Int32)
    b.last = readbe(r, Int32)
    b.flag = readbe(r, UInt8)
    b.last > b.bufsize && (b.bufsize = b.last)

    keylen = Int(b.key.keylen)
    border = Int(b.last) - keylen

    if _has_offsets(b) && b.nevbuf > 0
        b.offsets = _read_offsets(r, Int(b.nevbuf), keylen, border)
        _basket_flag(b) > 40 && (b.displacement = _read_offsets_raw(r))
    end

    if _has_buffer(b)
        # ROOT reserved `fKeylen` bytes at the front of the buffer for the key
        # it would be written with; the entries begin after them.
        buf = read_array(r, UInt8, Int(b.last))
        b.head = buf[1:min(keylen, length(buf))]
        b.data = buf[(min(keylen, length(buf)) + 1):end]
    end
    check_header(r, hdr)
    return b
end

"A `WriteArray` of positions ROOT did not translate — the displacement table."
function _read_offsets_raw(r::RBuffer)
    n = Int(readbe(r, Int32))
    return read_array(r, Int32, n)
end

function Bytes.marshal!(w::WBuffer, b::Basket)
    write_key!(w, b.key)
    _write_basket_head!(w, b)

    keylen = Int(b.key.keylen)
    if _has_offsets(b) && b.nevbuf > 0
        writebe!(w, Int32(b.nevbuf))
        write_array!(w, Int32[o + Int32(keylen) - Int32(1) for o in b.offsets[1:(end - 1)]])
        if _basket_flag(b) > 40
            writebe!(w, Int32(length(b.displacement)))
            write_array!(w, b.displacement)
        end
    end

    if _has_buffer(b)
        if length(b.head) == keylen
            write_array!(w, b.head)
        else
            write_key!(w, b.key)
            _write_basket_head!(w, b)
        end
        write_array!(w, b.data)
    end
    return w
end

function _write_basket_head!(w::WBuffer, b::Basket)
    writebe!(w, b.version == 0 ? rversion(b) : b.version)
    writebe!(w, b.bufsize)
    writebe!(w, b.nevbufsize)
    writebe!(w, b.nevbuf)
    writebe!(w, b.last)
    writebe!(w, b.flag)
    return w
end

# ---------------------------------------------------------------------------
# Getting at a branch's baskets, wherever they are.

"""
    nbaskets(b) -> Int

Number of baskets of branch `b` that hold entries.

That is `fWriteBasket` — the baskets on the file — plus the one the branch was
still filling when the tree was written, if it was streamed into the branch
rather than flushed.
"""
function nbaskets(b::AnyBranch)
    core = branchcore(b)
    n = Int(core.writebasket)
    n < length(core.baskets) && core.baskets[n + 1] isa Basket && (n += 1)
    return n
end

"""
    basket(b, i) -> Basket

The `i`-th basket of branch `b`, counting from one.
"""
function basket(b::AnyBranch, i::Integer)
    core = branchcore(b)
    1 <= i <= nbaskets(b) || throw(
        BoundsError("TTree: branch $(repr(Objects.name(b))) has $(nbaskets(b)) baskets", i),
    )

    if i <= length(core.basketseek) && core.basketseek[i] != 0
        isempty(core.filename) || throw(
            ArgumentError(
                "TTree: branch $(repr(Objects.name(b))) keeps its baskets in $(repr(core.filename)), which this package does not follow",
            ),
        )
        f = core.file
        f === nothing && throw(
            ArgumentError(
                "TTree: branch $(repr(Objects.name(b))) is not attached to a file, so its baskets cannot be read",
            ),
        )
        src = f.source
        src === nothing && throw(ArgumentError("TTree: $(f.id) is open for writing only"))
        return read_basket(src, core.basketseek[i], core.basketbytes[i])
    end

    bk = i <= length(core.baskets) ? core.baskets[i] : nothing
    bk isa Basket && return bk
    return throw(
        ArgumentError(
            "TTree: basket $i of branch $(repr(Objects.name(b))) is neither on the file nor in the tree",
        ),
    )
end

"""
    eachbasket(b) -> iterator

Every basket of branch `b` that holds entries, in entry order, read one at a
time.

This is the record as it sits on the file — its key, its entry count and its
decompressed payload. For the values inside it, iterate [`eachchunk`](@ref),
which is this with the decoding done.
"""
eachbasket(b::AnyBranch) = (basket(b, i) for i in 1:nbaskets(b))

function Base.show(io::IO, b::Basket)
    print(
        io,
        "Basket(",
        repr(b.key.name),
        ", ",
        b.nevbuf,
        " entries, ",
        length(b.data),
        " bytes",
    )
    isjagged(b) && print(io, ", jagged")
    return print(io, ")")
end
