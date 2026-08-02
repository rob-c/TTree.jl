# The format

Enough of the ROOT file format to know what this package is doing, and to know
where to look when a file does something unexpected. Each section names the
module that implements it.

## The container — `TTree.IOFS`

A ROOT file begins with the four bytes `root` and a header giving the version,
where the first record starts, where the directory record is, and how the file
is compressed. Everything after that is a sequence of *records*, each one
preceded by a *key*: a small header saying how long the record is, where it
sits, what class it holds, what it is called, and — the part that matters for
reading — how long it was before it was compressed.

Records are not laid out in any particular order and the space between them is
tracked in a free list, so a file can be appended to and rewritten in place.
That is why a key holds its own address: it is the only way to tell a record
that was moved from one that was not.

A directory is itself a record holding a list of keys, so subdirectories are
directories nested by reference rather than by containment. Writing the same
name twice adds a key with the next *cycle* number; the highest cycle is what a
bare name resolves to.

## Compression — `TTree.Compress`

A record larger than 512 bytes is compressed in blocks of at most 16 MB, each
with a nine-byte header naming the algorithm — zlib, LZMA, LZ4 or ZSTD — and
giving the compressed and uncompressed sizes. The block structure is what makes
partial reads possible: the header alone says how far to skip.

ROOT packs the algorithm and level into one integer as `alg * 100 + lvl`, which
is what a file's `fCompress` holds and what
[`Compress.Settings`](@ref TTree.Compress.Settings) unpacks.

LZ4 blocks carry an xxHash64 checksum of the *compressed* payload ahead of it,
which this package computes itself rather than depend on a hashing library for.

## Objects — `TTree.Bytes` and `TTree.Objects`

An object is written as a byte count, a version word, and then its members —
base classes first, streamed inline, each with a header of its own. The byte
count is what lets a reader skip a class it does not know: it can always find
where the object ends without understanding a byte of it.

Two details account for most of the surprises:

  - `TObject` is streamed **without** a byte count — just a version word — so
    it is the one class that has to be read differently from every other.
  - A class declared `ClassDef(X, 0)` has no version number. ROOT writes a
    *checksum* of its layout in place of one, flagged in the version word, and
    a reader has to notice and look the class up by name instead.

Pointer members come in two flavours that look alike and are encoded
differently: a `//->` pointer is streamed inline, where a nullable pointer is
streamed with a tag that may instead be a back-reference to an object already
written. Which one a member is comes from its streamer element type — 63 and
64 respectively — and not from its declared type, which is why `fFunctions` is
read one way in a `TH1` and another in a `TGraph`.

## Streamer info

Every file carries the layout of the classes it contains, as a record of
`TStreamerInfo` objects — one per class per version, each a list of elements
naming a member, its type and its size. This is what makes a ROOT file readable
by software that has never heard of the class: the file explains itself.

This package uses it directly. When a file's description covers exactly the
class version an object was written as, decoding follows the file's own
description; otherwise it follows the description built into this package for
the version it knows. One reader therefore handles `TAxis` v6 through v10 and
`TH1` v3 through v8 with no special case per version, and a member that appears
or disappears between versions is simply a member the description does or does
not list.

```julia
TTree.open("f.root") do f
    db = streamers(f)
    keys(db)                     # every class the file describes
    describe(db["TH1"])          # its layout, member by member
    describe(db["TH1", 8])       # a particular version of it
end
```

A file this package writes carries the same record, assembled from the objects
that went into it and ordered base classes first, so ROOT reads it the way it
reads its own.

## Trees — `TTree.Trees`

A tree is metadata. It names its branches, each branch names its leaves, and a
leaf says what its values are: their type, how many per entry, and — when that
varies — which other leaf holds the count. What a branch *contains* is a list
of file offsets, one per *basket*.

A basket is a record like any other, compressed on its own, holding a run of
consecutive entries of one branch. This is the property the whole format exists
to provide: reading one column of ten touches one column's baskets and leaves
the rest of the file unread, whether it is on a local disk or across a network.

Inside a basket the entries are simply run together — nothing separates them,
nothing labels them — so decoding is entirely a matter of what the leaves say.
Two shapes need more:

  - A variable-length leaf is counted by another leaf, usually in a branch of
    its own, so reading one column can mean reading two.
  - A basket whose entries vary in length carries an *offset table* at its end,
    which is how entry `n` is found without reading entries 1 to `n-1`.

A branch that was never flushed keeps its still-filling basket inside the
branch record rather than on the file, and this package reads that too — it is
the normal state of a small tree.

Leaf types map to Julia types directly, with two that do not: `Float16_t` and
`Double32_t` are stored scaled into a declared range and occupy fewer bytes
than their names suggest, so they are unpacked value by value.
