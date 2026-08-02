# Writing

## Creating a file

```@docs
TTree.create
```

```julia
using TTree

TTree.create("out.root") do f
    write!(f, "h", h)
    write!(f, "g", g)
    write!(f, "s", TObjString("hello"))
end
```

What comes out is an ordinary ROOT file — header, key list, streamer info
record and free list — and ROOT opens it without knowing it was written from
Julia. The streamer info is assembled from the objects actually written, so the
file describes its own contents the way any ROOT file does.

The compression is the file's, and every object written inherits it:

```julia
using TTree.Compress

TTree.create("out.root"; compression=Compress.Settings(Compress.ALG_ZSTD, 5)) do f
    write!(f, "h", h)
end
```

`compression` takes a [`Compress.Settings`](@ref TTree.Compress.Settings) or the
packed integer ROOT stores — `505` is the same thing — and a single `write!`
can override it for one object.

```@docs
TTree.IOFS.write!
```

Writing the same name twice does not replace anything: the second copy gets the
next cycle and becomes what the name resolves to, exactly as `TObject::Write`
does. The earlier one stays on the file and is still reachable by cycle.

## Building histograms

```julia
h = TH1F("h", "a histogram", 10, 0.0, 10.0)      # equal bins
v = TH1D("v", "variable bins", [0.0, 1.0, 3.0, 6.0, 10.0])
h2 = TH2F("h2", "2d", 3, 0.0, 3.0, 4, 0.0, 4.0)

push!(h, 1.5)                                    # ROOT's Fill
push!(h, 2.5, 2.0)                               # ...with a weight
push!(h2, 1.5, 2.5)

sumw2!(h)                                        # keep Σw² per bin
```

[`push!`](@ref Base.push!) updates the running sums that give the mean and the
RMS the way ROOT updates them, so a histogram built here and one built by ROOT
from the same fills carry the same statistics — including the rule that an
entry landing in the underflow or overflow bin is counted but left out of them.

Cells can also be set outright, which is what a histogram computed rather than
filled wants:

```julia
c = bincontents(h)
c[findbin(h, 4.5)] = 12.0
```

## Writing trees

A tree can be written whole, from columns already in memory:

```julia
TTree.create("out.root") do f
    write!(f, "tree", (
        x = Int32.(1:1000),
        y = randn(1000),
        s = ["row-$i" for i in 1:1000],
        v = [rand(Float32, rand(0:3)) for _ in 1:1000],
        p = randn(3, 1000),
    ))
end
```

Each column says by its own type what the branch holds — a `Vector{T}` one
value per entry, a `Vector{String}` a string, a `Matrix{T}` one of its columns,
a `Vector{Vector{T}}` as many values as each entry happens to have. ROOT
records a varying length in a branch of its own, so one is written alongside:
`v` above comes back with an `nv` next to it, which is also how ROOT would have
written it.

The columns are given as a `NamedTuple` or a `Dict`, and `basketsize` and
`compression` can be set for the tree as they can for any other object.

For a tree too large to hold in memory, or one whose entries are computed as
they go, declare the columns and push the entries: [`TreeWriter`](@ref) opens
the tree, [`branch!`](@ref) declares a column, `push!` appends one entry across
all of them, and `close` writes the tree that describes them.

```julia
TTree.create("out.root") do f
    TreeWriter(f, "tree", "events"; basketsize=64_000) do t
        branch!(t, "n", Int32)
        branch!(t, "px", Vector{Float32}; count="n")
        branch!(t, "py", Vector{Float32}; count="n")
        for evt in source
            push!(t, (n=Int32(length(evt)), px=first.(evt), py=last.(evt)))
        end
    end
end
```

Columns fill independently and each flushes a basket of its own once it holds
`basketsize` bytes, which is what keeps a wide tree cheap to read one column of.
[`flush!`](@ref) closes the open baskets early, at an entry boundary of your
choosing. Nothing on the file points at any of them until the writer is closed,
so a writer abandoned part-way leaves the file as valid as it was before —
larger, and with a tree that was never announced.

## Building graphs

```julia
g = TGraph("g", "a graph", [1.0, 2.0, 3.0], [1.0, 4.0, 9.0])

ge = TGraphErrors("ge", "with errors", x, y, ex, ey)
ga = TGraphAsymmErrors("ga", "either side", x, y, exlo, exhi, eylo, eyhi)
```

The error vectors must be as long as the points; a mismatch is an
`ArgumentError` rather than a file ROOT will refuse.

## Round-tripping

Anything this package reads, it can write back:

```julia
TTree.open("in.root") do f
    TTree.create("out.root") do g
        write!(g, "h", f["h"])
    end
end
```

That is the property the tests lean on hardest — read, write, read again, and
compare — because it exercises both directions against each other at every
layer.

The exception is a tree read from one file and written to another. Its metadata
goes out faithfully, but the values live in baskets the tree only points at, and
those pointers are offsets into the file it came from — so what lands in the new
file is a tree whose baskets are not there. Copying a tree between files means
reading the values and writing them again, as above.

## Remote files

`root://` and `roots://` URLs can be written as well as read:

```julia
TTree.create("root://server//path/out.root") do f
    write!(f, "h", h)
end
```

The other schemes are read-only: an HTTP or S3 source answers ranged reads,
which is all reading needs, and this package will say so rather than write half
a file.
